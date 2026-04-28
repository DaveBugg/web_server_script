#!/bin/bash
# =============================================================================
# Apache: Uninstall — purge Apache + PHP + DB (auto-detects which DB)
#
# DESTRUCTIVE — requires explicit confirmation.
#
# Quick uninstall (interactive):
#   bash <(curl -fsSL https://raw.githubusercontent.com/DaveBugg/web_server_script/main/apache/uninstall.sh)
#
# Non-interactive:
#   curl -fsSL .../uninstall.sh | FORCE=yes DELETE_CERTS=yes bash
#
# Env vars:
#   FORCE          — yes  skip the typed confirmation
#   DELETE_CERTS   — yes  also remove /etc/letsencrypt and certbot package
#   KEEP_PACKAGES  — yes  remove only configs/data, leave packages installed
#
# Reads:  /etc/web_server_script.conf  → DATABASE
#
# Version: 4.0
# =============================================================================

STATE_FILE="/etc/web_server_script.conf"
[ -f "$STATE_FILE" ] && . "$STATE_FILE"
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

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: this script must be run as root (use sudo)"
    exit 1
fi

# =============================================================================
# Inventory
# =============================================================================
SITES=()
if [ -d /etc/apache2/sites-available ]; then
    for f in /etc/apache2/sites-available/*.conf; do
        [ -f "$f" ] || continue
        n=$(basename "$f" .conf)
        case "$n" in 000-default|default-ssl|phpmyadmin|phppgadmin) continue ;; esac
        SITES+=("$n")
    done
fi

SITE_USERS=()
for pool in /etc/php/*/fpm/pool.d/*.conf; do
    [ -f "$pool" ] || continue
    pname=$(basename "$pool" .conf)
    case "$pname" in www|phpmyadmin|phppgadmin) continue ;; esac
    user=$(grep -E '^\s*user\s*=' "$pool" 2>/dev/null | head -1 | awk -F'=' '{print $2}' | xargs)
    if [ -n "$user" ] && [ "$user" != "www-data" ]; then
        SITE_USERS+=("$user")
    fi
done
[ ${#SITE_USERS[@]} -gt 0 ] && mapfile -t SITE_USERS < <(printf '%s\n' "${SITE_USERS[@]}" | sort -u)

PHP_DIRS=()
for d in /etc/php/*; do
    [ -d "$d" ] && PHP_DIRS+=("$(basename "$d")")
done

# Auto-detect DB if state file missing
if [ -z "$DATABASE" ]; then
    if dpkg -l 2>/dev/null | grep -q "^ii\s\+mariadb-server"; then DATABASE=mariadb
    elif dpkg -l 2>/dev/null | grep -q "^ii\s\+postgresql\b"; then DATABASE=pgsql
    fi
fi

echo "=============================================="
echo " UNINSTALL — review what will be removed"
echo "=============================================="
echo "  Web server     : Apache"
echo "  Database       : ${DATABASE:-<none detected>}"
echo "  Sites          : ${SITES[*]:-<none>}"
echo "  Site users     : ${SITE_USERS[*]:-<none>}"
echo "  PHP versions   : ${PHP_DIRS[*]:-<none>}"
case "$DATABASE" in
    mariadb) echo "  Packages       : apache2*, libapache2-*, php*, mariadb-*, mysql-*, phpmyadmin" ;;
    pgsql)   echo "  Packages       : apache2*, libapache2-*, php*, postgresql*, phpPgAdmin (manual files)" ;;
    *)       echo "  Packages       : apache2*, libapache2-*, php*" ;;
esac
[ "${KEEP_PACKAGES:-no}" = "yes" ] && echo "                   (skipped — KEEP_PACKAGES=yes)"
echo "  Config dirs    : /etc/apache2  /etc/php"
[ "$DATABASE" = "mariadb" ] && echo "                   /etc/mysql"
[ "$DATABASE" = "pgsql" ]   && echo "                   /etc/postgresql"
echo "  Data dirs      : /usr/share/phpmyadmin  /usr/share/phppgadmin  (whichever exists)"
[ "$DATABASE" = "mariadb" ] && echo "                   /var/lib/mysql"
[ "$DATABASE" = "pgsql" ]   && echo "                   /var/lib/postgresql"
echo "  Site files     : /www  (everything inside)"
echo "  Logs           : /var/log/apache2"
echo "  Composer       : /usr/local/bin/composer"
echo "  State file     : $STATE_FILE"
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

# 1. Stop services
echo "Stopping services..."
systemctl stop apache2 2>/dev/null || true
[ "$DATABASE" = "mariadb" ] && systemctl stop mariadb 2>/dev/null || true
[ "$DATABASE" = "pgsql"   ] && systemctl stop postgresql 2>/dev/null || true
for v in "${PHP_DIRS[@]}"; do systemctl stop "php${v}-fpm" 2>/dev/null || true; done
systemctl stop fail2ban 2>/dev/null || true

# 2. Kill site-user processes
for u in "${SITE_USERS[@]}"; do pkill -9 -u "$u" 2>/dev/null || true; done
sleep 1

# 3. Purge packages
if [ "${KEEP_PACKAGES:-no}" != "yes" ]; then
    echo "Purging packages (this may take a few minutes)..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get purge -y \
        'php*' 'apache2*' 'libapache2-*' \
        >/dev/null 2>&1 || true
    case "$DATABASE" in
        mariadb)
            apt-get purge -y 'mariadb-*' 'mysql-*' phpmyadmin >/dev/null 2>&1 || true
            ;;
        pgsql)
            apt-get purge -y 'postgresql*' >/dev/null 2>&1 || true
            ;;
    esac
    if [ "${DELETE_CERTS:-no}" = "yes" ]; then
        apt-get purge -y certbot python3-certbot-apache >/dev/null 2>&1 || true
    fi
    apt-get autoremove -y --purge >/dev/null 2>&1 || true
fi

# 4. Configs + data
echo "Removing config and data directories..."
rm -rf /etc/apache2 /etc/php
[ "$DATABASE" = "mariadb" ] && rm -rf /etc/mysql /var/lib/mysql /var/lib/phpmyadmin /usr/share/phpmyadmin
[ "$DATABASE" = "pgsql"   ] && rm -rf /etc/postgresql /var/lib/postgresql /usr/share/phppgadmin /var/lib/phppgadmin
rm -rf /run/php /var/log/apache2
rm -f  /etc/apt/sources.list.d/php.list /etc/apt/trusted.gpg.d/php.gpg
rm -f  /etc/apt/sources.list.d/ondrej-*.list /etc/apt/sources.list.d/ondrej-*.sources

for s in "${SITES[@]}"; do
    rm -f "/etc/cron.d/php-sessions-${s}"
    rm -f "/etc/logrotate.d/${s}.conf"
done

rm -f /usr/local/bin/composer
rm -f "$STATE_FILE"

if [ "${DELETE_CERTS:-no}" = "yes" ]; then
    rm -rf /etc/letsencrypt /var/lib/letsencrypt /var/log/letsencrypt
fi

# 5. Site users
echo "Removing site users..."
for u in "${SITE_USERS[@]}"; do
    if id "$u" >/dev/null 2>&1; then
        gpasswd -d www-data "$u" >/dev/null 2>&1 || true
        userdel -r "$u" 2>/dev/null || userdel "$u" 2>/dev/null || true
        groupdel "$u" 2>/dev/null || true
    fi
done

# 6. /www
rm -rf /www

# 7. Recreate www-data (purge can drop it)
if ! id www-data >/dev/null 2>&1; then
    groupadd -r www-data 2>/dev/null || true
    useradd -r -g www-data -d /var/www -s /usr/sbin/nologin www-data 2>/dev/null || true
fi

# 8. Final report
echo ""
echo "=============================================="
echo " Uninstall complete."
echo "=============================================="
echo ""
remaining=$(dpkg -l 2>/dev/null | grep -E '^ii\s+(php|apache2|mariadb-server|postgresql|phpmyadmin)' | awk '{print $2}')
if [ -n "$remaining" ]; then
    echo "WARNING: some packages remain installed:"
    echo "$remaining" | sed 's/^/    /'
else
    echo "  ✓ no LAMP packages remain installed"
fi
echo ""
echo "  ✓ /etc/apache2 /etc/php removed"
[ "$DATABASE" = "mariadb" ] && echo "  ✓ /etc/mysql /var/lib/mysql /usr/share/phpmyadmin removed"
[ "$DATABASE" = "pgsql"   ] && echo "  ✓ /etc/postgresql /var/lib/postgresql /usr/share/phppgadmin removed"
echo "  ✓ /www removed"
echo "  ✓ www-data system user preserved"
[ "${DELETE_CERTS:-no}" = "yes" ] && echo "  ✓ /etc/letsencrypt removed"
echo ""
echo "You can now re-run install.sh on this host for a clean setup."
