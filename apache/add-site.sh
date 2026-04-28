#!/bin/bash
# =============================================================================
# Apache: Add Site — vhost + isolated PHP-FPM pool + optional DB per site
#
# Quick add (interactive):
#   bash <(curl -fsSL https://raw.githubusercontent.com/DaveBugg/web_server_script/main/apache/add-site.sh)
#
# Non-interactive (env vars):
#   curl -fsSL .../add-site.sh | \
#     DOMAIN=example.com NEWUSER=example SITE_PASS='Secure123!' \
#     SSL_SETUP=y CERTBOT_EMAIL=admin@example.com \
#     CREATE_DB=yes DB_NAME=example_db DB_USER=example_user bash
#
# Env vars:
#   DOMAIN, NEWUSER, SITE_PASS, SSL_SETUP (y/n), CERTBOT_EMAIL,
#   ADDITIONAL_DOMAINS (comma list), PHP_VER (default from state file or 8.4),
#   CREATE_DB (yes/no), DB_NAME, DB_USER, DB_PASS (auto-generated if blank)
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

if [ ! -d "/etc/php/${PHP_VER}/fpm/pool.d" ] || ! systemctl list-unit-files 2>/dev/null | grep -q "php${PHP_VER}-fpm"; then
    echo "ERROR: PHP-FPM ${PHP_VER} not installed."
    echo "       Run apache/install.sh first."
    exit 1
fi

if ! command -v apache2 >/dev/null 2>&1; then
    echo "ERROR: Apache not installed. Run apache/install.sh first."
    exit 1
fi

# =============================================================================
# Domain + user input
# =============================================================================
ask DOMAIN  "Enter domain: "
ask NEWUSER "Enter new username for virtualhost: "
[ -z "${DOMAIN:-}" ]  && { echo "Domain can't be blank"; exit 1; }
[ -z "${NEWUSER:-}" ] && { echo "Username can't be blank"; exit 1; }

DOMAIN_ESCAPED=$(echo "$DOMAIN" | sed 's/\./\\./g')

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
    if ! check_package "certbot" || ! check_package "python3-certbot-apache"; then
        echo "Installing Certbot + python3-certbot-apache..."
        DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-certbot-apache; then
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
# Optional per-site database
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
# Apache vhost
# =============================================================================
echo "Creating Apache virtual host configuration for $DOMAIN with PHP-FPM support..."

cat > /etc/apache2/sites-available/$DOMAIN.conf <<EOF
<VirtualHost *:80>
    ServerName _
    DocumentRoot /var/www/html
    <Location />
        Require all denied
        ErrorDocument 403 "<!DOCTYPE html><html><head><title>Access Denied</title></head><body><h1>403 Forbidden</h1><p>Direct IP access is not allowed.</p></body></html>"
    </Location>
    ErrorLog \${APACHE_LOG_DIR}/ip_block_error.log
    CustomLog \${APACHE_LOG_DIR}/ip_block_access.log combined
</VirtualHost>

<VirtualHost *:443>
    ServerName _
    DocumentRoot /var/www/html
    SSLEngine on
    SSLCertificateFile /etc/ssl/certs/ssl-cert-snakeoil.pem
    SSLCertificateKeyFile /etc/ssl/private/ssl-cert-snakeoil.key
    <Location />
        Require all denied
        ErrorDocument 403 "<!DOCTYPE html><html><head><title>Access Denied</title></head><body><h1>403 Forbidden</h1><p>Direct IP access is not allowed.</p></body></html>"
    </Location>
    ErrorLog \${APACHE_LOG_DIR}/ip_block_ssl_error.log
    CustomLog \${APACHE_LOG_DIR}/ip_block_ssl_access.log combined
</VirtualHost>

<VirtualHost *:80>
    ServerName $DOMAIN
    ServerAlias www.$DOMAIN
    DocumentRoot /www/$DOMAIN/www
    ServerAdmin support@$DOMAIN
    RewriteEngine On
    RewriteRule ^ https://%{SERVER_NAME}%{REQUEST_URI} [END,NE,R=permanent]
    ErrorLog /www/$DOMAIN/logs/error.log
    CustomLog /www/$DOMAIN/logs/access.log combined
</VirtualHost>

<VirtualHost *:443>
    ServerName $DOMAIN
    ServerAlias www.$DOMAIN
    DocumentRoot /www/$DOMAIN/www
    ServerAdmin support@$DOMAIN
    Protocols h2 http/1.1

    ##SSLEngine on
    # SSLCertificateFile /etc/letsencrypt/live/$DOMAIN/fullchain.pem
    # SSLCertificateKeyFile /etc/letsencrypt/live/$DOMAIN/privkey.pem
    # Include /etc/letsencrypt/options-ssl-apache.conf

    ##SSLProtocol -all +TLSv1.2 +TLSv1.3
    ##SSLHonorCipherOrder off
    ##SSLSessionTickets off

    <IfModule mod_http2.c>
        H2Direct on
        H2Upgrade on
        H2PushPriority *                     after
        H2PushPriority text/css              before
        H2PushPriority application/javascript after
        H2PushPriority image/webp            after
    </IfModule>

    <FilesMatch "\.php$">
        SetHandler "proxy:unix:/run/php/php${PHP_VER}-fpm-$DOMAIN.sock|fcgi://localhost"
    </FilesMatch>

    <Directory "/www/$DOMAIN/www">
        Options FollowSymLinks
        AllowOverride All
        Require all granted

        RewriteEngine On
        RewriteCond %{HTTP_HOST} !^(${DOMAIN_ESCAPED}|www\\.${DOMAIN_ESCAPED})\$ [NC]
        RewriteRule ^(.*)\$ - [F,L]

        <FilesMatch "\.php$">
            Require all granted
        </FilesMatch>
    </Directory>

    DirectoryIndex index.html index.php
    SetEnvIfNoCase Request_URI "\.(gif|jpe?g|png|htc|css|js|ico|bmp|woff|woff2|svg|webp)\$" skiplog
    CustomLog /www/$DOMAIN/logs/access.log combined env=!skiplog
    ErrorLog  /www/$DOMAIN/logs/error.log

    <IfModule mod_headers.c>
        Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"
        Header always set X-Content-Type-Options nosniff
        Header always set X-Frame-Options DENY
        Header always set X-XSS-Protection "1; mode=block"

        <FilesMatch "\.css$">
            Header set Content-Type "text/css; charset=utf-8"
        </FilesMatch>

        <FilesMatch "\.js$">
            Header set Content-Type "application/javascript; charset=utf-8"
        </FilesMatch>

        <LocationMatch "\.(css|js|woff|woff2|ttf|eot|svg|png|jpg|jpeg|gif|webp|ico)\$">
            Header set Cache-Control "public, max-age=31536000, immutable"
            Header set Vary "Accept-Encoding"
        </LocationMatch>
    </IfModule>
</VirtualHost>
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
# Session cleanup for $DOMAIN — removes sessions older than 24 minutes
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

echo "Creating directories and setting permissions..."
mkdir -p /www/$DOMAIN/www
mkdir -p /www/$DOMAIN/logs
mkdir -p /www/$DOMAIN/tmp

chown -R $NEWUSER:www-data /www/$DOMAIN
chmod -R 750 /www/$DOMAIN/www
chmod -R 770 /www/$DOMAIN/tmp
chmod -R 770 /www/$DOMAIN/logs

usermod -a -G www-data  "$NEWUSER"
usermod -a -G "$NEWUSER" www-data

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
        if /etc/init.d/apache2 status > /dev/null ; then \\
            /etc/init.d/apache2 reload > /dev/null; \\
        fi;
        if /etc/init.d/php${PHP_VER}-fpm status > /dev/null ; then \\
            /etc/init.d/php${PHP_VER}-fpm reload > /dev/null; \\
        fi;
    endscript
    prerotate
        if [ -d /etc/logrotate.d/httpd-prerotate ]; then \\
            run-parts /etc/logrotate.d/httpd-prerotate; \\
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
# Save DB credentials to /www/$DOMAIN/db.txt (mode 600, owner = site user)
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
# Enable site + restart
# =============================================================================
echo "Enabling site $DOMAIN..."
a2ensite $DOMAIN

echo "Restarting PHP-FPM..."
systemctl restart php${PHP_VER}-fpm

echo "Testing Apache configuration..."
if ! apache2ctl configtest; then
    echo "ERROR: Apache configuration test failed."
    exit 1
fi

echo "Restarting Apache..."
systemctl restart apache2

SSL_CONFIGURED=false
if [ "$SSL_SETUP_FLAG" = true ]; then
    echo ""
    echo "=== Setting up SSL Certificate ==="
    if certbot --apache --email "$CERTBOT_EMAIL" --agree-tos --no-eff-email \
        --redirect $CERTBOT_DOMAINS; then
        echo "SSL certificate installed."
        sed -i 's/##//g' /etc/apache2/sites-available/$DOMAIN.conf
        if systemctl restart apache2; then
            echo "SSL configuration activated."
            SSL_CONFIGURED=true
        fi
    else
        echo ""
        echo "ERROR: SSL certificate installation failed."
        echo "Retry: certbot --apache --email \"$CERTBOT_EMAIL\" --agree-tos --no-eff-email --redirect $CERTBOT_DOMAINS"
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
    echo "  HTTPS URL  : https://$DOMAIN  (configure SSL manually with certbot)"
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
