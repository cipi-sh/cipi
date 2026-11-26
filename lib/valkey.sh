#!/bin/bash
#############################################
# Cipi — One Valkey per app
#
# The server's Valkey (valkey-server, 127.0.0.1:6379) has one password, and
# until 5.9.0 every app got it in its .env: any app could read and write the
# cache, the sessions and the queues of every other app, and FLUSHDB in one
# emptied them all.
#
# An app now has an instance of its own:
#
#   systemd        cipi-valkey@<app>.service, running as the app's user
#   listens on     127.0.0.1:<port> — one port per app, from 6400 up
#   password       its own (requirepass), in the app's .env only
#   configuration  /etc/cipi-valkey/<app>.conf   root:<app> 0640
#   data           /var/lib/cipi-valkey/<app>    <app> 0700
#
# Instances rather than ACL users on the shared one: an ACL confines an app
# to a key prefix, and Laravel's prefix is a setting of the app — two apps
# with the same APP_NAME share it, a package that writes outside it breaks.
# With its own instance an app keeps every key name it uses today, FLUSHDB
# stays its own business, and the process is not shared at all. An idle
# instance costs about 10 MB of RAM.
#
# `cipi app create` gives a new Laravel app its instance (--valkey=shared
# keeps the old behaviour). An app that exists already is not touched until
# someone asks: `cipi valkey isolate <app>` copies its keys, switches its
# .env and restarts its workers, with the app in maintenance mode for the
# seconds the copy takes.
#
#   cipi valkey list [--json]
#   cipi valkey isolate <app>|--all [--no-copy] [--maxmemory=256mb] [--policy=…] [--yes]
#   cipi valkey share <app> [--no-copy] [--yes]
#   cipi valkey restart <app>
#   cipi valkey flush-shared [--yes]
#############################################

# The time of a notification is common.sh's (and follows `cipi notification
# timezone`); loaded on its own, this file still has a clock.
declare -f notify_now >/dev/null 2>&1 || notify_now() { date "$@" '+%Y-%m-%d %H:%M:%S %Z'; }

[[ -z "${VALKEY_CONF_DIR:-}" ]] && readonly VALKEY_CONF_DIR="/etc/cipi-valkey"
[[ -z "${VALKEY_DATA_DIR:-}" ]] && readonly VALKEY_DATA_DIR="/var/lib/cipi-valkey"
[[ -z "${VALKEY_UNIT_FILE:-}" ]] && readonly VALKEY_UNIT_FILE="/etc/systemd/system/cipi-valkey@.service"
[[ -z "${VALKEY_PORT_MIN:-}" ]] && readonly VALKEY_PORT_MIN=6400
[[ -z "${VALKEY_PORT_MAX:-}" ]] && readonly VALKEY_PORT_MAX=6999
[[ -z "${VALKEY_SHARED_PORT:-}" ]] && readonly VALKEY_SHARED_PORT=6379

# Set by valkey_instance_create for its caller.
VALKEY_NEW_PORT=""
VALKEY_NEW_PASS=""

_valkey_app_ok() { [[ "${1:-}" =~ ^[a-z][a-z0-9]{2,31}$ ]]; }

# Servers installed before Cipi moved to Valkey still run Redis: same
# protocol, same configuration file, same command line.
_valkey_server_bin() { command -v valkey-server 2>/dev/null || command -v redis-server 2>/dev/null; }
_valkey_cli_bin()    { command -v valkey-cli 2>/dev/null || command -v redis-cli 2>/dev/null; }

valkey_available() { _valkey_server_bin >/dev/null && _valkey_cli_bin >/dev/null; }

_valkey_unit()     { printf 'cipi-valkey@%s.service' "$1"; }
_valkey_conf()     { printf '%s/%s.conf' "$VALKEY_CONF_DIR" "$1"; }

valkey_has_instance() { _valkey_app_ok "${1:-}" && [[ -f "$(_valkey_conf "$1")" ]]; }

valkey_instance_port() { awk '$1 == "port" { print $2; exit }' "$(_valkey_conf "$1")" 2>/dev/null || true; }
valkey_instance_pass() { awk '$1 == "requirepass" { print $2; exit }' "$(_valkey_conf "$1")" 2>/dev/null || true; }

valkey_shared_pass() {
    vault_read server.json 2>/dev/null | jq -r '.valkey_password // .redis_password // empty' 2>/dev/null || true
}

# The password travels in the environment, never on a command line: every
# local user can read those in /proc.
_valkey_cli() {   # <port> <password> [valkey-cli args…]
    local port="$1" pass="$2"; shift 2
    REDISCLI_AUTH="$pass" VALKEYCLI_AUTH="$pass" "$(_valkey_cli_bin)" -h 127.0.0.1 -p "$port" "$@" 2>/dev/null
}

_valkey_wait() {   # <port> <password> — up to 15 seconds for PONG
    local i
    for i in $(seq 1 30); do
        [[ "$(_valkey_cli "$1" "$2" PING || true)" == "PONG" ]] && return 0
        sleep 0.5
    done
    return 1
}

_valkey_port_free() {
    local p="$1"
    [[ "$p" =~ ^[0-9]+$ ]] && (( p >= VALKEY_PORT_MIN && p <= VALKEY_PORT_MAX )) || return 1
    grep -qsxE "port[[:space:]]+${p}" "$VALKEY_CONF_DIR"/*.conf 2>/dev/null && return 1
    if command -v ss &>/dev/null; then
        ss -ltn 2>/dev/null | grep -qE ":${p}[[:space:]]" && return 1
    fi
    return 0
}

_valkey_port_allocate() {
    local p used
    used=$(vault_read apps.json 2>/dev/null | jq -r '.[] | .valkey_port // empty | tostring' 2>/dev/null || true)
    for p in $(seq "$VALKEY_PORT_MIN" "$VALKEY_PORT_MAX"); do
        grep -qx "$p" <<< "$used" && continue
        _valkey_port_free "$p" || continue
        echo "$p"
        return 0
    done
    return 1
}

# ── systemd template ─────────────────────────────────────────
# Type=simple: no assumption about how the server binary was built. The
# sandboxing lines are the ones Ubuntu's own valkey-server unit carries;
# /home is hidden from the instance — it has nothing to read there.
_valkey_unit_text() {
    local bin; bin=$(_valkey_server_bin)
    cat <<EOF
# Managed by Cipi — rewritten on update. One Valkey per app (cipi valkey):
# cipi-valkey@<app> runs as the app's user, with the port and the password
# in ${VALKEY_CONF_DIR}/<app>.conf and its data in ${VALKEY_DATA_DIR}/<app>.
[Unit]
Description=Cipi Valkey for app %i
After=network.target
StartLimitIntervalSec=0

[Service]
Type=simple
User=%i
ExecStart=${bin} ${VALKEY_CONF_DIR}/%i.conf --daemonize no --supervised no
WorkingDirectory=${VALKEY_DATA_DIR}/%i
Restart=always
RestartSec=2
TimeoutStopSec=60
LimitNOFILE=65535
UMask=0077
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectHome=true
ProtectSystem=full
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=true
RestrictRealtime=true
RestrictSUIDSGID=true
LockPersonality=true
MemoryDenyWriteExecute=true
CapabilityBoundingSet=

[Install]
WantedBy=multi-user.target
EOF
}

# Idempotent. Returns 1 when there is no server binary to point the unit at.
valkey_unit_install() {
    _valkey_server_bin >/dev/null || return 1
    local tmp
    tmp=$(mktemp) || return 1
    _valkey_unit_text > "$tmp"
    if [[ -f "$VALKEY_UNIT_FILE" ]] && cmp -s "$tmp" "$VALKEY_UNIT_FILE"; then
        rm -f "$tmp"; return 0
    fi
    install -m 644 -o root -g root "$tmp" "$VALKEY_UNIT_FILE" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    systemctl daemon-reload 2>/dev/null || true
    return 0
}

_valkey_valid_maxmemory() { [[ "${1:-}" =~ ^[1-9][0-9]{0,5}(kb|mb|gb)$ ]]; }
_valkey_valid_policy() {
    case "${1:-}" in
        noeviction|allkeys-lru|allkeys-lfu|allkeys-random|volatile-lru|volatile-lfu|volatile-random|volatile-ttl) return 0 ;;
        *) return 1 ;;
    esac
}

_valkey_conf_text() {   # <app> <port> <password> [maxmemory] [policy]
    local app="$1" port="$2" pass="$3" mm="${4:-}" pol="${5:-}"
    cat <<EOF
# Managed by Cipi — rewritten by \`cipi valkey\`. The Valkey of app ${app}.
bind 127.0.0.1
port ${port}
protected-mode yes
requirepass ${pass}
daemonize no
dir ${VALKEY_DATA_DIR}/${app}
dbfilename dump.rdb
appendonly no
save 3600 1
save 300 100
save 60 10000
EOF
    [[ -n "$mm" ]]  && echo "maxmemory ${mm}"
    [[ -n "$pol" ]] && echo "maxmemory-policy ${pol}"
    return 0
}

# Creates and starts the instance of one app. Port and password are chosen
# here unless given (an import brings the ones already in the app's .env).
# On success VALKEY_NEW_PORT / VALKEY_NEW_PASS hold them; apps.json is the
# caller's to update (valkey_port). On failure nothing is left behind.
valkey_instance_create() {   # <app> [port] [password] [maxmemory] [policy]
    local app="${1:-}" port="${2:-}" pass="${3:-}" mm="${4:-}" pol="${5:-}" grp conf tmp
    VALKEY_NEW_PORT=""; VALKEY_NEW_PASS=""
    _valkey_app_ok "$app" || return 1
    id "$app" &>/dev/null || return 1
    valkey_available || return 1
    command -v systemctl &>/dev/null || return 1
    grp=$(id -gn "$app" 2>/dev/null) || return 1
    conf=$(_valkey_conf "$app")
    [[ -f "$conf" ]] && return 1

    if [[ -z "$port" ]] || ! _valkey_port_free "$port"; then
        port=$(_valkey_port_allocate) || return 1
    fi
    [[ "$pass" =~ ^[A-Za-z0-9]{16,128}$ ]] || pass=$(generate_password 40)
    [[ -n "$mm" ]]  && { _valkey_valid_maxmemory "$mm" || return 1; }
    [[ -n "$pol" ]] && { _valkey_valid_policy "$pol" || return 1; }

    install -d -m 755 -o root -g root "$VALKEY_CONF_DIR" "$VALKEY_DATA_DIR" || return 1
    # A directory left by an app of the same name that was deleted holds that
    # app's data: a new instance starts empty.
    rm -rf "${VALKEY_DATA_DIR:?}/${app}"
    install -d -m 700 -o "$app" -g "$grp" "${VALKEY_DATA_DIR}/${app}" || return 1

    tmp=$(mktemp) || return 1
    _valkey_conf_text "$app" "$port" "$pass" "$mm" "$pol" > "$tmp"
    if ! install -m 640 -o root -g "$grp" "$tmp" "$conf"; then
        rm -f "$tmp"; return 1
    fi
    rm -f "$tmp"

    if ! valkey_unit_install \
       || ! systemctl enable "$(_valkey_unit "$app")" >/dev/null 2>&1 \
       || ! systemctl restart "$(_valkey_unit "$app")" >/dev/null 2>&1 \
       || ! _valkey_wait "$port" "$pass"; then
        valkey_instance_remove "$app"
        return 1
    fi
    VALKEY_NEW_PORT="$port"; VALKEY_NEW_PASS="$pass"
    return 0
}

valkey_instance_remove() {   # <app> — the unit, the configuration, the data
    local app="${1:-}"
    _valkey_app_ok "$app" || return 0
    if command -v systemctl &>/dev/null; then
        systemctl disable --now "$(_valkey_unit "$app")" >/dev/null 2>&1 || true
        systemctl reset-failed "$(_valkey_unit "$app")" >/dev/null 2>&1 || true
    fi
    rm -f "$(_valkey_conf "$app")"
    rm -rf "${VALKEY_DATA_DIR:?}/${app}"
    return 0
}

# Instances whose user is gone (a create that stopped half way, an account
# removed by hand).
valkey_instances_sweep() {
    local c app
    for c in "$VALKEY_CONF_DIR"/*.conf; do
        [[ -f "$c" ]] || continue
        app="${c##*/}"; app="${app%.conf}"
        _valkey_app_ok "$app" || continue
        id "$app" &>/dev/null || valkey_instance_remove "$app"
    done
    return 0
}

# After the valkey packages were upgraded: the instances keep running the
# old binary until restarted. Each saves on the way down and loads on the way
# up, like the shared one when apt restarts it.
valkey_instances_restart_all() {
    local c app
    for c in "$VALKEY_CONF_DIR"/*.conf; do
        [[ -f "$c" ]] || continue
        app="${c##*/}"; app="${app%.conf}"
        _valkey_app_ok "$app" || continue
        systemctl try-restart "$(_valkey_unit "$app")" >/dev/null 2>&1 || true
    done
    return 0
}

# The REDIS_* lines of a new app's .env, in the shape _app_redis_env_block
# gives them (appended to the QUEUE_CONNECTION line of the template).
valkey_env_block() {   # <port> <password>
    printf '\n\nREDIS_HOST=127.0.0.1\nREDIS_PASSWORD=%s\nREDIS_PORT=%s' "$2" "$1"
}

# ── an app's .env ────────────────────────────────────────────
# One value of the app's shared/.env, read as the app's user; quotes off.
_valkey_env_get() {   # <env text> <KEY>
    local v
    v=$(grep -E "^${2}=" <<< "$1" | tail -n 1 | cut -d= -f2- || true)
    v="${v%$'\r'}"
    if [[ "$v" == \"*\" && ${#v} -ge 2 ]]; then v="${v:1:${#v}-2}"
    elif [[ "$v" == \'*\' && ${#v} -ge 2 ]]; then v="${v:1:${#v}-2}"; fi
    printf '%s' "$v"
}

_valkey_env_text() {   # <app> → the text of its shared/.env, or nothing
    local env="/home/${1}/shared/.env"
    app_read "$1" "$env" 2>/dev/null || true
}

# Where an app's .env points: "own" (its instance), "shared" (it holds the
# server's password), "external" (another host, port or a REDIS_URL), "none".
_valkey_app_target() {   # <app> [env text]
    local app="$1" text="${2-}" host port pass url shared
    [[ $# -ge 2 ]] || text=$(_valkey_env_text "$app")
    [[ -n "$text" ]] || { echo none; return 0; }
    host=$(_valkey_env_get "$text" REDIS_HOST); port=$(_valkey_env_get "$text" REDIS_PORT)
    pass=$(_valkey_env_get "$text" REDIS_PASSWORD); url=$(_valkey_env_get "$text" REDIS_URL)
    if [[ -n "$url" ]]; then echo external; return 0; fi
    case "$host" in ""|127.0.0.1|localhost|::1) ;; *) echo external; return 0 ;; esac
    if valkey_has_instance "$app" && [[ "$port" == "$(valkey_instance_port "$app")" ]]; then
        echo own; return 0
    fi
    shared=$(valkey_shared_pass)
    if [[ -n "$shared" && "$pass" == "$shared" && ( -z "$port" || "$port" == "$VALKEY_SHARED_PORT" ) ]]; then
        echo shared; return 0
    fi
    if [[ -z "$host$port$pass" ]]; then echo none; return 0; fi
    echo external
}

_valkey_laravel_apps() {
    vault_read apps.json 2>/dev/null \
        | jq -r 'to_entries[] | select((.value.custom // false) != true and (.value.custom // "") != "true") | .key' 2>/dev/null || true
}

# Apps whose .env holds the shared instance's password, one per line.
valkey_shared_apps() {
    local app
    [[ -n "$(valkey_shared_pass)" ]] || return 0
    while IFS= read -r app; do
        [[ -n "$app" ]] || continue
        id "$app" &>/dev/null || continue
        [[ "$(_valkey_app_target "$app")" == "shared" ]] && echo "$app"
    done < <(_valkey_laravel_apps)
    return 0
}

# ── the app's key prefix ─────────────────────────────────────
# Laravel puts one prefix in front of every key it writes through a Redis
# connection (database.redis.options.prefix): cache, sessions, queues and
# Horizon all sit under it. It is a setting of the application, so it is
# asked of the application — booted as the app's user, the way artisan
# boots it. Prints the prefix; nothing when it cannot be read or is empty.
_valkey_app_prefix() {
    local app="$1" php out
    php=$(app_get "$app" php)
    [[ "$php" =~ ^[0-9]\.[0-9]$ ]] || return 0
    out=$(cd / && sudo -u "$app" /bin/bash -c '
        cd "$1/current" 2>/dev/null || exit 0
        [[ -f artisan && -f vendor/autoload.php && -f bootstrap/app.php ]] || exit 0
        exec timeout 60 "/usr/bin/php$2" -r "
            require \"vendor/autoload.php\";
            \$app = require \"bootstrap/app.php\";
            \$app->make(Illuminate\\Contracts\\Console\\Kernel::class)->bootstrap();
            echo \"\\nCIPI_REDIS_PREFIX=\" . bin2hex((string) config(\"database.redis.options.prefix\")) . \"\\n\";
        "' _ "/home/${app}" "$php" 2>/dev/null < /dev/null || true)
    out=$(sed -n 's/^CIPI_REDIS_PREFIX=\([0-9a-f]*\)$/\1/p' <<< "$out" | tail -n 1)
    [[ -n "$out" ]] || return 0
    # Hex, so that whatever the prefix holds arrives as it is.
    printf '%b' "$(sed 's/../\\x&/g' <<< "$out")"
}

# Glob characters in a prefix are part of the name, not a pattern.
_valkey_glob_escape() { printf '%s' "$1" | sed 's/[][*?\\]/\\&/g'; }

# ── copy ─────────────────────────────────────────────────────
# Copies the keys that match a pattern from one instance to another, database
# by database, with their expiry (MIGRATE … COPY REPLACE: the source keeps
# them). The commands are written to valkey-cli's standard input with every
# name and the destination password hex-quoted: nothing is on a command line,
# and a key name is never read as a command. Prints the number of keys sent;
# returns 1 when a batch was refused.
_valkey_copy() {   # <src port> <src pass> <dst port> <dst pass> <pattern>
    local sp="$1" spw="$2" dp="$3" dpw="$4" pat="$5" db dbs out total=0 n rc=0 cnt
    cnt=$(mktemp) || return 1
    dbs=$(_valkey_cli "$sp" "$spw" INFO keyspace | sed -n 's/^db\([0-9]*\):keys=.*/\1/p' || true)
    for db in $dbs; do
        : > "$cnt"
        out=$(_valkey_cli "$sp" "$spw" -n "$db" --scan --pattern "$pat" \
            | CIPI_DP="$dp" CIPI_DB="$db" CIPI_DPW="$dpw" perl -e '
                my ($port, $db, $pw) = ($ENV{CIPI_DP}, $ENV{CIPI_DB}, $ENV{CIPI_DPW});
                my @k; my $n = 0;
                sub hx { my $s = shift; return "\"" . join("", map { sprintf("\\x%02x", ord) } split(//, $s)) . "\"" }
                sub send_batch { return unless @k;
                    print "MIGRATE 127.0.0.1 $port \"\" $db 60000 COPY REPLACE AUTH " . hx($pw) . " KEYS " . join(" ", map { hx($_) } @k) . "\n";
                    @k = () }
                while (<STDIN>) { chomp; next if $_ eq ""; push @k, $_; $n++; send_batch() if @k >= 100 }
                send_batch();
                print STDERR "$n\n";
              ' 2> "$cnt" \
            | _valkey_cli "$sp" "$spw" -n "$db" || true)
        n=$(tail -n 1 "$cnt" 2>/dev/null || echo 0)
        [[ "$n" =~ ^[0-9]+$ ]] || n=0
        total=$((total + n))
        # One reply per batch: OK, or NOKEY when every key of it expired
        # between the scan and the copy. Anything else is a refusal.
        if grep -qvE '^(OK|NOKEY)?$' <<< "$out"; then
            rc=1
        fi
    done
    rm -f "$cnt"
    echo "$total"
    return "$rc"
}

_valkey_dbsize() {   # <port> <password> → keys in all databases
    _valkey_cli "$1" "$2" INFO keyspace \
        | awk -F'[=,]' '/^db[0-9]+:keys=/ { n += $2 } END { print n + 0 }' || echo 0
}

# ── the app around the switch ────────────────────────────────
_valkey_artisan() {   # <app> <args…> — quiet, as the app's user; 1 when there is no artisan
    local app="$1" php; shift
    php=$(app_get "$app" php)
    [[ "$php" =~ ^[0-9]\.[0-9]$ ]] || return 1
    (cd / && sudo -u "$app" /bin/bash -c '
        cd "$1/current" 2>/dev/null || exit 1
        [[ -f artisan ]] || exit 1
        php="/usr/bin/php$2"; shift 2
        exec timeout 120 "$php" artisan "$@"' _ "/home/${app}" "$php" "$@") >/dev/null 2>&1 < /dev/null
}

_valkey_config_cached() {
    (cd / && sudo -u "$1" /bin/bash -c '[[ -f "$1/current/bootstrap/cache/config.php" ]]' _ "/home/$1") 2>/dev/null < /dev/null
}

# Every supervisor program of the app: queue workers, Horizon, Octane, Reverb
# all hold a connection, and all read REDIS_* when they start.
_valkey_workers() {   # <app> <stop|restart>
    local conf="/etc/supervisor/conf.d/${1}.conf" group
    [[ -f "$conf" ]] && command -v supervisorctl &>/dev/null || return 0
    for group in $(grep '^\[program:' "$conf" 2>/dev/null | sed 's/\[program://;s/\]//' || true); do
        supervisorctl "$2" "${group}:*" >/dev/null 2>&1 || supervisorctl "$2" "$group" >/dev/null 2>&1 || true
    done
    return 0
}

# REDIS_* in the app's .env, then whatever caches them: the config cache, the
# PHP-FPM workers (opcache may hold the cached config), the long-running
# processes.
_valkey_env_switch() {   # <app> <port> <password>
    local app="$1" env="/home/${1}/shared/.env" php
    declare -f _env_set_or_add >/dev/null || source "${CIPI_LIB}/app.sh"
    _env_set_or_add "$env" REDIS_HOST "127.0.0.1" || return 1
    _env_set_or_add "$env" REDIS_PORT "$2" || return 1
    _env_set_or_add "$env" REDIS_PASSWORD "$3" || return 1
    if _valkey_config_cached "$app"; then
        _valkey_artisan "$app" config:cache || warn "${app}: config:cache failed — run: cipi app artisan ${app} config:cache"
        php=$(app_get "$app" php)
        if [[ "$php" =~ ^[0-9]\.[0-9]$ ]]; then
            systemctl reload "php${php}-fpm" >/dev/null 2>&1 || true
        fi
    fi
    return 0
}

# Moves one app between the shared instance and its own.
#   direction "own":    create the instance, copy the app's keys into it
#   direction "shared": copy everything back, remove the instance
# The app is in maintenance mode while keys are copied, so that nothing is
# written on the side that is about to be left. A failure before the switch
# leaves the app exactly as it was.
_valkey_move() {   # <app> <own|shared> — options in ARG_*
    local app="$1" dir="$2" text target shared_pass prefix="" pattern copy=true down=false n=0
    local port pass

    app_exists "$app" || { error "App '${app}' not found"; return 1; }
    [[ "$(app_get "$app" custom)" == "true" ]] && { error "'${app}' is not a Laravel app: it has no .env for Cipi to point at an instance"; return 1; }
    id "$app" &>/dev/null || { error "User '${app}' does not exist"; return 1; }
    valkey_available || { error "valkey-server is not installed on this server"; return 1; }
    text=$(_valkey_env_text "$app")
    [[ -n "$text" ]] || { error "/home/${app}/shared/.env not found or empty"; return 1; }
    target=$(_valkey_app_target "$app" "$text")
    shared_pass=$(valkey_shared_pass)
    [[ "${ARG_no_copy:-}" == "true" ]] && copy=false

    if [[ "$dir" == "own" ]]; then
        valkey_has_instance "$app" && [[ "$target" == "own" ]] && { info "'${app}' already has its own Valkey (127.0.0.1:$(valkey_instance_port "$app"))"; return 0; }
        if [[ "$target" == "external" && "${ARG_force:-}" != "true" ]]; then
            error "'${app}': its .env points Redis somewhere else (REDIS_HOST=$(_valkey_env_get "$text" REDIS_HOST) REDIS_PORT=$(_valkey_env_get "$text" REDIS_PORT)$([[ -n "$(_valkey_env_get "$text" REDIS_URL)" ]] && echo ' REDIS_URL set')) — not the shared instance; left as it is (--force to give it one anyway, without a copy)"
            return 1
        fi
        [[ "$target" == "shared" ]] || copy=false
        [[ -n "${ARG_maxmemory:-}" ]] && { _valkey_valid_maxmemory "${ARG_maxmemory}" || { error "--maxmemory: a size such as 256mb or 1gb"; return 1; }; }
        [[ -n "${ARG_policy:-}" ]]    && { _valkey_valid_policy "${ARG_policy}" || { error "--policy: noeviction, allkeys-lru, allkeys-lfu, volatile-lru, volatile-lfu, volatile-ttl, allkeys-random or volatile-random"; return 1; }; }

        if [[ "$copy" == true ]] && [[ "$(_valkey_cli "$VALKEY_SHARED_PORT" "$shared_pass" PING || true)" != "PONG" ]]; then
            error "'${app}': the shared Valkey does not answer on 127.0.0.1:${VALKEY_SHARED_PORT} — its keys cannot be copied (start it: cipi service start valkey-server, or move without them: --no-copy)"
            return 1
        fi
        if [[ "$copy" == true ]]; then
            prefix=$(_valkey_app_prefix "$app")
            if [[ -z "$prefix" ]]; then
                warn "'${app}': its Redis key prefix could not be read (no release deployed, or an empty prefix) — its keys cannot be told from the other apps' on the shared instance"
                if [[ "${ARG_yes:-}" == "true" ]]; then
                    error "'${app}' left on the shared instance. To move it without its keys (cache, sessions and queued jobs start empty): cipi valkey isolate ${app} --no-copy"
                    return 1
                fi
                confirm "Move '${app}' to its own instance WITHOUT copying its keys? Cache and sessions start empty; queued jobs stay behind." || { info "Left as it is"; return 1; }
                copy=false
            fi
        fi

        if valkey_has_instance "$app"; then
            # An instance without the .env pointing at it: a run that stopped
            # half way. Its port and password are reused.
            port=$(valkey_instance_port "$app"); pass=$(valkey_instance_pass "$app")
            systemctl restart "$(_valkey_unit "$app")" >/dev/null 2>&1 || true
            _valkey_wait "$port" "$pass" || { error "'${app}': its instance does not answer — journalctl -u $(_valkey_unit "$app")"; return 1; }
        else
            step "${app}: starting its instance..."
            valkey_instance_create "$app" "" "" "${ARG_maxmemory:-}" "${ARG_policy:-}" \
                || { error "'${app}': could not start an instance (journalctl -u $(_valkey_unit "$app"))"; return 1; }
            port="$VALKEY_NEW_PORT"; pass="$VALKEY_NEW_PASS"
        fi

        if [[ "$copy" == true ]]; then
            step "${app}: maintenance mode, workers stopped..."
            _valkey_artisan "$app" down --retry=15 && down=true
            _valkey_workers "$app" stop
            step "${app}: copying its keys (prefix '${prefix}')..."
            pattern="$(_valkey_glob_escape "$prefix")*"
            if ! n=$(_valkey_copy "$VALKEY_SHARED_PORT" "$shared_pass" "$port" "$pass" "$pattern"); then
                error "'${app}': the copy was refused — the app is left on the shared instance"
                valkey_instance_remove "$app"
                _valkey_workers "$app" restart
                [[ "$down" == true ]] && { _valkey_artisan "$app" up || true; }
                return 1
            fi
        fi

        if ! _valkey_env_switch "$app" "$port" "$pass"; then
            error "'${app}': could not write its .env — the app is left on the shared instance"
            valkey_instance_remove "$app"
            _valkey_workers "$app" restart
            [[ "$down" == true ]] && { _valkey_artisan "$app" up || true; }
            return 1
        fi
        app_set_json "$app" valkey_port "$port"
        _valkey_workers "$app" restart
        [[ "$down" == true ]] && { _valkey_artisan "$app" up || warn "${app}: still in maintenance mode — cipi app artisan ${app} up"; }

        log_action "VALKEY ISOLATE: ${app} port=${port} keys_copied=${n}"
        cipi_notify \
            "Cipi: ${app} has its own Valkey on $(hostname)" \
            "The app now uses an instance of its own.\n\nServer: $(hostname)\nApp: ${app}\nInstance: 127.0.0.1:${port} (cipi-valkey@${app})\nKeys copied: ${n}\nTime: $(notify_now)" \
            valkey_isolate
        success "${app}: own Valkey on 127.0.0.1:${port}$([[ "$copy" == true ]] && echo " — ${n} key(s) copied")"
        return 0
    fi

    # ── back to the shared instance ──
    valkey_has_instance "$app" || { info "'${app}' has no instance of its own"; return 0; }
    [[ -n "$shared_pass" ]] || { error "No shared Valkey password on record (server.json) — nothing to go back to"; return 1; }
    [[ "$(_valkey_cli "$VALKEY_SHARED_PORT" "$shared_pass" PING || true)" == "PONG" ]] \
        || { error "The shared Valkey does not answer on 127.0.0.1:${VALKEY_SHARED_PORT}"; return 1; }
    port=$(valkey_instance_port "$app"); pass=$(valkey_instance_pass "$app")
    if [[ "$copy" == true ]] && _valkey_wait "$port" "$pass"; then
        step "${app}: maintenance mode, workers stopped..."
        _valkey_artisan "$app" down --retry=15 && down=true
        _valkey_workers "$app" stop
        step "${app}: copying its keys back..."
        if ! n=$(_valkey_copy "$port" "$pass" "$VALKEY_SHARED_PORT" "$shared_pass" '*'); then
            error "'${app}': the copy was refused — the app keeps its own instance"
            _valkey_workers "$app" restart
            [[ "$down" == true ]] && { _valkey_artisan "$app" up || true; }
            return 1
        fi
    fi
    if ! _valkey_env_switch "$app" "$VALKEY_SHARED_PORT" "$shared_pass"; then
        error "'${app}': could not write its .env — the app keeps its own instance"
        _valkey_workers "$app" restart
        [[ "$down" == true ]] && { _valkey_artisan "$app" up || true; }
        return 1
    fi
    app_unset "$app" valkey_port
    _valkey_workers "$app" restart
    [[ "$down" == true ]] && { _valkey_artisan "$app" up || warn "${app}: still in maintenance mode — cipi app artisan ${app} up"; }
    valkey_instance_remove "$app"
    log_action "VALKEY SHARE: ${app} keys_copied=${n}"
    cipi_notify \
        "Cipi: ${app} is back on the shared Valkey on $(hostname)" \
        "The app's own instance was removed.\n\nServer: $(hostname)\nApp: ${app}\nKeys copied back: ${n}\nTime: $(notify_now)" \
        valkey_isolate
    success "${app}: back on the shared Valkey (127.0.0.1:${VALKEY_SHARED_PORT})"
}

_valkey_isolate_cmd() {
    local app="" a
    for a in "$@"; do [[ "$a" == --* ]] || { app="$a"; break; }; done
    parse_args "$@"
    local rc=0
    if [[ "${ARG_all:-}" == "true" ]]; then
        local list failed="" done_n=0
        list=$(valkey_shared_apps)
        if [[ -z "$list" ]]; then
            info "No app uses the shared Valkey"
            return 0
        fi
        echo -e "\n  Apps on the shared instance: ${CYAN}$(paste -sd' ' - <<< "$list")${NC}"
        echo -e "  ${DIM}Each one goes into maintenance mode for the seconds its keys take to copy.${NC}\n"
        if [[ "${ARG_yes:-}" != "true" ]]; then
            confirm "Give each of them its own Valkey instance?" || { info "Aborted"; return 0; }
            # Asked once: what follows runs without further questions, and an
            # app whose prefix cannot be read is reported, not moved empty.
            ARG_yes=true
        fi
        while IFS= read -r a; do
            [[ -n "$a" ]] || continue
            if ( _valkey_move "$a" own ); then done_n=$((done_n + 1)); else failed="${failed} ${a}"; fi
        done <<< "$list"
        echo ""
        success "${done_n} app(s) moved to their own instance"
        if [[ -n "$failed" ]]; then
            warn "Left on the shared instance:${failed} — see above"
            rc=1
        elif [[ -z "$(valkey_shared_apps)" ]]; then
            info "No app uses the shared instance any more. It still holds the old keys, and every app has seen its password:"
            echo -e "    ${CYAN}cipi valkey flush-shared${NC}  ${DIM}(empties it and changes its password)${NC}"
        fi
    else
        [[ -n "$app" ]] || { error "Usage: cipi valkey isolate <app>|--all [--no-copy] [--maxmemory=256mb] [--policy=allkeys-lru] [--yes]"; return 1; }
        if [[ "${ARG_yes:-}" != "true" && "${ARG_no_copy:-}" != "true" ]]; then
            echo -e "  ${DIM}'${app}' goes into maintenance mode for the seconds its keys take to copy; its workers are restarted.${NC}"
            confirm "Give '${app}' its own Valkey instance?" || { info "Aborted"; return 0; }
        fi
        _valkey_move "$app" own || rc=1
    fi
    return "$rc"
}

_valkey_share_cmd() {
    local app="" a rc=0
    for a in "$@"; do [[ "$a" == --* ]] || { app="$a"; break; }; done
    parse_args "$@"
    [[ -n "$app" ]] || { error "Usage: cipi valkey share <app> [--no-copy] [--yes]"; return 1; }
    if [[ "${ARG_yes:-}" != "true" ]]; then
        warn "On the shared instance every other app can read and write this app's cache, sessions and queues."
        confirm "Move '${app}' back to the shared Valkey and remove its instance?" || { info "Aborted"; return 0; }
    fi
    _valkey_move "$app" shared || rc=1
    return "$rc"
}

_valkey_restart_cmd() {
    local app="${1:-}"
    valkey_has_instance "$app" || { error "Usage: cipi valkey restart <app>  (an app with its own instance — cipi valkey list)"; return 1; }
    systemctl restart "$(_valkey_unit "$app")" || { error "Restart failed — journalctl -u $(_valkey_unit "$app")"; return 1; }
    if _valkey_wait "$(valkey_instance_port "$app")" "$(valkey_instance_pass "$app")"; then
        success "$(_valkey_unit "$app") restarted"
    else
        error "$(_valkey_unit "$app") does not answer — journalctl -u $(_valkey_unit "$app")"
        return 1
    fi
}

# Empties the shared instance and changes its password: what is left there
# after the apps moved out is their old cache, sessions and jobs, readable by
# whoever still has the password every app was given.
_valkey_flush_shared_cmd() {
    parse_args "$@"
    local pass users
    pass=$(valkey_shared_pass)
    [[ -n "$pass" ]] || { error "No shared Valkey password on record"; return 1; }
    users=$(valkey_shared_apps | paste -sd' ' -)
    if [[ -n "$users" && "${ARG_force:-}" != "true" ]]; then
        error "Still in use by: ${users} — move them first (cipi valkey isolate --all), or --force"
        return 1
    fi
    if [[ "${ARG_yes:-}" != "true" ]]; then
        confirm "Delete every key in the shared Valkey (127.0.0.1:${VALKEY_SHARED_PORT}) and change its password?" || { info "Aborted"; return 0; }
    fi
    [[ "$(_valkey_cli "$VALKEY_SHARED_PORT" "$pass" FLUSHALL || true)" == "OK" ]] \
        || { error "FLUSHALL was refused — is valkey-server running?"; return 1; }
    log_action "VALKEY SHARED FLUSHED"
    success "Shared Valkey emptied"
    # shellcheck source=/dev/null
    source "${CIPI_LIB}/reset.sh"
    reset_valkey_password
}

# ── cipi sync ────────────────────────────────────────────────
# An app imported as new on this server. Its .env comes from the server it
# left, and so do its REDIS_* lines:
#   - it had its own instance there (valkey_port in apps.json): it gets one
#     here with the same port and password when the port is free, so the
#     .env stays as it is; otherwise on a new port, and the .env follows;
#   - it used that server's shared instance: the password in its .env is
#     that server's, good for nothing here. It gets its own instance, like
#     any app created on this server.
# Where no instance can be started the app is put on this server's shared
# one, which is what an import did before 5.9.0. An .env that points Redis
# at another host, or through REDIS_URL, is not touched.
valkey_sync_adopt() {   # <app>
    local app="${1:-}" text host eport epass port pass want_port="" want_pass="" shared
    _valkey_app_ok "$app" || return 0
    id "$app" &>/dev/null || return 0
    text=$(_valkey_env_text "$app")
    [[ -n "$text" ]] || return 0
    host=$(_valkey_env_get "$text" REDIS_HOST); eport=$(_valkey_env_get "$text" REDIS_PORT)
    epass=$(_valkey_env_get "$text" REDIS_PASSWORD)
    if valkey_has_instance "$app"; then
        port=$(valkey_instance_port "$app"); pass=$(valkey_instance_pass "$app")
    else
        [[ -z "$(_valkey_env_get "$text" REDIS_URL)" ]] || return 0
        case "$host" in ""|127.0.0.1|localhost|::1) ;; *) return 0 ;; esac
        if [[ -n "$(app_get "$app" valkey_port)" ]]; then
            want_port="$eport"; want_pass="$epass"
        elif [[ -z "$epass" || ( -n "$eport" && "$eport" != "$VALKEY_SHARED_PORT" ) ]]; then
            return 0
        fi
        valkey_available || { app_unset "$app" valkey_port; return 0; }
        if ! valkey_instance_create "$app" "$want_port" "$want_pass"; then
            app_unset "$app" valkey_port
            shared=$(valkey_shared_pass)
            if [[ -n "$shared" ]]; then
                _valkey_env_switch "$app" "$VALKEY_SHARED_PORT" "$shared" || true
                warn "${app}: a Valkey instance of its own could not be started — it is on the shared one (later: cipi valkey isolate ${app})"
            else
                warn "${app}: a Valkey instance of its own could not be started, and its .env names one that is not on this server"
            fi
            return 1
        fi
        port="$VALKEY_NEW_PORT"; pass="$VALKEY_NEW_PASS"
    fi
    app_set_json "$app" valkey_port "$port"
    if [[ "$eport" != "$port" || "$epass" != "$pass" || "$host" != "127.0.0.1" ]]; then
        _valkey_env_switch "$app" "$port" "$pass" || warn "${app}: could not point its .env at 127.0.0.1:${port}"
    fi
    return 0
}

# An app that was here before the import: its Valkey is this server's
# business. apps.json came from the other server, so valkey_port is put back
# to what is true here; and an instance that exists keeps the .env.
valkey_sync_keep() {   # <app>
    local app="${1:-}" text port pass
    _valkey_app_ok "$app" || return 0
    if valkey_has_instance "$app"; then
        port=$(valkey_instance_port "$app"); pass=$(valkey_instance_pass "$app")
        app_set_json "$app" valkey_port "$port"
        text=$(_valkey_env_text "$app")
        if [[ "$(_valkey_env_get "$text" REDIS_PORT)" != "$port" || "$(_valkey_env_get "$text" REDIS_PASSWORD)" != "$pass" ]]; then
            _valkey_env_switch "$app" "$port" "$pass" || warn "${app}: could not point its .env at 127.0.0.1:${port}"
        fi
    elif [[ -n "$(app_get "$app" valkey_port)" ]]; then
        app_unset "$app" valkey_port
    fi
    return 0
}

_valkey_list() {
    parse_args "$@"
    local app target port state mem keys rows="[]" unit
    while IFS= read -r app; do
        [[ -n "$app" ]] || continue
        id "$app" &>/dev/null || continue
        target=$(_valkey_app_target "$app")
        port=""; state=""; mem=""; keys=""
        if valkey_has_instance "$app"; then
            port=$(valkey_instance_port "$app")
            unit=$(_valkey_unit "$app")
            if systemctl is-active --quiet "$unit" 2>/dev/null; then state="running"; else state="stopped"; fi
            if [[ "$state" == "running" ]]; then
                mem=$(_valkey_cli "$port" "$(valkey_instance_pass "$app")" INFO memory | awk -F: '$1 == "used_memory_human" { gsub(/\r/, "", $2); print $2 }' || true)
                keys=$(_valkey_dbsize "$port" "$(valkey_instance_pass "$app")")
            fi
        fi
        rows=$(jq -c --arg a "$app" --arg t "$target" --arg p "$port" --arg s "$state" --arg m "$mem" --arg k "$keys" \
            '. + [{app: $a, uses: $t, port: (if $p == "" then null else ($p | tonumber) end),
                   instance: (if $s == "" then null else $s end), memory: (if $m == "" then null else $m end),
                   keys: (if $k == "" then null else ($k | tonumber) end)}]' <<< "$rows")
    done < <(_valkey_laravel_apps)

    if [[ "${ARG_json:-}" == "true" ]]; then
        jq '{shared_port: '"$VALKEY_SHARED_PORT"', apps: .}' <<< "$rows"
        return 0
    fi

    echo -e "\n${BOLD}Valkey${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    if [[ "$(jq 'length' <<< "$rows")" -eq 0 ]]; then
        echo -e "  ${DIM}No Laravel app${NC}\n"
        return 0
    fi
    printf "  ${DIM}%-18s %-10s %-18s %-9s %-9s %s${NC}\n" "APP" "USES" "INSTANCE" "STATE" "MEMORY" "KEYS"
    local line col
    while IFS=$'\t' read -r app target port state mem keys; do
        case "$target" in
            own)      col="$GREEN" ;;
            shared)   col="$YELLOW" ;;
            *)        col="$DIM" ;;
        esac
        printf "  %-18s ${col}%-10s${NC} %-18s %-9s %-9s %s\n" "$app" "$target" \
            "$([[ "$port" != "-" ]] && echo "127.0.0.1:${port}" || echo "-")" "$state" "$mem" "$keys"
    done < <(jq -r '.[] | [.app, .uses, (.port // "-" | tostring), (.instance // "-"), (.memory // "-"), (.keys // "-" | tostring)] | @tsv' <<< "$rows")
    echo ""
    if jq -e 'any(.[]; .uses == "shared")' <<< "$rows" >/dev/null; then
        echo -e "  ${YELLOW}shared${NC}: the app has the password of the server's Valkey (127.0.0.1:${VALKEY_SHARED_PORT}), like every other app on it."
        echo -e "  ${CYAN}cipi valkey isolate <app>${NC}   ${CYAN}cipi valkey isolate --all${NC}"
        echo ""
    fi
}

valkey_command() {
    local sub="${1:-list}"; shift || true
    # _env_set_or_add and friends.
    declare -f _env_set_or_add >/dev/null || source "${CIPI_LIB}/app.sh"
    case "$sub" in
        list|ls|status|"") _valkey_list "$@" ;;
        isolate|own)       _valkey_isolate_cmd "$@" ;;
        share|shared)      _valkey_share_cmd "$@" ;;
        restart)           _valkey_restart_cmd "$@" ;;
        flush-shared)      _valkey_flush_shared_cmd "$@" ;;
        *) error "Use: cipi valkey list | isolate <app>|--all | share <app> | restart <app> | flush-shared"; return 1 ;;
    esac
}
