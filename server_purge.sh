#!/bin/bash

# server_purge.sh — Purges server back to a clean state (Nginx, DBs, PHP, Node.js)
# Matches everything installed in server_setup.sh
# ⚠️ WARNING: Irreversibly removes data and config — use with caution

set -e

log() {
  echo -e "\n--- $1 ---\n"
}

confirm() {
  read -p "$1 (y/N): " CONFIRM
  [[ "$CONFIRM" =~ ^[Yy]$ ]]
}

log "⚠️  WARNING: This will REMOVE all services and data related to:"
echo "  - Nginx"
echo "  - MySQL and PostgreSQL (including data)"
echo "  - PHP and PHP-FPM"
echo "  - Node.js"
echo "  - Composer and PM2"
echo "  - Apache2 (if present)"
echo "  - UFW rules (except OpenSSH)"
echo ""
confirm "Are you sure you want to continue?" || exit 1

# --- Stop and Disable Services ---
log "Stopping services..."
sudo systemctl stop nginx || true
sudo systemctl stop mysql || true
sudo systemctl stop postgresql || true
sudo systemctl stop apache2 || true

# --- UFW Cleanup ---
log "Resetting UFW (firewall)..."
sudo ufw --force reset
sudo ufw allow OpenSSH
sudo ufw --force enable
sudo ufw status verbose

# --- Purge Packages ---
log "Purging installed packages..."
sudo apt purge -y \
  nginx* mysql-* postgresql* \
  php* libapache2-mod-php* apache2* \
  nodejs composer

sudo apt autoremove -y
sudo apt autoclean -y

# --- Remove Configuration & Data ---
log "Removing config directories and databases..."
sudo rm -rf \
  /etc/nginx /var/www /var/log/nginx \
  /etc/mysql /var/lib/mysql /var/log/mysql* \
  /etc/postgresql /var/lib/postgresql /var/log/postgresql \
  /etc/php /var/lib/php /var/log/php* \
  /etc/apache2 /var/log/apache2 \
  /usr/lib/node_modules \
  /root/.composer /root/.config/composer \
  ~/.composer ~/.config/composer

# --- Remove Certificates if Any ---
log "Optionally removing SSL certs..."
if confirm "Remove all Let's Encrypt certificates under /etc/letsencrypt?"; then
  sudo rm -rf /etc/letsencrypt
  echo "✅ Let's Encrypt certs removed."
fi

# --- Final Summary ---
log "✅ Server purge complete."
echo "💡 Remaining:"
echo "  - SSH (OpenSSH)"
echo "  - Base system packages"
echo "🧹 You can now rerun ./server_setup.sh for a clean reinstall."
