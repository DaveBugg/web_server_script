#!/bin/bash
# =============================================================================
# Web Server Manager — interactive menu
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/DaveBugg/web_server_script/main/web-server.sh)
#   bash <(wget -qO- https://raw.githubusercontent.com/DaveBugg/web_server_script/main/web-server.sh)
#
# The menu shows the detected stack (web server + database). For a fresh install
# it asks which web server (apache|nginx) and which database (mariadb|pgsql),
# then downloads the matching install.sh from <repo>/<webserver>/install.sh.
# After that, the choice is persisted in /etc/web_server_script.conf and
# subsequent actions (add/remove site, uninstall) are routed automatically.
#
# Override the repo source (forks / branches):
#   REPO_URL=https://raw.githubusercontent.com/myfork/web_server_script/dev \
#     bash <(curl -fsSL "$REPO_URL/web-server.sh")
#
# Version: 4.0
# =============================================================================

REPO_URL="${REPO_URL:-https://raw.githubusercontent.com/DaveBugg/web_server_script/main}"
STATE_FILE="/etc/web_server_script.conf"

if [ -e /dev/tty ]; then
    exec 3</dev/tty
else
    exec 3<&0
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: this script must be run as root (use sudo)"
    exit 1
fi

if [ -t 1 ]; then
    C_BOLD=$'\e[1m';   C_RESET=$'\e[0m'
    C_CYAN=$'\e[36m';  C_GREEN=$'\e[32m';  C_YELLOW=$'\e[33m';  C_RED=$'\e[31m'
    C_DIM=$'\e[2m'
else
    C_BOLD=""; C_RESET=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_DIM=""
fi

# =============================================================================
# State detection
# =============================================================================
detect_state() {
    WEB_SERVER=""; DATABASE=""; PHP_VER_DETECTED=""

    # Read persisted config first (set by install.sh after success)
    if [ -f "$STATE_FILE" ]; then
        . "$STATE_FILE"
    fi

    # Auto-detect even without state file (e.g. partial install / re-deploy)
    if [ -z "$WEB_SERVER" ]; then
        if   command -v apache2 >/dev/null 2>&1; then WEB_SERVER=apache
        elif command -v nginx   >/dev/null 2>&1; then WEB_SERVER=nginx
        fi
    fi
    if [ -z "$DATABASE" ]; then
        if   dpkg -l 2>/dev/null | grep -q "^ii\s\+mariadb-server"; then DATABASE=mariadb
        elif dpkg -l 2>/dev/null | grep -q "^ii\s\+postgresql\b";   then DATABASE=pgsql
        fi
    fi
    if [ -z "${DB_UI:-}" ]; then
        if   [ -d /usr/share/phpmyadmin ]; then DB_UI=phpmyadmin
        elif [ -d /usr/share/adminer ];    then DB_UI=adminer
        elif [ -d /usr/pgadmin4 ];         then DB_UI=pgadmin4
        fi
    fi

    PHP_VER_DETECTED="${PHP_VER:-}"
    if [ -z "$PHP_VER_DETECTED" ] && [ -d /etc/php ]; then
        PHP_VER_DETECTED=$(ls /etc/php 2>/dev/null | sort -V | tail -1)
    fi

    OS_PRETTY=""
    [ -f /etc/os-release ] && OS_PRETTY=$(. /etc/os-release; echo "$PRETTY_NAME")

    SITE_COUNT=0
    if [ "$WEB_SERVER" = "apache" ] && [ -d /etc/apache2/sites-available ]; then
        for f in /etc/apache2/sites-available/*.conf; do
            [ -f "$f" ] || continue
            n=$(basename "$f" .conf)
            case "$n" in 000-default|default-ssl|phpmyadmin|phppgadmin|adminer) continue ;; esac
            SITE_COUNT=$((SITE_COUNT+1))
        done
    elif [ "$WEB_SERVER" = "nginx" ] && [ -d /etc/nginx/sites-available ]; then
        for f in /etc/nginx/sites-available/*; do
            [ -f "$f" ] || continue
            n=$(basename "$f")
            case "$n" in 000-default|default) continue ;; esac
            SITE_COUNT=$((SITE_COUNT+1))
        done
    fi

    if [ -n "$WEB_SERVER" ] && systemctl is-active "$WEB_SERVER" >/dev/null 2>&1; then
        WEB_STATE="${C_GREEN}installed${C_RESET}"
    elif [ -n "$WEB_SERVER" ]; then
        WEB_STATE="${C_YELLOW}installed (not running)${C_RESET}"
    else
        WEB_STATE="${C_YELLOW}not installed${C_RESET}"
    fi
}

# =============================================================================
# Run a sub-script from the repo (preserves stdin from caller's tty)
# =============================================================================
run_action() {
    local script="$1"
    local url="$REPO_URL/$script"
    echo ""
    echo "${C_CYAN}> Fetching $url ...${C_RESET}"
    local tmp
    tmp=$(mktemp /tmp/web-server-action-XXXXXX.sh)
    if ! curl -fsSL "$url" -o "$tmp"; then
        echo "${C_RED}ERROR: failed to download $url${C_RESET}"
        rm -f "$tmp"
        return 1
    fi
    chmod +x "$tmp"
    bash "$tmp"
    local rc=$?
    rm -f "$tmp"
    echo ""
    echo "${C_CYAN}> Action finished (exit $rc).${C_RESET}"
    return $rc
}

# =============================================================================
# Pick web server + database for fresh install
# =============================================================================
fresh_install_flow() {
    echo ""
    echo "${C_BOLD}--- Fresh install ---${C_RESET}"
    echo ""
    echo "Web server:"
    echo "  ${C_GREEN}1)${C_RESET} Apache (mpm_event + PHP-FPM via mod_proxy_fcgi)"
    echo "  ${C_GREEN}2)${C_RESET} Nginx  (PHP-FPM via fastcgi_pass)"
    local ws_choice
    read -u 3 -r -p "Select web server [1-2]: " ws_choice
    case "$ws_choice" in
        1|apache) export WEB_SERVER=apache ;;
        2|nginx)  export WEB_SERVER=nginx ;;
        *) echo "${C_RED}Invalid choice — must be 1 or 2${C_RESET}"; return 1 ;;
    esac

    echo ""
    echo "Database:"
    echo "  ${C_GREEN}1)${C_RESET} MariaDB    (admin UI: phpMyAdmin or Adminer)"
    echo "  ${C_GREEN}2)${C_RESET} PostgreSQL (admin UI: Adminer or pgAdmin4)"
    local db_choice
    read -u 3 -r -p "Select database [1-2]: " db_choice
    case "$db_choice" in
        1|mariadb) export DATABASE=mariadb ;;
        2|pgsql|postgres|postgresql) export DATABASE=pgsql ;;
        *) echo "${C_RED}Invalid choice — must be 1 or 2${C_RESET}"; return 1 ;;
    esac

    echo ""
    echo "Selected: ${C_BOLD}${WEB_SERVER}${C_RESET} + ${C_BOLD}${DATABASE}${C_RESET}"
    run_action "${WEB_SERVER}/install.sh"
}

# =============================================================================
# Menu
# =============================================================================
show_menu() {
    detect_state
    clear 2>/dev/null || true
    cat <<EOF

${C_BOLD}=================================================================${C_RESET}
${C_BOLD}  Web Server Manager${C_RESET}  ${C_DIM}v4.2${C_RESET}
${C_BOLD}=================================================================${C_RESET}
  System    : ${OS_PRETTY:-unknown}
  Web server: ${WEB_SERVER:-<none>}  ($WEB_STATE)
  Database  : ${DATABASE:-<none>}
  Admin UI  : ${DB_UI:-<none>}${DB_UI_DIR:+  → /${DB_UI_DIR}}
  PHP-FPM   : ${PHP_VER_DETECTED:-<none>}
  Sites     : $SITE_COUNT

${C_BOLD}-----------------------------------------------------------------${C_RESET}
EOF

    if [ -z "$WEB_SERVER" ]; then
        cat <<EOF
  ${C_GREEN}1)${C_RESET} Install web server         (pick Apache/Nginx + MariaDB/PostgreSQL)
  ${C_DIM}2) Add new site               (install web server first)${C_RESET}
  ${C_DIM}3) Remove a site              (install web server first)${C_RESET}
  ${C_DIM}4) Uninstall everything       (nothing to uninstall)${C_RESET}
EOF
    else
        cat <<EOF
  ${C_GREEN}1)${C_RESET} Re-install                 (only if you want a different stack — uninstall first)
  ${C_GREEN}2)${C_RESET} Add new site              (vhost + isolated FPM pool + optional DB)
  ${C_GREEN}3)${C_RESET} Remove a site             (vhost + pool + optional user/files/cert/DB)
  ${C_RED}4)${C_RESET} Uninstall everything      ${C_RED}(destructive — purges packages + data)${C_RESET}
EOF
    fi

    cat <<EOF

  ${C_YELLOW}0)${C_RESET} Exit
${C_BOLD}-----------------------------------------------------------------${C_RESET}
EOF
}

while true; do
    show_menu
    read -u 3 -r -p "Select an action [0-4]: " choice
    case "$choice" in
        1)
            if [ -z "$WEB_SERVER" ]; then
                fresh_install_flow
            else
                echo ""
                echo "${C_YELLOW}A web server is already installed (${WEB_SERVER} + ${DATABASE}).${C_RESET}"
                echo "To switch stacks, run uninstall first (option 4), then install."
            fi
            ;;
        2)
            if [ -z "$WEB_SERVER" ]; then
                echo "${C_RED}No web server installed yet — pick option 1 first.${C_RESET}"
            else
                run_action "${WEB_SERVER}/add-site.sh"
            fi
            ;;
        3)
            if [ -z "$WEB_SERVER" ]; then
                echo "${C_RED}No web server installed yet — nothing to remove.${C_RESET}"
            else
                run_action "${WEB_SERVER}/remove-site.sh"
            fi
            ;;
        4)
            if [ -z "$WEB_SERVER" ]; then
                echo "${C_RED}Nothing to uninstall.${C_RESET}"
            else
                run_action "${WEB_SERVER}/uninstall.sh"
            fi
            ;;
        0|q|Q|exit) echo "Bye."; exit 0 ;;
        *) echo "${C_RED}Invalid choice: '$choice' — pick 0-4${C_RESET}" ;;
    esac
    echo ""
    read -u 3 -r -p "Press Enter to return to the menu..." _
done
