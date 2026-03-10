#!/bin/bash
#############################################
# Cipi — Self-Update
#############################################

readonly _CIPI_REPO="cipi-sh/cipi"

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
    GIT_TERMINAL_PROMPT=0 git clone -b "$branch" --depth 1 "https://github.com/${_CIPI_REPO}.git" "$tmp" 2>/dev/null \
        || { error "Download failed"; exit 1; }
    local nv; nv=$(tr -d '[:space:]' < "${tmp}/version.md" 2>/dev/null)
    [[ -z "$nv" ]] && { error "Invalid package (version.md missing)"; rm -rf "$tmp"; exit 1; }
    info "Updating v${CIPI_VERSION} → v${nv}"
    cp -r /opt/cipi "/opt/cipi.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null||true
    cp "${tmp}/cipi" /usr/local/bin/cipi; chmod 700 /usr/local/bin/cipi
    cp "${tmp}"/lib/*.sh /opt/cipi/lib/; chmod 700 /opt/cipi/lib/*.sh
    [[ -f "${tmp}/lib/cipi-worker.sh" ]] && cp "${tmp}/lib/cipi-worker.sh" /usr/local/bin/cipi-worker && chmod 700 /usr/local/bin/cipi-worker
    [[ -f "${tmp}/lib/cipi-cron-notify.sh" ]] && cp "${tmp}/lib/cipi-cron-notify.sh" /usr/local/bin/cipi-cron-notify && chmod 700 /usr/local/bin/cipi-cron-notify
    [[ -f "${tmp}/lib/cipi-auth-notify.sh" ]] && cp "${tmp}/lib/cipi-auth-notify.sh" /usr/local/bin/cipi-auth-notify && chmod 700 /usr/local/bin/cipi-auth-notify
    [[ -d "${tmp}/cipi-api" ]] && rm -rf /opt/cipi/cipi-api && cp -a "${tmp}/cipi-api" /opt/cipi/cipi-api
    chown -R root:root /usr/local/bin/cipi /opt/cipi

    # Run migrations
    if [[ -d "${tmp}/lib/migrations" ]]; then
        for m in $(ls "${tmp}/lib/migrations/"*.sh 2>/dev/null|sort -V); do
            local mv; mv=$(basename "$m" .sh)
            if [[ "$(printf '%s\n' "$CIPI_VERSION" "$mv"|sort -V|head -1)" == "$CIPI_VERSION" && "$mv" != "$CIPI_VERSION" ]]; then
                step "Migration ${mv}..."; bash "$m" 2>&1
            fi
        done
    fi

    # Auto-update cipi-api package in installed API app
    if [[ -f "${CIPI_API_ROOT:-/opt/cipi/api}/artisan" ]] && [[ -d /opt/cipi/cipi-api ]]; then
        step "Updating cipi-api in Laravel app..."
        local api_root="${CIPI_API_ROOT:-/opt/cipi/api}"
        (cd "$api_root" && composer config repositories.cipi-api path /opt/cipi/cipi-api 2>/dev/null) || true
        (cd "$api_root" && composer update cipi/api --no-interaction 2>/dev/null) || true
        (cd "$api_root" && php artisan vendor:publish --tag=cipi-assets --force 2>/dev/null) || true
        (cd "$api_root" && sudo -u www-data php artisan migrate --force 2>/dev/null) || true
        chown -R www-data:www-data "$api_root"
        systemctl restart cipi-queue 2>/dev/null || true
        success "cipi-api package updated in Laravel app"
    fi

    echo "$nv" > "${CIPI_CONFIG}/version"
    rm -rf "$tmp"
    log_action "SELF-UPDATE: v${CIPI_VERSION} → v${nv}"
    success "Updated to v${nv}"
}
