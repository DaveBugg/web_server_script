#!/bin/bash
# =============================================================================
# Web Server Manager — interactive menu
#
# Usage:
#   bash <(curl -fsSL https://raw.githubusercontent.com/USER/REPO/main/web-server.sh)
#   bash <(wget -qO- https://raw.githubusercontent.com/USER/REPO/main/web-server.sh)
#
# Override the script source (for testing forks / branches):
#   REPO_URL=https://raw.githubusercontent.com/myfork/web_server_script/dev \
#     bash <(curl -fsSL "$REPO_URL/web-server.sh")
#
# Each menu action downloads the corresponding sub-script and runs it.
# All sub-scripts honor env-var overrides — you can also call them directly:
#   bash <(curl -fsSL .../install.sh)
#   bash <(curl -fsSL .../add-site.sh)
#   etc.
#
# Version: 1.0
# =============================================================================

REPO_URL="${REPO_URL:-https://raw.githubusercontent.com/DaveBugg/web_server_script/main}"

# Open fd 3 from /dev/tty so the menu prompt works under `bash <(curl ...)`
if [ -e /dev/tty ]; then
    exec 3</dev/tty
else
    exec 3<&0
fi

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: this script must be run as root (use sudo)"
    exit 1
fi

# Colors (only if stdout is a tty)
if [ -t 1 ]; then
    C_BOLD=$'\e[1m';   C_RESET=$'\e[0m'
    C_CYAN=$'\e[36m';  C_GREEN=$'\e[32m';  C_YELLOW=$'\e[33m';  C_RED=$'\e[31m'
else
    C_BOLD=""; C_RESET=""; C_CYAN=""; C_GREEN=""; C_YELLOW=""; C_RED=""
fi

# Detect installed web server state
detect_state() {
    if command -v apache2 >/dev/null 2>&1 && systemctl is-active apache2 >/dev/null 2>&1; then
        STATE="${C_GREEN}installed${C_RESET}"
    elif command -v apache2 >/dev/null 2>&1; then
        STATE="${C_YELLOW}installed (not running)${C_RESET}"
    else
        STATE="${C_YELLOW}not installed${C_RESET}"
    fi

    SITE_COUNT=0
    if [ -d /etc/apache2/sites-available ]; then
        for f in /etc/apache2/sites-available/*.conf; do
            [ -f "$f" ] || continue
            n=$(basename "$f" .conf)
            case "$n" in 000-default|default-ssl|phpmyadmin) continue ;; esac
            SITE_COUNT=$((SITE_COUNT+1))
        done
    fi

    PHP_VER_DETECTED=""
    if [ -d /etc/php ]; then
        PHP_VER_DETECTED=$(ls /etc/php 2>/dev/null | sort -V | tail -1)
    fi

    OS_PRETTY=""
    if [ -f /etc/os-release ]; then
        OS_PRETTY=$(. /etc/os-release; echo "$PRETTY_NAME")
    fi
}

# Download a sub-script and exec it (preserves stdin from caller's tty)
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

show_menu() {
    detect_state
    clear 2>/dev/null || true
    cat <<EOF

${C_BOLD}=================================================================${C_RESET}
${C_BOLD}  Web Server Manager${C_RESET}
${C_BOLD}=================================================================${C_RESET}
  Apache + PHP-FPM + MariaDB + phpMyAdmin + HTTP/2 + Cloudflare

  System    : ${OS_PRETTY:-unknown}
  Web server: $STATE
  PHP-FPM   : ${PHP_VER_DETECTED:-not detected}
  Sites     : $SITE_COUNT

${C_BOLD}-----------------------------------------------------------------${C_RESET}
  ${C_GREEN}1)${C_RESET} Install web server         (Apache + PHP-FPM + MariaDB + phpMyAdmin)
  ${C_GREEN}2)${C_RESET} Add new site              (vhost + isolated PHP-FPM pool + SSL)
  ${C_GREEN}3)${C_RESET} Remove a site             (vhost + pool + optional user/files/cert)
  ${C_RED}4)${C_RESET} Uninstall everything      ${C_RED}(destructive — purges all packages + data)${C_RESET}

  ${C_YELLOW}0)${C_RESET} Exit
${C_BOLD}-----------------------------------------------------------------${C_RESET}
EOF
}

while true; do
    show_menu
    read -u 3 -r -p "Select an action [0-4]: " choice
    case "$choice" in
        1) run_action install.sh      ;;
        2) run_action add-site.sh     ;;
        3) run_action remove-site.sh  ;;
        4) run_action uninstall.sh    ;;
        0|q|Q|exit) echo "Bye."; exit 0 ;;
        *) echo "${C_RED}Invalid choice: '$choice' — pick 0-4${C_RESET}" ;;
    esac
    echo ""
    read -u 3 -r -p "Press Enter to return to the menu..." _
done
