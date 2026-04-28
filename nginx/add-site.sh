#!/bin/bash
# =============================================================================
# Nginx: Add Site — server block + isolated PHP-FPM pool + optional DB per site
#
# Quick add (interactive):
#   bash <(curl -fsSL https://raw.githubusercontent.com/DaveBugg/web_server_script/main/nginx/add-site.sh)
#
# Non-interactive (env vars):
#   curl -fsSL .../add-site.sh | \
#     DOMAIN=example.com NEWUSER=example SITE_PASS='Secure123!' \
#     SSL_SETUP=y CERTBOT_EMAIL=admin@example.com \
#     CREATE_DB=yes DB_NAME=example_db DB_USER=example_user bash
#
# Reads:  /etc/web_server_script.conf  → DATABASE, PHP_VER
#
# Version: 4.0
# =============================================================================

STATE_FILE="/etc/web_server_script.conf"
[ -f "$STATE_FILE" ] && . "$STATE_FILE"

PHP_VER="${PHP_VER:-8.4}"
DATABASE="${DATABASE:-}"

if [ -e /dev/tty ]; then
    exec 3</dev/tty
else
    exec 3<&0
fi

ask() {
    local var="$1" msg="$2"
    local current="${!var:-}"
    if [ -n "$current" ]; then
        echo "$msg$current  [from env]"
        return 0
    fi
    read -u 3 -r -p "$msg" "$var"
}

check_package() { dpkg -l 2>/dev/null | grep -q "^ii  $1 "; }

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: this script must be run as root (use sudo)"
    exit 1
fi

if [ ! -d "/etc/php/${PHP_VER}/fpm/pool.d" ]; then
    echo "ERROR: PHP-FPM ${PHP_VER} not installed. Run nginx/install.sh first."
    exit 1
fi

if ! command -v nginx >/dev/null 2>&1; then
    echo "ERROR: Nginx not installed. Run nginx/install.sh first."
    exit 1
fi

# =============================================================================
# Inputs
# =============================================================================
ask DOMAIN  "Enter domain: "
ask NEWUSER "Enter new username for virtualhost: "
[ -z "${DOMAIN:-}" ]  && { echo "Domain can't be blank"; exit 1; }
[ -z "${NEWUSER:-}" ] && { echo "Username can't be blank"; exit 1; }

# =============================================================================
# SSL
# =============================================================================
SSL_SETUP_FLAG=false
CERTBOT_DOMAINS=""
CERTBOT_EMAIL="${CERTBOT_EMAIL:-}"
ADDITIONAL_DOMAINS="${ADDITIONAL_DOMAINS:-}"

echo ""
echo "=== SSL Certificate Setup ==="
ask SSL_SETUP "Do you want to set up SSL certificate with Certbot? (y/n): "

if [[ ${SSL_SETUP:-n} =~ ^[Yy]$ ]]; then
    if ! check_package "certbot" || ! check_package "python3-certbot-nginx"; then
        echo "Installing Certbot + python3-certbot-nginx..."
        DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-certbot-nginx; then
            echo "Failed to install Certbot. SSL setup will be skipped."
            SSL_SETUP="n"
        fi
    fi
    if [[ ${SSL_SETUP:-n} =~ ^[Yy]$ ]]; then
        ask CERTBOT_EMAIL "Enter email for Let's Encrypt notifications: "
        if [ -z "${CERTBOT_EMAIL:-}" ]; then
            echo "Email required. SSL setup skipped."
            SSL_SETUP="n"
        else
            CERTBOT_DOMAINS="-d $DOMAIN -d www.$DOMAIN"
            if [ -z "${ADDITIONAL_DOMAINS+set}" ]; then
                echo "Comma-separated subdomains (e.g. api,blog) — Enter to skip:"
                ask ADDITIONAL_DOMAINS "Additional subdomains: "
            fi
            if [ -n "${ADDITIONAL_DOMAINS:-}" ]; then
                IFS=',' read -ra DA <<< "$ADDITIONAL_DOMAINS"
                for sd in "${DA[@]}"; do
                    sd=$(echo "$sd" | xargs)
                    [ -n "$sd" ] && CERTBOT_DOMAINS="$CERTBOT_DOMAINS -d $sd.$DOMAIN"
                done
            fi
            SSL_SETUP_FLAG=true
            echo "SSL will be configured for: $(echo $CERTBOT_DOMAINS | sed 's/-d //g')"
        fi
    fi
fi

# =============================================================================
# Optional per-site DB (same logic as apache/add-site.sh)
# =============================================================================
DB_CREATED=false
DB_NAME="${DB_NAME:-}"
DB_USER="${DB_USER:-}"
DB_PASS="${DB_PASS:-}"

echo ""
echo "=== Database Setup ==="
if [ -z "$DATABASE" ]; then
    echo "No database engine detected (state file missing) — skipping DB setup."
    CREATE_DB="no"
else
    echo "Database engine on this server: ${DATABASE}"
    ask CREATE_DB "Create a ${DATABASE} database for this site? (yes/no): "
fi

if [[ ${CREATE_DB:-no} =~ ^[Yy] ]] && [ -n "$DATABASE" ]; then
    SLUG=$(echo "$DOMAIN" | tr '.-' '__' | tr -cd 'a-zA-Z0-9_')
    : "${DB_NAME:=${SLUG}_db}"
    : "${DB_USER:=${SLUG}_user}"
    ask DB_NAME "  Database name [${DB_NAME}]: "
    ask DB_USER "  Database user [${DB_USER}]: "
    DB_NAME="${DB_NAME:-${SLUG}_db}"
    DB_USER="${DB_USER:-${SLUG}_user}"

    if [ -z "$DB_PASS" ]; then
        DB_PASS=$(LC_ALL=C tr -dc 'A-Za-z0-9!@#%^_+=' </dev/urandom | head -c 24)
        echo "  Auto-generated password (24 chars)"
    fi

    if [ "$DATABASE" = "mariadb" ]; then
        if ! mysql --defaults-file=/etc/mysql/debian.cnf -e "SELECT 1" >/dev/null 2>&1; then
            echo "ERROR: cannot connect to MariaDB as root. Skipping DB creation."
        else
            mysql --defaults-file=/etc/mysql/debian.cnf <<EOF
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
            if [ $? -eq 0 ]; then
                DB_CREATED=true
                echo "  + MariaDB database '${DB_NAME}' and user '${DB_USER}' created"
            else
                echo "  ERROR: MariaDB DB/user creation failed"
            fi
        fi
    else
        DB_PASS_SQL=$(printf '%s' "$DB_PASS" | sed "s/'/''/g")
        if sudo -u postgres psql >/dev/null 2>&1 <<EOF
DO \$\$
BEGIN
   IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname='${DB_USER}') THEN
      CREATE ROLE "${DB_USER}" LOGIN PASSWORD '${DB_PASS_SQL}';
   ELSE
      ALTER ROLE "${DB_USER}" WITH LOGIN PASSWORD '${DB_PASS_SQL}';
   END IF;
END\$\$;
EOF
        then
            if sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" 2>/dev/null | grep -q 1; then
                echo "  - PostgreSQL database '${DB_NAME}' already exists"
            else
                sudo -u postgres createdb -O "${DB_USER}" "${DB_NAME}" 2>&1 || true
            fi
            sudo -u postgres psql -d "${DB_NAME}" -c "GRANT ALL PRIVILEGES ON DATABASE \"${DB_NAME}\" TO \"${DB_USER}\"; GRANT ALL ON SCHEMA public TO \"${DB_USER}\";" >/dev/null 2>&1
            DB_CREATED=true
            echo "  + PostgreSQL database '${DB_NAME}' and user '${DB_USER}' created"
        else
            echo "  ERROR: PostgreSQL role creation failed"
        fi
    fi
fi

# =============================================================================
# Determine which admin snippet to include in the vhost (so /<alias> works)
# =============================================================================
ADMIN_INCLUDE=""
[ "$DATABASE" = "mariadb" ] && [ -f /etc/nginx/snippets/admin-pma.conf ] && \
    ADMIN_INCLUDE="include /etc/nginx/snippets/admin-pma.conf;"
[ "$DATABASE" = "pgsql" ]   && [ -f /etc/nginx/snippets/admin-pga.conf ] && \
    ADMIN_INCLUDE="include /etc/nginx/snippets/admin-pga.conf;"

# =============================================================================
# Nginx server blocks
#
# Two blocks: HTTP (redirect to HTTPS) + HTTPS (serves PHP).
# SSL lines marked with '##' are uncommented after Certbot succeeds.
# =============================================================================
echo "Creating Nginx server block for $DOMAIN..."

cat > /etc/nginx/sites-available/$DOMAIN <<EOF
# HTTP -> HTTPS redirect
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN www.$DOMAIN;

    include /etc/nginx/snippets/cloudflare-realip.conf;

    # Allow ACME challenge over HTTP (Certbot)
    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

# HTTPS — PHP-FPM + HTTP/2
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    ##http2 on;
    server_name $DOMAIN www.$DOMAIN;

    root /www/$DOMAIN/www;
    index index.html index.php;

    include /etc/nginx/snippets/cloudflare-realip.conf;
    include /etc/nginx/snippets/security-headers.conf;

    # SSL cert paths — uncommented after certbot --nginx succeeds.
    ##ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ##ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ##ssl_protocols TLSv1.2 TLSv1.3;
    ##ssl_ciphers HIGH:!aNULL:!MD5;
    ##ssl_prefer_server_ciphers off;

    # Snakeoil cert as a fallback so the vhost survives a config-test before SSL is set up.
    ssl_certificate     /etc/ssl/certs/ssl-cert-snakeoil.pem;
    ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key;

    access_log /www/$DOMAIN/logs/access.log;
    error_log  /www/$DOMAIN/logs/error.log;

    # Admin UI passthrough (matches /<alias>/ before generic location /)
    ${ADMIN_INCLUDE}

    # Static assets — long cache
    location ~* \.(css|js|woff2?|ttf|eot|svg|png|jpg|jpeg|gif|webp|ico)\$ {
        expires 1y;
        access_log off;
        add_header Cache-Control "public, max-age=31536000, immutable";
        add_header Vary "Accept-Encoding";
        try_files \$uri =404;
    }

    location / {
        try_files \$uri \$uri/ /index.php?\$args;
    }

    location ~ \.php\$ {
        try_files \$uri =404;
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php${PHP_VER}-fpm-$DOMAIN.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param PATH_INFO       \$fastcgi_path_info;
        fastcgi_read_timeout 60;
    }

    # Hide dotfiles
    location ~ /\.(?!well-known).* {
        deny all;
    }
}
EOF

# =============================================================================
# PHP-FPM pool
# =============================================================================
echo "Creating PHP-FPM pool configuration for $DOMAIN..."
cat > /etc/php/${PHP_VER}/fpm/pool.d/$DOMAIN.conf <<EOF
[$DOMAIN]
user = $NEWUSER
group = $NEWUSER

listen = /run/php/php${PHP_VER}-fpm-$DOMAIN.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660

pm = dynamic
pm.max_children = 10
pm.start_servers = 2
pm.min_spare_servers = 1
pm.max_spare_servers = 3

php_admin_value[open_basedir] = /www/$DOMAIN/www:/www/$DOMAIN/tmp:/tmp
php_admin_value[upload_tmp_dir] = /www/$DOMAIN/tmp
php_admin_value[session.save_path] = /www/$DOMAIN/tmp

php_admin_value[disable_functions] = passthru,shell_exec,system,proc_open,popen
php_admin_value[allow_url_include] = Off

php_admin_value[memory_limit] = 256M
php_admin_value[max_execution_time] = 30
php_admin_value[max_input_vars] = 3000
php_admin_value[post_max_size] = 32M
php_admin_value[upload_max_filesize] = 32M

php_admin_value[display_errors] = Off
php_admin_value[log_errors] = On
php_admin_value[error_log] = /www/$DOMAIN/logs/php_error.log
EOF

cat > /etc/cron.d/php-sessions-$DOMAIN <<EOF
09,39 * * * *  root  /usr/bin/find /www/$DOMAIN/tmp -name "sess_*" -type f -cmin +24 -print0 | /usr/bin/xargs -r -0 rm >/dev/null 2>&1
EOF

# =============================================================================
# System user + dirs
# =============================================================================
echo "Creating user $NEWUSER..."
groupadd "$NEWUSER" 2>/dev/null || true
if id "$NEWUSER" >/dev/null 2>&1; then
    echo "  user $NEWUSER already exists, skipping useradd"
else
    useradd "$NEWUSER" -d "/www/$DOMAIN" -g "$NEWUSER" -s /bin/false
fi

if [ -n "${SITE_PASS:-}" ]; then
    echo "$NEWUSER:$SITE_PASS" | chpasswd
    echo "  password set from env SITE_PASS"
else
    echo "Enter password for new user $NEWUSER:"
    passwd "$NEWUSER" < /dev/tty || echo "  WARN: passwd failed (skipped). Set later with: passwd $NEWUSER"
fi

mkdir -p /www/$DOMAIN/www
mkdir -p /www/$DOMAIN/logs
mkdir -p /www/$DOMAIN/tmp

chown -R $NEWUSER:www-data /www/$DOMAIN
chmod -R 750 /www/$DOMAIN/www
chmod -R 770 /www/$DOMAIN/tmp
chmod -R 770 /www/$DOMAIN/logs

usermod -a -G www-data  "$NEWUSER"
usermod -a -G "$NEWUSER" www-data

# =============================================================================
# Logrotate
# =============================================================================
cat > /etc/logrotate.d/$DOMAIN.conf <<EOF
/www/$DOMAIN/logs/*.log {
    daily
    missingok
    size=50M
    rotate 14
    compress
    delaycompress
    notifempty
    create 640 $NEWUSER www-data
    sharedscripts
    postrotate
        if /etc/init.d/nginx status > /dev/null ; then \\
            /etc/init.d/nginx reload > /dev/null; \\
        fi;
        if /etc/init.d/php${PHP_VER}-fpm status > /dev/null ; then \\
            /etc/init.d/php${PHP_VER}-fpm reload > /dev/null; \\
        fi;
    endscript
}
EOF

cat > /www/$DOMAIN/www/index.php <<EOF
<?php
echo "<h1>Welcome to $DOMAIN</h1>";
echo "<p>PHP-FPM is working.</p>";
echo "<p>PHP Version: " . phpversion() . "</p>";
echo "<p>Server time: " . date('Y-m-d H:i:s') . "</p>";
EOF
chown $NEWUSER:www-data /www/$DOMAIN/www/index.php
chmod 640 /www/$DOMAIN/www/index.php

# =============================================================================
# DB credentials file
# =============================================================================
if [ "$DB_CREATED" = "true" ]; then
    cat > /www/$DOMAIN/db.txt <<EOF
# Database credentials for $DOMAIN
# Created: $(date -u +%FT%TZ)
DB_TYPE=$DATABASE
DB_HOST=localhost
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PASS=$DB_PASS
EOF
    chown $NEWUSER:$NEWUSER /www/$DOMAIN/db.txt
    chmod 600 /www/$DOMAIN/db.txt
fi

# =============================================================================
# Enable + reload
# =============================================================================
ln -sf /etc/nginx/sites-available/$DOMAIN /etc/nginx/sites-enabled/$DOMAIN

systemctl restart php${PHP_VER}-fpm

echo "Testing Nginx configuration..."
if ! nginx -t; then
    echo "ERROR: Nginx configuration test failed."
    exit 1
fi

systemctl reload nginx

# ---- SSL via certbot --nginx ----
SSL_CONFIGURED=false
if [ "$SSL_SETUP_FLAG" = true ]; then
    echo ""
    echo "=== Setting up SSL Certificate ==="
    if certbot --nginx --email "$CERTBOT_EMAIL" --agree-tos --no-eff-email \
        --redirect $CERTBOT_DOMAINS; then
        echo "SSL certificate installed."
        # Uncomment our hardening lines (http2 on, real cert paths, TLS protocol)
        # NOTE: certbot will already have rewritten ssl_certificate paths to point
        # at the Let's Encrypt files; we just enable http2 and TLS protocols.
        sed -i 's/##http2 on;/http2 on;/'                       /etc/nginx/sites-available/$DOMAIN
        sed -i 's/##ssl_protocols TLSv1.2 TLSv1.3;/ssl_protocols TLSv1.2 TLSv1.3;/' /etc/nginx/sites-available/$DOMAIN
        sed -i 's/##ssl_ciphers HIGH:!aNULL:!MD5;/ssl_ciphers HIGH:!aNULL:!MD5;/'   /etc/nginx/sites-available/$DOMAIN
        sed -i 's/##ssl_prefer_server_ciphers off;/ssl_prefer_server_ciphers off;/' /etc/nginx/sites-available/$DOMAIN

        if nginx -t && systemctl reload nginx; then
            echo "SSL configuration activated."
            SSL_CONFIGURED=true
        else
            echo "WARNING: SSL cert installed but nginx reload failed."
        fi
    else
        echo ""
        echo "ERROR: SSL certificate installation failed."
        echo "SSL hardening lines remain commented out (safe state)."
        echo "Retry: certbot --nginx --email \"$CERTBOT_EMAIL\" --agree-tos --no-eff-email --redirect $CERTBOT_DOMAINS"
    fi
fi

# =============================================================================
echo ""
echo "=============================================================="
echo " Site $DOMAIN created successfully!"
echo "=============================================================="
echo "  Site files : /www/$DOMAIN/www"
echo "  Logs       : /www/$DOMAIN/logs"
echo "  Temp/sess  : /www/$DOMAIN/tmp"
echo "  User       : $NEWUSER"
echo "  HTTP URL   : http://$DOMAIN  (redirects to HTTPS)"
if [ "$SSL_CONFIGURED" = true ]; then
    echo "  HTTPS URL  : https://$DOMAIN  (SSL active)"
else
    echo "  HTTPS URL  : https://$DOMAIN  (snakeoil cert until certbot runs)"
fi

if [ "$DB_CREATED" = "true" ]; then
    echo ""
    echo "  ----- Database credentials ($DATABASE) -----"
    echo "  DB host    : localhost"
    echo "  DB name    : $DB_NAME"
    echo "  DB user    : $DB_USER"
    echo "  DB pass    : $DB_PASS"
    echo "  Saved to   : /www/$DOMAIN/db.txt  (mode 600, owner $NEWUSER)"
fi

echo ""
echo "  After deploying app: chown -R $NEWUSER:www-data /www/$DOMAIN/www && chmod -R 750 /www/$DOMAIN/www"
