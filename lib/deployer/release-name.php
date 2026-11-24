
// cipi:release-name — a release is never named at or below one already in releases/.
// Deployer 7 and 8 number a release from .dep/latest_release; Deployer 6 kept its
// own list (.dep/releases) and never wrote that file. On the servers that went from
// Deployer 6 to 8 with Cipi 5.10.0 the first deploy started again at 1, next to the
// old releases, and a later one stopped at "Release name "N" already exists".
set('release_name', function () {
    return within('{{deploy_path}}', function () {
        $latest = intval(run('cat .dep/latest_release 2>/dev/null || echo 0'));
        $highest = intval(run('ls -1 releases 2>/dev/null | grep -x "[0-9][0-9]*" | sort -n | tail -n 1'));
        return strval(max($latest, $highest) + 1);
    });
});
