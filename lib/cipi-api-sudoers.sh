#!/bin/bash
#############################################
# Cipi — www-data sudoers whitelist for the panel API
#
# sudo-rs (Ubuntu 25.10+) allows '*' only as the final argument token.
# Use "db restore *" (not "db restore * *") for multi-arg commands.
#
# 5.18.0 also adds `cipi sync` for the panel's transfer wizard: this server's
# sync key (`pubkey --raw`), whether a target accepts it (`check`), trusting
# and no longer trusting the key of another server (`trust --key=`, `untrust
# --key=`), and the transfer itself (`push … --import --auto-passphrase`: the
# passphrase of the archive is made by the command, for that one transfer, and
# never goes through the API). `export`, `import` and `list` are not here: an
# archive is not left on, or read from, a path the panel names.
#
# 5.18.0 adds the mesh network of Zero Trust (`zt tailscale`, `zt netbird`)
# to the panel's Zero Trust tab: join (`enable`, the key passed as a flag and
# run synchronously, like every other secret), leave (`disable --yes`), the
# two locks and their unlocks, Tailscale SSH on and off. The commands
# themselves hold the line when sudo comes from www-data (lib/zt-mesh.sh):
# --force is ignored; `lock ssh` wants a login sshd accepted over the mesh
# and a node key that cannot expire; `lock http` and `disable` are refused
# when they would cut the panel's own way to this server (--via=<the address
# the API was called from>), and `lock http` when it would close the page of
# the person at a panel that runs here (--client=<the browser's address>):
# the last arguments. Nothing of Cloudflare's side is here: `zt status` only,
# as before.
#
# 5.17.0 adds, for the panel's new pages: the nginx page cache of an app
# (`cache` — list, on, off, ttl, size, clear: every argument is checked by
# the command, none is a path), Valkey per app from the server's page
# (`valkey list --json`, isolate, share, restart and `flush-shared --yes`,
# which refuses while an app still uses the shared instance — --force is not
# here), an Octane app's PHP by its number and its restart (`frankenphp php`,
# `frankenphp restart`), and how notifications read (`notification timezone`,
# `notification server-name`). Not here: `frankenphp use|import`, as before.
#
# 5.15.0 adds the visitor's address behind Cloudflare (`nginx real-ip`) to
# the panel's Firewall tab: its state, on (`cloudflare`), the ranges fetched
# again, off (`off --yes`: the panel asks first, with what `off` warns of).
# Each with its arguments spelled out, nothing after them.
#
# 5.14.0 adds the panel's Firewall tab: one read of UFW, fail2ban and
# CrowdSec (`firewall status --json`), opening a port (`firewall allow`,
# never `deny`), removing what allow made, blocking an address, the fail2ban
# threshold, unbanning, and CrowdSec — enable (a job; the panel passes its
# own address with --allow), disable (--force there only skips the
# question), its allowlist. `firewall` and `crowdsec enable` ignore --force
# when sudo comes from www-data: the ports the server is reached on, the
# Zero Trust locks and CrowdSec's RAM and real_ip checks hold for the panel.
# Not here: `crowdsec rescue` (on-box break-glass) and `crowdsec refresh`.
#
# 5.12.0 adds `cipi notification`: every channel (SMTP, Resend, SES, Slack,
# Discord, Mattermost, Google Chat, Telegram, ntfy, Pushover, webhook) and
# the triggers, read and changed from the panel. Secrets are passed as flags,
# like `smtp configure` always did; the API runs these synchronously, so they
# never reach the panel's jobs table.
#
# 5.10.0 adds `app jit` (JIT per app) and `frankenphp status|upgrade` (the
# FrankenPHP build of Octane apps). Not here: `frankenphp import` (a path on
# the server, for whoever is at its shell) and `frankenphp use`, whose
# --force skips the PHP-minor check.
#
# 5.9.0 adds what the panel's Node, backup and database pages run: Node
# runtimes (install, default, upgrade, remove), the link between a database
# and an app, and the backup profiles — status and archive listings as JSON,
# a run started in the background (--detach comes first on purpose: a plain
# `backup run` would hold the panel's queue worker for as long as it takes),
# verify, and the profiles themselves. Not here, and so not in the panel:
# `backup configure` and `backup destination add|edit|remove` (an S3 secret
# on a command line, which the panel would also keep in its jobs table),
# `backup fetch`, `backup key` and `backup prune`.
#
# 5.18.0 adds SFTP destinations from the panel — `backup sftp add|edit|key|
# test|remove <name> …` (a host, a port, a user, a folder: no secret; Cipi
# makes the key on the server). `backup sftp` touches SFTP destinations only;
# `backup destination add|edit|remove`, which take S3 secrets, stay out.
#
# 5.19.0 lets the panel set up and manage backups whole: `backup configure`
# (the default bucket, or local only), `backup destination add|edit|remove`
# (S3 buckets and SFTP servers), `backup key show --raw` and `key rotate`, and
# `backup prune`. A secret key never rides a command line: from www-data the
# CLI takes it only on standard input (--secret-stdin), which the API writes
# into the command's stdin, in a synchronous call — never a job, never kept,
# never answered back. The folders of `configure` stay the server's: from
# www-data --local-dir and --tmpdir are refused. Still not here: `backup
# fetch` (an archive at a path of the server).
#
# And how Cipi updates itself: `self-update policy` (the signature check and
# the delay; trusting signers takes the fingerprint the person compared).
# Not `self-update` itself: an update is started at the shell or by cron.
#
# The file exists only while something runs PHP as www-data on behalf of a
# person: the panel API (`cipi api <domain>`) or the GUI (`cipi gui <domain>`).
# Until 5.8.5 setup.sh wrote it on every server; with nothing installed it
# was a dormant path from www-data to root (`cipi ssh add` appends a key to
# the cipi admin user). ensure_cipi_api_sudoers() writes it when a panel is
# installed and removes it otherwise; `cipi api`, `cipi gui`, their `remove`
# and the 5.9.0 migration all go through it.
#############################################

# True when the panel API or the GUI is installed, or half-installed: the
# same evidence _api_is_installed / _gui_is_installed look at, so a server
# mid-way through an install or a removal keeps the file. Self-contained on
# purpose — setup.sh and migrations call this before api.sh / gui.sh load.
_cipi_panel_installed() {
    local cfg="${CIPI_CONFIG:-/etc/cipi}" api_root="${CIPI_API_ROOT:-/opt/cipi/api}" gui_root="${CIPI_GUI_ROOT:-/opt/cipi/gui}" pv
    [[ -f "${cfg}/api.json" || -f "${cfg}/gui.json" ]] && return 0
    [[ -f "${api_root}/artisan" || -f "${gui_root}/artisan" ]] && return 0
    [[ -f /etc/nginx/sites-available/cipi-api || -f /etc/nginx/sites-available/cipi-gui ]] && return 0
    [[ -f /etc/systemd/system/cipi-queue.service ]] && return 0
    [[ -f /etc/cron.d/cipi-api || -f /etc/cron.d/cipi-gui ]] && return 0
    for pv in 7.4 8.0 8.1 8.2 8.3 8.4 8.5 8.6; do
        [[ -f "/etc/php/${pv}/fpm/pool.d/cipi-api.conf" || -f "/etc/php/${pv}/fpm/pool.d/cipi-gui.conf" ]] && return 0
    done
    return 1
}

# visudo -c -f <file>: flags apart and without -q, the form both sudo and
# sudo-rs accept. No visudo: nothing to check with.
cipi_sudoers_check() {
    command -v visudo >/dev/null 2>&1 || return 0
    visudo -c -f "$1" >/dev/null 2>&1
}

# Written to a temporary file, checked, then put in place: an invalid
# whitelist never reaches the sudoers directory (where it would break sudo for
# everyone) and the previous one stays. On a refusal visudo's own message
# goes to stderr and the function returns 1.
write_cipi_api_sudoers() {
    local target="/etc/sudoers.d/cipi-api" tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/cipi-api-sudoers.XXXXXX") || return 1
    cat > "$tmp" <<'SUDOEOF'
www-data ALL=(root) NOPASSWD: /usr/local/bin/cipi app create *, \
                               /usr/local/bin/cipi app edit *, \
                               /usr/local/bin/cipi app delete *, \
                               /usr/local/bin/cipi app convert *, \
                               /usr/local/bin/cipi app clone *, \
                               /usr/local/bin/cipi app reverb *, \
                               /usr/local/bin/cipi app limits *, \
                               /usr/local/bin/cipi app jit *, \
                               /usr/local/bin/cipi app logs read *, \
                               /usr/local/bin/cipi app env *, \
                               /usr/local/bin/cipi app artisan *, \
                               /usr/local/bin/cipi app run *, \
                               /usr/local/bin/cipi app deploy-config *, \
                               /usr/local/bin/cipi app suspend *, \
                               /usr/local/bin/cipi app unsuspend *, \
                               /usr/local/bin/cipi auth create *, \
                               /usr/local/bin/cipi auth edit *, \
                               /usr/local/bin/cipi auth show *, \
                               /usr/local/bin/cipi auth delete *, \
                               /usr/local/bin/cipi basicauth enable *, \
                               /usr/local/bin/cipi basicauth disable *, \
                               /usr/local/bin/cipi basicauth status *, \
                               /usr/local/bin/cipi basicauth agent *, \
                               /usr/local/bin/cipi deploy *, \
                               /usr/local/bin/cipi worker horizon *, \
                               /usr/local/bin/cipi schedule *, \
                               /usr/local/bin/cipi health *, \
                               /usr/local/bin/cipi smtp status, \
                               /usr/local/bin/cipi smtp status *, \
                               /usr/local/bin/cipi smtp configure *, \
                               /usr/local/bin/cipi smtp enable, \
                               /usr/local/bin/cipi smtp disable, \
                               /usr/local/bin/cipi smtp test, \
                               /usr/local/bin/cipi smtp delete, \
                               /usr/local/bin/cipi smtp delete *, \
                               /usr/local/bin/cipi notification status --json, \
                               /usr/local/bin/cipi notification triggers --json, \
                               /usr/local/bin/cipi notification triggers set *, \
                               /usr/local/bin/cipi notification triggers enable-all, \
                               /usr/local/bin/cipi notification triggers disable-all, \
                               /usr/local/bin/cipi notification triggers reset, \
                               /usr/local/bin/cipi notification add *, \
                               /usr/local/bin/cipi notification update *, \
                               /usr/local/bin/cipi notification remove *, \
                               /usr/local/bin/cipi notification test *, \
                               /usr/local/bin/cipi notification enable *, \
                               /usr/local/bin/cipi notification disable *, \
                               /usr/local/bin/cipi alias add *, \
                               /usr/local/bin/cipi alias remove *, \
                               /usr/local/bin/cipi www add *, \
                               /usr/local/bin/cipi www force-to-root *, \
                               /usr/local/bin/cipi www force-from-root *, \
                               /usr/local/bin/cipi www clear *, \
                               /usr/local/bin/cipi www status *, \
                               /usr/local/bin/cipi redirect set *, \
                               /usr/local/bin/cipi redirect enable *, \
                               /usr/local/bin/cipi redirect disable *, \
                               /usr/local/bin/cipi redirect unset *, \
                               /usr/local/bin/cipi redirect add *, \
                               /usr/local/bin/cipi redirect remove *, \
                               /usr/local/bin/cipi redirect list *, \
                               /usr/local/bin/cipi proxy add *, \
                               /usr/local/bin/cipi proxy remove *, \
                               /usr/local/bin/cipi proxy list *, \
                               /usr/local/bin/cipi nginx show *, \
                               /usr/local/bin/cipi nginx set *, \
                               /usr/local/bin/cipi nginx reset *, \
                               /usr/local/bin/cipi nginx real-ip status --json, \
                               /usr/local/bin/cipi nginx real-ip cloudflare, \
                               /usr/local/bin/cipi nginx real-ip refresh, \
                               /usr/local/bin/cipi nginx real-ip off --yes, \
                               /usr/local/bin/cipi node list, \
                               /usr/local/bin/cipi node status *, \
                               /usr/local/bin/cipi node restart *, \
                               /usr/local/bin/cipi node install *, \
                               /usr/local/bin/cipi node default *, \
                               /usr/local/bin/cipi node upgrade, \
                               /usr/local/bin/cipi node upgrade *, \
                               /usr/local/bin/cipi node remove *, \
                               /usr/local/bin/cipi ssl install *, \
                               /usr/local/bin/cipi ssl force *, \
                               /usr/local/bin/cipi ssl dns *, \
                               /usr/local/bin/cipi db list, \
                               /usr/local/bin/cipi db list *, \
                               /usr/local/bin/cipi db engines, \
                               /usr/local/bin/cipi db engines --json, \
                               /usr/local/bin/cipi db install *, \
                               /usr/local/bin/cipi db default *, \
                               /usr/local/bin/cipi db create *, \
                               /usr/local/bin/cipi db delete *, \
                               /usr/local/bin/cipi db backup *, \
                               /usr/local/bin/cipi db restore *, \
                               /usr/local/bin/cipi db password *, \
                               /usr/local/bin/cipi db link *, \
                               /usr/local/bin/cipi db unlink *, \
                               /usr/local/bin/cipi backup status --json, \
                               /usr/local/bin/cipi backup list --json, \
                               /usr/local/bin/cipi backup list --json *, \
                               /usr/local/bin/cipi backup run --detach, \
                               /usr/local/bin/cipi backup run --detach *, \
                               /usr/local/bin/cipi backup verify *, \
                               /usr/local/bin/cipi backup profile add *, \
                               /usr/local/bin/cipi backup profile edit *, \
                               /usr/local/bin/cipi backup profile remove *, \
                               /usr/local/bin/cipi backup profile enable *, \
                               /usr/local/bin/cipi backup profile disable *, \
                               /usr/local/bin/cipi backup destination test, \
                               /usr/local/bin/cipi backup destination test *, \
                               /usr/local/bin/cipi backup sftp *, \
                               /usr/local/bin/cipi backup configure *, \
                               /usr/local/bin/cipi backup destination add *, \
                               /usr/local/bin/cipi backup destination edit *, \
                               /usr/local/bin/cipi backup destination remove *, \
                               /usr/local/bin/cipi backup key show --raw, \
                               /usr/local/bin/cipi backup key rotate, \
                               /usr/local/bin/cipi backup prune, \
                               /usr/local/bin/cipi backup prune *, \
                               /usr/local/bin/cipi self-update policy --json, \
                               /usr/local/bin/cipi self-update policy *, \
                               /usr/local/bin/cipi search status, \
                               /usr/local/bin/cipi search status *, \
                               /usr/local/bin/cipi search list, \
                               /usr/local/bin/cipi search list *, \
                               /usr/local/bin/cipi search enable *, \
                               /usr/local/bin/cipi search disable *, \
                               /usr/local/bin/cipi package list, \
                               /usr/local/bin/cipi package list *, \
                               /usr/local/bin/cipi package install *, \
                               /usr/local/bin/cipi package remove *, \
                               /usr/local/bin/cipi php list, \
                               /usr/local/bin/cipi php list *, \
                               /usr/local/bin/cipi php install *, \
                               /usr/local/bin/cipi php remove *, \
                               /usr/local/bin/cipi php switch *, \
                               /usr/local/bin/cipi frankenphp status, \
                               /usr/local/bin/cipi frankenphp status *, \
                               /usr/local/bin/cipi frankenphp upgrade *, \
                               /usr/local/bin/cipi frankenphp php *, \
                               /usr/local/bin/cipi frankenphp restart *, \
                               /usr/local/bin/cipi cache, \
                               /usr/local/bin/cipi cache *, \
                               /usr/local/bin/cipi valkey list --json, \
                               /usr/local/bin/cipi valkey isolate *, \
                               /usr/local/bin/cipi valkey share *, \
                               /usr/local/bin/cipi valkey restart *, \
                               /usr/local/bin/cipi valkey flush-shared --yes, \
                               /usr/local/bin/cipi ssh list, \
                               /usr/local/bin/cipi ssh list *, \
                               /usr/local/bin/cipi ssh add *, \
                               /usr/local/bin/cipi ssh remove *, \
                               /usr/local/bin/cipi service list, \
                               /usr/local/bin/cipi service list *, \
                               /usr/local/bin/cipi service restart *, \
                               /usr/local/bin/cipi status, \
                               /usr/local/bin/cipi zt status, \
                               /usr/local/bin/cipi zt status *, \
                               /usr/local/bin/cipi zt tailscale enable *, \
                               /usr/local/bin/cipi zt tailscale disable --yes, \
                               /usr/local/bin/cipi zt tailscale disable --yes *, \
                               /usr/local/bin/cipi zt tailscale lock ssh --yes, \
                               /usr/local/bin/cipi zt tailscale lock http --yes, \
                               /usr/local/bin/cipi zt tailscale lock http --yes *, \
                               /usr/local/bin/cipi zt tailscale unlock ssh, \
                               /usr/local/bin/cipi zt tailscale unlock http, \
                               /usr/local/bin/cipi zt tailscale ssh enable, \
                               /usr/local/bin/cipi zt tailscale ssh disable, \
                               /usr/local/bin/cipi zt netbird enable *, \
                               /usr/local/bin/cipi zt netbird disable --yes, \
                               /usr/local/bin/cipi zt netbird disable --yes *, \
                               /usr/local/bin/cipi zt netbird lock ssh --yes, \
                               /usr/local/bin/cipi zt netbird lock http --yes, \
                               /usr/local/bin/cipi zt netbird lock http --yes *, \
                               /usr/local/bin/cipi zt netbird unlock ssh, \
                               /usr/local/bin/cipi zt netbird unlock http, \
                               /usr/local/bin/cipi sync pubkey --raw, \
                               /usr/local/bin/cipi sync check *, \
                               /usr/local/bin/cipi sync trust *, \
                               /usr/local/bin/cipi sync untrust *, \
                               /usr/local/bin/cipi sync push *, \
                               /usr/local/bin/cipi monitor list, \
                               /usr/local/bin/cipi monitor list *, \
                               /usr/local/bin/cipi metrics overview *, \
                               /usr/local/bin/cipi metrics status *, \
                               /usr/local/bin/cipi metrics show *, \
                               /usr/local/bin/cipi metrics uptime *, \
                               /usr/local/bin/cipi metrics events *, \
                               /usr/local/bin/cipi metrics retention *, \
                               /usr/local/bin/cipi metrics probe *, \
                               /usr/local/bin/cipi metrics enable, \
                               /usr/local/bin/cipi metrics disable, \
                               /usr/local/bin/cipi metrics heartbeat *, \
                               /usr/local/bin/cipi disk, \
                               /usr/local/bin/cipi disk *, \
                               /usr/local/bin/cipi yml plan *, \
                               /usr/local/bin/cipi yml apply *, \
                               /usr/local/bin/cipi yml auto *, \
                               /usr/local/bin/cipi app webhook recreate *, \
                               /usr/local/bin/cipi app fix-permissions, \
                               /usr/local/bin/cipi app fix-permissions *, \
                               /usr/local/bin/cipi api ip-whitelist, \
                               /usr/local/bin/cipi api ip-whitelist *, \
                               /usr/local/bin/cipi firewall status --json, \
                               /usr/local/bin/cipi firewall allow *, \
                               /usr/local/bin/cipi firewall remove *, \
                               /usr/local/bin/cipi firewall block *, \
                               /usr/local/bin/cipi firewall unblock *, \
                               /usr/local/bin/cipi firewall attempts *, \
                               /usr/local/bin/cipi ban unban *, \
                               /usr/local/bin/cipi crowdsec enable, \
                               /usr/local/bin/cipi crowdsec enable *, \
                               /usr/local/bin/cipi crowdsec disable --force, \
                               /usr/local/bin/cipi crowdsec allow *, \
                               /usr/local/bin/cipi crowdsec unallow *, \
                               /usr/local/bin/cipi notification timezone *, \
                               /usr/local/bin/cipi notification server-name *, \
                               /usr/local/bin/cipi-read-app-logs *, \
                               /bin/cat /etc/cipi/apps.json
SUDOEOF
    # One rule per 40 commands: sudo-rs (Ubuntu 26.04: 0.2.13) refuses a list
    # of more than about 127 items ("too many items in list"), and the single
    # rule passed that in 5.11.0. sudo reads several rules exactly as one.
    awk -v per=40 '
        { line = $0; sub(/^www-data ALL=\(root\) NOPASSWD: */, "", line); sub(/^[[:space:]]+/, "", line)
          sub(/,[[:space:]]*\\[[:space:]]*$/, "", line); sub(/[[:space:]]+$/, "", line)
          if (line != "") cmd[++n] = line }
        END {
            for (i = 1; i <= n; i++) {
                first = ((i - 1) % per == 0); last = (i % per == 0 || i == n)
                printf "%s%s%s\n", (first ? "www-data ALL=(root) NOPASSWD: " : "                               "), cmd[i], (last ? "" : ", \\")
            }
        }' "$tmp" > "${tmp}.rules" && mv -f "${tmp}.rules" "$tmp"
    chmod 440 "$tmp" 2>/dev/null || true
    if ! cipi_sudoers_check "$tmp"; then
        echo "  ${target} not updated — visudo refused the new whitelist:" >&2
        visudo -c -f "$tmp" 2>&1 | head -5 | sed 's/^/    /' >&2
        rm -f "$tmp"
        return 1
    fi
    install -m 0440 "$tmp" "$target" 2>/dev/null || { cat "$tmp" > "$target" && chmod 440 "$target"; } || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    return 0
}

# Write the whitelist when a panel is installed, remove it when none is.
# Idempotent and best-effort: never fails the caller. Prints one line
# only when something changed, so setup, install and migrations can show it.
ensure_cipi_api_sudoers() {
    if _cipi_panel_installed; then
        write_cipi_api_sudoers || return 0
    elif [[ -f /etc/sudoers.d/cipi-api ]]; then
        rm -f /etc/sudoers.d/cipi-api 2>/dev/null || return 0
        echo "  /etc/sudoers.d/cipi-api removed (no panel API or GUI installed)"
    fi
    return 0
}
