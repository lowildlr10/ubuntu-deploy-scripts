#!/bin/bash

# deploy.sh — Deploys a new user with Laravel, Node, Nginx, DB, and SSL

set -e

install_nodejs() {
	local USERNAME="$1"
	local NODE_VERSION="${2:---lts}"

	echo "Installing Node.js and PM2..."
	sudo -u "$USERNAME" bash <<EOF
export HOME=/home/$USERNAME
export NVM_DIR="\$HOME/.nvm"
curl -o-  https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
[ -s "\$NVM_DIR/nvm.sh" ] && \. "\$NVM_DIR/nvm.sh"
nvm install $NODE_VERSION
npm install -g pm2
EOF
	echo "✅ Node.js and PM2 installed locally"
	echo ""
}

install_php_version() {
	local USERNAME="$1"
	local PHP_VERSION="$2"
	local USER_DIR="/home/$USERNAME"
	local USER_POOL_DIR="$USER_DIR/php/pool.d"
	local LOCAL_POOL_CONF="$USER_POOL_DIR/$USERNAME.conf"
	local SYSTEM_POOL_CONF="/etc/php/$PHP_VERSION/fpm/pool.d/$USERNAME.conf"
	local PHP_SOCK="/run/php/php$PHP_VERSION-$USERNAME.sock"
	local BASHRC_PATH="$USER_DIR/.bashrc"

	echo "📦 Installing PHP $PHP_VERSION and required libraries for '$USERNAME'..."

	sudo apt update
	sudo apt install -y \
		"php$PHP_VERSION-cli" \
		"php$PHP_VERSION-fpm" \
		"php$PHP_VERSION-curl" \
		"php$PHP_VERSION-mbstring" \
		"php$PHP_VERSION-xml" \
		"php$PHP_VERSION-gd" \
		"php$PHP_VERSION-zip" \
		"php$PHP_VERSION-mysql" \
		"php$PHP_VERSION-pgsql"

	echo "✅ PHP modules installed."

	echo "Creating PHP-FPM pool config in $LOCAL_POOL_CONF..."
	sudo mkdir -p "$USER_POOL_DIR"
	sudo cp "/etc/php/$PHP_VERSION/fpm/pool.d/www.conf" "$LOCAL_POOL_CONF"

	# Update pool name and user/group
	sudo sed -i "s/^\[www\]/\[$USERNAME\]/" "$LOCAL_POOL_CONF"
	sudo sed -i "s|^user = .*|user = $USERNAME|" "$LOCAL_POOL_CONF"
	sudo sed -i "s|^group = .*|group = $USERNAME|" "$LOCAL_POOL_CONF"
	sudo sed -i "s|^listen = .*|listen = $PHP_SOCK|" "$LOCAL_POOL_CONF"

	# Set custom PHP settings
	sudo tee -a "$LOCAL_POOL_CONF" > /dev/null <<EOF

; Custom PHP settings for user $USERNAME
php_admin_value[memory_limit] = 256M
php_admin_value[upload_max_filesize] = 256M
php_admin_value[post_max_size] = 256M
php_admin_value[max_execution_time] = 120
php_admin_value[max_input_time] = 120
php_admin_value[max_file_uploads] = 50
EOF

	echo "✅ Custom memory/upload limits added."

	# Symlink to system pool directory
	sudo ln -sf "$LOCAL_POOL_CONF" "$SYSTEM_POOL_CONF"
	echo "✅ PHP-FPM pool linked at $SYSTEM_POOL_CONF using config from user directory."

	# Restart PHP-FPM service
	sudo systemctl restart "php$PHP_VERSION-fpm"
	echo "PHP-FPM restarted for version $PHP_VERSION"

	# Optional bashrc enhancement
	if [ -f "$BASHRC_PATH" ]; then
		echo "🔧 Updating .bashrc for '$USERNAME' to use PHP $PHP_VERSION CLI..."

		# Remove any existing alias for php to avoid duplication
		sudo sed -i '/alias php=/d' "$BASHRC_PATH"

		# Add PHP version alias and helpful info
		{
			echo ""
			echo "# PHP CLI setup for version $PHP_VERSION"
			echo "alias php='/usr/bin/php$PHP_VERSION'"
			echo "alias php-fpm='/usr/sbin/php-fpm$PHP_VERSION'"
			echo "# PHP-FPM socket: $PHP_SOCK"
		} | sudo tee -a "$BASHRC_PATH" > /dev/null
		echo "✅ .bashrc updated for PHP $PHP_VERSION"
	fi

	echo "✅ PHP $PHP_VERSION configured and isolated for '$USERNAME'."
	echo ""
}

setup_default_directory() {
	# $1 = 1: Monolithic, 2: Microservices, 3: Backend
	# $2 = USERNAME
	
	# --- User Directories ---
	echo "Creating directories..."
	if [[ "$1" == "1" ]]; then
		mkdir -p /home/$2/{public_html,logs}
		sudo chown -R $2:www-data /home/$2/{public_html,logs}
		sudo find /home/$2/{public_html,logs} -type d -exec chmod 755 {} +
		sudo find /home/$2/{public_html,logs} -type f -exec chmod 644 {} +
	elif [[ "$1" == "2" ]]; then
		mkdir -p /home/$2/{public_app,public_api,logs}
		sudo chown -R $2:www-data /home/$2/{public_app,public_api,logs}
		sudo find /home/$2/{public_app,public_api,logs} -type d -exec chmod 755 {} +
		sudo find /home/$2/{public_app,public_api,logs} -type f -exec chmod 644 {} +
	elif [[ "$1" == "3" ]]; then
		mkdir -p /home/$2/{public_app,public_api,logs}
		sudo chown -R $2:www-data /home/$2/{public_api,logs}
		sudo find /home/$2/{public_api,logs} -type d -exec chmod 755 {} +
		sudo find /home/$2/{public_api,logs} -type f -exec chmod 644 {} +
	fi
	
	sudo chmod o+x /home
	sudo chmod o+x /home/$2

	echo "📂 Directories created."
	echo ""
}

setup_nginx_custom_commands() {
	# $1 = USERNAME
	local USERNAME="$1"
	local USER_HOME="/home/$USERNAME"
	local USER_NGINX_DIR="$USER_HOME/nginx/sites-available"
	local BASHRC="$USER_HOME/.bashrc"

	echo "🔧 Adding Nginx helper commands (ngxensite, ngxdissite) for $USERNAME..."

	sudo tee -a "$BASHRC" > /dev/null <<EOF

# --- Custom Nginx Commands for $USERNAME ---
alias ngxensite='function _ngxensite() { sudo ln -sf "$USER_NGINX_DIR/\$1" /etc/nginx/sites-enabled/\$1; }; _ngxensite'
alias ngxdissite='function _ngxdissite() { sudo rm -f /etc/nginx/sites-enabled/\$1; }; _ngxdissite'
alias ngxtest='sudo nginx -t'
alias ngxreload='sudo nginx -t && sudo systemctl reload nginx'
EOF

	sudo chown "$USERNAME:$USERNAME" "$BASHRC"
	echo "✅ Added Nginx command aliases to $USERNAME's .bashrc"
	echo ""
}

setup_nginx_config() {
	# $1 = IS_LARAVEL
	# $2 = USERNAME
	# $3 = PROJECT_STRUCTURE
	# $4 = PHP_VERSION
	# $5 = PORT
	# $6 = IS_FRONTEND (Optional)
	
	local IS_LARAVEL=$1
	local USERNAME=$2
	local PROJECT_STRUCTURE=$3
	local PHP_VERSION=${4:-8.4}
	local PORT=${5:-8080}
	local IS_FRONTEND=${6:-n}

	local PUBLIC_DIRECTORY="public_api"
	local LOG_NAME="${USERNAME}_api"
	local CONFIG_NAME="${USERNAME}_api.conf"
	
	if [[ "$PROJECT_STRUCTURE" == "1" ]]; then
		PUBLIC_DIRECTORY="public_html"
		CONFIG_NAME="${USERNAME}_html.conf"
		LOG_NAME="${USERNAME}_html"
	fi
	
	if [[ "$PROJECT_STRUCTURE" == "2" ]] && [[ "$IS_FRONTEND" =~ ^[Yy]$ ]]; then
		PUBLIC_DIRECTORY="public_app"
		CONFIG_NAME="${USERNAME}_app.conf"
		
		if [[ "$IS_FRONTEND" =~ ^[Yy]$ ]]; then
			LOG_NAME="${2}_app"
		else
			LOG_NAME="${2}_api"
		fi
	fi
	
	# Prepare user-specific nginx config directory
	local USER_NGINX_DIR="/home/$USERNAME/nginx/sites-available"
	local CONF="$USER_NGINX_DIR/$CONFIG_NAME"
	
	sudo mkdir -p "$USER_NGINX_DIR"
	sudo chown -R "$USERNAME:www-data" "/home/$USERNAME/nginx"
	
	# Create empty log files
	sudo touch "/home/$USERNAME/logs/${LOG_NAME}_access.log"
	sudo touch "/home/$USERNAME/logs/${LOG_NAME}_error.log"
	sudo chown $USERNAME:www-data "/home/$USERNAME/logs/${LOG_NAME}_access.log" "/home/$USERNAME/logs/${LOG_NAME}_error.log"
	
	if [[ "$IS_LARAVEL" =~ ^[Yy]$ ]]; then
		mkdir /home/$USERNAME/$PUBLIC_DIRECTORY/public
		echo "<html><body><h1>$USERNAME - $PUBLIC_DIRECTORY is ready!</h1></body></html>" | tee /home/$USERNAME/$PUBLIC_DIRECTORY/public/index.html > /dev/null
		sudo chown -R $USERNAME:www-data /home/$USERNAME/$PUBLIC_DIRECTORY/public
		
		sudo tee "$CONF" > /dev/null <<EOF
server {
    listen $PORT;
    listen [::]:$PORT;
    server_name _;
    root /home/$USERNAME/$PUBLIC_DIRECTORY/public;

    add_header X-Frame-Options "SAMEORIGIN";
    add_header X-Content-Type-Options "nosniff";

    index index.php index.html index.htm;

    charset utf-8;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location = /favicon.ico { access_log off; log_not_found off; }
    location = /robots.txt  { access_log off; log_not_found off; }

    error_page 404 /index.php;

    location ~ ^/index\.php(/|$) {
        fastcgi_pass unix:/run/php/php$PHP_VERSION-$USERNAME.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }

    access_log /home/$USERNAME/logs/${LOG_NAME}_access.log;
    error_log /home/$USERNAME/logs/${LOG_NAME}_error.log;
}
EOF
	else
		echo "<html><body><h1>$USERNAME - $PUBLIC_DIRECTORY is ready!</h1></body></html>" | tee /home/$USERNAME/$PUBLIC_DIRECTORY/index.html > /dev/null
		sudo chown $USERNAME:www-data /home/$USERNAME/$PUBLIC_DIRECTORY/index.html
	
		sudo tee "$CONF" > /dev/null <<EOF
server {
    listen $PORT;
    listen [::]:$PORT;
    server_name _;
    root /home/$USERNAME/$PUBLIC_DIRECTORY/public;

	index index.php index.html index.htm;

	location / {
		try_files $uri $uri/ /index.php$is_args$args;
	}

	location ~ \.php$ {
		fastcgi_pass unix:/run/php/php$PHP_VERSION-$USERNAME.sock;
		fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
		fastcgi_index index.php;
		include fastcgi.conf;
    }
	
	access_log /home/$USERNAME/logs/${LOG_NAME}_access.log;
    error_log /home/$USERNAME/logs/${LOG_NAME}_error.log;
}
EOF
	fi
	
	sudo chown -R "$USERNAME:www-data" "/home/$USERNAME/nginx"
	
	# Symlink to global sites-enabled so nginx picks it up
	sudo ln -sf "$CONF" "/etc/nginx/sites-enabled/$CONFIG_NAME"
	
	# Reload Nginx
	sudo nginx -t && sudo systemctl reload nginx
	echo "✅ Nginx configured for listen port $PORT"
	
	# --- UFW Firewall Rules ---
	echo "🛡️  Applying UFW firewall rules..."
	sudo ufw allow "$PORT" comment "Allow Nginx + PHP listen port for $USERNAME"
	echo "✅ UFW allowed listen port $PORT for Nginx + PHP"
	echo ""
}

setup_nodejs_config() {
	# $1 = USERNAME
	# $2 = PROJECT_STRUCTURE
	# $3 = NODE_LOCAL_PORT
	# $4 = PORT
	# $5 = IS_BACKEND (Optional)
	
	local USERNAME=$1
	local PROJECT_STRUCTURE=$2
	local NODE_LOCAL_PORT=${3:-3000}
	local PORT=${4:-80}
	local IS_BACKEND=${5:-n}

	local PUBLIC_DIRECTORY="public_app"
	local CONFIG_NAME="${USERNAME}_app.conf"
	local LOG_NAME="${USERNAME}_app"
	
	if [[ "$PROJECT_STRUCTURE" == "1" ]]; then
		PUBLIC_DIRECTORY="public_html"
		CONFIG_NAME="${USERNAME}_html.conf"
		LOG_NAME="${USERNAME}_html"
	fi
	
	if [[ "$PROJECT_STRUCTURE" == "3" ]] || ([[ "$PROJECT_STRUCTURE" == "2" ]] && [[ "$IS_BACKEND" =~ ^[Yy]$ ]]); then
		PUBLIC_DIRECTORY="public_api"
		CONFIG_NAME="${USERNAME}_api.conf"
		LOG_NAME="${USERNAME}_api"
	fi
	
	# --- Prepare user nginx config directory ---
	local USER_NGINX_DIR="/home/$USERNAME/nginx/sites-available"
	local CONF="$USER_NGINX_DIR/$CONFIG_NAME"
	
	sudo mkdir -p "$USER_NGINX_DIR"
	sudo chown -R "$USERNAME:www-data" "/home/$USERNAME/nginx"
	
	# Create log files
	sudo touch "/home/$USERNAME/logs/${LOG_NAME}_access.log"
	sudo touch "/home/$USERNAME/logs/${LOG_NAME}_error.log"
	sudo chown $USERNAME:www-data "/home/$USERNAME/logs/${LOG_NAME}_access.log" "/home/$USERNAME/logs/${LOG_NAME}_error.log"
	
	# --- Write Nginx reverse proxy config ---
	sudo tee "$CONF" > /dev/null <<EOF
server {
    listen $PORT;
    server_name _;

    location / {
        proxy_pass http://localhost:$NODE_LOCAL_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }

    access_log /home/$1/logs/${LOG_NAME}_access.log;
    error_log /home/$1/logs/${LOG_NAME}_error.log;
}
EOF
	
	# --- Enable site ---
	sudo ln -sf "$CONF" "/etc/nginx/sites-enabled/$CONFIG_NAME"
	sudo nginx -t && sudo systemctl reload nginx
	echo "✅ Nginx reverse proxy configured for Node.js listen port $PORT"
	
	# --- Deploy Node.js test 'app.js' ---
	echo "🚀 Deploying test app.js on port $NODE_LOCAL_PORT..."
	sudo -u "$USERNAME" bash <<EOF
export HOME=/home/$USERNAME
export NVM_DIR="\$HOME/.nvm"
[ -s "\$NVM_DIR/nvm.sh" ] && \. "\$NVM_DIR/nvm.sh"
[ -s "\$NVM_DIR/bash_completion" ] && \. "\$NVM_DIR/bash_completion"

mkdir -p /home/$USERNAME/$PUBLIC_DIRECTORY

cat > /home/$USERNAME/$PUBLIC_DIRECTORY/app.js <<'EOL'
const http = require('http');
const port = process.env.PORT || $NODE_LOCAL_PORT;

const server = http.createServer((req, res) => {
  res.statusCode = 200;
  res.setHeader('Content-Type', 'text/plain');
  res.end('$USERNAME - $PUBLIC_DIRECTORY is ready!');
});

server.listen(port, () => {
  console.log(\`Server running at http://localhost:\${port}/\`);
});
EOL

cd /home/$USERNAME/$PUBLIC_DIRECTORY
PORT=$NODE_LOCAL_PORT pm2 start app.js --name "${USERNAME}-app"
pm2 save
EOF

	sudo chown -R "$USERNAME:www-data" "/home/$USERNAME/nginx"

	sudo chown $USERNAME:www-data /home/$USERNAME/$PUBLIC_DIRECTORY/app.js
	echo "✅ Deployed test 'app.js' with PM2"

	# --- UFW Firewall Rules ---
	echo "🛡️  Applying UFW firewall rules..."
	sudo ufw allow "$PORT" comment "Allow Node.js listen port for $USERNAME"
	echo "✅ UFW allowed listen port $PORT for Node.js"
	echo ""
}

# --------------------------------------------------------------------------------

echo "🚀 Starting Deployment..."

# --- Create User ---
read -p "Enter new username: " USERNAME
USERNAME=$(echo "$USERNAME" | xargs)
sudo useradd -m -s /bin/bash -G sudo,www-data "$USERNAME"

if ! id "$USERNAME" &>/dev/null; then
	echo "❌ Failed to create user '$USERNAME'."
	exit 1
fi

USER_HOME="/home/$USERNAME"
SSH_DIR="$USER_HOME/.ssh"
PRIVATE_KEY_PATH="$SSH_DIR/${USERNAME}_id_rsa"
PUBLIC_KEY_PATH="$PRIVATE_KEY_PATH.pub"

# SSH Key Setup
echo "Generating SSH key pair for $USERNAME..."
sudo -u "$USERNAME" mkdir -p "$SSH_DIR"
sudo -u "$USERNAME" ssh-keygen -t rsa -b 4096 -f "$PRIVATE_KEY_PATH" -N "" > /dev/null

# Set correct permissions and ownership
sudo chown -R "$USERNAME:$USERNAME" "$SSH_DIR"
sudo chmod 700 "$SSH_DIR"
sudo chmod 600 "$PRIVATE_KEY_PATH" "$PUBLIC_KEY_PATH"

# Configure authorized_keys
cat "$PUBLIC_KEY_PATH" | sudo tee "$SSH_DIR/authorized_keys" > /dev/null
sudo chown "$USERNAME:$USERNAME" "$SSH_DIR/authorized_keys"
sudo chmod 600 "$SSH_DIR/authorized_keys"

# Set user password for local login
PASSWORD=$(openssl rand -base64 12)
echo "$USERNAME:$PASSWORD" | sudo chpasswd

# --- SSH Match Block Config ---
SSH_CONFIG_FILE="/etc/ssh/sshd_config.d/99-${USERNAME}.conf"

{
	echo "Match User $USERNAME"
	echo "    PasswordAuthentication no"
	echo "    AuthenticationMethods publickey"
} | sudo tee "$SSH_CONFIG_FILE" > /dev/null

# Ensure config permissions
sudo chmod 644 "$SSH_CONFIG_FILE"

# Restart SSH to apply changes
sudo systemctl restart ssh

# --- Validate SSH Config ---
echo "🔍 Verifying SSH daemon config for '$USERNAME'..."
if sudo sshd -T -C user="$USERNAME" 2>/dev/null | grep -q "passwordauthentication no"; then
	echo "✅ SSH Match block applied correctly for '$USERNAME'"
else
	echo "⚠️ SSH Match block may not be taking effect for '$USERNAME'"
fi

# Safely copy the private key file to the current user's home directory for easier access
read -p " Enter a username to copy '${USERNAME}_id_rsa' to (optional): " OTHER_USERNAME
OTHER_USERNAME=$(echo "$OTHER_USERNAME" | xargs)

# Empty input check
if [ -n "$OTHER_USERNAME" ]; then
	OTHER_USER_HOME="/home/$OTHER_USERNAME"
	sudo cp "$PRIVATE_KEY_PATH" "$OTHER_USER_HOME/${USERNAME}_id_rsa"
	sudo chown "$OTHER_USERNAME:$OTHER_USERNAME" "$OTHER_USER_HOME/${USERNAME}_id_rsa"
fi

echo ""
echo "✅ SSH key pair generated and configured for $USERNAME"
echo ""

# --- Project Structure ---
echo "🔧 Project Structure (0: None, 1: Monolithic, 2: Microservices, 3: Backend)"
read -p "Select Type: " PROJECT_STRUCTURE

NEED_NGINX="n"
NEED_NODE="n"
PORT="80"
NODE_LOCAL_PORT="3000"
PHP_VERSION="8.4"
NEED_FRONTEND_NGINX="n"
NEED_FRONTEND_NODE="n"
FRONTEND_PORT="80"
NODE_FRONTEND_LOCAL_PORT="3000"
FRONTEND_PHP_VERSION="8.4"
NEED_BACKEND_NGINX="n"
NEED_BACKEND_NODE="n"
BACKEND_PORT="8080"
NODE_BACKEND_LOCAL_PORT="8080"
BACKEND_PHP_VERSION="8.4"

if [[ "$PROJECT_STRUCTURE" == "1" ]]; then
	echo "🔧 Server (0: Nginx + PHP, 1: Node.js)"
	read -p "Select a server (default 0): " SERVER
	SERVER=${SERVER:-0}
	
	setup_default_directory "$PROJECT_STRUCTURE" "$USERNAME"
	
	if [[ "$SERVER" == "1" ]]; then
		NEED_NODE="Y"
		
		read -p "Select NodeJS Version (default --lts): " NODE_VERSION
		NODE_VERSION=${NODE_VERSION:---lts}
		install_nodejs "$USERNAME" "$NODE_VERSION"
		
		read -p "Local port for Node.js app (default 3000): " NODE_LOCAL_PORT
		NODE_LOCAL_PORT=${NODE_LOCAL_PORT:-3000}

	    read -p "Public port for Node.js app (default 80): " PORT
	    PORT=${PORT:-80}
		
		setup_nodejs_config "$USERNAME" "$PROJECT_STRUCTURE" "$NODE_LOCAL_PORT" "$PORT"
	else
		NEED_NGINX="Y"
		
		read -p "Setup as Laravel App? (Y/n): " IS_LARAVEL
		IS_LARAVEL=${IS_LARAVEL:-n}
		
		read -p "Enter PHP-FPM version (default: 8.4): " PHP_VERSION
		PHP_VERSION=${PHP_VERSION:-8.4}

		read -p "Enter listen port (default: 80): " PORT
		PORT=${PORT:-80}

		install_php_version "$USERNAME" "$PHP_VERSION"
		setup_nginx_config "$IS_LARAVEL" "$USERNAME" "$PROJECT_STRUCTURE" "$PHP_VERSION" "$PORT"
	fi
elif [[ "$PROJECT_STRUCTURE" == "2" ]]; then
	echo "🔧 Frontend Server (0: Nginx + PHP, 1: Node.js)"
	read -p "Select a frontend server (default 1): " FRONTEND_SERVER
	FRONTEND_SERVER=${FRONTEND_SERVER:-1}
	
	echo "🔧 Backend Server (0: Nginx + PHP, 1: Node.js)"
	read -p "Select a backend server (default 0): " BACKEND_SERVER
	BACKEND_SERVER=${BACKEND_SERVER:-0}
	
	setup_default_directory "$PROJECT_STRUCTURE" "$USERNAME"
	
	if [[ "$FRONTEND_SERVER" == "1" ]] || [[ "$BACKEND_SERVER" == "1" ]]; then
		read -p "Select NodeJS Version (default --lts): " NODE_VERSION
		NODE_VERSION=${NODE_VERSION:---lts}
		install_nodejs "$USERNAME" "$NODE_VERSION"
	fi
	
	if [[ "$FRONTEND_SERVER" == "1" ]]; then
		NEED_FRONTEND_NODE="Y"
		
		read -p "Local port for frontend Node.js app (default 3000): " NODE_FRONTEND_LOCAL_PORT
		NODE_FRONTEND_LOCAL_PORT=${NODE_FRONTEND_LOCAL_PORT:-3000}

	    read -p "Public port for frontend Node.js app (default 80): " FRONTEND_PORT
	    FRONTEND_PORT=${FRONTEND_PORT:-80}
		
		setup_nodejs_config "$USERNAME" "$PROJECT_STRUCTURE" "$NODE_FRONTEND_LOCAL_PORT" "$FRONTEND_PORT"
	else
		NEED_FRONTEND_NGINX="Y"
		
		read -p "Setup as Frontend Laravel App? (Y/n): " IS_LARAVEL
		IS_LARAVEL=${IS_LARAVEL:-n}
		
		read -p "Enter PHP-FPM version (default: 8.4): " FRONTEND_PHP_VERSION
		FRONTEND_PHP_VERSION=${FRONTEND_PHP_VERSION:-8.4}

		read -p "Enter listen port (default: 80): " FRONTEND_PORT
		FRONTEND_PORT=${FRONTEND_PORT:-80}

		install_php_version "$USERNAME" "$FRONTEND_PHP_VERSION"
		setup_nginx_config "$IS_LARAVEL" "$USERNAME" "$PROJECT_STRUCTURE" "FRONTEND_PHP_VERSION" "$FRONTEND_PORT" "Y"
	fi
	
	if [[ "$BACKEND_SERVER" == "1" ]]; then
		NEED_BACKEND_NODE="Y"
		
		read -p "Local port for backend Node.js api (default 3000): " NODE_BACKEND_LOCAL_PORT
		NODE_BACKEND_LOCAL_PORT=${NODE_BACKEND_LOCAL_PORT:-3000}

	    read -p "Public port for backend Node.js api (default 80): " BACKEND_PORT
	    BACKEND_PORT=${BACKEND_PORT:-80}
		
		setup_nodejs_config "$USERNAME" "$PROJECT_STRUCTURE" "$NODE_BACKEND_LOCAL_PORT" "$BACKEND_PORT" "Y"
	else
		NEED_BACKEND_NGINX="Y"
		
		read -p "Setup as Backend Laravel App? (Y/n): " IS_LARAVEL
		IS_LARAVEL=${IS_LARAVEL:-n}
		
		read -p "Enter PHP-FPM version (default: 8.4): " BACKEND_PHP_VERSION
		BACKEND_PHP_VERSION=${BACKEND_PHP_VERSION:-8.4}

		read -p "Enter listen port (default: 8080): " BACKEND_PORT
		BACKEND_PORT=${BACKEND_PORT:-8080}

		install_php_version "$USERNAME" "$BACKEND_PHP_VERSION"
		setup_nginx_config "$IS_LARAVEL" "$USERNAME" "$PROJECT_STRUCTURE" "$BACKEND_PHP_VERSION" "$BACKEND_PORT"
	fi
elif [[ "$PROJECT_STRUCTURE" == "3" ]]; then
	echo "🔧 Backend Server (0: Nginx + PHP, 1: Node.js)"
	read -p "Select a backend server (default 0): " BACKEND_SERVER
	BACKEND_SERVER=${BACKEND_SERVER:-0}
	
	setup_default_directory "$PROJECT_STRUCTURE" "$USERNAME"
	
	if [[ "$BACKEND_SERVER" == "1" ]]; then
		NEED_BACKEND_NODE="Y"
		
		read -p "Select NodeJS Version (default --lts): " NODE_VERSION
		NODE_VERSION=${NODE_VERSION:---lts}
		install_nodejs "$USERNAME" "$NODE_VERSION"
		
		read -p "Local port for backend Node.js api (default 3000): " NODE_BACKEND_LOCAL_PORT
		NODE_BACKEND_LOCAL_PORT=${NODE_BACKEND_LOCAL_PORT:-3000}

	    read -p "Public port for backend Node.js api (default 8080): " BACKEND_PORT
	    BACKEND_PORT=${BACKEND_PORT:-8080}
		
		setup_nodejs_config "$USERNAME" "$PROJECT_STRUCTURE" "$NODE_BACKEND_LOCAL_PORT" "$BACKEND_PORT" "Y"
	else
		NEED_BACKEND_NGINX="Y"
		
		read -p "Setup as Backend Laravel App? (Y/n): " IS_LARAVEL
		IS_LARAVEL=${IS_LARAVEL:-n}
		
		read -p "Enter PHP-FPM version (default: 8.4): " BACKEND_PHP_VERSION
		BACKEND_PHP_VERSION=${BACKEND_PHP_VERSION:-8.4}

		read -p "Enter listen port (default: 8080): " BACKEND_PORT
		BACKEND_PORT=${BACKEND_PORT:-8080}

		install_php_version "$USERNAME" "$BACKEND_PHP_VERSION"
		setup_nginx_config "$IS_LARAVEL" "$USERNAME" "$PROJECT_STRUCTURE" "$BACKEND_PHP_VERSION" "$BACKEND_PORT"
	fi
else
	# --- Summary ---
	echo ""
	echo "------------------------------------------------------------------------"
	echo "🎉 Deployment Summary:"
	echo "------------------------------------------------------------------------"

	echo "👤 Username: $USERNAME"
	echo "🔑 Password (for local login): $PASSWORD"
	echo "⚠️ Store this password securely for terminal/console login."
	echo ""
	echo "✅ Login using: ssh -i ${USERNAME}_id_rsa $USERNAME@<server-ip>"
	echo ""
	echo "🔑 Private Key: $PRIVATE_KEY_PATH"
	sudo cat "$PRIVATE_KEY_PATH"
	echo ""
	echo "📌 Add this key to your SSH agent or use it to connect via:"
	echo "    ssh -i $PRIVATE_KEY_PATH $USERNAME@<your-server-ip>"

	echo "------------------------------------------------------------------------"
	echo ""
	exit 1
fi

if [[ "$NEED_NGINX" =~ ^[Yy]$ ]] || [[ "$NEED_FRONTEND_NGINX" =~ ^[Yy]$ ]] || [[ "$NEED_BACKEND_NGINX" =~ ^[Yy]$ ]]; then
	setup_nginx_custom_commands "$USERNAME"
fi

# --- Database Setup ---
echo "🔧 Database Setup (0: None, 1: MySQL, 2: PostgreSQL)"
read -p "Enter your choice: " DB_CHOICE
if [[ "$DB_CHOICE" == "1" ]]; then
	read -p "Enter DB name: " DB_NAME
	DB_PASS=$(openssl rand -base64 12)
	sudo mysql -e "CREATE DATABASE $DB_NAME; CREATE USER '$USERNAME'@'localhost' IDENTIFIED BY '$DB_PASS'; GRANT ALL PRIVILEGES ON $DB_NAME.* TO '$USERNAME'@'localhost'; FLUSH PRIVILEGES;"
	echo "✅ Databse '$DB_NAME' successfully created"
elif [[ "$DB_CHOICE" == "2" ]]; then
	read -p "Enter DB name: " DB_NAME
	DB_PASS=$(openssl rand -base64 12)
	sudo -u postgres psql -c "CREATE USER $USERNAME WITH PASSWORD '$DB_PASS';"
	sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $USERNAME;"
	echo ""
fi

# --- Composer (Local) ---
read -p "Do you need Composer? (Y/n): " NEED_COMPOSER
if [[ "$NEED_COMPOSER" =~ ^[Yy]$ ]]; then
  sudo -u "$USERNAME" bash <<EOF
cd /home/$USERNAME
curl -sS https://getcomposer.org/installer | php
mv composer.phar composer
chmod +x composer
echo 'export PATH=\$HOME:\$PATH' >> ~/.bashrc
EOF
  echo "✅ Composer installed locally at /home/$USERNAME/composer and PATH updated"
  echo ""
fi

# --- SSL (Optional) ---
read -p "Apply SSL via Let's Encrypt? (Y/n): " NEED_SSL
if [[ "$NEED_SSL" =~ ^[Yy]$ ]]; then
  sudo apt install -y certbot python3-certbot-nginx
  read -p "Enter domain(s) (comma-separated): " DOMAINS
  IFS=',' read -ra DOMAIN_LIST <<< "$DOMAINS"
  for DOMAIN in "${DOMAIN_LIST[@]}"; do
    sudo certbot --nginx -d "$DOMAIN" --register-unsafely-without-email --agree-tos
  done
  echo "✅ SSL certificates applied."
  echo ""
fi

# --- Summary ---
echo "------------------------------------------------------------------------"
echo "🎉 Deployment Summary:"
echo "------------------------------------------------------------------------"

echo "👤 Username: $USERNAME"
echo "🔑 Password (for local login): $PASSWORD"
echo "⚠️ Store this password securely for terminal/console login."
echo ""
echo "✅ Login using: ssh -i ${USERNAME}_id_rsa $USERNAME@<server-ip>"
echo ""
echo "🔑 Private Key: $PRIVATE_KEY_PATH"
sudo cat "$PRIVATE_KEY_PATH"
echo ""
echo "📌 Add this key to your SSH agent or use it to connect via:"
echo "    ssh -i $PRIVATE_KEY_PATH $USERNAME@<your-server-ip>"

echo "------------------------------------------------------------------------"

if [[ "$DB_CHOICE" == "1" || "$DB_CHOICE" == "2" ]]; then
  echo "📚 DB: $DB_NAME, Password: $DB_PASS"
else
  echo "📚 DB: N/A"
fi

if [[ "$PROJECT_STRUCTURE" == "1" ]]; then
	if [[ "$NEED_NODE" =~ ^[Yy]$ ]]; then
		echo "📦 Node.js Local Port: ${NODE_LOCAL_PORT:-3000}"
		echo "🌍 App Public Port: ${PORT:-80}"
	fi

	if [[ "$NEED_NGINX" =~ ^[Yy]$ ]]; then
		echo "🌐 App Port: ${PORT:-8080}"
	fi
elif [[ "$PROJECT_STRUCTURE" == "2" ]]; then
	if [[ "$NEED_FRONTEND_NODE" =~ ^[Yy]$ ]]; then
		echo "📦 Node.js Frontend Local Port: ${NODE_FRONTEND_LOCAL_PORT:-3000}"
		echo "🌍 Frontend Public Port: ${FRONTEND_PORT:-80}"
	fi

	if [[ "$NEED_FRONTEND_NGINX" =~ ^[Yy]$ ]]; then
		echo "🌐 Backend API Port: ${FRONTEND_PORT:-8080}"
	fi
	
	if [[ "$NEED_BACKEND_NODE" =~ ^[Yy]$ ]]; then
		echo "📦 Node.js Backend Local Port: ${NODE_BACKEND_LOCAL_PORT:-3000}"
		echo "🌍 Backend Public Port: ${BACKEND_PORT:-80}"
	fi

	if [[ "$NEED_BACKEND_NGINX" =~ ^[Yy]$ ]]; then
		echo "🌐 Backend API Port: ${BACKEND_PORT:-8080}"
	fi
elif [[ "$PROJECT_STRUCTURE" == "3" ]]; then
	if [[ "$NEED_BACKEND_NODE" =~ ^[Yy]$ ]]; then
		echo "📦 Node.js Backend Local Port: ${NODE_BACKEND_LOCAL_PORT:-3000}"
		echo "🌍 Backend Public Port: ${BACKEND_PORT:-80}"
	fi

	if [[ "$NEED_BACKEND_NGINX" =~ ^[Yy]$ ]]; then
		echo "🌐 Backend API Port: ${BACKEND_PORT:-8080}"
	fi
fi

echo "------------------------------------------------------------------------"

if [[ "$PROJECT_STRUCTURE" == "1" ]]; then
	echo "🌐 Access your App at: http://<server-ip>:${PORT:-80}/"
elif [[ "$PROJECT_STRUCTURE" == "2" ]]; then
	echo "🌐 Access your frontend app at: http://<server-ip>:${FRONTEND_PORT:-80}/"
	echo "🌐 Access your backend API at: http://<server-ip>:${BACKEND_PORT:-8080}/"
elif [[ "$PROJECT_STRUCTURE" == "3" ]]; then
	echo "🌐 Access your backend API at: http://<server-ip>:${BACKEND_PORT:-8080}/"
fi

echo "------------------------------------------------------------------------"