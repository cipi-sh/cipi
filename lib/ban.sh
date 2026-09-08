#!/bin/bash
#############################################
# Cipi — Fail2ban (+ CrowdSec, when enabled) IP management
#############################################

ban_command() {
    local sub="${1:-}"; shift||true
    case "$sub" in
        list)   _ban_list ;;
        unban)  _ban_unban "$@" ;;
        *)      error "Usage: cipi ban list | cipi ban unban <IP>"; exit 1 ;;
    esac
}

_ban_fail2ban_running() {
    systemctl is-active --quiet fail2ban 2>/dev/null
}

_ban_crowdsec_running() {
    command -v cscli >/dev/null 2>&1 && systemctl is-active --quiet crowdsec 2>/dev/null
}

_ban_list() {
    local f2b=0 cs=0
    _ban_fail2ban_running && f2b=1
    _ban_crowdsec_running && cs=1
    if [[ "$f2b" -eq 0 && "$cs" -eq 0 ]]; then
        error "Neither fail2ban nor CrowdSec is running"
        exit 1
    fi

    echo ""
    echo -e "  ${BOLD}Banned IPs${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    local found=0

    if [[ "$f2b" -eq 1 ]]; then
        local jails
        jails=$(fail2ban-client status | grep "Jail list" | sed 's/.*://;s/,/ /g' | xargs)
        local jail
        for jail in $jails; do
            local banned count
            banned=$(fail2ban-client status "$jail" | grep "Banned IP list" | sed 's/.*://' | xargs)
            count=$(fail2ban-client status "$jail" | grep "Currently banned" | grep -oE '[0-9]+')
            if [[ "${count:-0}" -gt 0 ]]; then
                echo -e "\n  ${BOLD}${CYAN}fail2ban:${jail}${NC} ${DIM}(${count} banned)${NC}"
                local ip
                for ip in $banned; do
                    found=1
                    echo -e "    ${RED}●${NC} ${ip}"
                done
            fi
        done
    fi

    if [[ "$cs" -eq 1 ]]; then
        # `cscli decisions list -o json` returns ALERTS, each carrying its bans
        # under .decisions[]. Reading .value at the top level yielded an empty
        # string for every row, so the header printed a count and listed nobody.
        local raw rows n=0
        raw=$(cscli decisions list -o json 2>/dev/null || echo '[]')
        rows=$(echo "$raw" \
            | jq -r '.[]?.decisions[]? | [.value, (.scenario // .origin // .type // "")] | @tsv' \
            2>/dev/null || true)
        n=$(printf '%s' "$rows" | grep -c . || true)
        if [[ "${n:-0}" -gt 0 ]]; then
            echo -e "\n  ${BOLD}${CYAN}crowdsec${NC} ${DIM}(${n} decisions)${NC}"
            local val reason
            while IFS=$'\t' read -r val reason; do
                [[ -z "$val" ]] && continue
                found=1
                echo -e "    ${RED}●${NC} ${val}  ${DIM}${reason}${NC}"
            done <<< "$rows"
        fi
    fi

    if [[ "$found" -eq 0 ]]; then
        echo -e "\n  ${GREEN}No banned IPs${NC}"
    fi

    echo ""
}

_ban_unban() {
    local ip="${1:-}"
    [[ -z "$ip" ]] && { error "Usage: cipi ban unban <IP>"; exit 1; }

    local f2b=0 cs=0
    _ban_fail2ban_running && f2b=1
    _ban_crowdsec_running && cs=1
    if [[ "$f2b" -eq 0 && "$cs" -eq 0 ]]; then
        error "Neither fail2ban nor CrowdSec is running"
        exit 1
    fi

    local unbanned=0

    if [[ "$f2b" -eq 1 ]]; then
        local jails jail
        jails=$(fail2ban-client status | grep "Jail list" | sed 's/.*://;s/,/ /g' | xargs)
        for jail in $jails; do
            if fail2ban-client status "$jail" | grep -q "$ip"; then
                fail2ban-client set "$jail" unbanip "$ip" &>/dev/null
                echo -e "  Unbanned ${CYAN}${ip}${NC} from ${BOLD}fail2ban:${jail}${NC}"
                unbanned=1
            fi
        done
    fi

    if [[ "$cs" -eq 1 ]]; then
        # `cscli decisions delete` exits 0 whether it removed one decision or
        # none, so ask first — otherwise every unban claimed success.
        local had
        had=$(cscli decisions list --ip "$ip" -o json 2>/dev/null \
            | jq '[.[]?.decisions[]?] | length' 2>/dev/null || echo 0)
        if [[ "${had:-0}" -gt 0 ]]; then
            cscli decisions delete --ip "$ip" >/dev/null 2>&1 || true
            echo -e "  Unbanned ${CYAN}${ip}${NC} from ${BOLD}crowdsec${NC} ${DIM}(${had} decision(s))${NC}"
            unbanned=1
        fi
    fi

    if [[ "$unbanned" -eq 0 ]]; then
        warn "${ip} is not currently banned"
    else
        log_action "ban unban ${ip}"
        success "IP ${ip} unbanned"
    fi
}
