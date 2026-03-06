# Changelog

All notable changes to Cipi are documented in this file.

---

## [4.0.8] — 2026-03-06

### Security

- **apps.json isolation**: app users could read other apps' webhook tokens via shared `www-data` group membership. Introduced dedicated `cipi-api` group — only `www-data` (PHP-FPM) belongs to it, so app SSH users can no longer access `/etc/cipi/apps.json`

### Changed

- `ensure_apps_json_api_access()` now creates and uses a `cipi-api` group instead of relying on the `www-data` group directly
- Migration `4.0.8.sh` fixes permissions on existing servers and restarts PHP-FPM to pick up the new group
- API `.env` now defaults to `APP_ENV=production` and `APP_DEBUG=false` on fresh install and upgrade
- MOTD updated to "Easy Laravel Deployments"

---

## [4.0.7] — 2026-03-06

### Added

- **Git provider integration**: `cipi git` — automatic deploy key and webhook configuration for GitHub and GitLab repositories
- **`cipi git github-token <token>`** — save GitHub Personal Access Token for auto-setup
- **`cipi git gitlab-token <token>`** — save GitLab Personal Access Token for auto-setup
- **`cipi git gitlab-url <url>`** — configure self-hosted GitLab instance URL
- **`cipi git remove-github`** — remove stored GitHub token
- **`cipi git remove-gitlab`** — remove stored GitLab token and URL
- **`cipi git status`** — show configured providers, tokens (masked) and per-app integration status
- **Auto-setup on `cipi app create`**: when a GitHub/GitLab token is configured, Cipi automatically adds the deploy key and creates the webhook on the repository — zero manual configuration needed
- **Auto-migrate on `cipi app edit --repository=...`**: when changing repository, Cipi removes deploy key + webhook from the old repo and creates them on the new one
- **Auto-cleanup on `cipi app delete`**: Cipi removes deploy key + webhook from the repository before deleting the app
- New `lib/git.sh` module with GitHub REST API v3 and GitLab REST API v4 integration (deploy keys + webhooks CRUD)
- `apps.json` extended with optional `git_provider`, `git_deploy_key_id`, `git_webhook_id` fields per app
- `server.json` extended on-demand with `github_token`, `gitlab_token`, `gitlab_url` fields

### Changed

- `cipi app show` now displays git provider integration status (provider, deploy key ID, webhook ID)
- `cipi deploy <app> --key` shows "auto-configured" status when deploy key was added via API
- `cipi deploy <app> --webhook` shows "auto-configured" status when webhook was added via API
- `cipi app create` summary adapts: shows "auto-configured" badge when git integration succeeded, or manual instructions with a setup tip when no token is configured
- Graceful fallback: if no token is configured or the API call fails, Cipi falls back to manual setup (existing behavior) without interrupting the flow

---

## [4.0.6] — 2026-03-05

### Added

- **Global API**: `cipi api <domain>` — configure API at root (e.g. api.miohosting.it), no aliases
- **API SSL**: `cipi api ssl` — install Let's Encrypt certificate for API domain
- **API tokens**: `cipi api token list|create|revoke` — manage Sanctum tokens (abilities: apps-view, apps-create, apps-edit, apps-delete, ssl-manage, aliases-view, aliases-create, aliases-delete, mcp-access)
- **REST API** (Bearer token): `GET/POST/PUT/DELETE /api/apps`, `GET/POST/DELETE /api/apps/{name}/aliases`, `POST /api/ssl/{name}`, `GET /api/jobs/{id}`
- **Async job system**: all write operations (create, edit, delete, SSL, alias add/remove) dispatch background jobs via Laravel queue, returning `202 Accepted` with a `job_id` for polling; GET operations remain synchronous
- **Sync validation**: domain uniqueness, app existence, PHP version, username format and domain format validated synchronously before job dispatch (409/404/422 returned immediately)
- **Swagger/OpenAPI docs** at `/docs` — interactive API documentation via Swagger UI (spec v2.0.0)
- **MCP server** at `/mcp` — requires `mcp-access` ability, tools for app/alias/SSL management (async dispatch with job_id)
- **Dedicated PHP-FPM pool** `cipi-api` for the API (isolated from app pools, up to 10 workers)
- **Queue worker** `cipi-queue` systemd service for processing background jobs (auto-restart, 600s timeout)
- **`andreapollastri/cipi-api` Composer package**: all API logic (controllers, services, models, MCP tools, migrations, views, routes) is now a standalone Laravel package, publishable on Packagist — install via `cipi api <domain>` or `composer require andreapollastri/cipi-api`
- **Welcome page** `welcome.blade.php` — dark/light theme landing page served at `/`
- **`cipi api update`** — soft update: `composer update` on all packages (Laravel minor/patch + cipi-api), re-publishes assets and runs migrations
- **`cipi api upgrade`** — full rebuild: fresh `composer create-project laravel/laravel` + `composer require cipi-api`, preserves `.env`, database, SSL certificates and tokens; keeps old version at `/opt/cipi/api.old` for rollback
- **`cipi api status`** — shows current Laravel version, cipi-api version, queue worker status and pending jobs

### Changed

- `cipi app delete <app> --force` — skip confirmation for non-interactive use
- API read endpoints (GET /apps, GET /apps/{name}, GET /aliases) now read directly from `apps.json` instead of invoking CLI
- API install uses `composer create-project laravel/laravel` + `composer require andreapollastri/cipi-api` instead of overlay copy — easier upgrades to future Laravel versions
- **apps.json API access**: when `cipi api <domain>` is run, Cipi automatically configures `/etc/cipi` and `apps.json` so that www-data (PHP-FPM) can read them — no manual `chmod 644` or sudoers rules needed

---

## [4.0.5] — 2026-03-05

### Fixed

- Nginx "conflicting server name" warnings when domains or aliases were duplicated
- `_create_nginx_vhost` now deduplicates domain + aliases before writing `server_name`
- Primary domain excluded from aliases when reading (handles legacy data where primary was added as alias)
- `cipi app create` rejects creation if the domain is already used by another app
- `cipi alias add` rejects adding an alias that equals the primary domain or is already used by another app
- `cipi ssl install` excludes primary domain from aliases when building Certbot `-d` flags

---

## [4.0.4] — 2026-03-05

### Added

- Redis in the default stack — installed with password, bind to localhost only
- `cipi service` now includes `redis-server` (list, restart, start, stop)
- Redis credentials (user, password) saved in `/etc/cipi/server.json` and shown at end of installation
- Migration 4.0.4 for existing servers: installs Redis and adds `redis-server` to unattended-upgrades blacklist

### Changed

- Redis added to unattended-upgrades package blacklist (managed by Cipi, no auto-upgrade)

---

## [4.0.3] — 2026-03-05

### Fixed

- `cipi app logs` now includes Laravel daily logs (`laravel-YYYY-MM-DD.log`) from `shared/storage/logs/`
- Added `--type=laravel` option to tail only Laravel application logs

---

## [4.0.2] — 2026-03-04

### Added

- `cipi deploy <app> --trust-host=<host[:port]>` — trust a custom Git server by scanning and persisting its SSH host key
- Custom Git server support in the deploy workflow (non-GitHub/GitLab repositories)
- `cipi backup prune [app] --weeks=N` — delete S3 backups older than N weeks, per-app or globally

### Fixed

- Installer (`setup.sh`) fix for edge cases during provisioning

### Changed

- Documentation updated to reflect new deploy and backup commands

---

## [4.0.1] — 2026-03-03

### Changed

- Self-update mechanism revised: version check and install script updated
- Installer link updated to new canonical URL (`cipi.sh/setup.sh`)
- README refreshed (condensed, up-to-date command reference)

---

## [4.0.0] — 2026-03-03

Complete rewrite of the Cipi CLI from the ground up.

### Added

- New modular shell architecture: each domain split into its own library (`lib/app.sh`, `lib/deploy.sh`, `lib/db.sh`, `lib/backup.sh`, `lib/ssl.sh`, `lib/php.sh`, `lib/firewall.sh`, `lib/service.sh`, `lib/worker.sh`, `lib/self-update.sh`, `lib/common.sh`)
- `lib/common.sh` — shared helpers: `parse_args`, `validate_*`, `generate_password`, `read_input`, `confirm`, `log_action`, and app registry helpers (`app_exists`, `app_get`, `app_set`, `app_save`, `app_remove`)
- `cipi service list|restart|start|stop` — full service management for nginx, mariadb, supervisor, fail2ban, php-fpm
- `cipi deploy <app> --unlock` — unlock a stuck Deployer process
- `cipi deploy <app> --webhook` — display webhook URL and token
- `cipi deploy <app> --key` — display the SSH deploy public key
- `cipi deploy <app> --releases` — list available releases
- `cipi deploy <app> --rollback` — roll back to the previous release
- `cipi backup configure` — interactive S3 configuration wizard
- `cipi backup run [app]` — run backup for a specific app or all apps
- `cipi backup list [app]` — list S3 backups per-app or globally (supports multiple S3 providers)
- `cipi self-update [--check]` — update Cipi in place; `--check` shows available version without installing
- `cipi app artisan <app> <cmd>` — run arbitrary Artisan commands
- `cipi app tinker <app>` — open Laravel Tinker for an app
- `cipi app logs <app> [--type=nginx|php|worker|deploy|laravel|all]` — tail app logs by type
- PHP 8.4 and 8.5 support
- `lib/cipi-worker` — standalone helper script for queue worker management via sudoers
- Nginx security headers (`X-Frame-Options`, `X-Content-Type-Options`, `Referrer-Policy`) in generated vhosts
- App registry stored as JSON (`/etc/cipi/apps.json`) with full CRUD via `app_save`/`app_remove`
- Structured action logging to `/var/log/cipi`

### Changed

- `cipi app create` now provisions: Linux user, directories, SSH deploy key, MariaDB database, `.env`, PHP-FPM pool, Nginx vhost, Supervisor worker, crontab (scheduler + deploy trigger), Deployer config, sudoers entry
- Deployer recipe uses `recipe/laravel.php` with automatic `artisan:migrate`, `artisan:optimize`, `artisan:storage:link`, `artisan:queue:restart`, and `workers:restart` hooks
- `cipi app edit` supports `--php`, `--branch`, `--repository` flags and updates all affected config files atomically
- `cipi app delete` performs full cleanup: workers, nginx, php-fpm, database, crontab, sudoers, SSL certificate, home directory
- `cipi alias add/remove` regenerates the Nginx vhost and reloads nginx
- `cipi db` commands (`create`, `list`, `delete`, `backup`, `restore`) rewritten with MariaDB-native tooling
- `cipi ssl install` uses Certbot with all aliases included in the certificate SAN
- `cipi php install` manages PHP-FPM installs per version
- `cipi firewall allow/list` wraps `ufw`
- Removed legacy `lib/commands.sh`, `lib/domain.sh`, `lib/nginx.sh`, `lib/database.sh`
- Removed Redis dependency from the default stack

### Fixed

- SSL Certbot integration with multi-domain vhosts
- Worker restart via supervisor with app-scoped naming
- PHP-FPM pool `open_basedir` set correctly per app
- Deploy key `authorized_keys` and `known_hosts` permissions hardened
