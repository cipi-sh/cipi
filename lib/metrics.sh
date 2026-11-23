#!/bin/bash
#############################################
# Cipi — Metrics & health history (5.11.0)
#
# `cipi health` and `cipi monitor` already say *that* something is wrong, and
# alert when it happens. Neither keeps a past: a 5xx spike at 03:10, an app
# whose memory crept up for a week, the uptime of last month. This keeps one.
#
#   collector   /usr/local/bin/cipi-metrics, every minute (/etc/cron.d/cipi-metrics),
#               as root. One pass: host CPU, memory, swap, disk, load, network;
#               per app CPU, memory (RSS), PHP-FPM children and "max_children
#               reached", requests and 5xx per minute (its nginx access log),
#               queue workers up, and the healthcheck URL — status and time.
#   storage     SQLite, /var/lib/cipi-metrics/metrics.db (root, 0600), "wide" tables —
#               one row per scope (host, app:<name>) and time, one column per metric:
#                 samples  every minute, kept raw_days (7)
#                 rollups  avg and max per resolution_minutes (15), kept rollup_days (30)
#                 events   monitor / health / deploy / heartbeat transitions, kept events_days (90)
#               About 2 MB per app per week of raw data, a third of that per month of
#               rollups: 20–30 MB for a server with ten apps on the defaults.
#   heartbeat   optional: the collector calls a URL every N minutes (healthchecks.io,
#               Uptime Kuma, Boogle, …). When the server is down the calls stop,
#               and the receiver alerts: the one failure a server cannot report itself.
#   openmetrics optional, off: /metrics on its own port for an existing
#               Prometheus, behind an IP allowlist and a bearer token.
#
# Alerts stay where they were (cipi monitor, cipi health): this records, it does
# not page. Nothing here listens on a port unless `cipi metrics openmetrics on`.
#############################################

[[ -z "${METRICS_DIR:-}" ]]    && readonly METRICS_DIR="/var/lib/cipi-metrics"
[[ -z "${METRICS_DB:-}" ]]     && readonly METRICS_DB="${METRICS_DIR}/metrics.db"
[[ -z "${METRICS_STATE:-}" ]]  && readonly METRICS_STATE="${METRICS_DIR}/state"
[[ -z "${METRICS_PROM:-}" ]]   && readonly METRICS_PROM="${METRICS_DIR}/metrics.prom"
[[ -z "${METRICS_CRON:-}" ]]   && readonly METRICS_CRON="/etc/cron.d/cipi-metrics"
[[ -z "${METRICS_HELPER:-}" ]] && readonly METRICS_HELPER="/usr/local/bin/cipi-metrics"
[[ -z "${METRICS_NGINX:-}" ]]  && readonly METRICS_NGINX="/etc/nginx/conf.d/cipi-metrics.conf"
[[ -z "${METRICS_PROC:-}" ]]   && readonly METRICS_PROC="/proc"
[[ -z "${METRICS_APP_LOGS:-}" ]] && readonly METRICS_APP_LOGS="/var/log/cipi-apps"
[[ -z "${METRICS_FPM_POOLS:-}" ]] && readonly METRICS_FPM_POOLS="/etc/php"

# Metrics per scope, in display order. Units: cpu %, mem % (host) or MB (app),
# net bytes/s, req and 5xx per minute, http_ms milliseconds, http_ok 1|0.
[[ -z "${METRICS_HOST_LIST:-}" ]] && readonly METRICS_HOST_LIST="cpu load1 mem mem_used_mb swap disk net_rx net_tx"
[[ -z "${METRICS_APP_LIST:-}" ]] && readonly METRICS_APP_LIST="cpu mem_mb procs fpm_procs fpm_max fpm_saturated req http_5xx http_ms http_ok http_code workers_up workers_total"
# Every column of samples / rollups. A name added here in a later version is
# added to an existing database by _met_db_init (ALTER TABLE … ADD COLUMN).
[[ -z "${METRICS_COLUMNS:-}" ]] && readonly METRICS_COLUMNS="cpu load1 mem mem_used_mb swap disk net_rx net_tx mem_mb procs fpm_procs fpm_max fpm_saturated req http_5xx http_ms http_ok http_code workers_up workers_total"

# ── Configuration ──────────────────────────────────────────────

_met_default_config() {
    jq -n '{
        enabled: true,
        probe: true,
        retention: {raw_days: 7, rollup_days: 30, resolution_minutes: 15, events_days: 90},
        heartbeat: {enabled: false, url: "", every: 1},
        openmetrics: {enabled: false, port: 9273, allow: [], token: ""}
    }'
}

# The stored file merged over the defaults: a key a later version adds has a
# value on a server that has never written it.
_met_cfg() {
    # The collector reads it once per run (it is decrypted from the vault).
    if [[ -n "${_MET_CFG_CACHE:-}" ]]; then printf '%s\n' "$_MET_CFG_CACHE"; return 0; fi
    local stored
    stored=$(vault_read metrics.json 2>/dev/null) || stored='{}'
    jq -e 'type == "object"' >/dev/null 2>&1 <<< "$stored" || stored='{}'
    jq -c -n --argjson d "$(_met_default_config)" --argjson s "$stored" '$d * $s'
}

_met_cfg_write() {
    local json="$1"
    jq -e 'type == "object"' >/dev/null 2>&1 <<< "$json" || { error "metrics: refusing to write an invalid configuration"; return 1; }
    _MET_CFG_CACHE=""
    printf '%s\n' "$json" | vault_write metrics.json
}

_met_cfg_get() {   # <jq path> <default>
    local v
    v=$(_met_cfg | jq -r "${1} // empty" 2>/dev/null)
    [[ -n "$v" ]] && echo "$v" || echo "${2:-}"
}

# Retention values, validated: a hand-edited file cannot make the collector
# delete everything (raw_days 0) or keep forever.
_met_retention() {   # → "raw_days rollup_days resolution_minutes events_days"
    local cfg raw roll res ev
    cfg=$(_met_cfg)
    raw=$(jq -r '.retention.raw_days' <<< "$cfg");            [[ "$raw" =~ ^[0-9]+$ ]] && (( raw >= 1 && raw <= 90 )) || raw=7
    roll=$(jq -r '.retention.rollup_days' <<< "$cfg");        [[ "$roll" =~ ^[0-9]+$ ]] && (( roll >= raw && roll <= 400 )) || roll=$(( raw > 30 ? raw : 30 ))
    res=$(jq -r '.retention.resolution_minutes' <<< "$cfg");  [[ "$res" =~ ^(5|10|15|30|60)$ ]] || res=15
    ev=$(jq -r '.retention.events_days' <<< "$cfg");          [[ "$ev" =~ ^[0-9]+$ ]] && (( ev >= 7 && ev <= 730 )) || ev=90
    echo "$raw $roll $res $ev"
}

# ── Storage ────────────────────────────────────────────────────

_met_have_sqlite() { command -v sqlite3 >/dev/null 2>&1; }

_met_sql() {   # stdin: SQL
    sqlite3 -batch -bail -cmd '.timeout 5000' "$METRICS_DB" 2>/dev/null
}

_met_sql_json() {   # <sql> → JSON array ([] when no row)
    local out
    out=$(sqlite3 -batch -json -cmd '.timeout 5000' "$METRICS_DB" "$1" 2>/dev/null) || out=""
    [[ -n "$out" ]] && printf '%s\n' "$out" || echo '[]'
}

_met_sql_val() {   # <sql> → first column of the first row
    sqlite3 -batch -noheader -cmd '.timeout 5000' "$METRICS_DB" "$1" 2>/dev/null | head -1
}

_met_q() { local s="${1//\'/\'\'}"; printf "'%s'" "$s"; }   # SQL string literal

_met_db_init() {
    _met_have_sqlite || return 1
    if [[ ! -d "$METRICS_DIR" ]]; then
        install -d -m 750 -o root -g www-data "$METRICS_DIR" 2>/dev/null \
            || mkdir -p "$METRICS_DIR" 2>/dev/null || return 1
    fi
    mkdir -p "$METRICS_STATE" 2>/dev/null && chmod 700 "$METRICS_STATE" 2>/dev/null
    # auto_vacuum only takes effect on a database without tables, i.e. the
    # first time: the hourly prune then gives freed pages back to the disk.
    (umask 077; _met_sql <<'SQL'
PRAGMA auto_vacuum = INCREMENTAL;
PRAGMA journal_mode = WAL;
CREATE TABLE IF NOT EXISTS samples (scope TEXT NOT NULL, ts INTEGER NOT NULL, PRIMARY KEY (scope, ts)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS rollups (scope TEXT NOT NULL, ts INTEGER NOT NULL, n INTEGER NOT NULL, ok_n INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (scope, ts)) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS events (ts INTEGER NOT NULL, source TEXT NOT NULL, subject TEXT NOT NULL,
    status TEXT NOT NULL, summary TEXT NOT NULL DEFAULT '');
CREATE INDEX IF NOT EXISTS events_ts ON events (ts);
CREATE INDEX IF NOT EXISTS events_subject ON events (subject, ts);
CREATE TABLE IF NOT EXISTS meta (k TEXT PRIMARY KEY, v TEXT) WITHOUT ROWID;
SQL
    ) || return 1
    chmod 600 "$METRICS_DB" 2>/dev/null || true
    # One column per metric; the ones this version knows and the database not yet.
    local have_s have_r c add=""
    have_s=" $(_met_sql_json "SELECT name FROM pragma_table_info('samples');" | jq -r 'map(.name) | join(" ")') "
    have_r=" $(_met_sql_json "SELECT name FROM pragma_table_info('rollups');" | jq -r 'map(.name) | join(" ")') "
    for c in $METRICS_COLUMNS; do
        [[ "$have_s" == *" ${c} "* ]] || add+="ALTER TABLE samples ADD COLUMN ${c} REAL;"$'\n'
        [[ "$have_r" == *" ${c}_avg "* ]] || add+="ALTER TABLE rollups ADD COLUMN ${c}_avg REAL;"$'\n'
        [[ "$have_r" == *" ${c}_max "* ]] || add+="ALTER TABLE rollups ADD COLUMN ${c}_max REAL;"$'\n'
    done
    if [[ -n "$add" ]]; then
        printf 'BEGIN;\n%sCOMMIT;\n' "$add" | _met_sql >/dev/null || return 1
    fi
    return 0
}

_met_meta_get() { _met_sql_val "SELECT v FROM meta WHERE k = $(_met_q "$1");"; }
_met_meta_set_sql() { printf "INSERT INTO meta (k, v) VALUES (%s, %s) ON CONFLICT(k) DO UPDATE SET v = excluded.v;\n" "$(_met_q "$1")" "$(_met_q "$2")"; }

# metrics_event <source> <subject> <status> [summary]
# Called by monitor.sh, health.sh, deploy and the collector on a transition.
# Silent and harmless when there is no database (metrics never set up, sqlite3
# missing): a failure to record must never fail what is being recorded.
metrics_event() {
    local source="${1:-}" subject="${2:-}" status="${3:-}" summary="${4:-}"
    [[ -n "$source" && -n "$subject" && -n "$status" ]] || return 0
    _met_have_sqlite || return 0
    [[ -f "$METRICS_DB" ]] || return 0
    summary="${summary:0:500}"
    printf "INSERT INTO events (ts, source, subject, status, summary) VALUES (%s, %s, %s, %s, %s);\n" \
        "$(date +%s)" "$(_met_q "$source")" "$(_met_q "$subject")" "$(_met_q "$status")" "$(_met_q "$summary")" \
        | _met_sql >/dev/null 2>&1 || true
    return 0
}

# ── Collector ──────────────────────────────────────────────────

# Fields joined by \x1f, not tabs: `read` folds consecutive tabs (an app with
# no octane) into one, and every later field would shift left.
_met_apps_tsv() {   # app \x1f health_url \t suspended \t octane \t php \t health_expect
    vault_read apps.json 2>/dev/null | jq -r 'to_entries[] | select(.key | test("^[a-z][a-z0-9]{2,31}$")) |
        [.key, (.value.health_url // ""), (.value.suspended // "false" | tostring),
         (.value.octane // ""), (.value.php // ""), (.value.health_expect // "200" | tostring)] | join("\u001f")' 2>/dev/null
}

_met_num() { [[ "${1:-}" =~ ^-?[0-9]+(\.[0-9]+)?$ ]]; }

# Host CPU busy % since the previous run, from /proc/stat.
_met_host_cpu() {
    local line total idle prev ptotal pidle
    line=$(head -1 "${METRICS_PROC}/stat" 2>/dev/null) || return 1
    read -r total idle < <(awk '{t=0; for(i=2;i<=9;i++) t+=$i; print t, $5+$6}' <<< "$line")
    prev=$(cat "${METRICS_STATE}/host.cpu" 2>/dev/null || true)
    echo "$total $idle" > "${METRICS_STATE}/host.cpu"
    read -r ptotal pidle <<< "$prev"
    _met_num "$ptotal" && _met_num "$pidle" || return 1
    awk -v t="$total" -v i="$idle" -v pt="$ptotal" -v pi="$pidle" \
        'BEGIN{dt=t-pt; di=i-pi; if (dt<=0) exit 1; v=(1-di/dt)*100; if(v<0)v=0; if(v>100)v=100; printf "%.2f", v}'
}

# Bytes/s received and sent on every interface but lo, since the previous run.
_met_host_net() {   # <now> → "rx tx"
    local now="$1" rx tx prev pts prx ptx
    read -r rx tx < <(awk -F'[: ]+' 'NR>2 { sub(/^ +/,""); split($0,a,/[: ]+/); if (a[1]=="lo") next; r+=a[2]; t+=a[10] } END {printf "%.0f %.0f\n", r, t}' "${METRICS_PROC}/net/dev" 2>/dev/null)
    prev=$(cat "${METRICS_STATE}/host.net" 2>/dev/null || true)
    echo "$now $rx $tx" > "${METRICS_STATE}/host.net"
    read -r pts prx ptx <<< "$prev"
    _met_num "$pts" && _met_num "$prx" && _met_num "$ptx" || return 1
    awk -v n="$now" -v r="$rx" -v t="$tx" -v pn="$pts" -v pr="$prx" -v pt="$ptx" \
        'BEGIN{d=n-pn; if (d<=0) exit 1; a=(r-pr)/d; b=(t-pt)/d; if(a<0)a=0; if(b<0)b=0; printf "%.0f %.0f\n", a, b}'
}

# Per app user: CPU % of one core since the previous run, RSS in MB, process
# count, PHP-FPM children. CPU is the sum of the ticks each process gained,
# tracked per PID: a process that started since the last run counts in full,
# one that ended stops counting. (ps %cpu is a lifetime average — useless here.)
_met_app_procs() {   # <space separated app users> → lines "app cpu% mem_mb procs fpm"
    local users="$1" hz up prevup prevfile newfile
    hz=$(getconf CLK_TCK 2>/dev/null || echo 100)
    up=$(cut -d' ' -f1 "${METRICS_PROC}/uptime" 2>/dev/null || echo 0)
    prevfile="${METRICS_STATE}/procs.ticks"
    newfile="${METRICS_STATE}/procs.ticks.new"
    prevup=$(head -1 "$prevfile" 2>/dev/null | awk '$1=="#up"{print $2}')
    [[ -f "$prevfile" ]] || : > "$prevfile"
    ps -e -o pid=,user:64=,rss= 2>/dev/null | awk -v hz="$hz" -v up="$up" -v prevup="${prevup:-0}" \
        -v users="$users" -v out="$newfile" -v proc="$METRICS_PROC" '
        BEGIN {
            n = split(users, U, " "); for (i = 1; i <= n; i++) want[U[i]] = 1
            while ((getline l < ARGV[1]) > 0) { split(l, p, " "); if (p[1] != "#up") prev[p[1]] = p[2] }
            close(ARGV[1]); ARGV[1] = ""
            print "#up " up > out
        }
        {
            pid = $1; user = $2; rss = $3
            if (!(user in want)) next
            f = proc "/" pid "/stat"
            if ((getline line < f) <= 0) { close(f); next }
            close(f)
            lp = 0; for (i = length(line); i > 0; i--) if (substr(line, i, 1) == ")") { lp = i; break }
            if (!lp) next
            comm = substr(line, index(line, "(") + 1, lp - index(line, "(") - 1)
            split(substr(line, lp + 2), F, " ")
            ticks = F[12] + F[13]; start = F[20]
            if (pid in prev) d = ticks - prev[pid]
            else if (prevup > 0 && start >= prevup * hz) d = ticks
            else d = 0
            if (d < 0) d = 0
            cpu[user] += d; mem[user] += rss; procs[user]++
            if (comm ~ /^php-fpm/) fpm[user]++
            print pid, ticks > out
        }
        END {
            el = up - prevup
            for (u in want) {
                c = (prevup > 0 && el > 0) ? (cpu[u] / hz) / el * 100 : -1
                printf "%s %.2f %.1f %d %d\n", u, c, mem[u] / 1024, procs[u] + 0, fpm[u] + 0
            }
        }' "$prevfile"
    mv -f "$newfile" "$prevfile" 2>/dev/null || true
}

# New bytes of a log since the previous run, through a callback. The offset is
# kept with the inode: after logrotate the new file is read from its start.
_met_log_tail() {   # <file> <state key> → new content on stdout (at most 64 MB)
    local file="$1" key="$2" sf ino size pino="" poff=0
    sf="${METRICS_STATE}/log.${key}"
    [[ -f "$file" ]] || return 0
    ino=$(stat -c '%i' "$file" 2>/dev/null) || return 0
    size=$(stat -c '%s' "$file" 2>/dev/null) || return 0
    [[ -f "$sf" ]] && read -r pino poff < "$sf"
    echo "$ino $size" > "$sf"
    # First sight of the file: start from now, not from a year of history.
    [[ -n "${pino:-}" ]] || return 0
    _met_num "$poff" || poff=0
    if [[ "$pino" != "$ino" || "$size" -lt "$poff" ]]; then poff=0; fi
    (( size > poff )) || return 0
    tail -c +"$(( poff + 1 ))" "$file" 2>/dev/null | head -c "$(( size - poff < 67108864 ? size - poff : 67108864 ))"
}

# requests and 5xx in a chunk of nginx "combined" log.
_met_count_requests() {
    awk '{ n++; if (match($0, /" [0-9][0-9][0-9] /)) { s = substr($0, RSTART + 2, 3) + 0; if (s >= 500) e++ } } END { printf "%d %d\n", n, e }'
}

# "app count" for every pool that hit pm.max_children since the previous run.
_met_fpm_saturation() {
    local f v
    for f in /var/log/php*-fpm.log; do
        [[ -f "$f" ]] || continue
        v=$(basename "$f" .log); v="${v//[^a-z0-9.]/_}"
        _met_log_tail "$f" "fpm.${v}"
    done | awk 'match($0, /\[pool [a-z][a-z0-9]*\] server reached (pm\.)?max_children/) { s = substr($0, RSTART + 6); sub(/\].*/, "", s); c[s]++ } END { for (p in c) print p, c[p] }'
}

_met_fpm_max() {   # <app> <php> → pm.max_children of its pool, empty when none
    local app="$1" php="$2" f
    for f in "${METRICS_FPM_POOLS}/${php}/fpm/pool.d/${app}.conf" "${METRICS_FPM_POOLS}"/*/fpm/pool.d/"${app}".conf; do
        [[ -f "$f" ]] || continue
        awk -F= '/^[[:space:]]*pm\.max_children[[:space:]]*=/ { gsub(/[^0-9]/, "", $2); print $2; exit }' "$f"
        return 0
    done
}

# "app up total" from Supervisor, for the queue worker programs.
_met_workers() {
    command -v supervisorctl >/dev/null 2>&1 || return 0
    timeout 10 supervisorctl status 2>/dev/null | awk '{
        name = $1; sub(/:.*/, "", name)
        if (match(name, /-worker-/)) { app = substr(name, 1, RSTART - 1); t[app]++; if ($2 == "RUNNING") u[app]++ }
    } END { for (a in t) print a, u[a] + 0, t[a] }'
}

# The healthcheck URL of every app that has one, in parallel: one slow app
# must not delay the others (10 s each at most, 8 at a time).
_met_probe_all() {   # stdin: "app url" lines → "app code ms"
    local dir; dir=$(mktemp -d 2>/dev/null) || return 0
    local app url n=0
    while read -r app url; do
        [[ -n "$app" && -n "$url" ]] || continue
        ( r=$(curl -sS -o /dev/null -w '%{http_code} %{time_total}' --connect-timeout 5 --max-time 10 -L "$url" 2>/dev/null) || true
          read -r code t <<< "$r"
          [[ "$code" =~ ^[0-9]{3}$ ]] || code=000
          _met_num "$t" || t=0
          printf '%s %s %.0f\n' "$app" "$code" "$(awk -v t="$t" 'BEGIN{print t*1000}')" > "${dir}/${app}" ) &
        n=$(( n + 1 ))
        (( n % 8 == 0 )) && wait
    done
    wait
    cat "$dir"/* 2>/dev/null
    rm -rf "$dir"
}

# Consecutive-failure bookkeeping of the probe, the same debounce as the
# 5-minute healthcheck: an incident opens at the third failure in a row and
# closes at the first success. Returns SQL for the events table.
_met_probe_transition() {   # <app> <ok 1|0> <code> <url> <ts>
    local app="$1" ok="$2" code="$3" url="$4" ts="$5" sf fails=0 down=0 since=0
    sf="${METRICS_STATE}/probe.${app}"
    [[ -f "$sf" ]] && read -r fails down since < "$sf"
    _met_num "$fails" || fails=0; [[ "$down" == 1 ]] || down=0; _met_num "$since" || since=0
    if [[ "$ok" == 1 ]]; then
        if [[ "$down" == 1 ]]; then
            local mins=$(( (ts - since) / 60 ))
            printf "INSERT INTO events (ts, source, subject, status, summary) VALUES (%s, 'health', %s, 'ok', %s);\n" \
                "$ts" "$(_met_q "$app")" "$(_met_q "back up — HTTP ${code} (down ~${mins} min)")"
        fi
        echo "0 0 0" > "$sf"
        return 0
    fi
    fails=$(( fails + 1 ))
    if (( fails == 1 )); then since=$ts; fi
    if [[ "$down" == 0 && "$fails" -ge 3 ]]; then
        down=1
        printf "INSERT INTO events (ts, source, subject, status, summary) VALUES (%s, 'health', %s, 'crit', %s);\n" \
            "$since" "$(_met_q "$app")" "$(_met_q "down — HTTP ${code} from ${url} (3 checks in a row)")"
    fi
    echo "$fails $down $since" > "$sf"
}

# Heartbeat: an outbound call every `every` minutes. A failed call is recorded
# once (and once when it works again); it does not alert — the receiver does.
_met_heartbeat() {   # <ts> → SQL
    local ts="$1" cfg url every code ok prev
    cfg=$(_met_cfg)
    [[ "$(jq -r '.heartbeat.enabled' <<< "$cfg")" == "true" ]] || return 0
    url=$(jq -r '.heartbeat.url // ""' <<< "$cfg")
    [[ "$url" =~ ^https?:// ]] || return 0
    every=$(jq -r '.heartbeat.every // 1' <<< "$cfg"); [[ "$every" =~ ^[0-9]+$ ]] && (( every >= 1 && every <= 60 )) || every=1
    (( (ts / 60) % every == 0 )) || return 0
    code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 --retry 2 --retry-delay 2 "$url" 2>/dev/null) || true
    [[ "$code" =~ ^[0-9]{3}$ ]] || code=000
    ok=0; [[ "$code" =~ ^2 ]] && ok=1
    prev=$(_met_meta_get hb_ok)
    _met_meta_set_sql hb_ts "$ts"
    _met_meta_set_sql hb_ok "$ok"
    _met_meta_set_sql hb_code "$code"
    if [[ "$ok" == 0 && "$prev" != 0 ]]; then
        printf "INSERT INTO events (ts, source, subject, status, summary) VALUES (%s, 'heartbeat', 'server', 'warn', %s);\n" \
            "$ts" "$(_met_q "heartbeat call failed — HTTP ${code} from $(_met_url_host "$url")")"
    elif [[ "$ok" == 1 && "$prev" == 0 ]]; then
        printf "INSERT INTO events (ts, source, subject, status, summary) VALUES (%s, 'heartbeat', 'server', 'ok', 'heartbeat calls work again');\n" "$ts"
    fi
}

_met_url_host() { local u="${1#*://}"; u="${u%%/*}"; u="${u##*@}"; echo "${u%%\?*}"; }

# Rollups for every bucket that is complete and not rolled yet, then — once an
# hour — the prune. Returns SQL.
_met_rollup_prune_sql() {   # <now>
    local now="$1" raw roll res ev step until last
    read -r raw roll res ev < <(_met_retention)
    step=$(( res * 60 ))
    until=$(( now / step * step ))
    last=$(_met_meta_get rolled_until)
    _met_num "$last" || last=$(_met_sql_val "SELECT COALESCE(MIN(ts), 0) FROM samples;")
    _met_num "$last" || last=0
    last=$(( last / step * step ))
    if (( until > last )); then
        local c sel="" ins="" upd=""
        for c in $METRICS_COLUMNS; do
            ins+=", ${c}_avg, ${c}_max"
            sel+=", AVG(${c}), MAX(${c})"
            upd+=", ${c}_avg = excluded.${c}_avg, ${c}_max = excluded.${c}_max"
        done
        cat <<SQL
INSERT INTO rollups (scope, ts, n, ok_n${ins})
    SELECT scope, (ts / ${step}) * ${step}, COUNT(*), COUNT(http_ok)${sel}
    FROM samples WHERE ts >= ${last} AND ts < ${until} GROUP BY 1, 2
    ON CONFLICT(scope, ts) DO UPDATE SET n = excluded.n, ok_n = excluded.ok_n${upd};
SQL
        _met_meta_set_sql rolled_until "$until"
    fi
    if (( (now / 60) % 60 == 17 )) || [[ "${METRICS_FORCE_PRUNE:-}" == 1 ]]; then
        cat <<SQL
DELETE FROM samples WHERE ts < $(( now - raw * 86400 ));
DELETE FROM rollups WHERE ts < $(( now - roll * 86400 ));
DELETE FROM events  WHERE ts < $(( now - ev * 86400 ));
PRAGMA incremental_vacuum;
SQL
        _met_meta_set_sql pruned_at "$now"
    fi
}

# Prometheus text exposition of the latest values — written every run,
# served only when `cipi metrics openmetrics on`.
_met_prom_write() {   # stdin: "scope metric value" lines
    local tmp="${METRICS_PROM}.tmp"
    awk -v ts="$1" '
        function help(n, h) { if (!(n in seen)) { seen[n] = 1; printf "# HELP %s %s\n# TYPE %s gauge\n", n, h, n } }
        BEGIN {
            H["cpu"]="CPU busy, percent (host: all cores; app: of one core)"; H["load1"]="Load average, 1 minute"
            H["mem"]="Memory in use, percent"; H["mem_used_mb"]="Memory in use, MB"; H["swap"]="Swap in use, percent"
            H["disk"]="Root filesystem in use, percent"; H["net_rx"]="Bytes received per second"; H["net_tx"]="Bytes sent per second"
            H["mem_mb"]="Resident memory of the app user processes, MB"; H["procs"]="Processes of the app user"
            H["fpm_procs"]="PHP-FPM children of the app pool"; H["fpm_max"]="pm.max_children of the app pool"
            H["fpm_saturated"]="Times the pool hit pm.max_children in the last minute"; H["req"]="Requests in the last minute"
            H["http_5xx"]="HTTP 5xx responses in the last minute"; H["http_ms"]="Healthcheck response time, milliseconds"
            H["http_ok"]="Healthcheck answered the expected status (1) or not (0)"; H["http_code"]="Healthcheck HTTP status"
            H["workers_up"]="Queue worker programs running"; H["workers_total"]="Queue worker programs configured"
            # Exposed names carry their unit, as Prometheus naming asks.
            N["cpu"]="cpu_percent"; N["mem"]="memory_percent"; N["mem_used_mb"]="memory_used_megabytes"; N["swap"]="swap_percent"
            N["disk"]="disk_percent"; N["net_rx"]="network_receive_bytes_per_second"; N["net_tx"]="network_transmit_bytes_per_second"
            N["mem_mb"]="memory_rss_megabytes"; N["procs"]="processes"; N["fpm_procs"]="fpm_children"; N["fpm_max"]="fpm_max_children"
            N["fpm_saturated"]="fpm_max_children_reached"; N["req"]="requests_per_minute"; N["http_5xx"]="http_5xx_per_minute"
            N["http_ms"]="healthcheck_duration_milliseconds"; N["http_ok"]="healthcheck_up"; N["http_code"]="healthcheck_status_code"
        }
        {
            m = ($2 in N) ? N[$2] : $2; gsub(/[^a-z0-9_]/, "_", m)
            if ($1 == "host") { n = "cipi_host_" m; help(n, H[$2]); printf "%s %s\n", n, $3 }
            else { a = $1; sub(/^app:/, "", a); n = "cipi_app_" m; help(n, H[$2]); printf "%s{app=\"%s\"} %s\n", n, a, $3 }
        }
        END { printf "# HELP cipi_metrics_collected_timestamp_seconds When these values were collected\n# TYPE cipi_metrics_collected_timestamp_seconds gauge\ncipi_metrics_collected_timestamp_seconds %s\n", ts }
    ' > "$tmp" 2>/dev/null || { rm -f "$tmp"; return 0; }
    chown root:www-data "$tmp" 2>/dev/null || true
    chmod 640 "$tmp" 2>/dev/null || true
    mv -f "$tmp" "$METRICS_PROM" 2>/dev/null || rm -f "$tmp"
}

# "scope metric value" lines → one upsert per scope. Only known columns and
# numeric values get through: nothing read from a log or a process reaches SQL.
_met_rows_to_sql() {   # <ts>
    awk -v ts="$1" -v cols="$METRICS_COLUMNS" '
        BEGIN { n = split(cols, C, " "); for (i = 1; i <= n; i++) ok[C[i]] = 1 }
        $1 ~ /^(host|app:[a-z][a-z0-9]*)$/ && ($2 in ok) && $3 ~ /^-?[0-9]+(\.[0-9]+)?$/ {
            if (!($1 in seen)) { seen[$1] = 1; order[++k] = $1 }
            v[$1, $2] = $3; has[$1] = has[$1] " " $2
        }
        END {
            for (i = 1; i <= k; i++) {
                s = order[i]; m = split(substr(has[s], 2), M, " ")
                cl = ""; vl = ""; up = ""
                for (j = 1; j <= m; j++) { cl = cl ", " M[j]; vl = vl ", " v[s, M[j]]; up = up (j > 1 ? ", " : "") M[j] " = excluded." M[j] }
                printf "INSERT INTO samples (scope, ts%s) VALUES ('\''%s'\'', %d%s) ON CONFLICT(scope, ts) DO UPDATE SET %s;\n", cl, s, ts, vl, up
            }
        }'
}

# One pass. Run by /usr/local/bin/cipi-metrics every minute.
metrics_collect() {
    _met_have_sqlite || return 0
    _MET_CFG_CACHE=""
    local cfg; cfg=$(_met_cfg)
    _MET_CFG_CACHE="$cfg"
    [[ "$(jq -r '.enabled' <<< "$cfg")" == "false" ]] && return 0
    _met_db_init || return 0

    local started now ts
    started=$(date +%s%3N)
    now=$(date +%s); ts=$(( now / 60 * 60 ))
    local rows; rows=$(mktemp) || return 0   # "scope metric value"

    # Host
    local v rx tx
    v=$(_met_host_cpu) && echo "host cpu $v" >> "$rows"
    awk '{print "host load1", $1}' "${METRICS_PROC}/loadavg" 2>/dev/null >> "$rows"
    awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} /^SwapTotal:/{st=$2} /^SwapFree:/{sf=$2}
         END { if (t > 0) { printf "host mem %.2f\nhost mem_used_mb %.0f\n", (t-a)/t*100, (t-a)/1024 }
               printf "host swap %.2f\n", (st > 0 ? (st-sf)/st*100 : 0) }' "${METRICS_PROC}/meminfo" 2>/dev/null >> "$rows"
    df -P / 2>/dev/null | awk 'NR==2 { gsub(/%/, "", $5); print "host disk", $5 }' >> "$rows"
    if read -r rx tx < <(_met_host_net "$now"); then
        echo "host net_rx $rx" >> "$rows"; echo "host net_tx $tx" >> "$rows"
    fi

    # Apps
    local apps_tsv; apps_tsv=$(_met_apps_tsv)
    local -A A_URL=() A_SUSP=() A_PHP=() A_OCT=() A_EXP=()
    local users="" app url susp oct php exp
    while IFS=$'\x1f' read -r app url susp oct php exp; do
        [[ -n "$app" ]] || continue
        A_URL[$app]="$url"; A_SUSP[$app]="$susp"; A_PHP[$app]="$php"; A_OCT[$app]="$oct"; A_EXP[$app]="$exp"
        users+="${app} "
    done <<< "$apps_tsv"

    local events_sql=""
    if [[ -n "$users" ]]; then
        local c m p f
        while read -r app c m p f; do
            [[ -n "${A_SUSP[$app]+x}" ]] || continue
            _met_num "$c" && [[ "$c" != -1* ]] && echo "app:${app} cpu $c" >> "$rows"
            echo "app:${app} mem_mb $m" >> "$rows"
            echo "app:${app} procs $p" >> "$rows"
            if [[ -z "${A_OCT[$app]}" && "${A_PHP[$app]}" =~ ^[0-9]+\.[0-9]+$ ]]; then
                echo "app:${app} fpm_procs $f" >> "$rows"
                local mx; mx=$(_met_fpm_max "$app" "${A_PHP[$app]}")
                [[ "$mx" =~ ^[0-9]+$ ]] && echo "app:${app} fpm_max $mx" >> "$rows"
            fi
        done < <(_met_app_procs "$users")

        local -A SAT=()
        while read -r app c; do [[ -n "$app" ]] && SAT[$app]="$c"; done < <(_met_fpm_saturation)
        local -A WUP=() WTOT=()
        while read -r app c m; do [[ -n "$app" ]] && { WUP[$app]="$c"; WTOT[$app]="$m"; }; done < <(_met_workers)

        for app in $users; do
            if [[ -z "${A_OCT[$app]}" && "${A_PHP[$app]}" =~ ^[0-9]+\.[0-9]+$ ]]; then
                echo "app:${app} fpm_saturated ${SAT[$app]:-0}" >> "$rows"
            fi
            if [[ -n "${WTOT[$app]:-}" ]]; then
                echo "app:${app} workers_up ${WUP[$app]}" >> "$rows"
                echo "app:${app} workers_total ${WTOT[$app]}" >> "$rows"
            fi
            # The first time a log is seen there is no "since": count from the next run.
            local counts seen=false
            [[ -f "${METRICS_STATE}/log.access.${app}" ]] && seen=true
            counts=$(_met_log_tail "${METRICS_APP_LOGS}/${app}/nginx-access.log" "access.${app}" | _met_count_requests)
            if [[ "$seen" == true ]]; then
                read -r c m <<< "$counts"
                echo "app:${app} req ${c:-0}" >> "$rows"
                echo "app:${app} http_5xx ${m:-0}" >> "$rows"
            fi
        done

        if [[ "$(jq -r '.probe' <<< "$cfg")" != "false" ]]; then
            local probes code ms expect
            probes=$(for app in $users; do
                [[ -n "${A_URL[$app]}" && "${A_SUSP[$app]}" != "true" ]] && echo "$app ${A_URL[$app]}"
            done | _met_probe_all)
            while read -r app code ms; do
                [[ -n "$app" ]] || continue
                expect="${A_EXP[$app]:-200}"
                [[ "$expect" =~ ^[0-9]{3}$ ]] || expect=200
                local ok=0; [[ "$code" == "$expect" ]] && ok=1
                echo "app:${app} http_code $code" >> "$rows"
                echo "app:${app} http_ok $ok" >> "$rows"
                [[ "$code" != 000 ]] && echo "app:${app} http_ms $ms" >> "$rows"
                events_sql+=$(_met_probe_transition "$app" "$ok" "$code" "${A_URL[$app]}" "$ts")$'\n'
            done <<< "$probes"
        fi
    fi

    # One transaction for the whole minute.
    local sql
    sql=$(
        echo "BEGIN;"
        _met_rows_to_sql "$ts" < "$rows"
        printf '%s' "$events_sql"
        _met_heartbeat "$ts"
        _met_rollup_prune_sql "$now"
        _met_meta_set_sql last_run "$ts"
        _met_meta_set_sql last_duration_ms "$(( $(date +%s%3N) - started ))"
        echo "COMMIT;"
    )
    printf '%s\n' "$sql" | _met_sql >/dev/null 2>&1 || true
    if (( (now / 60) % 60 == 17 )); then
        echo "PRAGMA wal_checkpoint(TRUNCATE);" | _met_sql >/dev/null 2>&1 || true
    fi
    _met_prom_write "$ts" < "$rows"
    rm -f "$rows"
    return 0
}

# ── Queries ────────────────────────────────────────────────────

_met_range_sec() {   # 90m | 24h | 7d → seconds; empty on error
    [[ "${1:-}" =~ ^([0-9]+)(m|h|d)$ ]] || return 1
    local n="${BASH_REMATCH[1]}" u="${BASH_REMATCH[2]}"
    (( n > 0 )) || return 1
    case "$u" in m) echo $(( n * 60 )) ;; h) echo $(( n * 3600 )) ;; d) echo $(( n * 86400 )) ;; esac
}

# A step that gives about 240 points, rounded to a value a chart reads well.
_met_step_for() {   # <range seconds> <min step>
    local want=$(( $1 / 240 )) s
    for s in 60 120 300 600 900 1800 3600 7200 10800 21600 43200 86400; do
        (( s >= want && s >= $2 )) && { echo "$s"; return; }
    done
    echo 86400
}

_met_valid_metrics() {   # <scope host|app> <csv> → space list, only known names
    local list out="" m
    [[ "$1" == host ]] && list="$METRICS_HOST_LIST" || list="$METRICS_APP_LIST"
    if [[ -z "${2:-}" ]]; then echo "$list"; return; fi
    for m in ${2//,/ }; do
        [[ " $list " == *" $m "* ]] && out+="$m "
    done
    echo "${out% }"
}

_met_require_db() {
    if ! _met_have_sqlite; then
        error "sqlite3 is not installed — apt-get install -y sqlite3, then: cipi metrics status"; return 1
    fi
    [[ -f "$METRICS_DB" ]] || _met_db_init || { error "Cannot create ${METRICS_DB}"; return 1; }
}

# JSON: {scope, metrics, from, to, step, source, series: {metric: [[ts, avg, max], …]}}
# Within the raw retention it reads the minutes; beyond it the rollups, plus
# the minutes not rolled up yet.
_met_series_json() {   # <scope> <metrics space list> <from> <to>
    local scope="$1" metrics="$2" from="$3" to="$4"
    local raw roll res ev range step source rolled m sel="" inner_r="" inner_s=""
    read -r raw roll res ev < <(_met_retention)
    range=$(( to - from ))
    local now; now=$(date +%s)
    local sq; sq=$(_met_q "$scope")
    local q
    if (( from >= now - raw * 86400 )); then
        source=raw; step=$(_met_step_for "$range" 60)
        for m in $metrics; do sel+=", ROUND(AVG(${m}), 2) AS \"${m}|a\", ROUND(MAX(${m}), 2) AS \"${m}|m\""; done
        q="SELECT (ts / ${step}) * ${step} AS t${sel} FROM samples WHERE scope = ${sq} AND ts >= ${from} AND ts <= ${to} GROUP BY t ORDER BY t;"
    else
        source=rollup; step=$(_met_step_for "$range" $(( res * 60 )))
        rolled=$(_met_meta_get rolled_until); _met_num "$rolled" || rolled=0
        for m in $metrics; do
            inner_r+=", ${m}_avg AS ${m}_a, ${m}_max AS ${m}_m"
            inner_s+=", ${m}, ${m}"
            sel+=", ROUND(SUM(${m}_a * w) / SUM(CASE WHEN ${m}_a IS NOT NULL THEN w END), 2) AS \"${m}|a\", ROUND(MAX(${m}_m), 2) AS \"${m}|m\""
        done
        q="SELECT (ts / ${step}) * ${step} AS t${sel} FROM (
                SELECT ts, n AS w${inner_r} FROM rollups WHERE scope = ${sq} AND ts >= ${from} AND ts <= ${to} AND ts < ${rolled}
                UNION ALL
                SELECT ts, 1${inner_s} FROM samples WHERE scope = ${sq} AND ts >= MAX(${from}, ${rolled}) AND ts <= ${to})
            GROUP BY t ORDER BY t;"
    fi
    _met_sql_json "$q" | jq -c --arg scope "$scope" --arg metrics "$metrics" --argjson from "$from" --argjson to "$to" \
        --argjson step "$step" --arg source "$source" '
        . as $rows | ($metrics | split(" ") | map(select(. != ""))) as $ms
        | {scope: $scope, metrics: $ms, from: $from, to: $to, step: $step, source: $source,
           series: ($ms | map(. as $m | {key: $m, value: ($rows | map(select(.["\($m)|a"] != null) | [.t, .["\($m)|a"], .["\($m)|m"]]))}) | from_entries)}'
}

# Uptime of the healthcheck over a window: share of probes that answered the
# expected status. Raw samples while the window fits the raw retention,
# rollups (weighted by their sample count) beyond it.
_met_uptime_sql() {   # <app> <from> → "pct checks down_minutes avg_ms"
    local app="$1" from="$2" raw roll res ev now rolled
    read -r raw roll res ev < <(_met_retention)
    now=$(date +%s)
    local s; s=$(_met_q "app:${app}")
    if (( from >= now - raw * 86400 )); then
        _met_sql_val "SELECT COALESCE(ROUND(AVG(http_ok) * 100, 3), ''), COUNT(http_ok), COALESCE(SUM(http_ok = 0), 0), COALESCE(ROUND(AVG(http_ms)), '')
            FROM samples WHERE scope = ${s} AND ts >= ${from};" | tr '|' ' '
    else
        rolled=$(_met_meta_get rolled_until); _met_num "$rolled" || rolled=0
        _met_sql_val "SELECT COALESCE(ROUND(SUM(ok * okn) / SUM(CASE WHEN ok IS NOT NULL THEN okn END) * 100, 3), ''),
            COALESCE(SUM(CASE WHEN ok IS NOT NULL THEN okn END), 0),
            COALESCE(ROUND(SUM((1 - ok) * okn)), 0),
            COALESCE(ROUND(SUM(ms * w) / SUM(CASE WHEN ms IS NOT NULL THEN w END)), '')
            FROM (SELECT http_ok_avg AS ok, ok_n AS okn, http_ms_avg AS ms, n AS w FROM rollups WHERE scope = ${s} AND ts >= ${from} AND ts < ${rolled}
                  UNION ALL SELECT http_ok, 1, http_ms, 1 FROM samples WHERE scope = ${s} AND ts >= MAX(${from}, ${rolled}));" | tr '|' ' '
    fi
}

_met_uptime_days_json() {   # <app> <from> → [[day_ts, pct|null], …] (UTC days)
    local app="$1" from="$2" rolled s
    s=$(_met_q "app:${app}")
    rolled=$(_met_meta_get rolled_until); _met_num "$rolled" || rolled=0
    _met_sql_json "SELECT (ts / 86400) * 86400 AS d, ROUND(SUM(ok * okn) / SUM(okn) * 100, 2) AS pct FROM (
            SELECT ts, http_ok_avg AS ok, ok_n AS okn FROM rollups WHERE scope = ${s} AND http_ok_avg IS NOT NULL AND ts >= ${from} AND ts < ${rolled}
            UNION ALL SELECT ts, http_ok, 1 FROM samples WHERE scope = ${s} AND http_ok IS NOT NULL AND ts >= MAX(${from}, ${rolled}))
        GROUP BY d ORDER BY d;" | jq -c 'map([.d, .pct])'
}

_met_app_uptime_json() {   # <app> <range seconds>
    local app="$1" range="$2" now from pct checks down ms
    now=$(date +%s); from=$(( now - range ))
    read -r pct checks down ms <<< "$(_met_uptime_sql "$app" "$from")" || true
    local incidents
    incidents=$(_met_sql_json "SELECT ts, status, summary FROM events WHERE source = 'health' AND subject = $(_met_q "$app") AND ts >= ${from} ORDER BY ts;")
    jq -c -n --arg app "$app" --argjson range "$range" --arg pct "${pct:-}" --arg checks "${checks:-0}" --arg down "${down:-0}" --arg ms "${ms:-}" \
        --argjson days "$(_met_uptime_days_json "$app" "$from")" --argjson ev "$incidents" '
        {app: $app, range: $range,
         uptime: (if $pct == "" then null else ($pct | tonumber) end),
         checks: (($checks | tonumber?) // 0), down_minutes: (($down | tonumber?) // 0),
         avg_ms: (if $ms == "" then null else ($ms | tonumber) end),
         incidents: ($ev | map(select(.status != "ok")) | length),
         days: $days, events: $ev}'
}

# ── Commands ───────────────────────────────────────────────────

metrics_command() {
    local sub="${1:-}"; shift || true
    case "$sub" in
        ""|overview)  _met_cmd_overview "$@" ;;
        status)       _met_cmd_status "$@" ;;
        show)         _met_cmd_show "$@" ;;
        uptime)       _met_cmd_uptime "$@" ;;
        events)       _met_cmd_events "$@" ;;
        enable)       _met_cmd_toggle true ;;
        disable)      _met_cmd_toggle false ;;
        retention)    _met_cmd_retention "$@" ;;
        probe)        _met_cmd_probe "$@" ;;
        heartbeat)    _met_cmd_heartbeat "$@" ;;
        openmetrics)  _met_cmd_openmetrics "$@" ;;
        prune)        _met_cmd_prune "$@" ;;
        reset)        _met_cmd_reset "$@" ;;
        collect)      metrics_collect ;;
        *) error "Unknown: cipi metrics ${sub}"
           echo "Use: overview status show uptime events enable disable retention probe heartbeat openmetrics prune reset"
           exit 1 ;;
    esac
}

metrics_ensure_cron() {
    if [[ -f "${CIPI_LIB}/cipi-metrics.sh" ]]; then
        install -m 755 -o root -g root "${CIPI_LIB}/cipi-metrics.sh" "$METRICS_HELPER" 2>/dev/null \
            || warn "Could not install ${METRICS_HELPER}"
    fi
    if [[ ! -f "$METRICS_CRON" ]]; then
        if cat > "$METRICS_CRON" 2>/dev/null <<EOF
# Cipi metrics & health history (every minute) — cipi metrics
* * * * * root ${METRICS_HELPER} >/dev/null 2>&1
EOF
        then chmod 644 "$METRICS_CRON" 2>/dev/null || true
        else warn "Could not write ${METRICS_CRON} — nothing will be collected"
        fi
    fi
}

_met_cmd_status_json() {
    local cfg raw roll res ev db_bytes=0 samples=0 rollups=0 events=0 oldest="" last="" dur="" hb_ts="" hb_ok="" hb_code="" sqlite=false
    cfg=$(_met_cfg)
    read -r raw roll res ev < <(_met_retention)
    if _met_have_sqlite; then
        sqlite=true
        if [[ -f "$METRICS_DB" ]]; then
            db_bytes=$(( $(stat -c '%s' "$METRICS_DB" 2>/dev/null || echo 0) + $(stat -c '%s' "${METRICS_DB}-wal" 2>/dev/null || echo 0) ))
            IFS='|' read -r samples rollups events oldest < <(_met_sql_val "SELECT (SELECT COUNT(*) FROM samples), (SELECT COUNT(*) FROM rollups), (SELECT COUNT(*) FROM events), (SELECT MIN(m) FROM (SELECT MIN(ts) AS m FROM samples UNION ALL SELECT MIN(ts) FROM rollups));") || true
            last=$(_met_meta_get last_run); dur=$(_met_meta_get last_duration_ms)
            hb_ts=$(_met_meta_get hb_ts); hb_ok=$(_met_meta_get hb_ok); hb_code=$(_met_meta_get hb_code)
        fi
    fi
    local cron=false; [[ -f "$METRICS_CRON" ]] && cron=true
    local url; url=$(jq -r '.heartbeat.url // ""' <<< "$cfg")
    jq -c -n --argjson cfg "$cfg" --argjson sqlite "$sqlite" --argjson cron "$cron" \
        --arg db "$METRICS_DB" --arg bytes "$db_bytes" --arg samples "${samples:-0}" --arg rollups "${rollups:-0}" --arg events "${events:-0}" \
        --arg oldest "${oldest:-}" --arg last "${last:-}" --arg dur "${dur:-}" \
        --argjson raw "$raw" --argjson roll "$roll" --argjson res "$res" --argjson ev "$ev" \
        --arg hb_host "$(_met_url_host "$url")" --arg hb_ts "${hb_ts:-}" --arg hb_ok "${hb_ok:-}" --arg hb_code "${hb_code:-}" '
        def n: if . == "" then null else (tonumber? // null) end;
        {enabled: ($cfg.enabled != false), sqlite: $sqlite, cron: $cron, probe: ($cfg.probe != false),
         database: {path: $db, bytes: ($bytes | n), samples: ($samples | n), rollups: ($rollups | n), events: ($events | n), oldest: ($oldest | n)},
         last_run: ($last | n), last_duration_ms: ($dur | n),
         retention: {raw_days: $raw, rollup_days: $roll, resolution_minutes: $res, events_days: $ev},
         heartbeat: {enabled: ($cfg.heartbeat.enabled == true), url_set: (($cfg.heartbeat.url // "") != ""), url_host: (if $hb_host == "" then null else $hb_host end),
                     every: ($cfg.heartbeat.every // 1), last_ts: ($hb_ts | n), last_ok: (if $hb_ok == "" then null else ($hb_ok == "1") end), last_code: ($hb_code | n)},
         openmetrics: {enabled: ($cfg.openmetrics.enabled == true), port: ($cfg.openmetrics.port // 9273),
                       allow: ($cfg.openmetrics.allow // []), token_set: (($cfg.openmetrics.token // "") != "")}}'
}

_met_cmd_status() {
    parse_args "$@"
    local j; j=$(_met_cmd_status_json)
    if [[ "${ARG_json:-}" == "true" ]]; then echo "$j"; return 0; fi
    local fmt_ts='if . == null then "never" else (. | strftime("%Y-%m-%d %H:%M UTC")) end'
    echo -e "\n${BOLD}Metrics & health history${NC}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    printf "  %-14s %s\n" "Collector" "$(jq -r 'if .enabled then "on — every minute" else "off (cipi metrics enable)" end' <<< "$j")"
    [[ "$(jq -r .sqlite <<< "$j")" == "true" ]] || printf "  %-14s ${RED}%s${NC}\n" "sqlite3" "missing — apt-get install -y sqlite3"
    [[ "$(jq -r .cron <<< "$j")" == "true" ]] || printf "  %-14s ${YELLOW}%s${NC}\n" "Cron" "${METRICS_CRON} missing — cipi metrics enable"
    printf "  %-14s %s\n" "Last run" "$(jq -r ".last_run | ${fmt_ts}" <<< "$j")$(jq -r 'if .last_duration_ms then " (\(.last_duration_ms) ms)" else "" end' <<< "$j")"
    printf "  %-14s %s\n" "Healthchecks" "$(jq -r 'if .probe then "probed every minute (apps with cipi health set)" else "not probed (cipi metrics probe on)" end' <<< "$j")"
    printf "  %-14s %s\n" "Retention" "$(jq -r '.retention | "raw \(.raw_days)d · \(.resolution_minutes)-minute rollups \(.rollup_days)d · events \(.events_days)d"' <<< "$j")"
    printf "  %-14s %s\n" "Database" "$(jq -r '.database | "\(.path) — \(((.bytes // 0) / 1048576 * 10 | round) / 10) MB, \(.samples // 0) samples, \(.rollups // 0) rollups, \(.events // 0) events"' <<< "$j")"
    printf "  %-14s %s\n" "Heartbeat" "$(jq -r '.heartbeat | if .enabled then "every \(.every) min → \(.url_host)" + (if .last_ok == true then " (last call ok)" elif .last_ok == false then " (last call FAILED, HTTP \(.last_code))" else "" end) else "off (cipi metrics heartbeat set <url>)" end' <<< "$j")"
    printf "  %-14s %s\n" "OpenMetrics" "$(jq -r '.openmetrics | if .enabled then "on — :\(.port)/metrics, from \(.allow | join(", "))" else "off" end' <<< "$j")"
    echo ""
}

_met_scope_from_args() {   # sets MET_SCOPE, MET_KIND
    if [[ -n "${ARG_app:-}" ]]; then
        app_exists "$ARG_app" || { error "App '${ARG_app}' not found"; exit 1; }
        MET_SCOPE="app:${ARG_app}"; MET_KIND=app
    else
        MET_SCOPE=host; MET_KIND=host
    fi
}

_met_window_from_args() {   # sets MET_FROM, MET_TO, MET_RANGE (default $1)
    local def="$1" roll range
    read -r _ roll _ _ < <(_met_retention)
    MET_TO=$(date +%s)
    if [[ -n "${ARG_from:-}" ]]; then
        [[ "$ARG_from" =~ ^[0-9]{9,11}$ ]] || { error "--from must be a Unix timestamp"; exit 1; }
        MET_FROM="$ARG_from"
        if [[ -n "${ARG_to:-}" ]]; then
            [[ "$ARG_to" =~ ^[0-9]{9,11}$ ]] || { error "--to must be a Unix timestamp"; exit 1; }
            MET_TO="$ARG_to"
        fi
        (( MET_TO > MET_FROM )) || { error "--to must be after --from"; exit 1; }
        MET_RANGE=$(( MET_TO - MET_FROM ))
        return 0
    fi
    range=$(_met_range_sec "${ARG_range:-$def}") || { error "--range must look like 90m, 24h or 7d"; exit 1; }
    if (( range > roll * 86400 )); then
        range=$(( roll * 86400 ))
    fi
    MET_RANGE=$range
    MET_FROM=$(( MET_TO - range ))
}

_met_spark() {   # values on stdin (one per line, "" = gap) → ▁▂▃▄▅▆▇█
    awk 'BEGIN { split("▁ ▂ ▃ ▄ ▅ ▆ ▇ █", c, " ") }
         { v[NR] = $1; if ($1 != "") { if (mn == "" || $1 < mn) mn = $1; if (mx == "" || $1 > mx) mx = $1 } }
         END { for (i = 1; i <= NR; i++) { if (v[i] == "") { printf " "; continue }
               k = (mx > mn) ? int((v[i] - mn) / (mx - mn) * 7) + 1 : 1; printf "%s", c[k] } }'
}

_met_cmd_show() {
    parse_args "$@"
    _met_require_db || exit 1
    _met_scope_from_args
    _met_window_from_args 24h
    local metrics
    metrics=$(_met_valid_metrics "$MET_KIND" "${ARG_metrics:-${ARG_metric:-}}")
    [[ -n "$metrics" ]] || { error "No known metric in '${ARG_metrics:-}'. ${MET_KIND}: $([[ $MET_KIND == host ]] && echo "$METRICS_HOST_LIST" || echo "$METRICS_APP_LIST")"; exit 1; }
    local j; j=$(_met_series_json "$MET_SCOPE" "$metrics" "$MET_FROM" "$MET_TO")
    if [[ "${ARG_json:-}" == "true" ]]; then echo "$j"; return 0; fi

    echo -e "\n${BOLD}${MET_SCOPE#app:} — last $(_met_human_range "$MET_RANGE")${NC}  ${DIM}(step $(_met_human_range "$(jq -r .step <<< "$j")"), $(jq -r .source <<< "$j") data)${NC}"
    source "${CIPI_LIB}/table.sh"
    tbl_start; tbl_align l r r r l
    tbl_head "METRIC" "MIN" "AVG" "MAX" "TREND"
    local m
    for m in $metrics; do
        local stats spark
        stats=$(jq -r --arg m "$m" '.series[$m] | if length == 0 then "— — —" else
            "\(map(.[1]) | min) \((map(.[1]) | add / length) * 100 | round / 100) \(map(.[2]) | max)" end' <<< "$j")
        spark=$(jq -r --arg m "$m" '.series[$m][] | .[1]' <<< "$j" | tail -60 | _met_spark)
        read -r a b c <<< "$stats"
        tbl_row "$m" "$a" "$b" "$c" "${CYAN}${spark}${NC}"
    done
    tbl_print
    echo ""
}

_met_human_range() {
    local s="$1"
    if (( s % 86400 == 0 )); then echo "$(( s / 86400 ))d"
    elif (( s % 3600 == 0 )); then echo "$(( s / 3600 ))h"
    else echo "$(( s / 60 ))m"; fi
}

_met_cmd_uptime() {
    local app="${1:-}"
    [[ "$app" == --* ]] && app="" || shift || true
    parse_args "$@"
    _met_require_db || exit 1
    _met_window_from_args 30d
    local apps
    if [[ -n "$app" ]]; then
        app_exists "$app" || { error "App '${app}' not found"; exit 1; }
        apps="$app"
    else
        apps=$(vault_read apps.json | jq -r 'to_entries[] | select((.value.health_url // "") != "") | .key')
    fi
    local items="[]" a
    for a in $apps; do
        items=$(jq -c --argjson u "$(_met_app_uptime_json "$a" "$MET_RANGE")" '. + [$u]' <<< "$items")
    done
    if [[ "${ARG_json:-}" == "true" ]]; then
        if [[ -n "$app" ]]; then jq -c '.[0]' <<< "$items"; else jq -c --argjson r "$MET_RANGE" '{range: $r, apps: .}' <<< "$items"; fi
        return 0
    fi
    echo -e "\n${BOLD}Uptime — last $(_met_human_range "$MET_RANGE")${NC}  ${DIM}(healthcheck URL, probed every minute)${NC}"
    if [[ "$items" == "[]" ]]; then
        info "No app has a healthcheck. Set one with: cipi health set <app>"; echo ""; return 0
    fi
    source "${CIPI_LIB}/table.sh"
    tbl_start; tbl_align l r r r r l
    tbl_head "APP" "UPTIME" "DOWN" "AVG" "INCIDENTS" "DAYS"
    local row
    while IFS=$'\t' read -r a pct down ms inc; do
        local bars
        bars=$(jq -r --arg a "$a" '.[] | select(.app == $a) | .days[] | .[1] // ""' <<< "$items" | tail -45 | _met_spark)
        local color="$GREEN"
        [[ "$pct" != "—" ]] && awk -v p="$pct" 'BEGIN{exit !(p < 99.9)}' && color="$YELLOW"
        [[ "$pct" != "—" ]] && awk -v p="$pct" 'BEGIN{exit !(p < 99)}' && color="$RED"
        tbl_row "$a" "${color}${pct}%${NC}" "${down}m" "${ms}" "$inc" "${CYAN}${bars}${NC}"
    done < <(jq -r '.[] | [.app, (.uptime // "—" | tostring), (.down_minutes | tostring), (if .avg_ms then "\(.avg_ms) ms" else "—" end), (.incidents | tostring)] | @tsv' <<< "$items")
    tbl_print
    echo ""
}

_met_cmd_events() {
    parse_args "$@"
    _met_require_db || exit 1
    _met_window_from_args 7d
    local limit="${ARG_limit:-100}" where=""
    [[ "$limit" =~ ^[0-9]+$ ]] && (( limit >= 1 && limit <= 1000 )) || limit=100
    if [[ -n "${ARG_app:-}" ]]; then
        app_exists "$ARG_app" || { error "App '${ARG_app}' not found"; exit 1; }
        where="AND subject = $(_met_q "$ARG_app")"
    fi
    if [[ -n "${ARG_source:-}" ]]; then
        [[ "$ARG_source" =~ ^(monitor|health|deploy|heartbeat)$ ]] || { error "--source: monitor, health, deploy or heartbeat"; exit 1; }
        where+=" AND source = $(_met_q "$ARG_source")"
    fi
    local j
    j=$(_met_sql_json "SELECT ts, source, subject, status, summary FROM events WHERE ts >= ${MET_FROM} AND ts <= ${MET_TO} ${where} ORDER BY ts DESC LIMIT ${limit};")
    if [[ "${ARG_json:-}" == "true" ]]; then
        jq -c --argjson f "$MET_FROM" --argjson t "$MET_TO" '{from: $f, to: $t, events: .}' <<< "$j"; return 0
    fi
    echo -e "\n${BOLD}Events — last $(_met_human_range "$MET_RANGE")${NC}"
    if [[ "$j" == "[]" ]]; then echo "  none"; echo ""; return 0; fi
    source "${CIPI_LIB}/table.sh"
    tbl_start
    tbl_head "WHEN" "SOURCE" "SUBJECT" "STATUS" "SUMMARY"
    local ts src sub st sum col
    while IFS=$'\t' read -r ts src sub st sum; do
        case "$st" in ok) col="$GREEN" ;; warn) col="$YELLOW" ;; *) col="$RED" ;; esac
        tbl_row "$(date -d "@${ts}" '+%m-%d %H:%M' 2>/dev/null)" "$src" "$sub" "${col}${st}${NC}" "$sum"
    done < <(jq -r '.[] | [.ts, .source, .subject, .status, .summary] | @tsv' <<< "$j")
    tbl_print
    echo ""
}

# The data a dashboard needs in one call: latest values, a one-hour trend per
# app, uptime 24h/7d/30d, the last events.
metrics_overview_json() {
    local now from1h latest spark apps_json cfg
    now=$(date +%s); from1h=$(( now - 3600 ))
    latest=$(_met_sql_json "SELECT s.* FROM samples s
        JOIN (SELECT scope, MAX(ts) AS ts FROM samples WHERE ts >= $(( now - 900 )) GROUP BY scope) l ON s.scope = l.scope AND s.ts = l.ts;")
    spark=$(_met_sql_json "SELECT scope, (ts / 300) * 300 AS t, ROUND(AVG(cpu), 2) AS cpu, ROUND(AVG(mem_mb), 1) AS mem_mb,
            ROUND(AVG(req), 1) AS req, ROUND(AVG(http_5xx), 2) AS http_5xx, ROUND(AVG(http_ms)) AS http_ms
        FROM samples WHERE ts >= ${from1h} AND scope LIKE 'app:%' GROUP BY scope, t ORDER BY t;")
    apps_json=$(vault_read apps.json 2>/dev/null || echo '{}')
    local up="{}" a u24 u7 u30
    for a in $(jq -r 'to_entries[] | select((.value.health_url // "") != "") | .key' <<< "$apps_json"); do
        read -r u24 _ <<< "$(_met_uptime_sql "$a" $(( now - 86400 )))"
        read -r u7 _ <<< "$(_met_uptime_sql "$a" $(( now - 7 * 86400 )))"
        read -r u30 _ <<< "$(_met_uptime_sql "$a" $(( now - 30 * 86400 )))"
        up=$(jq -c --arg a "$a" --arg d "${u24:-}" --arg w "${u7:-}" --arg m "${u30:-}" \
            '.[$a] = {"24h": ($d | tonumber? // null), "7d": ($w | tonumber? // null), "30d": ($m | tonumber? // null)}' <<< "$up")
    done
    local events
    events=$(_met_sql_json "SELECT ts, source, subject, status, summary FROM events ORDER BY ts DESC LIMIT 15;")
    jq -c -n --argjson now "$now" --argjson latest "$latest" --argjson spark "$spark" --argjson apps "$apps_json" \
        --argjson up "$up" --argjson events "$events" --argjson status "$(_met_cmd_status_json)" '
        def vals($scope): ($latest | map(select(.scope == $scope)) | first // {} | del(.scope, .ts) | with_entries(select(.value != null)));
        def at($scope): ($latest | map(select(.scope == $scope)) | first // {} | .ts);
        def sp($scope): ($spark | map(select(.scope == $scope))) as $r
            | if ($r | length) == 0 then {} else
              (["cpu", "mem_mb", "req", "http_5xx", "http_ms"] | map(. as $m | {key: $m, value: ($r | map(.[$m]))}) | from_entries) end;
        {ts: $now, collector: {enabled: $status.enabled, sqlite: $status.sqlite, last_run: $status.last_run,
                               retention: $status.retention, heartbeat: $status.heartbeat, openmetrics: $status.openmetrics.enabled},
         host: {at: at("host"), values: vals("host")},
         apps: ($apps | to_entries | map(select(.key | test("^[a-z][a-z0-9]{2,31}$"))) | map(
            .key as $a | ("app:" + $a) as $s | {
                app: $a, domain: (.value.domain // null),
                suspended: ((.value.suspended // "false") | tostring == "true"),
                health: (if (.value.health_url // "") == "" then null else {url: .value.health_url, expect: ((.value.health_expect // "200") | tonumber? // 200)} end),
                at: at($s), values: vals($s), spark: sp($s), uptime: ($up[$a] // null)})),
         events: $events}'
}

_met_cmd_overview() {
    parse_args "$@"
    _met_require_db || exit 1
    local j; j=$(metrics_overview_json)
    if [[ "${ARG_json:-}" == "true" ]]; then echo "$j"; return 0; fi
    local last; last=$(jq -r '.collector.last_run // empty' <<< "$j")
    echo -e "\n${BOLD}Server${NC}  ${DIM}$(if [[ -n "$last" ]]; then echo "collected $(( ($(date +%s) - last) / 60 )) min ago"; else echo "nothing collected yet — the first run is within a minute"; fi)${NC}"
    jq -r '.host.values | "  CPU \(.cpu // "—")%   load \(.load1 // "—")   memory \(.mem // "—")% (\(.mem_used_mb // "—") MB)   swap \(.swap // "—")%   disk \(.disk // "—")%   net ↓\(((.net_rx // 0) / 1024) | round) KB/s ↑\(((.net_tx // 0) / 1024) | round) KB/s"' <<< "$j"
    echo ""
    source "${CIPI_LIB}/table.sh"
    tbl_start; tbl_align l r r r r r r l
    tbl_head "APP" "CPU%" "MEM MB" "REQ/MIN" "5XX" "HTTP" "UP 24H" "LAST HOUR (req)"
    local a cpu mem req e5 http up24 spark
    while IFS=$'\t' read -r a cpu mem req e5 http up24; do
        spark=$(jq -r --arg a "$a" '.apps[] | select(.app == $a) | (.spark.req // [])[]' <<< "$j" | _met_spark)
        tbl_row "$a" "$cpu" "$mem" "$req" "$e5" "$http" "$up24" "${CYAN}${spark}${NC}"
    done < <(jq -r '.apps[] | [.app, (.values.cpu // "—"), (.values.mem_mb // "—"), (.values.req // "—"), (.values.http_5xx // "—"),
        (if .values.http_code then "\(.values.http_code | floor) \(.values.http_ms // "?")ms" else "—" end),
        (if .uptime["24h"] then "\(.uptime["24h"])%" else "—" end)] | map(tostring) | @tsv' <<< "$j")
    tbl_print
    local n; n=$(jq '.events | length' <<< "$j")
    if (( n > 0 )); then
        echo -e "\n${BOLD}Recent events${NC}"
        jq -r '.events[:5][] | "  \(.ts | strftime("%m-%d %H:%M"))  \(.source)/\(.subject)  \(.status)  \(.summary)"' <<< "$j"
    fi
    echo -e "\n  ${DIM}cipi metrics show [--app=<app>] [--range=7d] · cipi metrics uptime · cipi metrics events${NC}\n"
}

_met_cmd_toggle() {
    local on="$1" cfg
    cfg=$(_met_cfg | jq -c --argjson on "$on" '.enabled = $on')
    _met_cfg_write "$cfg" || exit 1
    if [[ "$on" == true ]]; then
        _met_have_sqlite || { warn "sqlite3 is not installed — apt-get install -y sqlite3 (nothing is collected until then)"; }
        _met_db_init 2>/dev/null || true
        metrics_ensure_cron
        log_action "METRICS ENABLED"
        success "Metrics on — collected every minute"
    else
        log_action "METRICS DISABLED"
        success "Metrics off — nothing is collected; the history is kept (cipi metrics reset --yes removes it)"
    fi
}

_met_cmd_retention() {
    parse_args "$@"
    local raw roll res ev cfg
    read -r raw roll res ev < <(_met_retention)
    if [[ -z "${ARG_raw:-}${ARG_rollup:-}${ARG_resolution:-}${ARG_events:-}" ]]; then
        if [[ "${ARG_json:-}" == "true" ]]; then
            jq -c -n --argjson a "$raw" --argjson b "$roll" --argjson c "$res" --argjson d "$ev" \
                '{raw_days: $a, rollup_days: $b, resolution_minutes: $c, events_days: $d}'
        else
            echo "raw ${raw}d · ${res}-minute rollups ${roll}d · events ${ev}d"
            echo "Change: cipi metrics retention [--raw=7d] [--rollup=30d] [--resolution=15m] [--events=90d]"
        fi
        return 0
    fi
    _met_days_arg() { local v="${1%d}"; [[ "$v" =~ ^[0-9]+$ ]] && echo "$v"; }
    if [[ -n "${ARG_raw:-}" ]]; then
        raw=$(_met_days_arg "$ARG_raw") && (( raw >= 1 && raw <= 90 )) || { error "--raw: 1 to 90 days"; exit 1; }
    fi
    if [[ -n "${ARG_rollup:-}" ]]; then
        roll=$(_met_days_arg "$ARG_rollup") && (( roll >= 1 && roll <= 400 )) || { error "--rollup: 1 to 400 days"; exit 1; }
    fi
    if [[ -n "${ARG_resolution:-}" ]]; then
        res="${ARG_resolution%m}"
        [[ "$res" =~ ^(5|10|15|30|60)$ ]] || { error "--resolution: 5m, 10m, 15m, 30m or 60m"; exit 1; }
    fi
    if [[ -n "${ARG_events:-}" ]]; then
        ev=$(_met_days_arg "$ARG_events") && (( ev >= 7 && ev <= 730 )) || { error "--events: 7 to 730 days"; exit 1; }
    fi
    (( roll >= raw )) || { error "--rollup (${roll}d) cannot be shorter than --raw (${raw}d)"; exit 1; }
    cfg=$(_met_cfg | jq -c --argjson a "$raw" --argjson b "$roll" --argjson c "$res" --argjson d "$ev" \
        '.retention = {raw_days: $a, rollup_days: $b, resolution_minutes: $c, events_days: $d}')
    _met_cfg_write "$cfg" || exit 1
    log_action "METRICS RETENTION: raw=${raw}d rollup=${roll}d resolution=${res}m events=${ev}d"
    success "Retention: raw ${raw}d · ${res}-minute rollups ${roll}d · events ${ev}d"
    info "Older data goes at the next hourly prune (now: cipi metrics prune)"
}

_met_cmd_probe() {
    local v="${1:-status}" cfg
    case "$v" in
        on|off)
            cfg=$(_met_cfg | jq -c --argjson p "$([[ $v == on ]] && echo true || echo false)" '.probe = $p')
            _met_cfg_write "$cfg" || exit 1
            log_action "METRICS PROBE ${v}"
            success "Healthcheck probe every minute: ${v}" ;;
        status) echo "probe: $(_met_cfg | jq -r 'if .probe == false then "off" else "on" end')" ;;
        *) error "Usage: cipi metrics probe on|off|status"; exit 1 ;;
    esac
}

_met_cmd_heartbeat() {
    local sub="${1:-status}"; shift || true
    parse_args "$@"
    local cfg; cfg=$(_met_cfg)
    case "$sub" in
        status)
            if [[ "${ARG_json:-}" == "true" ]]; then _met_cmd_status_json | jq -c .heartbeat; return 0; fi
            _met_cmd_status_json | jq -r '.heartbeat | if .enabled then "on — every \(.every) min → \(.url_host)" else "off" end' ;;
        set)
            local url="${1:-${ARG_url:-}}" every="${ARG_every:-1}"
            [[ "$url" == --* ]] && url="${ARG_url:-}"
            [[ "$url" =~ ^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~:/?#@!\$\&\'\(\)\*\+,\;=%-]*)?$ ]] \
                || { error "Usage: cipi metrics heartbeat set <https://…> [--every=1]"; exit 1; }
            [[ "$url" == http://* ]] && warn "The URL is http:// — the call (and any token in it) travels in clear"
            [[ "$every" =~ ^[0-9]+$ ]] && (( every >= 1 && every <= 60 )) || { error "--every: 1 to 60 minutes"; exit 1; }
            cfg=$(jq -c --arg u "$url" --argjson e "$every" '.heartbeat = {enabled: true, url: $u, every: $e}' <<< "$cfg")
            _met_cfg_write "$cfg" || exit 1
            metrics_ensure_cron
            log_action "METRICS HEARTBEAT SET: $(_met_url_host "$url") every ${every}m"
            success "Heartbeat: every ${every} min → $(_met_url_host "$url")"
            info "Set the receiver to expect a call every ${every} min (plus a grace period): it alerts when they stop." ;;
        off)
            cfg=$(jq -c '.heartbeat.enabled = false' <<< "$cfg")
            _met_cfg_write "$cfg" || exit 1
            log_action "METRICS HEARTBEAT OFF"
            success "Heartbeat off" ;;
        test)
            local url; url=$(jq -r '.heartbeat.url // ""' <<< "$cfg")
            [[ -n "$url" ]] || { error "No heartbeat URL — cipi metrics heartbeat set <url>"; exit 1; }
            local code
            code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 5 --max-time 10 "$url" 2>/dev/null) || true
            [[ "$code" =~ ^[0-9]{3}$ ]] || code=000
            if [[ "${ARG_json:-}" == "true" ]]; then
                jq -c -n --arg h "$(_met_url_host "$url")" --arg c "$code" '{host: $h, code: ($c | tonumber), ok: ($c | startswith("2"))}'
                [[ "$code" =~ ^2 ]]; return
            fi
            if [[ "$code" =~ ^2 ]]; then success "HTTP ${code} ← $(_met_url_host "$url")"; else error "HTTP ${code} ← $(_met_url_host "$url")"; exit 1; fi ;;
        *) error "Usage: cipi metrics heartbeat [status]|set <url> [--every=N]|off|test"; exit 1 ;;
    esac
}

# ── OpenMetrics endpoint (opt-in) ─────────────────────────────

_met_allow_valid() {   # one entry
    [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ || "$1" =~ ^[0-9a-fA-F:]+(/[0-9]{1,3})?$ ]]
}

_met_nginx_write() {   # <port> <token> <allow json array>
    local port="$1" token="$2" allow="$3" rules="" ip
    while IFS= read -r ip; do
        [[ -n "$ip" ]] || continue
        rules+="    allow ${ip};"$'\n'
    done < <(jq -r '.[]' <<< "$allow")
    (umask 077; cat > "${METRICS_NGINX}.tmp" <<EOF
# Cipi — OpenMetrics endpoint (cipi metrics openmetrics). Written by Cipi: changes are overwritten.
server {
    listen ${port};
    listen [::]:${port};
    server_name _;
    access_log off;
${rules}    deny all;
    location = /metrics {
        if (\$http_authorization != "Bearer ${token}") { return 401; }
        default_type "text/plain; version=0.0.4; charset=utf-8";
        add_header Cache-Control "no-store" always;
        alias ${METRICS_PROM};
    }
    location / { return 404; }
}
EOF
    ) || return 1
    mv -f "${METRICS_NGINX}.tmp" "$METRICS_NGINX"
    chmod 600 "$METRICS_NGINX" 2>/dev/null || true
}

_met_ufw() {   # allow|delete <port> <allow json array>
    command -v ufw >/dev/null 2>&1 || return 0
    local op="$1" port="$2" allow="$3" ip
    while IFS= read -r ip; do
        [[ -n "$ip" ]] || continue
        if [[ "$op" == allow ]]; then
            ufw allow from "$ip" to any port "$port" proto tcp comment 'cipi metrics' >/dev/null 2>&1 || true
        else
            ufw delete allow from "$ip" to any port "$port" proto tcp >/dev/null 2>&1 || true
        fi
    done < <(jq -r '.[]' <<< "$allow")
}

_met_cmd_openmetrics() {
    local sub="${1:-status}"; shift || true
    parse_args "$@"
    local cfg; cfg=$(_met_cfg)
    local port token allow
    port=$(jq -r '.openmetrics.port // 9273' <<< "$cfg")
    token=$(jq -r '.openmetrics.token // ""' <<< "$cfg")
    allow=$(jq -c '.openmetrics.allow // []' <<< "$cfg")
    case "$sub" in
        status)
            if [[ "${ARG_json:-}" == "true" ]]; then _met_cmd_status_json | jq -c .openmetrics; return 0; fi
            if [[ "$(jq -r '.openmetrics.enabled' <<< "$cfg")" == "true" ]]; then
                echo "on — http://$(server_public_ip 2>/dev/null || hostname):${port}/metrics, from: $(jq -r 'join(", ")' <<< "$allow")"
                echo "token: cipi metrics openmetrics token --show"
            else
                echo "off — cipi metrics openmetrics on --allow=<prometheus IP>[,…] [--port=9273]"
            fi ;;
        on)
            [[ -n "${ARG_allow:-}" ]] || { error "--allow is required: the IPs (or CIDRs) of your Prometheus, comma separated"; exit 1; }
            local new_port="${ARG_port:-$port}" new_allow="[]" ip
            [[ "$new_port" =~ ^[0-9]+$ ]] && (( new_port >= 1024 && new_port <= 65535 )) || { error "--port: 1024 to 65535"; exit 1; }
            case "$new_port" in 3306|5432|6379|7700|8080|9000) error "Port ${new_port} is used by a service Cipi installs"; exit 1 ;; esac
            for ip in ${ARG_allow//,/ }; do
                _met_allow_valid "$ip" || { error "Not an IP or CIDR: ${ip}"; exit 1; }
                [[ "$ip" == "0.0.0.0/0" || "$ip" == "::/0" ]] && { error "${ip} would open the endpoint to everyone — list your Prometheus"; exit 1; }
                new_allow=$(jq -c --arg i "$ip" '. + [$i] | unique' <<< "$new_allow")
            done
            [[ -n "$token" ]] || token=$(generate_token)
            # Rules of the previous configuration go first: the allowlist may have changed.
            [[ "$(jq -r '.openmetrics.enabled' <<< "$cfg")" == "true" ]] && _met_ufw delete "$port" "$allow"
            _met_nginx_write "$new_port" "$token" "$new_allow" || { error "Could not write ${METRICS_NGINX}"; exit 1; }
            if ! reload_nginx >/dev/null 2>&1; then
                rm -f "$METRICS_NGINX"; reload_nginx >/dev/null 2>&1 || true
                error "nginx refused the configuration — nothing changed"; exit 1
            fi
            _met_ufw allow "$new_port" "$new_allow"
            cfg=$(jq -c --argjson p "$new_port" --arg t "$token" --argjson a "$new_allow" \
                '.openmetrics = {enabled: true, port: $p, token: $t, allow: $a}' <<< "$cfg")
            _met_cfg_write "$cfg" || exit 1
            log_action "METRICS OPENMETRICS ON: port=${new_port} allow=$(jq -r 'join(",")' <<< "$new_allow")"
            success "OpenMetrics on :${new_port}/metrics — from $(jq -r 'join(", ")' <<< "$new_allow")"
            echo ""
            echo -e "  ${BOLD}Prometheus scrape config${NC}"
            echo "    - job_name: cipi-$(hostname -s)"
            echo "      scrape_interval: 60s"
            echo "      authorization: { credentials: ${token} }"
            echo "      static_configs: [{ targets: ['$(server_public_ip 2>/dev/null || hostname):${new_port}'] }]"
            echo ""
            warn "Plain HTTP: the token is only as private as the network between the two hosts."
            warn "Prefer a private network or a tunnel (WireGuard, Tailscale) when you have one." ;;
        off)
            [[ "$(jq -r '.openmetrics.enabled' <<< "$cfg")" == "true" ]] && _met_ufw delete "$port" "$allow"
            rm -f "$METRICS_NGINX"
            reload_nginx >/dev/null 2>&1 || true
            cfg=$(jq -c '.openmetrics.enabled = false | .openmetrics.token = ""' <<< "$cfg")
            _met_cfg_write "$cfg" || exit 1
            log_action "METRICS OPENMETRICS OFF"
            success "OpenMetrics off — the port is closed and the token revoked" ;;
        token)
            [[ "$(jq -r '.openmetrics.enabled' <<< "$cfg")" == "true" ]] || { error "OpenMetrics is off"; exit 1; }
            if [[ "${ARG_show:-}" == "true" ]]; then echo "$token"; return 0; fi
            token=$(generate_token)
            _met_nginx_write "$port" "$token" "$allow" && reload_nginx >/dev/null 2>&1 || { error "Could not rewrite ${METRICS_NGINX}"; exit 1; }
            cfg=$(jq -c --arg t "$token" '.openmetrics.token = $t' <<< "$cfg")
            _met_cfg_write "$cfg" || exit 1
            log_action "METRICS OPENMETRICS TOKEN ROTATED"
            success "New token: ${token}"
            info "The previous one no longer works — update your Prometheus." ;;
        *) error "Usage: cipi metrics openmetrics [status]|on --allow=IP[,IP] [--port=9273]|off|token [--show]"; exit 1 ;;
    esac
}

_met_cmd_prune() {
    _met_require_db || exit 1
    local before after
    before=$(stat -c '%s' "$METRICS_DB" 2>/dev/null || echo 0)
    { echo "BEGIN;"; METRICS_FORCE_PRUNE=1 _met_rollup_prune_sql "$(date +%s)"; echo "COMMIT;"; } | _met_sql >/dev/null \
        || { error "Prune failed"; exit 1; }
    echo "VACUUM;" | _met_sql >/dev/null 2>&1 || true
    after=$(stat -c '%s' "$METRICS_DB" 2>/dev/null || echo 0)
    success "Pruned to the retention — ${METRICS_DB}: $(( before / 1024 )) KB → $(( after / 1024 )) KB"
}

_met_cmd_reset() {
    parse_args "$@"
    [[ "${ARG_yes:-}" == "true" ]] || { error "This deletes the whole metrics history. Run: cipi metrics reset --yes"; exit 1; }
    rm -f "$METRICS_DB" "${METRICS_DB}-wal" "${METRICS_DB}-shm"
    rm -rf "${METRICS_STATE:?}"
    _met_db_init || true
    log_action "METRICS RESET"
    success "Metrics history deleted — collecting again from the next minute"
}
