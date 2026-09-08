#!/bin/bash
#############################################
# Cipi — punch the CrowdSec rescue port through
# the bouncer's DROP-all chain (and an INPUT
# ACCEPT for iptables-legacy). Idempotent.
# Called on listener start and as ExecStartPost
# of crowdsec-firewall-bouncer (which rebuilds
# its table on every restart).
#############################################
set -u

CONFIG="${CIPI_CONFIG:-/etc/cipi}"
PORT_FILE="${CONFIG}/crowdsec-rescue.port"
[[ -s "$PORT_FILE" ]] || exit 0

PORT=$(tr -d '[:space:]' < "$PORT_FILE")
[[ "$PORT" =~ ^[0-9]+$ ]] || exit 0
[[ "$PORT" -ge 1024 && "$PORT" -le 65535 ]] || exit 0

_nft_has() {
    local fam="$1" tab="$2" chain="$3"
    nft list chain "$fam" "$tab" "$chain" 2>/dev/null | grep -Eq "tcp dport ${PORT} .*accept"
}

_nft_punch() {
    local fam="$1" tab="$2" chain="$3"
    nft list chain "$fam" "$tab" "$chain" >/dev/null 2>&1 || return 0
    _nft_has "$fam" "$tab" "$chain" && return 0
    nft insert rule "$fam" "$tab" "$chain" tcp dport "$PORT" accept 2>/dev/null || true
}

if command -v nft >/dev/null 2>&1; then
    # CrowdSec 1.6+ inet table, older ip/ip6 split, plus a few aliases.
    for spec in \
        "inet crowdsec crowdsec-chain" \
        "inet crowdsec input" \
        "ip crowdsec crowdsec-chain" \
        "ip crowdsec crowdsec" \
        "ip6 crowdsec6 crowdsec6-chain" \
        "ip6 crowdsec6 crowdsec6" \
        "inet crowdsec6 crowdsec6-chain"
    do
        set -- $spec
        _nft_punch "$1" "$2" "$3"
    done
    # Any other table whose name contains crowdsec.
    while read -r fam tab; do
        [[ "${tab:-}" == *crowdsec* ]] || continue
        while read -r chain; do
            [[ -n "${chain:-}" ]] || continue
            _nft_punch "$fam" "$tab" "$chain"
        done < <(nft -a list table "$fam" "$tab" 2>/dev/null | awk '/chain /{print $2}')
    done < <(nft list tables 2>/dev/null | awk '{print $2, $3}')
fi

_ipt_punch() {
    local bin="$1"
    command -v "$bin" >/dev/null 2>&1 || return 0
    local chains c
    chains=$("$bin" -S 2>/dev/null | awk '/^:CROWDSEC/{gsub(/^:/,"",$1); gsub(/ .*/,"",$1); print $1}')
    for c in $chains CROWDSEC CROWDSEC_CHAIN CROWDSEC_BLOCK; do
        "$bin" -n -L "$c" >/dev/null 2>&1 || continue
        if "$bin" -n -L "$c" 2>/dev/null | grep -q "dpt:${PORT}"; then
            continue
        fi
        "$bin" -I "$c" 1 -p tcp --dport "$PORT" -j ACCEPT 2>/dev/null || true
    done
    if ! "$bin" -n -L INPUT 2>/dev/null | grep -q "dpt:${PORT}.*cipi-crowdsec-rescue"; then
        "$bin" -I INPUT 1 -p tcp --dport "$PORT" -m comment --comment cipi-crowdsec-rescue -j ACCEPT 2>/dev/null || true
    fi
}

_ipt_punch iptables
_ipt_punch ip6tables

exit 0
