#!/bin/bash
#############################################
# Cipi — Fail2ban IP Management
#############################################

ban_command() {
    local sub="${1:-}"; shift||true
    case "$sub" in
        list)   _ban_list ;;
        unban)  _ban_unban "$@" ;;
        *)      error "Usage: cipi ban list | cipi ban unban <IP>"; exit 1 ;;
    esac
}

_ban_list() {
    if ! systemctl is-active --quiet fail2ban 2>/dev/null; then
        error "Fail2ban is not running"
        exit 1
    fi

    echo ""
    echo -e "  ${BOLD}Banned IPs${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local jails found=0
    jails=$(fail2ban-client status | grep "Jail list" | sed 's/.*://;s/,/ /g' | xargs)

    for jail in $jails; do
        local banned
        banned=$(fail2ban-client status "$jail" | grep "Banned IP list" | sed 's/.*://' | xargs)
        local count
        count=$(fail2ban-client status "$jail" | grep "Currently banned" | grep -oE '[0-9]+')

        if [[ "${count:-0}" -gt 0 ]]; then
            echo -e "\n  ${BOLD}${CYAN}${jail}${NC} ${DIM}(${count} banned)${NC}"
            for ip in $banned; do
                found=1
                echo -e "    ${RED}●${NC} ${ip}"
            done
        fi
    done

    if [[ "$found" -eq 0 ]]; then
        echo -e "\n  ${GREEN}No banned IPs${NC}"
    fi

    echo ""
}

_ban_unban() {
    local ip="${1:-}"
    [[ -z "$ip" ]] && { error "Usage: cipi ban unban <IP>"; exit 1; }

    if ! systemctl is-active --quiet fail2ban 2>/dev/null; then
        error "Fail2ban is not running"
        exit 1
    fi

    local jails unbanned=0
    jails=$(fail2ban-client status | grep "Jail list" | sed 's/.*://;s/,/ /g' | xargs)

    for jail in $jails; do
        if fail2ban-client status "$jail" | grep -q "$ip"; then
            fail2ban-client set "$jail" unbanip "$ip" &>/dev/null
            echo -e "  Unbanned ${CYAN}${ip}${NC} from ${BOLD}${jail}${NC}"
            unbanned=1
        fi
    done

    if [[ "$unbanned" -eq 0 ]]; then
        warn "${ip} is not currently banned in any jail"
    else
        log_action "ban unban ${ip}"
        success "IP ${ip} unbanned"
    fi
}
