#!/bin/bash
# Local regression checks for 5.11.0: metrics & health history, and cipi/agent
# behind basic auth.
#
# The metrics library runs against a fake root: every path it uses is one of
# its METRICS_* variables, pointed under the temp dir; apps.json and the
# vault key are temp files. /proc is the real one (read only). curl answers
# from a stub in front of PATH. The database checks need the sqlite3 CLI and
# are skipped without it.
#
#   - schema: wide tables, a column a later version adds is added in place
#   - the collector: host and app rows, requests and 5xx from an access log
#     (first sight, new lines, rotation), max_children hits from an FPM log,
#     the probe and its incidents (third failure opens, success closes),
#     the heartbeat and its events, the OpenMetrics file
#   - rollups and prune against the retention; retention validation
#   - queries: series from raw minutes and from rollups, uptime, events,
#     overview JSON, status JSON without secrets
#   - cipi/agent behind basic auth: the prefix (default, CIPI_ROUTE_PREFIX,
#     refused values, a proxy on it, protected), the location blocks, the
#     marker the deploy check reads
#   - migration 5.11.0 parses; sudoers carry the read and settings commands
#     and not openmetrics
#
# Not here, because it needs a real server: nginx -t on the vhost, Supervisor,
# UFW, and cron.
# Run from repo root: bash tests/verify-5.11.0.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="${ROOT}/lib"
PASS=0
FAIL=0
SKIP=0
pass() { echo "  OK: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
skip() { echo "  SKIP: $*"; SKIP=$((SKIP + 1)); }

TMP=$(mktemp -d) && [[ -n "$TMP" && -d "$TMP" ]] || { echo "mktemp -d failed" >&2; exit 1; }
trap 'rm -rf "${TMP:?}"' EXIT

echo "=== Cipi 5.11.0 regression checks ==="

# ── 0. release files, static ─────────────────────────────────
[[ "$(tr -d '[:space:]' < "${ROOT}/version.md")" == "5.11.0" ]] && pass "version.md is 5.11.0" || fail "version.md"
grep -q '^## \[5.11.0\]' "${ROOT}/CHANGELOG.md" && pass "CHANGELOG has a 5.11.0 entry" || fail "CHANGELOG 5.11.0"
for f in metrics.sh cipi-metrics.sh app.sh deploy.sh monitor.sh health.sh completion.sh cipi-api-sudoers.sh self-update.sh migrations/5.11.0.sh; do
    bash -n "${LIB}/${f}" && pass "${f} parses" || fail "${f} does not parse"
done
bash -n "${ROOT}/cipi" && pass "cipi parses" || fail "cipi does not parse"
bash -n "${ROOT}/setup.sh" && pass "setup.sh parses" || fail "setup.sh does not parse"
grep -q 'metrics)    _maybe_cmd_help metrics' "${ROOT}/cipi" && pass "cipi dispatches metrics" || fail "dispatcher"
grep -q 'cipi-metrics.sh /usr/local/bin/cipi-metrics' "${ROOT}/setup.sh" && grep -q '/etc/cron.d/cipi-metrics' "${ROOT}/setup.sh" \
    && pass "setup.sh installs the collector and its cron" || fail "setup.sh collector"
grep -q 'sqlite3$' "${ROOT}/setup.sh" && pass "setup.sh installs sqlite3" || fail "setup.sh sqlite3"
grep -q 'cipi-metrics.sh" /usr/local/bin/cipi-metrics' "${LIB}/self-update.sh" && pass "self-update refreshes the collector" || fail "self-update"
S="${LIB}/cipi-api-sudoers.sh"
for c in "metrics overview \*" "metrics status \*" "metrics show \*" "metrics uptime \*" "metrics events \*" "metrics retention \*" "metrics heartbeat \*" "basicauth agent \*"; do
    grep -q "/usr/local/bin/cipi ${c}," "$S" && pass "sudoers: cipi ${c//\\/}" || fail "sudoers: cipi ${c//\\/}"
done
grep -q 'metrics openmetrics\|metrics reset\|metrics prune' "$S" && fail "sudoers must not allow openmetrics/reset/prune" || pass "sudoers: no openmetrics, reset or prune"

# ── fake root ────────────────────────────────────────────────
F="${TMP}/root"
mkdir -p "${F}/etc" "${F}/log" "${F}/applogs/shop1" "${F}/applogs/blog1" "${F}/php/8.4/fpm/pool.d" "${F}/bin"
openssl rand -hex 16 > "${F}/etc/.vault_key"
cat > "${F}/etc/apps.json" <<'EOF'
{"shop1":{"domain":"shop.test","php":"8.4","health_url":"http://shop.test/up","health_expect":"200"},
 "blog1":{"domain":"blog.test","php":"8.4","health_url":"http://blog.test/up","health_expect":"200"}}
EOF
printf 'pm.max_children = 12\n' > "${F}/php/8.4/fpm/pool.d/shop1.conf"
# curl: the healthchecks answer from files, the heartbeat from a file.
cat > "${F}/bin/curl" <<'EOF'
#!/bin/bash
url="${@: -1}"
case "$url" in
  http://shop.test/up) printf '200 0.042' ;;
  http://blog.test/up) printf '%s 0.010' "$(cat "${FAKE_ROOT}/blog.code" 2>/dev/null || echo 503)" ;;
  https://hb.test/*)   printf '%s' "$(cat "${FAKE_ROOT}/hb.code" 2>/dev/null || echo 200)"; echo "$url" >> "${FAKE_ROOT}/hb.calls" ;;
  *) printf '000' ;;
esac
EOF
chmod +x "${F}/bin/curl"
cat > "${F}/bin/supervisorctl" <<'EOF'
#!/bin/bash
echo "shop1-worker-default:shop1-worker-default_00   RUNNING   pid 1, uptime 1:00:00"
echo "shop1-worker-default:shop1-worker-default_01   FATAL     Exited too quickly"
EOF
chmod +x "${F}/bin/supervisorctl"

run() {   # bash with the libraries loaded against the fake root
    env PATH="${F}/bin:${PATH}" FAKE_ROOT="$F" CIPI_LIB="$LIB" CIPI_CONFIG="${F}/etc" CIPI_LOG="${F}/log" \
        METRICS_DIR="${F}/m" METRICS_CRON="${F}/cron.metrics" METRICS_HELPER="${F}/cipi-metrics" \
        METRICS_NGINX="${F}/nginx-metrics.conf" METRICS_APP_LOGS="${F}/applogs" METRICS_FPM_POOLS="${F}/php" \
        bash -c 'RED="" GREEN="" YELLOW="" CYAN="" DIM="" NC="" BOLD=""
                 source "$CIPI_LIB/common.sh"; source "$CIPI_LIB/metrics.sh"; set -uo pipefail; '"$1"
}

# ── 1. pure helpers ──────────────────────────────────────────
[[ "$(run '_met_range_sec 90m; _met_range_sec 24h; _met_range_sec 7d' | tr '\n' ' ')" == "5400 86400 604800 " ]] && pass "ranges" || fail "ranges"
run '_met_range_sec 0d || echo bad; _met_range_sec 3w || echo bad' | grep -c bad | grep -q 2 && pass "bad ranges refused" || fail "bad ranges"
[[ "$(run '_met_step_for 3600 60; _met_step_for 86400 60; _met_step_for 2592000 900' | tr '\n' ' ')" == "60 600 10800 " ]] && pass "steps" || fail "steps: $(run '_met_step_for 3600 60; _met_step_for 86400 60; _met_step_for 2592000 900' | tr '\n' ' ')"
[[ "$(run '_met_valid_metrics app "cpu,nope,http_5xx"')" == "cpu http_5xx" ]] && pass "unknown metrics dropped" || fail "valid metrics"
[[ "$(run '_met_url_host "https://user:pw@hc-ping.com/abcd-uuid?x=1"')" == "hc-ping.com" ]] && pass "URL reduced to its host" || fail "url host"
[[ "$(run '_met_retention')" == "7 30 15 90" ]] && pass "default retention 7d / 30d / 15m / 90d" || fail "default retention"
run 'echo "{\"retention\":{\"raw_days\":0,\"rollup_days\":2,\"resolution_minutes\":7,\"events_days\":1}}" | vault_write metrics.json; _met_retention' \
    | grep -qx "7 30 15 90" && pass "a hand-edited retention out of range falls back" || fail "retention fallback"
rm -f "${F}/etc/metrics.json"
printf 'host cpu 12.5\napp:shop1 req 30\napp:shop1 http_5xx 2\napp:x;drop cpu 1\nhost evil 1\nhost cpu 1;DROP\n' \
    | run '_met_rows_to_sql 1700000040' > "${TMP}/rows.sql"
grep -q "INSERT INTO samples (scope, ts, cpu) VALUES ('host', 1700000040, 12.5)" "${TMP}/rows.sql" \
    && grep -q "'app:shop1', 1700000040, 30, 2" "${TMP}/rows.sql" && pass "rows become one upsert per scope" || fail "rows to sql: $(cat "${TMP}/rows.sql")"
grep -q 'drop\|evil\|DROP' "${TMP}/rows.sql" && fail "unknown scope/metric/value reached SQL" || pass "unknown scope, metric or value never reaches SQL"
printf '1.2.3.4 - - [x] "GET / HTTP/1.1" 200 5 "-" "a"\n1.2.3.4 - - [x] "GET /a HTTP/1.1" 502 5 "-" "a"\n1.2.3.4 - - [x] "GET /b HTTP/2.0" 500 5 "-" "a"\n' \
    | run '_met_count_requests' | grep -qx "3 2" && pass "requests and 5xx counted" || fail "count requests"

if ! command -v sqlite3 >/dev/null 2>&1; then
    skip "sqlite3 CLI not installed: database checks skipped"
else
# ── 2. schema ────────────────────────────────────────────────
run '_met_db_init' && pass "database created" || fail "db init"
cols=$(sqlite3 "${F}/m/metrics.db" "SELECT group_concat(name, ' ') FROM pragma_table_info('samples');")
[[ "$cols" == *"cpu"* && "$cols" == *"http_5xx"* && "$cols" == *"workers_total"* ]] && pass "samples has one column per metric" || fail "samples columns: $cols"
sqlite3 "${F}/m/metrics.db" "ALTER TABLE samples DROP COLUMN workers_total;" 2>/dev/null
run '_met_db_init' && sqlite3 "${F}/m/metrics.db" "SELECT name FROM pragma_table_info('samples');" | grep -qx workers_total \
    && pass "a column missing from an existing database is added" || fail "column migration"
[[ "$(stat -c '%a' "${F}/m/metrics.db")" == "600" ]] && pass "database is 0600" || fail "db mode"

# ── 3. collector ─────────────────────────────────────────────
echo 503 > "${F}/blog.code"
run 'metrics_collect' && pass "first run" || fail "first run"
n=$(sqlite3 "${F}/m/metrics.db" "SELECT COUNT(*) FROM samples;")
[[ "$n" == 3 ]] && pass "one row per scope (host + 2 apps)" || fail "rows after first run: $n"
sqlite3 "${F}/m/metrics.db" "SELECT http_code, http_ok, http_ms FROM samples WHERE scope = 'app:shop1';" | grep -qx "200.0|1.0|42.0" \
    && pass "probe: status, ok, time" || fail "probe shop1: $(sqlite3 "${F}/m/metrics.db" "SELECT http_code, http_ok, http_ms FROM samples WHERE scope = 'app:shop1';")"
sqlite3 "${F}/m/metrics.db" "SELECT workers_up, workers_total, fpm_max FROM samples WHERE scope = 'app:shop1';" | grep -qx "1.0|2.0|12.0" \
    && pass "workers up/total and pm.max_children" || fail "workers/fpm_max"
sqlite3 "${F}/m/metrics.db" "SELECT req FROM samples WHERE scope = 'app:shop1';" | grep -q . && fail "req counted on first sight of the log" || pass "no request count before the log has been seen"

# second minute: new log lines, a max_children hit
for i in $(seq 1 7); do echo '1.1.1.1 - - [x] "GET / HTTP/1.1" 200 1 "-" "a"' >> "${F}/applogs/shop1/nginx-access.log"; done
run 'metrics_collect'
for i in $(seq 1 5); do echo '1.1.1.1 - - [x] "GET / HTTP/1.1" 200 1 "-" "a"' >> "${F}/applogs/shop1/nginx-access.log"; done
echo '1.1.1.1 - - [x] "GET /x HTTP/1.1" 503 1 "-" "a"' >> "${F}/applogs/shop1/nginx-access.log"
sqlite3 "${F}/m/metrics.db" "UPDATE samples SET ts = ts - 120;"   # make room: the next run is "a minute later"
run 'metrics_collect'
sqlite3 "${F}/m/metrics.db" "SELECT req, http_5xx FROM samples WHERE scope = 'app:shop1' ORDER BY ts DESC LIMIT 1;" | grep -qx "6.0|1.0" \
    && pass "only the new lines are counted (6 requests, 1 5xx)" || fail "incremental log: $(sqlite3 "${F}/m/metrics.db" "SELECT ts, req, http_5xx FROM samples WHERE scope = 'app:shop1' ORDER BY ts;" | tr '\n' ' ')"
mv "${F}/applogs/shop1/nginx-access.log" "${F}/applogs/shop1/nginx-access.log.1"
for i in 1 2; do echo '1.1.1.1 - - [x] "GET / HTTP/1.1" 200 1 "-" "a"' >> "${F}/applogs/shop1/nginx-access.log"; done
sqlite3 "${F}/m/metrics.db" "UPDATE samples SET ts = ts - 120;"
run 'metrics_collect'
sqlite3 "${F}/m/metrics.db" "SELECT req FROM samples WHERE scope = 'app:shop1' ORDER BY ts DESC LIMIT 1;" | grep -qx "2.0" \
    && pass "after logrotate the new file is read from its start" || fail "rotation"

# incidents: blog1 has failed 4 times now → one 'crit' event; then it recovers
ev=$(sqlite3 "${F}/m/metrics.db" "SELECT status || ':' || summary FROM events WHERE source = 'health' AND subject = 'blog1';")
[[ "$(grep -c '^crit:' <<< "$ev")" == 1 && "$ev" == *"3 checks in a row"* ]] && pass "an incident opens at the third failure, once" || fail "incident open: $ev"
echo 200 > "${F}/blog.code"
sqlite3 "${F}/m/metrics.db" "UPDATE samples SET ts = ts - 120;"
run 'metrics_collect'
sqlite3 "${F}/m/metrics.db" "SELECT summary FROM events WHERE source = 'health' AND subject = 'blog1' AND status = 'ok';" | grep -q 'back up' \
    && pass "the first success closes it" || fail "incident close"

# OpenMetrics file
grep -q '^cipi_app_requests_per_minute{app="shop1"} ' "${F}/m/metrics.prom" && grep -q '^cipi_host_memory_percent ' "${F}/m/metrics.prom" \
    && grep -q '^# TYPE cipi_app_healthcheck_up gauge' "${F}/m/metrics.prom" && pass "OpenMetrics file written with units in the names" || fail "prom file"
[[ "$(stat -c '%a' "${F}/m/metrics.prom")" == "640" ]] && pass "OpenMetrics file 0640" || fail "prom mode"

# heartbeat
run 'echo "{\"heartbeat\":{\"enabled\":true,\"url\":\"https://hb.test/ping/secret-uuid\",\"every\":1}}" | vault_write metrics.json'
echo 500 > "${F}/hb.code"
sqlite3 "${F}/m/metrics.db" "UPDATE samples SET ts = ts - 120;"
run 'metrics_collect'
[[ -s "${F}/hb.calls" ]] && pass "heartbeat called" || fail "heartbeat not called"
sqlite3 "${F}/m/metrics.db" "SELECT status FROM events WHERE source = 'heartbeat';" | grep -qx warn && pass "a failed call is an event" || fail "heartbeat event"
echo 200 > "${F}/hb.code"
sqlite3 "${F}/m/metrics.db" "UPDATE samples SET ts = ts - 120;"
run 'metrics_collect'
[[ "$(sqlite3 "${F}/m/metrics.db" "SELECT COUNT(*) FROM events WHERE source = 'heartbeat';")" == 2 ]] && pass "…and so is the first call that works again" || fail "heartbeat recovery"
st=$(run '_met_cmd_status_json')
jq -e '.heartbeat.url_host == "hb.test" and .heartbeat.url_set and .heartbeat.last_ok' >/dev/null <<< "$st" && pass "status: heartbeat by host" || fail "status heartbeat: $st"
grep -q 'secret-uuid' <<< "$st" && fail "status --json leaks the heartbeat URL" || pass "status --json does not carry the URL"
rm -f "${F}/etc/metrics.json"

# ── 4. rollups, prune, queries ───────────────────────────────
now=$(date +%s); start=$(( (now - 40 * 86400) / 60 * 60 ))
sqlite3 "${F}/m/metrics.db" <<SQL
WITH RECURSIVE t(ts) AS (SELECT ${start} UNION ALL SELECT ts + 60 FROM t WHERE ts < ${now} - 3600)
INSERT OR IGNORE INTO samples (scope, ts, cpu, http_ok, http_ms)
    SELECT 'app:shop1', ts, 10 + (ts / 60) % 5, CASE WHEN ts % 86400 < 600 THEN 0 ELSE 1 END, 100 FROM t;
DELETE FROM meta WHERE k = 'rolled_until';
SQL
run 'METRICS_FORCE_PRUNE=1 metrics_collect' >/dev/null
old=$(sqlite3 "${F}/m/metrics.db" "SELECT COUNT(*) FROM samples WHERE ts < ${now} - 7 * 86400 - 120;")
[[ "$old" == 0 ]] && pass "raw minutes older than 7 days pruned" || fail "raw prune: $old left"
rmin=$(sqlite3 "${F}/m/metrics.db" "SELECT MIN(ts) FROM rollups;")
(( rmin >= now - 30 * 86400 - 900 )) && pass "rollups older than 30 days pruned" || fail "rollup prune: $rmin"
step=$(sqlite3 "${F}/m/metrics.db" "SELECT ts FROM rollups WHERE scope = 'app:shop1' ORDER BY ts LIMIT 1;")
(( step % 900 == 0 )) && pass "rollups on 15-minute boundaries" || fail "rollup boundary"
j=$(run '_met_series_json app:shop1 "cpu http_ms" $(( $(date +%s) - 86400 )) $(date +%s)')
jq -e '.source == "raw" and .step == 600 and (.series.cpu | length) > 100 and (.series.cpu[0] | length) == 3' >/dev/null <<< "$j" \
    && pass "24h series from the raw minutes, ~240 points" || fail "24h series: $(jq -c '{source,step,n:(.series.cpu|length)}' <<< "$j")"
j=$(run '_met_series_json app:shop1 "cpu" $(( $(date +%s) - 30 * 86400 )) $(date +%s)')
jq -e '.source == "rollup" and .step >= 900 and (.series.cpu | length) > 100' >/dev/null <<< "$j" \
    && pass "30d series from the rollups" || fail "30d series: $(jq -c '{source,step,n:(.series.cpu|length)}' <<< "$j")"
u=$(run '_met_app_uptime_json shop1 $(( 30 * 86400 ))')
jq -e '.uptime > 99 and .uptime < 99.5 and .checks > 40000 and (.days | length) >= 30 and .avg_ms != null' >/dev/null <<< "$u" \
    && pass "30-day uptime from rollups + recent minutes ($(jq -r .uptime <<< "$u")%)" || fail "uptime: $(jq -c 'del(.days,.events)' <<< "$u")"
o=$(run 'metrics_overview_json')
jq -e '(.apps | map(.app) | sort) == ["blog1", "shop1"] and (.apps[] | select(.app == "shop1") | .uptime["30d"]) != null and (.events | length) > 0 and .host.values.mem != null' >/dev/null <<< "$o" \
    && pass "overview JSON" || fail "overview: $(jq -c '{apps:(.apps|map(.app)), h:.host.values}' <<< "$o")"
run 'parse_args --raw=10d --rollup=5d; _met_cmd_retention --raw=10d --rollup=5d' >/dev/null 2>&1 && fail "rollup shorter than raw accepted" || pass "rollup shorter than raw refused"
run '_met_cmd_retention --raw=3d --rollup=60d --resolution=30m --events=120d' >/dev/null 2>&1
[[ "$(run '_met_retention')" == "3 60 30 120" ]] && pass "retention set from the CLI" || fail "retention set: $(run '_met_retention')"
run '_met_cmd_retention --resolution=7m' >/dev/null 2>&1 && fail "resolution 7m accepted" || pass "resolution limited to 5/10/15/30/60"
fi

# ── 5. cipi/agent behind basic auth ──────────────────────────
# app.sh with /home, /etc/nginx and the log directory moved into the fake root.
A="${TMP}/app.sh"
sed -e "s|/home/|${F}/home/|g" -e "s|/etc/nginx/|${F}/nginx/|g" -e "s|/var/log/cipi-apps|${F}/applogs|g" "${LIB}/app.sh" > "$A"
mkdir -p "${F}/home/shop1/current/vendor/cipi/agent" "${F}/home/shop1/shared" "${F}/nginx/sites-available" "${F}/nginx/cipi-basicauth"
echo '{}' > "${F}/home/shop1/current/vendor/cipi/agent/composer.json"
echo 'admin:$apr1$x$y' > "${F}/nginx/cipi-basicauth/shop1.htpasswd"
run "source '$A'; app_set shop1 basic_auth true" >/dev/null 2>&1
ba() { run "source '$A'; source '${LIB}/routes.sh'; app_log_links_default() { :; }; $1" 2>/dev/null; }
[[ "$(ba '_basicauth_agent_prefix shop1')" == "cipi" ]] && pass "agent prefix: cipi by default" || fail "default prefix"
echo 'CIPI_ROUTE_PREFIX="/hooks/agent/"' > "${F}/home/shop1/shared/.env"
[[ "$(ba '_basicauth_agent_prefix shop1')" == "hooks/agent" ]] && pass "agent prefix from CIPI_ROUTE_PREFIX" || fail "env prefix"
echo 'CIPI_ROUTE_PREFIX=a;b' > "${F}/home/shop1/shared/.env"
ba '_basicauth_agent_prefix shop1' | grep -q . && fail "a prefix with ; accepted" || pass "a prefix that is not plain path segments is refused"
echo 'CIPI_ROUTE_PREFIX=cipi' > "${F}/home/shop1/shared/.env"
ba '_create_nginx_vhost_http shop1 shop.test 8.4'
V="${F}/nginx/sites-available/shop1"
grep -q 'cipi-agent-public:/cipi/' "$V" && grep -q 'location ^~ /cipi/ {' "$V" && pass "vhost leaves /cipi/ out" || fail "vhost agent location"
awk '/location \^~ \/cipi\/ \{/,/^    \}/' "$V" > "${TMP}/loc"
grep -q 'auth_basic off;' "${TMP}/loc" && grep -q 'rewrite ^ /index.php break;' "${TMP}/loc" && ! grep -q 'auth_basic_user_file' "${TMP}/loc" \
    && pass "the agent location has no basic auth and stays in place" || fail "agent location body: $(cat "${TMP}/loc")"
[[ "$(grep -c 'auth_basic_user_file' "$V")" == 2 ]] && pass "the rest of the app is still protected" || fail "other locations"
grep -q '^    location / {' "$V" && pass "next location on its own line" || fail "newline after agent block"
[[ "$(ba '_basicauth_agent_in_vhost shop1')" == "cipi" ]] && pass "the deploy check reads the marker" || fail "marker"
ba 'app_set shop1 basic_auth_agent protected; _create_nginx_vhost_http shop1 shop.test 8.4'
grep -q 'cipi-agent' "$V" && fail "protected still leaves the agent out" || pass "protected: the agent stays behind basic auth"
ba 'app_unset shop1 basic_auth_agent; app_set_json shop1 proxies "[{\"prefix\":\"/cipi/\",\"upstream\":\"http://127.0.0.1:9\"}]"'
ba '_basicauth_agent_prefix shop1' | grep -q . && fail "prefix owned by a proxy" || pass "not when a proxy owns the prefix"
ba 'app_set_json shop1 proxies "[]"'
rm -rf "${F}/home/shop1/current/vendor/cipi"
ba '_basicauth_agent_prefix shop1' | grep -q . && fail "prefix without the agent" || pass "nothing left out without cipi/agent in the live release"
ba 'app_set shop1 basic_auth false; _create_nginx_vhost_http shop1 shop.test 8.4'
grep -q 'auth_basic\|cipi-agent' "$V" && fail "basic auth off still writes auth" || pass "basic auth off: no auth, no agent block"

echo ""
echo "=== ${PASS} passed, ${FAIL} failed, ${SKIP} skipped ==="
[[ $FAIL -eq 0 ]]
