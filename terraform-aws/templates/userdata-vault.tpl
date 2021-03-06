#!/usr/bin/env bash
set -x
exec > >(tee /var/log/tf-user-data.log|logger -t user-data ) 2>&1

logger() {
  DT=$(date '+%Y/%m/%d %H:%M:%S')
  echo "$DT $0: $1"
}

logger "Running"

##--------------------------------------------------------------------
## Variables

# Get Private IP address
#HOSTNAME=$(curl http://169.254.169.254/latest/meta-data/hostname)
PRIVATE_IP=$(curl http://169.254.169.254/latest/meta-data/local-ipv4)
#PUBLIC_IP=$(curl http://169.254.169.254/latest/meta-data/public-ipv4)

# S3 Bucket With Enterprise Binaries
S3_BUCKET="${tpl_s3_bucket_name}"
VAULT_ZIP="${tpl_vault_zip_file}"
CONSUL_ZIP="${tpl_consul_zip_file}"

# Detect package management system.
YUM=$(which yum 2>/dev/null)
APT_GET=$(which apt-get 2>/dev/null)

##--------------------------------------------------------------------
## Functions

user_rhel() {
  # RHEL/CentOS user setup
  sudo /usr/sbin/groupadd --force --system $${USER_GROUP}

  if ! getent passwd $${USER_NAME} >/dev/null ; then
    sudo /usr/sbin/adduser \
      --system \
      --gid $${USER_GROUP} \
      --home $${USER_HOME} \
      --no-create-home \
      --comment "$${USER_COMMENT}" \
      --shell /bin/false \
      $${USER_NAME}  >/dev/null
  fi
}

user_ubuntu() {
  # UBUNTU user setup
  if ! getent group $${USER_GROUP} >/dev/null
  then
    sudo addgroup --system $${USER_GROUP} >/dev/null
  fi

  if ! getent passwd $${USER_NAME} >/dev/null
  then
    sudo adduser \
      --system \
      --disabled-login \
      --ingroup $${USER_GROUP} \
      --home $${USER_HOME} \
      --no-create-home \
      --gecos "$${USER_COMMENT}" \
      --shell /bin/false \
      $${USER_NAME}  >/dev/null
  fi
}

##--------------------------------------------------------------------
## Install Base Prerequisites

logger "Setting timezone to UTC"
sudo timedatectl set-timezone UTC

if [[ ! -z $${YUM} ]]; then
  logger "RHEL/CentOS system detected"
  logger "Performing updates and installing prerequisites"
  sudo yum-config-manager --enable rhui-REGION-rhel-server-releases-optional
  sudo yum-config-manager --enable rhui-REGION-rhel-server-supplementary
  sudo yum-config-manager --enable rhui-REGION-rhel-server-extras
  sudo yum -y check-update
  sudo yum install -q -y wget unzip bind-utils ruby rubygems ntp jq
  sudo systemctl start ntpd.service
  sudo systemctl enable ntpd.service
elif [[ ! -z $${APT_GET} ]]; then
  logger "Debian/Ubuntu system detected"
  logger "Performing updates and installing prerequisites"
  sudo apt-get -qq -y update
  sudo apt-get install -qq -y wget unzip dnsutils ruby rubygems ntp jq
  sudo systemctl start ntp.service
  sudo systemctl enable ntp.service
  logger "Disable reverse dns lookup in SSH"
  sudo sh -c 'echo "\nUseDNS no" >> /etc/ssh/sshd_config'
  sudo service ssh restart
else
  logger "Prerequisites not installed due to OS detection failure"
  exit 1;
fi

##--------------------------------------------------------------------
## Install AWS-Specific Prerequisites

if [[ ! -z $${YUM} ]]; then
  logger "RHEL/CentOS system detected"
  logger "Performing updates and installing prerequisites"
  curl --silent -O https://bootstrap.pypa.io/get-pip.py
  sudo python get-pip.py
  sudo pip install awscli
elif [[ ! -z $${APT_GET} ]]; then
  logger "Debian/Ubuntu system detected"
  logger "Performing updates and installing prerequisites"
  sudo apt-get -qq -y update
  sudo apt-get install -qq -y awscli
else
  logger "AWS Prerequisites not installed due to OS detection failure"
  exit 1;
fi

##--------------------------------------------------------------------
## Configure Consul user

USER_NAME="consul"
USER_COMMENT="HashiCorp Consul user"
USER_GROUP="consul"
USER_HOME="/srv/consul"

if [[ ! -z $${YUM} ]]; then
  logger "Setting up user $${USER_NAME} for RHEL/CentOS"
  user_rhel
elif [[ ! -z $${APT_GET} ]]; then
  logger "Setting up user $${USER_NAME} for Debian/Ubuntu"
  user_ubuntu
else
  logger "$${USER_NAME} user not created due to OS detection failure"
  exit 1;
fi

##--------------------------------------------------------------------
## Install Consul

logger "Downloading Consul"
aws --region ${tpl_aws_region} s3 cp s3://$${S3_BUCKET}/$${CONSUL_ZIP} /tmp/$${CONSUL_ZIP} --cli-read-timeout=0

logger "Installing Consul"
sudo unzip -o /tmp/$${CONSUL_ZIP} -d /usr/local/bin/
sudo chmod 0755 /usr/local/bin/consul
sudo chown consul:consul /usr/local/bin/consul
# Config dir
sudo mkdir -pm 0755 /etc/consul.d
# Storage dir
sudo mkdir -pm 0755 /opt/consul
# SSL dir (optional)
sudo mkdir -pm 0755 /etc/ssl/consul

logger "/usr/local/bin/consul --version: $(/usr/local/bin/consul --version)"

logger "Configuring Consul"

# Consul Client Config
sudo tee /etc/consul.d/consul-default.json <<EOF
{
  "datacenter": "${tpl_consul_dc}",
  "data_dir": "/opt/consul/data",
  "bind_addr": "$${PRIVATE_IP}",
  "log_level": "INFO",
  "ui": true,
  "retry_join": ["provider=aws tag_key=ConsulDC tag_value=${tpl_consul_dc}"]
}
EOF

# Consul Server Config
sudo tee /etc/consul.d/consul-server.json <<EOF
{
  "server": true,
  "bootstrap_expect": 1
}
EOF

sudo chown -R consul:consul /etc/consul.d /opt/consul /etc/ssl/consul
sudo chmod -R 0644 /etc/consul.d/*

##--------------------------------------------------------------------
## Create Consul Systemd Service

# Service Definition
read -d '' CONSUL_SERVICE <<EOF
[Unit]
Description=Consul Agent

[Service]
Restart=on-failure
ExecStart=/usr/local/bin/consul agent -config-dir /etc/consul.d
ExecReload=/bin/kill -HUP $MAINPID
KillSignal=SIGTERM
User=consul
Group=consul

[Install]
WantedBy=multi-user.target
EOF

if [[ ! -z $${YUM} ]]; then
  SYSTEMD_DIR="/etc/systemd/system"
  logger "Installing systemd services for RHEL/CentOS"
  echo "$${CONSUL_SERVICE}" | sudo tee $${SYSTEMD_DIR}/consul.service
  sudo chmod 0664 $${SYSTEMD_DIR}/consul*
elif [[ ! -z $${APT_GET} ]]; then
  SYSTEMD_DIR="/lib/systemd/system"
  logger "Installing systemd services for Debian/Ubuntu"
  echo "$${CONSUL_SERVICE}" | sudo tee $${SYSTEMD_DIR}/consul.service
  sudo chmod 0664 $${SYSTEMD_DIR}/consul*
else
  logger "Service not installed due to OS detection failure"
  exit 1;
fi

sudo systemctl enable consul
sudo systemctl start consul

##--------------------------------------------------------------------
## Install & Configure Dnsmasq

if [[ ! -z $${YUM} ]]; then
  logger "Installing dnsmasq"
  sudo yum install -q -y dnsmasq
elif [[ ! -z $${APT_GET} ]]; then
  logger "Installing dnsmasq"
  sudo apt-get -qq -y update
  sudo apt-get install -qq -y dnsmasq-base dnsmasq
else
  logger "Dnsmasq not installed due to OS detection failure"
  exit 1;
fi

logger "Configuring dnsmasq to forward .consul requests to consul port 8600"
sudo sh -c 'echo "server=/consul/127.0.0.1#8600" >> /etc/dnsmasq.d/consul'

sudo systemctl enable dnsmasq
sudo systemctl restart dnsmasq

##--------------------------------------------------------------------
## Configure Vault user

USER_NAME="vault"
USER_COMMENT="HashiCorp Vault user"
USER_GROUP="vault"
USER_HOME="/srv/vault"

if [[ ! -z $${YUM} ]]; then
  logger "Setting up user $${USER_NAME} for RHEL/CentOS"
  user_rhel
elif [[ ! -z $${APT_GET} ]]; then
  logger "Setting up user $${USER_NAME} for Debian/Ubuntu"
  user_ubuntu
else
  logger "$${USER_NAME} user not created due to OS detection failure"
  exit 1;
fi

##--------------------------------------------------------------------
## Install Vault

logger "Downloading Vault"
aws --region ${tpl_aws_region} s3 cp s3://$${S3_BUCKET}/$${VAULT_ZIP} /tmp/$${VAULT_ZIP} --cli-read-timeout=0

logger "Installing Vault"
sudo unzip -o /tmp/$${VAULT_ZIP} -d /usr/local/bin/
sudo chmod 0755 /usr/local/bin/vault
sudo chown vault:vault /usr/local/bin/vault
sudo mkdir -pm 0755 /etc/vault.d
sudo mkdir -pm 0755 /etc/ssl/vault

logger "/usr/local/bin/vault --version: $(/usr/local/bin/vault --version)"

logger "Configuring Vault"
sudo tee /etc/vault.d/vault.hcl <<EOF
api_addr = "http://active.${tpl_vault_service_name}.service.${tpl_consul_dc}.consul:8200"
cluster_addr = "https://active.${tpl_vault_service_name}.service.${tpl_consul_dc}.consul:8201"

storage "consul" {
    service = "${tpl_vault_service_name}"
    path = "${tpl_vault_service_name}"
}

listener "tcp" {
  address     = "$${PRIVATE_IP}:8200"
  #address     = "0.0.0.0:8200"
  tls_disable = 1
}

seal "awskms" {
  region = "${tpl_aws_region}"
  kms_key_id = "${tpl_kms_key}"
}

ui=true
EOF

sudo chown -R vault:vault /etc/vault.d /etc/ssl/vault
sudo chmod -R 0644 /etc/vault.d/*

sudo tee -a /etc/environment <<EOF
export VAULT_ADDR=http://$${PRIVATE_IP}:8200
export VAULT_SKIP_VERIFY=true
EOF

source /etc/environment

logger "Granting mlock syscall to vault binary"
sudo setcap cap_ipc_lock=+ep /usr/local/bin/vault

##--------------------------------------------------------------------
## Install Vault Systemd Service

read -d '' VAULT_SERVICE <<EOF
[Unit]
Description=Vault Agent
Requires=network-online.target
After=network-online.target

[Service]
Restart=on-failure
PermissionsStartOnly=true
ExecStartPre=/sbin/setcap 'cap_ipc_lock=+ep' /usr/local/bin/vault
ExecStart=/usr/local/bin/vault server -config /etc/vault.d
ExecReload=/bin/kill -HUP $MAINPID
KillSignal=SIGTERM
User=vault
Group=vault

[Install]
WantedBy=multi-user.target

EOF

if [[ ! -z $${YUM} ]]; then
  SYSTEMD_DIR="/etc/systemd/system"
  logger "Installing systemd services for RHEL/CentOS"
  echo "$${VAULT_SERVICE}" | sudo tee $${SYSTEMD_DIR}/vault.service
  sudo chmod 0664 $${SYSTEMD_DIR}/vault*
elif [[ ! -z $${APT_GET} ]]; then
  SYSTEMD_DIR="/lib/systemd/system"
  logger "Installing systemd services for Debian/Ubuntu"
  echo "$${VAULT_SERVICE}" | sudo tee $${SYSTEMD_DIR}/vault.service
  sudo chmod 0664 $${SYSTEMD_DIR}/vault*
else
  logger "Service not installed due to OS detection failure"
  exit 1;
fi

sudo systemctl enable vault
sudo systemctl start vault

logger "Complete"
