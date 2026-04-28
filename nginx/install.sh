#!/bin/bash
# =============================================================================
# Nginx Web Server Setup Script (PHP-FPM + DB choice)
#
# Stack: Nginx + PHP-FPM + (MariaDB|PostgreSQL) + (phpMyAdmin|phpPgAdmin) +
#        HTTP/2 + Cloudflare real-IP via set_real_ip_from
#
# Supported: Debian 12/13, Ubuntu 22.04/24.04/26.04 (same PHP repo logic as
#            apache/install.sh)
#
# Quick install:
#   bash <(curl -fsSL https://raw.githubusercontent.com/DaveBugg/web_server_script/main/nginx/install.sh)
#
# Non-interactive:
#   curl -fsSL .../install.sh | \
#     DATABASE=mariadb MYSQL_ROOT='Pass!' PHPMYADMIN_DIR='myadmin' bash
#   curl -fsSL .../install.sh | \
#     DATABASE=pgsql PG_PASS='Pass!' PHPPGADMIN_DIR='mypga' bash
#
# Version: 4.0
# =============================================================================

set -u
set -o pipefail
LOG_FILE="install.log"
PHP_VER="${PHP_VER:-8.4}"
PHPMYADMIN_URL="https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-all-languages.zip"
PHPPGADMIN_VER="7.13.0"
PHPPGADMIN_URL="https://github.com/phppgadmin/phppgadmin/releases/download/REL_7-13-0/phpPgAdmin-${PHPPGADMIN_VER}.tar.gz"
STATE_FILE="/etc/web_server_script.conf"

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

apt_install() {
    local name="$1"; shift
    echo "  apt: installing $name..." | tee -a $LOG_FILE
    local attempts=0
    while [ $attempts -lt 3 ]; do
        if DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" >> $LOG_FILE 2>&1; then
            return 0
        fi
        attempts=$((attempts + 1))
        echo "  apt: retry $attempts/3 for $name (waiting for lock release)..." | tee -a $LOG_FILE
        sleep 5
        dpkg --configure -a >> $LOG_FILE 2>&1 || true
    done
    echo "ERROR: failed to install $name after 3 attempts (see $LOG_FILE)" | tee -a $LOG_FILE
    return 1
}

# =============================================================================
# OS detection
# =============================================================================
if [ ! -f /etc/os-release ]; then
    echo "ERROR: /etc/os-release not found — unsupported system" >&2
    exit 1
fi
. /etc/os-release
DISTRO_ID="${ID:-unknown}"
DISTRO_VER="${VERSION_ID:-0}"
DISTRO_CODENAME="${VERSION_CODENAME:-unknown}"

case "$DISTRO_ID:$DISTRO_VER" in
    debian:12|debian:13|ubuntu:22.04|ubuntu:24.04|ubuntu:26.04) ;;
    *)
        echo "ERROR: unsupported OS: $PRETTY_NAME"
        echo "Supported: Debian 12/13, Ubuntu 22.04/24.04/26.04"
        exit 1
        ;;
esac

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: this script must be run as root (use sudo)"
    exit 1
fi

# =============================================================================
# DB choice & inputs
# =============================================================================
ask DATABASE "Database engine [mariadb|pgsql]: "
DATABASE=$(echo "${DATABASE:-mariadb}" | tr '[:upper:]' '[:lower:]')
case "$DATABASE" in
    mariadb|mysql) DATABASE=mariadb ;;
    pgsql|postgres|postgresql) DATABASE=pgsql ;;
    *) echo "ERROR: unknown DATABASE='$DATABASE' (use 'mariadb' or 'pgsql')"; exit 1 ;;
esac

echo "============================================================"
echo " Web server install — version 4.0 (Nginx stack)"
echo " Detected: $PRETTY_NAME ($DISTRO_CODENAME)"
echo " Target  : Nginx + PHP-FPM ${PHP_VER} + ${DATABASE} +"
[ "$DATABASE" = "mariadb" ] && echo "           phpMyAdmin + HTTP/2 + Cloudflare real-IP"
[ "$DATABASE" = "pgsql"   ] && echo "           phpPgAdmin + HTTP/2 + Cloudflare real-IP"
echo "============================================================"

if [ "$DATABASE" = "mariadb" ]; then
    ask MYSQL_ROOT     "Enter password for MariaDB root user: "
    ask PHPMYADMIN_DIR "Enter phpMyAdmin path alias: "
    [ -z "${MYSQL_ROOT:-}"     ] && { echo "Password can't be blank"; exit 1; }
    [ -z "${PHPMYADMIN_DIR:-}" ] && { echo "phpMyAdmin alias can't be blank"; exit 1; }
else
    ask PG_PASS        "Enter password for PostgreSQL 'postgres' user: "
    ask PHPPGADMIN_DIR "Enter phpPgAdmin path alias: "
    [ -z "${PG_PASS:-}"        ] && { echo "Password can't be blank"; exit 1; }
    [ -z "${PHPPGADMIN_DIR:-}" ] && { echo "phpPgAdmin alias can't be blank"; exit 1; }
fi

BLOWFISH_SECRET=$(openssl rand -base64 32 2>/dev/null || head -c 32 /dev/urandom | base64)

# =============================================================================
# System update + prerequisites
# =============================================================================
echo "Updating system and installing prerequisites..." | tee -a $LOG_FILE
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >> $LOG_FILE 2>&1

apt_install "prerequisites" lsb-release apt-transport-https ca-certificates \
    wget curl gnupg openssl || exit 1

if [ "$DISTRO_ID" = "ubuntu" ]; then
    apt_install "software-properties-common" software-properties-common || exit 1
fi

# =============================================================================
# PHP repo
# =============================================================================
NEED_THIRD_PARTY_REPO=true
case "$DISTRO_ID:$DISTRO_VER" in
    debian:13)
        echo "Debian 13 — PHP ${PHP_VER} available in native repo" | tee -a $LOG_FILE
        NEED_THIRD_PARTY_REPO=false
        ;;
    debian:12)
        echo "Adding sury.org PHP repo for Debian 12..." | tee -a $LOG_FILE
        wget -qO /etc/apt/trusted.gpg.d/php.gpg https://packages.sury.org/php/apt.gpg
        echo "deb https://packages.sury.org/php/ ${DISTRO_CODENAME} main" \
            > /etc/apt/sources.list.d/php.list
        ;;
    ubuntu:*)
        echo "Adding ondrej/php PPA for Ubuntu ${DISTRO_VER} (${DISTRO_CODENAME})..." | tee -a $LOG_FILE
        add-apt-repository -y ppa:ondrej/php >> $LOG_FILE 2>&1 || \
            echo "  WARN: add-apt-repository failed — falling back to native repos" | tee -a $LOG_FILE
        ;;
esac

[ "$NEED_THIRD_PARTY_REPO" = true ] && apt-get update -y >> $LOG_FILE 2>&1

if ! apt-cache show php${PHP_VER}-fpm >/dev/null 2>&1; then
    echo "ERROR: php${PHP_VER}-fpm not available after repo setup." | tee -a $LOG_FILE
    echo "Try: PHP_VER=<other-version> bash $0" | tee -a $LOG_FILE
    exit 1
fi

# =============================================================================
# Main packages
# =============================================================================
apt_install "utilities" mc screen fail2ban ssl-cert || exit 1
apt_install "nginx" nginx curl unzip || exit 1

apt-get purge -y rpcbind 2>/dev/null || true

# DB server
if [ "$DATABASE" = "mariadb" ]; then
    apt_install "mariadb-server" mariadb-server || exit 1
else
    apt_install "postgresql" postgresql postgresql-contrib || exit 1
fi

# PHP-FPM (with both DB drivers)
echo "Installing PHP-FPM ${PHP_VER} and modules (incl. both DB drivers)..." | tee -a $LOG_FILE
apt_install "PHP-FPM ${PHP_VER} core" \
    php${PHP_VER}-fpm \
    php${PHP_VER}-mysql php${PHP_VER}-pgsql \
    php${PHP_VER}-cli php${PHP_VER}-common \
    php${PHP_VER}-ldap php${PHP_VER}-xml php${PHP_VER}-curl \
    php${PHP_VER}-mbstring php${PHP_VER}-zip php${PHP_VER}-bcmath \
    php${PHP_VER}-gd php${PHP_VER}-soap php${PHP_VER}-bz2 \
    php${PHP_VER}-intl php${PHP_VER}-gmp php${PHP_VER}-redis \
    || exit 1

systemctl daemon-reload
if ! dpkg-query -W -f='${Status}' php${PHP_VER}-fpm 2>/dev/null | grep -q "install ok installed"; then
    echo "ERROR: php${PHP_VER}-fpm package not installed after apt-get success" | tee -a $LOG_FILE
    exit 1
fi

if DEBIAN_FRONTEND=noninteractive apt-get install -y php${PHP_VER}-imagick >> $LOG_FILE 2>&1; then
    echo "  + php${PHP_VER}-imagick installed" | tee -a $LOG_FILE
else
    echo "  - php${PHP_VER}-imagick NOT available, skipped" | tee -a $LOG_FILE
fi

systemctl enable php${PHP_VER}-fpm >> $LOG_FILE 2>&1
systemctl start  php${PHP_VER}-fpm >> $LOG_FILE 2>&1

# =============================================================================
# Configure database
# =============================================================================
if [ "$DATABASE" = "mariadb" ]; then
    echo "Configuring MariaDB server..." | tee -a $LOG_FILE
    mysql -u root mysql >> $LOG_FILE 2>&1 <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT';
CREATE USER IF NOT EXISTS 'rooty'@'localhost' IDENTIFIED BY '$MYSQL_ROOT';
GRANT ALL PRIVILEGES ON *.* TO 'rooty'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to configure MariaDB. Aborting." | tee -a $LOG_FILE
        exit 1
    fi
    echo "MariaDB configured." | tee -a $LOG_FILE
else
    echo "Configuring PostgreSQL server..." | tee -a $LOG_FILE
    sudo -u postgres psql >> $LOG_FILE 2>&1 <<EOF
ALTER USER postgres WITH PASSWORD '$PG_PASS';
EOF
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to set postgres password. Aborting." | tee -a $LOG_FILE
        exit 1
    fi
    PG_HBA=$(sudo -u postgres psql -tAc "SHOW hba_file" 2>/dev/null)
    if [ -n "$PG_HBA" ] && [ -f "$PG_HBA" ]; then
        if grep -qE '^host\s+all\s+all\s+127\.0\.0\.1/32' "$PG_HBA"; then
            sed -i -E 's|^(host\s+all\s+all\s+127\.0\.0\.1/32)\s+\S+|\1                       scram-sha-256|' "$PG_HBA"
        else
            echo "host    all             all             127.0.0.1/32            scram-sha-256" >> "$PG_HBA"
        fi
        if grep -qE '^host\s+all\s+all\s+::1/128' "$PG_HBA"; then
            sed -i -E 's|^(host\s+all\s+all\s+::1/128)\s+\S+|\1                            scram-sha-256|' "$PG_HBA"
        else
            echo "host    all             all             ::1/128                 scram-sha-256" >> "$PG_HBA"
        fi
        systemctl reload postgresql >> $LOG_FILE 2>&1
    fi
    echo "PostgreSQL configured." | tee -a $LOG_FILE
fi

# =============================================================================
# Cloudflare real-IP snippet (Nginx)
# =============================================================================
echo "Configuring Cloudflare real-IP for Nginx..." | tee -a $LOG_FILE
CF_IPV4=$(curl -s --max-time 10 https://www.cloudflare.com/ips-v4 || true)
CF_IPV6=$(curl -s --max-time 10 https://www.cloudflare.com/ips-v6 || true)

mkdir -p /etc/nginx/snippets
{
    echo "# Cloudflare real-IP — included from each vhost"
    echo "# IP list fetched from cloudflare.com/ips/ at install time"
    echo ""
    if [ -n "$CF_IPV4" ]; then
        echo "$CF_IPV4" | while read -r ip; do
            [ -n "$ip" ] && echo "set_real_ip_from $ip;"
        done
    fi
    if [ -n "$CF_IPV6" ]; then
        echo "$CF_IPV6" | while read -r ip; do
            [ -n "$ip" ] && echo "set_real_ip_from $ip;"
        done
    fi
    echo ""
    echo "real_ip_header CF-Connecting-IP;"
    echo "real_ip_recursive on;"
} > /etc/nginx/snippets/cloudflare-realip.conf

# =============================================================================
# Default IP-block server (returns 444 for bare-IP requests)
# =============================================================================
cat > /etc/nginx/snippets/security-headers.conf <<'EOF'
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
add_header X-Content-Type-Options nosniff always;
add_header X-Frame-Options DENY always;
add_header X-XSS-Protection "1; mode=block" always;
EOF

cat > /etc/nginx/sites-available/000-default <<EOF
# Default catch-all: drop bare-IP HTTP/HTTPS requests
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 444;
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    http2 on;
    server_name _;
    ssl_certificate     /etc/ssl/certs/ssl-cert-snakeoil.pem;
    ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key;
    return 444;
}
EOF

# Replace stock Debian/Ubuntu default (which serves /var/www/html on :80)
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/000-default /etc/nginx/sites-enabled/000-default

# =============================================================================
# Main nginx.conf — minimal tweaks; let Debian defaults stay otherwise
# =============================================================================
# Ensure HTTP/2 directive support is recognized (modern nginx).
# We only adjust server_tokens and worker tuning here.
mkdir -p /etc/nginx/conf.d
cat > /etc/nginx/conf.d/00-tuning.conf <<'EOF'
# Additional nginx tuning. The stock Debian/Ubuntu /etc/nginx/nginx.conf
# already enables `gzip on;` and sane defaults — we only ADD here.
server_tokens off;
client_max_body_size 32M;
keepalive_timeout 65;
gzip_types text/plain text/css application/javascript application/json image/svg+xml;
gzip_min_length 1024;
EOF

# Hide nginx version in error pages
sed -i 's|^# server_tokens off;|server_tokens off;|' /etc/nginx/nginx.conf 2>/dev/null || true

# =============================================================================
# Install web admin UI
# =============================================================================
if [ "$DATABASE" = "mariadb" ]; then
    # ---------- phpMyAdmin ----------
    echo "Installing phpMyAdmin (latest)..." | tee -a $LOG_FILE
    cd /tmp
    wget -q "$PHPMYADMIN_URL" -O phpMyAdmin.zip
    [ -s phpMyAdmin.zip ] || { echo "ERROR: phpMyAdmin download failed" | tee -a $LOG_FILE; exit 1; }
    unzip -q phpMyAdmin.zip
    PMA_DIR=$(ls -d phpMyAdmin-*-all-languages 2>/dev/null | head -1)
    [ -n "$PMA_DIR" ] && [ -d "$PMA_DIR" ] || { echo "ERROR: phpMyAdmin extraction failed" | tee -a $LOG_FILE; exit 1; }
    rm -rf /usr/share/phpmyadmin
    mv "$PMA_DIR" /usr/share/phpmyadmin
    rm phpMyAdmin.zip
    cd - >/dev/null
    chown -R www-data:www-data /usr/share/phpmyadmin

    mysql -u rooty -p"$MYSQL_ROOT" < /usr/share/phpmyadmin/sql/create_tables.sql >> $LOG_FILE 2>&1
    mysql -u rooty -p"$MYSQL_ROOT" >> $LOG_FILE 2>&1 <<EOF
GRANT ALL PRIVILEGES ON phpmyadmin.* TO 'phpmyadmin'@'localhost' IDENTIFIED BY '$MYSQL_ROOT';
FLUSH PRIVILEGES;
EOF
    mkdir -p /var/lib/phpmyadmin/tmp
    chown www-data:www-data /var/lib/phpmyadmin/tmp

    cat > /etc/php/${PHP_VER}/fpm/pool.d/phpmyadmin.conf <<EOF
[phpmyadmin]
user = www-data
group = www-data
listen = /run/php/php${PHP_VER}-fpm-phpmyadmin.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = dynamic
pm.max_children = 5
pm.start_servers = 1
pm.min_spare_servers = 1
pm.max_spare_servers = 3
php_admin_value[open_basedir] = /usr/share/phpmyadmin/:/etc/phpmyadmin/:/var/lib/phpmyadmin/:/usr/share/php/:/usr/share/javascript/:/tmp
php_admin_value[upload_tmp_dir] = /var/lib/phpmyadmin/tmp
php_admin_value[session.save_path] = /var/lib/phpmyadmin/tmp
php_admin_value[memory_limit] = 128M
php_admin_value[max_execution_time] = 300
php_admin_value[post_max_size] = 32M
php_admin_value[upload_max_filesize] = 32M
EOF

    cat > /usr/share/phpmyadmin/config.inc.php <<EOF
<?php
\$i = 0;
\$i++;
\$cfg['Servers'][\$i]['verbose'] = '';
\$cfg['Servers'][\$i]['host'] = 'localhost';
\$cfg['Servers'][\$i]['port'] = '';
\$cfg['Servers'][\$i]['socket'] = '';
\$cfg['Servers'][\$i]['auth_type'] = 'cookie';
\$cfg['Servers'][\$i]['user'] = '';
\$cfg['Servers'][\$i]['password'] = '';
\$cfg['blowfish_secret'] = '${BLOWFISH_SECRET}';
\$cfg['DefaultLang'] = 'en';
\$cfg['ServerDefault'] = 1;
\$cfg['UploadDir'] = '';
\$cfg['SaveDir'] = '';
EOF
    chown www-data:www-data /usr/share/phpmyadmin/config.inc.php

    # Nginx admin location snippet — included from each vhost (so admin UI
    # works under every domain at /<alias>/) AND from the IP-block server.
    cat > /etc/nginx/snippets/admin-pma.conf <<EOF
# phpMyAdmin: served at /${PHPMYADMIN_DIR}
location ~ ^/${PHPMYADMIN_DIR}(?:/(.*))?\$ {
    alias /usr/share/phpmyadmin/\$1;

    location ~ \\.php\$ {
        fastcgi_pass   unix:/run/php/php${PHP_VER}-fpm-phpmyadmin.sock;
        fastcgi_index  index.php;
        fastcgi_param  SCRIPT_FILENAME \$request_filename;
        include        fastcgi_params;
    }

    location ~* \\.(css|js|png|jpg|gif|svg|woff2?)\$ {
        expires 7d;
        access_log off;
    }

    index index.php;
}

location ~ ^/${PHPMYADMIN_DIR}/(setup/lib|libraries|templates) {
    deny all;
}
EOF
else
    # ---------- phpPgAdmin ----------
    echo "Installing phpPgAdmin ${PHPPGADMIN_VER}..." | tee -a $LOG_FILE
    cd /tmp
    wget -qL "$PHPPGADMIN_URL" -O phpPgAdmin.tar.gz
    [ -s phpPgAdmin.tar.gz ] || { echo "ERROR: phpPgAdmin download failed (URL: $PHPPGADMIN_URL)" | tee -a $LOG_FILE; exit 1; }
    tar -xzf phpPgAdmin.tar.gz
    PGA_DIR=$(ls -d phpPgAdmin-* 2>/dev/null | head -1)
    [ -n "$PGA_DIR" ] && [ -d "$PGA_DIR" ] || { echo "ERROR: phpPgAdmin extraction failed" | tee -a $LOG_FILE; exit 1; }
    rm -rf /usr/share/phppgadmin
    mv "$PGA_DIR" /usr/share/phppgadmin
    rm phpPgAdmin.tar.gz
    cd - >/dev/null
    chown -R www-data:www-data /usr/share/phppgadmin

    if [ -f /usr/share/phppgadmin/conf/config.inc.php ]; then
        sed -i "s|\$conf\['servers'\]\[0\]\['host'\] = '';|\$conf['servers'][0]['host'] = 'localhost';|" \
            /usr/share/phppgadmin/conf/config.inc.php
        sed -i "s|\$conf\['extra_login_security'\] = true;|\$conf['extra_login_security'] = false;|" \
            /usr/share/phppgadmin/conf/config.inc.php
    fi

    mkdir -p /var/lib/phppgadmin/tmp
    chown www-data:www-data /var/lib/phppgadmin/tmp

    cat > /etc/php/${PHP_VER}/fpm/pool.d/phppgadmin.conf <<EOF
[phppgadmin]
user = www-data
group = www-data
listen = /run/php/php${PHP_VER}-fpm-phppgadmin.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = dynamic
pm.max_children = 5
pm.start_servers = 1
pm.min_spare_servers = 1
pm.max_spare_servers = 3
php_admin_value[open_basedir] = /usr/share/phppgadmin/:/var/lib/phppgadmin/:/usr/share/php/:/tmp
php_admin_value[upload_tmp_dir] = /var/lib/phppgadmin/tmp
php_admin_value[session.save_path] = /var/lib/phppgadmin/tmp
php_admin_value[memory_limit] = 128M
php_admin_value[max_execution_time] = 300
EOF

    cat > /etc/nginx/snippets/admin-pga.conf <<EOF
# phpPgAdmin: served at /${PHPPGADMIN_DIR}
location ~ ^/${PHPPGADMIN_DIR}(?:/(.*))?\$ {
    alias /usr/share/phppgadmin/\$1;

    location ~ \\.php\$ {
        fastcgi_pass   unix:/run/php/php${PHP_VER}-fpm-phppgadmin.sock;
        fastcgi_index  index.php;
        fastcgi_param  SCRIPT_FILENAME \$request_filename;
        include        fastcgi_params;
    }

    location ~* \\.(css|js|png|jpg|gif|svg|woff2?)\$ {
        expires 7d;
        access_log off;
    }

    index index.php;
}
EOF
fi

# =============================================================================
# Allow admin UI from IP-block server too (so /pma works on bare IP if
# Cloudflare proxies the IP). Re-render 000-default with the snippet.
# =============================================================================
ADMIN_SNIPPET=""
[ "$DATABASE" = "mariadb" ] && ADMIN_SNIPPET="include /etc/nginx/snippets/admin-pma.conf;"
[ "$DATABASE" = "pgsql"   ] && ADMIN_SNIPPET="include /etc/nginx/snippets/admin-pga.conf;"

cat > /etc/nginx/sites-available/000-default <<EOF
# Default catch-all server — admin UI accessible here, everything else 444.
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    include /etc/nginx/snippets/cloudflare-realip.conf;
    ${ADMIN_SNIPPET}

    location / { return 444; }
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    http2 on;
    server_name _;
    ssl_certificate     /etc/ssl/certs/ssl-cert-snakeoil.pem;
    ssl_certificate_key /etc/ssl/private/ssl-cert-snakeoil.key;

    include /etc/nginx/snippets/cloudflare-realip.conf;
    include /etc/nginx/snippets/security-headers.conf;
    ${ADMIN_SNIPPET}

    location / { return 444; }
}
EOF

# =============================================================================
# Test nginx config + restart
# =============================================================================
nginx -t 2>&1 | tee -a $LOG_FILE
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "ERROR: Nginx configuration test failed. Check $LOG_FILE" | tee -a $LOG_FILE
    exit 1
fi

systemctl restart php${PHP_VER}-fpm >> $LOG_FILE 2>&1
systemctl restart nginx             >> $LOG_FILE 2>&1

# =============================================================================
# MariaDB client config
# =============================================================================
if [ "$DATABASE" = "mariadb" ]; then
    cat > /etc/mysql/debian.cnf <<EOF
[client]
host     = localhost
user     = root
password = $MYSQL_ROOT
socket   = /var/run/mysqld/mysqld.sock
[mysql_upgrade]
host     = localhost
user     = root
password = $MYSQL_ROOT
socket   = /var/run/mysqld/mysqld.sock
basedir  = /usr
EOF
    chmod 600 /etc/mysql/debian.cnf

    cat > /etc/mysql/conf.d/mysql.cnf <<'EOF'
[mysql]

[mysqld]
innodb_autoinc_lock_mode=0
EOF
    chmod 644 /etc/mysql/conf.d/mysql.cnf
fi

# =============================================================================
# Composer
# =============================================================================
echo "Installing Composer..." | tee -a $LOG_FILE
cd /tmp
curl -sS https://getcomposer.org/installer -o composer-setup.php
if php composer-setup.php --quiet --install-dir=/usr/local/bin --filename=composer >> $LOG_FILE 2>&1; then
    echo "  Composer installed: $(COMPOSER_ALLOW_SUPERUSER=1 /usr/local/bin/composer --version --no-interaction --no-ansi 2>/dev/null | head -1)" | tee -a $LOG_FILE
else
    echo "  WARN: Composer install failed" | tee -a $LOG_FILE
fi
rm -f composer-setup.php
cd - >/dev/null

# =============================================================================
# Save state
# =============================================================================
{
    echo "# Generated by web_server_script — do not edit by hand"
    echo "WEB_SERVER=nginx"
    echo "DATABASE=$DATABASE"
    echo "PHP_VER=$PHP_VER"
    [ "$DATABASE" = "mariadb" ] && echo "PHPMYADMIN_DIR=$PHPMYADMIN_DIR"
    [ "$DATABASE" = "pgsql"   ] && echo "PHPPGADMIN_DIR=$PHPPGADMIN_DIR"
    echo "INSTALLED_AT=$(date -u +%FT%TZ)"
} > "$STATE_FILE"
chmod 644 "$STATE_FILE"

echo ""
echo "============================================================"
echo " Installation completed successfully!"
echo "============================================================"
echo ""
echo "OS              : $PRETTY_NAME"
echo "Web server      : Nginx (HTTP/2 enabled)"
echo "PHP-FPM         : ${PHP_VER}"
echo "Database        : ${DATABASE}"
echo "Cloudflare IPs  : set_real_ip_from configured (snippets/cloudflare-realip.conf)"
if [ "$DATABASE" = "mariadb" ]; then
    echo "phpMyAdmin URL  : http://<server>/${PHPMYADMIN_DIR}"
else
    echo "phpPgAdmin URL  : http://<server>/${PHPPGADMIN_DIR}"
fi
echo "State file      : $STATE_FILE"
echo ""
echo "Next: add a site with nginx/add-site.sh"
echo ""
