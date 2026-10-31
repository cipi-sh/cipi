#!/bin/bash
#############################################
# Cipi — www-data sudoers whitelist for the panel API
#
# sudo-rs (Ubuntu 25.10+) allows '*' only as the final argument token.
# Use "db restore *" (not "db restore * *") for multi-arg commands.
#
# The file exists only while something runs PHP as www-data on behalf of a
# person: the panel API (`cipi api <domain>`) or the GUI (`cipi gui <domain>`).
# Until 5.8.5 setup.sh wrote it on every server; with nothing installed it
# was a dormant path from www-data to root (`cipi ssh add` appends a key to
# the cipi admin user). ensure_cipi_api_sudoers() writes it when a panel is
# installed and removes it otherwise; `cipi api`, `cipi gui`, their `remove`
# and the 5.8.6 migration all go through it.
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
    for pv in 7.4 8.0 8.1 8.2 8.3 8.4 8.5; do
        [[ -f "/etc/php/${pv}/fpm/pool.d/cipi-api.conf" || -f "/etc/php/${pv}/fpm/pool.d/cipi-gui.conf" ]] && return 0
    done
    return 1
}

write_cipi_api_sudoers() {
    cat > /etc/sudoers.d/cipi-api <<'SUDOEOF'
www-data ALL=(root) NOPASSWD: /usr/local/bin/cipi app create *, \
                               /usr/local/bin/cipi app edit *, \
                               /usr/local/bin/cipi app delete *, \
                               /usr/local/bin/cipi app convert *, \
                               /usr/local/bin/cipi app clone *, \
                               /usr/local/bin/cipi app reverb *, \
                               /usr/local/bin/cipi app limits *, \
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
                               /usr/local/bin/cipi node list, \
                               /usr/local/bin/cipi node status *, \
                               /usr/local/bin/cipi node restart *, \
                               /usr/local/bin/cipi ssl install *, \
                               /usr/local/bin/cipi ssl force *, \
                               /usr/local/bin/cipi ssl dns *, \
                               /usr/local/bin/cipi db list, \
                               /usr/local/bin/cipi db list *, \
                               /usr/local/bin/cipi db engines, \
                               /usr/local/bin/cipi db install *, \
                               /usr/local/bin/cipi db default *, \
                               /usr/local/bin/cipi db create *, \
                               /usr/local/bin/cipi db delete *, \
                               /usr/local/bin/cipi db backup *, \
                               /usr/local/bin/cipi db restore *, \
                               /usr/local/bin/cipi db password *, \
                               /usr/local/bin/cipi search status, \
                               /usr/local/bin/cipi search status *, \
                               /usr/local/bin/cipi search list, \
                               /usr/local/bin/cipi search list *, \
                               /usr/local/bin/cipi search enable *, \
                               /usr/local/bin/cipi search disable *, \
                               /usr/local/bin/cipi package list, \
                               /usr/local/bin/cipi package list *, \
                               /usr/local/bin/cipi php list, \
                               /usr/local/bin/cipi php list *, \
                               /usr/local/bin/cipi php install *, \
                               /usr/local/bin/cipi php remove *, \
                               /usr/local/bin/cipi php switch *, \
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
                               /usr/local/bin/cipi monitor list, \
                               /usr/local/bin/cipi monitor list *, \
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
                               /usr/local/bin/cipi-read-app-logs *, \
                               /bin/cat /etc/cipi/apps.json
SUDOEOF
    chmod 440 /etc/sudoers.d/cipi-api 2>/dev/null || true
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
