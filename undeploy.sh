#!/bin/bash

# undeploy.sh – Safely remove a user's full deployment: Nginx, DBs, SSL, Supervisor, PHP-FPM, user account, group

set -euo pipefail

echo "⚠️ Starting undeployment..."

# --- Identify User ---
read -p "Enter username to undeploy: " USERNAME
USERNAME=$(echo "$USERNAME" | xargs)

if ! id "$USERNAME" &>/dev/null; then
  echo "❌ User '$USERNAME' does not exist. Exiting."
  exit 1
fi

USER_HOME="/home/$USERNAME"

# --- Auto-detect PHP version for user pool ---
PHP_VERSION=$(sudo bash -c "grep -lR '^\[$USERNAME\]' /etc/php/*/fpm/pool.d/ 2>/dev/null | sed -n 's|/etc/php/\([^/]*\)/fpm.*|\1|p' | head -n 1")
PHP_VERSION="${PHP_VERSION:-}"

if [[ -n "$PHP_VERSION" ]]; then
  FPM_SERVICE="php$PHP_VERSION-fpm"
  echo "📛 Detected PHP version: $PHP_VERSION"
else
  FPM_SERVICE=""
  echo "ℹ️ No PHP-FPM pool found for '$USERNAME'."
fi

# --- Stop PHP-FPM and user processes ---
echo "🔪 Killing all processes owned by '$USERNAME'..."
if [[ -n "$FPM_SERVICE" ]]; then
  echo "⛔️ Stopping PHP-FPM service: $FPM_SERVICE..."
  if systemctl is-active --quiet "$FPM_SERVICE"; then
    sudo systemctl stop "$FPM_SERVICE"
    echo "✅ $FPM_SERVICE stopped."
  else
    echo "ℹ️ $FPM_SERVICE is not running."
  fi

  sudo rm -f "/etc/php/$PHP_VERSION/fpm/pool.d/$USERNAME.conf"
  sudo systemctl start "$FPM_SERVICE"
  echo "♻️ Restarted $FPM_SERVICE to refresh pool configuration."
fi

sudo pkill -KILL -u "$USERNAME" || echo "ℹ️ No running processes found."

# --- Remove PM2 apps and config ---
echo "🧹 Cleaning up PM2 processes and config for '$USERNAME'..."

sudo -u "$USERNAME" bash <<EOF
  export HOME="/home/$USERNAME"
  export PATH="\$HOME/.nvm/versions/node/*/bin:\$PATH"

  if command -v pm2 >/dev/null 2>&1; then
    pm2 delete all || echo "ℹ️ No PM2 apps to delete."
    pm2 unstartup systemd -u "$USERNAME" --hp "\$HOME" || echo "ℹ️ PM2 unstartup not configured."
    pm2 save --force || echo "ℹ️ PM2 save skipped."
  fi
EOF

# Remove .pm2 directory
sudo rm -rf "/home/$USERNAME/.pm2"
echo "✅ PM2 cleanup done."

# --- Remove Nginx Configs ---
echo "🧹 Removing Nginx configs..."
sudo rm -f "/etc/nginx/sites-enabled/${USERNAME}_*"
sudo rm -f "/etc/nginx/sites-available/${USERNAME}_*"
sudo rm -f "/home/${USERNAME}/nginx/sites-available/${USERNAME}_*"

if sudo nginx -t &>/dev/null; then
  sudo systemctl reload nginx
  echo "✅ Nginx configs removed and reloaded."
else
  echo "⚠️ Nginx config test failed. Skipping reload."
fi

# --- SSL Cleanup ---
read -p "Remove Let's Encrypt certs? (Y/n): " REMOVE_SSL
if [[ "$REMOVE_SSL" =~ ^[Yy]$ ]]; then
  read -p "Enter domain(s) (comma-separated): " DOMAINS
  IFS=',' read -ra DOMAIN_LIST <<< "$DOMAINS"
  for DOMAIN in "${DOMAIN_LIST[@]}"; do
    DOMAIN=$(echo "$DOMAIN" | xargs)
    if [[ -n "$DOMAIN" ]]; then
      sudo certbot delete --cert-name "$DOMAIN" || echo "⚠️ Certificate '$DOMAIN' not found."
    fi
  done
  echo "✅ SSL certs removed."
fi

# --- Remove Supervisor ---
if command -v supervisorctl >/dev/null 2>&1; then
  echo "🧹 Removing Supervisor config..."
  if pgrep -f supervisord >/dev/null; then
    sudo rm -f "/etc/supervisor/conf.d/${USERNAME}_queue.conf"
    sudo supervisorctl reread || echo "⚠️ supervisorctl reread failed."
    sudo supervisorctl update || echo "⚠️ supervisorctl update failed."
    sudo supervisorctl stop "${USERNAME}_queue" || echo "⚠️ Could not stop ${USERNAME}_queue"
    echo "✅ Supervisor config removed."
  else
    echo "⚠️ supervisord is not running. Skipping Supervisor cleanup."
  fi
else
  echo "ℹ️ Supervisor is not installed. Skipping."
fi

# --- Remove Databases ---
read -p "Remove MySQL/PostgreSQL databases? (Y/n): " REMOVE_DB
if [[ "$REMOVE_DB" =~ ^[Yy]$ ]]; then
  # MySQL
  if command -v mysql >/dev/null 2>&1; then
    echo "🔎 Checking for MySQL databases..."
    MYSQL_DBS=$(sudo mysql -sN -e "SHOW DATABASES;" 2>/dev/null | grep -i "^${USERNAME}" || true)
    for DB in $MYSQL_DBS; do
      sudo mysql -e "DROP DATABASE IF EXISTS \`$DB\`;"
    done
    sudo mysql -e "DROP USER IF EXISTS '$USERNAME'@'localhost';"
    echo "✅ MySQL databases and user removed."
  else
    echo "ℹ️ MySQL is not installed. Skipping."
  fi

  # PostgreSQL
  if command -v psql >/dev/null 2>&1; then
    echo "🔎 Checking for PostgreSQL databases..."
    PG_DBS=$(sudo -u postgres psql -t -c "SELECT datname FROM pg_database WHERE datdba = (SELECT usesysid FROM pg_user WHERE usename = '$USERNAME');" 2>/dev/null | xargs)
    for DB in $PG_DBS; do
      sudo -u postgres psql -c "DROP DATABASE IF EXISTS \"$DB\";"
    done
    sudo -u postgres psql -c "DROP USER IF EXISTS \"$USERNAME\";"
    echo "✅ PostgreSQL databases and user removed."
  else
    echo "ℹ️ PostgreSQL is not installed. Skipping."
  fi
fi

# --- Remove User and Home Directory ---
echo "👤 Deleting user '$USERNAME'..."
if sudo deluser --remove-home "$USERNAME"; then
  echo "✅ User '$USERNAME' deleted."
else
  echo "❌ Failed to delete user. Check for running processes or open sessions."
  exit 1
fi

# --- Remove User Group ---
echo "🔍 Checking users with '$USERNAME' as their primary group..."
GROUP_GID=$(getent group "$USERNAME" | cut -d: -f3 || true)

if [[ -z "$GROUP_GID" ]]; then
  echo "⚠️ Group '$USERNAME' does not exist. Skipping group reassignment and deletion."
else
  while IFS=: read -r username _ uid _ _ _ _; do
    [[ "$uid" -lt 1000 ]] && continue
    [[ "$(getent passwd "$username" | cut -d: -f7)" == "/usr/sbin/nologin" ]] && continue

    USER_GID=$(id -g "$username" 2>/dev/null || echo "")
    if [[ "$USER_GID" == "$GROUP_GID" ]]; then
      echo "⚠️ User '$username' has '$USERNAME' as primary group. Reassigning to 'users'..."
      sudo usermod -g users "$username"
    fi
  done < /etc/passwd

  if sudo groupdel "$USERNAME"; then
    echo "✅ Group '$USERNAME' successfully deleted."
  else
    echo "❌ Failed to delete group '$USERNAME'. Manual cleanup may be needed."
  fi
fi

# --- UFW Cleanup ---
read -p "Remove UFW rules for user '$USERNAME'? (Y/n): " REMOVE_UFW
if [[ "$REMOVE_UFW" =~ ^[Yy]$ ]]; then
  echo "🔍 Checking current UFW rules for user '$USERNAME'..."
  MATCHED=$(sudo ufw status numbered | grep "$USERNAME" || true)

  if [[ -z "$MATCHED" ]]; then
    echo "ℹ️ No UFW rules found for user '$USERNAME'."
  else
    RULE_NUMS=$(echo "$MATCHED" | awk '{print $1}' | tr -d '[]' | tac)
    for NUM in $RULE_NUMS; do
      sudo ufw delete "$NUM"
    done
    echo "✅ Removed UFW rules for user '$USERNAME'."
  fi
fi

echo ""
echo "🎯 Undeployment complete for '$USERNAME'. Server cleaned."
