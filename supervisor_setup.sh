#!/bin/bash

# supervisor_setup.sh — Setup a supervisor for Laravel queue worker

set -e

setup_supervisor() {
	# $1 = USERNAME
	# $2 = PUBLIC_DIRECTORY
	
	local USERNAME=$1
	local PUBLIC_DIRECTORY=${2:-public_api}

	
	read -p "Enable Supervisor for Laravel queue worker? (Y/n): " ENABLE_SUPERVISOR

	# Normalize input and check
	ENABLE_SUPERVISOR=$(echo "$ENABLE_SUPERVISOR" | tr -d '\r' | xargs)

	if [ "$ENABLE_SUPERVISOR" = "Y" ] || [ "$ENABLE_SUPERVISOR" = "y" ]; then
		echo "📦 Setting up Supervisor for Laravel Queue..."

		sudo apt install -y supervisor

		local USER_HOME="/home/$USERNAME"
		local SUPERVISOR_DIR="$USER_HOME/supervisor"
		local LOG_DIR="$USER_HOME/logs"
		local BASHRC="$USER_HOME/.bashrc"

		mkdir -p "$SUPERVISOR_DIR" "$LOG_DIR"

		# Write main supervisor queue config
		cat > "$SUPERVISOR_DIR/queue.conf" <<EOF
[program:${USERNAME}_queue]
process_name=%(program_name)s_%(process_num)02d
command=/usr/bin/php $USER_HOME/$PUBLIC_DIRECTORY/artisan queue:work --sleep=3 --tries=3 --timeout=90
directory=$USER_HOME/$PUBLIC_DIRECTORY
autostart=true
autorestart=true
user=$USERNAME
redirect_stderr=true
stdout_logfile=$LOG_DIR/queue_worker.log
stopasgroup=true
killasgroup=true
numprocs=20
EOF

		# Symlink and activate
		sudo ln -sf "$SUPERVISOR_DIR/queue.conf" "/etc/supervisor/conf.d/${USERNAME}_queue.conf"
		sudo supervisorctl reread
		sudo supervisorctl update
		sudo supervisorctl start "${USERNAME}_queue"

		echo "✅ Supervisor queue worker started for $USERNAME"
		echo "🗂️  Config: $SUPERVISOR_DIR/queue.conf"
		echo "📄 Log: $LOG_DIR/queue_worker.log"

		# Bash helpers
		echo "🧩 Adding bash queue helper commands..."
		cat >> "$BASHRC" <<'EOF'

# === Laravel Queue Supervisor Helpers ===

add-queue() {
  local queue_name="${1:-default}"
  local user="$(whoami)"
  local app_dir="/home/$user/$PUBLIC_DIRECTORY"
  local conf_dir="/home/$user/supervisor"
  local log_dir="/home/$user/logs"
  local conf_file="$conf_dir/${queue_name}.conf"

  mkdir -p "$conf_dir" "$log_dir"

  cat > "$conf_file" <<EOL
[program:${user}_queue_${queue_name}]
process_name=%(program_name)s_%(process_num)02d
command=/usr/bin/php $app_dir/artisan queue:work --queue=${queue_name} --sleep=3 --tries=3 --timeout=90
directory=$app_dir
autostart=true
autorestart=true
user=$user
redirect_stderr=true
stdout_logfile=$log_dir/queue_${queue_name}.log
stopasgroup=true
killasgroup=true
numprocs=20
EOL

  sudo ln -sf "$conf_file" /etc/supervisor/conf.d/${user}_queue_${queue_name}.conf
  sudo supervisorctl reread
  sudo supervisorctl update
  sudo supervisorctl start ${user}_queue_${queue_name}
  echo "✅ Queue '${queue_name}' added and started."
}

remove-queue() {
  local queue_name="${1:-default}"
  local user="$(whoami)"
  sudo supervisorctl stop ${user}_queue_${queue_name}
  sudo rm -f /etc/supervisor/conf.d/${user}_queue_${queue_name}.conf
  sudo rm -f /home/$user/supervisor/${queue_name}.conf
  sudo rm -f /home/$user/logs/queue_${queue_name}.log
  sudo supervisorctl reread
  sudo supervisorctl update
  echo "🗑️  Queue '${queue_name}' removed."
}

restart-queue() {
  local queue_name="${1:-default}"
  local user="$(whoami)"
  sudo supervisorctl restart ${user}_queue_${queue_name}
}
EOF

		sudo chown "$USERNAME:$USERNAME" "$BASHRC"
		echo "✅ Added bash helpers: add-queue, remove-queue, restart-queue"
		echo ""
	else
		echo "❌ Supervisor setup skipped."
	exit 0
fi

}

# --------------------------------------------------------------------------------

echo "🚀 Starting Supervisor Setup..."

# --- Inital Information ---
read -p "👤 Enter username: " USERNAME
USERNAME=$(echo "$USERNAME" | xargs)  # Trim spaces

# Empty input check
if [ -z "$USERNAME" ]; then
  echo "⚠️ Username can't be empty. Please try again."
  exit 1
fi

echo "🔍 Verifying username: '$USERNAME'"

# Show debug output
if id "$USERNAME"; then
  echo "✅ User '$USERNAME' exists."
else
  echo "❌ User '$USERNAME' doesn't exist. Here's a list of existing users:"
  cut -d: -f1 /etc/passwd | column
fi

read -p "Enter app path (default 'public_api'): " PUBLIC_DIRECTORY
PUBLIC_DIRECTORY=${PUBLIC_DIRECTORY:-public_api}
setup_supervisor "$USERNAME" "$PUBLIC_DIRECTORY"