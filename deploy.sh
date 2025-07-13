#!/bin/bash

# deploy.sh — Deploys a new user with Laravel, Node, Nginx, DB, and SSL

set -e

install_nodejs() {
	echo "Installing Node.js and PM2..."
	sudo -u "$1" bash <<EOF
export HOME=/home/$1
export NVM_DIR="\$HOME/.nvm"
curl -o-  https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.3/install.sh | bash
[ -s "\$NVM_DIR/nvm.sh" ] && \. "\$NVM_DIR/nvm.sh"
nvm install --lts
npm install -g pm2
EOF
	echo "✅ Node.js and PM2 installed locally"
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

setup_nginx_config() {
	# $1 = IS_LARAVEL
	# $2 = USERNAME
	# $3 = PROJECT_STRUCTURE
	# $4 = PHP_VERSION
	# $5 = PORT
	# $6 = IS_FRONTEND (Optional)
	
	PUBLIC_DIRECTORY="public_api"
	CONFIG_NAME="${2}_api.conf"
	PHP_VERSION=${4:-8.4}
	PORT=${5:-8080}
	IS_FRONTEND=${6:-n}
	
	if [[ "$3" == "1" ]]; then
		PUBLIC_DIRECTORY="public_html"
		CONFIG_NAME="${2}_html.conf"
	fi
	
	if [[ "$3" == "2" ]] && [[ "$IS_FRONTEND" =~ ^[Yy]$ ]]; then
		PUBLIC_DIRECTORY="public_app"
		CONFIG_NAME="${2}_app.conf"
	fi

	CONF="/etc/nginx/sites-available/${CONFIG_NAME}"
	
	if [[ "$IS_LARAVEL" =~ ^[Yy]$ ]]; then
		mkdir /home/$2/$PUBLIC_DIRECTORY/public
		echo "<html><body><h1>$2 - $PUBLIC_DIRECTORY is ready!</h1></body></html>" | tee /home/$2/$PUBLIC_DIRECTORY/public/index.html > /dev/null
		sudo chown -R $2:www-data /home/$2/$PUBLIC_DIRECTORY/public
		
		sudo tee "$CONF" > /dev/null <<EOF
server {
    listen $PORT;
    listen [::]:$PORT;
    server_name _;
    root /home/$2/$PUBLIC_DIRECTORY/public;

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
        fastcgi_pass unix:/var/run/php/php$PHP_VERSION-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;
    }

    location ~ /\.(?!well-known).* {
        deny all;
    }

    access_log /home/$2/logs/${PUBLIC_DIRECTORY}_access.log;
    error_log /home/$2/logs/${PUBLIC_DIRECTORY}_error.log;
}
EOF
	else
		echo "<html><body><h1>$2 - $PUBLIC_DIRECTORY is ready!</h1></body></html>" | tee /home/$2/$PUBLIC_DIRECTORY/index.html > /dev/null
		sudo chown $2:www-data /home/$2/$PUBLIC_DIRECTORY/index.html
	
		sudo tee "$CONF" > /dev/null <<EOF
server {
    listen $PORT;
    listen [::]:$PORT;
    server_name _;
    root /home/$2/$PUBLIC_DIRECTORY/public;

	index index.php index.html index.htm;

	location / {
		try_files $uri $uri/ /index.php$is_args$args;
	}

	location ~ \.php$ {
		fastcgi_pass unix:/var/run/php/php$PHP_VERSION-fpm.sock;
		fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
		fastcgi_index index.php;
		include fastcgi.conf;
    }
	
	access_log /home/$2/logs/${PUBLIC_DIRECTORY}_access.log;
    error_log /home/$2/logs/${PUBLIC_DIRECTORY}_error.log;
}
EOF
	fi

	sudo ln -sf "$CONF" /etc/nginx/sites-enabled/
	sudo nginx -t && sudo systemctl reload nginx
	echo "✅ Nginx configured for listen port $PORT"
	
	# --- UFW Firewall Rules ---
	echo "🛡️  Applying UFW firewall rules..."
	
	sudo ufw allow "$PORT" comment "Allow Nginx + PHP listen port for $2"
	echo "✅ UFW allowed listen port $PORT for Nginx + PHP"
	echo ""
}

setup_nodejs_config() {
	# $1 = USERNAME
	# $2 = PROJECT_STRUCTURE
	# $3 = NODE_LOCAL_PORT
	# $4 = PORT
	# $5 = IS_BACKEND (Optional)
	
	PUBLIC_DIRECTORY="public_app"
	CONFIG_NAME="${1}_app.conf"
	NODE_LOCAL_PORT=${3:-3000}
	PORT=${4:-80}
	IS_BACKEND=${5:-n}
	
	if [[ "$3" == "1" ]]; then
		PUBLIC_DIRECTORY="public_html"
		CONFIG_NAME="${1}_html.conf"
	fi
	
	if [[ "$2" == "3" ]] || ([[ "$2" == "2" ]] && [[ "$IS_BACKEND" =~ ^[Yy]$ ]]); then
		PUBLIC_DIRECTORY="public_api"
		CONFIG_NAME="${1}_api.conf"
	fi
	
	echo "<html><body><h1>$1 - $PUBLIC_DIRECTORY is ready!</h1></body></html>" | tee /home/$1/$PUBLIC_DIRECTORY/index.html > /dev/null
	sudo chown $1:www-data /home/$1/$PUBLIC_DIRECTORY/index.html
	
	CONF="/etc/nginx/sites-available/${CONFIG_NAME}"
	sudo tee "$CONF" > /dev/null <<EOF
server {
    listen 80;
    server_name _;

    root /home/$1/$PUBLIC_DIRECTORY;
    index index.html index.htm;

    location / {
        try_files \$uri \$uri/ @node;
    }

    location @node {
        proxy_pass http://localhost:$NODE_LOCAL_PORT;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host \$host;
        proxy_cache_bypass \$http_upgrade;
    }

    access_log /home/$1/logs/public_app_access.log;
    error_log /home/$1/logs/public_app_error.log;
}
EOF

	sudo ln -sf "$CONF" /etc/nginx/sites-enabled/
	sudo nginx -t && sudo systemctl reload nginx
	echo "✅ Nginx reverse proxy configured for Node.js listen port $PORT"
	
	# --- UFW Firewall Rules ---
	echo "🛡️  Applying UFW firewall rules..."

	sudo ufw allow "$PORT" comment "Allow Node.js listen port for $1"
	echo "✅ UFW allowed listen port $PORT for Node.js"
	echo ""
}


echo "🚀 Starting Deployment..."

# --- Create User ---
read -p "Enter new username: " USERNAME
USERNAME=$(echo "$USERNAME" | xargs)
PASSWORD=$(openssl rand -base64 12)
sudo useradd -m -s /bin/bash -G sudo,www-data "$USERNAME"
echo "$USERNAME:$PASSWORD" | sudo chpasswd

if ! id "$USERNAME" &>/dev/null; then
  echo "❌ Failed to create user '$USERNAME'."
  exit 1
fi

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
		
		install_nodejs "$USERNAME"
		
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
		install_nodejs "$USERNAME"
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

		setup_nginx_config "$IS_LARAVEL" "$USERNAME" "$PROJECT_STRUCTURE" "FRONTEND_PHP_VERSION" "FRONTEND_PORT" "Y"
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

		setup_nginx_config "$IS_LARAVEL" "$USERNAME" "$PROJECT_STRUCTURE" "$BACKEND_PHP_VERSION" "$BACKEND_PORT"
	fi
elif [[ "$PROJECT_STRUCTURE" == "3" ]]; then
	echo "🔧 Backend Server (0: Nginx + PHP, 1: Node.js)"
	read -p "Select a backend server (default 0): " BACKEND_SERVER
	BACKEND_SERVER=${BACKEND_SERVER:-0}
	
	setup_default_directory "$PROJECT_STRUCTURE" "$USERNAME"
	
	if [[ "$BACKEND_SERVER" == "1" ]]; then
		NEED_BACKEND_NODE="Y"
		install_nodejs "$USERNAME"
		
		read -p "Local port for backend Node.js api (default 3000): " NODE_BACKEND_LOCAL_PORT
		NODE_BACKEND_LOCAL_PORT=${NODE_BACKEND_LOCAL_PORT:-3000}

	    read -p "Public port for backend Node.js api (default 8080): " BACKEND_PORT
	    BACKEND_PORT=${BACKEND_PORT:-8080}
		
		setup_nodejs_config "$USERNAME" "$PROJECT_STRUCTURE" "$NODE_BACKEND_LOCAL_PORT" "$BACKEND_PORT" "Y"
	else
		NEED_BACKEND_NGINX="Y"
		
		read -p "Setup as Backend Laravel App? (Y/n): " IS_LARAVEL
		IS_LARAVEL=${IS_LARAVEL:-n}
		setup_nginx_config "$IS_LARAVEL" "$USERNAME" "3"
		
		setup_nginx_config "$IS_LARAVEL" "$USERNAME" "$PROJECT_STRUCTURE" "$BACKEND_PHP_VERSION" "$BACKEND_PORT"
	fi
else
	# --- Summary ---
	echo ""
	echo "🎉 Deployment Summary:"
	echo "👤 Username: $USERNAME"
	echo "🔑 Password: $PASSWORD"
	exit 1
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

# --- Supervisor for Laravel Queue ---
read -p "Enable Supervisor for Laravel queue worker? (Y/n): " ENABLE_SUPERVISOR
if [[ "$ENABLE_SUPERVISOR" =~ ^[Yy]$ ]]; then
  sudo apt install -y supervisor
  sudo tee "/etc/supervisor/conf.d/${USERNAME}_queue.conf" > /dev/null <<EOF
[program:${USERNAME}_queue]
command=/usr/bin/php /home/$USERNAME/public_api/artisan queue:work --sleep=3 --tries=3 --timeout=90
directory=/home/$USERNAME/public_api
autostart=true
autorestart=true
user=$USERNAME
redirect_stderr=true
stdout_logfile=/home/$USERNAME/logs/queue_worker.log
stopasgroup=true
killasgroup=true
EOF
  sudo supervisorctl reread
  sudo supervisorctl update
  sudo supervisorctl start "${USERNAME}_queue"
  echo "✅ Supervisor queue worker started"
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
echo "🎉 Deployment Summary:"
echo "👤 Username: $USERNAME"
echo "🔑 Password: $PASSWORD"

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

if [[ "$PROJECT_STRUCTURE" == "1" ]]; then
	echo ""
	echo "🌐 Access your App at: http://<server-ip>:${PORT:-80}/"
	echo ""
elif [[ "$PROJECT_STRUCTURE" == "2" ]]; then
	echo ""
	echo "🌐 Access your frontend app at: http://<server-ip>:${FRONTEND_PORT:-80}/"
	echo "🌐 Access your backend API at: http://<server-ip>:${BACKEND_PORT:-8080}/"
	echo ""
elif [[ "$PROJECT_STRUCTURE" == "3" ]]; then
	echo ""
	echo "🌐 Access your backend API at: http://<server-ip>:${BACKEND_PORT:-8080}/"
	echo ""
fi