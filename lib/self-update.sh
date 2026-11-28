#!/bin/bash
#############################################
# Cipi — Self-Update
#############################################

# The time of a notification is common.sh's (and follows `cipi notification
# timezone`); loaded on its own, this file still has a clock.
declare -f notify_now >/dev/null 2>&1 || notify_now() { date "$@" '+%Y-%m-%d %H:%M:%S %Z'; }

readonly _CIPI_REPO="cipi-sh/cipi"
readonly _CIPI_SELFUPDATE_BACKUP_KEEP=7

_selfupdate_prune_backups() {
    local keep="${_CIPI_SELFUPDATE_BACKUP_KEEP}" dir count=0 removed=0
    while IFS= read -r dir; do
        [[ -d "$dir" ]] || continue
        ((count++)) || true
        if (( count > keep )); then
            rm -rf "$dir" && ((removed++)) || true
        fi
    done < <(ls -1dt /opt/cipi.bak.* 2>/dev/null)
    if (( removed > 0 )); then
        info "Pruned ${removed} old self-update backup(s) (keeping ${keep} newest)"
        log_action "SELF-UPDATE: pruned ${removed} /opt/cipi.bak.* (keep=${keep})"
    fi
}

# ── How this server takes updates: signature, delay ──────────
#
# By default the nightly `cipi self-update` installs what is on the branch,
# as it always did. Two safeguards can be turned on, alone or together
# (cipi self-update policy):
#
#   --verify=on   install a release only when its tag v<version> is signed
#                 by a key of /etc/cipi/release-signers and points at what was
#                 downloaded. The signers are the ones already on this server:
#                 a release cannot vouch for itself, it can only hand over a
#                 new list once it has been verified with the old one.
#   --delay=12h   install a new commit only after this server has seen it for
#                 that long — time for a bad release, or a hijacked account,
#                 to be noticed and reverted before it lands here. The clock
#                 is this server's own: a commit date can be forged.
#
# Kept in the vault as selfupdate.json: {verify: bool, delay_hours: int}; what
# is waiting in selfupdate-state.json: {installed_sha, pending: {sha, version,
# first_seen}, held: {reason, at}}.

readonly _SU_SIGNERS="${CIPI_CONFIG}/release-signers"
readonly _SU_DELAY_CRON="${CIPI_SELFUPDATE_DELAY_CRON:-/etc/cron.d/cipi-selfupdate-delay}"
readonly _SU_DELAY_DEFAULT=12

# An empty or missing file is the default: jq prints nothing for no input.
_su_policy() {
    local j; j=$(vault_read selfupdate.json 2>/dev/null | jq -c '{verify: (.verify // false), delay_hours: (.delay_hours // 0)}' 2>/dev/null)
    printf '%s\n' "${j:-{\"verify\":false,\"delay_hours\":0\}}"
}
_su_state() {
    local j; j=$(vault_read selfupdate-state.json 2>/dev/null | jq -c 'if type == "object" then . else {} end' 2>/dev/null)
    printf '%s\n' "${j:-{\}}"
}
_su_state_write()  { printf '%s' "$1" | vault_write selfupdate-state.json; }
_su_verify_on()    { [[ "$(_su_policy | jq -r '.verify')" == "true" ]]; }
_su_delay_hours()  { _su_policy | jq -r '.delay_hours'; }

# The keys a release may be signed with: "<principal> <type> <key>" lines of
# an allowed_signers file (git, gpg.format=ssh).
_su_signers_count() { grep -cE '^[^#[:space:]][^[:space:]]*[[:space:]].*(ssh-ed25519|ssh-rsa|ecdsa-sha2-|sk-ssh-ed25519|sk-ecdsa)' "${1:-$_SU_SIGNERS}" 2>/dev/null || echo 0; }

# "<sha256 fingerprint> <principal>" of each signer.
_su_signers_list() {
    local f="${1:-$_SU_SIGNERS}" line principal key
    [[ -f "$f" ]] || return 0
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# || -z "${line// }" ]] && continue
        principal="${line%% *}"
        # A hardware key's type has a suffix: sk-ssh-ed25519@openssh.com.
        key=$(grep -oE '(sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com|ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+)[[:space:]]+[A-Za-z0-9+/=]+' <<< "$line" | head -1)
        [[ -n "$key" ]] || continue
        echo "$(ssh-keygen -lf /dev/stdin <<< "$key" 2>/dev/null | awk '{print $2}') ${principal}"
    done < "$f"
}

# The tag v<version> is signed by a known key and is the commit downloaded.
# Prints why not, and fails, when it is not.
_su_verify_release() {   # <tree> <version>
    local tree="$1" nv="$2" head tagc out rc=0
    if (( $(_su_signers_count) == 0 )); then
        echo "no signer is trusted on this server (${_SU_SIGNERS} has no key)"
        return 1
    fi
    command -v ssh-keygen >/dev/null 2>&1 || { echo "ssh-keygen is missing (apt-get install openssh-client)"; return 1; }
    out=$(GIT_TERMINAL_PROMPT=0 _cipi_run_timed 120 git -C "$tree" fetch --depth 1 --no-tags origin "refs/tags/v${nv}:refs/tags/v${nv}" 2>&1) || {
        echo "the release has no tag v${nv} — it was not signed (git: $(tail -1 <<< "$out"))"
        return 1
    }
    head=$(git -C "$tree" rev-parse HEAD 2>/dev/null)
    tagc=$(git -C "$tree" rev-parse "v${nv}^{commit}" 2>/dev/null)
    if [[ -z "$head" || "$head" != "$tagc" ]]; then
        echo "the branch is at ${head:0:12}, not at the signed tag v${nv} (${tagc:0:12}) — what would be installed is not what was signed"
        return 1
    fi
    [[ "$(git -C "$tree" cat-file -t "v${nv}" 2>/dev/null)" == "tag" ]] || { echo "v${nv} is a lightweight tag: it carries no signature"; return 1; }
    out=$(git -C "$tree" -c gpg.format=ssh -c "gpg.ssh.allowedSignersFile=${_SU_SIGNERS}" verify-tag "v${nv}" 2>&1) || rc=$?
    if (( rc != 0 )) || ! grep -q 'Good "git" signature' <<< "$out"; then
        echo "the signature of v${nv} is not one of a trusted key: $(grep -v '^[[:space:]]*$' <<< "$out" | tail -1)"
        return 1
    fi
    grep -o 'Good "git" signature for [^ ]* with [^ ]* key SHA256:[A-Za-z0-9+/]*' <<< "$out" | head -1
    return 0
}

# With the check on, an older release is never installed over this one: an
# account that can move the branch could otherwise point it at an old, signed
# release with a known flaw. Prints why, and fails, when <version> is older.
_su_downgrade() {   # <version>
    local nv="$1" cur="${CIPI_VERSION:-}"
    [[ -n "$cur" && "$nv" != "$cur" ]] || return 1
    [[ "$(printf '%s\n%s\n' "$nv" "$cur" | sort -V | head -1)" == "$nv" ]] || return 1
    echo "v${nv} is older than the v${cur} installed here — a signed release is not installed over a newer one"
}

# A new commit is installed once this server has seen it for the delay.
# 0: go ahead. 1: held — and the reason is printed.
_su_delay_gate() {   # <sha> <version>
    local sha="$1" nv="$2" hours state now first due
    hours=$(_su_delay_hours)
    [[ "$hours" =~ ^[0-9]+$ ]] && (( hours > 0 )) || return 0
    state=$(_su_state); now=$(date +%s)
    [[ "$(jq -r '.installed_sha // ""' <<< "$state")" == "$sha" ]] && return 0
    # Which commit is installed is known from the first update made by this
    # version on. Before that, the version running now is not a new release:
    # it is taken as installed, rather than held as if it were one.
    if [[ -z "$(jq -r '.installed_sha // ""' <<< "$state")" && "$nv" == "${CIPI_VERSION:-}" ]]; then
        _su_state_write "$(jq -c --arg s "$sha" '.installed_sha = $s | del(.pending) | del(.held)' <<< "$state")"
        return 0
    fi
    if [[ "$(jq -r '.pending.sha // ""' <<< "$state")" != "$sha" ]]; then
        state=$(jq -c --arg s "$sha" --arg v "$nv" --argjson t "$now" '.pending = {sha: $s, version: $v, first_seen: $t}' <<< "$state")
        _su_state_write "$state"
    fi
    first=$(jq -r '.pending.first_seen' <<< "$state")
    due=$(( first + hours * 3600 ))
    (( now >= due )) && return 0
    echo "v${nv} (${sha:0:12}) first seen $(date -d "@${first}" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || echo "$first"); installed from $(date -d "@${due}" '+%Y-%m-%d %H:%M %Z' 2>/dev/null || echo "$due") (delay ${hours}h)"
    return 1
}

_su_held() {   # <reason>
    _su_state_write "$(_su_state | jq -c --arg r "$1" --argjson t "$(date +%s)" '.held = {reason: $r, at: $t}')"
}

# The hourly check while a delay is on: a pending release is installed once it
# is due, without waiting for the night.
_su_delay_cron_sync() {
    local hours; hours=$(_su_delay_hours)
    if [[ "$hours" =~ ^[0-9]+$ ]] && (( hours > 0 )); then
        printf '%s\n' "# Cipi: a release held by the update delay (cipi self-update policy) is installed once it is due" \
            "SHELL=/bin/bash" "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
            "17 * * * * root /usr/local/bin/cipi self-update --if-due >> /var/log/cipi/cipi.log 2>&1" > "$_SU_DELAY_CRON" 2>/dev/null \
            && chmod 644 "$_SU_DELAY_CRON" 2>/dev/null || true
    else
        rm -f "$_SU_DELAY_CRON" 2>/dev/null || true
    fi
}

_su_policy_json() {
    local p s signers
    p=$(_su_policy); s=$(_su_state)
    signers=$(_su_signers_list | jq -R 'split(" ") | {fingerprint: .[0], principal: (.[1] // "")}' | jq -s '.')
    local shipped; shipped=$(_su_signers_list "${CIPI_SHIPPED_SIGNERS:-/opt/cipi/release-signers}" | jq -R 'split(" ") | {fingerprint: .[0], principal: (.[1] // "")}' | jq -s '.')
    jq -n --argjson p "$p" --argjson s "$s" --argjson g "$signers" --argjson sh "$shipped" --arg f "$_SU_SIGNERS" --arg v "${CIPI_VERSION:-}" \
        --argjson def "$_SU_DELAY_DEFAULT" '
        $p + {delay_default_hours: $def, signers_file: $f, signers: $g, signers_ready: ($g | length > 0), shipped_signers: $sh,
              version: $v, installed_sha: ($s.installed_sha // null), pending: ($s.pending // null), held: ($s.held // null)}'
}

# cipi self-update policy [--verify=on|off] [--delay=12h|off] [--json]
selfupdate_policy() {
    parse_args "$@"
    local p changed=false
    p=$(_su_policy)
    if [[ -n "${ARG_verify:-}" ]]; then
        case "${ARG_verify}" in
            on|true|yes)
                if (( $(_su_signers_count) == 0 )); then
                    # The first trust: the list shipped with the installed release,
                    # once its fingerprints are the ones published on cipi.sh.
                    local shipped="${CIPI_SHIPPED_SIGNERS:-/opt/cipi/release-signers}" fps
                    if (( $(_su_signers_count "$shipped") == 0 )); then
                        error "No signer to trust: neither ${_SU_SIGNERS} nor ${shipped} has a key — nothing changed"
                        echo "  Write it by hand, one line per key:  <principal> namespaces=\"git\" ssh-ed25519 AAAA…"
                        exit 1
                    fi
                    fps=$(_su_signers_list "$shipped" | awk '{print $1}')
                    if [[ -n "${ARG_fingerprint:-}" ]]; then
                        grep -qxF -- "${ARG_fingerprint}" <<< "$fps" || {
                            error "${ARG_fingerprint} is not the fingerprint of the signers shipped with this release — nothing changed"
                            echo "  They are: $(paste -sd' ' - <<< "$fps")"
                            exit 1
                        }
                    elif [[ -t 0 && "${SUDO_USER:-}" != "www-data" ]]; then
                        echo -e "\n  Releases will be checked against these keys:"
                        _su_signers_list "$shipped" | sed 's/^/    /'
                        echo -e "  ${DIM}Compare them with the ones published at https://cipi.sh/docs/self-update#signers${NC}"
                        confirm "They are the same — trust them?" || { info "Nothing changed"; return 0; }
                    else
                        error "Say which key you checked: --fingerprint=SHA256:… (published at https://cipi.sh/docs/self-update#signers) — nothing changed"
                        echo "  Shipped with this release: $(paste -sd' ' - <<< "$fps")"
                        exit 1
                    fi
                    install -m 644 "$shipped" "$_SU_SIGNERS" || { error "Could not write ${_SU_SIGNERS}"; exit 1; }
                fi
                p=$(jq -c '.verify = true' <<< "$p") ;;
            off|false|no) p=$(jq -c '.verify = false' <<< "$p") ;;
            *) error "--verify is on or off"; exit 1 ;;
        esac
        changed=true
    fi
    if [[ -n "${ARG_delay+x}" && -n "${ARG_delay}" ]]; then
        local d="${ARG_delay}" h
        case "$d" in
            off|0|none|false) h=0 ;;
            on|true) h=$_SU_DELAY_DEFAULT ;;
            *h) h="${d%h}" ;;
            # Checked before any arithmetic: bash evaluates an array subscript
            # in $(( )), so text from the command line never goes in one.
            *d) h="${d%d}"; [[ "$h" =~ ^[0-9]{1,3}$ ]] && h=$(( 10#$h * 24 )) || h="" ;;
            *) h="$d" ;;
        esac
        [[ "$h" =~ ^[0-9]{1,3}$ ]] && (( 10#$h <= 168 )) || { error "--delay is a number of hours (12h), of days (2d), or off — a week at most"; exit 1; }
        h=$(( 10#$h ))
        p=$(jq -c --argjson h "$h" '.delay_hours = $h' <<< "$p")
        changed=true
    fi
    if [[ "$changed" == true ]]; then
        printf '%s' "$p" | vault_write selfupdate.json
        _su_delay_cron_sync
        log_action "SELF-UPDATE POLICY: verify=$(jq -r '.verify' <<< "$p") delay=$(jq -r '.delay_hours' <<< "$p")h"
    fi
    if [[ "${ARG_json:-}" == "true" ]]; then _su_policy_json; return 0; fi
    local j; j=$(_su_policy_json)
    echo -e "\n${BOLD}How this server updates Cipi${NC}"
    if [[ "$(jq -r '.verify' <<< "$j")" == true ]]; then
        echo -e "  Signature   ${GREEN}required${NC} — a release is installed only when its tag v<version> is signed by:"
    else
        echo -e "  Signature   ${DIM}not checked${NC} (cipi self-update policy --verify=on)"
    fi
    jq -r '.signers[] | "                \(.fingerprint)  \(.principal)"' <<< "$j"
    [[ "$(jq -r '.signers_ready' <<< "$j")" == true ]] || echo -e "              ${DIM}no signer in ${_SU_SIGNERS} yet${NC}"
    local h; h=$(jq -r '.delay_hours' <<< "$j")
    if (( h > 0 )); then
        echo -e "  Delay       ${GREEN}${h}h${NC} — a new commit is installed once this server has seen it for that long"
    else
        echo -e "  Delay       ${DIM}none${NC} — installed the night it is published (cipi self-update policy --delay=${_SU_DELAY_DEFAULT}h)"
    fi
    if [[ "$(jq -r '.pending // empty' <<< "$j")" != "" ]]; then
        echo -e "  Waiting     v$(jq -r '.pending.version' <<< "$j") ($(jq -r '.pending.sha[0:12]' <<< "$j")), seen $(date -d "@$(jq -r '.pending.first_seen' <<< "$j")" '+%Y-%m-%d %H:%M %Z' 2>/dev/null)"
    fi
    if [[ "$(jq -r '.held // empty' <<< "$j")" != "" ]]; then
        echo -e "  Last held   $(jq -r '.held.reason' <<< "$j")"
    fi
    echo ""
}

selfupdate_command() {
    case "${1:-}" in policy|config) shift; selfupdate_policy "$@"; return ;; esac
    parse_args "$@"
    local branch="${ARG_branch:-latest}"
    # The hourly check while a delay is on: nothing to download unless the
    # branch moved to a commit that is due.
    if [[ "${ARG_if_due:-}" == "true" ]]; then
        local hours; hours=$(_su_delay_hours)
        [[ "$hours" =~ ^[0-9]+$ ]] && (( hours > 0 )) || return 0
        local remote_sha st
        remote_sha=$(GIT_TERMINAL_PROMPT=0 _cipi_run_timed 60 git ls-remote "https://github.com/${_CIPI_REPO}.git" "refs/heads/${branch}" 2>/dev/null | awk '{print $1}')
        [[ "$remote_sha" =~ ^[0-9a-f]{40}$ ]] || return 0
        st=$(_su_state)
        [[ "$(jq -r '.installed_sha // ""' <<< "$st")" == "$remote_sha" ]] && return 0
        if [[ "$(jq -r '.pending.sha // ""' <<< "$st")" != "$remote_sha" ]]; then
            # Its version, for what the policy shows as waiting (and to tell the
            # version running now from a new release — see _su_delay_gate).
            local rv; rv=$(curl -fsSL --max-time 30 "https://raw.githubusercontent.com/${_CIPI_REPO}/${remote_sha}/version.md" 2>/dev/null | tr -d '[:space:]')
            [[ "$rv" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || rv=""
            if [[ -z "$(jq -r '.installed_sha // ""' <<< "$st")" && -n "$rv" && "$rv" == "${CIPI_VERSION:-}" ]]; then
                _su_state_write "$(jq -c --arg s "$remote_sha" '.installed_sha = $s | del(.pending) | del(.held)' <<< "$st")"
                return 0
            fi
            _su_state_write "$(jq -c --arg s "$remote_sha" --arg v "$rv" --argjson t "$(date +%s)" '.pending = {sha: $s, version: (if $v == "" then null else $v end), first_seen: $t}' <<< "$st")"
            return 0
        fi
        (( $(date +%s) >= $(jq -r '.pending.first_seen' <<< "$st") + hours * 3600 )) || return 0
        info "A release held by the update delay is due — installing it"
    fi
    if [[ "${ARG_check:-}" == "true" ]]; then
        local rv; rv=$(curl -fsSL "https://raw.githubusercontent.com/${_CIPI_REPO}/refs/heads/${branch}/version.md" 2>/dev/null | tr -d '[:space:]')
        [[ -z "$rv" ]] && { error "Cannot check updates"; exit 1; }
        [[ "$rv" == "$CIPI_VERSION" ]] && success "Up to date (v${CIPI_VERSION})" || info "Update: v${CIPI_VERSION} → v${rv}"
        return
    fi

    step "Downloading from '${branch}'..."
    # A private, unpredictable directory. The old /tmp/cipi-update-$$ was
    # removed and then cloned into: a local user who recreated it in between
    # owned the tree that root copies over /opt/cipi (5.9.0).
    local tmp
    tmp=$(mktemp -d /tmp/cipi-update.XXXXXXXXXX) && [[ -n "$tmp" && -d "$tmp" ]] || {
        error "Cannot create a temporary directory under /tmp"
        echo "  Check:  df -h /tmp  and  ls -ld /tmp"
        exit 1
    }
    chmod 700 "$tmp"

    if ! command -v git >/dev/null 2>&1; then
        error "git is not installed — cannot download the update"
        echo "  Install it with:  apt-get install -y git"
        rm -rf "$tmp"
        exit 1
    fi

    # Never swallow git's message. "Download failed" on its own gives nobody
    # anything to act on, and the causes are wildly different: no egress, DNS,
    # a full disk, a branch that does not exist. Capture stderr, print it, and
    # name the most likely cause.
    local clone_err clone_rc=0
    clone_err=$(GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true \
        _cipi_run_timed 180 git clone -b "$branch" --depth 1 \
        "https://github.com/${_CIPI_REPO}.git" "$tmp" 2>&1) || clone_rc=$?

    if [[ $clone_rc -ne 0 ]]; then
        error "Download failed (git exit ${clone_rc})"
        [[ -n "$clone_err" ]] && printf '%s\n' "$clone_err" | sed 's/^/  /'
        echo ""
        if [[ $clone_rc -eq 124 ]]; then
            echo "  Timed out after 180s — the server could not reach github.com."
        elif grep -qiE 'could not resolve|name or service not known|temporary failure in name' <<< "$clone_err"; then
            echo "  DNS cannot resolve github.com. Check /etc/resolv.conf."
        elif grep -qiE 'connection refused|connection timed out|failed to connect|network is unreachable' <<< "$clone_err"; then
            echo "  No outbound HTTPS to github.com. Check the firewall, the security group"
            echo "  and — on AWS — that this subnet has a NAT gateway or public IP."
        elif grep -qiE 'remote branch .* not found|couldn.t find remote ref' <<< "$clone_err"; then
            echo "  The branch '${branch}' does not exist on ${_CIPI_REPO}."
            echo "  Try:  cipi self-update --branch=master"
        elif grep -qiE 'no space left|write error|disk quota' <<< "$clone_err"; then
            echo "  No space left. Free some and retry:  df -h /tmp /"
        elif grep -qiE 'ssl|certificate|tls' <<< "$clone_err"; then
            echo "  TLS failure — the system CA bundle or the clock may be wrong."
            echo "  Check:  date  and  apt-get install --reinstall ca-certificates"
        fi
        echo ""
        echo "  Reproduce it by hand:"
        echo "    git clone -b ${branch} --depth 1 https://github.com/${_CIPI_REPO}.git /tmp/cipi-test"
        rm -rf "$tmp"
        exit 1
    fi
    local nv; nv=$(tr -d '[:space:]' < "${tmp}/version.md" 2>/dev/null)
    [[ -z "$nv" ]] && { error "Invalid package (version.md missing)"; rm -rf "$tmp"; exit 1; }

    # The safeguards of `cipi self-update policy`, when on. Off: as always.
    local new_sha; new_sha=$(git -C "$tmp" rev-parse HEAD 2>/dev/null || true)
    if _su_verify_on; then
        local why
        if why=$(_su_downgrade "$nv") || ! why=$(_su_verify_release "$tmp" "$nv"); then
            error "Update refused: ${why}"
            echo "  Nothing was installed; this server stays on v${CIPI_VERSION}. (cipi self-update policy)"
            _su_held "refused: ${why}"
            cipi_notify "Cipi update refused on $(hostname)" \
                "A Cipi update was not installed: its signature could not be verified.\n\nServer: $(hostname)\nInstalled: v${CIPI_VERSION}\nOffered: v${nv} (${new_sha:0:12})\nReason: ${why}\nTime: $(notify_now)\n\nIf this release is genuine, its maintainer has not signed it yet. If it is not, nothing reached this server.\nPolicy: cipi self-update policy" \
                self_update 2>/dev/null || true
            rm -rf "$tmp"
            exit 1
        fi
        success "Signature verified — ${why}"
        # The release may hand over a new list of signers, now that it was verified with the old one.
        if [[ -f "${tmp}/release-signers" ]] && (( $(_su_signers_count "${tmp}/release-signers") > 0 )) && ! cmp -s "${tmp}/release-signers" "$_SU_SIGNERS"; then
            install -m 644 "${tmp}/release-signers" "$_SU_SIGNERS" && info "Release signers updated by the signed release"
        fi
    fi
    if [[ -n "$new_sha" && "${ARG_now:-}" != "true" ]]; then
        local wait
        if ! wait=$(_su_delay_gate "$new_sha" "$nv"); then
            info "Held by the update delay: ${wait}"
            echo "  Install it now: cipi self-update --now   (cipi self-update policy)"
            _su_held "delay: ${wait}"
            rm -rf "$tmp"
            return 0
        fi
    fi
    # Snapshot before we rewrite /etc/cipi/version or re-source libs — the
    # nightly cron always refreshes files, but the mail must fire only on a bump.
    local old_ver="${CIPI_VERSION}" version_changed=false
    if [[ "$nv" != "$old_ver" ]]; then
        version_changed=true
    fi
    info "Updating v${old_ver} → v${nv}"
    local bak
    bak="/opt/cipi.bak.$(date +%Y%m%d%H%M%S)"
    cp -r /opt/cipi "$bak" 2>/dev/null || bak=""
    cp "${tmp}/cipi" /usr/local/bin/cipi; chmod 700 /usr/local/bin/cipi
    cp "${tmp}"/lib/*.sh /opt/cipi/lib/; chmod 700 /opt/cipi/lib/*.sh
    # cipi-app-post-deploy (app user) sources yml.sh for the deploy.post steps
    # of cipi.yml. With the 0700 above the source failed and the runner died
    # with "command not found" (exit 127) on every webhook deploy.
    chmod 755 /opt/cipi /opt/cipi/lib; chmod 644 /opt/cipi/lib/yml.sh
    cp "${tmp}/lib/gui-reset-admin.php" /opt/cipi/lib/ 2>/dev/null || true
    cp "${tmp}/lib/cipi-webhook.php" /opt/cipi/lib/ 2>/dev/null || true
    chmod 644 /opt/cipi/lib/gui-reset-admin.php 2>/dev/null || true
    [[ -d "${tmp}/lib/deployer" ]] && cp -r "${tmp}/lib/deployer" /opt/cipi/lib/
    [[ -f "${tmp}/lib/cipi-worker.sh" ]] && cp "${tmp}/lib/cipi-worker.sh" /usr/local/bin/cipi-worker && chmod 700 /usr/local/bin/cipi-worker
    [[ -f "${tmp}/lib/cipi-cron-notify.sh" ]] && cp "${tmp}/lib/cipi-cron-notify.sh" /usr/local/bin/cipi-cron-notify && chmod 700 /usr/local/bin/cipi-cron-notify
    [[ -f "${tmp}/lib/cipi-auth-notify.sh" ]] && cp "${tmp}/lib/cipi-auth-notify.sh" /usr/local/bin/cipi-auth-notify && chmod 700 /usr/local/bin/cipi-auth-notify
    [[ -f "${tmp}/lib/cipi-app-notify.sh" ]] && cp "${tmp}/lib/cipi-app-notify.sh" /usr/local/bin/cipi-app-notify && chmod 700 /usr/local/bin/cipi-app-notify
    [[ -f "${tmp}/lib/cipi-app-deploy.sh" ]] && cp "${tmp}/lib/cipi-app-deploy.sh" /usr/local/bin/cipi-app-deploy && chmod 755 /usr/local/bin/cipi-app-deploy
    [[ -f "${tmp}/lib/cipi-app-post-deploy.sh" ]] && cp "${tmp}/lib/cipi-app-post-deploy.sh" /usr/local/bin/cipi-app-post-deploy && chmod 755 /usr/local/bin/cipi-app-post-deploy
    [[ -f "${tmp}/lib/cipi-deploy-audit.sh" ]] && cp "${tmp}/lib/cipi-deploy-audit.sh" /usr/local/bin/cipi-deploy-audit && chmod 700 /usr/local/bin/cipi-deploy-audit
    [[ -f "${tmp}/lib/cipi-node-switch.sh" ]] && cp "${tmp}/lib/cipi-node-switch.sh" /usr/local/bin/cipi-node-switch && chmod 700 /usr/local/bin/cipi-node-switch
    [[ -f "${tmp}/lib/cipi-node-run.sh" ]] && cp "${tmp}/lib/cipi-node-run.sh" /usr/local/bin/cipi-node-run && chmod 755 /usr/local/bin/cipi-node-run
    # Run by Deployer as the app user (Octane recipe): 755, root's.
    [[ -f "${tmp}/lib/cipi-frankenphp-link.sh" ]] && cp "${tmp}/lib/cipi-frankenphp-link.sh" /usr/local/bin/cipi-frankenphp-link && chmod 755 /usr/local/bin/cipi-frankenphp-link
    # Run through sudo by an app user (cipi cache): root's, and nobody else's to write.
    [[ -f "${tmp}/lib/cipi-cache-clear.sh" ]] && cp "${tmp}/lib/cipi-cache-clear.sh" /usr/local/bin/cipi-cache-clear && chown root:root /usr/local/bin/cipi-cache-clear && chmod 755 /usr/local/bin/cipi-cache-clear
    if [[ -f "${tmp}/lib/cipi-webhook.php" ]]; then
        install -d -m 755 /usr/local/share/cipi && install -m 644 "${tmp}/lib/cipi-webhook.php" /usr/local/share/cipi/webhook.php
    fi
    [[ -f "${tmp}/lib/cipi-health-check.sh" ]] && cp "${tmp}/lib/cipi-health-check.sh" /usr/local/bin/cipi-health-check && chmod 700 /usr/local/bin/cipi-health-check
    # Refresh unconditionally: _mon_ensure_cron only installs the helper when it
    # is missing, so without this the 5.3.0 copy would never be updated again.
    [[ -f "${tmp}/lib/cipi-monitor.sh" ]] && cp "${tmp}/lib/cipi-monitor.sh" /usr/local/bin/cipi-monitor && chmod 755 /usr/local/bin/cipi-monitor
    [[ -f "${tmp}/lib/cipi-metrics.sh" ]] && cp "${tmp}/lib/cipi-metrics.sh" /usr/local/bin/cipi-metrics && chmod 755 /usr/local/bin/cipi-metrics
    [[ -f "${tmp}/lib/cipi-scan-manifest.sh" ]] && cp "${tmp}/lib/cipi-scan-manifest.sh" /usr/local/bin/cipi-scan-manifest && chmod 755 /usr/local/bin/cipi-scan-manifest
    [[ -f "${tmp}/lib/cipi-crowdsec-rescue.py" ]] && cp "${tmp}/lib/cipi-crowdsec-rescue.py" /usr/local/bin/cipi-crowdsec-rescue && chmod 700 /usr/local/bin/cipi-crowdsec-rescue
    [[ -f "${tmp}/lib/cipi-crowdsec-rescue-hole.sh" ]] && cp "${tmp}/lib/cipi-crowdsec-rescue-hole.sh" /usr/local/bin/cipi-crowdsec-rescue-hole && chmod 700 /usr/local/bin/cipi-crowdsec-rescue-hole
    # cloudflared / `cipi zt enable` is opt-in. lib/zt.sh is copied with the
    # other libs above; this update must not install or start it.
    if systemctl is-active --quiet cipi-crowdsec-rescue 2>/dev/null; then
        systemctl restart cipi-crowdsec-rescue 2>/dev/null || true
    fi
    [[ -f "${tmp}/lib/cipi-read-app-logs.sh" ]] && cp "${tmp}/lib/cipi-read-app-logs.sh" /usr/local/bin/cipi-read-app-logs && chmod 755 /usr/local/bin/cipi-read-app-logs
    # sshd runs it (AuthorizedKeysCommand) as the cipi user, and refuses a
    # command that is not root's or that anyone else can write.
    [[ -f "${tmp}/lib/cipi-ssh-keys.sh" ]] && cp "${tmp}/lib/cipi-ssh-keys.sh" /usr/local/bin/cipi-ssh-keys && chown root:root /usr/local/bin/cipi-ssh-keys && chmod 755 /usr/local/bin/cipi-ssh-keys
    [[ -d "${tmp}/cipi-api" ]] && rm -rf /opt/cipi/cipi-api && cp -a "${tmp}/cipi-api" /opt/cipi/cipi-api
    chown -R root:root /usr/local/bin/cipi /opt/cipi
    [[ -f /usr/local/bin/cipi-frankenphp-link ]] && chown root:root /usr/local/bin/cipi-frankenphp-link

    # Refresh shell completion from the just-copied lib (also backfills servers
    # that predate the feature). Best effort — never abort an update.
    if [[ -f /opt/cipi/lib/completion.sh ]]; then
        # shellcheck source=/dev/null
        source /opt/cipi/lib/completion.sh
        _completion_install_system || true
    fi

    # This process started with pre-update common.sh; reload lib helpers copied above
    # so migrations and composer steps see functions added in this release.
    # shellcheck source=/dev/null
    source /opt/cipi/lib/common.sh

    # Run migrations — child bash processes need CIPI_* in the environment.
    # The main cipi binary sets CIPI_LIB/CONFIG/LOG readonly; export by name only (no reassignment).
    export CIPI_LIB CIPI_CONFIG CIPI_LOG
    [[ -z "${CIPI_API_ROOT:-}" ]] && export CIPI_API_ROOT="/opt/cipi/api"
    [[ -z "${CIPI_GUI_ROOT:-}" ]] && export CIPI_GUI_ROOT="/opt/cipi/gui"
    export CIPI_UPDATE_TMP="$tmp"

    # The blanket `chown -R root:root /opt/cipi` above also re-roots the panel
    # Laravel app under /opt/cipi/api: storage/, database/ and bootstrap/cache/
    # become root:root, so PHP-FPM (www-data) can no longer open
    # storage/logs/laravel.log or write the SQLite DB → the panel returns HTTP
    # 500 after EVERY self-update (including the nightly cron). The cipi-api
    # block below only reclaims them when /opt/cipi/cipi-api exists, so on
    # package-from-packagist installs it was skipped and the panel stayed
    # broken. Reclaim the writable paths unconditionally, right here.
    ensure_cipi_api_permissions
    if [[ -f /opt/cipi/lib/gui.sh ]]; then
        # shellcheck source=/dev/null
        source /opt/cipi/lib/gui.sh
        ensure_cipi_gui_permissions
    fi

    if [[ -d "${tmp}/lib/migrations" ]]; then
        for m in $(ls "${tmp}/lib/migrations/"*.sh 2>/dev/null|sort -V); do
            local mv; mv=$(basename "$m" .sh)
            if [[ "$(printf '%s\n' "$CIPI_VERSION" "$mv"|sort -V|head -1)" == "$CIPI_VERSION" && "$mv" != "$CIPI_VERSION" ]]; then
                step "Migration ${mv}..."
                if ! ( set -euo pipefail; bash "$m" ); then
                    # Honest about the state: the v${nv} files are already in
                    # place, only /etc/cipi/version still says v${CIPI_VERSION},
                    # so this migration runs again on the next self-update.
                    error "Migration ${mv} failed — recorded version stays v${CIPI_VERSION}; the v${nv} files are already installed"
                    echo "  The migration runs again on the next update (the nightly one too):"
                    echo "    cipi self-update"
                    [[ -n "$bak" ]] && echo "  The v${CIPI_VERSION} files are kept in ${bak}"
                    rm -rf "$tmp"
                    exit 1
                fi
            fi
        done
    fi

    # The panel's sudoers whitelist follows the installed cipi on every
    # update, not only when a migration rewrites it: a migration that was
    # interrupted, or a release that adds a command without one, would leave
    # the panel with "sudo: … can't do that" (5.11.1).
    if [[ -f "${tmp}/lib/cipi-api-sudoers.sh" ]]; then
        # shellcheck source=/dev/null
        source "${tmp}/lib/cipi-api-sudoers.sh"
        if _cipi_panel_installed; then
            write_cipi_api_sudoers || warn "The panel sudoers were not updated (see above) — the previous ones are kept"
        fi
    fi

    # Record the new version before panel package updates. Composer/migrate for
    # cipi/api can take minutes or hang; core files and migrations are already done.
    if declare -f _cipi_ensure_config_writable >/dev/null 2>&1; then
        _cipi_ensure_config_writable || true
    fi
    echo "$nv" > "${CIPI_CONFIG}/version"
    # What is installed now: the delay counts from the next commit.
    [[ -n "$new_sha" ]] && _su_state_write "$(_su_state | jq -c --arg s "$new_sha" '.installed_sha = $s | del(.pending) | del(.held)')"
    # The release's list of signers, as shipped: what --verify=on offers to
    # trust, once its fingerprint has been compared with the published one.
    [[ -f "${tmp}/release-signers" ]] && install -m 644 "${tmp}/release-signers" /opt/cipi/release-signers 2>/dev/null || true
    step "Core updated to v${nv}"

    # Auto-update cipi-api package in installed API app (never installs the API).
    # Delegates to _api_update_package from the freshly copied api.sh so the first
    # upgrade pass already gets timeouts / non-hanging ssh-keyscan / queue stop.
    if [[ -f "${CIPI_API_ROOT:-/opt/cipi/api}/artisan" ]]; then
        step "Updating cipi-api in Laravel app..."
        if [[ -f /opt/cipi/lib/api.sh ]]; then
            # shellcheck source=/dev/null
            source /opt/cipi/lib/api.sh
        fi
        if declare -f _api_update_package >/dev/null 2>&1; then
            if ! _api_update_package; then
                warn "cipi/api package update failed — continuing (run: cipi api update)"
            fi
        else
            warn "api.sh missing _api_update_package — skip (run: cipi api update)"
        fi
        ensure_cipi_api_permissions || true
    fi

    # Auto-update cipi/gui package in installed GUI app (from GitHub VCS).
    # Never let a composer helper miss abort the update after chown root:root —
    # that left .env root-owned and the panel on HTTP 500 (v5.0.2 → 5.0.12).
    if [[ -f "${CIPI_GUI_ROOT:-/opt/cipi/gui}/artisan" ]] && [[ -f /opt/cipi/lib/gui.sh ]]; then
        step "Updating cipi/gui in Laravel app..."
        # shellcheck source=/dev/null
        source /opt/cipi/lib/gui.sh
        if ! _gui_update_package; then
            warn "cipi/gui package update failed — continuing (run: cipi gui update)"
        fi
        ensure_cipi_gui_permissions || true
        _gui_create_fpm_pool || true
        # The FPM the pool was just written for (the system PHP), not 8.5 by name.
        reload_php_fpm "$(php -r 'echo PHP_MAJOR_VERSION.".".PHP_MINOR_VERSION;' 2>/dev/null || echo "8.5")" 2>/dev/null || true
        success "cipi/gui package step finished"
    fi

    rm -rf "$tmp"
    _selfupdate_prune_backups

    # Re-source so helpers added in this update (e.g. purge_orphan_app_users) are
    # available even when no new migration ran (same-version refresh / already on 4.7.19).
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/common.sh"
    # Final reclaim: blanket chown root:root above must never leave the panel unreadable.
    ensure_cipi_api_permissions || true
    if declare -f ensure_cipi_gui_permissions >/dev/null 2>&1; then
        ensure_cipi_gui_permissions || true
    elif [[ -f /opt/cipi/lib/gui.sh ]]; then
        # shellcheck source=/dev/null
        source /opt/cipi/lib/gui.sh
        ensure_cipi_gui_permissions || true
    fi
    if declare -f purge_orphan_app_users >/dev/null; then
        step "Purging orphan app users..."
        purge_orphan_app_users || true
    fi

    log_action "SELF-UPDATE: v${old_ver} → v${nv}"

    # Same-version refresh (nightly cron, --branch of a tag already installed)
    # still copies libs; it must not mail. version_changed was decided from the
    # snapshot above, not from CIPI_VERSION after /etc/cipi/version was rewritten.
    if [[ "$version_changed" == true ]]; then
        cipi_notify \
            "Cipi updated to v${nv} on $(hostname)" \
            "Cipi updated itself.\n\nServer: $(hostname)\nVersion: v${old_ver} → v${nv}\nTime: $(notify_now)\n\nChangelog: https://github.com/cipi-sh/cipi/blob/master/CHANGELOG.md\n\nTurn this off with: cipi notifications disable self_update" \
            self_update
    fi

    # Upstream package entries (sec-nuclei, sec-zap…) whose pin moved with this
    # release: said here, updated by the operator — downloading hundreds of MB
    # is not a side effect of an update that may run from cron (5.14.0).
    if [[ -d /opt/cipi/packages && -f /opt/cipi/lib/package.sh ]]; then
        local pkg_outdated
        pkg_outdated=$( (
            # shellcheck source=/dev/null
            source /opt/cipi/lib/package.sh
            for id in $(_pkg_upstream | cut -d'|' -f1); do
                [[ "$(_pkg_up_state "$id")" == outdated ]] && echo "$id"
            done
        ) 2>/dev/null | paste -sd' ' - || true)
        if [[ -n "$pkg_outdated" ]]; then
            warn "Optional packages with a newer pinned version: ${pkg_outdated}"
            echo "  Update each with: cipi package install <id>  (or from the panel)"
        fi
    fi
    success "Updated to v${nv}"
}
