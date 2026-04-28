#!/bin/bash
# =============================================================================
# Nginx: Remove Site — disable & remove server block + PHP-FPM pool + opt DB
#
# Quick remove (interactive):
#   bash <(curl -fsSL https://raw.githubusercontent.com/DaveBugg/web_server_script/main/nginx/remove-site.sh)
#
# Non-interactive:
#   curl -fsSL .../remove-site.sh | \
#     DOMAIN=example.com DELETE_USER=yes DELETE_FILES=yes \
#     DELETE_CERT=yes DELETE_DB=yes FORCE=yes bash
#
# Reads:  /etc/web_server_script.conf
#
# Version: 4.0
# =============================================================================

STATE_FILE="/etc/web_server_script.conf"
[ -f "$STATE_FILE" ] && . "$STATE_FILE"

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

if [ -z "${PHP_VER:-}" ]; then
    PHP_VER=$(ls -d /etc/php/*/fpm/pool.d 2>/dev/null | sed -n 's|/etc/php/\([0-9.]*\)/fpm/pool.d|\1|p' | sort -V | tail -1)
fi
if [ -z "$PHP_VER" ]; then
    echo "ERROR: could not detect PHP-FPM version. Was install.sh ever run?"
    exit 1
fi

# =============================================================================
# List sites (skip default + admin UIs)
# =============================================================================
SITES=()
if [ -d /etc/nginx/sites-available ]; then
    for f in /etc/nginx/sites-available/*; do
        [ -f "$f" ] || continue
        n=$(basename "$f")
        case "$n" in 000-default|default) continue ;; esac
        SITES+=("$n")
    done
fi

if [ ${#SITES[@]} -eq 0 ]; then
    echo "No managed sites found in /etc/nginx/sites-available/"
    exit 0
fi

# =============================================================================
# Pick site
# =============================================================================
if [ -z "${DOMAIN:-}" ]; then
    echo ""
    echo "Existing sites:"
    i=1
    for s in "${SITES[@]}"; do
        echo "  $i) $s"
        i=$((i+1))
    done
    echo ""
    ask SITE_CHOICE "Select site to remove (1-${#SITES[@]}, or type domain): "
    if [[ "$SITE_CHOICE" =~ ^[0-9]+$ ]] && [ "$SITE_CHOICE" -ge 1 ] && [ "$SITE_CHOICE" -le ${#SITES[@]} ]; then
        DOMAIN="${SITES[$((SITE_CHOICE-1))]}"
    else
        DOMAIN="$SITE_CHOICE"
    fi
fi

[ -z "$DOMAIN" ] && { echo "Domain not specified, aborting."; exit 1; }

if [ ! -f "/etc/nginx/sites-available/$DOMAIN" ]; then
    echo "ERROR: /etc/nginx/sites-available/$DOMAIN not found."
    echo "Available: ${SITES[*]}"
    exit 1
fi

# =============================================================================
# Find user + DB info
# =============================================================================
POOL_FILE="/etc/php/${PHP_VER}/fpm/pool.d/${DOMAIN}.conf"
SITE_USER=""
[ -f "$POOL_FILE" ] && SITE_USER=$(grep -E '^\s*user\s*=' "$POOL_FILE" | head -1 | awk -F'=' '{print $2}' | xargs)

DB_INFO_FILE="/www/${DOMAIN}/db.txt"
DB_TYPE=""; DB_NAME=""; DB_USER=""
if [ -f "$DB_INFO_FILE" ]; then
    DB_TYPE=$(grep -E '^DB_TYPE='  "$DB_INFO_FILE" | head -1 | cut -d'=' -f2-)
    DB_NAME=$(grep -E '^DB_NAME='  "$DB_INFO_FILE" | head -1 | cut -d'=' -f2-)
    DB_USER=$(grep -E '^DB_USER='  "$DB_INFO_FILE" | head -1 | cut -d'=' -f2-)
fi

# =============================================================================
# Summary + confirm
# =============================================================================
echo ""
echo "=============================================="
echo " About to remove site: $DOMAIN"
echo "=============================================="
echo "  Nginx vhost   : /etc/nginx/sites-available/${DOMAIN}"
echo "  PHP-FPM pool  : ${POOL_FILE}"
echo "  Cron job      : /etc/cron.d/php-sessions-${DOMAIN}"
echo "  Logrotate     : /etc/logrotate.d/${DOMAIN}.conf"
echo "  Site user     : ${SITE_USER:-<unknown>}"
echo "  Files         : /www/${DOMAIN}"
echo "  SSL cert      : /etc/letsencrypt/live/${DOMAIN}/ (if exists)"
[ -n "$DB_NAME" ] && echo "  Database      : ${DB_TYPE} → ${DB_NAME} (user: ${DB_USER})"
echo ""

if [ "${FORCE:-no}" != "yes" ]; then
    ask CONFIRM "Type the domain '$DOMAIN' to confirm removal: "
    if [ "$CONFIRM" != "$DOMAIN" ]; then
        echo "Confirmation failed (got '$CONFIRM', expected '$DOMAIN'). Aborting."
        exit 1
    fi
fi

ask DELETE_USER  "Also delete system user '${SITE_USER:-<none>}'? (yes/no) [no]: "
ask DELETE_FILES "Also delete site files /www/${DOMAIN}? (yes/no) [no]: "
ask DELETE_CERT  "Also delete SSL certificate for ${DOMAIN}? (yes/no) [no]: "
[ -n "$DB_NAME" ] && ask DELETE_DB "Also DROP database '${DB_NAME}' and DB user '${DB_USER}'? (yes/no) [no]: "

DELETE_USER="${DELETE_USER:-no}"
DELETE_FILES="${DELETE_FILES:-no}"
DELETE_CERT="${DELETE_CERT:-no}"
DELETE_DB="${DELETE_DB:-no}"

# =============================================================================
# Remove
# =============================================================================
echo ""
echo "Removing site $DOMAIN..."

rm -f "/etc/nginx/sites-enabled/${DOMAIN}"
rm -f "/etc/nginx/sites-available/${DOMAIN}"
echo "  - nginx vhost removed"

rm -f "$POOL_FILE"
echo "  - php-fpm pool removed"

rm -f "/etc/cron.d/php-sessions-${DOMAIN}"
rm -f "/etc/logrotate.d/${DOMAIN}.conf"
echo "  - cron + logrotate removed"

# Restart PHP-FPM BEFORE deleting user (so worker procs exit)
systemctl restart "php${PHP_VER}-fpm" 2>/dev/null || true

# SSL cert
if [ "$DELETE_CERT" = "yes" ] && command -v certbot >/dev/null 2>&1; then
    if certbot certificates 2>/dev/null | grep -q "Certificate Name: ${DOMAIN}\$"; then
        certbot delete --cert-name "$DOMAIN" -n 2>&1 | tail -3
        echo "  - SSL cert deleted"
    else
        echo "  - no SSL cert found for ${DOMAIN}"
    fi
fi

# DB
if [ "$DELETE_DB" = "yes" ] && [ -n "$DB_NAME" ] && [ -n "$DB_TYPE" ]; then
    case "$DB_TYPE" in
        mariadb|mysql)
            if mysql --defaults-file=/etc/mysql/debian.cnf -e "SELECT 1" >/dev/null 2>&1; then
                mysql --defaults-file=/etc/mysql/debian.cnf <<EOF
DROP DATABASE IF EXISTS \`${DB_NAME}\`;
DROP USER IF EXISTS '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
EOF
                echo "  - MariaDB database '${DB_NAME}' and user '${DB_USER}' dropped"
            else
                echo "  - WARN: cannot connect to MariaDB; DB drop skipped"
            fi
            ;;
        pgsql|postgres|postgresql)
            sudo -u postgres psql -c "DROP DATABASE IF EXISTS \"${DB_NAME}\";"  >/dev/null 2>&1 || true
            sudo -u postgres psql -c "DROP ROLE IF EXISTS \"${DB_USER}\";"      >/dev/null 2>&1 || true
            echo "  - PostgreSQL database '${DB_NAME}' and role '${DB_USER}' dropped"
            ;;
    esac
fi

# System user
if [ "$DELETE_USER" = "yes" ] && [ -n "$SITE_USER" ] && [ "$SITE_USER" != "www-data" ]; then
    if id "$SITE_USER" >/dev/null 2>&1; then
        gpasswd -d www-data "$SITE_USER" >/dev/null 2>&1 || true
        pkill -9 -u "$SITE_USER" 2>/dev/null || true
        sleep 1
        if userdel -r "$SITE_USER" 2>&1; then
            echo "  - user $SITE_USER deleted"
        elif userdel "$SITE_USER" 2>&1; then
            echo "  - user $SITE_USER deleted (home dir not removed)"
        else
            echo "  - WARN: userdel failed for $SITE_USER (check above stderr)"
        fi
        groupdel "$SITE_USER" 2>/dev/null || true
    else
        echo "  - user $SITE_USER not found (already removed?)"
    fi
fi

# Files
if [ "$DELETE_FILES" = "yes" ]; then
    rm -rf "/www/${DOMAIN}"
    echo "  - files /www/${DOMAIN} deleted"
fi

# Reload nginx
nginx -t >/dev/null 2>&1 && systemctl reload nginx 2>/dev/null || systemctl restart nginx

echo ""
echo "=============================================="
echo " Site $DOMAIN removed."
echo "=============================================="
{
    [ "$DELETE_USER"  = "no" ] && [ -n "$SITE_USER" ]    && echo "  Note: system user '$SITE_USER' kept."
    [ "$DELETE_FILES" = "no" ] && [ -d "/www/$DOMAIN" ]  && echo "  Note: site files in /www/$DOMAIN kept."
    [ "$DELETE_CERT"  = "no" ]                           && echo "  Note: SSL cert (if any) kept — remove with: certbot delete --cert-name $DOMAIN"
    [ -n "$DB_NAME" ] && [ "$DELETE_DB" = "no" ]         && echo "  Note: database '$DB_NAME' and DB user '$DB_USER' kept."
} || true
exit 0
