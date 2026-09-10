#!/bin/bash
#############################################
# Cipi — Self-Update
#############################################

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

selfupdate_command() {
    parse_args "$@"
    local branch="${ARG_branch:-latest}"
    if [[ "${ARG_check:-}" == "true" ]]; then
        local rv; rv=$(curl -fsSL "https://raw.githubusercontent.com/${_CIPI_REPO}/refs/heads/${branch}/version.md" 2>/dev/null | tr -d '[:space:]')
        [[ -z "$rv" ]] && { error "Cannot check updates"; exit 1; }
        [[ "$rv" == "$CIPI_VERSION" ]] && success "Up to date (v${CIPI_VERSION})" || info "Update: v${CIPI_VERSION} → v${rv}"
        return
    fi

    step "Downloading from '${branch}'..."
    local tmp="/tmp/cipi-update-$$"; rm -rf "$tmp"

    if ! command -v git >/dev/null 2>&1; then
        error "git is not installed — cannot download the update"
        echo "  Install it with:  apt-get install -y git"
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
    # Snapshot before we rewrite /etc/cipi/version or re-source libs — the
    # nightly cron always refreshes files, but the mail must fire only on a bump.
    local old_ver="${CIPI_VERSION}" version_changed=false
    if [[ "$nv" != "$old_ver" ]]; then
        version_changed=true
    fi
    info "Updating v${old_ver} → v${nv}"
    cp -r /opt/cipi "/opt/cipi.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null||true
    cp "${tmp}/cipi" /usr/local/bin/cipi; chmod 700 /usr/local/bin/cipi
    cp "${tmp}"/lib/*.sh /opt/cipi/lib/; chmod 700 /opt/cipi/lib/*.sh
    cp "${tmp}/lib/gui-reset-admin.php" /opt/cipi/lib/ 2>/dev/null || true
    chmod 644 /opt/cipi/lib/gui-reset-admin.php 2>/dev/null || true
    [[ -d "${tmp}/lib/deployer" ]] && cp -r "${tmp}/lib/deployer" /opt/cipi/lib/
    [[ -f "${tmp}/lib/cipi-worker.sh" ]] && cp "${tmp}/lib/cipi-worker.sh" /usr/local/bin/cipi-worker && chmod 700 /usr/local/bin/cipi-worker
    [[ -f "${tmp}/lib/cipi-cron-notify.sh" ]] && cp "${tmp}/lib/cipi-cron-notify.sh" /usr/local/bin/cipi-cron-notify && chmod 700 /usr/local/bin/cipi-cron-notify
    [[ -f "${tmp}/lib/cipi-auth-notify.sh" ]] && cp "${tmp}/lib/cipi-auth-notify.sh" /usr/local/bin/cipi-auth-notify && chmod 700 /usr/local/bin/cipi-auth-notify
    [[ -f "${tmp}/lib/cipi-app-notify.sh" ]] && cp "${tmp}/lib/cipi-app-notify.sh" /usr/local/bin/cipi-app-notify && chmod 700 /usr/local/bin/cipi-app-notify
    [[ -f "${tmp}/lib/cipi-app-deploy.sh" ]] && cp "${tmp}/lib/cipi-app-deploy.sh" /usr/local/bin/cipi-app-deploy && chmod 755 /usr/local/bin/cipi-app-deploy
    [[ -f "${tmp}/lib/cipi-app-post-deploy.sh" ]] && cp "${tmp}/lib/cipi-app-post-deploy.sh" /usr/local/bin/cipi-app-post-deploy && chmod 755 /usr/local/bin/cipi-app-post-deploy
    [[ -f "${tmp}/lib/cipi-health-check.sh" ]] && cp "${tmp}/lib/cipi-health-check.sh" /usr/local/bin/cipi-health-check && chmod 700 /usr/local/bin/cipi-health-check
    [[ -f "${tmp}/lib/cipi-scan-manifest.sh" ]] && cp "${tmp}/lib/cipi-scan-manifest.sh" /usr/local/bin/cipi-scan-manifest && chmod 755 /usr/local/bin/cipi-scan-manifest
    [[ -f "${tmp}/lib/cipi-crowdsec-rescue.py" ]] && cp "${tmp}/lib/cipi-crowdsec-rescue.py" /usr/local/bin/cipi-crowdsec-rescue && chmod 700 /usr/local/bin/cipi-crowdsec-rescue
    [[ -f "${tmp}/lib/cipi-crowdsec-rescue-hole.sh" ]] && cp "${tmp}/lib/cipi-crowdsec-rescue-hole.sh" /usr/local/bin/cipi-crowdsec-rescue-hole && chmod 700 /usr/local/bin/cipi-crowdsec-rescue-hole
    if systemctl is-active --quiet cipi-crowdsec-rescue 2>/dev/null; then
        systemctl restart cipi-crowdsec-rescue 2>/dev/null || true
    fi
    [[ -f "${tmp}/lib/cipi-read-app-logs.sh" ]] && cp "${tmp}/lib/cipi-read-app-logs.sh" /usr/local/bin/cipi-read-app-logs && chmod 755 /usr/local/bin/cipi-read-app-logs
    [[ -d "${tmp}/cipi-api" ]] && rm -rf /opt/cipi/cipi-api && cp -a "${tmp}/cipi-api" /opt/cipi/cipi-api
    chown -R root:root /usr/local/bin/cipi /opt/cipi

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
                    error "Migration ${mv} failed — version not updated, installation unchanged at v${CIPI_VERSION}"
                    rm -rf "$tmp"
                    exit 1
                fi
            fi
        done
    fi

    # Record the new version before panel package updates. Composer/migrate for
    # cipi/api can take minutes or hang; core files and migrations are already done.
    if declare -f _cipi_ensure_config_writable >/dev/null 2>&1; then
        _cipi_ensure_config_writable || true
    fi
    echo "$nv" > "${CIPI_CONFIG}/version"
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
        reload_php_fpm "8.5" 2>/dev/null || true
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
            "Cipi updated itself.\n\nServer: $(hostname)\nVersion: v${old_ver} → v${nv}\nTime: $(date '+%Y-%m-%d %H:%M:%S %Z')\n\nChangelog: https://github.com/cipi-sh/cipi/blob/master/CHANGELOG.md\n\nTurn this off with: cipi notifications disable self_update" \
            self_update
    fi
    success "Updated to v${nv}"
}
