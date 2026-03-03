#!/bin/bash
#############################################
# Cipi — PHP Version Management
#############################################

readonly _PHP_EXT="fpm common cli curl bcmath mbstring mysql sqlite3 pgsql memcached zip xml soap gd imagick intl"

php_command() {
    local sub="${1:-}"; shift||true
    case "$sub" in
        install) _php_install "$@" ;;
        remove)  _php_remove "$@" ;;
        list|ls) _php_list ;;
        *) error "Use: install remove list"; exit 1 ;;
    esac
}

_php_install() {
    local v="${1:-}"
    [[ -z "$v" ]] && { error "Usage: cipi php install <7.4|8.0|8.1|8.2|8.3|8.4|8.5>"; exit 1; }
    validate_php_version "$v" || { error "Invalid: $v"; exit 1; }
    php_is_installed "$v" && { info "PHP $v already installed"; return; }
    step "Adding PPA..."
    add-apt-repository -y ppa:ondrej/php &>/dev/null; apt-get update -qq
    step "Installing PHP ${v}..."
    local pkgs=""
    for e in $_PHP_EXT; do pkgs+=" php${v}-${e}"; done
    apt-get install -y -qq $pkgs
    cat > "/etc/php/${v}/fpm/conf.d/99-cipi.ini" <<EOF
memory_limit = 256M
upload_max_filesize = 256M
post_max_size = 256M
max_execution_time = 300
max_input_time = 300
expose_php = Off
EOF
    cat > "/etc/php/${v}/fpm/pool.d/www.conf" <<POOLEOF
[www]
user = www-data
group = www-data
listen = /run/php/php${v}-fpm.sock
listen.owner = www-data
listen.group = www-data
pm = ondemand
pm.max_children = 2
pm.process_idle_timeout = 10s
POOLEOF
    systemctl restart "php${v}-fpm"; systemctl enable "php${v}-fpm"
    log_action "PHP INSTALLED: $v"; success "PHP ${v} installed"
}

_php_remove() {
    local v="${1:-}"
    [[ -z "$v" ]] && { error "Usage: cipi php remove <ver>"; exit 1; }
    validate_php_version "$v" || { error "Invalid: $v"; exit 1; }
    if [[ -f "${CIPI_CONFIG}/apps.json" ]]; then
        local using; using=$(jq -r --arg v "$v" 'to_entries[]|select(.value.php==$v)|.key' "${CIPI_CONFIG}/apps.json" 2>/dev/null)
        [[ -n "$using" ]] && { error "In use by: $using"; exit 1; }
    fi
    confirm "Remove PHP ${v}?" || return
    systemctl stop "php${v}-fpm" 2>/dev/null; systemctl disable "php${v}-fpm" 2>/dev/null
    apt-get purge -y "php${v}-*" &>/dev/null; apt-get autoremove -y &>/dev/null
    log_action "PHP REMOVED: $v"; success "PHP ${v} removed"
}

_php_list() {
    echo -e "\n${BOLD}PHP Versions${NC}"
    for v in 7.4 8.0 8.1 8.2 8.3 8.4 8.5; do
        if php_is_installed "$v"; then
            local st="${RED}stopped" c="${RED}"
            systemctl is-active --quiet "php${v}-fpm" 2>/dev/null && st="running" && c="${GREEN}"
            local n=0; [[ -f "${CIPI_CONFIG}/apps.json" ]] && n=$(jq --arg v "$v" '[to_entries[]|select(.value.php==$v)]|length' "${CIPI_CONFIG}/apps.json" 2>/dev/null||echo 0)
            printf "  PHP %-6s ${c}● %-8s${NC}  %d apps\n" "$v" "$st" "$n"
        fi
    done; echo ""
}
