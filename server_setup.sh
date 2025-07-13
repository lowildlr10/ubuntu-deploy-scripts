#!/bin/bash

# server_setup.sh — Prepares Ubuntu 24.04 server for multi-user app hosting
# Installs: Nginx, MySQL, PostgreSQL, PHP-FPM, Node.js
# Skips: Apache2 and libapache2-mod-php
# Firewall: UFW manually configured for ports 22, 80, 443

set -e

log() {
  echo -e "\n--- $1 ---\n"
}

read -p "Press Enter to start the initial server setup..."

# --- 1. System Update ---
log "Updating system and installing base tools..."
sudo apt update -y && sudo apt upgrade -y
sudo apt install -y software-properties-common curl gnupg2 ufw ca-certificates lsb-release apt-transport-https

# --- 2. UFW Setup ---
log "Configuring UFW Firewall..."
sudo ufw allow OpenSSH
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp
sudo ufw --force enable
sudo ufw status verbose

# --- 3. Nginx ---
log "Installing Nginx..."
sudo apt install -y nginx
sudo systemctl enable --now nginx

# --- 4. MySQL ---
log "Installing MySQL..."
sudo apt install -y mysql-server
sudo systemctl enable --now mysql
log "✔ Run 'sudo mysql_secure_installation' to secure MySQL"

# --- 5. PostgreSQL ---
log "Installing PostgreSQL..."
sudo apt install -y postgresql postgresql-contrib
sudo systemctl enable --now postgresql

# --- 6. PHP & FPM ---
log "Installing PHP and FPM..."
sudo add-apt-repository ppa:ondrej/php -y
sudo apt update -y

# Prevent Apache and mod-php from being installed
sudo apt-mark hold apache2 apache2-bin apache2-data apache2-utils libapache2-mod-php*

# Install PHP-FPM and extensions only (no apache)
sudo apt install -y \
  php-fpm php-cli php-common \
  php-mysql php-pgsql php-mbstring php-xml php-curl php-zip php-gd

# Cleanup any apache-related leftovers
sudo systemctl stop apache2 || true
sudo apt purge -y apache2* libapache2-mod-php* || true
sudo rm -rf /etc/apache2 || true
sudo apt autoremove -y

# Enable the detected PHP-FPM service
PHP_VERSION=$(php -r "echo PHP_MAJOR_VERSION . '.' . PHP_MINOR_VERSION;" 2>/dev/null || echo "8.2")
sudo systemctl enable --now php${PHP_VERSION}-fpm

# --- 7. Node.js ---
log "Installing Node.js..."
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs

log "✅ Server setup complete."
echo "📦 PHP version: $PHP_VERSION"
echo "📂 Nginx sites: /etc/nginx/sites-available/"
echo "🚀 Use 'pm2' or Supervisor for Node/Laravel process management."
echo "🔐 Secure MySQL: sudo mysql_secure_installation"
