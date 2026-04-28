#!/bin/bash
# =============================================================================
# Remove Site — disable & remove a single virtual host + PHP-FPM pool
#
# Quick remove (interactive — picks site from a list):
#   bash <(curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/remove-site.sh)
#
# Non-interactive:
#   curl -fsSL https://.../remove-site.sh | \
#     DOMAIN=example.com DELETE_USER=yes DELETE_FILES=yes DELETE_CERT=yes bash
#
# Env vars:
#   DOMAIN          — domain to remove (required if non-interactive)
#   DELETE_USER     — yes/no  delete the system user (default: prompt)
#   DELETE_FILES    — yes/no  delete /www/$DOMAIN  (default: prompt)
#   DELETE_CERT     — yes/no  certbot delete --cert-name $DOMAIN  (default: prompt)
#   FORCE           — yes     skip the confirmation prompt
#   PHP_VER         — PHP version (auto-detected if not set)
#
# Version: 1.0
# =============================================================================

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

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: this script must be run as root (use sudo)"
    exit 1
fi

# =============================================================================
# Auto-detect PHP version if not set
# =============================================================================
if [ -z "${PHP_VER:-}" ]; then
    PHP_VER=$(ls -d /etc/php/*/fpm/pool.d 2>/dev/null | sed -n 's|/etc/php/\([0-9.]*\)/fpm/pool.d|\1|p' | sort -V | tail -1)
fi
if [ -z "$PHP_VER" ]; then
    echo "ERROR: could not detect PHP-FPM version. Is install.sh ever run?"
    exit 1
fi
echo "Detected PHP version: $PHP_VER"

# =============================================================================
# List existing sites (skip default + phpmyadmin)
# =============================================================================
list_sites() {
    local found=()
    if [ -d /etc/apache2/sites-available ]; then
        for f in /etc/apache2/sites-available/*.conf; do
            [ -f "$f" ] || continue
            local name=$(basename "$f" .conf)
            case "$name" in
                000-default|default-ssl|phpmyadmin) continue ;;
            esac
            found+=("$name")
        done
    fi
    printf '%s\n' "${found[@]}"
}

SITES=()
while IFS= read -r line; do
    [ -n "$line" ] && SITES+=("$line")
done < <(list_sites)

if [ ${#SITES[@]} -eq 0 ]; then
    echo "No managed sites found in /etc/apache2/sites-available/"
    exit 0
fi

# =============================================================================
# Pick a domain
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

if [ -z "$DOMAIN" ]; then
    echo "Domain not specified, aborting."
    exit 1
fi

# Verify the site exists
if [ ! -f "/etc/apache2/sites-available/$DOMAIN.conf" ]; then
    echo "ERROR: /etc/apache2/sites-available/$DOMAIN.conf not found."
    echo "Available sites:"
    printf '  %s\n' "${SITES[@]}"
    exit 1
fi

# =============================================================================
# Find associated user from PHP-FPM pool config
# =============================================================================
POOL_FILE="/etc/php/${PHP_VER}/fpm/pool.d/${DOMAIN}.conf"
SITE_USER=""
if [ -f "$POOL_FILE" ]; then
    SITE_USER=$(grep -E '^\s*user\s*=' "$POOL_FILE" | head -1 | awk -F'=' '{print $2}' | xargs)
fi

# =============================================================================
# Confirmation summary
# =============================================================================
echo ""
echo "=============================================="
echo " About to remove site: $DOMAIN"
echo "=============================================="
echo "  Apache vhost  : /etc/apache2/sites-available/${DOMAIN}.conf"
echo "  PHP-FPM pool  : ${POOL_FILE}"
echo "  Cron job      : /etc/cron.d/php-sessions-${DOMAIN}"
echo "  Logrotate     : /etc/logrotate.d/${DOMAIN}.conf"
echo "  Site user     : ${SITE_USER:-<unknown>}"
echo "  Files         : /www/${DOMAIN}"
echo "  SSL cert      : /etc/letsencrypt/live/${DOMAIN}/ (if exists)"
echo ""

if [ "${FORCE:-no}" != "yes" ]; then
    ask CONFIRM "Type the domain '$DOMAIN' to confirm removal: "
    if [ "$CONFIRM" != "$DOMAIN" ]; then
        echo "Confirmation failed (got '$CONFIRM', expected '$DOMAIN'). Aborting."
        exit 1
    fi
fi

# =============================================================================
# Optional deletions — ask for each unless overridden by env
# =============================================================================
ask DELETE_USER  "Also delete system user '${SITE_USER:-<none>}'? (yes/no) [no]: "
ask DELETE_FILES "Also delete site files /www/${DOMAIN}? (yes/no) [no]: "
ask DELETE_CERT  "Also delete SSL certificate for ${DOMAIN}? (yes/no) [no]: "

DELETE_USER="${DELETE_USER:-no}"
DELETE_FILES="${DELETE_FILES:-no}"
DELETE_CERT="${DELETE_CERT:-no}"

# =============================================================================
# Perform removal
# =============================================================================
echo ""
echo "Removing site $DOMAIN..."

# 1. Disable Apache site
if a2query -s "$DOMAIN" >/dev/null 2>&1; then
    a2dissite "$DOMAIN" >/dev/null 2>&1
    echo "  - apache vhost disabled"
fi
rm -f "/etc/apache2/sites-available/${DOMAIN}.conf"
rm -f "/etc/apache2/sites-enabled/${DOMAIN}.conf"

# 2. Remove PHP-FPM pool
rm -f "$POOL_FILE"
echo "  - php-fpm pool removed"

# 3. Remove cron + logrotate
rm -f "/etc/cron.d/php-sessions-${DOMAIN}"
rm -f "/etc/logrotate.d/${DOMAIN}.conf"
echo "  - cron + logrotate removed"

# 4. Restart PHP-FPM now (BEFORE deleting the user) so the pool's worker
# processes — which run as $SITE_USER — actually exit. Otherwise userdel
# fails with: "user X is currently used by process Y".
systemctl restart "php${PHP_VER}-fpm" 2>/dev/null || true

# 5. Optionally delete SSL cert
if [ "$DELETE_CERT" = "yes" ] && command -v certbot >/dev/null 2>&1; then
    if certbot certificates 2>/dev/null | grep -q "Certificate Name: ${DOMAIN}\$"; then
        certbot delete --cert-name "$DOMAIN" -n 2>&1 | tail -3
        echo "  - SSL cert deleted"
    else
        echo "  - no SSL cert found for ${DOMAIN}"
    fi
fi

# 6. Optionally delete user
if [ "$DELETE_USER" = "yes" ] && [ -n "$SITE_USER" ] && [ "$SITE_USER" != "www-data" ]; then
    if id "$SITE_USER" >/dev/null 2>&1; then
        # Remove www-data from this user's group first (otherwise groupdel fails)
        gpasswd -d www-data "$SITE_USER" >/dev/null 2>&1 || true
        # Kill any processes still owned by this user
        pkill -9 -u "$SITE_USER" 2>/dev/null || true
        sleep 1
        # userdel -r removes the home dir too. Stderr is shown so any failure
        # ("user is currently used by process X") is visible.
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

# 7. Optionally delete files
if [ "$DELETE_FILES" = "yes" ]; then
    rm -rf "/www/${DOMAIN}"
    echo "  - files /www/${DOMAIN} deleted"
fi

# 8. Reload Apache (php-fpm was already restarted in step 4)
systemctl reload apache2 2>/dev/null || systemctl restart apache2

echo ""
echo "=============================================="
echo " Site $DOMAIN removed."
echo "=============================================="
[ "$DELETE_USER"  = "no" ] && [ -n "$SITE_USER" ] && echo "  Note: system user '$SITE_USER' was kept."
[ "$DELETE_FILES" = "no" ] && [ -d "/www/$DOMAIN" ] && echo "  Note: site files in /www/$DOMAIN kept."
[ "$DELETE_CERT"  = "no" ] && echo "  Note: SSL cert (if any) kept — remove with: certbot delete --cert-name $DOMAIN"
