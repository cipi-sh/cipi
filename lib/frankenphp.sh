#!/bin/bash
#############################################
# Cipi — FrankenPHP builds for Octane apps
#
# An Octane app answers requests from a FrankenPHP binary, and that binary
# carries a PHP of its own: apt never patches it. Up to 5.9.x Cipi left it to
# Laravel Octane, which downloads `releases/latest` of php/frankenphp into the
# release whenever it finds no binary there — and `frankenphp` is in the
# .gitignore that `octane:install` writes, so every deploy started without
# one and fetched whatever GitHub had that minute, PHP minor included.
#
# From 5.10.0 the binary is Cipi's:
#
#   /opt/cipi-frankenphp/builds/<id>/frankenphp   root:root 0755, never written again
#   /opt/cipi-frankenphp/builds/<id>/meta         frankenphp= php= sha256= source= added=
#   /opt/cipi-frankenphp/apps/<app>               symlink → ../builds/<id>: the pin
#
# A deploy links <release>/frankenphp to /opt/cipi-frankenphp/apps/<app>/frankenphp
# (cipi-frankenphp-link, as the app user, before the release goes live), so
# Octane finds a binary and downloads nothing. Every release — the live one
# and those a rollback goes back to — follows the pin. Changing the pin is
# `cipi frankenphp use|upgrade`, which restarts the app's Octane, checks that
# it answers, and puts the previous build back when it does not.
#
# Several PHP minors side by side: each build records the PHP inside it, and
# an app is only ever moved to a build on its own PHP (apps.json "php"), so an
# app on 8.5 and one on 8.6 run different builds on the same server. GitHub
# publishes static binaries for one PHP minor at a time (the newest); a build
# on another minor is imported (cipi frankenphp import <file>), e.g. one made
# with FrankenPHP's static builder. `upgrade` never changes an app's PHP minor.
#
# Moving an app to another PHP is one command since 5.17.0, and it names the
# version: `cipi frankenphp php <app> 8.6` (or `cipi app edit <app> --php=8.6`,
# which does the same for an Octane app). The build that carries that PHP is
# looked for first — on this server, then in the release GitHub publishes —
# and nothing changes when there is none; then Octane moves to it (restart,
# check, way back) and Composer, artisan, cron and the workers to the server's
# php8.6. One PHP for the whole app, said by its number: "upgrade" never said
# which version would arrive.
#
# Outside /opt/cipi on purpose: self-update copies /opt/cipi into a backup on
# every run, and these binaries are about 100 MB each.
#############################################

# The time of a notification is common.sh's (and follows `cipi notification
# timezone`); loaded on its own, this file still has a clock.
declare -f notify_now >/dev/null 2>&1 || notify_now() { date "$@" '+%Y-%m-%d %H:%M:%S %Z'; }

[[ -z "${FRANKENPHP_ROOT:-}" ]] && FRANKENPHP_ROOT="/opt/cipi-frankenphp"
FRANKENPHP_BUILDS="${FRANKENPHP_ROOT}/builds"
FRANKENPHP_APPS="${FRANKENPHP_ROOT}/apps"
[[ -z "${FRANKENPHP_GITHUB_API:-}" ]] && FRANKENPHP_GITHUB_API="https://api.github.com/repos/php/frankenphp"
[[ -z "${FRANKENPHP_PROC:-}" ]] && FRANKENPHP_PROC="/proc"
[[ -z "${FRANKENPHP_NOTIFIED:-}" ]] && FRANKENPHP_NOTIFIED="/var/lib/cipi/frankenphp-notified"
# Builds kept per PHP minor that no app uses (the previous one, to go back to).
FRANKENPHP_KEEP_UNUSED=1

# ── builds ───────────────────────────────────────────────────

fphp_builds() {   # every build id, oldest FrankenPHP first
    [[ -d "$FRANKENPHP_BUILDS" ]] || return 0
    local d
    for d in "$FRANKENPHP_BUILDS"/*; do
        [[ -d "$d" && -x "${d}/frankenphp" && -f "${d}/meta" ]] || continue
        basename "$d"
    done | sort -V
}

fphp_build_exists() { [[ -n "${1:-}" && "$1" != */* && -x "${FRANKENPHP_BUILDS}/${1}/frankenphp" && -f "${FRANKENPHP_BUILDS}/${1}/meta" ]]; }

fphp_meta() {   # <id> <key>
    sed -n "s/^${2}=//p" "${FRANKENPHP_BUILDS}/${1}/meta" 2>/dev/null | head -n 1
}

fphp_minor() { local v="${1:-}"; [[ "$v" =~ ^([0-9]+\.[0-9]+) ]] && echo "${BASH_REMATCH[1]}"; return 0; }

# True when build $1 is newer than build $2: FrankenPHP first, then its PHP.
fphp_newer() {
    local a b
    a="$(fphp_meta "$1" frankenphp) $(fphp_meta "$1" php)"
    b="$(fphp_meta "$2" frankenphp) $(fphp_meta "$2" php)"
    [[ "$a" != "$b" && "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n 1)" == "$a" ]]
}

# A build an app may be given. An adopted build is the binary that was in
# that app's release: the app user could have put anything there, so it is
# never offered to another app.
fphp_build_trusted_for() {   # <id> <app>
    local src; src=$(fphp_meta "$1" source)
    case "$src" in
        github:*|import:*) return 0 ;;
        "adopted:${2}") return 0 ;;
    esac
    return 1
}

# "<frankenphp version> <php version>" of a binary, run as $2 (nobody by
# default) in a session of its own and without a terminal: the binary is not
# root's to trust (see _php_frankenphp_report).
fphp_probe() {   # <binary> [user]
    local bin="$1" user="${2:-nobody}" out fv pv
    [[ -f "$bin" && -x "$bin" ]] || return 1
    out=$(runuser -u "$user" -- setsid -w timeout 10 "$bin" -v 2>/dev/null < /dev/null || true)
    pv=$(grep -oE 'PHP [0-9]+\.[0-9]+\.[0-9]+' <<< "$out" | head -n 1 | cut -d' ' -f2 || true)
    fv=$(grep -oE 'FrankenPHP v?[0-9]+\.[0-9]+\.[0-9]+' <<< "$out" | head -n 1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
    if [[ -z "$fv" ]]; then
        out=$(runuser -u "$user" -- setsid -w timeout 10 "$bin" build-info 2>/dev/null < /dev/null || true)
        fv=$(grep -E '^[[:space:]]*dep[[:space:]].*/frankenphp[[:space:]]' <<< "$out" | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 | tr -d v || true)
    fi
    [[ -n "$pv" ]] || return 1
    echo "${fv:-0.0.0} ${pv}"
}

# Adds a binary to the store and prints its id. The same bytes twice are one
# build. Messages go to stderr: stdout is the id.
fphp_build_add() {   # <file> <source> [probe user]
    local file="$1" source="$2" user="${3:-nobody}" probe fv pv sha id tmpd
    probe=$(fphp_probe "$file" "$user") || { error "Not a FrankenPHP binary, or it does not start: ${file}"; return 1; }
    read -r fv pv <<< "$probe"
    sha=$(sha256sum "$file" | awk '{ print $1 }')
    for id in $(fphp_builds); do
        if [[ "$(fphp_meta "$id" sha256)" == "$sha" ]]; then
            echo "$id"
            return 0
        fi
    done
    id="${fv}-php${pv}"
    [[ "$source" == github:* ]] || id="${id}-${sha:0:8}"
    [[ -e "${FRANKENPHP_BUILDS}/${id}" ]] && id="${id}-${sha:0:8}"
    install -d -m 755 "$FRANKENPHP_ROOT" "$FRANKENPHP_BUILDS" || return 1
    tmpd=$(mktemp -d "${FRANKENPHP_BUILDS}/.add.XXXXXX") || return 1
    if ! install -m 755 "$file" "${tmpd}/frankenphp"; then rm -rf "$tmpd"; return 1; fi
    {
        echo "frankenphp=${fv}"
        echo "php=${pv}"
        echo "sha256=${sha}"
        echo "source=${source}"
        echo "added=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } > "${tmpd}/meta"
    chmod 644 "${tmpd}/meta"; chmod 755 "$tmpd"
    mv -T "$tmpd" "${FRANKENPHP_BUILDS}/${id}" || { rm -rf "$tmpd"; return 1; }
    log_action "FRANKENPHP BUILD ADDED: ${id} (${source})"
    echo "$id"
}

# ── pins ─────────────────────────────────────────────────────

fphp_app_build() {   # <app> → the pinned build id, or nothing
    local l="${FRANKENPHP_APPS}/${1}" id
    [[ -L "$l" ]] || return 0
    id=$(basename "$(readlink "$l")")
    fphp_build_exists "$id" && echo "$id"
    return 0
}

fphp_app_set() {   # <app> <id> — atomic: a running deploy sees the old pin or the new one
    install -d -m 755 "$FRANKENPHP_ROOT" "$FRANKENPHP_APPS" || return 1
    ln -sfn "../builds/${2}" "${FRANKENPHP_APPS}/.${1}.tmp" || return 1
    mv -Tf "${FRANKENPHP_APPS}/.${1}.tmp" "${FRANKENPHP_APPS}/${1}"
}

fphp_app_unset() { rm -f "${FRANKENPHP_APPS}/${1}"; }

fphp_octane_apps() {
    vault_read apps.json 2>/dev/null | jq -r 'to_entries[] | select(.value.octane == "frankenphp") | .key' 2>/dev/null || true
}

fphp_is_octane() { [[ "$(app_get "$1" octane)" == "frankenphp" ]]; }

# <current release>/frankenphp → the pin. As the app user: it is the app's
# release. A running Octane keeps the binary it started with.
fphp_release_link() {   # <app>
    local app="$1"
    [[ -d "/home/${app}/current" ]] || return 0
    app_as "$app" ln -sfn "${FRANKENPHP_APPS}/${app}/frankenphp" "/home/${app}/current/frankenphp" < /dev/null
}

# The binary the app's next Octane start runs: the pin, or what Octane put in
# the live release.
fphp_app_binary() {   # <app>
    local app="$1"
    if [[ -n "$(fphp_app_build "$app")" ]]; then
        echo "${FRANKENPHP_APPS}/${app}/frankenphp"
    elif [[ -x "/home/${app}/current/frankenphp" ]]; then
        echo "/home/${app}/current/frankenphp"
    fi
    return 0
}

# Where the running FrankenPHP of the app was started from (resolved), or
# nothing when none runs.
fphp_running_exe() {   # <app>
    local pid exe
    pid=$(pgrep -u "$1" -x frankenphp 2>/dev/null | head -n 1 || true)
    [[ -n "$pid" ]] || return 0
    exe=$(readlink "${FRANKENPHP_PROC}/${pid}/exe" 2>/dev/null || true)
    echo "$exe"
}

# True when the running binary is not the pinned one (the pin changed and
# Octane was not restarted, or it runs a binary Octane downloaded).
fphp_restart_pending() {   # <app>
    local app="$1" id exe want
    id=$(fphp_app_build "$app"); [[ -n "$id" ]] || return 1
    exe=$(fphp_running_exe "$app"); [[ -n "$exe" ]] || return 1
    want="${FRANKENPHP_BUILDS}/${id}/frankenphp"
    [[ "$exe" != "$want" && "$exe" != "$(readlink -f "$want" 2>/dev/null)" ]]
}

# The FrankenPHP the live release's laravel/octane asks for, read as the app
# user. Octane replaces a binary below it with the latest download when it
# starts, so a pin below it would not hold.
fphp_octane_required() {   # <app>
    local f="/home/${1}/current/vendor/laravel/octane/src/Commands/Concerns/InstallsFrankenPhpDependencies.php"
    app_read "$1" "$f" 2>/dev/null \
        | grep -oE "requiredFrankenPhpVersion[[:space:]]*=[[:space:]]*'[0-9]+\.[0-9]+\.[0-9]+'" \
        | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true
}

# Pins the binary Octane downloaded into the live release, when the app has
# no pin yet: the same bytes, so nothing restarts. Returns 1 when there is
# nothing to adopt.
fphp_adopt() {   # <app>
    local app="$1" bin tmpd id
    [[ -n "$(fphp_app_build "$app")" ]] && return 0
    bin="/home/${app}/current/frankenphp"
    # -x: Octane makes it executable only once the download is complete.
    [[ -f "$bin" && -x "$bin" && ! -L "$bin" ]] || return 1
    install -d -m 755 "$FRANKENPHP_ROOT" || return 1
    tmpd=$(mktemp -d "${FRANKENPHP_ROOT}/.adopt.XXXXXX") || return 1
    chmod 711 "$tmpd"
    # Read as the app user: root does not open files in an app's home.
    if ! app_as "$app" cat -- "$bin" > "${tmpd}/frankenphp" 2>/dev/null < /dev/null; then
        rm -rf "$tmpd"; return 1
    fi
    chmod 755 "${tmpd}/frankenphp"
    # The binary came out of the app's home: it is probed as that app.
    id=$(fphp_build_add "${tmpd}/frankenphp" "adopted:${app}" "$app") || { rm -rf "$tmpd"; return 1; }
    rm -rf "$tmpd"
    fphp_app_set "$app" "$id" || return 1
    fphp_release_link "$app" || warn "${app}: could not link the release to the pinned build"
    log_action "FRANKENPHP ADOPT: ${app} → ${id}"
    echo "$id"
}

# The newest build an app may be moved to: on the app's own PHP minor, of
# the same FrankenPHP major as the current one (when there is one), and one
# that may be given to it.
fphp_candidate() {   # <app> [current id] [php minor — the app's own by default]
    local app="$1" cur="${2:-}" minor="${3:-}" id best="" major=""
    [[ -n "$minor" ]] || minor=$(app_get "$app" php)
    [[ -n "$cur" ]] && major=$(fphp_meta "$cur" frankenphp | cut -d. -f1)
    for id in $(fphp_builds); do
        [[ "$(fphp_minor "$(fphp_meta "$id" php)")" == "$minor" ]] || continue
        fphp_build_trusted_for "$id" "$app" || continue
        if [[ -n "$major" && "$(fphp_meta "$id" frankenphp | cut -d. -f1)" != "$major" ]]; then continue; fi
        if [[ -z "$best" ]] || fphp_newer "$id" "$best"; then best="$id"; fi
    done
    echo "$best"
}

# The PHP minors an app's Octane can be put on with the builds this server
# has (the ones that may be given to it, on its FrankenPHP major): one per
# line, oldest first.
fphp_minors_for() {   # <app>
    local app="$1" cur id major=""
    cur=$(fphp_app_build "$app")
    [[ -n "$cur" ]] && major=$(fphp_meta "$cur" frankenphp | cut -d. -f1)
    for id in $(fphp_builds); do
        fphp_build_trusted_for "$id" "$app" || continue
        if [[ -n "$major" && "$(fphp_meta "$id" frankenphp | cut -d. -f1)" != "$major" ]]; then continue; fi
        fphp_minor "$(fphp_meta "$id" php)"
    done | sort -uV
    return 0
}

# An app whose Octane answers on another PHP than the one the app is on
# (state "mismatch"): the command that settles it, a tab, and what it does.
# `cipi frankenphp upgrade` was the hint until 5.17.0, and it did nothing
# where no build on the app's PHP was on the server — the usual case, since a
# FrankenPHP release carries one PHP and the newest one is what Octane
# downloads.
fphp_mismatch_fix() {   # <app>
    local app="$1" cur cand ap bp
    cur=$(fphp_app_build "$app"); [[ -n "$cur" ]] || return 0
    ap=$(app_get "$app" php); bp=$(fphp_minor "$(fphp_meta "$cur" php)")
    [[ -n "$bp" && "$bp" != "$ap" ]] || return 0
    cand=$(fphp_candidate "$app" "$cur")
    if [[ -n "$cand" ]]; then
        printf 'cipi frankenphp php %s %s\tOctane back on PHP %s, with the build %s that is on this server\n' "$app" "$ap" "$ap" "$cand"
    else
        printf 'cipi frankenphp php %s %s\tComposer, artisan, cron and the workers to PHP %s as well — no FrankenPHP build on PHP %s is on this server\n' "$app" "$bp" "$bp" "$ap"
    fi
}

# The build that puts an app's Octane on PHP <minor>: the newest one on this
# server — after fetching the release GitHub publishes, unless told not to —
# that may be given to the app and that its laravel/octane accepts. Prints
# the build id; the reason on stderr and 1 when there is none. Changes nothing
# but the store of builds.
fphp_build_for_php() {   # <app> <php minor> [no-fetch]
    local app="$1" want="$2" nofetch="${3:-}" cur latest="" cand req fv have
    cur=$(fphp_app_build "$app")
    if [[ -z "$nofetch" ]]; then
        latest=$(fphp_fetch) || { warn "GitHub could not be reached — only the builds on this server are considered" >&2; latest=""; }
    fi
    cand=$(fphp_candidate "$app" "$cur" "$want")
    if [[ -z "$cand" ]]; then
        have=$(fphp_minors_for "$app" | paste -sd, - | sed 's/,/, /g')
        error "No FrankenPHP build on PHP ${want} for '${app}'." >&2
        {
            echo "  A FrankenPHP release carries one PHP: on this server there are builds on ${have:-none yet}."
            if [[ -n "$latest" ]]; then
                echo "  The release GitHub publishes now ($(fphp_meta "$latest" frankenphp)) carries PHP $(fphp_meta "$latest" php)."
                if [[ -n "$cur" && "$(fphp_meta "$latest" frankenphp | cut -d. -f1)" != "$(fphp_meta "$cur" frankenphp | cut -d. -f1)" ]]; then
                    echo "  It is a new FrankenPHP major: Cipi does not move an app to one by itself — cipi frankenphp use ${app} ${latest}"
                fi
            fi
            echo "  A build on PHP ${want} is made with FrankenPHP's static builder (PHP_VERSION=${want}) and added with: cipi frankenphp import <file>"
        } >&2
        return 1
    fi
    req=$(fphp_octane_required "$app"); fv=$(fphp_meta "$cand" frankenphp)
    if [[ -n "$req" ]] && ! version_at_least "$fv" "$req"; then
        error "The newest build on PHP ${want} is ${cand} (FrankenPHP ${fv}); the live release's laravel/octane needs FrankenPHP ${req} or newer." >&2
        echo "  Octane would replace it with its own download when it starts. Import a newer build on PHP ${want}: cipi frankenphp import <file>" >&2
        return 1
    fi
    echo "$cand"
}

# A new Octane app (create, convert): the newest build on its PHP that the
# server already has. No download — `cipi frankenphp upgrade` does that.
fphp_pin_default() {   # <app>
    local app="$1" id
    [[ -n "$(fphp_app_build "$app")" ]] && return 0
    id=$(fphp_candidate "$app")
    if [[ -n "$id" ]]; then
        fphp_app_set "$app" "$id" && info "FrankenPHP: '${app}' pinned to ${id}"
    else
        info "FrankenPHP: no build on PHP $(app_get "$app" php) on this server yet — the first deploy lets Octane download one and Cipi pins it (or now: cipi frankenphp upgrade ${app})"
    fi
    return 0
}

# ── GitHub ───────────────────────────────────────────────────

fphp_asset_name() {
    local arch gnu=""
    arch=$(uname -m)
    getconf GNU_LIBC_VERSION >/dev/null 2>&1 && gnu="-gnu"
    case "$arch" in
        x86_64)  echo "frankenphp-linux-x86_64${gnu}" ;;
        aarch64) echo "frankenphp-linux-aarch64${gnu}" ;;
        *) return 1 ;;
    esac
}

_fphp_release_json() {   # [tag]
    local url="${FRANKENPHP_GITHUB_API}/releases/latest"
    [[ -n "${1:-}" && "${1:-}" != latest ]] && url="${FRANKENPHP_GITHUB_API}/releases/tags/v${1#v}"
    curl -fsSL --max-time 30 -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' "$url"
}

# "<tag>" of the latest release, without downloading anything.
fphp_latest_tag() {
    _fphp_release_json 2>/dev/null | jq -r '.tag_name // empty' 2>/dev/null || true
}

# Downloads a release (the latest by default) into the store and prints the
# build id; a release already in the store is not downloaded again. The
# download is checked against the digest GitHub publishes for the asset.
fphp_fetch() {   # [tag]
    local json tag fv asset url digest id tmpd sum
    asset=$(fphp_asset_name) || { error "FrankenPHP publishes no binary for $(uname -m)"; return 1; }
    json=$(_fphp_release_json "${1:-}") || { error "Could not read the FrankenPHP release from GitHub"; return 1; }
    tag=$(jq -r '.tag_name // empty' <<< "$json")
    [[ -n "$tag" ]] || { error "GitHub answered without a release"; return 1; }
    fv="${tag#v}"
    for id in $(fphp_builds); do
        if [[ "$(fphp_meta "$id" source)" == "github:${tag}" ]]; then
            echo "$id"
            return 0
        fi
    done
    url=$(jq -r --arg n "$asset" '.assets[]? | select(.name == $n) | .browser_download_url' <<< "$json" | head -n 1)
    digest=$(jq -r --arg n "$asset" '.assets[]? | select(.name == $n) | .digest // empty' <<< "$json" | head -n 1)
    [[ -n "$url" ]] || { error "FrankenPHP ${fv} has no ${asset}"; return 1; }
    install -d -m 755 "$FRANKENPHP_ROOT" || return 1
    tmpd=$(mktemp -d "${FRANKENPHP_ROOT}/.fetch.XXXXXX") || return 1
    chmod 711 "$tmpd"
    step "Downloading FrankenPHP ${fv} (${asset})..." >&2
    if ! curl -fsSL --max-time 600 -o "${tmpd}/frankenphp" "$url"; then
        rm -rf "$tmpd"; error "Download failed: ${url}"; return 1
    fi
    if [[ "$digest" == sha256:* ]]; then
        sum=$(sha256sum "${tmpd}/frankenphp" | awk '{ print $1 }')
        if [[ "$sum" != "${digest#sha256:}" ]]; then
            rm -rf "$tmpd"; error "FrankenPHP ${fv}: the download does not match GitHub's digest — not used"; return 1
        fi
    fi
    chmod 755 "${tmpd}/frankenphp"
    id=$(fphp_build_add "${tmpd}/frankenphp" "github:${tag}") || { rm -rf "$tmpd"; return 1; }
    rm -rf "$tmpd"
    echo "$id"
}

# ── Octane program ───────────────────────────────────────────

_fphp_program_block() {   # <app>
    awk -v p="[program:${1}-octane]" '$0 == p { s = 1; print; next } /^\[program:/ { s = 0 } s' \
        "/etc/supervisor/conf.d/${1}.conf" 2>/dev/null || true
}

# Rewrites the app's Octane program (PHP_INI_SCAN_DIR, PATH: see
# _create_supervisor_octane) and restarts it. A program stopped by hand
# (STOPPED) stays stopped, and 2 says there is nothing to verify; one that
# had crashed (FATAL, EXITED, BACKOFF) is started like a running one.
fphp_octane_restart() {   # <app>
    local app="$1" before after st php_ver port
    php_ver=$(app_get "$app" php); port=$(app_get "$app" octane_port)
    st=$(supervisorctl status "${app}-octane" 2>/dev/null | awk '{ print $2 }' || true)
    before=$(_fphp_program_block "$app")
    _supervisor_remove_program "$app" "${app}-octane"
    _create_supervisor_octane "$app" "$php_ver" "$port"
    after=$(_fphp_program_block "$app")
    if [[ "$before" != "$after" ]]; then
        # reread + update restarts a program whose configuration changed
        supervisorctl reread >/dev/null 2>&1 || true
        supervisorctl update >/dev/null 2>&1 || true
        if [[ "$st" == STOPPED ]]; then
            supervisorctl stop "${app}-octane" >/dev/null 2>&1 || true
            return 2
        fi
    else
        [[ "$st" == STOPPED ]] && return 2
        supervisorctl restart "${app}-octane" >/dev/null 2>&1 || true
    fi
    return 0
}

# Up, and its port answers (any HTTP status: the app decides what it answers,
# this is about FrankenPHP starting).
fphp_octane_verify() {   # <app>
    local app="$1" port i st code tries="${FRANKENPHP_VERIFY_TRIES:-15}"
    port=$(app_get "$app" octane_port)
    for (( i = 0; i < tries; i++ )); do
        sleep 2
        st=$(supervisorctl status "${app}-octane" 2>/dev/null | awk '{ print $2 }' || true)
        [[ "$st" == FATAL ]] && return 1
        [[ "$st" == RUNNING ]] || continue
        code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "http://127.0.0.1:${port}/" 2>/dev/null || true)
        [[ -n "$code" && "$code" != 000 ]] && return 0
    done
    return 1
}

# Moves an app to a build: pin, release link, restart, check — and back to the
# previous build when Octane does not come up on the new one.
fphp_activate() {   # <app> <id> [no-restart]
    local app="$1" id="$2" norestart="${3:-}" prev rc=0
    prev=$(fphp_app_build "$app")
    fphp_app_set "$app" "$id" || { error "Could not pin ${id} for '${app}'"; return 1; }
    fphp_release_link "$app" || warn "${app}: could not link the live release to the pinned build"
    log_action "FRANKENPHP USE: ${app} ${prev:-none} → ${id}"
    if [[ -n "$norestart" ]]; then
        info "'${app}' runs ${id} from its next Octane start (cipi frankenphp restart ${app})"
        return 0
    fi
    step "Restarting ${app}-octane on ${id}..."
    fphp_octane_restart "$app" || rc=$?
    if [[ "$rc" -eq 2 ]]; then
        info "${app}-octane is not running — it starts on ${id} next time"
        return 0
    fi
    if fphp_octane_verify "$app"; then
        success "'${app}' runs FrankenPHP $(fphp_meta "$id" frankenphp) on PHP $(fphp_meta "$id" php)"
        return 0
    fi
    if [[ -n "$prev" && "$prev" != "$id" ]]; then
        warn "Octane did not come up on ${id} — back to ${prev}"
        fphp_app_set "$app" "$prev" || true
        fphp_octane_restart "$app" || true
        fphp_octane_verify "$app" || warn "'${app}' does not answer on ${prev} either — check: tail -n 50 /var/log/cipi-apps/${app}/octane.log"
        log_action "FRANKENPHP ROLLBACK: ${app} ${id} → ${prev}"
    else
        warn "Octane did not come up on ${id} — check: tail -n 50 /var/log/cipi-apps/${app}/octane.log"
    fi
    return 1
}

# ── state, for status / php upgrade / pending ────────────────

# "<state> <build id or -> <php inside or -> <restart pending yes|no>"
# state: ok | vulnerable | mismatch (not the app's PHP minor) | unpinned | missing
fphp_app_state() {   # <app>
    local app="$1" id pv floor state restart=no probe bin
    id=$(fphp_app_build "$app")
    if [[ -n "$id" ]]; then
        pv=$(fphp_meta "$id" php)
    else
        bin="/home/${app}/current/frankenphp"
        if [[ -x "$bin" ]] && id "$app" &>/dev/null && probe=$(fphp_probe "$bin" "$app"); then
            pv="${probe#* }"
            echo "unpinned - ${pv} no"
        else
            echo "missing - - no"
        fi
        return 0
    fi
    floor=$(php_security_floor "$(fphp_minor "$pv")")
    if [[ "$(fphp_minor "$pv")" != "$(app_get "$app" php)" ]]; then
        state=mismatch
    elif [[ -n "$floor" ]] && version_at_least "$pv" "$floor"; then
        state=ok
    else
        state=vulnerable
    fi
    fphp_restart_pending "$app" && restart=yes
    echo "${state} ${id} ${pv} ${restart}"
}

# ── commands ─────────────────────────────────────────────────

frankenphp_command() {
    local sub="${1:-status}"; shift || true
    case "$sub" in
        status|list|ls) _fphp_status "$@" ;;
        fetch)          _fphp_fetch_cmd "$@" ;;
        import)         _fphp_import "$@" ;;
        use|pin)        _fphp_use "$@" ;;
        php)            _fphp_php "$@" ;;
        restart)        _fphp_restart_cmd "$@" ;;
        upgrade)        _fphp_upgrade "$@" ;;
        adopt)          _fphp_adopt_cmd "$@" ;;
        remove|rm)      _fphp_remove "$@" ;;
        prune)          fphp_prune; success "Unused FrankenPHP builds pruned" ;;
        *) error "Use: status php fetch import use upgrade restart adopt remove prune"; exit 1 ;;
    esac
}

_fphp_build_users() {   # <id> → the apps pinned to it, one per line
    local app
    for app in $(fphp_octane_apps); do
        if [[ "$(fphp_app_build "$app")" == "$1" ]]; then echo "$app"; fi
    done
    return 0
}

_fphp_status() {
    parse_args "$@"
    local id app st bid pv rs apps_json="[]" builds_json="[]" users
    if [[ "${ARG_json:-}" == "true" ]]; then
        for id in $(fphp_builds); do
            users=$(_fphp_build_users "$id" | jq -R . | jq -sc .)
            builds_json=$(jq -c --arg id "$id" --arg f "$(fphp_meta "$id" frankenphp)" --arg p "$(fphp_meta "$id" php)" \
                --arg s "$(fphp_meta "$id" source)" --arg a "$(fphp_meta "$id" added)" --argjson u "$users" \
                '. + [{id: $id, frankenphp: $f, php: $p, source: $s, added: $a, apps: $u}]' <<< "$builds_json")
        done
        for app in $(fphp_octane_apps); do
            read -r st bid pv rs <<< "$(fphp_app_state "$app")"
            local fix="" fix_cmd="" fix_why=""
            [[ "$st" == mismatch ]] && fix=$(fphp_mismatch_fix "$app")
            IFS=$'\t' read -r fix_cmd fix_why <<< "$fix"
            apps_json=$(jq -c --arg a "$app" --arg php "$(app_get "$app" php)" --arg st "$st" --arg b "$bid" --arg pv "$pv" --arg rs "$rs" \
                --arg f "$( [[ "$bid" != - ]] && fphp_meta "$bid" frankenphp || true)" \
                --argjson av "$(fphp_minors_for "$app" | jq -R . | jq -sc .)" --arg fc "$fix_cmd" --arg fw "$fix_why" \
                '. + [{app: $a, php: $php, state: $st, build: (if $b == "-" then null else $b end),
                       frankenphp: (if $f == "" then null else $f end), build_php: (if $pv == "-" then null else $pv end),
                       restart_pending: ($rs == "yes"), available_php: $av,
                       fix: (if $fc == "" then null else {command: $fc, why: $fw} end)}]' <<< "$apps_json")
        done
        jq -n --argjson b "$builds_json" --argjson a "$apps_json" --arg auto "$(_fphp_autoupdate_state)" \
            '{builds: $b, apps: $a, autoupdate: ($auto == "on")}'
        return 0
    fi

    echo -e "\n${BOLD}FrankenPHP${NC} ${DIM}— the binary each Octane app runs (${FRANKENPHP_ROOT})${NC}"
    local any=false
    tbl_start
    tbl_head "APP" "PHP" "BUILD" "STATE"
    for app in $(fphp_octane_apps); do
        any=true
        read -r st bid pv rs <<< "$(fphp_app_state "$app")"
        local col="$GREEN" note="$st"
        case "$st" in
            ok)         note="patched" ;;
            vulnerable) col="$RED"; note="VULNERABLE — cipi frankenphp upgrade ${app}" ;;
            mismatch)   col="$YELLOW"; note="Octane answers on PHP ${pv}, the rest of the app runs $(app_get "$app" php) — $(fphp_mismatch_fix "$app" | cut -f1)" ;;
            unpinned)   col="$YELLOW"; note="not pinned (PHP ${pv}, downloaded by Octane) — cipi frankenphp adopt ${app}" ;;
            missing)    col="$YELLOW"; note="no binary yet — deploy, or: cipi frankenphp upgrade ${app}" ;;
        esac
        [[ "$rs" == yes ]] && note="${note}; restart pending (cipi frankenphp restart ${app})"
        tbl_row "$app" "$(app_get "$app" php)" "${bid/#-/—}" "${col}${note}${NC}"
    done
    if [[ "$any" == true ]]; then tbl_print; else echo -e "  ${DIM}No Octane apps.${NC}"; fi
    echo ""
    echo -e "${BOLD}Builds${NC}"
    local nb=0
    tbl_start
    tbl_head "ID" "FRANKENPHP" "PHP" "SOURCE" "USED BY"
    for id in $(fphp_builds); do
        nb=$((nb + 1))
        users=$(_fphp_build_users "$id" | paste -sd, -)
        tbl_row "$id" "$(fphp_meta "$id" frankenphp)" "$(fphp_meta "$id" php)" "${DIM}$(fphp_meta "$id" source)${NC}" "${users:-${DIM}—${NC}}"
    done
    if [[ "$nb" -gt 0 ]]; then tbl_print; else echo -e "  ${DIM}None yet.${NC}"; fi
    echo ""
    echo -e "  ${DIM}Nightly patch updates (same PHP minor, same FrankenPHP major): $(_fphp_autoupdate_state) — cipi autoupdate on|off frankenphp${NC}"
    echo -e "  ${DIM}Upgrade now: ${CYAN}cipi frankenphp upgrade <app>|--all${NC}${DIM}   Another PHP: ${CYAN}cipi frankenphp php <app> <X.Y>${NC}${DIM}   A build of your own: ${CYAN}cipi frankenphp import <binary>${NC}"
    echo ""
}

_fphp_autoupdate_state() {
    if ! declare -f autoupdate_enabled >/dev/null 2>&1; then
        # shellcheck source=/dev/null
        source "${CIPI_LIB}/autoupdate.sh" 2>/dev/null || { echo off; return 0; }
    fi
    if autoupdate_enabled frankenphp; then echo on; else echo off; fi
}

_fphp_fetch_cmd() {
    local tag="${1:-latest}" id
    [[ "$tag" == --* ]] && tag=latest
    id=$(fphp_fetch "$tag") || exit 1
    success "FrankenPHP build ${id}  (FrankenPHP $(fphp_meta "$id" frankenphp), PHP $(fphp_meta "$id" php))"
    echo -e "  ${DIM}Give it to an app: cipi frankenphp use <app> ${id}${NC}"
}

# A binary built elsewhere — the way to run another PHP minor than the one
# GitHub's static binaries carry (FrankenPHP's static builder, PHP_VERSION=8.5).
_fphp_import() {
    local file="${1:-}" id
    [[ -n "$file" && "$file" != --* ]] || { error "Usage: cipi frankenphp import <path to a frankenphp binary>"; exit 1; }
    [[ -f "$file" ]] || { error "No such file: ${file}"; exit 1; }
    local tmpd; tmpd=$(mktemp -d) || exit 1
    chmod 711 "$tmpd"; install -m 755 "$file" "${tmpd}/frankenphp"
    id=$(fphp_build_add "${tmpd}/frankenphp" "import:$(basename "$file")") || { rm -rf "$tmpd"; exit 1; }
    rm -rf "$tmpd"
    success "Imported as ${id}  (FrankenPHP $(fphp_meta "$id" frankenphp), PHP $(fphp_meta "$id" php))"
    echo -e "  ${DIM}Give it to an app: cipi frankenphp use <app> ${id}${NC}"
}

_fphp_need_octane_app() {
    local app="$1"
    [[ -n "$app" && "$app" != --* ]] || return 1
    app_exists "$app" || { error "App '${app}' not found"; exit 1; }
    fphp_is_octane "$app" || { error "'${app}' does not run on Octane (cipi app convert ${app} --to=octane)"; exit 1; }
}

# The checks before an app is given a build. Prints the reason and returns 1.
_fphp_use_refused() {   # <app> <id> <force>
    local app="$1" id="$2" force="$3" pv req fv
    pv=$(fphp_meta "$id" php); fv=$(fphp_meta "$id" frankenphp)
    if ! fphp_build_trusted_for "$id" "$app"; then
        error "${id} is the binary that was in the release of another app ($(fphp_meta "$id" source)) — it is not given to '${app}'"
        return 1
    fi
    [[ "$force" == true ]] && return 0
    if [[ "$(fphp_minor "$pv")" != "$(app_get "$app" php)" ]]; then
        error "${id} carries PHP ${pv}; '${app}' is on PHP $(app_get "$app" php) (Composer, artisan and the workers run on that one)."
        error "To put the whole app on PHP $(fphp_minor "$pv"): cipi frankenphp php ${app} $(fphp_minor "$pv") — or --force for this build alone."
        return 1
    fi
    req=$(fphp_octane_required "$app")
    if [[ -n "$req" ]] && ! version_at_least "$fv" "$req"; then
        error "The live release's laravel/octane needs FrankenPHP ${req} or newer; ${id} is ${fv}."
        error "Octane would replace it with the latest download when it starts. Use a newer build, or --force."
        return 1
    fi
    return 0
}

_fphp_use() {
    local app="${1:-}" id="${2:-}"
    _fphp_need_octane_app "$app" || { error "Usage: cipi frankenphp use <app> <build> [--no-restart] [--force]"; exit 1; }
    [[ -n "$id" && "$id" != --* ]] || { error "Usage: cipi frankenphp use <app> <build> [--no-restart] [--force]"; exit 1; }
    shift 2
    parse_args "$@"
    fphp_build_exists "$id" || { error "No build '${id}' (cipi frankenphp status)"; exit 1; }
    _fphp_use_refused "$app" "$id" "${ARG_force:-false}" || exit 1
    if [[ "$(fphp_app_build "$app")" == "$id" ]] && ! fphp_restart_pending "$app" && [[ "${ARG_force:-}" != true ]]; then
        info "'${app}' already runs ${id}"
        return 0
    fi
    local prev; prev=$(fphp_app_build "$app")
    if fphp_activate "$app" "$id" "$( [[ "${ARG_no_restart:-}" == true ]] && echo yes || true)"; then
        cipi_notify \
            "Cipi FrankenPHP changed: ${app} on $(hostname)" \
            "The FrankenPHP build of an Octane app changed.\n\nServer: $(hostname)\nApp: ${app}\nFrom: ${prev:-not pinned}\nTo: ${id} (FrankenPHP $(fphp_meta "$id" frankenphp), PHP $(fphp_meta "$id" php))\nTime: $(notify_now)" \
            frankenphp_upgrade
        return 0
    fi
    exit 1
}

# cipi frankenphp php <app> [X.Y] [--yes] [--no-fetch] [--json]
#
# One PHP for the whole app, by its number. An Octane app runs two: the one
# inside its FrankenPHP build answers the requests, the server's php<X.Y>
# runs Composer, artisan, cron and the queue workers. This puts both on X.Y:
# the build first — Octane restarts, has to answer, and the previous build
# comes back when it does not, with nothing else changed — then the rest, the
# way `cipi app edit <app> --php=X.Y` moves it. Without a version: what the
# app runs and what it can be moved to.
_fphp_php() {
    local app="${1:-}" want="${2:-}"
    _fphp_need_octane_app "$app" || { error "Usage: cipi frankenphp php <app> [X.Y] [--yes] [--no-fetch] [--json]"; exit 1; }
    shift
    if [[ -z "$want" || "$want" == --* ]]; then want=""; else shift; fi
    parse_args "$@"
    local cur ap full="" bp="" st bid pv rs
    cur=$(fphp_app_build "$app"); ap=$(app_get "$app" php)
    read -r st bid pv rs <<< "$(fphp_app_state "$app")"
    [[ "$pv" != - ]] && { full="$pv"; bp=$(fphp_minor "$pv"); }

    if [[ -z "$want" ]]; then
        local fix="" fix_cmd="" fix_why=""
        [[ "$st" == mismatch ]] && fix=$(fphp_mismatch_fix "$app")
        IFS=$'\t' read -r fix_cmd fix_why <<< "$fix"
        if [[ "${ARG_json:-}" == "true" ]]; then
            jq -n --arg a "$app" --arg php "$ap" --arg op "$full" --arg b "${cur:-}" --arg st "$st" --arg rs "$rs" \
                --arg f "$( [[ -n "$cur" ]] && fphp_meta "$cur" frankenphp || true)" \
                --argjson av "$(fphp_minors_for "$app" | jq -R . | jq -sc .)" --arg fc "$fix_cmd" --arg fw "$fix_why" \
                '{app: $a, php: $php, octane_php: (if $op == "" then null else $op end),
                  build: (if $b == "" then null else $b end), frankenphp: (if $f == "" then null else $f end),
                  state: $st, restart_pending: ($rs == "yes"), available_php: $av,
                  fix: (if $fc == "" then null else {command: $fc, why: $fw} end)}'
            return 0
        fi
        echo -e "\n${BOLD}${app}${NC} ${DIM}— the PHP of an Octane app${NC}"
        echo -e "  Requests (Octane)                  PHP ${BOLD}${full:-none yet}${NC}${cur:+  ${DIM}FrankenPHP build ${cur}${NC}}"
        echo -e "  Composer, artisan, cron, workers   PHP ${BOLD}${ap}${NC}  ${DIM}/usr/bin/php${ap}${NC}"
        if [[ -n "$fix_cmd" ]]; then
            echo -e "  ${YELLOW}Two PHP versions in one app.${NC} ${CYAN}${fix_cmd}${NC}  ${DIM}${fix_why}${NC}"
        fi
        local av; av=$(fphp_minors_for "$app" | paste -sd, - | sed 's/,/, /g')
        echo -e "  ${DIM}Builds on this server for it: PHP ${av:-none yet}. Another version: ${CYAN}cipi frankenphp php ${app} <X.Y>${NC}${DIM} — the release GitHub publishes is fetched then.${NC}\n"
        return 0
    fi

    if ! [[ "$want" =~ ^[0-9]+\.[0-9]+$ ]] || ! validate_php_version "$want"; then
        error "Invalid PHP version '${want}' — one of 8.3, 8.4, 8.5, 8.6"
        exit 1
    fi
    if ! php_is_installed "$want"; then
        error "PHP ${want} is not installed on this server — Composer, artisan and the workers of '${app}' need it: cipi php install ${want}"
        exit 1
    fi
    if [[ "$want" != "$ap" ]]; then
        php_ext_pending_refuse "$want" "Nothing was changed." || exit 1
    fi
    if [[ -z "$cur" ]]; then
        cur=$(fphp_adopt "$app" 2>/dev/null || true)
        [[ -n "$cur" ]] && info "'${app}': pinned the binary it runs (${cur})"
    fi
    local cand
    cand=$(fphp_build_for_php "$app" "$want" "$( [[ "${ARG_no_fetch:-}" == true ]] && echo yes || true)") || exit 1

    if [[ "$cand" == "$cur" && "$want" == "$ap" ]] && ! fphp_restart_pending "$app"; then
        info "'${app}' is on PHP ${want} already — Octane on ${cur}, the rest on /usr/bin/php${want}"
        return 0
    fi
    if [[ "${ARG_yes:-}" != true && -t 0 ]]; then
        echo -e "  ${DIM}Octane: ${cur:-not pinned} → ${cand} (PHP $(fphp_meta "$cand" php)), restarted.$( [[ "$want" != "$ap" ]] && echo " Composer, artisan, cron and workers: PHP ${ap} → ${want}.")${NC}"
        confirm "Put '${app}' on PHP ${want}?" || { info "Nothing changed"; return 0; }
    fi
    if [[ "$cand" != "$cur" ]] || fphp_restart_pending "$app"; then
        if ! fphp_activate "$app" "$cand"; then
            error "'${app}' was not moved: it stays on PHP ${ap}${cur:+, Octane on ${cur}}"
            exit 1
        fi
    fi
    if [[ "$want" != "$ap" ]]; then
        declare -f app_edit >/dev/null 2>&1 || source "${CIPI_LIB}/app.sh"
        # The build is settled here: app_edit moves the rest and leaves it alone.
        CIPI_FPHP_SWITCHING=1 app_edit "$app" "--php=${want}"
    fi
    fphp_prune
    cipi_notify \
        "Cipi FrankenPHP: ${app} on PHP ${want} on $(hostname)" \
        "An Octane app was put on one PHP version.\n\nServer: $(hostname)\nApp: ${app}\nPHP: ${ap}${bp:+ (Octane: ${bp})} → ${want}\nBuild: ${cur:-not pinned} → ${cand} (FrankenPHP $(fphp_meta "$cand" frankenphp), PHP $(fphp_meta "$cand" php))\nTime: $(notify_now)" \
        frankenphp_upgrade
    success "'${app}' is on PHP ${want}: Octane on ${cand}, Composer, artisan, cron and workers on /usr/bin/php${want}"
}

# cipi frankenphp restart <app> — Octane restarted on its pinned build, and
# checked: what a pin changed with --no-restart, or `restart pending`, needs.
_fphp_restart_cmd() {
    local app="${1:-}" rc=0
    _fphp_need_octane_app "$app" || { error "Usage: cipi frankenphp restart <app>"; exit 1; }
    step "Restarting ${app}-octane..."
    fphp_octane_restart "$app" || rc=$?
    if [[ "$rc" -eq 2 ]]; then
        info "${app}-octane is stopped (supervisorctl start ${app}-octane) — left as it is"
        return 0
    fi
    if fphp_octane_verify "$app"; then
        log_action "OCTANE RESTART: ${app}"
        success "${app}-octane restarted and answering"
        return 0
    fi
    error "${app}-octane does not answer after the restart — tail -n 50 /var/log/cipi-apps/${app}/octane.log"
    exit 1
}

_fphp_adopt_cmd() {
    local app="${1:-}" id
    _fphp_need_octane_app "$app" || { error "Usage: cipi frankenphp adopt <app>"; exit 1; }
    if [[ -n "$(fphp_app_build "$app")" ]]; then info "'${app}' is already pinned to $(fphp_app_build "$app")"; return 0; fi
    id=$(fphp_adopt "$app") || { error "No FrankenPHP binary in /home/${app}/current to adopt — deploy first, or: cipi frankenphp upgrade ${app}"; exit 1; }
    success "'${app}' pinned to ${id} — the binary it already runs; nothing restarted"
}

_fphp_remove() {
    local id="${1:-}" app
    [[ -n "$id" ]] || { error "Usage: cipi frankenphp remove <build>"; exit 1; }
    fphp_build_exists "$id" || { error "No build '${id}'"; exit 1; }
    for app in $(fphp_octane_apps); do
        [[ "$(fphp_app_build "$app")" == "$id" ]] && { error "'${app}' uses ${id} — move it first (cipi frankenphp use ${app} <build>)"; exit 1; }
    done
    rm -rf "${FRANKENPHP_BUILDS:?}/${id}"
    log_action "FRANKENPHP BUILD REMOVED: ${id}"
    success "Build ${id} removed"
}

# Builds no app is pinned to. The newest FRANKENPHP_KEEP_UNUSED stay as the
# way back: per PHP minor for builds from GitHub or an import, per app for a
# build adopted from that app's release (it can go to no other app). An
# adopted build of an app that is no longer an Octane app goes.
fphp_prune() {
    local id used src key kept octane
    declare -A keep_count=()
    octane=" $(fphp_octane_apps | tr '\n' ' ') "
    used=" $(for a in $(fphp_octane_apps); do fphp_app_build "$a"; done | tr '\n' ' ') "
    for id in $(fphp_builds | sort -rV); do
        [[ "$used" == *" ${id} "* ]] && continue
        src=$(fphp_meta "$id" source)
        key=""
        case "$src" in
            github:*|import:*) key="minor:$(fphp_minor "$(fphp_meta "$id" php)")" ;;
            adopted:*) [[ "$octane" == *" ${src#adopted:} "* ]] && key="$src" ;;
        esac
        if [[ -n "$key" ]]; then
            kept=${keep_count[$key]:-0}
            if (( kept < FRANKENPHP_KEEP_UNUSED )); then
                keep_count[$key]=$((kept + 1))
                continue
            fi
        fi
        rm -rf "${FRANKENPHP_BUILDS:?}/${id}"
        log_action "FRANKENPHP BUILD PRUNED: ${id}"
    done
    return 0
}

# Once per (app, newer release on another PHP minor): said, not repeated nightly.
_fphp_notify_once() {   # <key> <subject> <body> <trigger>
    local key="$1"
    mkdir -p "$(dirname "$FRANKENPHP_NOTIFIED")" 2>/dev/null || true
    grep -qxF "$key" "$FRANKENPHP_NOTIFIED" 2>/dev/null && return 0
    echo "$key" >> "$FRANKENPHP_NOTIFIED"
    cipi_notify "$2" "$3" "$4"
}

# cipi frankenphp upgrade <app>|--all [--to=<build>] [--no-fetch] [--yes] [--cron]
#
# For each app: the newest build on the app's own PHP minor, of the same
# FrankenPHP major — downloaded first when GitHub has a newer release on that
# minor. Never another PHP minor (cipi app edit --php does that), never a new
# FrankenPHP major by itself (cipi frankenphp use, after reading its notes).
_fphp_upgrade() {
    local target="${1:-}"
    [[ "$target" == --* || -z "$target" ]] || shift
    parse_args "$@"
    if [[ "$target" == --* ]]; then target=""; fi
    local -a apps=()
    if [[ "${ARG_all:-}" == true || "$target" == "" && "${ARG_cron:-}" == true ]]; then
        mapfile -t apps < <(fphp_octane_apps)
    elif [[ -n "$target" ]]; then
        _fphp_need_octane_app "$target" || exit 1
        apps=("$target")
    else
        error "Usage: cipi frankenphp upgrade <app>|--all [--to=<build>] [--no-fetch] [--yes]"
        exit 1
    fi
    [[ ${#apps[@]} -gt 0 ]] || { info "No Octane apps"; return 0; }

    local cron="${ARG_cron:-false}" latest="" rc=0 app cur cand msg
    if [[ -z "${ARG_to:-}" && "${ARG_no_fetch:-}" != true ]]; then
        latest=$(fphp_fetch) || { warn "GitHub could not be reached — only builds already on this server are considered"; latest=""; }
    fi

    for app in "${apps[@]}"; do
        cur=$(fphp_app_build "$app")
        if [[ -z "$cur" ]]; then
            cur=$(fphp_adopt "$app" 2>/dev/null || true)
            [[ -n "$cur" ]] && info "'${app}': pinned the binary it runs (${cur})"
        fi
        if [[ -n "${ARG_to:-}" ]]; then
            fphp_build_exists "${ARG_to}" || { error "No build '${ARG_to}'"; exit 1; }
            cand="${ARG_to}"
            _fphp_use_refused "$app" "$cand" false || { rc=1; continue; }
        else
            cand=$(fphp_candidate "$app" "$cur")
        fi
        if [[ -n "$latest" && -n "$cur" && "$latest" != "$cand" ]] && fphp_newer "$latest" "$cur"; then
            if [[ "$(fphp_minor "$(fphp_meta "$latest" php)")" != "$(app_get "$app" php)" ]]; then
                msg="FrankenPHP $(fphp_meta "$latest" frankenphp) is out and carries PHP $(fphp_meta "$latest" php); '${app}' is on PHP $(app_get "$app" php), so Cipi keeps it on ${cand:-$cur}. To move it: cipi frankenphp php ${app} $(fphp_minor "$(fphp_meta "$latest" php)"). To stay and keep getting PHP patches: build FrankenPHP on PHP $(app_get "$app" php) and cipi frankenphp import it."
                info "$msg"
                [[ "$cron" == true ]] && _fphp_notify_once "${app} ${latest}" \
                    "Cipi FrankenPHP: a release on another PHP for ${app} on $(hostname)" \
                    "${msg}\n\nServer: $(hostname)\nApp: ${app}\nCurrent build: ${cur}\nTime: $(notify_now)" \
                    frankenphp_available
            elif [[ "$(fphp_meta "$latest" frankenphp | cut -d. -f1)" != "$(fphp_meta "$cur" frankenphp | cut -d. -f1)" ]]; then
                msg="FrankenPHP $(fphp_meta "$latest" frankenphp) is a new major release; '${app}' stays on ${cur} until you move it: cipi frankenphp use ${app} ${latest}"
                info "$msg"
                [[ "$cron" == true ]] && _fphp_notify_once "${app} ${latest}" \
                    "Cipi FrankenPHP: new major release for ${app} on $(hostname)" "${msg}\n\nServer: $(hostname)" frankenphp_available
            fi
        fi
        if [[ -z "$cand" ]]; then
            if [[ -z "$cur" ]]; then
                warn "'${app}': no FrankenPHP build on PHP $(app_get "$app" php) on this server, and no binary to adopt — deploy first, or import one"
            else
                warn "'${app}': no FrankenPHP build on PHP $(app_get "$app" php) on this server — it stays on ${cur}"
            fi
            continue
        fi
        if [[ "$cand" == "$cur" ]] && ! fphp_restart_pending "$app"; then
            info "'${app}' is up to date (${cur})"
            continue
        fi
        if [[ "$cron" != true && "${ARG_yes:-}" != true && -t 0 ]]; then
            confirm "Move '${app}' ${cur:-(not pinned)} → ${cand}? Its Octane restarts" || { info "Skipped '${app}'"; continue; }
        fi
        if fphp_activate "$app" "$cand"; then
            cipi_notify \
                "Cipi FrankenPHP upgraded: ${app} on $(hostname)" \
                "The FrankenPHP build of an Octane app was upgraded.\n\nServer: $(hostname)\nApp: ${app}\nFrom: ${cur:-not pinned}\nTo: ${cand} (FrankenPHP $(fphp_meta "$cand" frankenphp), PHP $(fphp_meta "$cand" php))\nTime: $(notify_now)" \
                frankenphp_upgrade
        else
            rc=1
            cipi_notify \
                "Cipi FrankenPHP upgrade failed: ${app} on $(hostname)" \
                "Octane did not come up on ${cand}; the app was put back on ${cur:-its previous binary}.\n\nServer: $(hostname)\nApp: ${app}\nLog: /var/log/cipi-apps/${app}/octane.log\nTime: $(notify_now)" \
                frankenphp_upgrade
        fi
    done
    fphp_prune
    return "$rc"
}
