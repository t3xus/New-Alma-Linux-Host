#!/bin/bash

# Ensure the script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run this script as root."
  exit 1
fi

# Prompt user for public IP and domain/subdomain
read -p "Enter the public IP address of the server: " PUBLIC_IP
read -p "Enter the domain or subdomain to be used (e.g., example.com): " DOMAIN_NAME

# Update and install required packages
dnf update -y
dnf install -y epel-release

# Check and install required dependencies
dependency_list=(
  certbot
  nginx
  httpd
  mod_ssl
  fail2ban
  wget
  policycoreutils-python-utils
  openvpn
  geoip
  geoip-update
  cronie
  tar
  nano
)

for package in "${dependency_list[@]}"; do
  if ! rpm -q $package &>/dev/null; then
    echo "Installing missing dependency: $package"
    dnf install -y $package
  else
    echo "$package is already installed."
  fi
done

# Check if any webserver is installed
if ! systemctl is-active --quiet nginx && ! systemctl is-active --quiet httpd; then
  echo "No webserver is currently active. Installing and configuring Nginx to use all available IPs on port 443..."

  # Configure Nginx for port 443 to listen on all available IPs
  NGINX_DEFAULT_CONF="/etc/nginx/conf.d/default_ssl.conf"
  cat <<EOL > $NGINX_DEFAULT_CONF
server {
    listen 443 ssl;
    server_name _;

    ssl_certificate /etc/ssl/certs/ssl-cert-snakeoil.pem; # Replace with your certificate
    ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key; # Replace with your private key

    location / {
        return 200 'Default Nginx SSL Configuration';
        add_header Content-Type text/plain;
    }
}
EOL

  # Enable and start Nginx
  systemctl enable nginx --now
  systemctl restart nginx
else
  echo "A webserver is already active. Skipping additional configuration."
fi

# Configure Nginx for the domain
NGINX_CONF="/etc/nginx/conf.d/$DOMAIN_NAME.conf"
echo "Creating Nginx configuration for $DOMAIN_NAME..."
cat <<EOL > $NGINX_CONF
server {
    listen 80;
    server_name $DOMAIN_NAME;

    location / {
        proxy_pass http://localhost:8080; # Change as needed
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOL

systemctl restart nginx

# Configure Apache for the domain
APACHE_CONF="/etc/httpd/conf.d/$DOMAIN_NAME.conf"
echo "Creating Apache configuration for $DOMAIN_NAME..."
cat <<EOL > $APACHE_CONF
<VirtualHost *:80>
    ServerName $DOMAIN_NAME
    DocumentRoot /var/www/html

    <Directory /var/www/html>
        Options -Indexes +FollowSymLinks
        AllowOverride All
    </Directory>

    ErrorLog /var/log/httpd/${DOMAIN_NAME}_error.log
    CustomLog /var/log/httpd/${DOMAIN_NAME}_access.log combined
</VirtualHost>
EOL

systemctl enable httpd --now
systemctl restart httpd

# Obtain SSL certificates for Nginx and Apache
certbot --nginx -d $DOMAIN_NAME --non-interactive --agree-tos -m admin@$DOMAIN_NAME
certbot --apache -d $DOMAIN_NAME --non-interactive --agree-tos -m admin@$DOMAIN_NAME

# Save SSL certificates to the user's home directory
LOGGED_USER=$(logname)
mkdir -p /home/$LOGGED_USER/ssl_backups
cp -r /etc/letsencrypt /home/$LOGGED_USER/ssl_backups/
chown -R $LOGGED_USER:$LOGGED_USER /home/$LOGGED_USER/ssl_backups

# Download and set up the GeoIP database
GEOIP_FILE="/usr/share/GeoIP/GeoIP.dat"
echo "Updating GeoIP database..."
geoipupdate

if [ -f $GEOIP_FILE ]; then
    echo "GeoIP database updated successfully."
else
    echo "Failed to update GeoIP database."
fi

# Configure OpenVPN
OPENVPN_CONF="/etc/openvpn/server/${DOMAIN_NAME}.conf"
echo "Creating OpenVPN server configuration..."
cat <<EOL > $OPENVPN_CONF
port 1194
proto udp
dev tun
ca /etc/openvpn/easy-rsa/pki/ca.crt
cert /etc/openvpn/easy-rsa/pki/issued/server.crt
key /etc/openvpn/easy-rsa/pki/private/server.key
dh /etc/openvpn/easy-rsa/pki/dh.pem
server 10.8.0.0 255.255.255.0
ifconfig-pool-persist ipp.txt
push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 8.8.8.8"
push "dhcp-option DNS 8.8.4.4"
keepalive 10 120
tls-auth /etc/openvpn/easy-rsa/pki/ta.key 0
cipher AES-256-CBC
persist-key
persist-tun
status openvpn-status.log
verb 3
EOL
systemctl enable openvpn-server@${DOMAIN_NAME} --now

# Configure SSH banner
SSH_BANNER="/etc/ssh/banner.txt"
echo "Creating SSH login banner..."
cat <<EOL > $SSH_BANNER
========================================
Welcome to $DOMAIN_NAME
========================================
Unauthorized access is prohibited.
All activities are monitored and logged.
========================================
EOL

sed -i 's/^#Banner.*/Banner $SSH_BANNER/' /etc/ssh/sshd_config
systemctl restart sshd

# Configure Firewalld
systemctl enable firewalld --now
firewall-cmd --permanent --set-default-zone=public
firewall-cmd --permanent --add-service=ssh
firewall-cmd --permanent --add-service=http
firewall-cmd --permanent --add-service=https
firewall-cmd --permanent --add-port=8080/tcp
firewall-cmd --permanent --add-port=1194/udp
firewall-cmd --permanent --add-service=ntp
firewall-cmd --permanent --add-port=5060-5061/udp
firewall-cmd --permanent --add-port=3389/tcp
firewall-cmd --permanent --add-port=5900-5901/tcp
firewall-cmd --reload

# Configure Fail2Ban with permanent bans
FAIL2BAN_JAIL_CONF="/etc/fail2ban/jail.local"
echo "Configuring Fail2Ban for SSH login protection..."
cat <<EOL > $FAIL2BAN_JAIL_CONF
[DEFAULT]
bantime = -1
findtime = 600
maxretry = 3
backend = auto

[sshd]
enabled = true
port = ssh
logpath = /var/log/secure
EOL

systemctl enable fail2ban --now

# Set up automatic certificate renewal
echo "Setting up automatic certificate renewal..."
(crontab -l 2>/dev/null; echo "0 0 * * * certbot renew --quiet && systemctl reload nginx && systemctl reload httpd") | crontab -

# Print success message
echo "Let's Encrypt and server configurations have been successfully set up for $DOMAIN_NAME on AlmaLinux with firewall rules, GeoIP, and Fail2Ban configured!"
