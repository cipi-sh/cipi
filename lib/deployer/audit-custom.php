
// cipi:deploy-audit — every deploy is recorded by root in /var/log/cipi/deploys.jsonl,
// whatever started it: cipi deploy, the Git webhook, cipi/agent, the panel, or
// `dep deploy` run by hand. runLocally keeps the process chain of whoever ran dep,
// which is how the record tells those apart. It can never fail a deploy.
function cipi_deploy_audit(string $event): void
{
    try {
        runLocally('sudo -n /usr/local/bin/cipi-deploy-audit __CIPI_APP_USER__ ' . $event . ' >/dev/null 2>&1 || true');
    } catch (\Throwable $e) {
    }
}
task('cipi:audit:published', function () { cipi_deploy_audit('published'); });
task('cipi:audit:failed', function () { cipi_deploy_audit('failed'); });
after('deploy', 'cipi:audit:published');
fail('deploy', 'cipi:audit:failed');
