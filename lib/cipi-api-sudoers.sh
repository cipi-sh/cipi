#!/bin/bash
#############################################
# Cipi — www-data sudoers whitelist for the panel API
#
# sudo-rs (Ubuntu 25.10+) allows '*' only as the final argument token.
# Use "db restore *" (not "db restore * *") for multi-arg commands.
#############################################

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
