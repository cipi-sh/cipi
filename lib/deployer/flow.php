
// cipi:deploy-flow — each step once. The `deploy` task of recipe/laravel.php runs
// artisan:storage:link, artisan:optimize (Deployer 7: the config, route, view and
// event caches) and artisan:migrate after deploy:vendors by itself. The hooks above
// run the same three, so every deploy linked the storage, optimized and migrated
// twice — and a step turned off with `cipi app deploy-config` (--no-migrate) still
// ran once, from the recipe. From here the list is Cipi's: after the vendors only
// the hooks run, each as the app's deploy-config says.
task('deploy', array_values(array_filter([
    'deploy:prepare',
    'deploy:vendors',
    'deploy:publish',
    Deployer::get()->tasks->has('artisan:reload') ? 'artisan:reload' : null,
])));
