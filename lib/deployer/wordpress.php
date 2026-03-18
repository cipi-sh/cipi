<?php
namespace Deployer;
require 'recipe/wordpress.php';

set('application', '__CIPI_APP_USER__');
set('repository', '__CIPI_REPOSITORY__');
set('branch', '__CIPI_BRANCH__');
set('deploy_path', '__CIPI_DEPLOY_PATH__');
set('keep_releases', 5);
set('git_ssh_command', 'ssh -i __CIPI_DEPLOY_PATH__/.ssh/id_ed25519 -o StrictHostKeyChecking=accept-new');
set('bin/php', '/usr/bin/php__CIPI_PHP_VERSION__');
set('writable_mode', 'chmod');

// Override recipe defaults: share whole wp-content (not wp-content/uploads only) to avoid conflict
set('shared_files', ['wp-config.php']);
set('shared_dirs', ['wp-content']);
set('writable_dirs', ['wp-content', 'wp-content/uploads']);

// WordPress: no composer in repo root — skip deploy:vendors
task('deploy:vendors', function () {});

host('localhost')
    ->set('remote_user', '__CIPI_APP_USER__')
    ->set('deploy_path', '__CIPI_DEPLOY_PATH__')
    ->set('ssh_arguments', ['-o StrictHostKeyChecking=accept-new', '-i __CIPI_DEPLOY_PATH__/.ssh/id_ed25519']);
