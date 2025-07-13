#!/bin/bash

# undeploy.sh – Safely remove a user's full deployment: Nginx, DBs, SSL, Supervisor, user account, group

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

# --- Remove Nginx Configs ---
echo "🧹 Removing Nginx configs..."
sudo rm -f "/etc/nginx/sites-enabled/${USERNAME}_api.conf"
sudo rm -f "/etc/nginx/sites-available/${USERNAME}_api.conf"
sudo rm -f "/etc/nginx/sites-enabled/${USERNAME}_node.conf"
sudo rm -f "/etc/nginx/sites-available/${USERNAME}_node.conf"

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
  sudo rm -f "/etc/supervisor/conf.d/${USERNAME}_queue.conf"
  sudo supervisorctl reread
  sudo supervisorctl update
  sudo supervisorctl stop "${USERNAME}_queue" || true
  echo "✅ Supervisor config removed."
else
  echo "ℹ️ Supervisor is not installed. Skipping."
fi

# --- Remove Databases ---
read -p "Remove MySQL/PostgreSQL databases? (Y/n): " REMOVE_DB
if [[ "$REMOVE_DB" =~ ^[Yy]$ ]]; then
  # MySQL
  if command -v mysql >/dev/null 2>&1; then
    echo "🔎 Checking for MySQL databases..."
    if MYSQL_DBS=$(sudo mysql -sN -e "SHOW DATABASES;" 2>/dev/null | grep -i "^${USERNAME}" || true); then
      for DB in $MYSQL_DBS; do
        sudo mysql -e "DROP DATABASE IF EXISTS \`$DB\`;"
      done
      sudo mysql -e "DROP USER IF EXISTS '$USERNAME'@'localhost';"
      echo "✅ MySQL databases and user removed."
    else
      echo "⚠️ No MySQL databases found or query failed."
    fi
  else
    echo "ℹ️ MySQL is not installed. Skipping."
  fi

  # PostgreSQL
  if command -v psql >/dev/null 2>&1; then
    echo "🔎 Checking for PostgreSQL databases..."
    if PG_DBS=$(sudo -u postgres psql -t -c "SELECT datname FROM pg_database WHERE datdba = (SELECT usesysid FROM pg_user WHERE usename = '$USERNAME');" 2>/dev/null | xargs); then
      for DB in $PG_DBS; do
        sudo -u postgres psql -c "DROP DATABASE IF EXISTS \"$DB\";"
      done
      sudo -u postgres psql -c "DROP USER IF EXISTS \"$USERNAME\";"
      echo "✅ PostgreSQL databases and user removed."
    else
      echo "⚠️ No PostgreSQL databases found or query failed."
    fi
  else
    echo "ℹ️ PostgreSQL is not installed. Skipping."
  fi
fi

# --- Remove User and Home Directory ---
echo "🧹 Removing system user and home directory..."
if id "$USERNAME" &>/dev/null; then
  sudo pkill -u "$USERNAME" || true
  sudo deluser "$USERNAME" || echo "⚠️ Could not remove user (may already be removed)"
else
  echo "ℹ️ User '$USERNAME' not found, skipping user deletion."
fi

if [[ -d "$USER_HOME" ]]; then
  sudo rm -rf "$USER_HOME"
  echo "✅ Home directory '$USER_HOME' deleted."
else
  echo "ℹ️ No home directory found."
fi

# --- Remove User Group ---
if getent group "$USERNAME" > /dev/null; then
  sudo groupdel "$USERNAME"
  echo "✅ Group '$USERNAME' deleted."
else
  echo "ℹ️ Group '$USERNAME' not found."
fi

# --- UFW Cleanup ---
read -p "Remove UFW rules for user '$USERNAME'? (Y/n): " REMOVE_UFW
if [[ "$REMOVE_UFW" =~ ^[Yy]$ ]]; then
  echo "🔍 Checking current UFW rules for user '$USERNAME'..."

  # Match rules by comment
  MATCHED=$(sudo ufw status numbered | grep "$USERNAME")

  if [ -z "$MATCHED" ]; then
    echo "ℹ️ No UFW rules found for user '$USERNAME'."
  else
    # Extract rule numbers and delete in reverse order
    RULE_NUMS=$(echo "$MATCHED" | awk '{print $1}' | tr -d '[]' | tac)
    for NUM in $RULE_NUMS; do
      sudo ufw delete "$NUM"
    done
    echo "✅ Removed UFW rules for user '$USERNAME'."
  fi
fi

echo ""
echo "🎯 Undeployment complete for '$USERNAME'. Server cleaned."
