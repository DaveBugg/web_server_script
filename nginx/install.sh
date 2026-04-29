#!/bin/bash
# =============================================================================
# Nginx Web Server Setup Script (PHP-FPM + DB choice)
#
# Stack: Nginx + PHP-FPM + (MariaDB|PostgreSQL) +
#        DB admin UI (phpMyAdmin|Adminer for MariaDB; Adminer|pgAdmin4 for PG) +
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
#     DATABASE=mariadb MYSQL_ROOT='Pass!' DB_UI=phpmyadmin PHPMYADMIN_DIR='myadmin' bash
#   curl -fsSL .../install.sh | \
#     DATABASE=pgsql PG_PASS='Pass!' DB_UI=adminer ADMINER_DIR='myadm' bash
#   curl -fsSL .../install.sh | \
#     DATABASE=pgsql PG_PASS='Pass!' DB_UI=pgadmin4 PGADMIN4_DIR='pga' \
#     PGADMIN4_EMAIL='admin@example.com' PGADMIN4_PASS='Pass!' bash
#
# Version: 4.2
# =============================================================================

set -u
set -o pipefail
LOG_FILE="install.log"
PHP_VER="${PHP_VER:-8.4}"
PHPMYADMIN_URL="https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-all-languages.zip"
ADMINER_URL="https://www.adminer.org/latest.php"
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

# Choice of web admin UI:
#   - mariadb: phpMyAdmin (default) OR Adminer
#   - pgsql:   Adminer (default, single PHP file) OR pgAdmin4 (gunicorn + reverse proxy)
if [ "$DATABASE" = "mariadb" ]; then
    ask DB_UI "DB admin UI [phpmyadmin|adminer]: "
    DB_UI=$(echo "${DB_UI:-phpmyadmin}" | tr '[:upper:]' '[:lower:]')
    case "$DB_UI" in
        phpmyadmin|pma) DB_UI=phpmyadmin ;;
        adminer)        DB_UI=adminer ;;
        *) echo "ERROR: unknown DB_UI='$DB_UI' (use 'phpmyadmin' or 'adminer')"; exit 1 ;;
    esac
else
    ask DB_UI "DB admin UI [adminer|pgadmin4]: "
    DB_UI=$(echo "${DB_UI:-adminer}" | tr '[:upper:]' '[:lower:]')
    case "$DB_UI" in
        adminer)          DB_UI=adminer ;;
        pgadmin4|pgadmin) DB_UI=pgadmin4 ;;
        *) echo "ERROR: unknown DB_UI='$DB_UI' (use 'adminer' or 'pgadmin4')"; exit 1 ;;
    esac
fi

echo "============================================================"
echo " Web server install — version 4.2 (Nginx stack)"
echo " Detected: $PRETTY_NAME ($DISTRO_CODENAME)"
echo " Target  : Nginx + PHP-FPM ${PHP_VER} + ${DATABASE} +"
echo "           ${DB_UI} + HTTP/2 + Cloudflare real-IP"
echo "============================================================"

if [ "$DATABASE" = "mariadb" ]; then
    ask MYSQL_ROOT "Enter password for MariaDB root user: "
    [ -z "${MYSQL_ROOT:-}" ] && { echo "Password can't be blank"; exit 1; }
else
    ask PG_PASS "Enter password for PostgreSQL 'postgres' user: "
    [ -z "${PG_PASS:-}" ] && { echo "Password can't be blank"; exit 1; }
fi

case "$DB_UI" in
    phpmyadmin)
        ask PHPMYADMIN_DIR "Enter phpMyAdmin path alias: "
        [ -z "${PHPMYADMIN_DIR:-}" ] && { echo "phpMyAdmin alias can't be blank"; exit 1; }
        DB_UI_DIR="$PHPMYADMIN_DIR"
        ;;
    adminer)
        ask ADMINER_DIR "Enter Adminer path alias: "
        [ -z "${ADMINER_DIR:-}" ] && { echo "Adminer alias can't be blank"; exit 1; }
        DB_UI_DIR="$ADMINER_DIR"
        ;;
    pgadmin4)
        ask PGADMIN4_DIR "Enter pgAdmin4 path alias: "
        [ -z "${PGADMIN4_DIR:-}" ] && { echo "pgAdmin4 alias can't be blank"; exit 1; }
        DB_UI_DIR="$PGADMIN4_DIR"
        ask PGADMIN4_EMAIL "Enter pgAdmin4 admin email: "
        [ -z "${PGADMIN4_EMAIL:-}" ] && { echo "pgAdmin4 email can't be blank"; exit 1; }
        ask PGADMIN4_PASS "Enter pgAdmin4 admin password (blank = auto-generate): "
        if [ -z "${PGADMIN4_PASS:-}" ]; then
            PGADMIN4_PASS=$(openssl rand -base64 18 2>/dev/null | tr -d '/+=' | head -c 24)
            PGADMIN4_PASS_GENERATED=yes
            echo "  pgAdmin4 password (auto-generated): $PGADMIN4_PASS"
        fi
        ;;
esac

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
    if ! systemctl is-active mariadb >/dev/null 2>&1; then
        echo "  MariaDB inactive after install — reinitialising data dir..." | tee -a $LOG_FILE
        mysql_install_db --user=mysql --basedir=/usr --datadir=/var/lib/mysql >> $LOG_FILE 2>&1 || true
        systemctl enable mariadb >> $LOG_FILE 2>&1
        systemctl start  mariadb >> $LOG_FILE 2>&1
    fi
else
    apt_install "postgresql" postgresql postgresql-contrib || exit 1
    if ! systemctl is-active postgresql >/dev/null 2>&1; then
        echo "  PostgreSQL inactive after install — reinitialising cluster..." | tee -a $LOG_FILE
        PG_VER=$(dpkg -l 'postgresql-[0-9]*' 2>/dev/null | awk '/^ii/{print $2}' | grep -oE '[0-9]+$' | sort -n | tail -1)
        [ -n "$PG_VER" ] && pg_createcluster "$PG_VER" main --start >> $LOG_FILE 2>&1 || true
    fi
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

# Use the legacy `listen ... ssl http2;` syntax — works on Nginx 1.18+ (Debian 12)
# AND on Nginx 1.25+ (just emits a deprecation warning). The new `http2 on;`
# directive is 1.25+ only and would error on older nginx.
cat > /etc/nginx/sites-available/000-default <<EOF
# Default catch-all: drop bare-IP HTTP/HTTPS requests
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;
    return 444;
}

server {
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
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
# Install web admin UI — phpMyAdmin (MariaDB) | Adminer (any DB) | pgAdmin4 (PG)
# =============================================================================
if [ "$DB_UI" = "phpmyadmin" ]; then
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
    #
    # Pattern: prefix-location with `alias` for the dir, then a NESTED regex
    # location that captures the file path into \$1 and aliases each PHP file
    # individually. This is the only reliable way to combine `alias` + PHP-FPM
    # in nginx — the more obvious `location ~ ^/<alias>/(.*)` pattern breaks
    # \$request_filename and FPM gets "Primary script unknown".
    cat > /etc/nginx/snippets/admin-ui.conf <<EOF
# phpMyAdmin: served at /${PHPMYADMIN_DIR}
location /${PHPMYADMIN_DIR} {
    alias /usr/share/phpmyadmin/;
    index index.php;

    location ~ ^/${PHPMYADMIN_DIR}/(.+\\.php)\$ {
        alias /usr/share/phpmyadmin/\$1;
        fastcgi_pass  unix:/run/php/php${PHP_VER}-fpm-phpmyadmin.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$request_filename;
        include       fastcgi_params;
    }

    location ~ ^/${PHPMYADMIN_DIR}/(.+\\.(css|js|png|jpg|gif|svg|woff2?))\$ {
        alias /usr/share/phpmyadmin/\$1;
        expires 7d;
        access_log off;
    }

    location ~ ^/${PHPMYADMIN_DIR}/(setup/lib|libraries|templates) {
        deny all;
    }
}
EOF
elif [ "$DB_UI" = "adminer" ]; then
    # ---------- Adminer ----------
    # Single PHP file — supports MySQL/MariaDB, PostgreSQL, SQLite, MSSQL, Oracle.
    # Active dev (5.x line, 2024+), drop-in replacement for phpMyAdmin and the
    # only sensible web UI for PostgreSQL after phpPgAdmin went stale (max PG13).
    echo "Installing Adminer (latest single-file release)..." | tee -a $LOG_FILE
    rm -rf /usr/share/adminer
    mkdir -p /usr/share/adminer
    if ! wget -qL "$ADMINER_URL" -O /usr/share/adminer/adminer.php; then
        echo "ERROR: Adminer download failed (URL: $ADMINER_URL)" | tee -a $LOG_FILE
        exit 1
    fi
    if [ ! -s /usr/share/adminer/adminer.php ]; then
        echo "ERROR: Adminer file is empty after download" | tee -a $LOG_FILE
        exit 1
    fi
    ln -sf adminer.php /usr/share/adminer/index.php
    chown -R www-data:www-data /usr/share/adminer

    cat > /etc/php/${PHP_VER}/fpm/pool.d/adminer.conf <<EOF
[adminer]
user = www-data
group = www-data
listen = /run/php/php${PHP_VER}-fpm-adminer.sock
listen.owner = www-data
listen.group = www-data
listen.mode = 0660
pm = dynamic
pm.max_children = 5
pm.start_servers = 1
pm.min_spare_servers = 1
pm.max_spare_servers = 3
php_admin_value[open_basedir] = /usr/share/adminer/:/usr/share/php/:/tmp
php_admin_value[memory_limit] = 128M
php_admin_value[max_execution_time] = 300
php_admin_value[post_max_size] = 32M
php_admin_value[upload_max_filesize] = 32M
EOF

    # Adminer is a single .php file — simpler nginx pattern. Same alias+nested
    # location used for phpMyAdmin works just as well, so we keep it consistent.
    cat > /etc/nginx/snippets/admin-ui.conf <<EOF
# Adminer: served at /${ADMINER_DIR}
location /${ADMINER_DIR} {
    alias /usr/share/adminer/;
    index index.php;

    location ~ ^/${ADMINER_DIR}/(.+\\.php)\$ {
        alias /usr/share/adminer/\$1;
        fastcgi_pass  unix:/run/php/php${PHP_VER}-fpm-adminer.sock;
        fastcgi_index index.php;
        fastcgi_param SCRIPT_FILENAME \$request_filename;
        include       fastcgi_params;
    }
}
EOF
else
    # ---------- pgAdmin4 (Nginx + gunicorn over unix socket) ----------
    # Apache uses pgadmin4-web (mod_wsgi) — but that pulls apache2 as a hard
    # dependency. For Nginx we install pgadmin4-server (the same /usr/pgadmin4
    # tree, just without the apache wsgi conf), then run it under gunicorn as
    # a systemd unit and reverse-proxy from nginx via a unix socket.
    #
    # Sub-path mounting (the past pain point — login bouncing back to /login):
    # we set APPLICATION_ROOT in /etc/pgadmin/config_system.py AND pass
    # X-Script-Name through the proxy so flask-login generates correct cookie
    # paths and CSRF tokens.
    echo "Installing pgAdmin4 (apt repo + gunicorn + nginx reverse proxy)..." | tee -a $LOG_FILE

    # pgadmin.org apt repo only publishes a subset of distro codenames.
    PGADMIN_CODENAME="$DISTRO_CODENAME"
    case "$DISTRO_ID:$DISTRO_VER" in
        debian:13)    PGADMIN_CODENAME="bookworm" ;;
        ubuntu:26.04) PGADMIN_CODENAME="noble" ;;
    esac

    install -d -m 0755 /usr/share/keyrings
    if ! curl -fsSL https://www.pgadmin.org/static/packages_pgadmin_org.pub \
            | gpg --dearmor -o /usr/share/keyrings/pgadmin4-archive-keyring.gpg 2>>$LOG_FILE; then
        echo "ERROR: failed to fetch pgAdmin4 GPG key" | tee -a $LOG_FILE
        exit 1
    fi
    echo "deb [signed-by=/usr/share/keyrings/pgadmin4-archive-keyring.gpg] https://ftp.postgresql.org/pub/pgadmin/pgadmin4/apt/${PGADMIN_CODENAME} pgadmin4 main" \
        > /etc/apt/sources.list.d/pgadmin4.list
    apt-get update -y >> $LOG_FILE 2>&1

    # Pre-create /etc/pgadmin/config_system.py BEFORE installing pgadmin4-server
    # so the package postinst sees our DATA_DIR, APPLICATION_ROOT, etc. The
    # postinst will run setup-db + create the admin user using PGADMIN_SETUP_*
    # env vars; if those are unset it would prompt interactively (and hang).
    install -d -m 0755 /etc/pgadmin
    cat > /etc/pgadmin/config_system.py <<EOF
import os
SERVER_MODE = True
DATA_DIR = '/var/lib/pgadmin'
LOG_FILE = '/var/log/pgadmin/pgadmin4.log'
SQLITE_PATH = os.path.join(DATA_DIR, 'pgadmin4.db')
SESSION_DB_PATH = os.path.join(DATA_DIR, 'sessions')
STORAGE_DIR = os.path.join(DATA_DIR, 'storage')
DEFAULT_BINARY_PATHS = {'pg': '/usr/bin'}
APPLICATION_ROOT = '/${PGADMIN4_DIR}'
SESSION_COOKIE_PATH = '/${PGADMIN4_DIR}'
EOF

    install -d -m 0750 -o www-data -g www-data /var/lib/pgadmin
    install -d -m 0750 -o www-data -g www-data /var/lib/pgadmin/sessions
    install -d -m 0750 -o www-data -g www-data /var/lib/pgadmin/storage
    install -d -m 0750 -o www-data -g www-data /var/log/pgadmin

    # pgAdmin4 hardcodes its db backup path as DATA_DIR/../pgadmin4.db.bak
    # (i.e. /var/lib/pgadmin4.db.bak). www-data can't write to /var/lib/, so
    # pre-create the backup file with the right ownership — shutil.copyfile
    # can overwrite an existing writable file even when its parent dir is not.
    touch /var/lib/pgadmin4.db.bak
    chown www-data:www-data /var/lib/pgadmin4.db.bak
    chmod 0640 /var/lib/pgadmin4.db.bak

    # pgadmin4-server = pgAdmin web app + bundled venv at /usr/pgadmin4/venv,
    # WITHOUT apache2 / mod_wsgi as dependencies.
    #
    # The pgAdmin code (specifically migrations/versions/fdc58d9bd449_.py via
    # user_info.user_info_server) reads PGADMIN_SETUP_EMAIL/PASSWORD env vars
    # to provision the first admin user; if either is unset it calls input()
    # which blocks under apt and EOFErrors under gunicorn. Export them before
    # apt_install so the package's setup phase picks them up, then re-pass
    # them to setup-db (which runs the migrations explicitly).
    export PGADMIN_SETUP_EMAIL="$PGADMIN4_EMAIL"
    export PGADMIN_SETUP_PASSWORD="$PGADMIN4_PASS"
    apt_install "pgadmin4-server" pgadmin4-server || {
        unset PGADMIN_SETUP_EMAIL PGADMIN_SETUP_PASSWORD; exit 1; }

    sudo -u www-data \
        PGADMIN_SETUP_EMAIL="$PGADMIN4_EMAIL" \
        PGADMIN_SETUP_PASSWORD="$PGADMIN4_PASS" \
        PYTHONPATH=/usr/pgadmin4/web \
        /usr/pgadmin4/venv/bin/python3 /usr/pgadmin4/web/setup.py setup-db >> $LOG_FILE 2>&1 || {
            unset PGADMIN_SETUP_EMAIL PGADMIN_SETUP_PASSWORD
            echo "ERROR: pgAdmin4 setup-db failed (see $LOG_FILE)" | tee -a $LOG_FILE
            exit 1
        }

    unset PGADMIN_SETUP_EMAIL PGADMIN_SETUP_PASSWORD

    # Gunicorn lives in the bundled venv so it picks up the right Python deps.
    /usr/pgadmin4/venv/bin/pip install --quiet gunicorn >> $LOG_FILE 2>&1 || {
        echo "ERROR: failed to install gunicorn into pgadmin4 venv" | tee -a $LOG_FILE
        exit 1
    }

    cat > /etc/systemd/system/pgadmin4.service <<EOF
[Unit]
Description=pgAdmin4 (gunicorn behind nginx)
After=network.target postgresql.service
Wants=postgresql.service

[Service]
Type=simple
User=www-data
Group=www-data
RuntimeDirectory=pgadmin4
RuntimeDirectoryMode=0755
WorkingDirectory=/usr/pgadmin4/web
Environment=PYTHONPATH=/usr/pgadmin4/web
Environment=HOME=/var/lib/pgadmin
ExecStart=/usr/pgadmin4/venv/bin/gunicorn \\
    --workers 2 --threads 25 \\
    --bind unix:/run/pgadmin4/socket \\
    --umask 0007 \\
    --access-logfile /var/log/pgadmin/access.log \\
    --error-logfile /var/log/pgadmin/error.log \\
    pgAdmin4:app
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now pgadmin4 >> $LOG_FILE 2>&1 || {
        echo "ERROR: failed to start pgadmin4.service (see journalctl -u pgadmin4)" | tee -a $LOG_FILE
        exit 1
    }

    # nginx vhost-included snippet. Note the trailing slash on proxy_pass
    # (`...:/`): combined with the trailing slash in `location /<dir>/` it
    # strips the prefix before forwarding so gunicorn sees `/login` not
    # `/<dir>/login` — and APPLICATION_ROOT + X-Script-Name handle URL
    # generation back to the client.
    cat > /etc/nginx/snippets/admin-ui.conf <<EOF
# pgAdmin4: served at /${PGADMIN4_DIR}
location = /${PGADMIN4_DIR} { return 301 /${PGADMIN4_DIR}/; }
location /${PGADMIN4_DIR}/ {
    proxy_pass http://unix:/run/pgadmin4/socket:/;
    proxy_set_header Host \$http_host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Script-Name /${PGADMIN4_DIR};
    proxy_redirect off;
    proxy_buffering off;
    client_max_body_size 50M;
}
EOF
fi

# =============================================================================
# Allow admin UI from IP-block server too (so /<alias> works on bare IP if
# Cloudflare proxies the IP). Re-render 000-default with the snippet.
# =============================================================================
ADMIN_SNIPPET="include /etc/nginx/snippets/admin-ui.conf;"

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
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
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
    echo "DB_UI=$DB_UI"
    echo "DB_UI_DIR=$DB_UI_DIR"
    echo "PHP_VER=$PHP_VER"
    [ "$DB_UI" = "phpmyadmin" ] && echo "PHPMYADMIN_DIR=$PHPMYADMIN_DIR"
    [ "$DB_UI" = "adminer" ]    && echo "ADMINER_DIR=$ADMINER_DIR"
    if [ "$DB_UI" = "pgadmin4" ]; then
        echo "PGADMIN4_DIR=$PGADMIN4_DIR"
        echo "PGADMIN4_EMAIL=$PGADMIN4_EMAIL"
    fi
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
echo "DB Admin UI     : ${DB_UI}"
echo "Cloudflare IPs  : set_real_ip_from configured (snippets/cloudflare-realip.conf)"
echo "Admin URL       : http://<server>/${DB_UI_DIR}"
if [ "$DB_UI" = "pgadmin4" ]; then
    echo "pgAdmin4 login  : ${PGADMIN4_EMAIL}"
    echo "pgAdmin4 pass   : ${PGADMIN4_PASS}"
    [ "${PGADMIN4_PASS_GENERATED:-no}" = "yes" ] && \
        echo "                  (auto-generated — copy this NOW, it's not stored anywhere else)"
fi
echo "State file      : $STATE_FILE"
echo ""
echo "Next: add a site with nginx/add-site.sh"
echo ""
