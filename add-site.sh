#!/bin/bash
# =============================================================================
# Add Site — Apache + PHP-FPM + HTTP/2
# Creates a new virtual host with isolated PHP-FPM pool per domain.
#
# Quick add (interactive):
#   bash <(curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/add-site.sh)
#
# Non-interactive (env vars):
#   curl -fsSL https://.../add-site.sh | \
#     DOMAIN=example.com NEWUSER=example SITE_PASS='Secure123!' \
#     SSL_SETUP=y CERTBOT_EMAIL=admin@example.com bash
#
# Available env vars:
#   DOMAIN, NEWUSER, SITE_PASS, SSL_SETUP (y/n), CERTBOT_EMAIL,
#   ADDITIONAL_DOMAINS (comma list, e.g. "api,blog"), PHP_VER (default 8.4)
#
# Version: 2.2
# =============================================================================

PHP_VER="${PHP_VER:-8.4}"

# Open fd 3 from /dev/tty so prompts work even when piped (curl | bash).
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

check_package() { dpkg -l | grep -q "^ii  $1 "; }

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: this script must be run as root (use sudo)"
    exit 1
fi

# Sanity check: was install.sh ever run?
if [ ! -d "/etc/php/${PHP_VER}/fpm/pool.d" ] || ! systemctl list-unit-files 2>/dev/null | grep -q "php${PHP_VER}-fpm"; then
    echo "ERROR: PHP-FPM ${PHP_VER} not installed."
    echo "       Run install.sh first, or override with PHP_VER=<installed-version>"
    exit 1
fi

# =============================================================================
# Input collection
# =============================================================================
ask DOMAIN  "Enter domain: "
ask NEWUSER "Enter new username for virtualhost: "

if [ -z "${DOMAIN:-}" ];  then echo "Domain can't be blank, aborting"; exit 1; fi
if [ -z "${NEWUSER:-}" ]; then echo "Username can't be blank, aborting"; exit 1; fi

# Escape dots in domain for use in Apache RewriteCond regex.
DOMAIN_ESCAPED=$(echo "$DOMAIN" | sed 's/\./\\./g')

# =============================================================================
# SSL Certificate setup
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
        echo ""
        echo "Certbot is not installed. Installing certbot + python3-certbot-apache..."
        DEBIAN_FRONTEND=noninteractive apt-get update -y >/dev/null 2>&1
        if ! DEBIAN_FRONTEND=noninteractive apt-get install -y certbot python3-certbot-apache; then
            echo "Failed to install Certbot. SSL setup will be skipped."
            SSL_SETUP="n"
        fi
    fi

    if [[ ${SSL_SETUP:-n} =~ ^[Yy]$ ]]; then
        ask CERTBOT_EMAIL "Enter email for Let's Encrypt notifications: "
        if [ -z "${CERTBOT_EMAIL:-}" ]; then
            echo "Email is required for SSL certificate. SSL setup will be skipped."
            SSL_SETUP="n"
        else
            CERTBOT_DOMAINS="-d $DOMAIN -d www.$DOMAIN"

            if [ -z "${ADDITIONAL_DOMAINS+set}" ]; then
                echo ""
                echo "Additional subdomains (optional):"
                echo "Comma-separated (e.g: api,blog,shop). Press Enter to skip."
                ask ADDITIONAL_DOMAINS "Additional subdomains: "
            fi

            if [ -n "${ADDITIONAL_DOMAINS:-}" ]; then
                IFS=',' read -ra DOMAINS_ARRAY <<< "$ADDITIONAL_DOMAINS"
                for subdomain in "${DOMAINS_ARRAY[@]}"; do
                    subdomain=$(echo "$subdomain" | xargs)
                    if [ -n "$subdomain" ]; then
                        CERTBOT_DOMAINS="$CERTBOT_DOMAINS -d $subdomain.$DOMAIN"
                    fi
                done
            fi

            SSL_SETUP_FLAG=true
            echo ""
            echo "SSL will be configured for: $(echo $CERTBOT_DOMAINS | sed 's/-d //g')"
        fi
    fi
fi

# =============================================================================
# Apache virtual host configuration
# =============================================================================
echo "Creating Apache virtual host configuration for $DOMAIN with PHP-FPM support..."

cat > /etc/apache2/sites-available/$DOMAIN.conf <<EOF
# -----------------------------------------------------------------------
# Default catch-all: block direct IP access (HTTP)
# -----------------------------------------------------------------------
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

# -----------------------------------------------------------------------
# Default catch-all: block direct IP access (HTTPS)
# -----------------------------------------------------------------------
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

# -----------------------------------------------------------------------
# HTTP vhost — permanent redirect to HTTPS only
# -----------------------------------------------------------------------
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

# -----------------------------------------------------------------------
# HTTPS vhost — PHP-FPM + HTTP/2
# -----------------------------------------------------------------------
<VirtualHost *:443>
    ServerName $DOMAIN
    ServerAlias www.$DOMAIN
    DocumentRoot /www/$DOMAIN/www
    ServerAdmin support@$DOMAIN

    Protocols h2 http/1.1

    # SSL Configuration — '##' lines are uncommented after Certbot succeeds.
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

        # Block requests whose Host header doesn't match this domain.
        # DOMAIN_ESCAPED has dots escaped (\.) so they are treated as
        # literal dots in the regex, not wildcard any-character matches.
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
# PHP-FPM pool for this domain
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

; open_basedir restricts PHP file access to this domain's directories only
php_admin_value[open_basedir] = /www/$DOMAIN/www:/www/$DOMAIN/tmp:/tmp
php_admin_value[upload_tmp_dir] = /www/$DOMAIN/tmp
php_admin_value[session.save_path] = /www/$DOMAIN/tmp

; Disable dangerous shell/process functions; exec kept enabled for Composer
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

# =============================================================================
# Session cleanup cron job
# =============================================================================
echo "Adding session cleanup cron job..."
cat > /etc/cron.d/php-sessions-$DOMAIN <<EOF
# Session cleanup for $DOMAIN — removes sessions older than 24 minutes
09,39 * * * *  root  /usr/bin/find /www/$DOMAIN/tmp -name "sess_*" -type f -cmin +24 -print0 | /usr/bin/xargs -r -0 rm >/dev/null 2>&1
EOF

# =============================================================================
# Create system user and group for this domain
# =============================================================================
echo "Creating user $NEWUSER..."
groupadd "$NEWUSER" 2>/dev/null || true
if id "$NEWUSER" >/dev/null 2>&1; then
    echo "  user $NEWUSER already exists, skipping useradd"
else
    useradd "$NEWUSER" -d "/www/$DOMAIN" -g "$NEWUSER" -s /bin/false
fi

# Set password — non-interactive if SITE_PASS env provided
if [ -n "${SITE_PASS:-}" ]; then
    echo "$NEWUSER:$SITE_PASS" | chpasswd
    echo "  password set from env SITE_PASS"
else
    echo "Enter password for new user $NEWUSER:"
    passwd "$NEWUSER" < /dev/tty || echo "  WARN: passwd failed (skipped). Set later with: passwd $NEWUSER"
fi

# =============================================================================
# Directory structure and permissions
# =============================================================================
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

# =============================================================================
# Log rotation
# =============================================================================
echo "Setting up log rotation..."
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

# =============================================================================
# Placeholder index.php (no phpinfo — security risk)
# =============================================================================
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
# Enable site and restart services
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

# ------------------------------------------------------------------
# SSL Certificate setup with Certbot
# ------------------------------------------------------------------
SSL_CONFIGURED=false
if [ "$SSL_SETUP_FLAG" = true ]; then
    echo ""
    echo "=== Setting up SSL Certificate ==="
    echo "Running Certbot for: $(echo $CERTBOT_DOMAINS | sed 's/-d //g')"
    echo ""

    if certbot --apache --email "$CERTBOT_EMAIL" --agree-tos --no-eff-email \
        --redirect $CERTBOT_DOMAINS; then
        echo "SSL certificate installed successfully."
        # Uncomment SSL hardening lines
        sed -i 's/##//g' /etc/apache2/sites-available/$DOMAIN.conf
        if systemctl restart apache2; then
            echo "SSL configuration activated successfully."
            SSL_CONFIGURED=true
        else
            echo "WARNING: SSL certificate installed but Apache restart failed."
        fi
    else
        echo ""
        echo "ERROR: SSL certificate installation failed."
        echo "SSL configuration lines remain commented out (safe state)."
        echo "Retry manually with:"
        echo "  certbot --apache --email \"$CERTBOT_EMAIL\" --agree-tos --no-eff-email --redirect $CERTBOT_DOMAINS"
    fi
fi

echo ""
echo "Site $DOMAIN created successfully!"
echo ""
echo "  Site files : /www/$DOMAIN/www"
echo "  Logs       : /www/$DOMAIN/logs"
echo "  Temp/sess  : /www/$DOMAIN/tmp"
echo "  User       : $NEWUSER"
echo "  HTTP URL   : http://$DOMAIN  (redirects to HTTPS)"

if [ "$SSL_CONFIGURED" = true ]; then
    echo "  HTTPS URL  : https://$DOMAIN  (SSL active)"
    echo "  SSL renewal: systemctl status certbot.timer"
else
    echo "  HTTPS URL  : https://$DOMAIN  (configure SSL first)"
    echo ""
    echo "  To install SSL manually:"
    echo "    certbot --apache -d $DOMAIN -d www.$DOMAIN"
    echo "  Then uncomment SSL lines in:"
    echo "    /etc/apache2/sites-available/$DOMAIN.conf"
fi

echo ""
echo "  After deploying your app:"
echo "    chown -R $NEWUSER:www-data /www/$DOMAIN/www"
echo "    chmod -R 750 /www/$DOMAIN/www"
