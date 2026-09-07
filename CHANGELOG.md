# Changelog

All notable changes to Cipi are documented in this file.

---

## [5.1.3] — 2026-09-07

A hotfix for `cipi ini list`: the table header printed, then the command died on the first setting.

### Fixed

- **`cipi ini list` crashed with `_INI_SOURCE: unbound variable`.** `_ini_effective` recorded which layer a value came from by assigning a global, then the caller captured the value with `val=$(_ini_effective …)`. Command substitution runs in a subshell, so the assignment never reached the parent, and `set -u` killed the process on the first catalog key — after printing the "SETTING / VALUE / SET BY" header and nothing else. The function now sets `_INI_VALUE` and `_INI_SOURCE` in the current shell; `list`, `get` and the companion-limit cascade all read those directly. **No migration:** the next `cipi self-update` copies the new `lib/ini.sh` and that is the whole fix.
- **A regression test now fails if this class of bug returns.** `tests/verify-5.1.3.sh` walks the full catalog under `set -u` and refuses a `$(_ini_effective)` call site.

---

## [5.1.2] — 2026-09-03

WebSockets, done properly. Reverb has been in Cipi since 5.0.0, but only as far as "a port, a Supervisor program and an Nginx proxy" — the parts that decide whether a WebSocket app actually works in production were missing, and one of them was quietly breaking ordinary routes.

### Fixed

- **The Nginx location for Reverb swallowed every URL beginning with `/app`.** It was written as `location /app`, and in Nginx that is a *prefix* match, not a path: `/appointments`, `/apple`, `/application/...` — any route whose path started with those four characters — was proxied into Reverb instead of reaching Laravel, on every app with Reverb enabled. The block is now the regex `~ ^/apps?(/|$)`, which matches only the two paths the Pusher protocol actually uses: `/app/{key}` for the WebSocket handshake and `/apps/{id}/…` for the HTTP API the application broadcasts through. (An app with its own `/app` or `/apps` route still cannot use Reverb behind the same domain — those paths belong to the protocol.)
- **`proxy_read_timeout` was set to exactly Reverb's ping interval.** Both were 60 seconds, and an idle WebSocket sees traffic only when Reverb pings it — so every idle client was a coin flip between the ping and the timeout. The timeout is now well clear of it; Reverb's own ping/prune cycle is what reaps dead connections, which is what it is there for.
- **Disabling Reverb left the app broadcasting into a dead server.** `cipi app reverb disable` removed the Supervisor program and the Nginx block but left `BROADCAST_CONNECTION=reverb` in the `.env`, so every broadcast failed afterwards. Cipi now records what the app was broadcasting through before Reverb took over and puts that back on disable (falling back to `log`).
- **`workers.horizon: false` in `cipi.yml` did nothing.** The plan read the value with jq's `// empty`, and that operator treats `false` exactly like a missing key — so declaring `horizon: false` on an app running Horizon read back as "not declared" and no action was planned, while the mutual-exclusion check simultaneously refused to accept the queue workers declared alongside it. Both `horizon` and the new `reverb` are now read with `has()`.

### Added

- **Reverb credentials are generated.** `REVERB_APP_ID`, `REVERB_APP_KEY` and `REVERB_APP_SECRET` were left for the admin to invent — and an empty set is precisely what stops `reverb:start` from booting. `cipi app reverb enable` now writes a set on first use and never touches it again: rotating a key would disconnect every live client and invalidate any frontend bundle already built against it, so existing values always win (an app that arrived with its own credentials keeps them).
- **`VITE_REVERB_APP_KEY`, `VITE_REVERB_HOST`, `VITE_REVERB_PORT` and `VITE_REVERB_SCHEME`** are written alongside them. Vite reads these at build time and bakes them into the bundle; Cipi's `node_build` step runs after Deployer has linked the shared `.env`, so a deploy now produces a frontend that can actually find the socket.
- **`ws://` or `wss://` is decided from what the server serves, not assumed.** A brand-new app with no certificate gets `http`/80, an app with one gets `https`/443 — and installing a certificate later (HTTP-01 or DNS-01) moves the app's Reverb settings to `wss://` on the spot. Previously the values were hardcoded to `https`/443 at enable time, which meant a browser refusing the connection as mixed content, with nothing in the Reverb log to explain it. A domain change re-derives them too, and a wildcard domain resolves to a concrete host (`www.example.com`) because no browser can open a socket to `*.example.com`.
- **The file-descriptor ceilings a WebSocket server runs into are lifted.** Every open socket costs one descriptor inside Reverb and two connections inside Nginx, and the stock 1024 soft limit stops an app at roughly a thousand concurrent clients — with nothing in any log to say why. Cipi now ships a systemd drop-in raising Supervisor's `LimitNOFILE` to 65535 (and therefore every program it runs, Reverb included), and sets `worker_rlimit_nofile 65535` with `worker_connections 8192` in `nginx.conf`. Supervisor picks its new limit up only on a restart, which also restarts every queue worker on the server — so Cipi says so rather than doing it behind your back; `cipi app reverb enable <app> --restart-supervisor` does it in one go.
  - The drop-in rather than supervisord's own `minfds`: `minfds` makes supervisord **refuse to start** when the limit cannot be reached, which would take every queue worker on the box down with it.
- **`workers.reverb: true|false` in `cipi.yml`.** Reverb was the one Laravel extra that could not be declared in a project file even though Horizon, the queue workers and the scheduler all could. It is planned, applied and emitted by `cipi yml generate` like the rest, and declaring it on a `--custom` app is refused up front.
- **`cipi app reverb status` says what a client should be dialling** — the full `wss://host:port/app/{key}` — and warns when the `.env` is missing a credential, when the app has a certificate but is still configured for `ws://`, and when Supervisor is still running with the old open-file limit.
- **Cloning a Reverb app clones its Reverb.** `cipi app clone` copied the source's `REVERB_*` keys into the new `.env` — pointing the clone's frontend at the production socket and handing it the production app secret — while never starting a Reverb for it. The clone now gets its own port, its own credentials and its own domain, the way it already got its own Octane.

**Migration 5.1.2** applies all of this to servers that are already running: it raises both limits (reporting whether Supervisor still needs a restart), rewrites the Nginx vhost of every app whose Reverb location is still the greedy prefix — backed up to `/var/lib/cipi/vhost-backup-5.1.2`, tested, SSL reapplied, and rolled back as a batch if `nginx -t` fails — and fills in the missing `.env` keys **without overwriting anything already there**, so an app whose socket settings were tuned by hand keeps them.

---

## [5.1.1] — 2026-09-02

A hotfix for 5.1.0: one unterminated heredoc, and wildcard domains made to work end to end.

### Fixed

- **One unterminated heredoc broke app creation, every vhost rewrite, and emptied FPM pools.** `_create_fpm_pool` ended its heredoc with `${overrides}EOF` on a single line. A heredoc only closes on a line holding the delimiter *alone*, so the body ran on: the pool file was truncated to **zero bytes** by the redirection and the run then died on an unbound variable, and the runaway body swallowed the next function, `_nginx_reverb_location_block`, whole. Consequences, all from the same line:
  - `cipi app create` aborted at the PHP-FPM step.
  - Every vhost regeneration — `cipi alias add/remove`, `cipi www`, `cipi basicauth`, `cipi app suspend`, a PHP version change — died with `_nginx_reverb_location_block: command not found` *after* apps.json had been written, so the panel's state and nginx drifted apart.
  - Migration 5.1.0 called `_create_fpm_pool` for every app, so **upgraded servers can be left with empty pools**: the sites keep serving until the next php-fpm restart, then answer 502.

  **Migration 5.1.1** rebuilds every FPM pool (reporting the ones that had been emptied), restarts the affected `php*-fpm` after a config test, and regenerates the vhosts that no longer match apps.json — healthy vhosts are left untouched, backups go to `/var/lib/cipi/vhost-backup-5.1.1`, and a failing `nginx -t` rolls the batch back.
- **A regression test now fails if this class of bug returns.** `tests/verify-5.1.1.sh` sources each library and checks that every function it defines is actually defined afterwards — an unterminated heredoc makes the functions behind it disappear, which is exactly what went unnoticed here.

### Fixed — wildcard domains

- **`*.example.com` was rejected as a primary domain.** `cipi app create` and `cipi app edit --domain=` validated the primary with the non-wildcard matcher, so a multi-tenant app fronted by one wildcard vhost could not be created at all — even though nginx serves a wildcard `server_name` natively and `cipi.yml` documents `*.${domain}` as an alias. Wildcards are now accepted for the primary domain of `app create`, `app edit --domain=` and `app clone --domain=`.
- **Every URL built from the domain was unusable on a wildcard app.** `APP_URL`, the deploy webhook shown by `cipi app show` / `cipi deploy webhook`, and the webhook registered with GitHub or GitLab were all built as `https://*.example.com/…`, which is not a hostname and which both providers refuse. They now name a concrete tenant host (`www.example.com`).
- **SSL could not work on a wildcard app.** Let's Encrypt validates a wildcard over DNS-01 only, and certbot names the lineage after the bare domain — but Cipi passed `--cert-name '*.example.com'` and looked for `/etc/letsencrypt/live/*.example.com`, so nothing matched. Certificate names and lineage lookups now strip the wildcard label everywhere (install, force, renew-time reinstall, domain change, app delete, `cipi domains`).
- **A single wildcard alias failed the whole certificate.** `cipi ssl install` sent every alias to HTTP-01, and one `-d '*.example.com'` fails the entire order — so an app with a wildcard alias could not get a certificate for any of its domains. Wildcard aliases are now left out of the HTTP-01 certificate with a warning pointing at `--dns=cloudflare`, and a wildcard *primary* is refused up front with the two commands that do work.
- **`cipi ssl install --dns=cloudflare --wildcard` doubled the wildcard label** when the primary domain already was one (`*.*.example.com`).
- **`cipi www force-to-root|force-from-root` and `cipi health set` produced nonsense on a wildcard app** — `www.*.example.com` as a server_name, and a healthcheck (with post-deploy rollback attached) aimed at `https://*.example.com/up`. Both now stop with an explanation; `cipi health set` asks for an explicit `--url`.
- **`cipi app create` now says how to secure a wildcard app**, printing the `cipi ssl dns set` / `cipi ssl install --dns=cloudflare` pair in the summary instead of the plain `cipi ssl install` that cannot work there.

---

## [5.1.0] — 2026-09-02

Thanks to **Alberto Peripolli** for putting Cipi through a real multi-tenant SaaS deployment and reporting every one of the problems this release fixes.

### Fixed

- **The "deploy failed" notification never fired.** `_deploy_run` ran Deployer as a plain command under `set -euo pipefail`, so a non-zero exit killed the `cipi` process on the spot: the failure branch, its warnings, the rollback hint and the `deploy_fail` email were unreachable code. The run is now wrapped so the real status is read from `PIPESTATUS[0]`, and both the CLI and the automatic webhook path report success **and** failure by email. `cipi deploy` also exits non-zero when the deploy failed, so CI and webhooks can see it. The same bug and the same fix applied to `cipi deploy --rollback`.
- **Backups silently skipped every database an app created at runtime.** `cipi backup run` dumped exactly one database per app — the one named after the app. A multi-tenant application creating `tenant_1`, `tenant_2`, … appears in no registry, so none of them were ever saved. Databases are now discovered from the engine itself (minus system schemas) and selected with glob patterns.
- **Backups of `--custom` apps failed on every run.** The archive step ran `tar -C /home/<app> shared/`, but a `--custom` app has no `shared/` — its files live in `htdocs/`. Every run errored, marked the backup as failed, and saved nothing for those apps.
- **`cipi worker horizon enable` left Horizon half-enabled.** `reload_supervisor` returns non-zero when `supervisorctl reread/update` complains, which under `set -e` aborted the function *before* `apps.json` was updated — so `enable` printed nothing after "Enabling Horizon…" and `status` still reported `disabled`. The state is now always written, the command reports what supervisor actually did, and `status` surfaces drift between the two.
- **A server-wide php.ini change could not reach any app.** Every FPM pool hardcoded `php_admin_value[upload_max_filesize]`, `post_max_size` and `max_execution_time`, and pool values outrank `conf.d`. Pools now carry only what is genuinely per-app (`open_basedir`, the error log, explicit overrides) and inherit everything else.
- **The CLI SAPI was never configured.** Cipi wrote `99-cipi.ini` for FPM only, so queue workers, `artisan` and cron ran on the PHP package defaults. Both SAPIs are now written, and **migration 5.1.0** backfills the CLI file on existing servers.
- **Deploy logs had no dates and no release numbers.** `/home/<app>/logs/deploy.log` was raw Deployer output appended forever, which made a deploy that failed overnight unreadable afterwards. Every line is now timestamped and each run is bracketed by a banner naming the trigger, the branch, the release and the duration.
- **HTTPS requests matching no app landed on an arbitrary app.** `:80` had a default server but `:443` never did, so a request with an unknown `Host` fell through to whichever vhost nginx loaded first — for a wildcard multi-tenant app, straight into a tenant resolver that cannot parse it.
- **Every backup run aborted before archiving anything** when an app had no `shared/` (or no `htdocs/`) directory. The helper that decides what to archive ended on a conditional, so "nothing to archive" was returned as a *failure* and `set -e` killed the run — before it could even print the "skipped" warning it had for exactly that case.
- **`cipi worker horizon enable` aborted at the first step, not the last.** `_supervisor_remove_program` ended on a conditional too, returning non-zero in the ordinary case where the app's supervisor file still holds other programs — and it is called before Horizon's own program is written. This is the deeper cause of the half-enabled Horizon reported against 5.0.x; the `reload_supervisor` guard added earlier in this release was necessary but not sufficient.
- **`local a="$1" b="…${a}…"` does not work.** Bash expands `${a}` before `local` has assigned it, so under `set -u` the function dies with `a: unbound variable`. Eight of these existed; they survived only because a variable of the same name usually happened to exist in the calling scope. All are now split into separate statements, and the test suite fails if one comes back.
- **Two more helpers returned non-zero on their success path**: the legacy prune reported failure precisely when it *had* deleted something, and `cipi sync export` returned a non-zero exit code after a successful export.
- **A disabled backup profile kept running.** `jq`'s `//` operator treats `false` as absent, so reading `enabled` returned an empty string instead of `"false"` — `cipi backup profile disable` had no effect on the schedule or on `cipi backup run`. Booleans are now read explicitly. The same read made `Encrypted` display as blank.
- **`tar` warnings were treated as backup failures.** `tar` exits 1 for "file changed as we read it", which happens constantly on a live application writing its logs — so a perfectly good archive was reported as failed and sent a `backup_fail` email. Only exit 2 and above now counts as a failure.
- **A truncated archive was stored as if it were a backup.** A dump cut short by a full disk is still a non-empty file, so the existing size check passed it. Every archive is now integrity-checked before it is shipped, and a corrupt one is discarded and reported instead of quietly replacing a good backup.
- **`cipi backup fetch` reported success when it downloaded nothing.** `aws s3 cp --recursive` exits 0 on a prefix that holds no objects, so a mistyped timestamp produced "Backup available at …" pointing at an empty directory.
- **`cipi backup verify` said "passed" after verifying nothing.** With no runs yet it now says so plainly rather than offering a false reassurance.
- **A newly created backup profile was immediately reported as overdue**, including by email, before its first scheduled run could possibly have happened.
- **Migration 5.1.0 could abort and pin a server on the old version.** A `grep` that matched nothing, under `set -o pipefail`, failed the assignment reading the previous retention — and a failed migration makes `cipi self-update` refuse the release and retry, failing again, every night. Every step of the migration now degrades to a warning and carries on.
- **The nginx catch-all reported "already claimed" when it simply could not write its file**, sending anyone debugging it after the wrong vhost.
- **`cipi yml example` produced a template that failed validation.** Its placeholder names sat outside the target app's namespace, so the documented first step (`cipi yml example > cipi.yml`, then validate) failed with four errors. It now takes an optional app name — `cipi yml example <app>` — and writes the template in that app's namespace, valid as-is.
- **`cipi self-update` said only "Download failed".** git's stderr was discarded, so the one message that explains what happened — no DNS, no outbound HTTPS, a missing branch, a full disk, an expired CA bundle — never reached anyone. The real error is now printed, the likely cause is named, and the command to reproduce it by hand is shown. The clone also runs under a 180-second timeout instead of being able to hang indefinitely, and a missing `git` is reported as such.
- **`set +e` blocks re-enabled errexit instead of restoring it.** The deploy helpers turned `set -e` back on unconditionally at the end of a guarded block, which silently changed the shell's contract for whatever called them. Now the previous state is saved and restored, so these functions are safe to call from any context.
- **A failed connection was reported as HTTP status `000000`.** `curl -w '%{http_code}'` already prints `000` when it cannot connect, so the `|| echo "000"` fallback appended a second one — the wrong value reached healthcheck alerts and the state files under `/var/log/cipi/health`.
- **Wildcard domain aliases were rejected.** `cipi alias add <app> '*.example.com'` failed validation even though nginx matches wildcard `server_name` natively and multi-tenant apps need it.

### Added

- **`cipi backup profile` — backup strategies instead of one hardcoded job.** A profile decides scope (`all`, `files`, `db`), which apps and databases it covers, which tables to skip, how often it runs, where it goes (`local`, `s3`, or both) and how long it is kept (`--keep=N` runs, `--keep-days`, `--keep-weeks`). Profiles are independent, so a 30-minute database copy kept locally coexists with an encrypted nightly full copy on S3. Retention is mandatory — a profile that would grow without bound is refused.
- **The backup schedule is managed for you.** `cipi backup configure` and every profile change rewrite a marked block in root's crontab; the pre-5.1 hand-written lines are absorbed on migration. Nothing outside the block is touched.
- **Application files and databases are stored separately** — `apps/<app>/files.tar.gz` next to `databases/<engine>/<db>.sql.gz`, with a manifest per run — so a database-only profile costs nothing to take and a database can be restored without unpacking an app.
- **Client-side backup encryption** (`--encrypt`): AES-256 before anything leaves the server, so the bucket operator never holds readable data. `cipi backup key show` prints the key to store off-server; `cipi backup fetch` downloads and decrypts a run for restore.
- **`cipi backup verify`** checks the newest run of each profile actually decompresses (`--deep` downloads from S3 to do it), and **`cipi backup status`** shows destinations, profiles and last results. An hourly watchdog raises `backup_stale` when a profile has not succeeded within twice its own interval.
- **`cipi ini` — guided php.ini editing.** `cipi ini list` shows the effective value of every tunable setting and which layer set it; `cipi ini set upload_max_filesize=50M` applies it server-wide to **both** FPM and CLI; `--app=<app>` scopes it to one app. `post_max_size` and `memory_limit` are raised along with an upload limit that would otherwise cap it, and nginx's `client_max_body_size` is flagged when it would. Settable keys are an explicit whitelist; `open_basedir`, `auto_prepend_file`, `extension` and friends are refused by name with the reason.
- **`cipi yml` — optional per-project `cipi.yml`.** An app can carry a file in its repository declaring domain aliases, PHP version and settings, **extra databases**, **queue workers**, its **healthcheck** (URL, expected status, grace period, whether to check after a deploy and whether to roll an unhealthy release back) and its **backup strategy**. `cipi yml plan` shows the exact diff, `cipi yml apply` applies it, `cipi yml auto <app> on` reconciles after every successful deploy — from **both** `cipi deploy <app>` and the Git webhook, the latter through one narrowly scoped sudoers rule — and `cipi yml example` prints a commented template. Deploys ignore the file entirely until that opt-in is given; with it on, a release that carries no `cipi.yml` is a quiet no-op, and a file that fails validation is reported by email and never partially applied. Credentials for databases it creates are written to `/home/<app>/shared/cipi-databases.env`, never to the repository.

  **`cipi yml generate <app>`** prints the app's configuration as it stands on the server — aliases, PHP version and per-app settings, its extra databases, its queue workers (read back out of supervisor), the scheduler and the backup profiles it owns — as a ready-to-commit `cipi.yml`, so the file never has to be written from scratch. Cron expressions are rendered back to the friendlier `every: 30m` form where they map cleanly, values are quoted wherever a plain scalar would be misread, and the result is fed back through the validator before printing. Server-wide backup profiles and the app's own database are deliberately left out.

  Because the file arrives over git, it is fail-closed throughout: it can only configure an app that already exists (never create, rename or delete one), its databases must be named `<app>` or `<app>_*` and its backup profiles `<app>` or `<app>-*`, its healthcheck URL must resolve to one of the app's own domains (otherwise a commit could aim the server's five-minute prober at an internal address and read the answer back out of the alert emails), unknown keys are errors, no field carries a shell command or a path to include, and the parser implements a small YAML subset that refuses anchors, aliases, tags, merge keys, block scalars and flow mappings outright.
- **`cipi nginx default-server on|off|status`** — claims whichever of `:80`/`:443` has no default server and closes unmatched requests with an empty reply (444). Enabled on fresh installs and, where nothing else claims it, by migration 5.1.0.
- **`cipi deploy <app> --log[=N]`** shows the timestamped deploy log; `--releases` now lists each release with its date, commit and subject (the directories stay numeric — rollback depends on that ordering).
- **Post-deploy healthcheck.** Once an app has a healthcheck URL (`cipi health set <app>`), the release that just went live is verified right after every deploy — from `cipi deploy` and from the Git webhook alike — and a failure raises `deploy_health_fail` **immediately**. The periodic checker deliberately waits for three consecutive failures before alerting, which is right for a running site and useless for the question "did the push I just made break production?". The probe waits a short grace period (8s for Octane apps, 3s otherwise, or `--grace=N`) and retries five times, so an app that needs a moment to come up is not reported as broken. The verdict never changes the deploy's exit code — the release is live either way — but the alert says so and gives the rollback command. Turn it off per app with `cipi health set <app> --no-postdeploy`; run it on demand with `cipi health postdeploy <app>`.
- **Auto-rollback of an unhealthy release** (opt-in). `cipi health set <app> --rollback-on-unhealthy`, or `cipi deploy <app> --rollback-on-unhealthy` for one deploy, undoes a release that fails its post-deploy healthcheck: the symlink moves back to the previous release, the app is probed again, and **one** email describes the whole sequence — what was published, what it answered, what it was rolled back to and whether that fixed it. The four outcomes are distinguished: recovered, rolled back but still unhealthy (so the cause is probably not the code), the rollback itself failed (the bad release is still live), and there is no earlier release to return to. It is off by default and says so loudly, because **database migrations are not undone** — a release that migrated the schema and then failed can be worse off after a rollback.
- **Deploy notifications now say what was actually deployed.** Success and failure carry visibly different subjects (`Cipi deploy succeeded: <app> release 55 …` / `Cipi deploy FAILED: <app> …`) and a body naming the branch, the release number, the commit hash and subject, its author and date, the duration, the previous release, the deploy log path and the post-deploy healthcheck verdict — on both the CLI and the webhook path. The success mail is now sent **after** verification, so it can never announce a successful deploy while the site is returning 500.
- **New notification triggers**: `backup_stale`, `ini_set`, `yml_apply`, `yml_fail`, and `self_update` — the last one so an unattended nightly update no longer lands without a word. All are toggled with `cipi notifications enable|disable`.
- **Table exclusions in dumps** (`--exclude-tables='*.jobs,*.telescope_*'`), expanded against the live table list on MariaDB and passed straight to `pg_dump` on PostgreSQL.

### Changed

- `cipi backup configure` accepts an empty bucket for local-only backups, and lists Cloudflare R2, Hetzner, DO Spaces, Backblaze B2, Scaleway and MinIO as S3-compatible endpoints.
- `cipi backup prune [app] --weeks=N` keeps working against the pre-5.1 layout, so existing archives and any hand-written cron line still prune.
- README: the install snippet no longer carries a `$` prefix that gets copied with it, and states that it runs **on the server** as a `sudo` user, how to produce the SSH public key it asks for (including on Windows), and what the root password it prints is for.

### Migration

**5.1.0** installs the automatic-deploy wrapper and repoints each app's webhook cron at it, backfills the CLI `99-cipi.ini`, rewrites FPM pools so they inherit the server-wide file, converts the hardcoded nightly backup job into a `default` profile carrying over its existing `--weeks` retention, takes over the backup schedule with the managed crontab block, and claims the `:443` default server when nothing else does.

---

## [5.0.18] — 2026-08-06

### Fixed

- **Panel GUI HTTP 500 after `cipi gui upgrade` / soft update** — path repo for `cipi/gui` defaulted to a **symlink** into `/opt/cipi/cipi-gui`, outside PHP-FPM `open_basedir` (`/opt/cipi/gui/` only). Restore Composer `options.symlink=false` (real copy in `vendor/`), widen `open_basedir` to include `/opt/cipi/cipi-gui/`, reinstall when a symlink is detected, and rewrite the FPM pool after upgrade/update. **Migration 5.0.18** repairs existing panels. Immediate: `cipi gui fix-permissions`.

---

## [5.0.17] — 2026-08-06

### Fixed

- **`cipi self-update` appeared stuck on “Downloading cipi/gui…” until Enter** — interactive TTY + `timeout --foreground curl -s` could stop on stdin (SIGTTIN). GUI tarball sync now uses curl’s own timeouts with stdin closed (`</dev/null`). Composer panel updates set `COMPOSER_ALLOW_SUPERUSER=1` and also close stdin so root/`--no-interaction` runs never wait for a prompt.

---

## [5.0.16] — 2026-08-06

### Fixed

- **`cipi self-update` hung on GUI after API Packagist fix** — `cipi/gui` is **not** on Packagist, so soft update still used a GitHub **VCS** repo and blocked on `Composer VCS repo → https://github.com/cipi-sh/gui`. Now syncs a timed GitHub **tar.gz** into `/opt/cipi/cipi-gui` and installs via **path** repo (`composer require cipi/gui:@dev`). **Migration 5.0.16** unsets stale `repositories.cipi-gui`.

---

## [5.0.15] — 2026-08-06

### Fixed

- **`cipi api update` / self-update API step hung while `cipi api upgrade` worked** — soft update forced a Composer **VCS** repo on `https://github.com/cipi-sh/api` (full git clone/scan). Upgrade installs from **Packagist** dist zips (`composer require cipi/api`), which already has **1.19.1**. Soft update now matches upgrade: unset stale `repositories.cipi-api`, then `composer require cipi/api` from Packagist (or local path). **Migration 5.0.15** drops the VCS entry on existing panel apps.

---

## [5.0.14] — 2026-08-06

### Fixed

- **`cipi self-update` / `cipi api update` hung forever on panel API package update** — bare `ssh-keyscan github.com` (no timeout) blocked before Composer, and VCS `composer update` had no wall-clock limit (stderr was often discarded). Now: timed keyscan + official GitHub host-key fallback, Composer guard (`timeout` + `COMPOSER_PROCESS_TIMEOUT`), timed queue stop/migrate, and `cipi api update` updates **`cipi/api` only** (full rebuild remains `cipi api upgrade`). Self-update delegates to `_api_update_package` / `_gui_update_package` so the first upgrade pass already gets the fix.
- **`systemctl list-unit-files --quiet UNIT` is not an existence check** — it exits 0 even when zero units match, so PostgreSQL (and optional PHP-FPM units) could be treated as present. Detection now uses `systemctl cat` via `systemd_unit_exists` for DB engines and `cipi service`.
- **`cipi db engines`** — prints ASCII `not_installed` instead of an em dash, so API/GUI parsers cannot mis-read the status column.

---

## [5.0.13] — 2026-08-06

### Fixed

- **`cipi self-update` aborted with `_cipi_composer_prepare_github: command not found` and left the panel on HTTP 500** — upgrading from older builds (e.g. v5.0.2) kept the pre-update `self-update`/`common.sh` helpers in memory while sourcing the new `gui.sh`, which called a helper that did not exist yet. After the blanket `chown -R root:root /opt/cipi`, GUI `.env` / storage stayed root-owned and PHP-FPM returned 500. **`lib/gui.sh`** now has the same inline fallback as the API (`_gui_composer_prepare_github`), **`ensure_cipi_gui_permissions`** also restores `.env` ownership, and **`self-update`** always reclaims panel permissions at the end even if the Composer step fails. **Migration 5.0.13** reclaims API/GUI ownership on update.

---

## [5.0.12] — 2026-08-06

### Fixed

- **`cipi php switch` could leave the panel on nginx 502** — it now **rewrites** the API and (when installed) GUI FPM pools onto the target PHP (`listen = /run/php/cipi-api.sock` / `cipi-gui.sock`), removes them from other versions, stops the old FPM to release the socks, recreates `/run/php` + both sockets via the new `php*-fpm`, waits until they exist, and **rolls back** both pools if either socket never appears.

---

## [5.0.11] — 2026-08-06

### Fixed

- **`cipi php switch` failed with `unable to remove '/etc/alternatives/php.dpkg-tmp': Read-only file system`** — same remount-ro class as SMTP/basicauth/vault. Switch now remounts `/`/`/etc` writable before `update-alternatives`, clears stale `*.dpkg-tmp` leftovers, retries once on RO errors, and prints an actionable recovery hint.

---

## [5.0.10] — 2026-08-06

### Fixed

- **`cipi php switch` false failure after a successful CLI switch** — `update-alternatives --set php` often prints `using /usr/bin/phpX.Y …` then exits non-zero when a slave alternative (phar/phpdbg/…) is missing or broken. The panel API treated that as hard failure even though `/usr/bin/php` already pointed at the new version. Switch now verifies the resolved binary and continues when the master link is correct. Re-running switch when CLI is already on the target version still migrates a leftover API FPM pool.

---

## [5.0.9] — 2026-08-06

### Fixed

- **Panel API `PUT /api/php/default` failed with `sudo: a terminal is required to read the password`** — `/etc/sudoers.d/cipi-api` allowed `php list|install|remove` but not **`php switch`**, so `www-data` could not set the system default PHP without a TTY. Added `cipi php switch *` to the whitelist. **Migration 5.0.9** regenerates sudoers on `cipi self-update`.

---

## [5.0.8] — 2026-08-06

### Fixed

- **Panel API `cipi/api` updates** — `cipi self-update` / `cipi api update` now pull **`cipi/api`** from **[GitHub](https://github.com/cipi-sh/api)** via Composer VCS when no bundled `/opt/cipi/cipi-api` copy exists (same model as **`cipi/gui`**). Only runs if the panel API is already installed (`/opt/cipi/api/artisan`); it never installs the API on servers that do not use it. Fixes servers stuck on Packagist while GitHub already has **1.16+**.
- **Non-interactive CLI flags** — `parse_args` strips wrapping quotes from `--key='value'` arguments built by the panel API (`escapeshellarg`), so `cipi smtp configure --host=…` and similar commands receive clean values.
- **Migration 5.0.8** — reduced to a noop (the previous script duplicated self-update and could abort with `ensure_cipi_api_permissions: command not found`).
- **`ssh_dir: unbound variable` during self-update** — `_cipi_composer_prepare_github` / `_api_composer_prepare_github` used `local ssh_dir=… kh="${ssh_dir}/…"`, which under `set -u` expands `ssh_dir` before it is assigned and aborted the API/GUI composer step.

---

## [5.0.7] — 2026-08-06

### Fixed

- **`cipi smtp test` / send failed with `/etc/msmtprc: Read-only file system`** — every send rewrites system `/etc/msmtprc`; when the kernel remounted `/` read-only that redirect aborted (same remount-ro class as basicauth/vault). **`lib/smtp.sh`**: `_smtp_write_rc` and `_smtp_delete` now call **`_cipi_ensure_config_writable`** + probe `/etc` (with `mount -n` remount) and print a clear recovery hint. **Migration 5.0.7** remounts on `cipi self-update` and regenerates `/etc/msmtprc` when SMTP is already configured.

---

## [5.0.6] — 2026-08-06

### Added

- **`cipi api ip-whitelist`** — restrict panel API / MCP clients by IP. Default file `/etc/cipi/api-ip-whitelist` is `*` (allow all). Subcommands: `show` (default), `add`, `remove`, `set`, `allow-all`. Entries: one IPv4/IPv6 or CIDR per line (or comma-separated `--ips=`). `--json` for automation.
- **Non-interactive SMTP** — `cipi smtp configure --host= --port= --user= --password= --from= --to= [--tls=on|off] [--enabled=on|off] [--no-test]`; `cipi smtp status --json` (password never printed); `cipi smtp delete --force`.
- **Healthcheck JSON** — `cipi health list --json`, `cipi health check <app> --json` (includes last state / failcount when present).
- **`cipi app webhook recreate <app> [--rotate-secret]`** — recreate the GitHub/GitLab deploy webhook; optional secret rotation updates `apps.json` + `shared/.env` `CIPI_WEBHOOK_TOKEN`.
- **`--json` on `cipi php list` / `cipi ssh list` / `cipi service list`** — structured output for the panel API.
- **Panel API sudoers** — `php list|install|remove`, `ssh list|add|remove`, `service list|restart`, `status`, `db install|default`, `app webhook recreate`, `smtp status|configure|enable|disable|test|delete`, `api ip-whitelist` (+ args). **Migration 5.0.6** creates the default IP whitelist file and regenerates `/etc/sudoers.d/cipi-api` on `cipi self-update`.

### Fixed

- **`cipi app edit --repository=` recreated deploy key + webhook even when the URL was unchanged** — provider cleanup/setup now runs only when the repository actually changes (same for unchanged `--php` / `--branch`).
- **GitHub/GitLab API `curl` could hang forever** — added `--connect-timeout 10 --max-time 30`.
- **`cipi php remove` hung under the panel API** — confirmation is skipped without a TTY (or with `--force`), matching other non-interactive commands.
- **Clearer error when editing to a PHP version that is not installed** — suggests `cipi php install <ver>`.

---

## [5.0.5] — 2026-08-05

### Fixed

- **`cipi basicauth enable` still failed after 5.0.4 with read-only `/etc/nginx/cipi-basicauth`** — plain `mount -o remount,rw /` often fails while root is still RO (mtab updates / broken fstab UUID lookup). **`lib/vault.sh`**: `_cipi_remount_rw` uses `mount -n` + `findmnt` SOURCE/TARGET, then re-creates `/etc/cipi`; basicauth also probes/remounts the nginx path and prints remount details on failure. **Migration 5.0.5** applies the same recovery on `cipi self-update`.

---

## [5.0.4] — 2026-08-05

### Fixed

- **`cipi app run` always failed with `/usr/bin/env: '--': No such file or directory`** — GNU `env` treats a bare `--` _after_ `NAME=VALUE` assignments as the command to execute (not an option terminator). `app_run` was invoking `/usr/bin/env -C … VAR=1 -- cmd`, so every whitelisted command (including GUI “App commands”) exec’d `--`. Now: `/usr/bin/env -C "$workdir" VAR=… cmd args…`.
- **`cipi basicauth enable` / vault writes on remount-ro root** — when the kernel remounted `/` read-only, `mkdir /etc/nginx/cipi-basicauth` and `vault_write apps.json` failed (`Read-only file system`), while `_basicauth_set_user` still returned success because trailing `chown`/`chmod` used `|| true`. **`lib/vault.sh`**: mutating writes call **`_cipi_ensure_config_writable`** (probe → best-effort `mount -o remount,rw /` → re-probe); read paths keep using **`_cipi_config_writable`** only (no remount on `source` / `db list`). **`lib/app.sh`**: basicauth credential writes fail closed with a clear error if the filesystem stays read-only. **Migration 5.0.4** remounts on `cipi self-update` when `/etc/cipi` is still RO.

---

## [5.0.3] — 2026-08-05

### Added

- **Non-interactive `.env` management** — `cipi app env <app>` still opens nano by default; API/scripts can use `--show` / `--get=KEY` / `--set=KEY=VALUE` / `--unset=KEY` with optional `--json`.
- **Non-interactive Composer `auth.json`** — `cipi auth create|delete <app> [--force]` (skips confirm when no TTY); `cipi auth edit <app> --file=PATH`; `cipi auth show <app> --json`.
- **`cipi app run <app> <cmd> [args…]`** — whitelisted **non-interactive** binaries as the app user (`composer`, `npm`/`npx`/`yarn`/`pnpm`, `ls`/`ll`, `cat`/`head`/`tail`, filesystem helpers, archives, `git`, `php`, `node`, `find`). List with `cipi app run --commands [--json]`. No editors/pagers/shells/REPLs (`nano`, `vim`, `less`, `bash`, `tinker`, …); interactive flags blocked.
- **Structured deploy config** — `cipi app deploy-config <app>` show/edit durable recipe options in `apps.json` (regenerates `deploy.php` — safe alternative to free-form PHP): `--keep-releases=N`, `--migrate`/`--no-migrate`, `--optimize`/`--no-optimize`, `--storage-link`/`--no-storage-link`, `--queue-restart`/`--no-queue-restart`, `--horizon-terminate`/`--no-horizon-terminate`, `--extra-artisan=cmd1,cmd2`, `--node-build` / `--predeploy-snapshot` (and clear flags).
- **Panel API sudoers** — `app env`, `app artisan`, `app run`, `auth create|edit|show|delete` in `/etc/sudoers.d/cipi-api`. **Migration 5.0.3** regenerates sudoers + Laravel/Octane `deploy.php` on `cipi self-update`.

---

## [5.0.2] — 2026-08-05

### Fixed

- **`horizon:terminate` reports `NamespaceNotFoundException` when Horizon is not installed** — Deploy templates always ran `php artisan horizon:terminate` before symlink. With `|| true` the deploy still succeeded, but apps without `laravel/horizon` threw Symfony’s “no commands defined in the horizon namespace”, which exception digests (Flare/Sentry/etc.) reported. Templates now skip artisan unless `vendor/laravel/horizon/composer.json` exists (same guard for `octane:reload` + `laravel/octane`). **Migration 5.0.2** regenerates existing `deploy.php` files.

---

## [5.0.1] — 2026-08-04

### Fixed

- **First deploy fails on `horizon:terminate` / `readlink …/current`** — Deployer resolves `{{current_path}}` with `readlink` before the shell `|| true` can run, so a brand-new app (no `current` symlink yet) aborted at `before('deploy:symlink', 'horizon:terminate')`. Templates now guard with `[ -L {{deploy_path}}/current ]` and call artisan via `{{deploy_path}}/current`. **Migration 5.0.1** regenerates existing `deploy.php` files.

---

## [5.0.0] — 2026-08-04

### Added

- **Optional Laravel Octane (FrankenPHP)** — create Laravel apps that serve HTTP via Octane instead of PHP-FPM, in parallel with classic FPM apps on the same server:
  - **`cipi app create --octane`** or **`--octane=frankenphp`** (Laravel only; rejected with `--custom`)
  - Allocates a localhost port (`8100–8999`), stores `octane` / `octane_port` in `apps.json`
  - Nginx vhost proxies to Octane (`proxy_pass`) and serves static files from `current/public` — no per-app FPM pool
  - Supervisor program `${app}-octane` alongside queue workers; Deployer template `laravel-octane.php` restarts/reloads on deploy
  - `.env`: `OCTANE_SERVER=frankenphp`, `OCTANE_HTTPS=true`
  - Requires `laravel/octane` + `php artisan octane:install --server=frankenphp` in the app repo (Octane starts after the first successful deploy)
- **`cipi app convert <app> --to=octane|fpm`** — convert an existing Laravel app between PHP-FPM and Octane (pool/vhost/supervisor/deployer/`.env`; SSL re-applied when present)
- **Laravel Reverb** — **`cipi app reverb enable|disable|status`**: localhost port `9000–9099`, Supervisor `${app}-reverb`, Nginx `/app` WebSocket proxy, `.env` `REVERB_*`
- **Laravel Horizon** — **`cipi worker horizon enable|disable|status`**: mutually exclusive with `queue:work` workers; deploy runs `horizon:terminate` + `cipi-worker` restart
- **Scheduler CLI** — **`cipi schedule on|off|status <app>`** (crontab `schedule:run` already existed; now manageable; `schedule` in apps.json)
- **Node build on deploy** — **`cipi app edit --node-build='npm ci && npm run build'`** / **`--no-node-build`**; Deployer runs `.deployer/node-build.sh` after vendors (fail-closed; validated command)
- **`cipi app clone <src> --domain=…`** — staging as a new app (`[--name=] [--branch=] [--with-db|--no-db]`); sets `cloned_from`; does not copy webhook/git IDs
- **Pre-deploy DB snapshot** — opt-in via **`predeploy_snapshot`** / **`cipi deploy --snapshot`** / **`--snapshot-required`**; dump under `/var/log/cipi/backups/`; code rollback does not auto-restore DB
- **Resource limits** — **`cipi app limits <app>`** (`--fpm-max-children`, `--memory-limit`, `--octane-workers`, `--worker-procs`) with hard caps
- **SSL DNS-01 (Cloudflare)** — **`cipi ssl dns set --provider=cloudflare --token=`** then **`cipi ssl install <app> --dns=cloudflare [--wildcard]`**; HTTP-01 remains default
- **HTTP healthchecks** — **`cipi health set|unset|check|list`**; cron every 5 minutes; notify `health_fail` after 3 consecutive failures
- **`apps-public.json`** — also exposes `reverb`, `reverb_port`, `horizon`, `schedule`, `node_build`, `cloned_from`, `predeploy_snapshot`, `limits`, `health_url`, `health_expect`, `ssl_dns_provider`

---

## [4.8.1] — 2026-08-03

### Fixed

- **`cipi self-update` stuck on Migration 4.7.16** — the historical migration used `|` as the `sed` delimiter while the replacement contained `|| true`, so `sed` aborted with `unknown option to s` and left the server at the previous version (files already copied). **4.7.16** now no-ops when `common.sh` has no bare init `chmod`, and uses `#` delimiters when patching. Unblocks upgrades from versions below 4.7.16 (e.g. 4.7.14 → 4.8.x).

---

## [4.8.0] — 2026-08-02

### Added

- **`cipi www`** — manage www/apex aliases and canonical redirects:
  - **`cipi www add <app>`** — add the counterpart host (`www.` + apex, or apex when primary is already `www.*`)
  - **`cipi www force-to-root <app>`** — 301 redirect `www.domain` → `domain` (auto-adds the missing alias)
  - **`cipi www force-from-root <app>`** — 301 redirect `domain` → `www.domain`
  - **`cipi www clear <app>`** / **`cipi www status <app>`** — clear or inspect redirect state
  - State lives in `apps.json` (`www_redirect`); `_create_nginx_vhost` emits a dedicated redirect server block (ACME path kept public). Survives vhost regeneration; SSL is re-applied via `certbot install --redirect`.
- **`cipi ssl force <app>`** — re-apply HTTP → HTTPS redirect for an app that already has a Let's Encrypt cert (no new issuance). Also set automatically by **`cipi ssl install`** (`force_https` in `apps.json`).
- **Multi-engine databases (MariaDB + PostgreSQL)** — MariaDB stays native on **3306**; optional PostgreSQL on **5432**:
  - **`cipi db install pgsql`** / **`cipi db uninstall pgsql|mariadb`** — install or remove a non-default engine (data destroyed on uninstall)
  - **`cipi db default mariadb|pgsql`** — server-wide default used when `--engine` is omitted
  - **`cipi db engines`** — show installed engines, ports, and default
  - **`cipi db create|list|delete|backup|restore|password`** accept **`--engine=mariadb|pgsql`**
  - **`cipi app create --engine=pgsql`** (interactive prompt when creating Laravel apps); `.env` + connection URL match the engine
  - App metadata stores `engine`; backup/sync/reset-db-password follow it
  - **`cipi reset db-password [--engine=]`** resets the root password for the chosen (or default) engine
  - **`cipi service`** recognizes **`postgresql`** (aliases: `pgsql`, `postgres`)

### Changed

- **`cipi alias add|remove`** — after regenerating the vhost, re-apply SSL with `certbot install --redirect` (same pattern as basicauth/suspend) so HTTPS is not dropped.
- **`apps-public.json`** — projection now includes `www_redirect`, `force_https`, and `engine`. **Migration 4.8.0** regenerates it, nests legacy `databases.json` under `mariadb`, backfills `engine=mariadb` on apps, and refreshes the panel API sudoers whitelist.

---

## [4.7.23] — 2026-07-25

### Changed

- **`cipi help`** — main help is now a short index grouped by area (Core, Apps & deploy, Security, Panel, Ops). Full command lists live in topic help: **`cipi help <topic>`** (e.g. `app`, `deploy`, `gui`) or **`cipi <command> help`**. Use **`cipi help all`** for the previous monolithic dump.

---

## [4.7.22] — 2026-07-25

### Fixed

- **`cipi smtp` Permission denied / AppArmor** — msmtp cannot use **`/etc/cipi/.msmtprc`** (setgid + AppArmor deny read on **`/etc/cipi/*`**), cannot run **`passwordeval`** helpers like **`cat`**, and cannot write custom log paths under **`/var/log`**. Send now uses only system **`/etc/msmtprc`** (`root:msmtp` **640**) with an embedded password — no `-C`, no `passwordeval`, no `logfile`. Legacy **`/etc/cipi/.msmtprc`** is removed. Configure/test show real msmtp errors and check host reachability. **Migration 4.7.22**.

---

## [4.7.21] — 2026-07-25

### Fixed

- **`cipi smtp` → `msmtp: /etc/cipi/.msmtprc: Permission denied`** — Debian/Ubuntu ship **`msmtp` setgid** (`msmtp` group). After setgid the process can no longer traverse **`/etc/cipi`** (**750** `root:cipi-api`) or read vault secrets via **`passwordeval`**. Cipi now clears the setgid bit on the msmtp binary (mail is only sent as root). **Migration 4.7.21** applies this on existing servers and regenerates `.msmtprc`.

---

## [4.7.20] — 2026-07-25

### Fixed

- **`cipi smtp configure` / `cipi smtp test` failed with working credentials** — several msmtp integration bugs:
  - Password was written via an **unquoted heredoc**, so `$` / backticks in passwords were shell-expanded and corrupted before msmtp saw them.
  - `.msmtprc` stored the password in cleartext; msmtp then **refused the file** when permissions were not strictly `0600` (common after group changes under `/etc/cipi`).
  - Hardcoded `tls_trust_file /etc/ssl/certs/ca-certificates.crt` made send fail when that path was missing; trust file is now used only if present.
  - `tls_starttls` stayed `on` even when TLS was disabled.
  - Test failures hid the real msmtp error (`2>/dev/null`) and did not detect an unreachable host/port.
- SMTP now uses **`passwordeval`** (`lib/cipi-smtp-pass.sh`) so the password stays in encrypted `smtp.json` only; configure/test print the msmtp error and check TCP reachability. **Migration 4.7.20** regenerates `.msmtprc` on existing servers.

---

## [4.7.19] — 2026-07-23

### Fixed

- **`cipi deploy` password prompt / `Permission denied (publickey,password)`** — new apps created under umask `002` got `~/.ssh` as **`775`** (group-writable). OpenSSH **StrictModes** then refused pubkey auth with `Authentication refused: bad ownership or modes for directory /home/<app>/.ssh`, so Deployer's localhost SSH fell through to a password prompt. **`cipi app create`** now forces **`chmod 700 ~/.ssh`**; **Migration 4.7.19** repairs existing apps on **`cipi self-update`**.
- **`cipi app delete` left orphan Linux users / homes / SSH keys** — `userdel -r … || true` often failed silently when cron or other processes still held the UID, so `/home/<app>` (and `~/.ssh` deploy keys) stayed on disk after the app was removed from `apps.json`. Delete now kills leftover processes, falls back to `rm -rf /home/<app>`, and runs **`purge_orphan_app_users`** to sweep other Cipi-looking leftovers not in `apps.json`. **Migration 4.7.19** / **`cipi self-update`** also purge orphans.

---

## [4.7.18] — 2026-07-14

### Fixed

- **`cipi db list` on Ubuntu 25.10+ / 26.04** — **Migration 4.7.18** completes what **4.7.16** / **4.7.17** left incomplete:
  - **Read-only `/etc/cipi`** — **`lib/common.sh`** / **`lib/vault.sh`**: **`_cipi_config_writable`**, **no init `chmod`**, **`_cipi_safe_chmod`**; migration re-installs lib from self-update bundle (or GitHub) when needed. Fixes **`HTTP 503: chmod … Read-only file system`** from **`cipi-cli db list`**.
  - **sudo-rs sudoers** + **API `open_basedir`** — re-applied idempotently.
  - **`mount -o remount,rw /`** when `/etc/cipi` is read-only; refresh **`apps-public.json`**; **`sudo cipi db list`** smoke test.
- **`cipi db list` missing databases** — **`lib/db.sh`** now uses **`information_schema.schemata`** so **empty** databases (fresh **`cipi db create`**, pre-migrate app DBs) show as **0 MB**.
- **`cipi db list` silent MariaDB failures** — surfaces vault/MariaDB errors instead of a blank table.

---

## [4.7.17] — 2026-07-14

### Fixed

- **Panel API on Ubuntu 25.10+ / 26.04 (consolidated)** — **Migration 4.7.17** applies in one **`cipi self-update`** pass:
  - **sudo-rs sudoers** — rewrites **`/etc/sudoers.d/cipi-api`** via **`lib/cipi-api-sudoers.sh`** (`cipi db restore *` instead of `* *`).
  - **Log viewer / `CipiLogReader`** — API PHP-FPM **`open_basedir`** now includes **`/usr/local/bin/`** so **`is_executable()`** on **`cipi-read-app-logs`** and **`cipi`** no longer fatals before **`sudo`** fallback.
  - **Read-only `/etc/cipi`** — **`common.sh`** / **`vault.sh`** guards (shipped in **`lib/*.sh`**); migration verifies **`_cipi_config_writable`** is present.

---

## [4.7.16] — 2026-07-14

### Fixed

- **Panel API / `sudo cipi` failing on read-only `/etc/cipi`** — sourcing **`common.sh`** always ran **`chmod 700 /etc/cipi`**, recreated **`apps-public.json`** ( **`vault_read apps.json`** + write), and initialized missing vault files — all requiring writes under **`/etc/cipi`**. On a read-only root (kernel **`remount-ro`**, dual-boot NTFS left dirty, etc.) that aborted even read-only commands like **`cipi db list`**, with errors such as **`chmod: Read-only file system (os error 30)`**, **`apps-public.json: Read-only file system`**, or **`vault: failed to decrypt apps.json`**. Added **`_cipi_config_writable`**; init **`chmod`**/**`mkdir`**, **`ensure_apps_json_api_access`**, and **`vault_init`** are now best-effort when **`/etc/cipi`** cannot be written. Fix ships in **`lib/common.sh`** / **`lib/vault.sh`** on **`cipi self-update`** (verified by **migration 4.7.17**).

---

## [4.7.15] — 2026-07-14

### Fixed

- **Panel API broken on Ubuntu 25.10+ (`sudo-rs`)** — `/etc/sudoers.d/cipi-api` used `cipi db restore * *`, which **sudo-rs** rejects (`wildcards are not allowed in command arguments`). The invalid rule made **sudo** ignore the whole file, so **`www-data`** could not run any whitelisted API command (`I'm afraid I can't do that`). Replaced with **`cipi db restore *`** (trailing `*` only, per sudo-rs). Centralized the whitelist in **`lib/cipi-api-sudoers.sh`**. **Migration 4.7.15** rewrites sudoers on existing servers via **`cipi self-update`**.

---

## [4.7.14] — 2026-07-07

### Fixed

- **Backup fails on large apps when `/tmp` is tmpfs** — `cipi backup run` wrote gzipped DB dumps and file archives under `/tmp`, which on many servers is a small RAM-backed tmpfs. Staging now defaults to **`/var/tmp`** (disk). Override with **`tmpdir`** in `backup.json` (set via `cipi backup configure`) or **`CIPI_BACKUP_TMPDIR`**. Fixes [#500](https://github.com/cipi-sh/cipi/issues/500).

---

## [4.7.13] — 2026-07-03

### Added

- **Weekly PHP security patch check** — PHP packages are excluded from `unattended-upgrades` (managed by Cipi). **`cipi php upgrade`** runs **`apt-get update`** and **`--only-upgrade`** on all installed **`php*`** / **`libphp*`** packages, restarts affected PHP-FPM pools, and emails when upgrades were applied (**`php_upgrade`** trigger). Root crontab: **Sunday 03:30** via **`cipi-cron-notify`**. Log: **`/var/log/cipi/php-upgrade.log`**. **Migration 4.7.13** adds the cron on existing servers and runs the check immediately (2026-07 PHP 8.x security release).

---

## [4.7.12] — 2026-07-01

### Security

- **SQL injection in `cipi db` commands** — `_db_delete`, `_db_backup`, `_db_restore`, and `_db_password` (**`lib/db.sh`**) interpolated the `<name>` argument (and, for delete/password, the stored `user` field) directly into `mariadb -e` statements without validation, unlike `_db_create` which already validated `name`. A crafted database name (e.g. containing a quote or backtick) could break out of the SQL string/identifier context and execute arbitrary statements as the MariaDB **root** user; `_db_create --user=` was also unvalidated, allowing the same injection at creation time. Added **`validate_db_name()`** (**`lib/common.sh`**) and applied it to `name`/`user` in every `_db_*` function, including the vault-stored `user` fallback used by delete/password.
- **PHP code injection via `cipi app create --repository=` / `--branch=` and `cipi app edit`** — these values were substituted unsanitized into the single-quoted PHP string literals `set('repository', '...')` / `set('branch', '...')` when generating each app's **`deploy.php`** (**`lib/app.sh`**, **`lib/deployer/{laravel,custom}.php`**); the existing `sed` escaping only handled sed metacharacters, not the PHP string delimiter. A crafted branch/repository value (e.g. `x'); system('...'); //`) could break out of the string literal and inject arbitrary PHP — executed as the app's Linux user on every deploy (manual, cron, or webhook-triggered), reachable even via a REST API token scoped only to `apps-edit`. Added **`validate_git_branch()`** and **`validate_git_repository()`** (**`lib/common.sh`**, restricted charset) and enforced them in `app_create` and `app_edit` before the values are written anywhere.

No migration required — both fixes are input-validation only and take effect immediately after `cipi self-update`; no existing app/database configuration needs to be regenerated.

---

## [4.7.11] — 2026-07-01

### Added

- **Setup post-install guide** — after the credentials summary, **`setup.sh`** now prints a short step-by-step guide for the optional **Panel API** (`cipi api <domain>` → `cipi api ssl` → `cipi api token create`) and **Web GUI** (`cipi gui <domain>` → `cipi gui ssl`), including DNS hints and what each layer does.

---

## [4.7.10] — 2026-07-01

### Added

- **`cipi app logs read <app>`** — paginated log snapshot for the panel API (**`GET /api/apps/{name}/logs`**) with **`--type=`**, **`--page=`**, **`--per-page=`**; emits **`===CIPI_LOG_FILE:…===`** markers. Wired as **`cipi app logs read`** subcommand (distinct from interactive **`cipi app logs`** tail).

### Fixed

- **GUI log viewer still empty for Laravel logs on servers that already ran migration 4.7.8** — **`open_basedir`** on the API PHP pool blocks reads under **`/home/*`**, so log content must be fetched via **`sudo cipi app logs read`**. **Migration 4.7.10** ensures **`/etc/sudoers.d/cipi-api`** whitelists that command (and **`cipi-read-app-logs`**) on existing servers.

---

## [4.7.9] — 2026-07-01

### Fixed

- **Panel API still could not read Laravel log files after 4.7.8** — traverse ACLs on **`shared/storage/logs`** were not enough when log files are **`app:app` 664**. **`ensure_app_logs_permissions`** now grants **`u:cipi:r`** on each **`*.log`** file (and clears stale ACLs first). **Migration 4.7.9** retrofits all known apps on **`cipi self-update`**.

---

## [4.7.8] — 2026-07-01

### Added

- **`/usr/local/bin/cipi-read-app-logs`** — root helper for paginated tail/head of app log globs under **`/home/*/logs/`** and **`/home/*/shared/storage/logs/`** (path-validated; used by the panel API via sudo).

### Fixed

- **GUI log viewer could not read files under `/home/*` from the API** — first sudoers pass for **`www-data`**: **`cipi-read-app-logs *`** plus suspend/basicauth entries from 4.7.6. **Migration 4.7.8** installs the helper and rewrites **`/etc/sudoers.d/cipi-api`** on existing servers.

---

## [4.7.7] — 2026-07-01

### Fixed

- **GUI apps list always showed “Suspend” / wrong Basic Auth state** — **`apps-public.json`** (API read model for **`GET /apps`**) omitted **`suspended`** and **`basic_auth`** from the projection even though they live in **`apps.json`**. **`_update_apps_public`** now includes both flags. **Migration 4.7.7** regenerates **`apps-public.json`** on **`cipi self-update`**.

---

## [4.7.6] — 2026-07-01

### Fixed

- **Panel Basic Auth / Suspend failing with `sudo: a terminal is required to read the password`** — the panel runs as **`www-data`** and calls **`sudo cipi basicauth enable|disable|status`** (ability `apps-basicauth`) and **`sudo cipi app suspend|unsuspend`** (ability `apps-suspend`), but these were missing from the **`/etc/sudoers.d/cipi-api`** whitelist, so `sudo` prompted for a password and failed without a TTY. Added them to the whitelist. **Migration 4.7.6** applies the same fix on existing servers via **`cipi self-update`**.
- **`cipi basicauth disable` refusing with `Basic auth is not enabled` while auth was still live** — when **`basic_auth`** in **`apps.json`** got reset without regenerating the vhost (Nginx kept enforcing the old **`auth_basic`** block and the htpasswd file lingered), disable relied on the flag alone and left the app stuck protected. It now also disables when the htpasswd file exists, so it always cleans up the file and regenerates the vhost.
- **Panel DB delete / restore and deploy rollback hanging on a `[y/N]` prompt** — **`cipi db delete`**, **`cipi db restore`** and **`cipi deploy --rollback`** always called **`confirm`**, whose blocking **`read`** never returns under the API/UI job runner (no TTY), so the job hung forever showing `Delete database 'x'? [y/N]:`. They now skip confirmation when **`--force`** is passed **or** stdin is not a terminal (matching **`cipi app delete --force`**).

---

## [4.7.5] — 2026-07-01

### Changed

- **GUI package source** — **`cipi gui`** now installs and updates **`cipi/gui`** from **[GitHub](https://github.com/cipi-sh/gui)** via Composer VCS (`dev-main`). The **`cipi-gui/`** directory was removed from this repo (GUI lives in its own repository). PHP-FPM **`open_basedir`** is simplified to **`/opt/cipi/gui/`** only. **Migration 4.7.5** migrates existing servers and removes the legacy **`/opt/cipi/cipi-gui`** bundle.
- **`cipi gui update`** — now runs **`composer update cipi/gui`**, **`migrate --force`**, and **`cipi:gui-refresh-theme`** (when available). New subcommand **`cipi gui refresh-theme`** for theme-only reloads.

### Added

- **`cipi gui remove`** — uninstall the web control panel when configured (Nginx, FPM, cron, SSL, Laravel app, vault config). Alias **`uninstall`**; **`--force`** skips confirmation.

### Fixed

- **`cipi gui reset-user`** — fixes login failing after reset (**`These credentials do not match our records`**) caused by **double password hashing** (Laravel 12 **`hashed`** cast + **`Hash::make()`** in **`cipi/gui`**'s **`--reset`**). Always resets via **`lib/gui-reset-admin.php`** (plain password + session purge). Payload written under **`storage/app/`** as **`www-data`**.
- **`cipi gui` / `gui upgrade` install** — fixes **`getcwd: cannot access parent directories`** when the shell cwd was inside **`/tmp/cipi-gui-build`** or **`/opt/cipi/gui`** during **`rm -rf`**. Build dir moved to **`/var/tmp/cipi-gui-build.*`** with **`_gui_cd_safe`** before destructive ops; **`open_basedir`** includes **`/var/tmp/`**.

---

## [4.7.3] — 2026-06-30

### Fixed

- **GUI `open_basedir` still blocking `/opt/cipi/cipi-gui/` on existing servers** — **`cipi gui fix-permissions`** now runs a full **`_gui_repair_runtime`**: copies **`cipi/gui`** into **`vendor/`** (`symlink: false` + `composer reinstall`), rewrites the FPM pool with **`/opt/cipi/cipi-gui/`** in **`open_basedir`**, and clears caches. **Migration 4.7.3** applies the same repair on **`cipi self-update`**.
- **GUI app detail 500 (`Undefined variable $name`)** — **`AppDetail::mount()`** now accepts the **`{name}`** route parameter (`mount(string $name)`).

---

## [4.7.2] — 2026-06-30

### Fixed

- **GUI giant icons / broken layout** — the inline CSS subset was missing size utilities used in Blade (`h-9`, `h-12`, `h-16`, `mx-auto`, `text-surface-600`, `bg-surface-900/50`, …); SVGs without matching rules rendered at full browser default size. Added the missing utilities plus safe SVG defaults in **`cipi/gui`** `partials/styles.blade.php`.
- **GUI Livewire / Alpine JS conflicts** — **`layouts/app.blade.php`** loaded Alpine from jsDelivr on top of Livewire 3’s bundled Alpine, breaking `wire:click`, polling, and `x-data` toasts. Removed the duplicate script tag.
- **GUI HTTPS / Livewire** — Nginx vhost now passes **`HTTP_X_FORWARDED_PROTO`** and **`HTTPS`** to PHP-FPM so Laravel generates correct URLs behind TLS. **Migration 4.7.2** patches existing vhosts in place (preserves certbot SSL blocks) and updates **`cipi/gui`**.

---

## [4.7.1] — 2026-06-30

### Fixed

- **GUI HTTP 500 (`open_basedir` / `CipiGuiServiceProvider`)** — the `cipi-gui` PHP-FPM pool allowed only `/opt/cipi/gui/`, but Composer's path repository symlinked `cipi/gui` from `/opt/cipi/cipi-gui/`, so autoload failed at runtime. **`lib/gui.sh`** now sets **`open_basedir`** to include **`/opt/cipi/cipi-gui/`**, configures the path repo with **`symlink: false`** (package copied into `vendor/`), and refreshes the FPM pool on **`cipi gui update`** / **`fix-permissions`**. **Migration 4.7.1** retrofits existing servers.

---

## [4.7.0] — 2026-06-30

### Added

- **`cipi gui`** — optional web control panel for managing one or more Cipi servers via the REST API ([cipi/gui](https://github.com/cipi-sh/gui)). **`cipi gui <domain>`** provisions a Laravel host at **`/opt/cipi/gui`** (dedicated PHP-FPM pool, Nginx vhost, scheduler cron), **prompts interactively for admin email and password** (password policy: min **12** chars, upper + lower + digit + special, max **4** identical chars in a row), and stores config in **`/etc/cipi/gui.json`**. Subcommands: **`ssl`**, **`update`** (soft `composer update`), **`upgrade`** (full rebuild), **`status`**, **`fix-permissions`**, **`reset-user`** (rewrite admin email/name/password and clear 2FA; same password policy; alias **`reset-password`**). Session login with optional TOTP 2FA; no local queue worker — remote async jobs are polled via the managed servers' **`cipi api`**. The **`cipi/gui`** Composer package is bundled at **`/opt/cipi/cipi-gui`** (same model as **`cipi-api`**). Requires **`cipi api`** enabled on each managed server with a token covering the full ability set.

---

## [4.6.7] — 2026-06-10

### Fixed

- **`setup.sh` failed on fresh VPS when `unattended-upgrades` holds the apt lock** — the typical flow (new VPS → paste the install command) often collides with the first automatic security update, so the very first `apt-get` could exit immediately with _Could not get lock_ and abort the install. **`setup.sh`** now waits up to **300s** for the lock on every **`apt-get`** via **`DPkg::Lock::Timeout`**, shows a short _System updates in progress…_ message when the lock is already held, and writes **`/etc/apt/apt.conf.d/00cipi-lock-timeout`** so later steps (PPA, NodeSource, cron) inherit the same timeout. **`set -o pipefail`** was added so piped installers (e.g. NodeSource) cannot fail silently. **`lib/php-apt.sh`**: direct **`dpkg -i`** (Sury keyring) uses **`cipi_wait_for_dpkg_lock`** because dpkg does not honour the apt timeout; removed **`|| true`** on that path so a broken keyring install stops instead of continuing with missing PHP packages. **Migration 4.6.7** applies the apt.conf snippet on existing servers.

---

## [4.6.6] — 2026-06-10

### Fixed

- **`setup.sh` MariaDB / PHP on Ubuntu 26.04 (resolute)** — the installer still always added the MariaDB.org **11.4** repo and **`ppa:ondrej/php`**, which have no **`resolute`** suite yet (_Release file not found_ at _Installing MariaDB…_). `setup.sh` now bootstraps **`lib/php-apt.sh`** (curl from GitHub when `/opt/cipi` does not exist), sanitises broken third-party sources left by a partial install, uses **`mariadb_setup_apt_repo`** (MariaDB.org when available, otherwise **Ubuntu main** — 11.8.x on 26.04), and **`php_setup_apt_sources`** (ondrej → **packages.sury.org** → archive). **`mariadb_setup_apt_repo`** / **`mariadb_apt_source_label`** added to **`lib/php-apt.sh`**.

---

## [4.6.5] — 2026-06-10

### Fixed

- **Self-update stuck on 4.6.2–4.6.4 (readonly / unset `CIPI_*`)** — `lib/api.sh` assigned `CIPI_API_ROOT` / `CIPI_API_CONFIG` as `readonly` without guards, so sourcing `api.sh` inside migrations could abort the loop; guards now match `common.sh`. **`self-update`** exported `CIPI_LIB=…` after the main binary had already marked `CIPI_LIB` / `CIPI_CONFIG` / `CIPI_LOG` readonly (`CIPI_LIB: readonly variable` at line 64) — it now uses `export CIPI_LIB CIPI_CONFIG CIPI_LOG` (by name) plus `CIPI_API_ROOT` default. **`cipi-cron-notify`**, **`cipi-auth-notify`**, and **`cipi-app-notify`** use the same guard pattern. **Migration 4.6.5** idempotently repairs hybrid `lib/*.sh` on disk (skips plain `CIPI_*=` heredoc lines in `app.sh`; pure bash, mawk-safe).

---

## [4.6.4] — 2026-06-10

### Fixed

- **`common.sh` CIPI_LIB when sourced outside `cipi`** — Migrations and other callers that `source common.sh` without going through the main binary left `CIPI_LIB` unset, so `source "${CIPI_LIB}/vault.sh"` failed mid–self-update (notably migration **4.6.3** after token-abilities / api.sh steps). `common.sh` now derives `CIPI_LIB` from its own path via `BASH_SOURCE` when unset (same pattern as `CIPI_CONFIG` / `CIPI_LOG`), with no hardcoded `/opt/cipi/lib`.
- **Migration runner hygiene** — `self-update` exports `CIPI_LIB`, `CIPI_CONFIG`, and `CIPI_LOG` before running migrations, runs each migration under `set -euo pipefail`, and prints a clear _migration failed — version not updated_ message instead of a raw bash traceback.
- **Partial 4.6.3 recovery** — Servers stuck at **4.6.2** with libs already copied from 4.6.3 can re-run `cipi self-update`: migration **4.6.3** remains idempotent; **4.6.4** verifies the path fix and completes any remaining cron / notifications steps. Emergency pre-release patch: `lib/fix-common-readonly.sh` now also applies the `CIPI_LIB` derive block.

---

## [4.6.3] — 2026-06-10

### Added

- **`cipi notifications`** — granular email trigger control when SMTP is configured. **`cipi notifications list`** shows every event grouped by category (apps, deploy, SSL, aliases, PHP, security, cron, …) with on/off status; **`enable` / `disable <trigger>`**, **`enable-all`**, **`disable-all`**, and **`reset`** toggle what gets emailed. All triggers are **on by default**; events are always logged to **`/var/log/cipi/events.log`** regardless. Config: **`/etc/cipi/notifications.json`**. **`cipi_notify()`** and the PAM / cron / webhook helpers (`cipi-auth-notify`, `cipi-cron-notify`, `cipi-app-notify`) respect the trigger map. New notifications were added for actions that previously only logged (aliases, SSL, deploy success/rollback, PHP install/remove, DB create/delete, workers, API, git, sync, services). **Migration 4.6.3** seeds `notifications.json` on existing servers.

### Changed

- **`cipi api token create` ability list** — reads `token-abilities.txt` from the panel API package (includes **`status-view`**, **`apps-suspend`**, **`apps-basicauth`**, and all other REST abilities). **`lib/migrations/4.6.3.sh`** retrofits existing servers: writes `/opt/cipi/api/token-abilities.txt` and patches `lib/api.sh` when it still has the legacy 14-line hardcoded list.
- **Nightly panel API update** — **`/usr/local/bin/cipi-api-update`** runs **`cipi api update`** (soft `composer update` + migrations) every night at **04:30** via **`/etc/cron.d/cipi-api`**, wrapped with **`cipi-cron-notify`** for failure alerts. Log: **`/var/log/cipi-api-update.log`**.

---

## [4.6.2] — 2026-06-09

### Added

- **Change primary domain via `cipi app edit --domain=`** — you can now rename an app's primary domain without recreating it: **`cipi app edit <app> --domain=<new>`** validates the new name (format + uniqueness), promotes it to primary, moves the previous primary into **aliases** (so the old URL keeps working), regenerates the Nginx vhost, updates **`APP_URL`** in `shared/.env` when present, refreshes the **GitHub/GitLab webhook** URL when git integration is auto-configured (deploy key unchanged), and **re-issues Let's Encrypt** when a certificate already existed for the old primary (otherwise it reminds you to run `cipi ssl install` once DNS for the new domain is ready). Promoting an existing alias to primary works too (e.g. swap `app.example.com` ↔ `www.example.com`). Composable with the existing `--php`, `--branch`, and `--repository` flags.

---

## [4.6.1] — 2026-06-04

### Changed

- **Composer upgraded to 2.10.1+** — servers provisioned earlier kept whatever Composer build the `getcomposer.org` installer shipped at the time (some as old as **2.9.x**), which lags the current stable 2.x release. `setup.sh` now enforces a Composer **2.10.1** floor on fresh installs: after running the installer it checks the reported version and, when below the floor, runs `composer self-update --2` (falling back to a pinned `self-update 2.10.1`). **Migration 4.6.1** applies the same guard to existing servers on `cipi self-update` — it self-updates the system Composer (`/usr/local/bin/composer`) to the latest stable **2.x** when below **2.10.1**, and is idempotent (servers already at/above the floor are skipped).

---

## [4.6.0] — 2026-06-04

### Changed

- **Supported Ubuntu releases** — fresh installs via `setup.sh` now accept **Ubuntu 24.04 or 26.04 only** (no other version, including interim releases). The initial requirements check uses an exact `VERSION_ID` match instead of a `24.04+` floor.

---

## [4.5.12] — 2026-06-04

### Fixed

- **PHP install / `apt-get update` failed on Ubuntu 26.04 (resolute)** — `setup.sh` and `cipi php install` always added **`ppa:ondrej/php`**, but Launchpad does not publish a **`resolute`** suite yet, so `apt-get update` failed with _Release file not found_ (including on re-runs at _Installing base packages_ when a broken PPA source was left from a partial install). Cipi now probes PHP APT sources per codename: when Launchpad ondrej has a suite (**noble**, **jammy**, …) it uses the PPA as before; when it does not (**resolute** / Ubuntu 26.04) it configures **[packages.sury.org](https://packages.sury.org/php/)** instead (same maintainer, co-installable **`php8.3` / `php8.4` / `php8.5`** — multi-PHP works on 26.04); if neither repo is available, it falls back to **Ubuntu main** (single version). **`lib/php-apt.sh`** centralises the logic; `setup.sh` bootstraps it before the first `apt-get update` and sanitises stale broken sources; **`cipi php install`** uses the same helper. **Migration 4.5.12** removes a leftover broken ondrej source and wires up packages.sury.org where needed.

---

## [4.5.11] — 2026-06-04

### Fixed

- **MariaDB install failed on Ubuntu 26.04 (resolute)** — `setup.sh` always added the MariaDB.org **11.4** APT repo using `$(lsb_release -cs)`, but that repository does not publish a **`resolute`** suite yet, so `apt-get update` failed with _Release file not found_. The installer now probes the repo for a valid `Release` file per codename: when the suite exists (e.g. **noble**, **jammy**) it uses MariaDB.org 11.4 as before; when it does not (e.g. **resolute** / Ubuntu 26.04) it skips the third-party repo and installs **MariaDB from Ubuntu main** (11.8.x on 26.04). A leftover broken `/etc/apt/sources.list.d/mariadb.list` from a failed run is removed automatically.

---

## [4.5.10] — 2026-06-04

### Fixed

- **Fresh install failed after nginx.org package install** — the official nginx.org DEB does not create `/etc/nginx/sites-available/` or `/etc/nginx/sites-enabled/` (Debian/Ubuntu convention only), so `setup.sh` aborted with _No such file or directory_ when writing the default vhost. `setup.sh` now creates those directories (and `/var/www/html`) and removes the stock `/etc/nginx/conf.d/default.conf` so it does not conflict with Cipi's default server block. **Migration 4.5.10** applies the same layout fix on existing servers (idempotent).

---

## [4.5.9] — 2026-06-04

### Security

- **Nginx upgraded to mainline 1.29.8+ (HTTP/2 bomb mitigation)** — a newly disclosed remote DoS dubbed [HTTP/2 bomb](https://thehackernews.com/2026/06/new-http2-bomb-vulnerability-allows.html) chains HPACK header amplification with a zero-byte HTTP/2 flow-control window so the server never frees allocated memory; nginx fixed this in **1.29.8** with the **`max_headers`** directive (default 1000). Ubuntu 24.04's distro nginx (1.24.x) does not include that fix, so Cipi now installs and upgrades nginx from the **[nginx.org mainline APT repository](https://nginx.org/en/linux_packages.html#Ubuntu)** (pinned with `99nginx` preferences) instead of the Ubuntu archive. Fresh installs via `setup.sh` get mainline nginx out of the box; existing servers receive **migration 4.5.9** on `cipi self-update`, which adds the repo, upgrades the package, and rewrites `/etc/nginx/nginx.conf` with `max_headers 1000`. The Ubuntu-only **`libnginx-mod-http-headers-more-filter`** module (used for `more_clear_headers`) is removed — it is incompatible with nginx.org packages; **`server_tokens off`** and per-vhost **`fastcgi_hide_header X-Powered-By`** remain in place. Nginx stays on the existing unattended-upgrades blacklist (Cipi-managed upgrades only).

---

## [4.5.8] — 2026-06-02

### Added

- **App suspend / unsuspend** — take any app (Laravel or custom) offline without deleting it: **`cipi app suspend <app>`** replaces the app's Nginx vhost with a generic static suspension page served as **HTTP 503**, and **`cipi app unsuspend <app>`** restores the normal vhost. State lives in `apps.json` (`suspended`), and `_create_nginx_vhost` renders the suspended vhost whenever the flag is set, so suspension **survives vhost regeneration** (alias add/remove, PHP edit) and `certbot install` clones it into the `:443` server block — **HTTPS is suspended too**. The ACME challenge path (`/.well-known/acme-challenge/`) is kept public so SSL issuance/renewal keeps working while a site is offline, and toggling re-runs `certbot install` (no new issuance, no rate-limit risk) so HTTPS is never dropped. The offline page is a shared, self-contained static page at `/var/www/cipi-suspended/index.html`, created on demand on first suspend; `no-store` cache headers and `noindex,nofollow` keep suspended pages out of caches and search engines. The suspended state is shown in `cipi app show` (Status), `cipi app list` (yellow dot + `(suspended)`) and `cipi domains` (a yellow `⏸ suspended` marker per row plus a count in the footer), and is cleared automatically when the app is deleted. This unblocks the **WHMCS module's Suspend/Unsuspend** lifecycle, which previously had no Cipi endpoint to call (see [cipi-sh/whmcs](https://github.com/cipi-sh/whmcs)).

---

## [4.5.7] — 2026-06-02

### Fixed

- **Valkey install used the wrong package name** — `setup.sh` and migration 4.5.6 installed `valkey`, but on Ubuntu 24.04 the daemon package is **`valkey-server`** (source `valkey`; binaries `valkey-server` + `valkey-tools`). On servers that had already updated to 4.5.6 the switch aborted with _"valkey package not available"_ and left `redis-server` running (no data touched). Since 4.5.6 has already shipped and a migration can't be re-run, `setup.sh` is corrected to `valkey-server` and **migration 4.5.7 performs the full, corrected Redis → Valkey switch itself** (self-contained: reuse password, preserve the RDB/AOF dataset, purge `redis-server`, install `valkey-server` + `valkey-tools`, restore data, rewrite `server.json`/blacklist). It adds extra safety nets: it **auto-enables the `universe` component** when the package isn't found (via `add-apt-repository` if present, otherwise by editing the deb822/legacy APT sources directly — no `software-properties-common` needed) and re-checks; it runs a **post-start health check** (`PING` → `PONG` with the password) and, if Valkey doesn't come up healthy (or can't be installed), **rolls back to `redis-server` restoring both the saved password and the dataset**, so the server is never left without a working cache backend. The dataset snapshot is kept until the switch is verified, then cleaned up. Idempotent — servers already on Valkey skip it.

---

## [4.5.6] — 2026-06-02

### Changed

- **Redis → Valkey** — Cipi now provisions **Valkey** (the BSD-licensed, Redis-compatible fork shipped in Ubuntu 24.04 Universe as `valkey-server` + `valkey-tools`) instead of `redis-server`. Valkey speaks the same RESP protocol on the same port (`127.0.0.1:6379`) and honours the same `requirepass`/`bind` directives, so **apps need zero changes**: the `phpredis` extension and existing `REDIS_*` `.env` values keep working as-is. `setup.sh` installs and configures Valkey (`/etc/valkey/valkey.conf`, service `valkey-server`); `cipi service …` manages `valkey-server` (with `redis-server`/`redis`/`valkey` accepted as aliases); credentials live under `valkey_user`/`valkey_password` in `server.json` (legacy `redis_*` keys are still read as a fallback). **`cipi reset valkey-password`** replaces `cipi reset redis-password` (the old name stays as an alias).
- **Migration 4.5.6 — automatic Redis → Valkey switch for existing servers** — on `cipi self-update`, servers still running `redis-server` are migrated to Valkey **reusing the current password** (recovered from `server.json` or `/etc/redis/redis.conf`), so no app `.env` needs editing. It first verifies the `valkey` package is installable (so a server that can't obtain it keeps its working cache backend untouched), **preserves the dataset** (forces an RDB `SAVE` and snapshots `dump.rdb`/AOF, restored into Valkey's data dir after install — Valkey reads the Redis 7.2 RDB/AOF format, so cache/sessions/queued jobs survive), then stops and **purges** `redis-server` (avoiding any apt Conflicts/Replaces ambiguity between the two packages) before installing and configuring Valkey on the same port with the same `requirepass`/`bind`, and rewrites `server.json` (`redis_*` → `valkey_*`) and the unattended-upgrades blacklist. If the install fails it restores `redis-server` with the saved password, so the server is never left without a cache backend; otherwise rollback is a plain `apt install redis-server` (the password lives in `server.json`). The migration is idempotent and safe to re-run.

---

## [4.5.5] — 2026-06-02

### Added

- **`cipi domains` — global domain/alias map** — a new top-level command that lists **every** domain and alias across all apps in a single table: **DOMAIN**, owning **APP**, **KIND** (`primary`/`alias`), **TYPE** (`Laravel`/`Custom`), **PHP** version, **DOCROOT** (`public` for Laravel, `/<docroot>` for custom), Git **BRANCH**, **LAST DEPLOY** as a human-relative age (`just now`, `10m ago`, `2h ago`, `3d ago`, `2w ago`, `2mo ago`, `2y ago` — derived from the mtime of the app's `current` symlink, which Deployer atomically re-points on every successful deploy; `-` when never deployed), per-name **SSL** status (`✓`/`✗`, detected from `/etc/letsencrypt/live/<domain>`), and the Git **REPOSITORY** (or `(SFTP only)` for custom apps with no repo). Rows are sorted by domain and a footer summarises totals (domains, apps, certs), making it easy to audit the whole mapping or spot a domain that's still missing a certificate — complements the per-app `cipi alias list <app>`.
- **`ll` shell alias for app users** — the `.bashrc` generated for every new app user (Laravel and custom) now defines `alias ll='ls -al'` for quicker directory listings over SSH. **Migration 4.5.5** retro-fits existing apps: it appends the alias to each app's `~/.bashrc` once (only when missing, preserving ownership), so apps created before 4.5.5 get it on the next `cipi self-update`.

---

## [4.5.4] — 2026-06-02

### Changed

- **PHP < 8.3 can no longer be installed** — Cipi now bundles **Deployer 8** (the current major, downloaded as the latest `deployer.org/deployer.phar`), which requires **PHP >= 8.3**. Because `dep` is executed with the _app's_ PHP version (`/usr/bin/php${php_ver} /usr/local/bin/dep deploy …`), running the v8 phar under PHP 7.4/8.0/8.1/8.2 would break every deploy. To prevent that mismatch at the source, **`validate_php_version` now accepts only `8.3`, `8.4`, `8.5`**, so `cipi php install`, `cipi php switch`, `cipi app create` and `cipi app edit` reject older versions with a clear message. The PHP recipes (`lib/deployer/{laravel,custom}.php`) are PHP-based and unchanged in Deployer 8, so no recipe migration is needed. Legacy installs are still detectable and removable: **`cipi php remove`** uses the new **`validate_php_version_known`** helper (7.4–8.5) so you can clean up a pre-4.5.4 server with e.g. `cipi php remove 8.1`.

### Added

- **Deploy-time guard for apps still on PHP < 8.3** — restricting _installs_ doesn't help servers that already host apps pinned to old PHP. **`cipi deploy <app>`** and **`cipi deploy <app> --rollback`** now call `_deploy_assert_php_compat`, which checks the **actually installed** Deployer major (`deployer_major_version`, parsed from `dep --version`): only when **Deployer 8+** is present _and_ the app's PHP fails `validate_php_version` does it abort **before** invoking `dep`, with a clear "upgrade to 8.3/8.4/8.5" message instead of a cryptic phar parse error. Under Deployer 7 it's a no-op (those apps still deploy). **Migration 4.5.4** performs the same check once at update time — gated on Deployer 8+ — and prints the list of affected apps so operators know exactly what to upgrade (it changes nothing).

---

## [4.5.3] — 2026-06-02

### Fixed

- **Panel API HTTP 500 after every self-update (the _real_ root cause)** — `lib/self-update.sh` runs `chown -R root:root /opt/cipi` on each update (including the nightly 03:50 cron), which also re-roots the Laravel panel app under `/opt/cipi/api`. With `storage/`, `database/` and `bootstrap/cache/` owned `root:root`, PHP-FPM (`www-data`) can no longer open `storage/logs/laravel.log` or write the SQLite DB — Laravel then fatals _while trying to log the error_ (`UnexpectedValueException: ... laravel.log ... Permission denied`), so the browser only sees a bare `HTTP ERROR 500`. The compensating `www-data` re-chown lived **inside** the `cipi-api` package block, which is skipped when `/opt/cipi/cipi-api` is absent (package installed from Packagist) — so the panel stayed broken after each update. This is what the 4.5.0/4.5.1 work (FPM pool, sessions, job/metrics pruning) never addressed, because those targeted _symptoms_, not the ownership reset. Fix: `cipi self-update` now calls **`ensure_cipi_api_permissions` unconditionally right after the root chown**, and **`lib/migrations/4.5.3.sh`** repairs already-broken servers (reclaims `storage`/`database`/`bootstrap-cache`/`.env` for `www-data`, clears stale root-owned config cache, restarts FPM + queue). Immediate manual fix on an affected server: `cipi api fix-permissions && systemctl restart php8.5-fpm`.

---

## [4.5.2] — 2026-06-02

### Added

- **HTTP basic auth for apps** — protect any app (Laravel or custom) behind an Nginx username/password prompt: **`cipi basicauth enable <app> [--user=NAME] [--password=PASS]`**, **`cipi basicauth disable <app>`**, **`cipi basicauth status <app>`**. Credentials are stored in `/etc/nginx/cipi-basicauth/<app>.htpasswd` (hashed with `openssl passwd -apr1`, no `apache2-utils` needed); state lives in `apps.json` (`basic_auth`). The `auth_basic` directives are injected into the app's `location` blocks by `_create_nginx_vhost`, so protection survives vhost regeneration (alias add/remove, PHP edit) and certbot clones it into the `:443` block — HTTPS is covered too. ACME challenges stay public (auth is injected per-location, not at server level), and toggling re-runs `certbot install` (no new issuance, no rate-limit risk) so HTTPS is never dropped. Removed automatically on `cipi app delete`. Distinct from `cipi auth` (Composer `auth.json`).

### Fixed

- **Panel API still 500s "after a while"** — 4.5.1 wired up the panel scheduler and pruned `cipi-job-logs`, `cipi_jobs`/`failed_jobs`, and the WAL, but missed the last unbounded-growth source: the `cipi-api` package's `cipi:record-server-metrics` runs **every minute** (~1440 rows/day) and **no job ever prunes the metrics table**. Within a few months it reaches hundreds of thousands of rows; the dashboard / `/api` server endpoints full-scan it on every load until a query crosses PHP-FPM's `request_terminate_timeout` (300s), the worker is `SIGKILL`'d mid-request, and the browser gets an opaque `HTTP ERROR 500` — intermittent at first, then constant. **`cipi-api-maintain`** now prunes the server-metrics table to **14 days** as well (table + timestamp column auto-discovered from the SQLite schema, so it stays correct across package versions), then runs the `wal_checkpoint(TRUNCATE)`. **`lib/migrations/4.5.2.sh`** retrofits existing servers: rewrites the maintenance helper and runs an immediate prune + WAL truncate so operators don't wait until 04:15.
- **Self-update backups filling `/opt`** — `cipi self-update` copied `/opt/cipi` to `/opt/cipi.bak.<timestamp>` before every run (including daily cron @ 03:50) but never deleted old copies. After `self-update`, Cipi now keeps only the **7 newest** `cipi.bak.*` directories and removes the rest.

---

## [4.5.1] — 2026-05-21

### Fixed

- **Panel API: recurring 500s on `/` and `/api/*` while user apps stayed up** — 4.5.0 fixed the _acute_ FPM saturation symptom, but the _chronic_ cause was untouched: the `cipi-api` Laravel package (v1.7.0+) registers scheduled commands (`cipi:prune-job-logs` daily @ 03:30, `cipi:record-server-metrics` every minute) and the cipi installer **never wired up `* * * * * php artisan schedule:run` for `/opt/cipi/api`** — user apps had it via their per-user crontab; the panel did not. Over weeks of operation this produced:
  - `storage/app/cipi-job-logs/{uuid}.log` accumulating forever (one file per deploy / artisan / MCP / `sudo cipi db …` call invoked via the API), eventually exhausting disk space or inodes → `fopen()` failures surfaced as opaque 500s on the panel while per-app vhosts (separate pool, separate writes) kept serving.
  - `cipi_jobs` and `failed_jobs` rows accumulating forever in the panel SQLite, slowing every authenticated request and bloating WAL.
  - `database.sqlite-wal` growing unbounded — `PASSIVE` auto-checkpoints don't reclaim space under concurrent FPM + queue writers.
  - Laravel session files piling up under the default `file` driver. The welcome route's `web` middleware writes one file per anonymous hit (bots, uptime monitors); GC is probabilistic (2/100) so low-traffic panels effectively never GC. Once the sessions dir grew large enough, `scandir()` stalled FPM workers past `request_terminate_timeout`.

  Fixed by wiring the Laravel scheduler into system cron for the panel app, adding a daily maintenance job for the SQLite cleanups, and switching the panel to the `array` session driver so the welcome page no longer writes to disk per request.

### Added

- **`/etc/cron.d/cipi-api`** — installed by `_api_setup_cron` (in `lib/api.sh`) and by migration 4.5.1 on existing servers. Two entries: `* * * * *` runs `php /opt/cipi/api/artisan schedule:run` as `www-data` (drives the cipi-api package's scheduled commands); `15 4 * * *` runs `/usr/local/bin/cipi-api-maintain` daily for the SQLite cleanups.
- **`/usr/local/bin/cipi-api-maintain`** — daily maintenance helper. Runs `php artisan queue:prune-failed --hours=336`, deletes `cipi_jobs` rows older than 14 days that are `completed` or `failed` (running/pending are preserved), and runs `PRAGMA wal_checkpoint(TRUNCATE)` to reclaim WAL space.
- **`lib/migrations/4.5.1.sh`** — retrofits installed servers: lays down the two cron files, sets `SESSION_DRIVER=array` in `.env`, prunes accumulated `cipi-job-logs/*.log` older than 14 days, runs an immediate `cipi_jobs` + `queue:prune-failed` + WAL truncate so operators see the benefit without waiting for 04:15, and reloads `cron`. Idempotent.
- **Logrotate for the maintenance log** — `/etc/logrotate.d/cipi-api-maintain` keeps `/var/log/cipi-api-maintain.log` bounded (weekly, 8 rotations, `copytruncate`).

### Changed

- **`SESSION_DRIVER=array`** is now forced in `/opt/cipi/api/.env` on install/update/upgrade/migration (the panel is token-only; persistent sessions only added disk thrash).
- **`api_setup` / `api_update` / `api_upgrade`** all call `_api_setup_cron` and `_api_ensure_session_driver_env` now, so any path through the API installer leaves the cron + env in the correct state.

---

## [4.5.0] — 2026-05-04

### Fixed

- **Panel API: silent 500 under load (no log written)** — Long sync calls in the API (deploy, artisan, MCP, `sudo cipi …`) saturated a too-small PHP-FPM pool (`pm.max_children = 10`); when `request_terminate_timeout = 300` fired, FPM `SIGKILL`'d workers mid-request, so Laravel's exception handler never ran and **nothing reached `storage/logs/laravel.log` or `cipi-api-php-error.log`** — the only trace was in `journalctl -u php<ver>-fpm`. Fixed by enlarging the pool, adding a slowlog (PHP backtrace 30s before the kill), and capturing child stderr in the FPM log.
- **Panel API: `database is locked` 500s** — SQLite default `journal_mode=DELETE` plus Laravel's ~5s `busy_timeout` caused contention between the `cipi-queue` worker and FPM children under burst traffic. Switched the panel SQLite DB to **`WAL` + `synchronous=NORMAL` + `busy_timeout=15000`** (set on every `cipi api setup|update|upgrade` and on existing servers via migration 4.5.0).
- **`cipi-queue` memory drift** — The systemd worker ran `queue:work` indefinitely; long-lived PHP processes leak memory. Now restarted automatically every hour or 200 jobs (`--max-time=3600 --max-jobs=200 --rest=1`).

### Changed

- **PHP-FPM pool for the Panel API** — `_api_create_fpm_pool` (in `lib/api.sh`) and `lib/migrations/4.5.0.sh` now write a tuned pool: `pm.max_children = 25`, `pm.start_servers = 4`, `pm.min_spare_servers = 2`, `pm.max_spare_servers = 8`, `pm.max_requests = 200`, `pm.process_idle_timeout = 60s`, `listen.backlog = 1024`. Added **`request_slowlog_timeout = 30`** with `slowlog = /var/log/cipi-api-fpm-slow.log` and **`catch_workers_output = yes`** so child stderr/fatals land in the FPM log even when a worker dies before Laravel can log. The PHP child `error_log` moved from `/var/log/nginx/cipi-api-php-error.log` (logically Nginx's) to **`/var/log/cipi-api-php-error.log`**, registered in a new `logrotate.d/cipi-api-logs`.
- **Nginx vhost for the Panel API** — `_api_create_nginx_vhost` now sets explicit FastCGI buffers (`fastcgi_buffers 16 32k`, `fastcgi_buffer_size 64k`, `fastcgi_busy_buffers_size 128k`) and adds a local-only `location = /cipi-api-fpm-status` (`allow 127.0.0.1`) used by `cipi api status` to read pool stats.
- **Laravel logging defaults** — `LOG_CHANNEL=stack` and `LOG_STACK=single,stderr` are now forced in `/opt/cipi/api/.env` on install/update/upgrade/migration, mirroring errors to FPM stdout/stderr so they survive a `SIGKILL`'d worker.
- **`cipi api status`** — Now also prints active/idle FPM workers, listen queue depth, and slowlog hits (when present), so operators can see pool saturation at a glance.

### Added

- **`lib/migrations/4.5.0.sh`** — Retrofits installed servers (auto-detects the PHP version actively running the API pool) by rewriting `cipi-api.conf`, `cipi-queue.service`, the Nginx vhost, `.env` log channels, the SQLite pragmas, and the logrotate config. Runs `certbot --nginx --reinstall` when an SSL cert exists, so the redirect/443 block survives the vhost rewrite. Idempotent and safe to re-run.

---

## [4.4.19] — 2026-04-16

### Fixed

- **`cipi app delete` — leftover Linux group blocking recreate** — On app create, `useradd` creates a private primary group named like the user and `usermod -aG "$app" www-data` adds `www-data` to that group. `userdel -r` removes the user and home directory but **does not always** remove the matching group from `/etc/group`. Recreating the same app then failed with `useradd: group <app> exists`. `app_delete` now runs `gpasswd -d www-data "$app"` (drop `www-data` from the group), then `userdel -r`, then `groupdel "$app"`. On servers already in a bad state, clean up manually with `gpasswd -d www-data <app> 2>/dev/null; groupdel <app> 2>/dev/null` before `cipi app create`.

---

## [4.4.18] — 2026-04-06

### Fixed

- **App crontabs wiped by migration 4.4.14** — The `sed` command in migration 4.4.14 used `|` as delimiter while the replacement string contained `||` (bash OR for `cipi-app-notify`). `sed` interpreted the first `|` of `||` as end-of-replacement, failed to parse, and produced empty output — which `crontab -u <user> -` then installed as an empty crontab, wiping both the **Laravel Scheduler** (`schedule:run`) and the **deploy trigger** for every app. Fixed the 4.4.14 `sed` to use `#` as delimiter. **Migration 4.4.18** detects apps missing `schedule:run` and re-creates the full crontab (scheduler + deploy trigger + failure notification).

---

## [4.4.17] — 2026-04-03

### Fixed

- **Panel API database commands / `sudo: a terminal is required`** — `/etc/sudoers.d/cipi-api` allowed `www-data` to run only `cipi app|deploy|alias|ssl` and `cat apps.json`, not **`cipi db`**. Any `sudo cipi db …` from PHP (sync `GET /api/dbs` or queue jobs) therefore asked for a password and failed without a TTY. The whitelist now includes **`db list`**, **`db create`**, **`db delete`**, **`db backup`**, **`db restore`** (two args), and **`db password`**. New installs get this from **`setup.sh`**; existing servers via **migration 4.4.17** (runs on `cipi self-update`).

---

## [4.4.16] — 2026-04-03

### Fixed

- **Panel API readonly SQLite / log permission errors** — Root-run `composer` (e.g. during `cipi self-update`) could leave `database.sqlite` or `storage/logs` owned by root before `migrate`, causing _attempt to write a readonly database_ and Monolog _Permission denied_ on `laravel.log`. Added **`ensure_cipi_api_permissions`** in `common.sh` (chown `storage`, `database`, `bootstrap/cache` → `www-data`, plus **`/opt/cipi/api/.env`** → `www-data`, mode `640`), invoked before API token commands, `api status`, `api update`, and after API install; **`cipi self-update`** now runs full `chown` immediately after `composer update` and runs `vendor:publish` as `www-data`. New command **`cipi api fix-permissions`** for manual repair. **`Migration 4.4.16`** also creates **`www-data`**’s PsySH config dir so **`cipi api status`** (tinker) is reliable.

- **`cipi api status` appeared to hang after Domain** — Status prints **Queue** first. **Laravel** and **cipi-api** versions are read from **`composer.lock`** via **`jq`** (no **`php artisan`** / **`composer show`** bootstrap). Pending job count uses **`sqlite3`** on the panel SQLite DB when **`DB_CONNECTION=sqlite`**; **`tinker`** is only a fallback with a short **`timeout`**. **`timeout`** still applies to rare fallbacks; **`_api_ensure_psysh_home`** on new installs. Servers **already on 4.4.16** before this revision can run **`cipi api fix-permissions`** once (migration does not re-run).

- **`cipi api token create` appeared to hang** — The ability menu ran inside command substitution `$(...)`, so prompts were written to **stdout** (captured) instead of the terminal; `read` waited with no visible UI. Menu and prompt now go to **stderr**; input is read from **`/dev/tty`** when available.

### Changed

- **`cipi api token create` abilities** — The interactive ability list now matches the [Cipi API docs](https://cipi.sh/docs/advanced#cipi-api): added **`deploy-manage`**, **`dbs-view`**, **`dbs-create`**, **`dbs-delete`**, **`dbs-manage`**, and **`apps-view`**. The whiptail fullscreen checklist is replaced by a **plain-terminal** checklist (numbered rows, ✓/· markers, toggle by number, `a`/`n`/`Enter`).

---

## [4.4.15] — 2026-04-03

### Changed

- **Root crontab S3 backup/prune — all apps** — `cipi backup configure` now appends default root cron lines that run **`cipi backup run`** and **`cipi backup prune --weeks=4`** (no per-app name), unless a `cipi backup run` line already exists. **Migration 4.4.15** rewrites existing root crontab entries from `cipi backup run <app>` / `cipi backup prune <app> --weeks=N` to the global form and drops duplicate lines after normalization.

---

## [4.4.14] — 2026-04-03

### Fixed

- **SMTP alerts for webhook/cron deploy failures** — Deploys triggered by `.deploy-trigger` (cipi/agent webhook) ran `dep deploy` as the app user with no notification path; only interactive `cipi deploy` called `cipi_notify`. Added **`/usr/local/bin/cipi-app-notify`**, invoked via `sudo` from the deploy-trigger crontab on non-zero exit, which reads `smtp.json` as root and emails the last lines of `logs/deploy.log`. New Laravel apps get an updated crontab line and sudoers rule; **migration 4.4.14** updates existing apps.

---

## [4.4.13] — 2026-04-02

### Fixed

- **Root-owned Laravel logs (`shared/storage/logs/laravel-*.log`)** — Old logrotate `create 0640 root root` left rotated log files owned by `root:root`. The app user could not read them, breaking `spatie/laravel-backup` (ZipArchive Permission denied) and other tools that access logs. `ensure_app_logs_permissions` now reclaims root-owned files in both `logs/` and `shared/storage/logs/`, restoring ownership to the app user. **Migration 4.4.13** runs this for all apps.

---

## [4.4.12] — 2026-04-02

### Fixed

- **Deployer `writable_dirs`: `set()` instead of `add()`** — The Laravel recipe (`recipe/laravel.php`) already defines `writable_dirs` with `storage` and `storage/logs`; using `add()` appended our list but kept those entries, so `chmod -R` still touched `laravel-*.log`. Changed to **`set('writable_dirs', [...])`** to fully override the recipe defaults. **Migration 4.4.12** regenerates `deploy.php` for all Laravel apps.

---

## [4.4.11] — 2026-04-02

### Fixed

- **Deploy `deploy:writable` / chmod on `storage/logs/*.log`** — Deployer was running `chmod -R` on **`storage`** and **`storage/logs`**, so it tried to change mode on existing `laravel-*.log` files (EPERM with ACLs or other attributes). **`writable_dirs`** now lists only concrete subdirs under `storage` (app, framework, …), **not** the parent `storage` or `storage/logs`. A follow-up task sets **`chmod 775`** on the **`storage/logs` directory only** (no recursive file chmod). **`lib/deployer/laravel.php`** is updated; **migration 4.4.11** regenerates `/home/*/.deployer/deploy.php` from the template for every non-custom app (overwrites local `deploy.php`).

---

## [4.4.10] — 2026-04-02

### Fixed

- **Deploy `deploy:writable` / chmod on `storage/logs/*.log`** — Residual per-file ACLs on Laravel logs (from older Cipi) still caused _Operation not permitted_ during `chmod`. `ensure_app_logs_permissions` now strips file ACLs and default ACL on `logs/` and `shared/storage/logs` **before** re-applying directory-only ACLs for `cipi`. **`cipi deploy <app>`** runs this automatically before Deployer. **Migration 4.4.10** applies the same once on existing servers.

---

## [4.4.9] — 2026-04-02

### Fixed

- **`common.sh` defaults vs readonly `CIPI_*`** — Replaced `: "${CIPI_CONFIG:=...}"` with `if [[ -z "${CIPI_CONFIG:-}" ]]; then … fi` (and the same for `CIPI_LOG`). If a server never completed `self-update` after 4.4.6, `/opt/cipi/lib/common.sh` could still contain a plain `CIPI_CONFIG=…` assignment on line 7; that blocks every `cipi` run until the file is replaced.
- **Stuck servers** — If `cipi self-update` fails before fixing `common.sh`, run once as root: `curl -fsSL https://raw.githubusercontent.com/cipi-sh/cipi/latest/lib/fix-common-readonly.sh | bash` (see `lib/fix-common-readonly.sh`), then `cipi self-update`.

---

## [4.4.8] — 2026-04-02

### Fixed

- **`common.sh` vs readonly `CIPI_CONFIG` / `CIPI_LOG`** — The main `cipi` binary sets these as `readonly` before sourcing `common.sh`; assigning `CIPI_CONFIG=...` caused _readonly variable_. Defaults now use `: "${CIPI_CONFIG:=...}"` / `: "${CIPI_LOG:=...}"` so existing readonly values are left unchanged and migrations still get defaults when unset.

---

## [4.4.7] — 2026-04-02

### Fixed

- **Migration / `common.sh` when sourced standalone** — If `CIPI_LOG` was unset (e.g. migration 4.4.6 sourcing `common.sh`), `mkdir -p "${CIPI_LOG}"` expanded to an empty path. `common.sh` now defaults `CIPI_CONFIG` and `CIPI_LOG` before loading the vault.
- **Deploy `deploy:writable` / chmod on Laravel logs** — ACLs applied with `setfacl -R` and default ACLs on `shared/storage/logs` caused `chmod` to fail with _Operation not permitted_ on existing `laravel-*.log` files. Directory-only ACLs for `cipi` are kept; per-file and default ACLs on that tree are removed. **Migration 4.4.7** clears those ACLs on existing servers and reapplies the corrected layout.

---

## [4.4.6] — 2026-04-02

### Fixed

- **App log access (`logs/`, Laravel `storage/logs`)** — App home directories are `750` (`app:app`), so the `cipi` user could not traverse `/home/<app>/` to read logs without root. Nginx vhost logs are written by `www-data`; logrotate used `create 0640 root …`, so after rotation files could be owned by `root` and no longer writable/readable as intended. New installs and migration **4.4.6** set `logs/` to `app:www-data` with setgid `2775`, apply **ACLs** so `cipi` can traverse the home and read logs, replace logrotate `create` with **`copytruncate`** (keeps correct ownership), and repair existing root-owned log files under `/home/*/logs/`.

### Added

- **`ensure_app_logs_permissions`** in `lib/common.sh` — Called from `cipi app create` and sync app import so new apps get the same layout from day one.

---

## [4.4.5] — 2026-03-23

### Added

- **PHP Redis extension (phpredis)** — The installer and `cipi php install <ver>` now include the `redis` package (`php*-redis`), so the phpredis extension is available for Laravel and other apps using the native Redis client
- **Migration 4.4.5** — On `cipi self-update`, existing servers automatically install `php*-redis` for every PHP version already present (7.4–8.5 with FPM), then reload PHP-FPM

### Changed

- **Post-install summary** — The final screen after `setup.sh` no longer prints the **Stack** block (Nginx, MariaDB, Redis, PHP, Node.js, Composer, Deployer versions); it goes from **Server** (IP, OS) straight to credentials and next steps

---

## [4.4.4] — 2026-03-20

### Added

- **Optional Git for custom apps** — On `cipi app create --custom`, the Git repository prompt can be left empty to provision SFTP-only hosting (no clone): `htdocs` is created with a placeholder page, branch is omitted, and `cipi deploy` explains that there is no repository until you set one with `cipi app edit <app> --repository=...`.

---

## [4.3.3] — 2026-03-18

### Added

- **`cipi app create --custom`** — Creates a custom app with classic deploy (no zero-downtime): code is deployed into `htdocs` (no `current`/`shared` symlinks). During creation you only choose document root (default `/`, or e.g. `www`, `dist`, `public`). Nginx is fixed: `index index.html index.php`, `try_files $uri $uri/ /index.php?$args`, `error_page 404 /404.html` (no prompts for try_files or entry point). Custom apps have no database, no `.env`, no cron, no queue workers, no webhook; post-creation summary shows only SSH, deploy key, and next steps.

### Changed

- **App types** — `cipi app create` now supports only **Laravel** (default) and **`--custom`**.
- **`cipi app show`** — Displays type "Custom" and docroot when applicable; Webhook line is shown only for Laravel apps.
- **`cipi app env`** — Exits with an error for custom apps (no .env).
- **`cipi app reset-db-password`** — Exits with an error for custom apps (no database).
- **`cipi app delete`** — Skips database drop for custom apps (none was created).

---

## [4.3.2] — 2026-03-14

### Added

- **Server IP in app creation summary** — `cipi app create` now shows the server's public IP address right below the domain in the post-creation summary, making it easy to configure DNS records without leaving the terminal
- **MariaDB connection URL in app creation summary** — `cipi app create` now displays a ready-to-use `mariadb+ssh://` connection URL after the database credentials; the URL includes SSH credentials, server IP, database credentials, and database name in a single copyable string (e.g. `mariadb+ssh://user:sshpass@1.2.3.4/user:dbpass@127.0.0.1/user`), useful for connecting from database clients like TablePlus, DBeaver, or Sequel Pro via SSH tunnel

### Changed

- **PHP 8.5 as sole pre-installed version** — The installer now installs only PHP 8.5 instead of both 8.4 and 8.5; PHP 8.5 is the default CLI version and the runtime used by the Cipi API FPM pool; other PHP versions (7.4–8.4) can still be installed on demand via `cipi php install <version>`
- **Default PHP for new apps set to 8.5** — `cipi app create` now defaults to PHP 8.5 when no `--php` flag is provided

### Fixed

- **MariaDB version "N/A" in post-install summary** — `grep -oP` (Perl regex) is not available in all environments; replaced with portable `awk` parsing and redirected stderr to stdout (`2>&1`) since `mariadb --version` may write to stderr

---

## [4.3.1] — 2026-03-12

### Fixed

- **Self-update crash on version upgrade** — The `cipi` main script was read lazily by bash; when `cipi self-update` replaced the file on disk mid-execution, bash would resume reading the new file at the old byte offset, causing `syntax error near unexpected token ';;'` whenever the new version had different line lengths (e.g. added commands); wrapped the entire script in a `{ …; exit; }` block so bash reads it fully into memory before executing, making on-disk replacement safe

---

## [4.3.0] — 2026-03-11

### Added

- **`cipi ban list`** — List all IPs currently banned by fail2ban, grouped by jail
- **`cipi ban unban <IP>`** — Unban a specific IP from all fail2ban jails

### Changed

- **Fail2ban hardening** — Progressive banning with exponential backoff (24h base, doubles each time, 7-day cap); reduced max retries from 5 to 3; added `recidive` jail that bans repeat offenders for 7 days after 3 bans in 24h; migration 4.3.0 upgrades existing installations automatically

---

## [4.2.9] — 2026-03-11

### Added

- **`cipi php switch <ver>`** — Switch the system default PHP version used by root/cipi; migrates the API FPM pool, restarts the API queue worker, and sends email notification; `cipi php list` now shows which version is the system default; `cipi php remove` now blocks removing the system default version

### Fixed

- **App commands use wrong PHP version** — Deployer (`dep`), Composer, and all deploy-related commands now run with the app's configured PHP version (`/usr/bin/phpX.Y`) instead of the system default; affects `cipi deploy`, `cipi deploy --rollback`, crontab deploy triggers, `.bashrc` aliases (`deploy`, `composer`), and `cipi sync import` deploys; Deployer config now explicitly sets `bin/composer` to use the app's PHP; migration 4.2.9 patches all existing apps automatically

---

## [4.2.8] — 2026-03-11

### Fixed

- **MariaDB version detection** — Installation summary showed the mysql client protocol number (e.g. `15.2`) instead of the actual MariaDB server version; replaced deprecated `mysql --version` with `mariadb --version` and proper `Distrib` field parsing

### Changed

- **su elevation notifications** — Restricted `su` email alerts to only the `cipi → root` escalation; all other `su` transitions are now silently ignored to reduce noise

---

## [4.2.7] — 2026-03-10

### Fixed

- **Workers stuck in EXITED** — Supervisor `autorestart=unexpected` (introduced in 4.1.2) prevented workers from restarting after a graceful `--max-time` exit (exit code 0); reverted to `autorestart=true` which is safe because `supervisorctl stop` (used during deploys) puts processes in STOPPED state, which Supervisor never auto-restarts regardless of the `autorestart` setting

---

## [4.2.6] — 2026-03-10

### Fixed

- **Git clone non-interactive** — `setup.sh` and `self-update.sh` now set `GIT_TERMINAL_PROMPT=0` on `git clone` commands to prevent credential prompts in automated/piped environments
- **Sudo notification spam during deploy** — PAM auth notifications were triggered when app users executed `sudo cipi-worker stop/restart` during deploys; `_is_internal()` now detects `/usr/local/bin/cipi` commands and Deployer (`dep`) in the process tree, suppressing notifications for all cipi-initiated sudo operations

### Changed

- **Official repo only** — removed `andreapollastri/cipi` fallback from `setup.sh` and `self-update.sh`; all references now point exclusively to `cipi-sh/cipi`

### Note

If you have issues with `cipi self-update` after 4.2.5, run:
`sed -i 's/^    git clone/    GIT_TERMINAL_PROMPT=0 git clone/' /opt/cipi/lib/self-update.sh`

---

## [4.2.5] — 2026-03-09

### Changed

- **GitHub organization migration** — moved repos to [cipi-sh](https://github.com/cipi-sh/) organization; Composer package names updated from `andreapollastri/cipi-api` → `cipi/api` and `andreapollastri/cipi-agent` → `cipi/agent`
- **Self-update & installer fallback** — `setup.sh` and `self-update.sh` now try `cipi-sh/cipi` first, falling back to `andreapollastri/cipi` for backward compatibility during the main repo transition
- **Migration 4.2.5** — automatically migrates existing installations: replaces old Composer package in the API app and updates crontab references

### Note

Cipi has been moved to organization namespace. If you have issues within self-update command after this version, run:
`sed -i 's/^    git clone/    GIT_TERMINAL_PROMPT=0 git clone/' /opt/cipi/lib/self-update.sh` to fix it!

---

## [4.2.4] — 2026-03-09

### Added

- **Centralized security event log** — all security-relevant events (SSH key changes, app lifecycle, password resets, sudo/su/SSH login, cron failures) are always logged to `/var/log/cipi/events.log` in a compact one-line format, regardless of whether SMTP is configured; `log_event()` helper in `common.sh` and inline logging in PAM and cron notification scripts
- **`su` PAM notifications** — PAM auth notification now covers `su` in addition to `sudo` and `sshd`; alerts include who ran `su`, the target user, SSH key, and client IP; PAM rule added to `/etc/pam.d/su` in both `setup.sh` and migration `4.2.3.sh`
- **Client identity in all notifications** — every email notification sent via `cipi_notify()` now includes a footer with the client IP (`SSH_CLIENT`) and the SSH key name used to authenticate; key name is resolved via `SSH_USER_AUTH` with `auth.log` fallback
- **Sudo command in notifications** — sudo alerts now include the command that was executed (`SUDO_COMMAND`)
- **SSH key rename notification** — email alert when an SSH key is renamed; includes old name, new name, fingerprint, server hostname, and timestamp

### Fixed

- **SSH key fingerprint resolution** — `SSH_USER_AUTH` contains raw key data (`type base64`), not a fingerprint; fixed `_resolve_ssh_key_name()` (PAM script), `_get_session_fingerprint()` (`ssh.sh`) and `_get_session_key_name()` (`common.sh`) to reconstruct the fingerprint via `ssh-keygen -lf -` instead of reading field 3 directly
- **Email `\n` literal** — `_smtp_send` now uses `printf %b` instead of `%s` for the body so escape sequences are interpreted correctly
- **Backup S3 region handling** — `_aws_s3()` now passes `--region` from `backup.json` (defaults to `eu-central-1`); fixes `NoneType is not iterable` errors on S3-compatible APIs when region is empty
- **Crontab setup error** — `setup_cron` no longer fails when no existing crontab is present (`|| true` guard on `crontab -l`)
- **Installer resilience** — `setup_pam` and `setup_cron` failures no longer abort the entire installation; errors are logged with a warning and setup continues

### Changed

- **Privileged-to-inferior suppression** — PAM auth notifications from `cipi`/`root` towards non-sudo app users are now suppressed unless the action is part of an app create/edit/delete lifecycle operation; reduces noise from routine app provisioning
- **Sync push improvements** — uses cipi's ed25519 sync key explicitly (`-i /home/cipi/.ssh/id_ed25519`); rsync failure gracefully falls back to scp; remote Cipi version checked via `sudo cipi version` instead of reading `/etc/cipi/version`; export suppresses manual transfer instructions during push; archive cleaned up after successful import; `scp` examples updated to use `cipi` user
- **SSH key rename logging** — `log_action` now includes old and new key name for rename operations

---

## [4.2.3] — 2026-03-09

### Fixed

- **SSH login notification showing "SSH Key: unknown"** — PAM auth notification script could not resolve the SSH key name on login because `SSH_USER_AUTH` is not yet available in the sshd PAM session context; added fallback that parses `/var/log/auth.log` for the `Accepted publickey` fingerprint and matches it against `authorized_keys` to resolve the key comment/name
- **Email notifications literal `\n`** — all notifications sent via `cipi_notify()` showed literal `\n` instead of line breaks; fixed `_smtp_send` to use `printf %b` for the body so escape sequences are interpreted correctly

### Added

- **SSH key rename notification** — email alert via SMTP when an SSH key is renamed; includes old name, new name, fingerprint, server hostname, and timestamp
- **Client identity in all notifications** — every email notification now includes a footer with the client IP (`SSH_CLIENT`) and the SSH key name used to authenticate; key name is resolved via `SSH_USER_AUTH` with `auth.log` fallback
- **`su` elevation notification** — PAM auth notification now covers `su` in addition to `sudo` and `sshd`; alerts include who ran `su`, the target user, SSH key, and client IP
- **Security event log** — all notification events (SSH key changes, app lifecycle, password resets, sudo/su/SSH login, cron failures) are always logged to `/var/log/cipi/events.log` in a compact one-line format, regardless of whether SMTP is configured; rotated daily with 1-year retention via existing logrotate config

---

## [4.2.2] — 2026-03-08

### Fixed

- **Nginx default host 404** — requests to unconfigured domains (e.g. server IP with random paths) now always serve the "Server Up" page instead of the default nginx 404 error; uses `rewrite` instead of `try_files` for reliable catch-all behavior
- **`cipi ssh list` / `cipi ssh remove` silent exit** — both commands printed the header but no keys; caused by `((i++))` returning exit code 1 when `i=0` (post-increment evaluates to 0 = falsy) under `set -euo pipefail`; fixed with `|| true` guard on all arithmetic increments
- **SSH key comment stripped on setup** — `collect_ssh_key()` used `awk '{print $1, $2}'` to sanitize input, discarding the comment field (third+ column); keys added during install were always stored without their original comment

### Changed

- **PAM auth notifications** — now include SSH key fingerprint/comment for both sudo and SSH login alerts; key is resolved via `ExposeAuthInfo` + `SSH_USER_AUTH`
- **SSH access model** — replaced `AllowUsers cipi` with group-based access (`AllowGroups cipi-ssh cipi-apps`); `cipi` user remains key-only; app users can now SSH directly with username and password via `Match Group cipi-apps` block that enables `PasswordAuthentication` selectively

### Added

- **App lifecycle notifications** — email alerts on app create, edit, and delete; includes server hostname, app name, domain, PHP version, and change details; sensitive data (passwords, tokens, keys) is never included
- **`cipi app reset-password <app>`** — regenerate the SSH password for an app's Linux user; displays new password once and sends email notification
- **`cipi app reset-db-password <app>`** — regenerate the MariaDB password for an app user; automatically updates `DB_PASSWORD` in the app's `.env` file
- **`cipi reset root-password`** — regenerate the root SSH password and update `server.json` in the vault
- **`cipi reset db-password`** — regenerate the MariaDB root password and update `server.json` in the vault
- **`cipi reset redis-password`** — regenerate the Redis password, restart Redis, and update `server.json` in the vault; warns about updating app `.env` files
- **`cipi ssh rename [number] [name]`** — set or change the display name of an SSH key; updates the comment field in `authorized_keys`; interactive selection if called without arguments

### Security

- **Sudoers hardening** — `www-data` sudo access restricted from wildcard (`cipi *`) to an explicit whitelist of API commands only (`app create/edit/delete`, `deploy`, `alias add/remove`, `ssl install`, `cat apps.json`); prevents privilege escalation from a compromised PHP process
- **Command injection fix** — replaced unsafe `eval` with `printf -v` in `read_input()` and `parse_args()` (`common.sh`); user input is no longer interpreted by the shell
- **Sed injection fix** — `branch` and `repository` values are now escaped before interpolation in `sed` commands (`app.sh`); prevents injection via special characters (`|`, `&`, `\`)
- **API command whitelist** — `CipiCliService` now validates commands against an `ALLOWED_COMMANDS` whitelist before executing `sudo cipi`; provides defence-in-depth alongside sudoers

---

## [4.2.1] — 2026-03-08

### Added

- **Non-interactive SSH key input** — `setup.sh` now accepts `SSH_PUBKEY` environment variable for non-interactive installs (e.g. `SSH_PUBKEY="ssh-rsa ..." bash setup.sh`)
- **Random root password** — installer generates a 32-character random root password, saves it in server.json, and displays it in the final summary
- **SSH key setup instructions** — clearer installer prompt: shows accepted key formats (ssh-rsa, ssh-ed25519, ecdsa) for existing keys, and RSA 4096 generation command for new keys

### Security

- **`su` restricted to sudo group** — application users can no longer use `su` to elevate to root or cipi (via `pam_wheel.so group=sudo`)

### Fixed

- **SSH key paste in `curl | bash`** — `read` now reads from `/dev/tty` so interactive input works when setup is piped via curl
- **SSH key sanitization** — automatically strips comments, carriage returns, and extra whitespace from pasted keys before validation
- **SSH service restart on Ubuntu 24.04** — use `ssh` service name with `sshd` fallback for compatibility across distributions
- **server.json missing during SSH hardening** — installer now creates `/etc/cipi/server.json` before writing to it, and MariaDB setup merges instead of overwriting

---

## [4.2.0] — 2026-03-08

### Added

- **SSH hardening at install** — `setup.sh` now asks for an SSH public key during installation (before any package install begins); creates a dedicated `cipi` user as the only SSH entry point; disables root login and password authentication
  - `PermitRootLogin no`, `PasswordAuthentication no`, `PubkeyAuthentication yes`, `AllowUsers cipi`, `MaxAuthTries 3`, `LoginGraceTime 20`, `X11Forwarding no`, `ExposeAuthInfo yes`
  - `cipi` user has passwordless sudo for `/usr/local/bin/cipi *` only
  - Server-to-server ed25519 keypair auto-generated for sync operations
- **`cipi ssh list`** — list all authorized SSH keys for the cipi user with fingerprint, comment, and current-session marker (`<< current session`)
- **`cipi ssh add [key]`** — add an SSH public key (interactive prompt if no argument); validates format, rejects duplicates; sends email notification via SMTP if configured
- **`cipi ssh remove [n]`** — remove an SSH key by number (interactive list if no argument); sends email notification via SMTP if configured
  - **Session safety** — detects the key used for the current SSH session (via `ExposeAuthInfo` + `SSH_USER_AUTH`) and blocks its removal
  - **Last-key safety** — prevents removing the last remaining key to avoid lockout
- **`cipi sync pubkey`** — display this server's sync public key (for server-to-server trust)
- **`cipi sync trust`** — add a remote server's public key to cipi's authorized_keys, enabling passwordless `cipi sync push` between servers
- **SSH key change notifications** — email alerts (via existing SMTP) on every key add/remove, including server hostname, IP, key fingerprint, comment, timestamp, and remaining key count

### Changed

- **Sync default user** — `cipi sync push` now connects as `cipi` (was `root`); remote commands use `sudo cipi` for privilege escalation
- **Sync troubleshooting** — updated help messages to reference `cipi sync trust` and `cipi sync pubkey` instead of `PermitRootLogin yes`
- **Installation summary** — now shows SSH access info (login command, root-login disabled, password-auth disabled) and the server sync public key
- **Sudoers** — `SSH_USER_AUTH` env variable preserved through sudo (`env_keep`) for session key detection
- **Nginx default vhost** — all requests to the server IP now serve the "Server Up" page instead of returning nginx default 404; custom `error_page` directive catches all error codes (400–504) and serves `/index.html`, preventing nginx version leaks in error pages

---

## [4.1.2] — 2026-03-07

### Fixed

- **Worker restart loop during deploy** — Supervisor no longer floods logs with `Could not open input file: /home/<app>/current/artisan` during deployments. Root cause: the worker process exited when the `current` symlink was briefly unavailable during `deploy:symlink`, triggering immediate Supervisor restarts before the new release was in place. Fix: Deployer now stops workers (`workers:stop`) **before** the symlink swap and restarts them **after** (`workers:restart`), ensuring zero restart attempts against a broken symlink
- **`cipi worker stop <app>`** — new CLI subcommand to cleanly stop all Supervisor workers for an app without removing their configuration
- **`cipi-worker stop`** — extended the sudoers-restricted helper to support `stop` action, enabling Deployer tasks to stop workers during deploy without elevated privileges
- **Supervisor `autorestart=unexpected`** — new worker configs now only auto-restart on unexpected exits with `startretries=5` and `startsecs=3`, reducing noise from transient failures
- **Sudoers** — `cipi-worker stop <app>` added to the sudoers whitelist in both `app create` and `cipi sync`

---

## [4.1.1] — 2026-03-06

### Added

- **Security auth notifications** — email alerts on sudo elevation and privileged SSH logins (requires SMTP configured):
  - **Sudo**: notifies when any user successfully elevates to root via `sudo`, including who ran it and from which TTY
  - **SSH login**: notifies when `root` or any sudoer logs in via SSH, including source IP
  - Integrated via PAM (`pam_exec.so`); runs asynchronously to avoid login delays; fails silently if SMTP is not configured
- **Auth notifications: suppress internal sudo events** — sudo notifications triggered by Cipi internal operations (API calls via PHP-FPM, queue workers, cron jobs, systemd services) are now silently skipped; only interactive sudo elevations from real SSH sessions generate alerts
  - Detection via kernel `loginuid` (primary) with process-tree inspection fallback (php-fpm, artisan queue, supervisord, cipi-queue)
- **Auth notifications: resolve "User: unknown"** — the `SUDO_USER` field in sudo alerts now correctly resolves the calling user via `loginuid` when the PAM environment does not propagate `$SUDO_USER`

### Fixed

- **Vault readonly guard** — `vault.sh` could crash with `readonly variable` error when sourced multiple times in the same shell (e.g. during PAM hooks or nested cipi calls)

---

## [4.1.0] — 2026-03-06

### Added

- **Sync: export/import/list** — transfer apps between CIPI servers
- **`cipi sync export [app ...] [--with-db] [--with-storage]`** — export all apps or specific ones to a portable `.tar.gz` archive including configs, SSH keys, deployer config, supervisor workers, and optionally database dumps and shared storage
- **`cipi sync import <file> [app ...] [--deploy] [--yes]`** — import apps from an archive into the current server; recreates users, databases (with new credentials), nginx vhosts, PHP-FPM pools, supervisor workers, crontabs, and deployer configs; selectively import specific apps from a multi-app archive
- **`cipi sync push [app ...] [--host=IP] [--port=22] [--with-db] [--with-storage] [--import]`** — export, transfer via rsync/scp to a remote server, and optionally run import on the remote; interactive prompts for SSH host/port with connectivity test and remote Cipi version check
- **`cipi sync list <file>`** — inspect archive contents without importing (apps, PHP versions, DB/storage inclusion)
- **`--update` mode for import** — when an app already exists on the target, incrementally syncs .env (preserving local DB credentials), database dump (drop + reimport), shared storage, supervisor workers, deployer config, nginx vhost (alias changes), and PHP version changes; new apps are created as before; `push --import` uses `--update` automatically
- Pre-flight checks on import: warns about missing PHP versions, blocks import of apps that already exist (unless `--update`); **domain conflict check** — blocks import if domain or alias is already used by another app on target or by another app in the same import batch
- `.env` DB credentials automatically updated on import with the new server's values
- SSH deploy keys preserved from source (same key works with git provider)
- **Email notifications (optional)** — receive alerts when backup or deploy fails
- **`cipi smtp configure`** — interactive SMTP setup (host, port, user, password, from/to, TLS); supports Gmail, SendGrid, Mailgun, etc.; installs `msmtp` on first use
- **`cipi smtp status`** — show if notifications are enabled and recipient
- **`cipi smtp test`** — send a test email
- **`cipi smtp disable`** / **`cipi smtp enable`** — toggle notifications without losing config
- **`cipi smtp delete`** — remove SMTP config
- Notifications sent automatically on: backup errors (per-app or full run), deploy failures, system cron failures (self-update, SSL renewal)
- `cipi-cron-notify` wrapper — runs system cron jobs and sends email alert on failure
- Config stored in `/etc/cipi/smtp.json`; `smtp.json` included in sync export for migration
- **Vault: config encryption at rest** — all JSON config files (`server.json`, `apps.json`, `databases.json`, `backup.json`, `smtp.json`, `api.json`) are encrypted on disk with AES-256-CBC using a per-server master key (`/etc/cipi/.vault_key`); transparent read/write with backward compatibility for existing plaintext configs; existing servers are automatically migrated on update
- **apps-public.json** — plaintext projection of `apps.json` containing only non-sensitive fields (domain, aliases, php, branch, repository, user, created_at); automatically regenerated on every app change; the `cipi-api` group reads this file instead of the encrypted `apps.json`, so the vault key stays root-only with no privilege escalation
- **Encrypted sync export** — `cipi sync export` now encrypts the archive with a user-provided passphrase (AES-256-CBC); `cipi sync import` and `cipi sync list` transparently detect and decrypt encrypted archives; protects SSH keys, `.env` files, database dumps, and credentials during transfer; all sync commands accept `--passphrase=<secret>` for non-interactive/automated usage (cron, scripts)
- **GDPR-compliant log rotation** — automatic retention policies via logrotate:
  - **Application logs** (Laravel, PHP-FPM, workers, deploy, Cipi system) — **12 months**
  - **Security logs** (fail2ban, UFW firewall, auth) — **12 months**
  - **HTTP / Navigation logs** (nginx access & error) — **90 days**

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
