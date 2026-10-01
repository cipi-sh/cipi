#!/bin/bash
#############################################
# Cipi — Firewall (UFW) + fail2ban login threshold
#############################################

# Failed SSH logins before fail2ban bans the address. Cipi's jail.local sets 3;
# another value lives in this drop-in, which fail2ban reads after jail.local
# (jail.conf, jail.d/*.conf, jail.local, jail.d/*.local), so it wins and a
# migration that rewrites jail.local does not undo it.
[[ -z "${FIREWALL_F2B_ATTEMPTS:-}" ]] && readonly FIREWALL_F2B_ATTEMPTS="/etc/fail2ban/jail.d/cipi-attempts.local"
[[ -z "${FIREWALL_ATTEMPTS_DEFAULT:-}" ]] && readonly FIREWALL_ATTEMPTS_DEFAULT=3

firewall_command() {
    local sub="${1:-}"; shift||true
    case "$sub" in
        allow) local p="${1:-}"; shift||true; [[ -z "$p" ]] && { error "Usage: cipi firewall allow <port> [--from=IP]"; exit 1; }
               parse_args "$@"
               if [[ -n "${ARG_from:-}" ]]; then ufw allow from "${ARG_from}" to any port "$p" proto tcp
               else ufw allow "$p/tcp"; fi
               success "Allowed ${p}/tcp" ;;
        deny)  local p="${1:-}"; [[ -z "$p" ]] && { error "Usage: cipi firewall deny <port>"; exit 1; }
               ufw deny "$p/tcp"; success "Denied ${p}/tcp" ;;
        list)  echo ""; ufw status numbered 2>/dev/null; echo "" ;;
        attempts)
               if [[ -z "${1:-}" ]]; then _firewall_attempts_show; else _firewall_attempts_set "$1"; fi ;;
        *) error "Use: allow deny list attempts"; exit 1 ;;
    esac
}

_firewall_f2b_running() {
    systemctl is-active --quiet fail2ban 2>/dev/null
}

# The drop-in's value, empty when there is none.
_firewall_attempts_custom() {
    [[ -f "$FIREWALL_F2B_ATTEMPTS" ]] || return 0
    sed -n 's/^maxretry[[:space:]]*=[[:space:]]*\([0-9][0-9]*\)[[:space:]]*$/\1/p' "$FIREWALL_F2B_ATTEMPTS" | head -1
}

# A live sshd jail setting, empty when fail2ban is not running.
_firewall_f2b_get() {
    _firewall_f2b_running || return 0
    fail2ban-client get sshd "$1" 2>/dev/null | grep -E '^[0-9]+$' | head -1 || true
}

_firewall_duration() {
    local s="$1"
    if   (( s % 86400 == 0 )); then echo "$((s / 86400))d"
    elif (( s % 3600 == 0 ));  then echo "$((s / 3600))h"
    elif (( s % 60 == 0 ));    then echo "$((s / 60))m"
    else echo "${s}s"; fi
}

_firewall_attempts_show() {
    local custom live n findtime bantime
    custom=$(_firewall_attempts_custom)
    live=$(_firewall_f2b_get maxretry)
    n="${live:-${custom:-$FIREWALL_ATTEMPTS_DEFAULT}}"
    findtime=$(_firewall_f2b_get findtime)
    bantime=$(_firewall_f2b_get bantime)

    echo ""
    echo -e "  ${BOLD}SSH login attempts${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ -n "$custom" ]]; then
        printf "  %-22s ${CYAN}%s${NC} ${DIM}(set with cipi firewall attempts; default %s)${NC}\n" "Failed logins → ban" "$n" "$FIREWALL_ATTEMPTS_DEFAULT"
    else
        printf "  %-22s ${CYAN}%s${NC} ${DIM}(default)${NC}\n" "Failed logins → ban" "$n"
    fi
    [[ -n "$findtime" ]] && printf "  %-22s %s\n" "Counted over" "$(_firewall_duration "$findtime")"
    [[ -n "$bantime" ]]  && printf "  %-22s %s ${DIM}(longer for repeat offenders)${NC}\n" "Ban" "$(_firewall_duration "$bantime")"
    if ! _firewall_f2b_running; then
        echo -e "  ${YELLOW}fail2ban is not running — nobody is being banned${NC}"
    elif [[ -n "$custom" && -n "$live" && "$custom" != "$live" ]]; then
        echo -e "  ${YELLOW}fail2ban runs with ${live}, the saved value is ${custom} — cipi service restart fail2ban${NC}"
    fi
    echo ""
    echo -e "  ${DIM}Change: cipi firewall attempts <1-100> | default${NC}"
    echo ""
}

_firewall_attempts_set() {
    local want="$1" n=""
    if [[ "$want" != "default" ]]; then
        if [[ ! "$want" =~ ^[0-9]{1,3}$ ]] || (( 10#$want < 1 || 10#$want > 100 )); then
            error "Usage: cipi firewall attempts [<1-100>|default]"
            exit 1
        fi
        n=$((10#$want))
    fi
    command -v fail2ban-client >/dev/null 2>&1 || { error "fail2ban is not installed"; exit 1; }

    local had=false prev=""
    if [[ -f "$FIREWALL_F2B_ATTEMPTS" ]]; then
        had=true
        prev=$(cat "$FIREWALL_F2B_ATTEMPTS")
    fi

    if [[ -z "$n" ]]; then
        rm -f "$FIREWALL_F2B_ATTEMPTS"
    else
        mkdir -p "$(dirname "$FIREWALL_F2B_ATTEMPTS")"
        cat > "$FIREWALL_F2B_ATTEMPTS" <<EOF
# Written by cipi firewall attempts. Read after jail.local, so this value wins.
[sshd]
maxretry = ${n}
EOF
        chmod 644 "$FIREWALL_F2B_ATTEMPTS"
    fi

    # A configuration fail2ban refuses would leave the server without bans at
    # the next restart: put the previous state back.
    if ! fail2ban-client -t >/dev/null 2>&1; then
        if [[ "$had" == true ]]; then
            printf '%s\n' "$prev" > "$FIREWALL_F2B_ATTEMPTS"
        else
            rm -f "$FIREWALL_F2B_ATTEMPTS"
        fi
        error "fail2ban rejected the configuration — nothing changed (check: fail2ban-client -t)"
        exit 1
    fi

    local shown="${n:-$FIREWALL_ATTEMPTS_DEFAULT}"
    if _firewall_f2b_running; then
        fail2ban-client reload >/dev/null 2>&1 || systemctl reload fail2ban >/dev/null 2>&1 || true
        local live; live=$(_firewall_f2b_get maxretry)
        if [[ -n "$n" && "$live" != "$n" ]]; then
            warn "Saved, but fail2ban still runs with '${live:-?}' — run: cipi service restart fail2ban"
        fi
        if [[ -z "$n" && -n "$live" ]]; then shown="$live"; fi
    else
        warn "fail2ban is not running — the value applies when it starts"
    fi

    log_action "firewall attempts ${want}"
    if [[ -z "$n" ]]; then
        success "Back to the default: ${shown} failed SSH logins ban the address"
    else
        success "${shown} failed SSH login(s) now ban the address"
    fi
    if [[ "$n" == "1" ]]; then
        warn "One mistyped password bans its owner too — unban with: cipi ban unban <IP>"
    fi
}
