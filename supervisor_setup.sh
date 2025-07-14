#!/bin/bash

# supervisor_setup.sh — Setup a supervisor for Laravel queue worker

set -e

setup_supervisor() {
	local USERNAME=$1
	local PUBLIC_DIRECTORY=${2:-public_api}
	local USER_HOME="/home/$USERNAME"
	local APP_DIR="$USER_HOME/$PUBLIC_DIRECTORY"
	local SUPERVISOR_DIR="$USER_HOME/supervisor"
	local LOG_DIR="$USER_HOME/logs"
	local BASHRC="$USER_HOME/.bashrc"
	local WRAPPER_SCRIPT="$USER_HOME/run_queue.sh"

	echo "📦 Setting up Supervisor for Laravel Queue..."
	sudo apt install -y supervisor

	mkdir -p "$SUPERVISOR_DIR" "$LOG_DIR"
	
	echo "Validating Laravel setup in $APP_DIR..."
	if [[ ! -f "$APP_DIR/artisan" ]]; then
		echo "❌ Missing artisan at $APP_DIR/artisan. Make sure the Laravel app is deployed."
		exit 1
	fi
	
	# Detect PHP binary from user's interactive shell (respect alias)
	PHP_BIN=$(sudo -u "$USERNAME" bash -i -c 'type -P php')

	if [[ -z "$PHP_BIN" || ! -x "$PHP_BIN" ]]; then
		echo "❌ PHP binary not found or not executable: $PHP_BIN"
		exit 1
	fi
	
	echo "✅ Found PHP: $PHP_BIN"
	echo "✅ Found Artisan: $APP_DIR/artisan"
	
	echo "Testing artisan queue worker..."
	sudo -u "$USERNAME" bash -c "cd $APP_DIR && $PHP_BIN artisan queue:work --once" || {
		echo "❌ Laravel queue worker test failed. Fix Laravel errors before proceeding."
		exit 1
	}
	
	# Create wrapper shell script
	echo "Creating Laravel queue wrapper script..."
	cat > "$WRAPPER_SCRIPT" <<EOF
#!/bin/bash
cd "$APP_DIR"
source "$BASHRC"
$PHP_BIN artisan queue:work --sleep=3 --tries=3 --timeout=90
EOF

	chmod +x "$WRAPPER_SCRIPT"
	chown "$USERNAME:$USERNAME" "$WRAPPER_SCRIPT"

	# Write Supervisor config
	echo "Writing Supervisor config..."
	cat > "$SUPERVISOR_DIR/queue.conf" <<EOF
[program:${USERNAME}_queue]
command=$WRAPPER_SCRIPT
directory=$APP_DIR
autostart=true
autorestart=true
user=$USERNAME
redirect_stderr=true
stdout_logfile=$LOG_DIR/queue_worker.log
stderr_logfile=$LOG_DIR/queue_worker_error.log
stopasgroup=true
killasgroup=true
EOF

	echo "Linking and starting Supervisor config..."
	sudo ln -sf "$SUPERVISOR_DIR/queue.conf" "/etc/supervisor/conf.d/${USERNAME}_queue.conf"
	sudo supervisorctl reread
	sudo supervisorctl update
	sudo supervisorctl start "${USERNAME}_queue"

	echo "✅ Supervisor queue worker started for $USERNAME"
	echo "🗂️ Config: $SUPERVISOR_DIR/queue.conf"
	echo "📄 Logs: $LOG_DIR/queue_worker.log, $LOG_DIR/queue_worker_error.log"

	echo "Adding bash helper commands..."
	cat >> "$BASHRC" <<'EOF'

# === Laravel Queue Supervisor Helpers ===

add-queue() {
  local queue_name="${1:-default}"
  local user="$(whoami)"
  local app_dir="/home/$user/public_api"
  local conf_dir="/home/$user/supervisor"
  local log_dir="/home/$user/logs"
  local wrapper_script="/home/$user/run_queue_${queue_name}.sh"
  local php_bin=$(bash -i -c 'type -P php')
  local conf_file="$conf_dir/${queue_name}.conf"

  mkdir -p "$conf_dir" "$log_dir"

  cat > "$wrapper_script" <<EOL
#!/bin/bash
cd "$app_dir"
source "/home/$user/.bashrc"
$php_bin artisan queue:work --queue=${queue_name} --sleep=3 --tries=3 --timeout=90
EOL

  chmod +x "$wrapper_script"

  cat > "$conf_file" <<EOL
[program:${user}_queue_${queue_name}]
command=$wrapper_script
directory=$app_dir
autostart=true
autorestart=true
user=$user
redirect_stderr=true
stdout_logfile=$log_dir/queue_${queue_name}.log
stderr_logfile=$log_dir/queue_${queue_name}_error.log
stopasgroup=true
killasgroup=true
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
  sudo rm -f /home/$user/logs/queue_${queue_name}_error.log
  sudo rm -f /home/$user/run_queue_${queue_name}.sh
  sudo supervisorctl reread
  sudo supervisorctl update
  echo "✅ Queue '${queue_name}' removed."
}

restart-queue() {
  local queue_name="${1:-default}"
  local user="$(whoami)"
  sudo supervisorctl restart ${user}_queue_${queue_name}
}
EOF

	sudo chown "$USERNAME:$USERNAME" "$BASHRC"
	echo "✅ Added bash helpers: add-queue, remove-queue, restart-queue"
}

# --------------------------------------------------------------------------------

echo "🚀 Starting Supervisor Setup..."

# --- Inital Information ---
read -p "👤 Enter username: " USERNAME
USERNAME=$(echo "$USERNAME" | xargs)

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