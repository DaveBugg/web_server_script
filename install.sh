#!/bin/bash
# =============================================================================
# Universal Web Server Setup Script
# Apache + PHP-FPM 8.4 + MariaDB + phpMyAdmin + HTTP/2 + mod_remoteip (Cloudflare)
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
#   bash <(curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/install.sh)
#
# Non-interactive (env vars):
#   curl -fsSL https://.../install.sh | \
#     MYSQL_ROOT='SecurePass!' PHPMYADMIN_DIR='myadmin' bash
#
# Override PHP version: PHP_VER=8.5 ...
#
# Version: 3.2
# =============================================================================

set -u
set -o pipefail
LOG_FILE="install.log"
PHP_VER="${PHP_VER:-8.4}"
PHPMYADMIN_URL="https://www.phpmyadmin.net/downloads/phpMyAdmin-latest-all-languages.zip"

# Open fd 3 from /dev/tty so prompts work even when piped (curl | bash).
# Falls back to fd 0 if /dev/tty is unavailable (e.g. CI without a tty).
if [ -e /dev/tty ]; then
    exec 3</dev/tty
else
    exec 3<&0
fi

# Helper: prompt user, supports env-var override (non-interactive mode)
ask() {
    local var="$1" msg="$2"
    local current="${!var:-}"
    if [ -n "$current" ]; then
        echo "$msg$current  [from env]"
        return 0
    fi
    read -u 3 -r -p "$msg" "$var"
}

# Helper: run apt-get install with retry and verification
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

echo "============================================================"
echo " Web server install — version 3.2"
echo " Detected: $PRETTY_NAME ($DISTRO_CODENAME)"
echo " Target  : Apache + PHP-FPM ${PHP_VER} + MariaDB + phpMyAdmin"
echo "============================================================"

# =============================================================================
# Input collection (interactive or via env: MYSQL_ROOT, PHPMYADMIN_DIR)
# =============================================================================
ask MYSQL_ROOT      "Enter password for MySQL root user: "
ask PHPMYADMIN_DIR  "Enter PhpMyAdmin path alias: "

if [ -z "${MYSQL_ROOT:-}" ];     then echo "Password can't be blank, aborting"; exit 1; fi
if [ -z "${PHPMYADMIN_DIR:-}" ]; then echo "PhpMyAdmin alias can't be blank, aborting"; exit 1; fi

BLOWFISH_SECRET=$(openssl rand -base64 32)

# =============================================================================
# System update and prerequisites
# =============================================================================
echo "Updating system and installing prerequisites..." | tee -a $LOG_FILE
export DEBIAN_FRONTEND=noninteractive

apt-get update -y >> $LOG_FILE 2>&1
# Note: full system upgrade intentionally skipped — would pull hundreds of MB
# of unrelated packages (kernel, firmware) and stretch install time massively.
# Only the packages this script installs receive the latest version from the
# enabled repos via apt-get install below. Run `apt-get upgrade` manually
# afterwards if you want a full security refresh.

apt_install "prerequisites" lsb-release apt-transport-https ca-certificates \
    wget curl gnupg || exit 1

if [ "$DISTRO_ID" = "ubuntu" ]; then
    apt_install "software-properties-common" software-properties-common || exit 1
fi

# =============================================================================
# Add PHP repository (only if not in native repos)
# =============================================================================
NEED_THIRD_PARTY_REPO=true
case "$DISTRO_ID:$DISTRO_VER" in
    debian:13)
        echo "Debian 13 — PHP ${PHP_VER} available in native repo, skipping third-party" | tee -a $LOG_FILE
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
        # Best-effort: on brand-new releases (e.g. 26.04 'resolute' on launch
        # day) the PPA may not yet list this codename. We continue regardless;
        # the apt-cache check below will catch a missing PHP package.
        add-apt-repository -y ppa:ondrej/php >> $LOG_FILE 2>&1 || \
            echo "  WARN: add-apt-repository failed — falling back to native repos" | tee -a $LOG_FILE
        ;;
esac

if [ "$NEED_THIRD_PARTY_REPO" = true ]; then
    apt-get update -y >> $LOG_FILE 2>&1
fi

# Verify the requested PHP version is now available
if ! apt-cache show php${PHP_VER}-fpm >/dev/null 2>&1; then
    echo "ERROR: php${PHP_VER}-fpm not available after repo setup." | tee -a $LOG_FILE
    echo "Possible causes:" | tee -a $LOG_FILE
    echo "  - ondrej/php PPA does not yet support codename '${DISTRO_CODENAME}'" | tee -a $LOG_FILE
    echo "  - The requested PHP_VER (${PHP_VER}) is not packaged for this OS" | tee -a $LOG_FILE
    echo "Try: PHP_VER=<other-version> bash $0" | tee -a $LOG_FILE
    echo "Full log: $LOG_FILE" | tee -a $LOG_FILE
    exit 1
fi

# =============================================================================
# Install main packages
# =============================================================================
echo "Installing main packages..." | tee -a $LOG_FILE
apt_install "utilities" mc screen fail2ban ssl-cert || exit 1
apt_install "apache2 + mariadb" apache2 mariadb-server curl unzip || exit 1

# Remove rpcbind if present (not needed on web servers, reduces attack surface)
apt-get purge -y rpcbind 2>/dev/null || true

# =============================================================================
# PHP-FPM installation
#
# Removed from default set:
#   - php-imap:    deprecated since PHP 8.2, removed from core in 8.4
#   - php-imagick: PECL imagick has no stable PHP 8.4 release as of 2026-Q1
#                  (installed below as optional)
# =============================================================================
echo "Installing PHP-FPM ${PHP_VER} and modules..." | tee -a $LOG_FILE
apt_install "PHP-FPM ${PHP_VER} core" \
    php${PHP_VER}-fpm \
    php${PHP_VER}-mysql php${PHP_VER}-cli php${PHP_VER}-common \
    php${PHP_VER}-ldap php${PHP_VER}-xml php${PHP_VER}-curl \
    php${PHP_VER}-mbstring php${PHP_VER}-zip php${PHP_VER}-bcmath \
    php${PHP_VER}-gd php${PHP_VER}-soap php${PHP_VER}-bz2 \
    php${PHP_VER}-intl php${PHP_VER}-gmp php${PHP_VER}-redis \
    || exit 1

systemctl daemon-reload
if ! dpkg-query -W -f='${Status}' php${PHP_VER}-fpm 2>/dev/null | grep -q "install ok installed"; then
    echo "ERROR: php${PHP_VER}-fpm package not installed after apt-get success" | tee -a $LOG_FILE
    echo "       Check $LOG_FILE for dpkg errors." | tee -a $LOG_FILE
    exit 1
fi

# Optional: imagick (may not be available on all distros for PHP 8.4)
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
# Configure MariaDB
# =============================================================================
echo "Configuring MariaDB server..." | tee -a $LOG_FILE

mysql -u root mysql >> $LOG_FILE 2>&1 <<EOF
ALTER USER 'root'@'localhost' IDENTIFIED BY '$MYSQL_ROOT';
CREATE USER IF NOT EXISTS 'rooty'@'localhost' IDENTIFIED BY '$MYSQL_ROOT';
GRANT ALL PRIVILEGES ON *.* TO 'rooty'@'localhost' WITH GRANT OPTION;
FLUSH PRIVILEGES;
EOF

if [ $? -eq 0 ]; then
    echo "MariaDB configuration completed successfully." | tee -a $LOG_FILE
else
    echo "ERROR: Failed to configure MariaDB. Aborting." | tee -a $LOG_FILE
    exit 1
fi

# =============================================================================
# Install phpMyAdmin (latest stable release)
# =============================================================================
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

# --- phpMyAdmin PHP-FPM pool ---
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

# --- phpMyAdmin Apache configuration ---
cat > /etc/apache2/conf-available/phpmyadmin.conf <<EOF
# phpMyAdmin Apache configuration for PHP-FPM
Alias /$PHPMYADMIN_DIR /usr/share/phpmyadmin

<Directory /usr/share/phpmyadmin>
    Options SymLinksIfOwnerMatch
    DirectoryIndex index.php
    AllowOverride All
    Require all granted

    <FilesMatch "\.php$">
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

# Use %a (real client IP after mod_remoteip) instead of %h (raw connection IP)
LogFormat "%v:%p %a %l %u %t \"%r\" %>s %O \"%{Referer}i\" \"%{User-Agent}i\"" vhost_combined
LogFormat "%a %l %u %t \"%r\" %>s %O \"%{Referer}i\" \"%{User-Agent}i\"" combined
LogFormat "%a %l %u %t \"%r\" %>s %O" common
LogFormat "%{Referer}i -> %U" referer
LogFormat "%{User-agent}i" agent

IncludeOptional conf-enabled/*.conf
IncludeOptional sites-enabled/*.conf
APACHEEOF

# =============================================================================
# Security configuration
# =============================================================================
cat > /etc/apache2/conf-available/security.conf <<'EOF'
ServerTokens Prod
ServerSignature Off
TraceEnable Off
EOF

# =============================================================================
# MPM Event configuration
# =============================================================================
cat > /etc/apache2/mods-available/mpm_event.conf <<'EOF'
# event MPM optimized for HTTP/2
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

# =============================================================================
# HTTP/2 configuration
# =============================================================================
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

# =============================================================================
# MySQL/MariaDB client configuration
# =============================================================================
cat > /etc/mysql/debian.cnf <<EOF
# Automatically generated. DO NOT TOUCH!
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

# =============================================================================
# Configure mod_remoteip for Cloudflare (replaces deprecated mod_cloudflare)
# =============================================================================
echo "Configuring mod_remoteip for Cloudflare..." | tee -a $LOG_FILE
a2enmod remoteip >> $LOG_FILE 2>&1

CF_IPV4=$(curl -s --max-time 10 https://www.cloudflare.com/ips-v4 || true)
CF_IPV6=$(curl -s --max-time 10 https://www.cloudflare.com/ips-v6 || true)

{
    echo "# Cloudflare real-IP configuration via mod_remoteip"
    echo "# IP list fetched from cloudflare.com/ips/ at install time"
    echo ""
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

# =============================================================================
# Enable Apache configurations and restart services
# =============================================================================
a2enconf phpmyadmin  >> $LOG_FILE 2>&1
a2enconf security    >> $LOG_FILE 2>&1

apache2ctl configtest 2>&1 | tee -a $LOG_FILE
if [ ${PIPESTATUS[0]} -ne 0 ]; then
    echo "ERROR: Apache configuration test failed. Check $LOG_FILE" | tee -a $LOG_FILE
    exit 1
fi

systemctl restart php${PHP_VER}-fpm >> $LOG_FILE 2>&1
systemctl restart apache2           >> $LOG_FILE 2>&1

# =============================================================================
# Install Composer (PHP dependency manager)
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
echo ""
echo "============================================================"
echo " Installation completed successfully!"
echo "============================================================"
echo ""
echo "OS              : $PRETTY_NAME"
echo "PHP-FPM         : ${PHP_VER}"
echo "MPM             : Event (HTTP/2 enabled)"
echo "Cloudflare IPs  : mod_remoteip configured"
echo "phpMyAdmin URL  : http://<server>/${PHPMYADMIN_DIR}"
echo ""
echo "Quick checks:"
echo "  apache2ctl -M | grep -E 'mpm|http2|remoteip'"
echo "  systemctl status php${PHP_VER}-fpm apache2 mariadb"
echo ""
