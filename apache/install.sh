#!/bin/bash
# =============================================================================
# Apache Web Server Setup Script (PHP-FPM + DB choice)
#
# Stack: Apache 2.4 (MPM Event) + PHP-FPM + (MariaDB|PostgreSQL) +
#        DB admin UI (phpMyAdmin|Adminer for MariaDB; Adminer|pgAdmin4 for PG) +
#        HTTP/2 + mod_remoteip (Cloudflare)
#
# Supported distributions:
#   - Debian 12 (bookworm)        — uses sury.org repo for PHP 8.4
#   - Debian 13 (trixie)          — uses native repo (PHP 8.4 in main)
#   - Ubuntu 22.04 (jammy)        — uses ondrej/php PPA for PHP 8.4
#   - Ubuntu 24.04 (noble)        — uses ondrej/php PPA for PHP 8.4
#   - Ubuntu 26.04 (resolute) LTS — uses ondrej/php PPA for PHP 8.4 (native = 8.5)
#                                   If PPA does not yet list 'resolute', re-run
#                                   with PHP_VER=8.5 to use the native package set.
#
# Quick install (interactive):
#   bash <(curl -fsSL https://raw.githubusercontent.com/DaveBugg/web_server_script/main/apache/install.sh)
#
# Non-interactive (env vars):
#   curl -fsSL .../install.sh | \
#     DATABASE=mariadb MYSQL_ROOT='Pass!' DB_UI=phpmyadmin PHPMYADMIN_DIR='myadmin' bash
#   curl -fsSL .../install.sh | \
#     DATABASE=pgsql PG_PASS='Pass!' DB_UI=adminer ADMINER_DIR='myadm' bash
#   curl -fsSL .../install.sh | \
#     DATABASE=pgsql PG_PASS='Pass!' DB_UI=pgadmin4 PGADMIN4_DIR='pga' \
#     PGADMIN4_EMAIL='admin@example.com' PGADMIN4_PASS='Pass!' bash
#
# Override PHP version: PHP_VER=8.5 ...
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
# Detect distribution & codename
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
# Database choice & input collection
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
#   - pgsql:   Adminer (default, single PHP file) OR pgAdmin4 (full-featured, mod_wsgi)
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
echo " Web server install — version 4.2 (Apache stack)"
echo " Detected: $PRETTY_NAME ($DISTRO_CODENAME)"
echo " Target  : Apache + PHP-FPM ${PHP_VER} + ${DATABASE} +"
echo "           ${DB_UI} + HTTP/2 + mod_remoteip"
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
# System update and prerequisites
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
# Add PHP repository (only if not in native repos)
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

if [ "$NEED_THIRD_PARTY_REPO" = true ]; then
    apt-get update -y >> $LOG_FILE 2>&1
fi

if ! apt-cache show php${PHP_VER}-fpm >/dev/null 2>&1; then
    echo "ERROR: php${PHP_VER}-fpm not available after repo setup." | tee -a $LOG_FILE
    echo "Try: PHP_VER=<other-version> bash $0" | tee -a $LOG_FILE
    exit 1
fi

# =============================================================================
# Install main packages
# =============================================================================
echo "Installing main packages..." | tee -a $LOG_FILE
apt_install "utilities" mc screen fail2ban ssl-cert || exit 1
apt_install "apache2" apache2 curl unzip || exit 1

apt-get purge -y rpcbind 2>/dev/null || true

# =============================================================================
# Database server install
# =============================================================================
if [ "$DATABASE" = "mariadb" ]; then
    apt_install "mariadb-server" mariadb-server || exit 1
else
    apt_install "postgresql" postgresql postgresql-contrib || exit 1
fi

# =============================================================================
# PHP-FPM installation (mysql + pgsql modules — both, regardless of DB choice)
# =============================================================================
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

# =============================================================================
# Configure Apache for PHP-FPM and HTTP/2
# =============================================================================
echo "Configuring Apache for PHP-FPM and HTTP/2..." | tee -a $LOG_FILE

a2dismod mpm_prefork >> $LOG_FILE 2>&1 || true
a2enmod  mpm_event   >> $LOG_FILE 2>&1
a2enmod  rewrite     >> $LOG_FILE 2>&1
a2enmod  proxy       >> $LOG_FILE 2>&1
a2enmod  proxy_fcgi  >> $LOG_FILE 2>&1
a2enmod  setenvif    >> $LOG_FILE 2>&1
a2enmod  ssl         >> $LOG_FILE 2>&1
a2enmod  http2       >> $LOG_FILE 2>&1
a2enmod  headers     >> $LOG_FILE 2>&1

a2enconf php${PHP_VER}-fpm >> $LOG_FILE 2>&1

systemctl enable php${PHP_VER}-fpm >> $LOG_FILE 2>&1
systemctl start  php${PHP_VER}-fpm >> $LOG_FILE 2>&1

# =============================================================================
# Configure database server
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
    echo "MariaDB configuration completed." | tee -a $LOG_FILE
else
    echo "Configuring PostgreSQL server..." | tee -a $LOG_FILE
    sudo -u postgres psql >> $LOG_FILE 2>&1 <<EOF
ALTER USER postgres WITH PASSWORD '$PG_PASS';
EOF
    if [ $? -ne 0 ]; then
        echo "ERROR: Failed to set postgres password. Aborting." | tee -a $LOG_FILE
        exit 1
    fi
    # Allow scram-sha-256 password auth over local TCP so Adminer (PHP) can log in.
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
    echo "PostgreSQL configuration completed." | tee -a $LOG_FILE
fi

# =============================================================================
# Install web admin UI — phpMyAdmin (MariaDB) | Adminer (any DB) | pgAdmin4 (PG)
# =============================================================================
if [ "$DB_UI" = "phpmyadmin" ]; then
    # ---------- phpMyAdmin ----------
    echo "Installing phpMyAdmin (latest) with PHP-FPM support..." | tee -a $LOG_FILE
    cd /tmp
    wget -q "$PHPMYADMIN_URL" -O phpMyAdmin.zip
    if [ ! -s phpMyAdmin.zip ]; then
        echo "ERROR: phpMyAdmin download failed" | tee -a $LOG_FILE
        exit 1
    fi
    unzip -q phpMyAdmin.zip
    PMA_DIR=$(ls -d phpMyAdmin-*-all-languages 2>/dev/null | head -1)
    if [ -z "$PMA_DIR" ] || [ ! -d "$PMA_DIR" ]; then
        echo "ERROR: phpMyAdmin extraction failed" | tee -a $LOG_FILE
        exit 1
    fi
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

    cat > /etc/apache2/conf-available/phpmyadmin.conf <<EOF
# phpMyAdmin Apache configuration for PHP-FPM
Alias /$PHPMYADMIN_DIR /usr/share/phpmyadmin

<Directory /usr/share/phpmyadmin>
    Options SymLinksIfOwnerMatch
    DirectoryIndex index.php
    AllowOverride All
    Require all granted

    <FilesMatch "\.php\$">
        SetHandler "proxy:unix:/run/php/php${PHP_VER}-fpm-phpmyadmin.sock|fcgi://localhost"
    </FilesMatch>
</Directory>

<Directory /usr/share/phpmyadmin/templates>
    Require all denied
</Directory>
<Directory /usr/share/phpmyadmin/libraries>
    Require all denied
</Directory>
<Directory /usr/share/phpmyadmin/setup/lib>
    Require all denied
</Directory>
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
    a2enconf phpmyadmin >> $LOG_FILE 2>&1
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
    # index.php symlink so /<alias>/ resolves the UI
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

    cat > /etc/apache2/conf-available/adminer.conf <<EOF
# Adminer Apache configuration for PHP-FPM
Alias /$ADMINER_DIR /usr/share/adminer

<Directory /usr/share/adminer>
    Options SymLinksIfOwnerMatch
    DirectoryIndex index.php
    AllowOverride None
    Require all granted

    <FilesMatch "\.php\$">
        SetHandler "proxy:unix:/run/php/php${PHP_VER}-fpm-adminer.sock|fcgi://localhost"
    </FilesMatch>
</Directory>
EOF
    a2enconf adminer >> $LOG_FILE 2>&1
else
    # ---------- pgAdmin4 (Apache + mod_wsgi) ----------
    # Installed from the official pgadmin.org apt repo. The 'pgadmin4-web'
    # metapackage pulls in pgadmin4-server + libapache2-mod-wsgi-py3 and ships
    # a setup-web.sh that initialises the SQLite metadata DB and registers an
    # Apache conf at /etc/apache2/conf-available/pgadmin4.conf. We run it
    # non-interactively (PGADMIN_SETUP_EMAIL/PASSWORD env vars + --yes), then
    # overwrite that conf so the alias matches the user-chosen $PGADMIN4_DIR
    # instead of the default /pgadmin4.
    echo "Installing pgAdmin4 (apt repo + mod_wsgi)..." | tee -a $LOG_FILE

    # pgadmin.org apt repo only publishes a subset of distro codenames. Map
    # newer/unsupported releases to the closest published codename.
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

    apt_install "pgadmin4-web" pgadmin4-web || exit 1

    # Run the bundled setup script. PGADMIN_SETUP_EMAIL/PASSWORD are read by
    # /usr/pgadmin4/web/setup.py to create the first admin user; --yes skips
    # all interactive prompts (incl. the 'configure Apache?' question).
    PGADMIN_SETUP_EMAIL="$PGADMIN4_EMAIL" \
    PGADMIN_SETUP_PASSWORD="$PGADMIN4_PASS" \
        /usr/pgadmin4/bin/setup-web.sh --yes >> $LOG_FILE 2>&1 || {
            echo "ERROR: pgAdmin4 setup-web.sh failed (see $LOG_FILE)" | tee -a $LOG_FILE
            exit 1
        }

    # Override the /pgadmin4 alias setup-web.sh just dropped in.
    cat > /etc/apache2/conf-available/pgadmin4.conf <<EOF
# pgAdmin4 served at /${PGADMIN4_DIR} (overrides setup-web.sh default of /pgadmin4)
WSGIDaemonProcess pgadmin processes=1 threads=25 python-home=/usr/pgadmin4/venv
WSGIScriptAlias /${PGADMIN4_DIR} /usr/pgadmin4/web/pgAdmin4.wsgi

<Directory /usr/pgadmin4/web/>
    WSGIProcessGroup pgadmin
    WSGIApplicationGroup %{GLOBAL}
    Require all granted
</Directory>
EOF
    a2enconf pgadmin4 >> $LOG_FILE 2>&1
fi

# =============================================================================
# Apache main configuration
# =============================================================================
cat > /etc/apache2/apache2.conf <<'APACHEEOF'
ServerRoot "/etc/apache2"
DefaultRuntimeDir ${APACHE_RUN_DIR}
PidFile ${APACHE_PID_FILE}
Timeout 300
KeepAlive On
MaxKeepAliveRequests 100
KeepAliveTimeout 5

User ${APACHE_RUN_USER}
Group ${APACHE_RUN_GROUP}

HostnameLookups Off
ErrorLog ${APACHE_LOG_DIR}/error.log
LogLevel warn

IncludeOptional mods-enabled/*.load
IncludeOptional mods-enabled/*.conf

Include ports.conf

<Directory />
    Options FollowSymLinks
    AllowOverride All
</Directory>

<Directory /usr/share>
    AllowOverride None
    Require all granted
</Directory>

<Directory /var/www/>
    Options Indexes FollowSymLinks
    AllowOverride All
    Require all granted
</Directory>

<Directory /www>
    Options FollowSymLinks
    AllowOverride All
    Require all granted
</Directory>

AccessFileName .htaccess

<FilesMatch "^\.ht">
    Require all denied
</FilesMatch>

LogFormat "%v:%p %a %l %u %t \"%r\" %>s %O \"%{Referer}i\" \"%{User-Agent}i\"" vhost_combined
LogFormat "%a %l %u %t \"%r\" %>s %O \"%{Referer}i\" \"%{User-Agent}i\"" combined
LogFormat "%a %l %u %t \"%r\" %>s %O" common
LogFormat "%{Referer}i -> %U" referer
LogFormat "%{User-agent}i" agent

IncludeOptional conf-enabled/*.conf
IncludeOptional sites-enabled/*.conf
APACHEEOF

cat > /etc/apache2/conf-available/security.conf <<'EOF'
ServerTokens Prod
ServerSignature Off
TraceEnable Off
EOF

cat > /etc/apache2/mods-available/mpm_event.conf <<'EOF'
<IfModule mpm_event_module>
    StartServers              4
    MinSpareThreads          25
    MaxSpareThreads          75
    ThreadLimit              64
    ThreadsPerChild          25
    MaxRequestWorkers       400
    MaxConnectionsPerChild 1000
    ServerLimit              16
    AsyncRequestWorkerFactor  2
</IfModule>
EOF

cat > /etc/apache2/conf-available/http2.conf <<'EOF'
Protocols h2 http/1.1

<IfModule mod_http2.c>
    H2Direct on
    H2Upgrade on
    H2StreamMaxMemSize 65536
    H2MaxSessionStreams 100
    H2MaxWorkers 400
    H2WindowSize 65535
</IfModule>
EOF
a2enconf http2 >> $LOG_FILE 2>&1

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
# Cloudflare mod_remoteip
# =============================================================================
echo "Configuring mod_remoteip for Cloudflare..." | tee -a $LOG_FILE
a2enmod remoteip >> $LOG_FILE 2>&1

CF_IPV4=$(curl -s --max-time 10 https://www.cloudflare.com/ips-v4 || true)
CF_IPV6=$(curl -s --max-time 10 https://www.cloudflare.com/ips-v6 || true)

{
    echo "# Cloudflare real-IP via mod_remoteip"
    echo "RemoteIPHeader CF-Connecting-IP"
    echo ""
    if [ -n "$CF_IPV4" ]; then
        echo "$CF_IPV4" | while read -r ip; do
            [ -n "$ip" ] && echo "RemoteIPTrustedProxy $ip"
        done
    fi
    if [ -n "$CF_IPV6" ]; then
        echo "$CF_IPV6" | while read -r ip; do
            [ -n "$ip" ] && echo "RemoteIPTrustedProxy $ip"
        done
    fi
} > /etc/apache2/conf-available/cloudflare.conf

a2enconf cloudflare >> $LOG_FILE 2>&1
a2enconf security   >> $LOG_FILE 2>&1

# =============================================================================
# Test config + restart
# =============================================================================
apache2ctl configtest 2>&1 | tee -a $LOG_FILE
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "ERROR: Apache configuration test failed. Check $LOG_FILE" | tee -a $LOG_FILE
    exit 1
fi

systemctl restart php${PHP_VER}-fpm >> $LOG_FILE 2>&1
systemctl restart apache2           >> $LOG_FILE 2>&1

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
# Save state for other action scripts
# =============================================================================
{
    echo "# Generated by web_server_script — do not edit by hand"
    echo "WEB_SERVER=apache"
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

# =============================================================================
echo ""
echo "============================================================"
echo " Installation completed successfully!"
echo "============================================================"
echo ""
echo "OS              : $PRETTY_NAME"
echo "Web server      : Apache (MPM Event, HTTP/2)"
echo "PHP-FPM         : ${PHP_VER}"
echo "Database        : ${DATABASE}"
echo "DB Admin UI     : ${DB_UI}"
echo "Cloudflare IPs  : mod_remoteip configured"
echo "Admin URL       : http://<server>/${DB_UI_DIR}"
if [ "$DB_UI" = "pgadmin4" ]; then
    echo "pgAdmin4 login  : ${PGADMIN4_EMAIL}"
    echo "pgAdmin4 pass   : ${PGADMIN4_PASS}"
    [ "${PGADMIN4_PASS_GENERATED:-no}" = "yes" ] && \
        echo "                  (auto-generated — copy this NOW, it's not stored anywhere else)"
fi
echo "State file      : $STATE_FILE"
echo ""
echo "Next: add a site with apache/add-site.sh"
echo ""
