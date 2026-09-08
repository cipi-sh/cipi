#!/bin/bash
#############################################
# Cipi — Nightly integrity + upload malware scan (opt-in)
#
# Two jobs, one cron:
#   1. Compare current/ (or htdocs/) to the sha256 manifest written at
#      deploy time. Extra/changed files are a webshell whether ClamAV
#      knows the signature or not.
#   2. One clamscan over upload dirs only (shared/storage/app, etc.),
#      with rfxn PHP-webshell signatures. Signatures load once.
#
# No clamd. Incomplete runs (timeout, freshclam fail) mail scan_incomplete
# — they are not silent and they are not "clean".
#############################################

[[ -z "${SCAN_CRON:-}" ]]       && readonly SCAN_CRON="/etc/cron.d/cipi-scan"
[[ -z "${SCAN_LOG:-}" ]]        && readonly SCAN_LOG="${CIPI_LOG}/scan.log"
[[ -z "${SCAN_REPORT_DIR:-}" ]] && readonly SCAN_REPORT_DIR="${CIPI_LOG}/scan"
[[ -z "${SCAN_LOCK:-}" ]]       && readonly SCAN_LOCK="/run/cipi-scan.lock"
[[ -z "${SCAN_TIMEOUT:-}" ]]    && readonly SCAN_TIMEOUT=1200
[[ -z "${SCAN_EXTRA_DB:-}" ]]   && readonly SCAN_EXTRA_DB="/var/lib/cipi/clamav-extra"
[[ -z "${SCAN_SIGPACK_URL:-}" ]] && readonly SCAN_SIGPACK_URL="https://cdn.rfxn.com/downloads/maldet-sigpack.tgz"
# clamscan loads the whole signature set on every invocation (~1.5GB resident),
# and the DB on disk is close to 1GB. Below this the nightly job does not fail
# quietly — the OOM killer picks a victim at 04:40, and it may well be MariaDB.
[[ -z "${SCAN_MIN_RAM_KB:-}" ]] && readonly SCAN_MIN_RAM_KB=2097152
[[ -z "${SCAN_MIN_DISK_KB:-}" ]] && readonly SCAN_MIN_DISK_KB=3145728
# Manifests live outside /home/<app>: the app user (and therefore any webshell
# running in the app) must not be able to rewrite the baseline it is checked
# against. Written by /usr/local/bin/cipi-scan-manifest, root:root 0600.
[[ -z "${SCAN_MANIFEST_DIR:-}" ]] && readonly SCAN_MANIFEST_DIR="/var/lib/cipi/manifests"
# How many nightly reports to keep in SCAN_REPORT_DIR.
[[ -z "${SCAN_REPORT_KEEP:-}" ]] && readonly SCAN_REPORT_KEEP=30

scan_command() {
    local sub="${1:-}"
    case "$sub" in
        enable)  shift || true; _scan_enable "$@" ;;
        disable) shift || true; _scan_disable "$@" ;;
        status)  shift || true; _scan_status "$@" ;;
        report)  shift || true; _scan_report "$@" ;;
        manifest) shift || true; _scan_manifest_cmd "$@" ;;
        --cron)  shift || true; _scan_run --cron "$@" ;;
        all)     shift || true; _scan_run all "$@" ;;
        help|--help|-h) show_help scan; return 0 ;;
        "")      _scan_run all ;;
        *)
            if [[ "$sub" == --* ]]; then
                _scan_run all "$@"
            elif app_exists "$sub"; then
                shift || true
                _scan_run "$sub" "$@"
            else
                error "App '${sub}' not found"
                echo "      Usage: cipi scan enable|disable|status|report|manifest|all [<app>]"
                exit 1
            fi
            ;;
    esac
}

_scan_enabled() {
    [[ -f "$SCAN_CRON" ]]
}

_scan_clamscan_bin() {
    command -v clamscan >/dev/null 2>&1
}

_scan_apt() {
    DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=300 "$@"
}

_scan_disable_daemons() {
    systemctl stop clamav-daemon 2>/dev/null || true
    systemctl disable clamav-daemon 2>/dev/null || true
    systemctl mask clamav-daemon 2>/dev/null || true
    systemctl stop clamav-freshclam 2>/dev/null || true
    systemctl disable clamav-freshclam 2>/dev/null || true
}

_scan_check_resources() {
    local force="${ARG_force:-}" ram disk fail=0
    ram=$(awk '/MemAvailable:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)
    disk=$(df -Pk /var 2>/dev/null | awk 'NR==2 {print $4}')

    if [[ "${ram:-0}" -lt "$SCAN_MIN_RAM_KB" ]]; then
        error "ClamAV needs at least $((SCAN_MIN_RAM_KB / 1024))MB free RAM (MemAvailable=$((ram / 1024))MB)."
        echo "  clamscan loads the full signature set on every run. Below this the"
        echo "  04:40 job is OOM-killed — and the kernel may pick MariaDB instead."
        fail=1
    fi
    if [[ "${disk:-0}" -lt "$SCAN_MIN_DISK_KB" ]]; then
        error "ClamAV needs at least $((SCAN_MIN_DISK_KB / 1024))MB free on /var (have $(( ${disk:-0} / 1024 ))MB)."
        echo "  The signature database alone is close to 1GB."
        fail=1
    fi
    [[ "$fail" -eq 0 ]] && return 0
    if [[ "$force" == "true" ]]; then
        warn "Continuing because --force. Integrity checks are cheap; ClamAV is not."
        return 0
    fi
    echo "  Pass --force to install anyway, or leave the scan off: the integrity"
    echo "  half of it needs no ClamAV at all."
    return 1
}

_scan_install_packages() {
    if _scan_clamscan_bin; then
        _scan_disable_daemons
        return 0
    fi
    step "Installing ClamAV scanner (no daemon)..."
    _scan_apt update -qq || true
    _scan_apt install -y -qq clamav clamav-freshclam \
        || { error "ClamAV install failed"; return 1; }
    _scan_disable_daemons
    _scan_clamscan_bin || { error "clamscan is not on PATH after install"; return 1; }
}

# rfxn/LMD signatures are the ones that actually know PHP webshells.
# Fail-open: keep the previous pack if the download dies.
_scan_refresh_extra_sigs() {
    mkdir -p "$SCAN_EXTRA_DB"
    local tmp tgz
    tmp=$(mktemp -d)
    tgz="${tmp}/sigpack.tgz"
    if ! _cipi_run_timed 60 curl -fsSL "$SCAN_SIGPACK_URL" -o "$tgz"; then
        rm -rf "$tmp"
        # A dead CDN is not an incomplete scan: the pack already on disk is
        # loaded and used. Only report failure when there is nothing to fall
        # back to, or every outage becomes a nightly scan_incomplete email.
        [[ -n "$(ls -A "$SCAN_EXTRA_DB" 2>/dev/null)" ]] && return 0
        return 1
    fi
    tar -tzf "$tgz" >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
    tar -xzf "$tgz" -C "$tmp" 2>/dev/null || { rm -rf "$tmp"; return 1; }
    find "$tmp" -type f \( -name '*.hdb' -o -name '*.ndb' -o -name '*.ldb' -o -name '*.fp' \) \
        -exec cp -f {} "$SCAN_EXTRA_DB/" \;
    rm -rf "$tmp"
    [[ -n "$(ls -A "$SCAN_EXTRA_DB" 2>/dev/null)" ]]
}

_scan_write_cron() {
    cat > "$SCAN_CRON" <<'EOF'
# Cipi nightly integrity + upload scan (opt-in — cipi scan enable).
40 4 * * * root /usr/local/bin/cipi-cron-notify app-scan /usr/local/bin/cipi scan --cron >> /var/log/cipi/scan.log 2>&1
EOF
    chmod 644 "$SCAN_CRON"
}

_scan_app_list() {
    [[ -f "${CIPI_CONFIG}/apps.json" ]] || return 0
    vault_read apps.json | jq -r 'keys[]?' 2>/dev/null
}

# Same rule as cipi-scan-manifest, deliberately: whichever tree the writer
# hashed is the tree the check must compare against. Keying one off the `custom`
# flag and the other off what is on disk makes an app with both directories
# report drift every single night.
_scan_code_root() {
    local home="/home/${1}"
    if [[ -d "${home}/current" ]]; then
        echo "${home}/current"
    elif [[ -d "${home}/htdocs" ]]; then
        echo "${home}/htdocs"
    fi
}

_scan_manifest_path() {
    echo "${SCAN_MANIFEST_DIR}/${1}.sha256"
}

# Upload dirs only — the tree that is supposed to change at runtime.
_scan_upload_paths() {
    local app="$1" home="/home/${app}" custom
    custom=$(app_get "$app" custom 2>/dev/null || echo "")
    if [[ "$custom" == "true" ]]; then
        [[ -d "${home}/htdocs/wp-content/uploads" ]] && printf '%s\n' "${home}/htdocs/wp-content/uploads"
        [[ -d "${home}/htdocs/storage/app" ]] && printf '%s\n' "${home}/htdocs/storage/app"
        return 0
    fi
    [[ -d "${home}/shared/storage/app" ]] && printf '%s\n' "${home}/shared/storage/app"
}

# Errors from the hash pass. mktemp rather than a PID-predictable name under a
# world-writable /tmp: root truncating a file an app user planted there first is
# the oldest trick in the book (protected_symlinks only covers part of it).
_scan_hash_err() {
    if [[ -z "${SCAN_HASH_ERR:-}" ]]; then
        SCAN_HASH_ERR=$(mktemp "${TMPDIR:-/tmp}/cipi-scan-hash.XXXXXX")
    fi
    printf '%s' "$SCAN_HASH_ERR"
}

_scan_hash_err_clear() {
    [[ -n "${SCAN_HASH_ERR:-}" ]] && rm -f "$SCAN_HASH_ERR"
    SCAN_HASH_ERR=""
    return 0
}

# Hash every regular file under the release. -P: do not follow the shared
# symlinks (storage, .env), so runtime writes are not in the manifest.
#
# A file sha256sum could not read is dropped from its output, which would make
# a dropped webshell look like a clean tree — and a partial run would install a
# truncated manifest. Errors go to $SCAN_HASH_ERR so the caller can refuse the
# result instead of trusting it.
_scan_hash_tree() {
    local root="$1" err
    [[ -d "$root" ]] || return 1
    err=$(_scan_hash_err)
    : > "$err"
    (
        cd "$root" || exit 1
        set -o pipefail
        find -P . -type f -print0 2>>"$err" \
            | sort -z \
            | xargs -0 -r sha256sum 2>>"$err"
    )
}

# Non-empty when the last _scan_hash_tree lost files.
_scan_hash_errors() {
    local err="${SCAN_HASH_ERR:-}"
    [[ -n "$err" && -s "$err" ]] && head -5 "$err"
    return 0
}

_scan_write_manifest() {
    local app="${1:-}"
    [[ -n "$app" ]] || return 1
    local root dest tmp
    root=$(_scan_code_root "$app")
    dest=$(_scan_manifest_path "$app")
    [[ -n "$root" && -d "$root" ]] || return 0
    install -d -m 700 -o root -g root "$SCAN_MANIFEST_DIR"
    tmp=$(mktemp "${SCAN_MANIFEST_DIR}/.${app}.XXXXXX")
    {
        echo "# cipi integrity manifest  app=${app}  $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        echo "# root=${root}  release=$(readlink -f "$root" 2>/dev/null || echo "$root")"
        echo "# symlinks not followed"
        _scan_hash_tree "$root"
    } > "$tmp"
    # An incomplete hash pass would be installed as the new baseline and every
    # file it lost would read as "extra" forever. Keep the old manifest.
    if [[ -n "$(_scan_hash_errors)" ]]; then
        rm -f "$tmp"
        warn "Could not hash every file under ${root} — manifest for ${app} left unchanged"
        _scan_hash_errors | sed 's/^/    /'
        return 1
    fi
    # root:root 0600: the app user must never be able to edit its own baseline.
    install -m 600 -o root -g root "$tmp" "$dest"
    rm -f "$tmp"
}

_scan_manifest_cmd() {
    local app="${1:-}"
    if [[ -z "$app" || "$app" == "all" ]]; then
        local a n=0
        while IFS= read -r a; do
            [[ -z "$a" ]] && continue
            _scan_write_manifest "$a" && n=$((n + 1))
        done < <(_scan_app_list)
        _scan_hash_err_clear
        success "Wrote integrity manifests for ${n} app(s)"
        return 0
    fi
    app_exists "$app" || { error "App '${app}' not found"; exit 1; }
    _scan_write_manifest "$app" || { _scan_hash_err_clear; exit 1; }
    _scan_hash_err_clear
    success "Manifest written: $(_scan_manifest_path "$app")"
}

_scan_diff_manifest() {
    local app="$1"
    local root dest
    root=$(_scan_code_root "$app")
    dest=$(_scan_manifest_path "$app")
    if [[ -z "$root" || ! -d "$root" ]]; then
        echo "NO_RELEASE ${app}"
        return 0
    fi
    if [[ ! -s "$dest" ]]; then
        echo "NO_MANIFEST ${app}"
        return 0
    fi
    local tmp
    tmp=$(mktemp)
    _scan_hash_tree "$root" > "$tmp"
    if [[ -n "$(_scan_hash_errors)" ]]; then
        rm -f "$tmp"
        # Files missing from the hash list cannot be told apart from files that
        # were never there, so this run says nothing rather than "clean".
        echo "HASH_INCOMPLETE ${app}"
        _scan_hash_errors | sed 's/^/  /'
        return 2
    fi
    local out rc=0
    out=$(awk "$(_scan_compare_awk)" "$dest" "$tmp") || rc=$?
    rm -f "$tmp"
    if [[ "$rc" -gt 1 ]]; then
        echo "COMPARE_FAILED ${app}"
        return 2
    fi
    [[ "$rc" -eq 0 ]] && return 0
    echo "DRIFT ${app}"
    printf '%s\n' "$out" | sort
    return 1
}

# sha256sum records are fixed width: 64 hex, a two-character separator, then
# the path verbatim. Two traps live here.
#   * GNU coreutils escapes a record whose name holds a backslash or a newline
#     and prefixes the line with a backslash. A filter anchored on the hash
#     drops those lines, so a webshell named `sh\ell.php` was invisible.
#   * Splitting on whitespace and reading $2 truncates every name with a space:
#     "public/my shell.php" was reported as "public/my".
# So: never split fields, slice by offset, and keep the escaped form (manifest
# and fresh pass escape identically, and it is what sha256sum -c expects).
# Exit 1 means drift, 0 means the trees match.
_scan_compare_awk() {
    cat <<'AWKEOF'
function rec(line,   esc, h) {
    esc = 0
    if (substr(line, 1, 1) == "\\") { esc = 1; line = substr(line, 2) }
    h = substr(line, 1, 64)
    if (h !~ /^[0-9a-f]{64}$/) return 0
    if (substr(line, 65, 1) != " ") return 0
    HASH = h
    FILEPATH = (esc ? "\\" : "") substr(line, 67)
    return (FILEPATH != "")
}
NR == FNR { if (rec($0)) base[FILEPATH] = HASH; next }
{
    if (!rec($0)) next
    if (!(FILEPATH in base)) { print "  extra: " FILEPATH; n++ }
    else {
        if (base[FILEPATH] != HASH) { print "  changed: " FILEPATH; n++ }
        delete base[FILEPATH]
    }
}
END {
    for (p in base) { print "  missing: " p; n++ }
    exit (n > 0 ? 1 : 0)
}
AWKEOF
}

_scan_check_isolation() {
    local app="$1" php pool
    php=$(app_get "$app" php 2>/dev/null || true)
    [[ -n "$php" ]] || return 0
    pool="/etc/php/${php}/fpm/pool.d/${app}.conf"
    [[ -f "$pool" ]] || return 0
    grep -q "open_basedir" "$pool" || echo "NO_OPEN_BASEDIR ${app} ${pool}"
    grep -qE "^user = ${app}$" "$pool" || echo "POOL_USER ${app} ${pool}"
    return 0
}

_scan_enable() {
    parse_args "$@"
    _scan_check_resources || exit 1
    _scan_install_packages || exit 1
    mkdir -p "$SCAN_REPORT_DIR" "$SCAN_EXTRA_DB"
    _scan_write_cron

    step "Downloading virus signatures..."
    local fresh_rc=0 extra_rc=0
    _cipi_run_timed 300 freshclam --stdout >> "$SCAN_LOG" 2>&1 || fresh_rc=$?
    _scan_refresh_extra_sigs || extra_rc=$?
    [[ "$fresh_rc" -eq 0 ]] || warn "freshclam did not finish — nightly will retry and mail if it still fails"
    [[ "$extra_rc" -eq 0 ]] || warn "rfxn PHP-webshell signatures missing — official ClamAV DB only for now"

    step "Writing integrity manifests for current releases..."
    _scan_manifest_cmd all >/dev/null || true

    log_action "scan enable"
    log_event "Integrity + upload scan enabled on $(hostname)"
    cipi_notify \
        "Cipi scan enabled on $(hostname)" \
        "Nightly job is on (04:40):\n  • integrity of current/ (or htdocs/) against the deploy manifest\n  • one ClamAV pass on upload dirs only, with rfxn PHP-webshell signatures\n\nA deploy writes a new manifest. Incomplete runs (timeout, failed signature update) email scan_incomplete — they are not reported as clean.\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')" \
        scan_enable
    success "Nightly integrity + upload scan enabled (04:40)"
}

_scan_disable() {
    parse_args "$@"
    if ! _scan_enabled && ! _scan_clamscan_bin; then
        info "Scan is not enabled"
        return 0
    fi
    if [[ "${ARG_force:-}" != "true" ]]; then
        confirm "Disable the nightly scan and remove ClamAV?" || { info "Aborted"; return 0; }
    fi

    rm -f "$SCAN_CRON"
    step "Removing ClamAV..."
    systemctl unmask clamav-daemon 2>/dev/null || true
    _scan_apt purge -y -qq clamav clamav-freshclam clamav-daemon clamav-base \
        >/dev/null 2>&1 || true
    _scan_apt autoremove -y -qq >/dev/null 2>&1 || true
    rm -rf /var/lib/clamav "$SCAN_EXTRA_DB"

    log_action "scan disable"
    log_event "Scan disabled on $(hostname)"
    success "Nightly scan removed — manifests under ${SCAN_MANIFEST_DIR} are left in place"
}

_scan_status() {
    echo ""
    echo -e "  ${BOLD}Integrity + upload scan${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if _scan_enabled; then
        echo -e "  Nightly     ${GREEN}enabled${NC}  ${DIM}04:40 — manifest then one clamscan on uploads${NC}"
    else
        echo -e "  Nightly     ${DIM}disabled${NC}  —  ${CYAN}cipi scan enable${NC}"
    fi
    if _scan_clamscan_bin; then
        echo -e "  clamscan    ${GREEN}installed${NC}"
    else
        echo -e "  clamscan    ${DIM}not installed${NC}"
    fi
    if [[ -n "$(ls -A "$SCAN_EXTRA_DB" 2>/dev/null)" ]]; then
        echo -e "  rfxn sigs   ${GREEN}present${NC}"
    else
        echo -e "  rfxn sigs   ${DIM}missing${NC}"
    fi
    if systemctl is-enabled --quiet clamav-daemon 2>/dev/null || systemctl is-active --quiet clamav-daemon 2>/dev/null; then
        echo -e "  clamd       ${YELLOW}running${NC}  ${DIM}(should be masked)${NC}"
    else
        echo -e "  clamd       ${DIM}off${NC}"
    fi
    echo ""
}

_scan_run() {
    parse_args "$@"
    local target="${1:-all}"
    [[ "$target" == --* ]] && target="all"

    exec 9>"$SCAN_LOCK"
    if ! flock -n 9; then
        info "A scan is already running — skip"
        return 0
    fi

    mkdir -p "$SCAN_REPORT_DIR" "$(dirname "$SCAN_LOG")"
    local cron=0
    [[ "${ARG_cron:-}" == "true" || "$1" == "--cron" ]] && cron=1

    local -a apps=()
    if [[ "$target" == "all" || "$target" == "--cron" ]]; then
        local a
        while IFS= read -r a; do
            [[ -n "$a" ]] && apps+=("$a")
        done < <(_scan_app_list)
    else
        app_exists "$target" || { error "App '${target}' not found"; exit 1; }
        apps+=("$target")
    fi

    if [[ ${#apps[@]} -eq 0 ]]; then
        info "No apps to scan"
        return 0
    fi

    local stamp incomplete=0 hits=0 drift=0
    local hit_body="" drift_body="" inc_body="" iso_body=""
    stamp=$(date -u '+%Y%m%dT%H%M%SZ')
    local report="${SCAN_REPORT_DIR}/${stamp}.txt"
    mkdir -p "$SCAN_REPORT_DIR"
    echo "cipi scan  ${stamp}" > "$report"

    # ── 1. Integrity ──────────────────────────────────────────
    step "Checking release integrity (${#apps[@]} app(s))..."
    local app
    for app in "${apps[@]}"; do
        local iso out
        iso=$(_scan_check_isolation "$app")
        if [[ -n "$iso" ]]; then
            echo "$iso" >> "$report"
            iso_body+="${iso}"$'\n'
        fi
        set +e
        out=$(_scan_diff_manifest "$app")
        local rc=$?
        set -euo pipefail
        case "$out" in
            NO_RELEASE*)
                echo -e "  ${DIM}○${NC} ${app}: no release deployed yet — nothing to compare"
                echo "$out" >> "$report"
                ;;
            NO_MANIFEST*)
                echo "  ${app}: no manifest yet (written on next deploy, or: cipi scan manifest ${app})"
                echo "$out" >> "$report"
                ;;
            HASH_INCOMPLETE*|COMPARE_FAILED*)
                incomplete=1
                warn "${app}: could not hash the whole release — not reporting this app as clean"
                printf '%s\n' "$out" | sed 's/^/    /'
                echo "$out" >> "$report"
                inc_body+="${out}"$'\n'
                ;;
            *)
                if [[ "$rc" -ne 0 ]]; then
                    drift=$((drift + 1))
                    echo -e "  ${RED}●${NC} ${app}: tree drifted from the deploy manifest"
                    printf '%s\n' "$out" | sed 's/^/    /'
                    echo "$out" >> "$report"
                    drift_body+="${out}"$'\n'
                else
                    echo -e "  ${GREEN}●${NC} ${app}: matches deploy manifest"
                fi
                ;;
        esac
    done
    _scan_hash_err_clear

    # ── 2. ClamAV on uploads, one process ─────────────────────
    local -a upaths=()
    for app in "${apps[@]}"; do
        local p
        while IFS= read -r p; do
            [[ -n "$p" ]] && upaths+=("$p")
        done < <(_scan_upload_paths "$app")
    done

    if [[ ${#upaths[@]} -eq 0 ]]; then
        echo "No upload dirs to ClamAV" >> "$report"
    elif ! _scan_clamscan_bin; then
        echo "ClamAV not installed — integrity only (cipi scan enable)" >> "$report"
        info "ClamAV not installed — integrity check only"
    else
        if [[ "$cron" -eq 1 ]]; then
            _cipi_run_timed 300 freshclam --stdout >> "$SCAN_LOG" 2>&1 || {
                incomplete=1
                inc_body+="freshclam failed"$'\n'
            }
            _scan_refresh_extra_sigs || {
                incomplete=1
                inc_body+="rfxn signature refresh failed"$'\n'
            }
            _scan_disable_daemons
        fi

        step "ClamAV on upload dirs (${#upaths[@]} path(s), one run)..."
        local db_args=()
        [[ -d /var/lib/clamav ]] && db_args+=(--database=/var/lib/clamav)
        [[ -n "$(ls -A "$SCAN_EXTRA_DB" 2>/dev/null)" ]] && db_args+=(--database="$SCAN_EXTRA_DB")

        local clam_out clam_rc=0
        set +e
        clam_out=$(ionice -c3 nice -n 19 \
            timeout --foreground "$SCAN_TIMEOUT" \
            clamscan --infected --recursive --no-summary --stdout \
                --follow-dir-symlinks=0 \
                --max-filesize=32M --max-scansize=32M \
                --max-recursion=12 --max-files=50000 \
                "${db_args[@]}" \
                "${upaths[@]}" 2>&1)
        clam_rc=$?
        set -euo pipefail
        printf '%s\n' "$clam_out" >> "$report"
        echo "clamscan_exit=${clam_rc}" >> "$report"

        if [[ "$clam_rc" -eq 1 ]]; then
            hits=1
            echo -e "  ${RED}●${NC} infected file(s) in uploads"
            printf '%s\n' "$clam_out" | sed 's/^/    /'
            hit_body+="${clam_out}"$'\n'
        elif [[ "$clam_rc" -eq 0 ]]; then
            echo -e "  ${GREEN}●${NC} uploads: clean"
        elif [[ "$clam_rc" -eq 124 ]]; then
            incomplete=1
            inc_body+="clamscan timed out after ${SCAN_TIMEOUT}s"$'\n'
            warn "clamscan timed out after ${SCAN_TIMEOUT}s — this is not a clean run"
        else
            incomplete=1
            inc_body+="clamscan exited ${clam_rc}"$'\n'
            warn "clamscan exited ${clam_rc} — this is not a clean run"
        fi
    fi

    ln -sfn "$report" "${SCAN_REPORT_DIR}/last.txt"
    # Nothing rotates *.txt in here, and this runs every night.
    ls -1t "${SCAN_REPORT_DIR}"/*.txt 2>/dev/null \
        | grep -v '/last\.txt$' \
        | tail -n +$((SCAN_REPORT_KEEP + 1)) \
        | xargs -r rm -f 2>/dev/null || true

    if [[ -n "$iso_body" ]]; then
        drift_body+="Isolation drift:"$'\n'"${iso_body}"
        drift=$((drift + 1))
    fi

    [[ "$hits" -gt 0 ]] && cipi_notify \
        "Cipi scan: infected uploads on $(hostname)" \
        "ClamAV found infected files in upload directories.\n\nServer: $(hostname)\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')\n\n${hit_body}\nReport: ${report}" \
        scan_hit

    [[ "$drift" -gt 0 ]] && cipi_notify \
        "Cipi scan: release integrity drift on $(hostname)" \
        "Files under current/ (or htdocs/) do not match the manifest written at deploy.\nThat is how a dropped webshell looks, with or without a virus signature.\n\nServer: $(hostname)\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')\n\n${drift_body}\nReport: ${report}" \
        scan_integrity

    if [[ "$incomplete" -gt 0 ]]; then
        cipi_notify \
            "Cipi scan: incomplete run on $(hostname)" \
            "The nightly scan did not finish cleanly. This is not a clean bill of health.\n\nServer: $(hostname)\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')\n\n${inc_body}\nReport: ${report}" \
            scan_incomplete
        warn "Scan incomplete — see ${report}"
    fi

    if [[ "$hits" -eq 0 && "$drift" -eq 0 && "$incomplete" -eq 0 ]]; then
        success "Scan finished — manifests match, uploads clean"
        return 0
    fi
    # Under cron the mail is the signal; a non-zero exit would stack a second,
    # less informative cron_fail on top of it. Interactively the exit status is
    # the whole point, so report it there.
    [[ "$cron" -eq 1 ]] && return 0
    return 1
}

_scan_report() {
    local f="${SCAN_REPORT_DIR}/last.txt"
    if [[ -n "${1:-}" ]]; then
        app_exists "$1" || { error "App '${1}' not found"; exit 1; }
        f="${SCAN_REPORT_DIR}/last.txt"
    fi
    [[ -f "$f" ]] || { info "No scan report yet"; return 0; }
    echo ""
    cat "$f"
    echo ""
}
