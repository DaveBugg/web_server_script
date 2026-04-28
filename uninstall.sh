#!/bin/bash
# =============================================================================
# Uninstall — REMOVE EVERYTHING installed by install.sh + add-site.sh
#
#   - Stops and purges Apache, PHP, MariaDB, phpMyAdmin
#   - Removes all sites, configs, data, logs
#   - Removes all custom site users + their files
#   - Removes Composer
#   - Removes SSL certificates (if --delete-certs)
#   - Recreates www-data so the system stays consistent for re-install
#
# DESTRUCTIVE — requires explicit confirmation.
#
# Quick uninstall (interactive):
#   bash <(curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/uninstall.sh)
#
# Non-interactive:
#   curl -fsSL https://.../uninstall.sh | FORCE=yes DELETE_CERTS=yes bash
#
# Env vars:
#   FORCE          — yes  skip the typed confirmation
#   DELETE_CERTS   — yes  also remove /etc/letsencrypt and certbot package
#   KEEP_PACKAGES  — yes  remove only configs/data, leave packages installed
#
# Version: 1.0
# =============================================================================

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

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: this script must be run as root (use sudo)"
    exit 1
fi

# =============================================================================
# Inventory: what will be removed
# =============================================================================
SITES=()
if [ -d /etc/apache2/sites-available ]; then
    for f in /etc/apache2/sites-available/*.conf; do
        [ -f "$f" ] || continue
        name=$(basename "$f" .conf)
        case "$name" in
            000-default|default-ssl|phpmyadmin) continue ;;
        esac
        SITES+=("$name")
    done
fi

# Site users from PHP-FPM pools
SITE_USERS=()
for pool in /etc/php/*/fpm/pool.d/*.conf; do
    [ -f "$pool" ] || continue
    pname=$(basename "$pool" .conf)
    case "$pname" in www|phpmyadmin) continue ;; esac
    user=$(grep -E '^\s*user\s*=' "$pool" 2>/dev/null | head -1 | awk -F'=' '{print $2}' | xargs)
    if [ -n "$user" ] && [ "$user" != "www-data" ]; then
        SITE_USERS+=("$user")
    fi
done
# de-duplicate
if [ ${#SITE_USERS[@]} -gt 0 ]; then
    mapfile -t SITE_USERS < <(printf '%s\n' "${SITE_USERS[@]}" | sort -u)
fi

PHP_DIRS=()
for d in /etc/php/*; do
    [ -d "$d" ] && PHP_DIRS+=("$(basename "$d")")
done

echo "=============================================="
echo " UNINSTALL — review what will be removed"
echo "=============================================="
echo "  Sites          : ${SITES[*]:-<none>}"
echo "  Site users     : ${SITE_USERS[*]:-<none>}"
echo "  PHP versions   : ${PHP_DIRS[*]:-<none>}"
echo "  Packages       : apache2*, libapache2-*, php*, mariadb-*, mysql-*, phpmyadmin"
[ "${KEEP_PACKAGES:-no}" = "yes" ] && echo "                   (skipped — KEEP_PACKAGES=yes)"
echo "  Config dirs    : /etc/apache2  /etc/php  /etc/mysql"
echo "  Data dirs      : /var/lib/mysql  /var/lib/phpmyadmin  /usr/share/phpmyadmin"
echo "  Site files     : /www  (everything inside)"
echo "  Logs           : /var/log/apache2  /var/log/mysql"
echo "  Composer       : /usr/local/bin/composer"
[ "${DELETE_CERTS:-no}" = "yes" ] && echo "  SSL certs      : /etc/letsencrypt  + certbot package"
[ "${DELETE_CERTS:-no}" != "yes" ] && echo "  SSL certs      : KEPT (set DELETE_CERTS=yes to remove)"
echo ""
echo "This is DESTRUCTIVE and CANNOT be undone."
echo ""

if [ "${FORCE:-no}" != "yes" ]; then
    ask CONFIRM "Type 'YES, DELETE EVERYTHING' to proceed: "
    if [ "$CONFIRM" != "YES, DELETE EVERYTHING" ]; then
        echo "Confirmation failed. Aborting (nothing was changed)."
        exit 1
    fi
fi

echo ""
echo "=============================================="
echo " Beginning uninstall..."
echo "=============================================="

# =============================================================================
# 1. Stop services
# =============================================================================
echo "Stopping services..."
systemctl stop apache2 mariadb 2>/dev/null || true
for v in "${PHP_DIRS[@]}"; do
    systemctl stop "php${v}-fpm" 2>/dev/null || true
done
systemctl stop fail2ban 2>/dev/null || true

# =============================================================================
# 2. Kill any remaining processes owned by site users
# =============================================================================
for u in "${SITE_USERS[@]}"; do
    pkill -9 -u "$u" 2>/dev/null || true
done
sleep 1

# =============================================================================
# 3. Purge packages (unless KEEP_PACKAGES)
# =============================================================================
if [ "${KEEP_PACKAGES:-no}" != "yes" ]; then
    echo "Purging packages (this may take a few minutes)..."
    export DEBIAN_FRONTEND=noninteractive

    # Use shell glob expansion via apt-get's package patterns
    apt-get purge -y \
        'php*' 'apache2*' 'libapache2-*' \
        'mariadb-*' 'mysql-*' \
        phpmyadmin \
        >/dev/null 2>&1 || true

    if [ "${DELETE_CERTS:-no}" = "yes" ]; then
        apt-get purge -y certbot python3-certbot-apache >/dev/null 2>&1 || true
    fi

    apt-get autoremove -y --purge >/dev/null 2>&1 || true
fi

# =============================================================================
# 4. Remove configs + data dirs
# =============================================================================
echo "Removing config and data directories..."
rm -rf /etc/apache2 /etc/php /etc/mysql
rm -rf /var/lib/mysql /var/lib/phpmyadmin /usr/share/phpmyadmin
rm -rf /run/php
rm -rf /var/log/apache2 /var/log/mysql
rm -f  /etc/apt/sources.list.d/php.list /etc/apt/trusted.gpg.d/php.gpg
rm -f  /etc/apt/sources.list.d/ondrej-*.list /etc/apt/sources.list.d/ondrej-*.sources

# Cron + logrotate fragments installed by add-site.sh
for s in "${SITES[@]}"; do
    rm -f "/etc/cron.d/php-sessions-${s}"
    rm -f "/etc/logrotate.d/${s}.conf"
done

# Composer
rm -f /usr/local/bin/composer

# Optionally remove all Let's Encrypt certs
if [ "${DELETE_CERTS:-no}" = "yes" ]; then
    rm -rf /etc/letsencrypt /var/lib/letsencrypt /var/log/letsencrypt
fi

# =============================================================================
# 5. Remove site users (and their /www homes)
# =============================================================================
echo "Removing site users..."
for u in "${SITE_USERS[@]}"; do
    if id "$u" >/dev/null 2>&1; then
        gpasswd -d www-data "$u" >/dev/null 2>&1 || true
        userdel -r "$u" 2>/dev/null || userdel "$u" 2>/dev/null || true
        groupdel "$u" 2>/dev/null || true
    fi
done

# =============================================================================
# 6. Remove site files directory tree (if anything left)
# =============================================================================
rm -rf /www

# =============================================================================
# 7. Recreate www-data (purge can drop it; keep system consistent for re-install)
# =============================================================================
if ! id www-data >/dev/null 2>&1; then
    groupadd -r www-data 2>/dev/null || true
    useradd -r -g www-data -d /var/www -s /usr/sbin/nologin www-data 2>/dev/null || true
fi

# =============================================================================
# 8. Final report
# =============================================================================
echo ""
echo "=============================================="
echo " Uninstall complete."
echo "=============================================="
echo ""
remaining=$(dpkg -l 2>/dev/null | grep -E '^ii\s+(php|apache2|mariadb|mysql|phpmyadmin)' | awk '{print $2}')
if [ -n "$remaining" ]; then
    echo "WARNING: some packages remain installed:"
    echo "$remaining" | sed 's/^/    /'
else
    echo "  ✓ no LAMP packages remain installed"
fi
echo ""
echo "  ✓ /etc/apache2 /etc/php /etc/mysql removed"
echo "  ✓ /var/lib/mysql /usr/share/phpmyadmin removed"
echo "  ✓ /www removed"
echo "  ✓ www-data system user preserved"
[ "${DELETE_CERTS:-no}" = "yes" ] && echo "  ✓ /etc/letsencrypt removed"
echo ""
echo "You can now re-run install.sh on this host for a clean setup."
