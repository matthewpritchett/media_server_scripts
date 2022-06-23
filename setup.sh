#!/bin/bash

function delete_config() {
  local filename=$1
  local key=$2
  
  sed --in-place "/^$key/d" "$filename"
  sed -i -e '/./,$!d' -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$filename"
  echo "" >> "$filename"
}

function upsert_config() {
  local filename=$1
  local key=$2
  local value=$3
  
  sed --in-place "/^$key/d" "$filename"
  sed -i -e '/./,$!d' -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$filename"
  echo "$key$value" >> "$filename"
  echo "" >> "$filename"
}

function setup_ssh() {
  echo "Beginning SSH Setup"
  upsert_config "/etc/ssh/sshd_config" "PermitRootLogin" " no"
  upsert_config "/etc/ssh/sshd_config" "PasswordAuthentication" " no"
  systemctl reload sshd
  echo "Finished SSH Setup"
}

function setup_media_user() {
  if id -u "media" >/dev/null 2>&1; then
    echo "Skipping media user setup as it already exists"
  else
    echo "Beginning media User Setup"
    groupadd --gid 8675309 media
    adduser --gecos "" --no-create-home --disabled-password --disabled-login --uid 8675309 --gid 8675309 media
    usermod -aG media pritchett
    echo "Finished media User Setup"
  fi
}

function setup_samba() {
  apt-get -qq -y install samba
  
  cp ./etc/samba/smb.conf /etc/samba/smb.conf
  chown root:root /etc/samba/smb.conf
  chmod 644 /etc/samba/smb.conf
  
  echo "SMB password is used for accessing the network shares."
  smbpasswd -a media
  service smbd restart
}

function setup_networking() {
  upsert_config "/etc/netplan/00-installer-config.yaml" "  renderer:" " NetworkManager"
  netplan generate
  netplan apply
}

function  setup_cockpit() {
  echo "Beginning Cockpit Setup"
  curl -sSL https://repo.45drives.com/setup -o setup-repo.sh
  sudo bash setup-repo.sh
  apt-get -qq -y install cockpit cockpit-benchmark cockpit-zfs-manager cockpit-navigator cockpit-file-sharing cockpit-machines
  systemctl start cockpit
  echo "Finished Cockpit Setup"
}

function setup_email() {
  echo "Beginning Email Setup"
  apt-get -qq -y install bsd-mailx msmtp msmtp-mta
  
  read -r -p "Enter the SMTP Username (your_email@gamil.com): " smtpUser
  read -r -p -s "Enter the SMTP Password: " smtpPassword
  read -r -p "Enter the SMTP Server (smtp.gmail.com): " smtpServer
  read -r -p "Enter the SMTP Port (587): " smtpPort
  read -r -p "Enter the email to send notifications to: " notifyEmail
  
  cat <<- EOF > /etc/msmtprc
  defaults
  auth on
  tls on
  tls_trust_file /etc/ssl/certs/ca-certificates.crt

  account default 
  host $smtpServer
  port $smtpPort
  user $smtpUser
  password $smtpPassword
  from $smtpUser

  aliases /etc/aliases

EOF
  chown root:root /etc/msmtprc
  chmod 644 /etc/msmtprc

  cat <<- EOF > /etc/aliases
  root: $notifyEmail
  default: $notifyEmail

EOF
  chown root:root /etc/aliases
  chmod 644 /etc/aliases

  echo "Sending test email..."
  echo "mail works!" | mail root
  echo "sendmail works!" | sendmail root
  echo "Finished Email Setup"
}

function setup_fail2ban() {
  echo "Starting Fail2Ban Setup"
  apt-get -qq -y install fail2ban
  echo "Finished Fail2Ban Setup"
}

function setup_cloud-init() {
  echo "Starting Cloud-Init Setup"
  touch /etc/cloud/cloud-init.disabled
  echo "Finished Cloud-Init Setup"
}

function setup_zfs() {
  echo "Starting ZFS Setup"
  apt-get -qq -y install zfsutils-linux
  upsert_config "/etc/zfs/zed.d/zed.rc" "ZED_NOTIFY_VERBOSE=" "1"
  upsert_config "/etc/zfs/zed.d/zed.rc" "ZED_EMAIL_ADDR=" "root"
  zpool import vault
  echo "Finished ZFS Setup"
}

function setup_hdd_monitoring() {
  echo "Starting HDD Monitoring Setup"
  apt-get -qq -y install smartmontools
  upsert_config "/etc/smartd.conf" "DEVICESCAN" " -a -o on -S on -n standby,q -s (S/../.././02|L/../../6/03) -W 4,38,45 -m root"
  echo "Finished HDD Monitoring Setup"
}

function setup_cron() {
  echo "Starting cron Setup"
  crontab ./mycron
  echo "Finished cron Setup"
}

function setup_docker() {
  echo "Starting Docker Setup"
  apt-get -qq -y install docker.io
  echo "Finished Docker Setup"
}

function setup_portainer() {
  docker stop portainer
  docker rm portainer
  docker run -d -p 8000:8000 -p 9443:9443 --name portainer \
    --restart=always \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v portainer_data:/data \
    portainer/portainer-ce:2.9.3
}

function setup_nut() {
  apt-get -qq -y install nut
  
  local upspassword
  upspassword=$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 10)
  
  upsert_config "/etc/nut/nut.conf" "MODE=" "standalone"
  
  cat <<- EOF > /etc/nut/upsd.users
  [upsmon]
    password  = $upspassword
    upsmon master

EOF
  chown root:nut /etc/nut/upsd.users
  chmod 460 /etc/nut/upsd.users
  
  cp ./etc/nut/ups.conf /etc/nut/ups.conf
  chown root:nut /etc/nut/ups.conf
  chmod 460 /etc/nut/ups.conf

  upsert_config "/etc/nut/upsd.conf" "MAXAGE" " 25"
  
  upsert_config "/etc/nut/upsmon.conf" "MONITOR" " cyberp@localhost 1 upsmon $upspassword master"
  upsert_config "/etc/nut/upsmon.conf" "NOTIFYCMD" " /usr/sbin/upssched"
  upsert_config "/etc/nut/upsmon.conf" "DEADTIME" " 25"
  delete_config "/etc/nut/upsmon.conf" "POWERDOWNFLAG"
  upsert_config "/etc/nut/upsmon.conf" "NOTIFYFLAG ONLINE" "       SYSLOG+EXEC"
  upsert_config "/etc/nut/upsmon.conf" "NOTIFYFLAG ONBATT" "       SYSLOG+EXEC"
  upsert_config "/etc/nut/upsmon.conf" "NOTIFYFLAG LOWBATT" "      SYSLOG+EXEC"
  upsert_config "/etc/nut/upsmon.conf" "NOTIFYFLAG FSD" "          SYSLOG+EXEC"
  upsert_config "/etc/nut/upsmon.conf" "NOTIFYFLAG COMMOK" "       SYSLOG+EXEC"
  upsert_config "/etc/nut/upsmon.conf" "NOTIFYFLAG COMMBAD" "      SYSLOG+EXEC"
  upsert_config "/etc/nut/upsmon.conf" "NOTIFYFLAG SHUTDOWN" "     SYSLOG+EXEC"
  upsert_config "/etc/nut/upsmon.conf" "NOTIFYFLAG REPLBATT" "     SYSLOG+EXEC"
  upsert_config "/etc/nut/upsmon.conf" "NOTIFYFLAG NOCOMM" "       SYSLOG+EXEC"
  upsert_config "/etc/nut/upsmon.conf" "NOTIFYFLAG NOPARENT" "     SYSLOG+EXEC"

  cp ./usr/bin/upssched-cmd /usr/bin/upssched-cmd
  chown root:root /usr/bin/upssched-cm
  chmod 755 /usr/bin/upssched-cm

  cp ./etc/nut/upssched.conf /etc/nut/upssched.conf
  chown root:nut /etc/nut/ups.conf
  chmod 460 /etc/nut/ups.conf
  
  service nut-service start
  service nut-monitor start
}

echo "Media Server Setup"
echo "=================="

PS3="Select the operation: "
options=("Automated Setup" "Setup Email" "Update Portainer" "Quit")
select opt in "${options[@]}"
do
  case $opt in
    "Automated Setup")
      echo "Automatic Setup"
      setup_email
      setup_ssh
      setup_networking
      setup_cockpit
      setup_media_user
      setup_samba
      setup_fail2ban
      setup_cloud-init
      setup_zfs
      setup_hdd_monitoring
      setup_cron
      setup_docker
      setup_portainer
      setup_nut
      break
      ;;
    "Setup Email")
      setup_email
      break
      ;;
    "Update Portainer")
      setup_portainer
      break
      ;;
    "Quit")
      break
      ;;
    *) 
      echo "Invalid option $REPLY"
      ;;
  esac
done