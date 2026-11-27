# Changelog

All notable changes to Cipi are documented in this file.

---

## [5.18.0] — 2026-11-27

Zero Trust gets its private side. Cloudflare Tunnel publishes the sites; **Tailscale** and **NetBird** are how the people who run the server reach it — SSH, the panel, the API and the sites on an address only the devices of the network can route to. `cipi zt tailscale …` and `cipi zt netbird …`, next to the Cloudflare commands, which do not change. **The panel does all of it too** (cipi/api 1.48.0, cipi/gui 4.10.0): join and leave a network, the two locks, Tailscale SSH — with the checks that keep a click from locking anyone out.

### Added

- **`cipi zt tailscale enable --auth-key=KEY`** and **`cipi zt netbird enable --setup-key=KEY`** — the server joins a mesh network. The client comes from its vendor's apt repository (`pkgs.tailscale.com` for this Ubuntu's codename, `pkgs.netbird.io`), the mesh interface (`tailscale0`, `wt0`) is let through UFW, and nothing is closed: 22, 80 and 443 stay as they were.
  - The join key is handed to the client in a file only root reads (`--auth-key=file:…`, `--setup-key-file`), never on the client's command line. `--key-file=` reads it from a file of yours; with no key at a terminal, `enable` asks for it.
  - `--hostname=`, `--direct` (the WireGuard port open in UFW — 41641/udp, 51820/udp — for direct connections; without it peers come through hole punching or a relay), `--accept-dns` and `--accept-routes`: **off unless asked**, so the network's DNS and routes do not change how a production server resolves and routes.
  - Tailscale: `--tags=tag:cipi` (a tagged machine's node key does not expire), `--login-server=URL` (**Headscale**, or any other coordination server), `--ssh` (Tailscale SSH). NetBird: `--management-url=URL` (a **self-hosted NetBird**).
  - **One mesh per server.** Both hand out addresses in 100.64.0.0/10 and Tailscale drops what comes from that range outside its own interface: a second one is refused, with the reason. Cloudflare Zero Trust and a mesh work side by side.
  - **A client that was on the server before Cipi is adopted**: `enable` without a key, its settings untouched, and `disable` leaves it installed and connected. What is only given when joining (`--tags`, `--accept-dns`…) is said, not silently dropped. Tailscale's `--reauth` signs a machine in again (an expired node key, a tagged key in place of a personal one).
- **`cipi zt tailscale|netbird lock ssh`** — port 22 closed to the world, open on the mesh. It refuses:
  - unless **the command itself arrives over the mesh** (the way back to the session's address is the mesh interface): that it does is the proof that SSH works there. From the public address, or from a console, it says how to come in;
  - while the mesh is not connected, sshd does not listen on its address, or UFW is not active (a lock that closes nothing is not recorded);
  - (Tailscale) **while the node key can expire**: on that day the server leaves the tailnet, and with port 22 closed the provider's console is the only way in. Disable key expiry for the machine, or join with a tagged key. `--force` skips the session and the key checks.
- **`cipi zt tailscale|netbird lock http`** — 80 and 443 closed to the world: every site, the panel and the API answer on the mesh address only (point their DNS records at it). For a staging or internal server. Refused while an app still renews its certificate over HTTP-01 (`--force` to accept that); the hostnames on a Cloudflare tunnel keep working.
- **`unlock ssh|http`**, and **the locks of the two sides know each other**: `cipi zt ssh unlock`, `cipi zt unlock http` and `cipi zt disable` (Cloudflare's) leave closed what the mesh's lock holds, and the other way round — each says who still holds the port. `cipi firewall allow 22|80|443` is refused under a mesh lock as it is under Cloudflare's, with the command that reopens it; `cipi firewall status --json` gains `zero_trust.by` (`http`, `ssh`: who holds each).
- **`cipi zt tailscale ssh enable|disable`** — Tailscale SSH: tailscaled answers port 22 of the tailnet address and signs people in by the tailnet's SSH policy, no keys on the server. Refused from a session that came over the tailnet (it may end with it) unless `--force`. **NetBird's own SSH server is never turned on**: it takes port 22 of the mesh address away from OpenSSH and signs people in its own way; SSH over NetBird is OpenSSH with the keys of `cipi ssh`, and `cipi zt netbird status` says when someone turned that server on elsewhere.
- **`cipi zt tailscale|netbird status [--json]`** — connected or not and why, the address and name of the server on the network, the network, peers online, the node key's expiry in days, tags, locks, the command to come in, and warnings. **`cipi zt status`** shows the mesh under Cloudflare's lines, and **`cipi zt status --json` gains `mesh`** — what the panel reads.
- **`cipi zt tailscale|netbird disable`** — what its locks closed is reopened first, then its firewall rules go, and last the server leaves the network and the client, its apt source and its key are removed. A session that came over the mesh ends at that last step: the removal ignores the hangup and runs to its end.
- **From the panel** — the API runs the same commands (`zt-manage`, a new ability; the sudoers name each one), and they hold the line themselves when sudo comes from `www-data`:
  - **`--force` is ignored.** A token cannot skip what protects the operator.
  - **`enable --adopt`** takes a client that is already installed and connected, and never asks for a key: what the panel sends when its form has none. With no client connected it stops, and says a key is needed.
  - **`lock ssh` has no session to look at**: the proof that SSH works over the mesh is a login sshd accepted from an address reached over it (`/var/log/auth.log`). No such login yet, a node key that can expire, Tailscale SSH on (its sessions are not in sshd's log): refused, with what to do.
  - **`lock http` and `disable` never cut the panel's own way in.** The API says where its caller comes from (`--via=`): over the mesh, from this server, or through the Cloudflare tunnel, the lock goes ahead; from the public address it is refused — the panel could not reach the server again, not even to unlock. `disable` is refused when the panel comes over the mesh.
  - **Nor the page of whoever is clicking.** A panel that runs on the server it manages (`cipi gui`) calls the API locally, so its API is never cut — but its pages are on 80/443 like every site. It passes the browser's address (`--client=`): on the public address, `lock http` is refused, since the page would close itself; over the mesh, on the server, or with the panel's hostname on the Cloudflare tunnel, it goes ahead.
  - `cipi zt status --json` says it before the click: `mesh.ssh.seen` (the last login over the mesh), `mesh.firewall_active`, `mesh.http01_apps`, and — asked by the panel — `mesh.panel` (`via`, `client` when a browser's address was given, and `blocked.lock_ssh|lock_http|disable` with the reason, or `null`).
  - **`zt-manage` is as strong as `ssh-manage`**: whoever holds it can put the server on a network of their own. A token made with a list of abilities has it only once it is named there; a `--full-access` token has it, as it has every ability.
- **The mesh in the monitor** — a `mesh` check (`monitor_mesh`, urgent): critical when the client is stopped or off the network (a node key that expired, a machine removed from the admin console) or the node key has expired; a warning when the key expires within `days` (14, `cipi monitor set mesh --days=`) or the coordination server cannot be reached. Off while no mesh is on. With port 22 closed it says what that means.
- `cipi help zt` (also `tailscale`, `netbird`, `mesh`), completion.
- **How long a deploy step may run, per app.** Two clocks, in seconds, with a fixed number for every app that says nothing:
  - **`cipi app deploy-config <app> --build-timeout=SECONDS`** — the frontend build: the `node_build` of a Laravel or Octane app, the install and the build of a Node app. 60 to 3600; **1800** unless set.
  - **`cipi app deploy-config <app> --step-timeout=SECONDS`** — every other command of the deploy (Deployer's `default_timeout`): the clone, Composer, the migrations. 60 to 1800; **300** unless set. A migration that needs ten minutes no longer has to be taken out of the deploy.
  - **In `cipi.yml`**: `deploy.build_timeout` and `deploy.step_timeout`, validated, planned (a change only when the file's number is not the app's), applied with the other deploy options, and written by `cipi yml init`.
  - A number out of bounds is refused before anything is written. The default, asked for by its number, is stored as nothing. `--json` and the table of `cipi app deploy-config` show both. The build never gets less than the other steps.
  - **`cipi app deploy-config` takes a Node app**, for what is not an artisan hook: `--keep-releases`, `--build-timeout`, `--step-timeout`, `--predeploy-snapshot` (until now its `keep_releases` could only come from `cipi.yml`). An artisan flag is refused with what the app does take.
  - Migration 5.18.0 writes the app's own number where it has one. The panel and the API: cipi/gui 4.10.0, cipi/api 1.48.0 (`build_timeout`, `step_timeout`); `cipi-cli deploy config set --build-timeout / --step-timeout`.
- **A Coming soon page for an app with no repository.** `cipi app create --custom` without Git — the files come later, over SFTP — now answers at its domain with a page of its own until they do: *Coming soon*, the domain, a line of text and a small drawing that blinks. One file with **nothing fetched from anywhere**: no web font (the visitor's system font), no image (inline SVG, the favicon included), no script or stylesheet of another site. In English. Light and dark by the visitor's theme, still for who asked for less motion, not indexed, and with no name on it but the site's — it is what the visitors of whoever runs the server see.
  - It is `coming-soon.html`, **the last choice of the vhost's `index`** (`index index.html index.php coming-soon.html`): nginx serves it only while the folder has neither an `index.html` nor an `index.php`. The site that is uploaded takes its place by being there — WordPress's `index.php` included, which an `index.html` placeholder kept hidden until someone deleted it. Nothing to remove; the file can be deleted, or kept and edited.
  - The summary of `cipi app create` says it is there and how it leaves.

### Fixed

- **A deploy stopped while building the frontend — "exceeded the timeout of 300 seconds" — some days and not others.** Deployer stops any command after `default_timeout`, 300 seconds, and the asset build of a Laravel app (`node_build`, usually `npm ci && npm run build` as one command) is the step of a deploy that comes close to it: on a small server, or on a day when a backup or another deploy is running next to it, it went over, and the deploy failed at `task cipi:node_build` with `The command "… /.deployer/node-build.sh /home/<app>/releases/N" exceeded the timeout of 300 seconds`. **The build now has a limit of its own: 30 minutes.**
  - Laravel and Octane apps: `cipi:node_build`. Node apps: `node:install` (`npm ci`, `pnpm install`, `yarn install`, `bun install`) and `node:build`, which were on the same 300 seconds each.
  - **Every other step keeps Deployer's 300 seconds** — the clone, Composer, the migrations, the switch: a step that hangs is still stopped soon, and the limit is back in place as soon as the build ends, also when it fails.
  - In `deploy.php` it is one number, `set('cipi_build_timeout', 1800)` — the app's own where it has one (below) — and the build commands run through `cipi_build_run()`, which raises `default_timeout` for that command only. No named argument (`timeout:`), so the file still parses under PHP 7.4 on a server that kept Deployer 7. A `default_timeout` someone turned off or made longer in a recipe of their own is never shortened.
  - **The apps that exist get it with the update**: migration 5.18.0 appends the block to each `deploy.php` (`deployer_build_timeout_ensure_hook`) — the build task defined again, with the limit; nothing that was in the file is rewritten. The next deploy is the first one with 30 minutes. A `deploy.php` whose build task is not the one Cipi wrote is left as it is and named, with the command that writes the recipe again; `cipi sync` gives the block to the apps it restores.
  - **`cipi deploy` says it in plain words** when a step is stopped on that clock, right under `Deploy failed`: which step it was and for how long it ran — and, for a build in a `deploy.php` that does not have the 30 minutes, the command that gives them to it. Until now the reason was one line inside a PHP exception.
  - A deploy started from the panel had a second ceiling — ten minutes for the whole job, in the API. cipi/api 1.48.0 gives a deploy two hours.

- **UFW rules numbered below ten were never removed by `cipi zt unlock http`, `cipi zt disable` and the nightly refresh of Cloudflare's ranges.** `ufw status numbered` pads the number (`[ 1]`), so it was not the first field the code read: the Cloudflare-only rules UFW had numbered 1 to 9 stayed after the lock was gone. The number is now read from the line itself.
- **A custom app with a document root other than `htdocs` answered 404 until its first upload.** The placeholder was written to `~/htdocs/index.html` whatever `--docroot` said, and the folder nginx serves (`~/htdocs/www`, `~/htdocs/public`) was not even created. The page is now written in the document root, which is created with it.
- **`cipi app create --docroot=` takes a folder name and nothing else.** The value became nginx's `root` as it was typed: `--docroot=/www/` gave `htdocs//www/`, and `..` was not refused. It is now cleaned (`/www/` is `www`; `/` and `.` are `htdocs` itself) and checked — letters, digits, dots, dashes and underscores, folders separated by `/`, no `..` and no hidden folder — before anything is created. What the panel's API already accepted is accepted.

### Changed

- The notifications `zt_enable`, `zt_disable`, `zt_lock_http` and `zt_lock_ssh` are sent for the mesh too; their names in `cipi notification` say so. A channel that takes them takes both sides'.

### Notes

- Migration 5.18.0 touches `deploy.php` and nothing else (the build's time limit, above): nothing restarts, nothing is deployed. Of the mesh, nothing is installed or changed until `enable`: `setup.sh` and `cipi self-update` never call it.
- **Who reaches what is the network's own policy**, not UFW's: the mesh interface is allowed as a whole, as Tailscale's own guide does (its client accepts its interface before UFW is asked). Write the tailnet's access rules, or NetBird's policies, so that the people who run the server reach tcp 22, 80 and 443 of it, and nobody else does.
- A database or Valkey from a laptop over the mesh: an SSH tunnel (TablePlus and DBeaver call it "over SSH") — the ports stay on localhost. There is no `tcp add` for the mesh.
- Cloudflare's side stays read-only in the panel: `cipi zt status` only, as before. Tunnels, hostnames, Access and their locks are still the server's shell.
- **Tailscale and NetBird themselves are not on the machine the release was prepared on.** `tests/verify-5.18.0.sh` runs every command, from the shell and as the panel, against stubs of `tailscale`, `netbird`, `ufw`, `ip`, `systemctl` and `apt-get` that keep a state and answer as the vendors' documentation says (`tailscale status --json`, NetBird's text `netbird status`); the flags of `tailscale up` and `netbird up` are the documented ones. On a first real server: `cipi zt tailscale enable --auth-key=…`, then `cipi zt tailscale status`, before any lock.
- The panel's side: cipi/api 1.48.0 and cipi/gui 4.10.0.
- **Custom apps created before**: nothing changes. An SFTP-only app keeps the `index.html` it was given; its vhost gets the new `index` line the next time it is written, which changes nothing where there is no `coming-soon.html`.

---

## [5.17.0] — 2026-11-26

Four reports, fixed: a deploy that ran its migrations and `optimize` twice, a logrotate warning in `cipi pending` that its own hint could not clear, deploy notifications with "Branch: ?", and an Octane app told to `upgrade` towards a PHP it could not reach. And what was asked for next to them: a page cache in nginx per app (`cipi cache`), an Octane app's PHP chosen by its number, the time zone and the server's name in notifications, and — in the panel (cipi/api 1.47.0, cipi/gui 4.9.0) — Octane, the page cache and Valkey per app.

### Fixed

- **Every deploy ran `artisan:storage:link`, `artisan:optimize` and `artisan:migrate` twice.** `recipe/laravel.php` runs the three after `deploy:vendors` in its own `deploy` task, and Cipi's hooks run the same three right before it. The deploy log showed it:

  ```
  task artisan:storage:link
  task artisan:migrate
  task artisan:optimize
  task artisan:storage:link
  task artisan:optimize
  task artisan:migrate
  ```

  Worse than the wasted seconds: **a step turned off with `cipi app deploy-config` still ran once**, from the recipe — `--no-migrate` did not stop a deploy from migrating. The `deploy` task is Cipi's own from here (`lib/deployer/flow.php`, appended to each recipe like the audit hooks): `deploy:prepare`, `deploy:vendors`, `deploy:publish` — and `artisan:reload` where the recipe has it (Deployer 8). After the vendors only the hooks run, each as the app's deploy-config says. Checked with Deployer 8.0.5's own `dep tree deploy`: one of each; with migrate off, none.
  - The migration appends the flow to the `deploy.php` of every Laravel and Octane app. **An app with a step off in its deploy-config is named**: from its next deploy that step is really skipped.
  - A `deploy.php` that defines its own `deploy` task, or whose three hooks are not where Cipi writes them (edited by hand), is left as it is and named — taking the recipe's steps away from it could leave it without a migration at all.
- **`cipi pending`: "logrotate reports a problem with a Cipi rule: error: skipping "/var/log/auth.log" because parent directory has insecure permissions"**, on servers whose image has rsyslog (there `/var/log` is `root:syslog 0775`) — and `cipi app fix-permissions`, the command the warning named, changed nothing. logrotate, as root, refuses a log in a directory a group other than root can write unless the rule says who to rotate as (`su`). Ubuntu's `/etc/logrotate.conf` says it for every rule it includes (`su root adm`), so the nightly run rotated `auth.log`, `fail2ban.log` and `ufw.log` all along; but `cipi pending` reads Cipi's rules on their own (`logrotate -d /etc/logrotate.d/cipi-*`), where that line is not, and called them skipped. Cipi's rules now say it themselves:
  - `setup.sh` and `cipi api` write `su root adm` in every block that names a log directly in `/var/log` (`cipi-security-logs`, `cipi-queue.log` in `cipi-app-logs`, `cipi-api-maintain`, `cipi-api-update`);
  - the migration adds the line to the rules of an existing server (`logrotate_cipi_su`), block by block: one that has a `su` line keeps it, the per-app rules and nginx's logs are not touched;
  - `cipi app fix-permissions` does the same, with or without apps, so the hint of `cipi pending` is true. A server whose `logrotate.conf` had lost its own `su` line gets those logs rotated for real.
- **Deploy notifications of a Git push said "Branch: ?"** and had no commit. The webhook deploy asked the release's `.git` for both, and a release made by Deployer 7 or 8 is an archive of the commit: there is no `.git` in it. The branch is now the one of the recipe (what Deployer deploys), in the notification and in the deploy log (`branch=main`); the commit is read from the release's `REVISION` in Deployer's mirror of the repository (`~/.dep/repo`) — `Commit: 3f2a91c — Fix the cart total`, author and date. `cipi deploy` reads the commit the same way: its notifications had lost those lines too.
- **An Octane app on two PHP versions was told to run `cipi frankenphp upgrade`, which did nothing.** "gameportal is on PHP 8.5, but Octane answers on PHP 8.6.0": the app's FrankenPHP build — the one Octane downloaded before it was pinned — carries the PHP of the newest FrankenPHP release, and `upgrade` stays on the app's own PHP, for which no build was on the server. `cipi pending`, `cipi frankenphp status` and `cipi php` now say what runs on which PHP (requests on the build's, Composer, artisan, cron and the workers on the app's) and name the command that settles it, with the version: `cipi frankenphp php gameportal 8.6` — or back to 8.5 when a build on it is on the server.
- **The PAM, cron and deploy-webhook notifications gave a time without its zone** ("at 2026-11-26 15:03:49"). Every notification now says it: `15:03:49 UTC`.

### Added

- **`cipi cache` — a page cache in nginx, per app.** OPcache, which every PHP on the server has on, keeps the compiled code: PHP still runs for every request, boots the framework, asks the database, builds the page. This is the other cache: nginx keeps the page and answers the next visitors with it, without starting PHP. Made for WordPress and the sites whose pages are the same for everyone who is not signed in — a page in a millisecond instead of a few hundred, and a small server that holds a traffic peak.
  - `cipi cache <app> on [--ttl=10m] [--size=256m]`, `off`, `ttl <time>` (`30s`, `10m`, `1h`, `7d`), `size <size>`, `clear`, `exclude`, `status [--json]`; `cipi cache [list] [--json]` for every app. One zone per app — `fastcgi_cache` for PHP-FPM (Laravel, WordPress, any PHP app), `proxy_cache` for Octane — in `/var/cache/nginx/cipi/<app>`; not for Node apps. Off unless turned on. Tested with `nginx -t` before nginx reloads; refused, the settings and the vhost go back.
  - **Never cached** — each rule fails towards "slower", never towards a private page shown to someone else: anything but GET and HEAD; a request with a login or session cookie (WordPress, WooCommerce and its cart, `PHPSESSID`, Laravel's `<app>_session`); an `Authorization` header; `/wp-admin`, `wp-login.php`, `wp-cron.php`, `xmlrpc.php`, `/wp-json`, cipi/agent's routes; a query string, unless made of tracking parameters only (`utm_*`, `fbclid`, `gclid`…); a response that sets a cookie or says `Cache-Control: private`, `no-cache` or `no-store`. **The app's headers are respected** (no `fastcgi_ignore_headers`): what WordPress and WooCommerce mark private stays private, and a Laravel app — which marks every response `no-cache, private` — caches only what it marks public itself (`cache.headers`).
  - **Paths of its own an app keeps out** — `cipi cache <app> exclude add '/cart*' '/feed'`, `exclude remove <path>…` (`--all` for none), `exclude set a,b`, `exclude [--json]`, and `on --exclude=a,b` with the rest. For the page that is different for each visitor with no cookie or header saying so, a feed, a page with a counter. `*` is anything, slashes included; without it, the path itself (with or without its last slash, whatever its query string); case does not count. A path is letters, digits, `. _ ~ % - /` and `*`, 128 characters and 50 paths at most — nothing nginx or a regular expression could read as its own; `/*` is refused (that is `off`). Each app has a map of its own (`$cipi_cache_skip_<app>`, next to its zone in `conf.d`) named in both `*_cache_bypass` and `*_no_cache`; with the cache off the list is kept for when it is turned on. `exclude` and `exclude_max` in `status --json`.
  - The time to live is for pages that say nothing; a response with its own `max-age` is kept that long. An expired page is served once more while nginx fetches the new one, and the cached copy keeps answering when PHP is down. `X-Cache-Status` in the response: `HIT`, `MISS`, `BYPASS`, `EXPIRED`, `STALE`.
  - **Emptied after every successful deploy and rollback** — `cipi deploy`, the Git webhook, the panel — before Cloudflare's purge when that is on, and said in the deploy notification (`--no-deploy-clear` to keep the pages). For everything else — a Deployer recipe of your own, a CI job, WordPress when a post is published — the app's own user may empty its cache: `sudo /usr/local/bin/cipi-cache-clear <app>` (a rule `cipi cache <app> on` adds to the app's sudoers; the helper takes the app's name and nothing else, and deletes as nginx's user, following no symlink).
  - Trigger `app_cache`; `page_cache` in `apps-public.json`; removed with the app.
- **`cipi frankenphp php <app> [<X.Y>]` — an Octane app's PHP, by its number.** An Octane app runs two PHP: the one inside its FrankenPHP build answers the requests, the server's `php<X.Y>` runs Composer, artisan, cron and the workers. `cipi frankenphp php shop 8.6` puts both on 8.6: the build that carries it is looked for first — on the server, then in the release GitHub publishes — and **nothing changes when there is none** (a FrankenPHP release carries one PHP; the message says which, and how to import a build of your own); then Octane moves to it — restart, check, and back to its build when it does not answer — and the rest moves the way `cipi app edit --php` moves it. Without a version: what the app runs, and the PHP versions the builds on the server can give it (`--json`: `php`, `octane_php`, `available_php`, `fix`).
  - **`cipi app edit <octane app> --php=X.Y` does the same**, and so does the panel's PHP selector: until now it moved everything but Octane and left a warning. `--force` moves the rest alone, as before.
  - `cipi frankenphp restart <app>`: Octane restarted on its pinned build, and checked.
  - `cipi frankenphp status --json`: `available_php` and `fix` (`command`, `why`) per app.
- **`cipi notification timezone [<Area/City>|server]`** — the zone the `Time:` of a notification is written in. A cloud image is on UTC, and so were the notifications: `cipi notification timezone Europe/Rome` makes them read `16:03:49 CET`, and changes nothing else — not the server's clock, cron or the logs. One function writes the time of every notification (`notify_now`), the helpers' included.
- **`cipi notification server-name [<name>|--clear]`** — the name the server goes by in notifications. The provider calls the machine `vmi12334`, the panel calls it `production`: with `cipi notification server-name production` a subject reads "Cipi deploy succeeded: shop (production)" and a body "Server: production (vmi12334)". The webhook payload keeps `server` (the hostname) and gains `server_name`. The panel offers to set it to the name it knows the server by.
- `cipi notification status --json`: `settings` (`timezone`, `server_timezone`, `server_name`, `hostname`, `now`).
- **The panel's sudoers** allow `cache`, `valkey list --json`, `valkey isolate|share|restart`, `valkey flush-shared --yes` (never `--force`: it refuses while an app still uses the shared instance), `frankenphp php`, `frankenphp restart`, `notification timezone`, `notification server-name`. Valkey per app (5.9.0) had no way in from the panel.

### Notes

- One migration, which restarts and deploys nothing: logrotate's rules and each app's `deploy.php`. The page cache, the notification time zone and the server's name are off until someone sets them.
- **If an app relied on a step that was off in its deploy-config but ran anyway** (`--no-migrate` with migrations in every release), turn it back on: `cipi app deploy-config <app> --migrate`. The migration names these apps.
- logrotate itself is not on the machine the release was prepared on: `logrotate_cipi_su` was checked against logrotate 3.21.0's source (the directory check is skipped for a rule with `su`; a `su` line of `logrotate.conf` reaches every rule it includes) and against the rules of 5.16.0, not by a run of logrotate. On a server: `logrotate -d /etc/logrotate.d/cipi-* 2>&1 | grep -c '^error'` is 0 after the update. The page cache's directives were not run through an nginx either — `cipi cache <app> on` itself runs `nginx -t` and takes everything back when nginx refuses.
- The panel's side: cipi/api 1.47.0 and cipi/gui 4.9.0.

---

## [5.16.0] — 2026-11-26

Cloudflare Tunnel grows from "a site behind Access" into the way a server is reached: Access on chosen paths and for chosen people, service tokens for the machines, databases and Valkey from a laptop with their ports closed, SSH with certificates instead of keys, previews of a branch on their own hostname, the same tunnel on more servers, and a single command that leaves no inbound port open. The monitor says when the tunnel goes down. The panel (cipi/gui 4.8.0) adds connectors for Cloudflare, DigitalOcean, AWS, Hetzner, Google Cloud, Azure, OVHcloud, Vultr, Akamai (Linode) and Scaleway, and passkeys.

### Added

- **Access on some paths, for some people** — `cipi zt access enable <app> --path=/admin,/horizon --allow=me@example.com,@example.com`. `--path=` puts Access in front of those paths only (Filament, Horizon, Pulse, Telescope behind single sign-on, the rest of the site public); `--allow=` replaces "anyone who signs in with the identity provider" with emails and `@domains`; `--allow=none` lets service tokens alone through. Running `access enable` again updates the application, keeping what was not given (`--path=` empty or `--allow=all` clears). The `/cipi/webhook` Bypass is created only when Access covers that path. `--gui` and `--api` take the same options.
- **The API on the tunnel** — `cipi zt hostname add --api`, `cipi zt access enable --api --allow=none`.
- **Service tokens** — `cipi zt service-token create <name> --for=<app>|gui|api [--duration=8760h] [--json]`, `list`, `revoke`. Cipi creates the token and a Service Auth policy on the target's Access application, and prints `CF-Access-Client-Id` and `CF-Access-Client-Secret` once. For CI deploys, monitors, and the panel calling a server's API behind Access (cipi/gui 4.8.0: Connections → the server → Cloudflare Access). Re-creating a target's Access application keeps its tokens' policies.
- **Databases and Valkey through the tunnel** — `cipi zt tcp add mysql|mariadb|pgsql|redis|valkey|<port> --hostname=db.example.com [--allow=…]`, `remove`, `list`. A hostname that reaches `127.0.0.1:<port>`, always behind Access (nothing is published if Access cannot be created); on the laptop `cloudflared access tcp --hostname db.example.com --url 127.0.0.1:13306`, then TablePlus or DBeaver on that address. The port stays closed on the server.
- **SSH with short-lived certificates** — `cipi zt ssh cert enable --principals=andrea,mario [--user=cipi]`, `disable`, `status`. sshd trusts the CA of the SSH Access application (`TrustedUserCAKeys`) and accepts, for each Unix user, the principals listed for it (`AuthorizedPrincipalsFile`): the part of the email before the @, which Cloudflare signs at every sign-in. `sshd -t` checks the drop-in first; keys in `authorized_keys` keep working. `cipi zt ssh enable` takes `--allow=` too.
- **`cipi zt lockdown`** — every app, the panel and the API on the tunnel, then 80/443 closed and, when SSH runs through the tunnel, port 22: no inbound port left, the shape of a server behind NAT with no port forwarding. It stops at the first step that fails, and it keeps refusing to close port 80 while a certificate still renews over HTTP-01 (`--force` to accept that).
- **Previews of a branch** — `cipi zt preview create <app> --branch=feature/login [--hostname=] [--allow=] [--public] [--no-deploy]`, `list`, `remove`. An app of its own (same repository and PHP, its own database and `.env`, environment `preview`) on `feature-login-shop.example.com` — one level below the zone, so Cloudflare's Universal certificate covers it — through the tunnel, behind Access unless `--public`, deployed once. `remove` deletes the app, its database and its hostname.
- **Replicas** — `cipi zt replica export` prints a bundle (the tunnel's credentials and routes: a secret) that `cipi zt replica join` runs on another server with the same apps; Cloudflare then sends requests to either one. Move a server without touching DNS (the records point at the tunnel), then `cipi zt replica leave` on the old one: it stops the connector and keeps the tunnel, the DNS and Access. `cipi zt replica list` shows the connectors and which one is this server. `cipi zt disable` now refuses on a replica, or while other servers run the tunnel (`--delete-tunnel` to delete it for everyone).
- **Cloudflare's cache** — `cipi zt purge <app> [--everything]` purges the app's hostnames (purge by hostname is on every plan), and `--on-deploy=on` does it after every successful deploy, `cipi deploy` and the webhook alike; the deploy notification says how it went.
- **The tunnel in the monitor** — a `tunnel` check (`monitor_tunnel`, urgent): critical when cloudflared stops or Cloudflare sees the tunnel down or inactive, a warning when it is degraded, recovery and reminders like every check. Off while Zero Trust is. With 80/443 closed it is the one outage a server can still report: notifications go out, not through the tunnel.
- **`cipi zt status --json`** — the tunnel (running, Cloudflare's status, connectors and which one is this server), the locks, every hostname with its Access paths, allowed people, service tokens, preview and purge setting, the panel and the API, SSH and its certificates, TCP services, service tokens, previews and what is not on the tunnel yet. The panel's sudoers already allowed `cipi zt status *`.

### Notes

- No migration. Tokens made for 5.15 keep working; the new commands name the permission they miss: Access: Service Tokens (Edit) for service tokens, Access: SSH Auditing (Edit) for certificates, Zone: Cache Purge for purges.
- The panel's side: cipi/api 1.46.0 (`GET /api/zero-trust`) and cipi/gui 4.8.0 (Zero Trust in the Firewall tab, read-only; connectors; passkeys). Cloudflare DNS from the panel is the panel's own: its token is saved in the panel, not on the servers.

---

## [5.15.0] — 2026-11-25

Each notification channel takes only what it is given: one channel for everything, one for the alarms, one for the deploys. The visitor's address behind Cloudflare is turned on from the panel's Firewall tab. And a server switched to MySQL no longer lists the client's warning about passwords as one of its databases — the root password of MySQL and MariaDB is no longer on any command line at all.

### Added

- **`cipi notification events` — what each channel takes.** Until now every trigger that was on reached every channel that was on. A channel now takes everything (as before, and the default) or only its `events`, a list of selectors any of which lets a trigger through:
  - a **category** of the catalog, as an id: `security`, `deploy`, `backup`, `monitor`, `health`, `ssl`, `database`, `basic-auth`, `ssh-keys`, `cipi-yml`… (`cipi notification events --json` lists them);
  - a single **trigger**: `backup_fail`, `deploy_success`…;
  - **`urgent`**: failures and security events — a failed deploy, backup, cron run or cipi.yml, a healthcheck down, a service or a worker stopped, the disk or an app's limit filling up, 5xx spikes, a read-only filesystem, an SSH login, sudo, su, malware or drift found, CrowdSec's rescue. The same triggers ntfy and Pushover raise in priority, which now read the one list.

  `cipi notification events <channel> security,deploy` sets it, `… urgent` for the alarms alone, `… all` back to everything; `cipi notification events` shows every channel (`--json` with the categories). `add` and `update` take `--events=` too, checked before the channel is saved: a typo changes nothing and is named. SMTP is a channel like the others (`cipi notification events smtp deploy`), and reconfiguring SMTP or editing a channel keeps what it takes. The triggers on and off (`cipi notification triggers`) still come first: a trigger that is off reaches no channel. A notification without a trigger (`cipi monitor test`) and `cipi notification test` reach every channel.
  `cipi notification status --json` gives each channel its `events` (`null`: everything) and lists the `categories` and the `selectors`; `cipi notification triggers --json` gives each trigger its `category_id`.
- **The visitor's address behind Cloudflare, from the panel** (cipi/gui 4.7.0, cipi/api 1.45.0): `cipi nginx real-ip` was a terminal command. `cipi firewall status --json` now carries `real_ip` — on or off, who keeps it (`real-ip`, `zero-trust`, `both`, or `other`: a configuration Cipi did not write), the ranges trusted and when they were fetched, `can_disable` (on, and kept by this setting alone) and `bans_active` (fail2ban or CrowdSec runs, which `off` warns of) — and the panel's sudoers allow `nginx real-ip status --json`, `nginx real-ip cloudflare`, `nginx real-ip refresh` and `nginx real-ip off --yes`, each spelled out, nothing after them. `cipi nginx real-ip status --json` reads the same function.

### Fixed

- **A server switched to MySQL listed "mysql: [Warning] Using a password on the command line interface can be insecure." as a database** — in `cipi db list` and in the panel's Databases page, with a Backup, a Restore and a New password next to it. MySQL's client (`cipi db switch mysql`) says so on stderr every time it is given `-p<password>`; MariaDB's does not. `cipi db list` read the client's stderr together with its rows (to show the error when the query fails), so the warning was one more row. Two fixes:
  - **the root password is no longer on any command line**: every `mysql`, `mariadb` and `mysqldump` Cipi runs as root — the list, the dumps and backups, a restore, `cipi db create|delete|password`, `cipi db switch`, `cipi reset db-password` — gets it in an option file read from a pipe (`--defaults-extra-file=<(…)`, `db_mysql_as_root` in `lib/common.sh`), never as `-p…`. On the command line it was in the process list — readable by every user of the server, each app's included — until the client got round to overwriting it, which is exactly what MySQL warns about; nothing touches the disk, so nothing is left behind either;
  - `cipi db list` keeps the client's stderr apart from the rows, for PostgreSQL too (which warns at connection time about a collation version mismatch after a glibc upgrade): a failed query still says why, a warning is never a database.
- **The PAM, cron and deploy-webhook helpers reached SMTP alone.** `cipi-auth-notify` (SSH login, sudo, su), `cipi-cron-notify` (`cron_fail`) and `cipi-app-notify` (a deploy through the webhook, its success or failure) predate the other channels and sent email only: Slack, Telegram, ntfy and the rest never heard of an SSH login. They now send through every channel that takes the trigger — `cipi-auth-notify` in the background, as before, so that a login never waits on a webhook — and run with alert channels and no SMTP at all.

### Notes

- No migration: `cipi self-update` installs the helpers and rewrites the panel's sudoers, as it does at every update. A channel without `events` takes everything, so nothing changes until you choose.
- The panel's side: cipi/api 1.45.0 (`events` on a channel, `PUT|DELETE /api/firewall/real-ip`, `POST /api/firewall/real-ip/refresh`) and cipi/gui 4.7.0. An older API refuses `events` instead of ignoring it.

---

## [5.14.0] — 2026-11-25

The firewall from the panel. A server's Firewall tab (cipi/gui 4.6.0, cipi/api 1.44.0) shows UFW, fail2ban and CrowdSec together and changes what is safe to change from a browser: ports, blocked addresses, the fail2ban threshold, bans, CrowdSec and its allowlist. What keeps the server reachable stays out of its reach. The same panel release lets an admin require two-factor authentication for every account; `cipi compliance` reads that policy. And the optional packages grow from four entries to twenty — Browsershot's libraries among them, and the security scanners [Hackly](https://github.com/andreapollastri/hackly) runs, seven of them pinned upstream releases — which the panel can now install and remove.

### Added

- **`cipi firewall status [--json]`** — everything in one read:
  - UFW: active or not, the default policies, and every rule as ufw keeps it (the `### tuple ###` lines of `/etc/ufw/user.rules` and `user6.rules`, comments decoded), an IPv4 rule and its IPv6 twin as one (`family`: `both`, `v4`, `v6`). Each rule says what it is (`kind`: `port` for what `allow`/`deny` make, `block` for what `block` makes, `other` for the rest), which Cipi feature owns it (`managed_by`, from its comment: `zero-trust`, `metrics`, `crowdsec`), whether it keeps a protected port open (`protected`), and so whether the panel may remove it (`removable`).
  - `protected_ports`: the ports sshd listens on (`sshd -T`, 22 when unreadable), 80 and 443. `zero_trust`: the HTTP and SSH locks.
  - fail2ban: the threshold (saved and live, and `attempts_pending` when they differ), find and ban times, every jail with its banned addresses.
  - CrowdSec: engine, bouncer, rescue listener, the operator's allowlist, the decisions, free RAM, and `enable_blockers` — what would stop `cipi crowdsec enable` (its RAM and real_ip checks), so the panel can say so before trying.
  - Without `--json`, a summary; `cipi firewall list --json` and `cipi firewall attempts --json` give their parts.
- **`cipi firewall remove <port> [--from=] [--proto=tcp|udp|any] [--deny]`** — drops what `allow` (or `deny`) made. Before, a port opened with `allow` could only be "closed" with `deny`, which UFW never reached (below).
- **`cipi firewall block <ip|cidr>` / `unblock`** — every port refused to an address, ahead of every allow: a scanner, an abuser, a range. Lasts until unblocked, unlike a fail2ban or CrowdSec ban.
- `cipi firewall allow` takes `--proto=udp` and port ranges (`8000:8100`); the port and `--from` are validated (1–65535, an IPv4/IPv6 address or CIDR) before anything reaches ufw.
- **`cipi crowdsec enable --allow=<ip|cidr>`** — allowlists that address too. The panel passes its own: the server never bans the panel that manages it.
- **The panel's whitelist** (`/etc/sudoers.d/cipi-api`) allows `firewall status --json`, `firewall allow|remove|block|unblock|attempts`, `ban unban`, `crowdsec enable`, `crowdsec disable --force` (`--force` there only skips the question), `crowdsec allow|unallow`. Not `firewall deny` (the panel opens ports and blocks addresses; it does not deny ports), not `crowdsec rescue` (break-glass belongs at the server) or `refresh`.
- **`cipi compliance`, control `gui_2fa`, reads the panel's 2FA policy** (cipi/gui 4.6.0, Team → Two-factor authentication): required and everyone enrolled → pass; required with accounts still to enrol → warn, naming them (the panel takes them to the setup at their next request); not required and accounts without 2FA → fail, as before, now saying where to require it.

- **Seven new optional packages** (`cipi package list`), on the same rule as the first four — stateless, from Ubuntu's repositories, a real Laravel or PHP package behind each:

  | Entry | apt | For |
  | --- | --- | --- |
  | `browsershot` | the shared libraries and fonts Chrome needs (`libnss3`, `libgbm1`, `libasound2t64`, `fonts-liberation`, `fonts-noto-color-emoji`, …) | spatie/browsershot, spatie/laravel-pdf. Chrome itself comes with Puppeteer, per app (`npm install puppeteer`) |
  | `fonts-cjk` | `fonts-noto-cjk` | Chinese, Japanese and Korean text in PDFs and images |
  | `avif` | `libavif-bin` (`avifenc`) | AVIF in spatie/laravel-image-optimizer |
  | `pdftk` | `pdftk-java` | mikehaertl/php-pdftk: forms, merge, split (pulls a headless Java runtime) |
  | `libreoffice` | `libreoffice-writer-nogui`, `libreoffice-calc-nogui` (`soffice`) | DOCX, XLSX, ODT to PDF |
  | `pandoc` | `pandoc` | ueberdosis/pandoc |
  | `tesseract` | `tesseract-ocr` with English, Italian, German, French and Spanish | thiagoalessio/tesseract_ocr |

  `browsershot` and `fonts-cjk` are *libraries*: nothing to find on PATH, every item checked with dpkg instead. An apt item may name two packages, `libasound2t64/libasound2`: the first one apt has a candidate for is installed, either one installed counts — 24.04 renamed those libraries for the 64-bit `time_t` transition, a later release may drop the suffix, and the catalog keeps real package names dpkg can see, never virtual ones. After an install Cipi says what the app still has to do: Puppeteer and the sandbox for Browsershot (Ubuntu 24.04+ restricts the user namespaces Chrome's sandbox uses), a queue worker and one profile per conversion for LibreOffice, the languages for Tesseract.
- **Security scanners for [Hackly](https://github.com/andreapollastri/hackly)** (`sec-*`), so a Cipi server can run its scans:
  | Entry | Source | Installs | Hackly uses it for |
  | --- | --- | --- | --- |
  | `sec-recon` | Ubuntu | `nmap`, `dig` (`bind9-dnsutils`), `whois` | port scans, DNS, WHOIS, mail security |
  | `sec-gitleaks` | Ubuntu | `gitleaks` | secrets in repositories |
  | `sec-nuclei` | upstream 3.11.1 | `nuclei` (the release zip) | DAST, path discovery, pentests |
  | `sec-zap` | upstream 2.17.0 | OWASP ZAP (the Linux tarball) and a Java runtime from Ubuntu | baseline and pentest scans |
  | `sec-nikto` | upstream 2.6.1 | Nikto from its git tag, Perl modules from Ubuntu | pentests — Ubuntu's Nikto is 2.1.5 (2014) and writes no JSON |
  | `sec-wpscan` | upstream 3.8.28 | WPScan from RubyGems in a gem home of its own, Ruby from Ubuntu | WordPress targets |
  | `sec-trivy` | upstream 0.76.2 | Trivy's `.deb` | SCA |
  | `sec-semgrep` | upstream 1.185.0 | Semgrep from PyPI in a virtualenv of its own | SAST |
  | `sec-checkov` | upstream 3.3.26 | Checkov from PyPI in a virtualenv of its own | IaC |

  A command name works as well: `cipi package install nuclei`. Each scanner keeps its own licence: WPScan's is not an open-source one (free to test your own systems and for penetration testers, a commercial licence to sell it as a service — the install says so), and Nmap has its own (the NPSL).
- **Upstream entries: pinned, verified, kept apart.** The catalog's rule was "from an Ubuntu repository"; Ubuntu has no nuclei, ZAP, WPScan, Trivy, Semgrep or Checkov. An upstream entry is pinned in `lib/package.sh` to one version, and its download to a SHA-256 (a git tag to its commit): the server never resolves "latest", a file that does not match is refused and deleted. The 5.14.0 pins come from upstream's own manifests — the checksums file of the nuclei and Trivy releases, ZAP's `ZapVersions.xml`, the Nikto tag — and were checked against the downloaded files. Every download is a GitHub release asset, which stays where it is (Aqua's apt repository has the same Trivy `.deb` but keeps only the latest few versions: a pin there would break at their next release). Python and Ruby tools are pinned by version, their dependencies resolved by pip and gem; Semgrep and Checkov start through a wrapper that puts their virtualenv first on PATH, so the helpers they start by name (`pysemgrep`, `semgrep-core`) are their own and not what a pipx install left in `/usr/local/bin`. ZAP takes Java 21, 17, or the release's default JRE when those are gone. Each entry lives in `/opt/cipi/packages/<id>/<version>`, `current` points at the live version, its commands are linked into `/usr/local/bin`; a command already there that is not Cipi's (Hackly's own installers put `nuclei` in `/usr/local/bin`) is left alone unless `--force` at the server's shell — never from the panel. The apt packages an entry needs come and go with it, recorded per entry — one that is already there only as a dependency of something else (the Java runtime `pdftk` brought) is kept for the entry too, so removing the other package does not take it away under it, and goes back to a dependency when the entry is removed; build tools (WPScan's `build-essential`, `ruby-dev`) are removed right after the build. An install that fails leaves the server as it was: what apt installed for it goes back, the leftovers of a killed install are cleared by the next one, and a repair that fails keeps the entry's record so that `remove` still works. A newer pin arrives with a Cipi release: `cipi package list` shows the entry as outdated, `cipi self-update` names it, installing it again updates it (new version first, `current` swapped, old one removed). They are not updated by unattended-upgrades. The panel installs and removes these too, like the rest of the catalog.
- **`scripts/package-pins.sh`** (for maintainers, not servers): compares every pin with upstream, `--write` fills or fixes them, `--download` also hashes the files themselves. `tests/verify-5.14.0.sh` fails while an upstream download has no hash.
- **One `cipi package install` or `remove` at a time** (`/run/lock/cipi-package.lock`): the panel's queue and a shell can meet; a second one waits. apt's own processes do not inherit the lock.
- **`chromium` and `wkhtmltopdf` stay out**, and the refusal says why and what instead: Chromium on Ubuntu is a snapd transitional package (→ `browsershot` and Puppeteer's Chrome); wkhtmltopdf is archived upstream, its Qt WebKit unpatched (→ `browsershot`).
- **`cipi package list --json`** adds `kind` (`tools` | `libraries`), `binaries`, `missing`, `source` (`ubuntu` | `upstream`), `version` (the pinned one), `installed_version` and `outdated` per entry, and `packages` names what is installed (`libasound2t64` on 24.04). `partial` no longer counts what other packages pulled in: an entry is partial only when one of its items was installed on purpose (so `sec-recon` on an image that ships `dig` reads as not installed, not as half-installed). The list asks dpkg once for the whole catalog instead of once per package and per question — 0.3 s instead of almost 3 on a small machine, more on a server's dpkg database, with the panel waiting on it. A package installed for two architectures counts as installed.
- **The panel installs and removes optional packages** (cipi/gui 4.6.0, cipi/api 1.44.0: `POST|DELETE /api/packages/{id}`): its sudoers allow `package install *` and `package remove *`. The catalog is what makes this safe — a name outside it is refused before apt sees it. From the panel (sudo as `www-data`) `--force` is ignored, so the 1 GB free-space check holds, and so is `--autoremove`.

- **`cipi nginx show|edit|set|reset <app>` — an app's own nginx directives.** The vhost of an app is Cipi's: it is written again at every alias, certificate, PHP, basic auth or routing change, so an edit of `/etc/nginx/sites-available/<app>` never lasted. What lasts now is a text of the app's own — headers, caching, limits, rewrites, `location` blocks — kept in `apps.json` (so it follows `cipi sync`) and included in the server block of every kind of vhost (Laravel, Octane, custom, Node, under an app-wide redirect), before `location /`:
  - `cipi nginx edit <app>` opens it in `$EDITOR`; `cipi nginx set <app> --file=<path>` (`-` for stdin) takes it from a file; `cipi nginx show <app> [--json]`; `cipi nginx reset <app>`.
  - Every change is tested with `nginx -t` before nginx reloads. Refused, the app's settings and its vhost go back to what they were, and nginx's reason is shown by line (`line 3: unknown directive "foo"`); `edit` offers the editor again on your text. A configuration already invalid is not touched. A location Cipi defines cannot be defined twice: nginx says so.
  - The directives live in a file of their own (`/etc/nginx/cipi-custom/<app>.conf`). nginx parses an included file on its own: a `}` in it cannot close the server block, and a block it opens must be closed in it.
  - **From the API a subset of the language** (`lib/nginx-lint.sh`, a list of what is allowed; `--strict` applies it at the terminal). The whole language would make a token root: nginx opens an `access_log` or `error_log` path and reads an `include` as root, `server_name` takes another app's domain, `listen` opens a port, a `*_pass` reaches another app's PHP socket or a database on the loopback. So through `cipi api`: no log path (`access_log off;` only), `include`, `listen`, `server_name`, `*_pass`, certificates, `auth_basic_user_file`; `root` and `alias` only under `/home/<app>/`; anything not on the list is refused by name. The check reads the text the way nginx does (quotes, comments, `${var}`), so a brace in a comment or a quoted directive name gets nothing past it. The API takes the text as `--content-b64`, never a file of the server; reverse proxies and redirects stay with `cipi proxy` and `cipi redirect`, which check where they point.
  - `cipi app delete` removes the file. 32 KB per app, no control characters. Sudoers of the API: `nginx show|set|reset` — not `edit`, `upgrade`, `default-server`.
- **`cipi nginx real-ip cloudflare` — the visitor's address behind Cloudflare's proxy.** A domain proxied by Cloudflare (the orange cloud) reaches nginx from Cloudflare's addresses: the access log, fail2ban, CrowdSec and the app all saw Cloudflare, and the only way to change it short of a Zero Trust tunnel was to write the nginx configuration by hand. One command now does what `cipi zt enable` did for its tunnel, without the tunnel:
  - nginx's `real_ip` module is given Cloudflare's IPv4 and IPv6 ranges and `CF-Connecting-IP`: a request from one of the ranges gets the visitor's address, a request from anywhere else keeps the address of its connection — the header cannot be forged by reaching the server directly. One setting for the whole server, right for the domains behind Cloudflare and without effect on the others. A PHP-FPM app sees it as `REMOTE_ADDR` (`$request->ip()` in Laravel, no TrustProxies change for the address); Octane and Node apps get it in `X-Forwarded-For`, as they do for a direct visitor.
  - fail2ban never bans Cloudflare's ranges and CrowdSec whitelists them (a ban on Cloudflare takes every proxied site down); `cipi crowdsec enable` behind a proxy no longer needs `--force`, and its refusal names the command.
  - the ranges are Cloudflare's public list (no token), fetched again every night; offline, the previous ones stay.
  - `nginx -t` runs before the reload: refused — another `real_ip_header` in `nginx.conf`, say — the file is taken back and nginx's reason shown; a `real_ip` configuration Cipi did not write is left alone.
  - `cipi nginx real-ip status [--json]`, `refresh`, `off [--yes]`. `off` says what it risks when CrowdSec or fail2ban run (with a domain still proxied they would see, and could ban, Cloudflare) and asks. With Zero Trust enabled the file is shared: `off` leaves it until `cipi zt disable`, and `cipi zt disable` leaves it when this command turned it on.
  - A terminal command: not in the panel's sudoers. A firewall ban still stops direct connections only — a visitor who comes through Cloudflare is blocked at Cloudflare.
- **`cipi deploy <app> --audit --json`: the title of each commit.** Every record gets `subject`, the first line of its commit's message, read when asked from the app's own clone (Deployer's mirror, `htdocs` for a custom app) as the app user, one `git` for all of them. It is not written to the ledger and no hash covers it — the record says which commit went live, the clone says what it is called; a commit the clone no longer has gets none. Control characters are taken out and it is cut at 200 characters: whoever can push chooses it. The table of `--audit` is unchanged.

### Changed

- **`cipi help` lists the commands in alphabetical order**, as `php artisan list` does: the commands that stand alone (`domains`, `pending`, `self-update`, `status`, `use`, `version`), then the namespaces from `alias` to `zt`, and inside each its commands. They followed the order of the help topics — `status`, `version`, `self-update`… then `disk`, `autoupdate`, `reboot`, `service`, `app` — which made a command hard to find in a list of 329. The topics named by *Unknown help topic* are alphabetical too, and made from the one list of topics (they were typed twice). `cipi help <topic>` and `cipi help all` keep their own order: there the commands are grouped by what they do, with their notes under them.

- **`cipi firewall deny` goes ahead of every allow** (`ufw prepend`, `ufw insert 1` where it is missing). UFW stops at the first rule that matches: a deny added after an allow of the same port let the traffic in all the same. It also takes `--from=` and `--proto=`.
- **What keeps the server reachable is not closed from here**:
  - `deny` of the SSH port, 80 or 443 to everyone, and `remove` of the rule that opens them to everyone, are refused — a range that takes one of them in too. One address can still be denied (`--from=`).
  - `block` refuses a range that takes in the address of the SSH session giving the command, and so does `deny --from=` on the SSH port; ranges wider than /8 (IPv4) or /16 (IPv6) are refused.
  - `allow` to everyone refuses to reopen what a Zero Trust lock keeps closed (`cipi zt lock http|ssh`): it says which `cipi zt unlock` does it.
  - `--force` gets past these at the server's shell. Coming from the panel (sudo as `www-data`) it is ignored, whatever the panel sends; so is `crowdsec enable --force`, which skips the RAM and real_ip checks — the panel gets them as they are. Enabled from the panel, CrowdSec does not look for an SSH session to allowlist (there is none).
- **`cipi package remove` takes the entry and nothing another package needs**, computed before anything changes and shown with the question:
  - a tool: its packages and the dependencies only they needed (`pdftk` takes its Java runtime). Only what was installed on purpose: a tool another package pulled in (`dig`, for `ubuntu-standard`) stays. A removal that would take another package with it — one that depends on the entry — is refused, nothing changed; `--force` at the server goes ahead;
  - libraries: marked as automatically installed, then only those nothing uses any more go (`browsershot` leaves `libcairo2` to the php-imagick that needs it); put back as they were on abort. Libraries other packages pulled in were never the entry's: an entry with only those is "not installed";
  - orphans that were already there are left alone. They used to be listed and offered on every removal; `--autoremove` at the server still takes them.
- **`cipi package install` and `remove` without a terminal need `--yes`** ("never implicit"), instead of reading an empty answer as no.
- `firewall allow`, `deny`, `remove`, `block`, `unblock` are written to `cipi.log`, and say when the rule was already there, when it did not exist, and when UFW is inactive.

### Fixed

- **On a server that runs MySQL, `cipi db create` still said `✓ Engine: mariadb`.** Since `cipi db switch mysql` (5.13.0) port 3306 can run MySQL under the engine id `mariadb`, and the messages that print the id named a server that was not installed. `db create`, `list`, `link`, `unlink`, `delete`, `backup`, `restore`, `password`, `default` and the notifications of a created or deleted database now say `mysql` there — a name `--engine=` takes too. On a MariaDB server, for PostgreSQL, and through the API (whose parser, like those of the releases already installed, reads `mariadb` / `pgsql` in these lines) nothing changes.

- **`cipi ban unban 1.2.3.4` unbanned 11.2.3.45** — and `198.51.100.2` matched `198.51.100.20`: the address was looked for as a substring of fail2ban's list, every dot a wildcard. It is matched whole now. `ban unban` takes nothing but an address (a CIDR for CrowdSec ranges, `cscli decisions … --range`); an option or shell characters are refused before fail2ban-client and cscli see them.
- `cipi ban list` and `unban` no longer stop under `set -o pipefail` when fail2ban answers without a jail list.
- `cipi crowdsec allow|unallow` accept as IPv6 only hex digits, colons and a mask (`*:*` was enough: the value is written into a YAML allowlist), and `unallow` validates its argument before grep reads it as one.

### Upgrade

- `cipi self-update` rewrites the panel's whitelist, as on every update; no migration. The API's new abilities for an app's nginx directives are `nginx-view` and `nginx-manage`: tokens created before do not have them. **Not verified against a real nginx:** the include of the app's file in each kind of vhost, the `real_ip` file and nginx's own messages (the suite uses a stub); `cipi nginx edit` at a terminal; `cipi db create` on a real MySQL server. Then `cipi api update` (cipi/api 1.44.0) on every managed server and `cipi gui update` (cipi/gui 4.6.0) on the panel's — the Firewall tab needs all three, and a token with `firewall-view` / `firewall-manage` (`cipi api token create`; a `--full-access` token has them).
- `tests/verify-5.14.0.sh` (283 checks) reads the order of `cipi help` from the real entry point, and runs `cipi nginx real-ip` against stubs of curl, nginx, systemctl and fail2ban (on, a refresh offline and with a new range, a refusal, a foreign configuration, off, with Zero Trust), the engine a database message names, `cipi nginx` against stubs of nginx and systemctl and the real vhost templates (set, a regeneration, a custom app, an app-wide redirect, a refusal put back, twenty texts the API must not take), reads commit subjects from a real Git mirror, and runs the firewall commands against a ufw stub that keeps its rules as ufw 0.36 does, and fail2ban, cscli, systemctl and sshd stubs: the JSON, both families, comments, removals, `prepend` and its `insert 1` fallback, the protected ports (sshd's own), the session and Zero Trust guards, `--force` from the shell and from the panel, the threshold, `ban unban` on near-identical addresses, CrowdSec's state and decisions, the sudoers (visudo, 40 commands per rule) and the compliance control on a panel database. For `cipi package`, apt, dpkg and apt-mark are one model of installed packages, their marks and dependencies: the catalog, both names of the renamed libraries (24.04 and a release without the suffix), a library with no candidate, installs and removals with what they leave (a library another package needs, older orphans, a reverse dependency), `--force` and `--autoremove` from the shell and from the panel, and an abort putting the marks back; for the upstream entries, a mirror for curl and stubs of git, gem and pip: install, the pin checked, a mismatch or a missing pin refused with nothing left behind, a commit that moved, a command Cipi did not install (from the shell with `--force`, never from the panel), outdated and updated, removal with the apt packages only it needed, a dependency shared with another entry, a repair and a first install that fail, build tools gone after the build, a `.deb` apt has from elsewhere; `tests/verify-5.2.2.sh` follows the panel's new rights. **Not verified on a real server:** ufw 0.36's `prepend` on Ubuntu 24.04 and 26.04 with IPv4 and IPv6 rules, `ufw --force delete` by rule, `crowdsec enable` started from the panel's queue; the new packages' apt names were checked against packages.ubuntu.com, not installed on 24.04 and 26.04 — nor Chrome started by Browsershot against the `browsershot` libraries; the upstream entries were not installed on a Cipi server either. Run for real, outside a server: `sec-nuclei` (downloaded, verified, unpacked, `nuclei -version` → 3.11.1), `sec-zap` (the same, `zap.sh -version` → 2.17.0 on Java 21) and `sec-nikto` (the tag cloned at its pinned commit, the wrapper started), each through its link and then removed; both Trivy `.deb`s were downloaded and hashed. The virtualenv and gem-home mechanics were run with the real `python3 -m venv`, pip and gem on a local wheel and a local gem (the command through its link, its own helpers first on PATH). Not run: the apt steps, and the real Semgrep, Checkov and WPScan from PyPI and RubyGems (their dependency trees and native builds, also on Ubuntu 26.04's Python and Ruby).

## [5.13.1] — 2026-11-24

### Fixed

- **`cipi db switch mysql` stopped right after "Checking the MySQL packages...", with nothing said** (Ubuntu 24.04 and 26.04). The candidate came from `apt-cache policy mysql-server | awk '/Candidate:/{print $2; exit}'`. Ubuntu Server's `awk` is gawk (byobu depends on it), which reads lines as they arrive: it exits at the candidate line, apt-cache — which flushes a line at a time — dies of SIGPIPE writing the version table, and under `set -o pipefail` the assignment fails, so `set -e` ended `cipi`. Nothing had been changed yet. apt's output is now read whole (`_db_apt_candidate`), and when there is no candidate the first lines of `apt-cache policy` are shown. The same pattern is gone from `cipi service upgrade` / `cipi autoupdate` (`_stack_upgrade_candidate`) and from CrowdSec's SSH client lookup.
- The rest of the switch, looked at for the same kind of stop: the MySQL version read after the install, and a rollback that stopped at its first failing step (packages, data directory) — every step is now tried and a failure is reported.
- Pipelines in the 5.13.0 deploy code that a consumer leaving early could fail: the deploy wrapper's "is it still running" and "was the lock refused" checks, the branch read from `deploy.php`, `cipi deploy`'s "a deploy is running" check and the paused commit.

### Added

- **A stop that nothing checked says where it happened**, instead of leaving you at the prompt: `[ERROR] Stopped unexpectedly at db.sh:986 in _db_switch_run() (exit 141): …`. Not after an error that was already printed, and not for failures inside `$(…)`, pipelines or subshells, which the command that runs them judges.
- **`cipi help` lists every command like `php artisan list`**: Usage, Options, then Available commands — the top-level ones, then one namespace per command family, commands in green, descriptions in one column — built from the topics' own lines, so it cannot drift from `cipi help <topic>`. In a terminal it opens in `less` (quits when it fits). `cipi help <topic>` and `cipi help all` show the command in green and its arguments dimmed; `help all` now includes `use` and `credentials`.

### Upgrade

- `cipi self-update`. `tests/verify-5.13.1.sh`; `tests/verify-5.13.0.sh` now runs the switch under `set -euo pipefail`, with an apt-cache that writes a line at a time and an awk that reads like gawk — 5.13.0 fails it the way it failed on the servers.

## [5.13.0] — 2026-11-24

A deploy that fails should not need anyone to unlock anything: fix the code, push, and the webhook deploys it. Most of that was already true — since 5.9.0 a deploy that fails releases its own lock (`deploy:failed` → `deploy:unlock`) — but two things still got in the way, and the one thing worth holding back was not held back. Deploys no longer wait for the jobs in progress either (#536). Backups can leave folders out, and port 3306 can run MySQL instead of MariaDB.

### Fixed

- **The panel's Access tab showed raw output — `[1mBasic auth — <app>[0m ━━━ Status [2mdisabled[0m` — on every app.** Since 5.11.0 `cipi basicauth status` (and `enable`, and `agent status`) read the vhost's cipi/agent marker with `grep | head | sed`; under `set -o pipefail` the grep that finds no marker — every app without one — failed the assignment, and `cipi` exited 1 right after printing its first lines. The API took the exit code for an error and passed the output, colours included, as its message. The helper never fails now. `basicauth enable` reported a failure after enabling for the same reason.
- **Deploys failed on `workers:stop` after 300 seconds and left Horizon in STOPPING** ([#536](https://github.com/cipi-sh/cipi/issues/536)). Before switching `current`, the deploy ran `cipi-worker stop`: `supervisorctl stop` on every program of the app, which waits for each to exit — up to `stopwaitsecs`, an hour for Horizon and the queue workers so that a running job can finish — while Deployer gives a command 300 seconds. With a long job in progress the deploy failed (exit 255), `current` stayed on the previous release, Horizon stayed in STOPPING and nothing started it again; the deploys that went through waited for the jobs in hand (2–3 minutes instead of ~40 seconds). Deployer swaps `current` atomically (`mv -T`), so nothing has to stop before the swap:
  - `cipi-worker stop` changes nothing any more (the `deploy.php` files that call it need no change);
  - `cipi-worker restart`, after the swap, does not wait for the jobs: Horizon and the queue workers get SIGTERM — they finish the job in hand and exit, and Supervisor (`autorestart`) starts them again on the new release; Octane, Reverb and other programs are restarted, waiting 90 seconds at most each (`CIPI_WORKER_RESTART_WAIT`); a program not running is started; one still STOPPING is started in the background as soon as it has stopped.
  - Octane keeps serving until its restart after the swap, instead of being down from before it.
  - The panel's "Unable to connect to server" after ~600 s, the deploy history layout and the panel language are cipi/api and cipi/gui matters.

- **A push that arrived while a deploy was running was lost, and reported as a failed deploy.** The per-minute cron moves `~/.deploy-trigger` and starts `cipi-app-deploy` also while a deploy is in progress; Deployer refused the second run ("Deploy locked by …"), the wrapper reported it as `FAILED`, sent the failure alert, and the commit it was for never deployed until the next push. `cipi deploy --status` said "it deploys when this run ends", which was not true. Now a trigger that finds a deploy in flight goes back in the queue and deploys when that one is over:
  - another automatic deploy, before, during or after Deployer (post-deploy steps, healthcheck, auto-rollback): `~/.deploy-running` holds the PID of the wrapper at work; a directory left by a run that was killed does not block;
  - `cipi deploy` or the panel while Deployer runs (Deployer always runs as the app user);
  - the very same second, Deployer's own lock decides and the push is queued again instead of reported as failed.
  - Several pushes in the meantime make one deploy, of the branch as it is then. A newer trigger is never overwritten.
- **A lock left by an interrupted deploy** (a reboot, a kill — a deploy that fails releases its own) is removed by the next deploy, automatic or by hand, when no Deployer of the app is alive, and the deploy log says so. `cipi deploy <app> --unlock` is no longer needed for it.
- **`cipi deploy <app>` while a deploy of the app is running** stops at once with "A deploy of '<app>' is running", instead of taking a database snapshot and being refused by Deployer as a failed deploy.

### Added

- **`cipi app env <app> --order=K1,K2,…`** — puts the keys of `.env` in that order (the panel's drag and drop). The list names every key once; anything else is refused and the file is left as it was. A key moves with its line(s) untouched (value, quotes, `export`) and the comments right above it; comments after a key stay with it; a blank line that started a group stays in front of the key that started it; a header stays first and the tail last. Applied after `--set`/`--unset` in the same call, so a new key can be placed where it belongs.
- **`cipi basicauth status <app> --json`** — `{app, enabled, users, agent: {mode, public_prefix}}`, and **`cipi db engines --json`** — `{default, engines: [{engine, status, port, default, server, label}]}`, where `server` is `mariadb` or `mysql` for the engine `mariadb`. What the panel reads, with no colours to parse out. The text forms are unchanged for older APIs; the panel's whitelist allows `cipi db engines --json`.
- **Backups can leave folders out: `--exclude-paths`.** An uploads folder of a terabyte is better kept with rsync than in a nightly tarball. `cipi backup profile add|edit <name> --exclude-paths=storage/app/uploads,*.mp4` — tar exclusion patterns matched against the names inside the app archive (relative to the app: `shared/…`, `htdocs/…`), after any `/` and with wildcards that cross `/`: `storage/app/uploads` leaves out `shared/storage/app/uploads`, `*.mp4` every video. `<apps>:<pattern>` applies to the apps of that name or glob only (`shop:storage/app/uploads`). Emptied again with `--exclude-paths=`.
  - Absolute paths (which never match a name in the archive), and patterns that would leave the whole app out (`*`, `shared`, `htdocs`), are refused.
  - `--dry-run` and the run itself say what each app leaves out; the archive's `meta.json` records it (`excluded_paths`), so a restore knows which folders come back from elsewhere.
  - `cipi.yml`: `exclude_paths` in a backup profile, validated the same way, exported by `cipi yml export`.
- **MySQL instead of MariaDB on port 3306: `cipi db switch mysql`.** MariaDB stays the default; MySQL is only ever an explicit choice, from the command line.
  - **Only on a server with no databases on port 3306** (no database, no app on it, nothing in the registry): the data is not converted. No in-place upgrade exists between the two, and what a dump cannot carry — MariaDB's `uuid`/`inet6` types, sequences, queries an app sends that only one of them understands — would surface later, in the apps. A server in use moves the way an app moves anywhere: a new server, `cipi db switch mysql` there before its first app, then `cipi sync` — this server stays as it was, the way back.
  - MySQL from the Ubuntu archive (8.4 LTS on 26.04; 8.0 on 24.04, where Ubuntu backports its security fixes): no repository or key of its own. The MariaDB.org repository is removed.
  - Checked before anything stops: a `mysql-server` candidate, and an apt simulation of the removal — when removing MariaDB would also remove anything but its own packages and client libraries (a Perl or Python driver, a monitoring agent), nothing changes. Then: MariaDB stopped, its data directory kept aside (`/var/lib/mysql.mariadb-<time>`), its packages purged (`libmariadb3` stays), MySQL installed with the same root password (`caching_sha2_password`) and Cipi's tuning (`/etc/mysql/mysql.conf.d/99-cipi.cnf`: buffer pool by RAM, `innodb_redo_log_capacity`, X protocol on localhost), kept off unattended-upgrades like MariaDB. When the install fails, the previous server is put back with its data directory.
  - `cipi db switch mariadb` goes back, on the same terms. `--yes` is required where no terminal can confirm it. Not in the panel's whitelist; `cipi db install mysql` (which the panel may run) never switches, it points to `cipi db switch`.
  - The engine keeps its id `mariadb` — in `apps.json`, `databases.json`, the backup layout, `cipi.yml` and the API — so nothing that stores or exchanges it changes shape; apps keep `DB_CONNECTION=mysql`. Everything that runs the server follows it: the client (`mysql`), the unit (`cipi service`, `cipi monitor`), `cipi db upgrade`, the nightly autoupdate and `cipi pending` (MySQL's packages), `cipi disk`, `cipi reset db-password`, the credentials and the URL printed at app creation (`mysql+ssh://` for TablePlus) and the labels.
  - **Dumps cross between the two:** a restore (`cipi db restore`, `cipi sync`, a backup) into MySQL drops MariaDB's sandbox line (`/*M!999999\- enable the sandbox mode */`, which the mysql client refuses) and maps its UCA 14 collations to MySQL's 0900 ones; into MariaDB, the 0900 collations become UCA 14. Rows of data are never touched.
  - Notification trigger `db_switch`.
- **A commit that failed does not deploy again by itself.** When an automatic deploy fails with the code in hand (its release has a `REVISION`), that commit is written to `~/.dep/cipi-paused-commit`, and automatic deploys of the same commit stop before Deployer: a redelivered webhook or a cipi/agent retry does not build it again (`===== deploy skipped … commit=<sha> …` in the deploy log). The head of the branch is asked of the remote with the deploy key, as Deployer does; a remote that does not answer holds nothing back.
  - **A new commit deploys as usual** and clears the pause. So do a deploy by hand that succeeds (`cipi deploy`, the panel) and `cipi deploy <app> --unlock`.
  - A deploy that fails before the code was fetched (SSH, disk, Deployer itself) pauses nothing: it is not the commit's fault.
  - The failure alert says which commit is paused and how to retry it.
  - `cipi deploy <app> --status` shows it (`Paused`), and `--status --json` has `paused_commit` (null when none).

### Changed

- `cipi deploy <app> --unlock` also resumes a paused commit; `--status` describes a leftover lock as one the next deploy removes.

### Upgrade

- Panel: cipi/api 1.43.0 and cipi/gui 4.5.0 read these (basic auth and engines as JSON, the `.env` order — rows dragged in the Environment tab —, `exclude_paths`, the paused commit, MySQL). cipi/sdk: `env()->update(…, order:)` and `env()->reorder()`; cipi-cli: `apps env order`, `apps env set --order`, `backup profile --exclude-paths`, the paused commit in `deploy status`, MySQL in `db engines`. `cipi self-update` rewrites the panel's whitelist, as on every update.
- No migration: `cipi self-update` installs the new `/usr/local/bin/cipi-app-deploy` and `/usr/local/bin/cipi-worker` as on every update. The crontab line and the `deploy.php` files are unchanged; backup profiles without `exclude_paths` leave nothing out.
- `tests/verify-5.13.0.sh` (78 checks) runs the wrapper against a Deployer stub (lock, `latest_release`, `REVISION` as Deployer 8 keeps them) and a local Git remote: a push during a running deploy (by hand and automatic), a guard left by a killed run, a stale lock, a failing commit and its redelivery, a fix, an early failure, an unreachable remote, a newer trigger. `cipi-worker` against a stub Supervisor (signals, restarts, a slow one, a program left STOPPING). Backup exclusions against real tar and the `cipi.yml` validator. `basicauth status` under `set -euo pipefail` and its JSON, `.env` reordering on a file with a header, groups, comments, quotes, `export` and a key set twice. `cipi db switch` both ways and its rollback against stubs of apt, dpkg, systemd and the two clients, the dump filter on MariaDB and MySQL dumps. **Not verified on a real server:** the MySQL packages of 24.04 and 26.04 installed over a purged MariaDB, PHP's connection to MySQL with `caching_sha2_password` over 127.0.0.1, Horizon's and the queue workers' handling of SIGTERM under Supervisor.

## [5.12.1] — 2026-11-24

### Fixed

- **Release numbers started again from 1 after 5.10.0, and deploys stopped at `Release name "2" already exists`.** Deployer 7 and 8 number a release from `.dep/latest_release` and keep the list in `.dep/releases_log`; Deployer 6 numbered from its own `.dep/releases` and wrote neither. On the servers that 5.10.0 moved from Deployer 6 (what `deployer.org/deployer.phar` served) to Deployer 8, the first deploy of every app made release `1` next to the old ones (`59 60 61`). Those were no longer in Deployer's list, so cleanup never removed them and `dep rollback` could not go back to them, and as soon as a name was already taken by an old directory the deploy failed at `deploy:release`. Servers that were already on Deployer 7 were not affected.
  - **`deploy.php` gets a `release_name` that never repeats a release already in `releases/`**: the highest of `.dep/latest_release` and the highest numbered directory, plus one (`lib/deployer/release-name.php`, appended by `deployer_release_name_ensure_hook`, as the audit hook is). Laravel, Octane and Node apps; the custom recipe has no releases. Written into every new `deploy.php` and on `cipi sync` import. It also covers a `releases/` edited by hand, such as removing a release and pointing `current` back at an older one.
  - **`deployer_release_state_repair`** (as the app user, idempotent) raises `.dep/latest_release` to the highest release, and puts the Deployer 6 releases back in `.dep/releases_log`, before the ones Deployer 8 made, with the dates of Deployer 6's own list (or of the directory). Each line it adds is marked `"imported"`. Skipped while a deploy holds the lock.
  - `cipi compliance` does not report the imported lines as releases missing from the audit ledger.

### Upgrade

- `lib/migrations/5.12.1.sh` runs both for every app and prints what it changed (`release counter 1 → 61 (next release: 62)`, `Deployer 6 releases 59 60 61 imported`). No release is renamed, deleted or switched: `current` stays where it is. The next deploy follows the highest release (`62`), and its cleanup removes old releases past `keep_releases`, Deployer 6 ones included.
- `tests/verify-5.12.1.sh`.

## [5.12.0] — 2026-11-23

The panel's server page had an SMTP tab and nothing else: Resend, SES, Slack, Discord, Mattermost, Google Chat, Telegram, ntfy, Pushover and webhooks, and the 100-odd triggers, were CLI only. This release gives the panel API what it needs to manage all of them (API 1.42, panel 4.4).

### Added

- **`cipi notification update <id> [flags]`** — change a channel in place. Every flag left out keeps its stored value, secrets included, so a form that never shows a token back can still change the recipients or the chat id. `--clear-secret` makes a webhook unsigned. The type of a channel does not change (remove it and add another). `update smtp` is `smtp configure` on top of the stored values, never interactive.
- **`cipi notification triggers --json`** (also `triggers list --json`) — every trigger with its id, category, label and state, in catalog order, and how many are on.
- **`cipi notification triggers set --on=a,b --off=c,d`** — many triggers at once, in one write; every name is checked first, an unknown one changes nothing.
- `cipi notification status --json` lists the channel types (`types`, SMTP first).
- The panel's sudoers whitelist allows `cipi notification status --json`, `triggers --json|set|enable-all|disable-all|reset`, `add`, `update`, `remove`, `test`, `enable`, `disable`. Secrets travel as flags, as `smtp configure` always did; the API runs these synchronously, so they never land in the panel's jobs table.

### Changed

- **`cipi notification test <id>` fails when the channel refuses the request** (HTTP error, timeout) with exit 1, instead of reporting "Test sent". A test now reaches a disabled channel too, so you can try it before turning it on. Delivery of real notifications is unchanged: best-effort, never blocking.
- Adding a channel whose id exists points to `cipi notification update <id>`.

### Upgrade

- `lib/migrations/5.12.0.sh` rewrites the panel whitelist (only where a panel is installed; checked with `visudo` before it replaces the old one). Channels and triggers are untouched.
- `tests/verify-5.12.0.sh`.

## [5.11.2] — 2026-11-23

### Fixed

- **The panel still got "sudo: I'm sorry www-data. I'm afraid I can't do that" for metrics after 5.11.1, on servers with sudo-rs** (the default sudo of Ubuntu 26.04, 0.2.13). The panel's whitelist was one rule listing every command, and with the 5.11.0 additions it reached about 138 items: sudo-rs refuses a list that long (`syntax error: too many items in list`, at item 128). The migrations saw the file fail `visudo`, put the previous one back with a warning easy to miss, and the panel was left without `cipi metrics …` and `cipi basicauth agent`. Classic sudo has no such limit, which is why it did not show elsewhere.
- **The whitelist is now written as rules of at most 40 commands** — sudo reads them exactly as one — so it can grow again without meeting the limit.
- `write_cipi_api_sudoers` writes to a temporary file, checks it with `visudo -c -f` and only then puts it in place: a whitelist that does not validate never reaches the sudoers directory, the previous one stays, and visudo's own message is printed instead of a generic warning. Migrations and `self-update` (which refreshes the whitelist on every update since 5.11.1) go through it.
- `lib/migrations/5.11.2.sh` runs the 5.11.0 steps again (idempotent) with the new writer.
- `tests/verify-5.11.2.sh`: a visudo with sudo-rs's limit, one that refuses the file, every command still present after the split, the real visudo when installed.

## [5.11.1] — 2026-11-23

### Fixed

- **"sudo: I'm sorry www-data. I'm afraid I can't do that" in the panel's Metrics tab.** The panel's sudoers whitelist is rewritten by migrations only; a 5.11.0 migration that did not finish — the first 5.11.0 build could wait up to 15 minutes on a busy apt, and an update stopped there never reached the sudoers step — left the panel without `cipi metrics …`. `lib/migrations/5.11.1.sh` runs the 5.11.0 steps again (all idempotent: sqlite3, collector and cron, sudoers, basic auth vhosts).
- **self-update now refreshes the panel sudoers on every update**, after the migrations, validated with `visudo` (the previous file is kept when the new one does not validate): the whitelist always matches the installed cipi.

## [5.11.0] — 2026-11-23

`cipi health` and `cipi monitor` say *that* something is wrong, and alert when it happens. Neither kept a past: the 5xx spike at 03:10, the app whose memory crept up for a week, last month's uptime. This release keeps one — on the server, in SQLite, with nothing listening on a port — and puts it in the panel with charts.

It also answers a long-standing annoyance: an app behind basic auth could not receive Git webhooks or MCP calls through cipi/agent, because neither can send the site's password. The agent's routes now stay reachable, and only those.

### Added

- **`cipi metrics` — metrics and health history** (`lib/metrics.sh`). A collector, `/usr/local/bin/cipi-metrics`, runs every minute from `/etc/cron.d/cipi-metrics` as root (one run at a time, `flock`; niced). One pass reads:
  - **host:** CPU busy % (from `/proc/stat`, since the previous run), load 1m, memory % and MB in use (`MemAvailable`), swap %, root filesystem %, network bytes/s in and out (every interface but `lo`).
  - **per app:** CPU % of one core and resident memory of the app user's processes — CPU from the ticks each PID gained since the previous run, so a process that started in between counts in full and one that ended stops counting (`ps %cpu` is a lifetime average); PHP-FPM children and `pm.max_children`, and how many times the pool **hit `pm.max_children`** in that minute (counted in `/var/log/php*-fpm.log`) — the warning that usually goes unread; **requests and 5xx per minute** from the app's nginx access log (read from where the previous run stopped, by inode and offset, so logrotate is followed); queue worker programs running and configured (Supervisor).
  - **healthcheck:** the URL of every app that has one (`cipi health set`) is probed every minute — status, expected or not, and response time — 8 apps at a time, 10 seconds each at most. `cipi metrics probe off` stops it (the 5-minute check of `cipi health` is not affected).
- **Storage: SQLite in `/var/lib/cipi-metrics/metrics.db`** (root, `0600`; the directory is `root:www-data 0750` for the OpenMetrics file). "Wide" tables — one row per scope (host, `app:<name>`) and minute, one column per metric — because one row per metric per minute meant about 180 MB a week for ten apps:
  - `samples` every minute, kept **7 days** (`raw_days`);
  - `rollups` average and maximum per **15 minutes** (`resolution_minutes`), kept **30 days** (`rollup_days`), with the number of minutes behind each, so uptime over a month is weighted correctly;
  - `events` kept **90 days** (`events_days`): every change of state of a `cipi monitor` check, healthcheck incidents (opened at the third failure in a row, the debounce of `cipi health`; closed at the first success, with how long it lasted), every release put live (`deploy`, with the post-deploy verdict) and heartbeat failures.
  - About 2 MB per app per week of raw data and a third of that per month of rollups: 20–30 MB for ten apps on the defaults. The hourly prune gives freed pages back (`auto_vacuum = INCREMENTAL`).
  - A metric a later version adds becomes a column of an existing database (`ALTER TABLE … ADD COLUMN`) the first time it is opened.
- **Retention is configurable:** `cipi metrics retention [--raw=7d] [--rollup=30d] [--resolution=15m] [--events=90d]` (raw 1–90 days, rollups up to 400 and never shorter than raw, resolution 5/10/15/30/60 minutes, events 7–730 days). Kept in the vault as `metrics.json`; a value out of range in a hand-edited file falls back to the default instead of deleting everything. `cipi metrics prune` applies it now, `cipi metrics reset --yes` deletes the history.
- **Reading it:**
  - `cipi metrics` — the server now, and per app CPU, memory, requests, 5xx, healthcheck and uptime over 24 hours, with the last hour as a sparkline; the last events. `--json` is the one call a dashboard needs (latest values, a 5-minute trend over the last hour per app, uptime 24h/7d/30d, events, collector state).
  - `cipi metrics show [--app=<app>] [--metrics=cpu,mem] [--range=24h|7d|30d] [--from= --to=] [--json]` — about 240 points whatever the range: within the raw retention from the minutes, beyond it from the rollups plus the minutes not rolled up yet. Without `--json`: min, average, max and a sparkline per metric.
  - `cipi metrics uptime [<app>] [--range=30d] [--json]` — uptime %, minutes down, average response time, incidents, and uptime per day.
  - `cipi metrics events [--app=] [--source=monitor|health|deploy|heartbeat] [--range=7d] [--json]`.
  - `cipi metrics status [--json]` — collector, last run and how long it took, database size and rows, retention, heartbeat, OpenMetrics. `--json` never carries a secret: the heartbeat URL is reported down to its host, the OpenMetrics token as `token_set`.
- **Heartbeat** — `cipi metrics heartbeat set <url> [--every=1]`, `off`, `test`, `status`. Every N minutes the collector calls the URL (healthchecks.io, Uptime Kuma's push monitor, Better Stack, Boogle, …). When the server is down, or the cron is, the calls stop and the receiver alerts: the one failure a server cannot report about itself. A failed call is recorded as an event, once, and once when calls work again.
- **OpenMetrics endpoint, off by default** — `cipi metrics openmetrics on --allow=<IP or CIDR>[,…] [--port=9273]`, `off`, `token [--show]` (rotates), `status`. The collector writes the latest values in Prometheus text format every minute (`cipi_host_cpu_percent`, `cipi_app_requests_per_minute{app="…"}`, `cipi_app_healthcheck_up`, …); this serves them with nginx on their own port, behind an IP allowlist (required; `0.0.0.0/0` refused), a bearer token, and UFW rules for the listed addresses only. Plain HTTP: the command says so and points to a private network or a tunnel. Not reachable through the panel's API: it opens a port.
- **`cipi basicauth agent <app> [public|protected|status]`** — see Changed.
- `cipi help metrics`, tab-completion for `cipi metrics` and `cipi basicauth agent`.
- **Panel API sudoers:** `cipi metrics overview|status|show|uptime|events|retention|probe|enable|disable|heartbeat *` and `cipi basicauth agent *`. Not `openmetrics` (a port and firewall rules), `prune` or `reset`. The routes that use them come with cipi/api 1.41.0 (`GET /api/metrics`, `/api/metrics/series`, `/api/metrics/uptime`, `/api/metrics/events`, `GET|PUT /api/metrics/settings`, `PUT|DELETE /api/metrics/heartbeat`, `POST /api/metrics/heartbeat/test`, `GET /api/apps/{name}/metrics`, and six MCP tools), and the charts with cipi/gui 4.3.0.

### Changed

- **Basic auth leaves cipi/agent out.** With `cipi basicauth enable`, every route of the app asked for the site's password, the agent's included — so a Git provider's push webhook got `401` and no deploy started, and an MCP client could not connect. Those routes authenticate themselves (`CIPI_WEBHOOK_TOKEN`, `CIPI_HEALTH_TOKEN`, `CIPI_MCP_TOKEN`, `CIPI_ANONYMIZER_TOKEN`, signed download URLs). Now, while basic auth is on and **the live release has `vendor/cipi/agent`**, the vhost gives the agent prefix — `CIPI_ROUTE_PREFIX` from `shared/.env`, `cipi` by default — a location of its own without `auth_basic`: `location ^~ /cipi/`, trailing slash included, so `/cipi-admin` or `/cipix` stay protected. PHP-FPM apps hand it to the pool as `/index.php` inside that location (`rewrite … break`: no second location lookup, so the protected `\.php$` location never applies); Octane apps proxy it to Octane.
  - **Checked after every deploy** (`deploy_post_release_verify`, as root): a release that adds the agent, removes it or changes `CIPI_ROUTE_PREFIX` rewrites the vhost; one that changes nothing leaves it alone. The vhost carries a marker comment (`cipi-agent-public:/cipi/`) that the check reads.
  - Not for custom or Node apps, not when a `cipi proxy` already owns that prefix, not for a prefix that is not plain path segments.
  - `cipi basicauth agent <app> protected` keeps the agent behind basic auth (apps.json `basic_auth_agent`); `public` is the default. `cipi basicauth status` and `enable` say what is left out.
- `cipi health set` points to the history (`cipi metrics uptime <app>`).
- `cipi monitor` records every change of state of a check as an event, alerting or not.

### Migration

`lib/migrations/5.11.0.sh`: installs the `sqlite3` CLI when missing (apt; a server where apt cannot gets a warning and collects nothing until it is installed), the collector, its directory and cron; rewrites the panel's sudoers (validated with `visudo`, the previous file put back otherwise); and, for each app with basic auth whose live release has cipi/agent, rewrites its vhost once so that the agent's routes are left out — saying so per app, with the command that undoes it. Nginx is reloaded only when a vhost changed. Nothing else restarts.

### Notes

- It records; it does not page. Alerts stay with `cipi monitor` and `cipi health`, and go where `cipi notification` sends them.
- The collector costs about 0.2 s of CPU a minute on a server with a few apps (it reads `/proc`, one `ps`, the new bytes of each access log, one `supervisorctl status`, one SQLite transaction).
- CPU of an app is the app user's processes. PHP-FPM masters run as root and are not counted; FrankenPHP (Octane) and Node processes are the app user's and are.
- Memory of an app is the sum of the resident sets of its processes: pages that PHP-FPM children share are counted once per child, so it is an upper bound.
- Requests and 5xx come from the access log Cipi gives the app's vhost; a request nginx answers itself (a redirect of `cipi redirect`, a `cipi proxy`) is counted too.

## [5.10.0] — 2026-11-22

An Octane app answers on the PHP built into its FrankenPHP binary, and until now that binary was nobody's: Laravel Octane downloads `releases/latest` of FrankenPHP into the project whenever it finds none there, `octane:install` puts `frankenphp` in `.gitignore`, and Deployer starts every release from a fresh checkout. So **every deploy of an Octane app downloaded whatever FrankenPHP GitHub had that minute** — a new PHP minor included, the day FrankenPHP's static builds move to it — and the deploy that did it could be a webhook at any hour. Nothing at night touched the binary; the deploys did. And the fix `cipi php upgrade` printed for a vulnerable build (`php artisan octane:install --server=frankenphp`, then a restart) did not work: `octane:install` keeps a binary that is already there.

This release makes the binary Cipi's, adds JIT per app, fixes two bugs of a freshly installed server (every deploy failing on Deployer 6, `cipi gui` failing at SSL), and turns `cipi smtp` into `cipi notification`: one command for every channel a notification can go to — SMTP, Resend, Amazon SES, Slack, Discord, Mattermost, Google Chat, Telegram, ntfy, Pushover and signed webhooks.

### Added

- **FrankenPHP builds, pinned per Octane app** (`lib/frankenphp.sh`). Builds live in `/opt/cipi-frankenphp/builds/<id>/` (root's, `0755`, never rewritten), each with the FrankenPHP and PHP versions inside it, its SHA-256 and where it came from; an app's pin is the symlink `/opt/cipi-frankenphp/apps/<app>`. Outside `/opt/cipi` on purpose: `cipi self-update` copies that tree into a backup on every run, and a build is about 100 MB.
  - `cipi frankenphp [status] [--json]` — each Octane app's build, the PHP inside, patched / vulnerable / not the app's PHP minor / not pinned, and whether the running binary is still an older one (restart pending).
  - `cipi frankenphp upgrade <app>|--all [--to=<build>] [--no-fetch] [--yes]` — the newest build on **the app's own PHP minor** (apps.json `php`) and FrankenPHP major, downloaded first when GitHub has a newer release; the download is checked against the SHA-256 digest GitHub publishes for the asset and the binary is asked its versions as `nobody`. Octane is restarted, has to answer on its port within 30 seconds, and the previous build is put back when it does not.
  - `cipi frankenphp use <app> <build> [--no-restart] [--force]` — refused, unless `--force`, for a build on another PHP minor than the app's, or below the FrankenPHP the live release's `laravel/octane` asks for (Octane would replace it with the latest download at start).
  - `cipi frankenphp import <binary>` — a build made elsewhere. **The way to run several PHP minors:** GitHub's static binaries carry one PHP minor at a time (the newest); a build on another one comes from FrankenPHP's static builder (`PHP_VERSION=8.5`). Apps on 8.5 and on 8.6 then run different builds on the same server.
  - `cipi frankenphp adopt <app>`, `fetch [<version>]`, `remove <build>`, `prune`.
  - **A binary that comes out of an app's release is that app's only.** `adopt` copies it into the store (read as the app user, probed as the app user); it is never offered to, or `use`d for, another app: the app user could have put anything there.
- **`cipi app jit <app> [on|off|status] [--mode=tracing|function] [--buffer=128M] [--json]`**, for PHP-FPM and Octane apps (not Node apps, not PHP before 8.0). Before anything is written, the PHP that will run the app is asked to start with JIT in that mode — its CLI for PHP-FPM, the FrankenPHP binary (`php-cli`) for Octane — so an extension that disables JIT (Xdebug, pcov) or a build without it is refused there. After the restart PHP-FPM has to be active, or Octane answering on its port; otherwise the previous setting is put back and restarted. Stored in apps.json as `jit`, so every later pool rewrite keeps it.
  - **PHP-FPM:** one FPM per PHP version serves all its pools, and the JIT buffer is shared memory its master maps at start (`opcache.jit_buffer_size` is `PHP_INI_SYSTEM`); PHP 8.4 starts with `opcache.jit = disable`, which a pool cannot undo. So while an app on version X has JIT, X's FPM gets `conf.d/99-zz-cipi-jit.ini` — `opcache.jit = off` (startable, off) and the largest buffer asked for — and only that app's pool gets `php_admin_value[opcache.jit]`. Every other pool keeps JIT off. The file goes with the last app that turns JIT off. A value set with `cipi ini set` wins: an `opcache.jit` of its own is left alone, a larger buffer is kept, and `opcache.jit = disable` makes `cipi app jit … on` refuse with the command that undoes it. Turning JIT on or off restarts that PHP's FPM, as `cipi ini set` does.
  - **Octane:** FrankenPHP is one process per app, so the app gets its own ini directory, `/etc/php/cipi-octane-apps/<app>/`, at the end of `PHP_INI_SCAN_DIR`, with both settings.
  - `cipi app convert` turns JIT off (it was checked for the other runtime) and says so. `cipi app edit --php` and `cipi app delete` keep the server-wide file in step.
  - What JIT gains depends on the app: CPU-bound PHP gains, a request that waits on the database or an API gains little. Measure it on yours.
- **`cipi autoupdate` has a `frankenphp` component** (nightly, 04:20, on unless switched off: `cipi autoupdate off frankenphp`): `cipi frankenphp upgrade --all` within each app's PHP minor and FrankenPHP major, with the same check and the same way back. A release on another PHP minor, or a new FrankenPHP major, is announced once per app (trigger `frankenphp_available`) and never applied by itself. Skipped for the night while a deploy is running.
- **Notification triggers** `frankenphp_upgrade`, `frankenphp_available`, `app_jit`.
- **`cipi pending`** lists an Octane app whose build carries a PHP below the security floor (critical), a build not on the app's PHP minor, a binary Octane downloaded that is not pinned yet, and an Octane still running an older binary than its pin.
- **Panel API sudoers:** `cipi app jit *`, `cipi frankenphp status [*]`, `cipi frankenphp upgrade *`. Not `import` (a path on the server) nor `use` (whose `--force` skips the PHP-minor check). The routes that use them come with cipi/api 1.40.0 (`GET|PUT /api/apps/{name}/jit`, `GET /api/frankenphp`, `POST /api/frankenphp/upgrade`, and the matching MCP tools).
- `cipi help frankenphp`, tab-completion for `cipi frankenphp` and `cipi app jit`.

- **`cipi notification`** — where notifications go, in one place. Every trigger (`cipi notification triggers`) reaches every enabled channel:
  - `cipi notification [status] [--json]` — SMTP and every other channel, enabled or not, and how many triggers are on. `--json` never contains a secret: an API key, token, AWS secret key or webhook secret is reported as `<name>_set: true`, a webhook URL down to its host.
  - `cipi notification add <type> <id> …`, `remove|enable|disable|test <id>` (`test all`), `triggers [list|enable|disable|enable-all|disable-all|reset]`.
  - **`smtp`** — the SMTP server, as before: `cipi notification add smtp --host= --user= --password= --from= --to=` is `cipi smtp configure`, and the channel is the `/etc/cipi/smtp.json` the server already has. **Nothing to redo on an existing server.**
  - **`resend`** (new) — email through the [Resend](https://resend.com) API: `--api-key=re_… --from= --to=a@x,b@y`. The key goes to curl on stdin, not on its command line.
  - **`ses`** (new) — email through Amazon SES, API v2 (`SendEmail`), with the request signed with AWS Signature Version 4 by Cipi itself (openssl; no AWS CLI): `--region= --access-key= --secret-key= --from= --to=`. The IAM user needs `ses:SendEmail` only; while the account is in SES's sandbox the recipients must be verified too. The secret key is used to sign and never sent.
  - **`mattermost`**, **`googlechat`** (new, incoming-webhook URL) and **`pushover`** (new, `--token=<app> --user=<user key>`; an urgent trigger is sent at priority 1). `slack`, `discord`, `telegram`, `ntfy` as before.
  - **`webhook`** takes `--secret=`: the JSON body is then signed, `X-Cipi-Signature: sha256=<HMAC-SHA256 of the body, hex>`, so the receiver can tell the request comes from this server. http:// is accepted for `webhook` and `ntfy` (an internal receiver), https:// is required for the chat webhooks.
  - A secret left out of the command line is asked for on a terminal, without echo. All channels are kept in `alerts.json`, encrypted by the vault, as the chat channels already were.
  - `cipi notifications` (the older name, with its `list`, `enable|disable <trigger>`, `channel …`) and `cipi smtp …` keep working, and so does the panel's SMTP page: its sudoers rules are the same. `enable|disable <name>` toggles a channel when `<name>` is one, a trigger otherwise.

### Changed

- **The Octane recipe links the pinned build into each release** (`cipi:frankenphp`, the first task after `deploy:vendors`, run as the app user by `/usr/local/bin/cipi-frankenphp-link`): `<release>/frankenphp → /opt/cipi-frankenphp/apps/<app>/frankenphp`. Octane finds it and downloads nothing; every release — the live one and the ones a rollback goes back to — follows the pin, and releases no longer carry a 100 MB copy each. When the release's `laravel/octane` asks for a newer FrankenPHP than the pin, the deploy stops there, before the migrations and with the live release untouched, and says what to run. An app without a pin is deployed as before (Octane downloads), and `cipi deploy` then pins the binary Octane downloaded, the nightly run too.
- **The Octane Supervisor program** puts the live release first on `PATH` (Octane looks for `frankenphp` on `PATH` before the project, so a FrankenPHP installed on the system would win over the pin) and adds the app's own ini directory to `PHP_INI_SCAN_DIR`. Written whenever the program is rewritten (`cipi frankenphp use|upgrade`, `cipi app jit`, `cipi app limits`, convert); the migration does not rewrite running programs.
- **`cipi app create --octane` and `cipi app convert --to=octane`** pin the newest build on the app's PHP that the server already has (no download); `cipi app clone` gives the copy the source's build when that build may go to another app.
- **`cipi app edit <octane app> --php=X.Y`** warns when the pinned build carries another PHP, with the command that moves it.
- `cipi ini set opcache.jit … --app=` and `opcache.jit_buffer_size … --app=` point to `cipi app jit`: a pool line alone cannot make JIT startable, and a per-app buffer size is not written to the pool (it never had an effect there).

### Fixed

- **Every deploy of a new server failed with "Task `deploy:publish` not found"** ([#519](https://github.com/cipi-sh/cipi/issues/519), reported by batv45). `setup.sh` downloaded `https://deployer.org/deployer.phar`, which now serves **Deployer 6.8.0**; Cipi's recipes are written for Deployer 8, and Deployer 6 has no `deploy:publish`. The installer printed the version without checking it, and the deploy-time check only acted on Deployer 8 and later. Now:
  - Deployer comes from its GitHub release, **pinned to 8.0.5** and checked against the SHA-256 GitHub publishes for `deployer.phar`, then asked its version before it is installed (`lib/deployer-install.sh`, `cipi_deployer_install`). A download that does not match, or a phar that is not Deployer 8, is not installed.
  - `setup.sh` stops when it cannot install it, instead of finishing a server that cannot deploy.
  - `cipi deploy` stops on Deployer 6 with what to run, instead of the task error.
- **`cipi gui <domain>` failed at its SSL step** ([#520](https://github.com/cipi-sh/cipi/issues/520), reported by batv45): the panel's vhost included `snippets/fastcgi-php.conf`, which Ubuntu's `nginx-common` ships and the nginx.org packages — Cipi's since 5.9.1 — do not, so `nginx -t` refused the vhost. It now has the lines the app and API vhosts use (`try_files $uri =404;`, `include fastcgi_params;`, an explicit `SCRIPT_FILENAME`).
- **`cipi php upgrade` advised a fix that did nothing** for a vulnerable FrankenPHP build (`octane:install` keeps an existing binary). It now names `cipi frankenphp upgrade <app>`, shows the build each app is pinned to and a pending restart.

### Migration 5.10.0

1. Installs `/usr/local/bin/cipi-frankenphp-link` and creates `/opt/cipi-frankenphp` (the `cipi self-update` that runs the migration may be the old one, which does not know the helper).
2. Pins, for each Octane app, the FrankenPHP binary in its live release: the one it runs now. Same bytes: **nothing restarts and no app changes PHP.** An app with no binary there gets one at its next deploy.
3. Adds the `cipi:frankenphp` hook and task to each Octane app's `deploy.php` in place, the rest of the file as it is; a `deploy.php` without the lines of Cipi's recipe is left alone, with a warning.
4. Rewrites the panel's sudoers where a panel is installed, checked with `visudo` and put back if refused.
5. **Deployer:** a server whose `/usr/local/bin/dep` is not Deployer 8 gets 8.0.5, the same way. **Deployer 7 is kept** where an app still runs PHP older than 8.3, which Deployer 8 cannot run: the migration names those apps; after `cipi app edit <app> --php=8.3` the upgrade is `source /opt/cipi/lib/deployer-install.sh && cipi_deployer_install`. A download that fails leaves the current `dep` in place, with a warning.
6. **The panel's vhost:** one that includes `snippets/fastcgi-php.conf` gets the same line instead — on a server moved to nginx.org by migration 5.9.1 the snippet may be gone, and the next reload would fail. `nginx -t`, then a reload; the previous file is put back if nginx refuses the new one.

JIT stays off for every app. The notification configuration is not touched: `smtp.json` is the SMTP channel, the chat channels of `alerts.json` are channels of `cipi notification` as they are.

### Verification

`tests/verify-5.10.0.sh` (179 checks) runs the real libraries, the link helper and the migration under `set -euo pipefail` against a fake root, with Supervisor, systemd, curl/GitHub, runuser, PHP and PHP-FPM as stubs that keep state and FrankenPHP binaries as scripts that answer `-v`, `build-info` and `php-cli` as the real one does. The notification channels are checked against a curl that records every request: the Resend request (key on stdin, body), the SES request (its SigV4 signature recomputed in the test, and the key derivation against AWS's own published test vector), the webhook signature, Pushover's form, one request per enabled channel and none for a disabled one. The Deployer installer runs against a stubbed download (wrong checksum, a Deployer 6 phar with a matching checksum, a failed download, the pinned one), with the deploy guard and both migration steps (Deployer 6 → 8, Deployer 7 kept for an app on PHP 7.4 and upgraded without one, the vhost rewritten and put back when `nginx -t` fails). **Not verified on a real server before this release:** the real Deployer download (the SHA-256 is the one GitHub's release API publishes for v8.0.5); delivery to the real Resend, SES, Pushover, Mattermost and Google Chat endpoints; a real FrankenPHP static binary (its `-v` and `php-cli` output, JIT under its ZTS build), PHP's own acceptance of `opcache.jit` set per FPM pool after `opcache.jit = off` at startup, Supervisor's `update` on a rewritten program, and GitHub's asset digests. The verify scripts of 5.7.1 and 5.9.0 pin the old Octane `environment=` line and the old list of autoupdate components, and fail on those checks now.

---

## [5.9.1] — 2026-11-19

nginx 1.31.9 (18 November) is a security release with ten CVEs. On 19 November the PHP project released PHP 8.6.0, and security releases of every other supported branch with it: 8.2.36, 8.3.37, 8.4.28 and 8.5.13. This release is about all three.

Two of the nginx CVEs were reported to us by name, CVE-2026-123007 and CVE-2026-123633. Both are in nginx, not in PHP, and both are in its HTTP/2 code: a memory corruption in flow control (1.9.5–1.31.8) and a use-after-free while proxying with `worker_connections` exhausted (1.19.7–1.31.8). **A server as Cipi 4 or 5 sets it up cannot be reached by either**: Cipi's vhosts are `listen 443 ssl;`, it never writes `http2 on;`, and nginx has HTTP/2 off by default since 1.25.1. They apply where someone turned HTTP/2 on by hand, on a vhost Cipi 3 wrote (`listen 443 ssl http2`) — and on servers that followed the pull-request preview workflow in our own documentation, which patched the vhost with that same line until today.

That is not the end of it, because two others in the same release need nothing but a stock Cipi server: CVE-2026-118899, an endless loop while reading a request body over TLS 1.3 (a worker stuck at 100% CPU per request, on any HTTPS vhost; 1.13.0–1.31.8), and CVE-2026-125283, a buffer overflow with `try_files` under an `alias` — which is exactly what the panel API vhost had for `/api-docs`. The remaining six are in parts Cipi does not use (resolver, HTTP/3, mail, stream, PROXY protocol v2). So every server needs nginx 1.31.9, whatever its HTTP/2 setting.

Looking at how servers would get it turned up a mistake of ours. Since 4.5.9 Cipi runs nginx from nginx.org's mainline repository: that is what the README says, what `cipi autoupdate` follows every night, and what migration 4.5.9 moved existing servers to. But `setup.sh` lost that on 10 June (4.6.5), when it was restored from an older copy after an empty commit: **every server installed from 4.6.5 to 5.9.0 runs the Ubuntu archive's nginx** (1.24.0 on 24.04) with the headers-more module, and without `max_headers`, the HTTP/2-bomb limit 4.5.9 was about. On those servers nginx is also excluded from `unattended-upgrades` (Cipi's own blacklist, meant for the nginx.org package), so it got Ubuntu's security updates from nobody; and the nightly `cipi autoupdate` run for nginx, which since 5.9.0 adds the nginx.org repository and asks apt to upgrade the installed packages, cannot be counted on to do it either: nginx.org's `nginx` declares a conflict with Ubuntu's `nginx-common`, and that run asks apt to upgrade both at once (we read this from the packages' metadata; we did not reproduce the nightly run on such a server). Ubuntu has published fixed packages for these CVEs (`1.24.0-2ubuntu7.20` on 24.04, `1.28.3-2ubuntu1.13` on 26.04); those servers did not get them.

### Security

- **nginx 1.31.9 or newer, on every server, from nginx.org mainline.** Migration 5.9.1 upgrades the package where the server is already on nginx.org, and moves the server there where it is on the Ubuntu archive's build: one apt transaction (nginx.org's `nginx` in, `libnginx-mod-http-headers-more-filter` out), simulated first — if apt cannot do all of it nothing is removed and nginx stays as it is, with a warning. The move is also refused before anything is touched when the installed nginx already fails `nginx -t`, or when a file other than `nginx.conf` uses a headers-more directive (`more_set_headers` and the like, which nginx.org's build does not have): in both cases the new binary would not start, and the warning names the files. `nginx.conf` is adapted in place and keeps everything else in it (the `modules-enabled` include and the headers-more directive go, `max_headers 1000;` comes in); a copy of the previous file stays beside it as `nginx.conf.cipi-<timestamp>.bak`. Only if nginx refuses the adapted file is it replaced by Cipi's own.
- **The binary that answers requests is the one just installed.** The nginx.org package asks the running master to start the new binary and, when that fails, prints a line and exits 0; when it works, old workers stay for as long as one of their connections is open — hours, with a WebSocket. Either way the fix is on disk and not in memory. After an nginx upgrade Cipi now waits a few seconds and looks at `/proc/<pid>/exe` of every nginx process: if one still runs a deleted binary, nginx is restarted instead of reloaded (connections are dropped for well under a second). This is in the migration, in `cipi nginx upgrade`, and in the nightly `cipi autoupdate`.
- **`cipi nginx upgrade` (and the nightly run) on the Ubuntu archive's nginx moves it to nginx.org mainline**, the same way the migration does, instead of failing on a package set apt cannot upgrade. Asked first when run by hand.
- **`setup.sh` installs nginx from nginx.org mainline again**, with `max_headers`, and stops if apt hands it the archive's package anyway. A test now compares the `nginx.conf` of `setup.sh` with the one in `lib/nginx.sh`, so the two cannot drift apart unnoticed a second time.
- **The panel API vhost serves `/api-docs` without `alias`.** The server's `root` already is that directory, so the `alias` did nothing but put `try_files` under one (CVE-2026-125283). The migration removes the line from an installed vhost when it is the one Cipi wrote, tests with `nginx -t`, and puts the file back if nginx refuses it.
- **`cipi pending` knows about nginx**: below `nginx_security_floor` (1.31.9; critical), on the Ubuntu archive's build (warning, with the command that fixes it), or upgraded on disk with the old binary still running (critical). The floor is one line in `lib/common.sh`, like PHP's, Composer's and Node's.
- **`cipi nginx security`** prints the same for a person: patch level, whether the running binary is the installed one, and every configuration file that turns HTTP/2 on. The migration prints the HTTP/2 line too, so the output of `cipi self-update` says whether CVE-2026-123007 and CVE-2026-123633 could reach that server.
- **A failed download of the nginx.org signing key no longer empties the keyring.** The key was piped straight into the keyring file on every nightly run; a network error left a zero-byte keyring and apt refused the repository until the next successful run. It is written to a temporary file and moved into place only when it is not empty.
- **PHP security release of 19 November: 8.2.36, 8.3.37, 8.4.28, 8.5.13.** `php_security_floor` is raised to them. 8.6.0, released the same day, carries the same fixes and is the floor of its branch. The migration runs `cipi php upgrade`, which installs them from the repository and restarts PHP-FPM; that afternoon packages.sury.org — the repository Cipi sets up first — had all four, the Launchpad PPA and the Ubuntu archive not yet. From this release on `cipi php list`, the nightly `cipi php upgrade` and `cipi pending` report anything older as vulnerable. What is fixed, and where a Cipi server stood before the update:
  - **CVE-2026-129289**, PHP-FPM request smuggling through an unread request body (critical: code execution without authentication). It needs a front end that reuses its FastCGI connection. Cipi's vhosts never set `fastcgi_keep_conn`, so nginx closes the connection after every request and the attack as published does not reach them. A vhost written by hand with `fastcgi_keep_conn on` is exposed until PHP is updated: `nginx -T | grep fastcgi_keep_conn`.
  - **CVE-2026-129291**, use-after-free in the PHP-FPM master: from code running in a worker to the master's user, root. It needs `catch_workers_output`, which the pools of the panel API and of the GUI set and the app pools do not, so someone would first have to run code as the user of one of those two pools. The update fixes it; the setting stays, it is what puts a killed worker's last words in the journal.
  - **CVE-2026-126714** and **CVE-2026-115560**, sessions (code execution through a session file overwritten halfway, or read back with another serializer). Both name upload progress as the way in, and that is off in every pool since 5.6.3 and in every Octane app since 5.7.1. The first also applies to an app that keeps untrusted data in PHP's own file sessions; Laravel's session drivers do not use that handler.
  - **CVE-2026-129474**, use-after-free while collecting the backtrace of a fatal error (8.5 and later, code execution; the advisory names Laravel facades as a path that reaches it). It needs `fatal_error_backtraces` on, and that is off in every pool since 5.6.3 and in every Octane app since 5.7.1.
  - **CVE-2026-129496**, use-after-free of the timezone cache (code execution). It needs PHP to write a diagnostic to its error log while starting — a configuration error, a deprecated setting — and that log to be a file, which it is in every Cipi pool. Cipi's own configuration is not known to produce such a diagnostic, an ini setting added by hand can; nothing in Cipi closes this one, the update does.
  - **CVE-2026-129292**, script injection in the full HTML view of the PHP-FPM status page. The panel API pool has a status page; nginx answers it to 127.0.0.1 only, and `cipi api status` reads the short text view with curl: nothing on the server renders the full one as HTML.
  - Also fixed: CVE-2026-129538 (php-cgi, which Cipi does not use), CVE-2026-128090 (PHAR signatures), CVE-2026-129501 (DOM, 8.4 and later), CVE-2026-15353 and CVE-2026-129506 (SOAP), CVE-2026-129481 (session shutdown, 8.3 and later), CVE-2026-129182 (the last fatal error's backtrace, 8.5 and later), CVE-2026-128064 and CVE-2026-127960 (the https/ftps and http stream wrappers), and in 8.5 and 8.6 CVE-2026-48841 and CVE-2026-129438 (URI).
  - Not reached by apt: an Octane app runs the PHP inside its FrankenPHP binary. `cipi php upgrade` lists each one with its PHP and calls it vulnerable until the app has a FrankenPHP build on a fixed release. And PHP 8.1 and older get none of these fixes.

### Added

- **PHP 8.6.** `cipi php install 8.6`, `cipi php switch 8.6`, `cipi app create --php=8.6`, `cipi app edit <app> --php=8.6`, `php: "8.6"` in `.cipi.yml`; `cipi php list --json` offers it as installable, `cipi status`, `cipi service`, `cipi ini` and the panel pools know the version.
- **A new server is installed with PHP 8.6; an existing one keeps the PHP it has.** `setup.sh` installed 8.5. It now installs 8.6 and makes it the server's PHP (the `php` command, the panel's pools) — when the repository has a release of it with every extension Cipi installs. For as long as it has a release candidate, or no `php8.6-redis`, `-memcached` or `-imagick` yet (on the afternoon of the release: packages.sury.org has 8.6.0 and none of the three; the Launchpad PPA still has a release candidate), the installer gives the server 8.5 as before and says why on its last screen, with the two commands that move it later (`cipi php install 8.6`, `cipi php switch 8.6`). A release candidate, or a server whose apps cannot reach Valkey because phpredis is missing, is not something to get by default. On a server that is already installed nothing changes: the migration does not install 8.6 (it says so), and `cipi php install 8.6` adds the version without making it the server's — it also puts the `php` command back where it was on a server whose alternative had been left on automatic, where apt would have handed it to 8.6.
- **An app is not put on a PHP that is still waiting for extensions.** `cipi php install 8.6` installs the version without the extensions the repository does not have yet and said so; nothing then stopped `cipi app edit <app> --php=8.6`, and an app that keeps cache, sessions or queues in Redis answered 500 on a PHP without the `redis` extension. Now `cipi app create` and `cipi app edit --php` refuse such a version, name what is missing and show how to go on: `--force`, for an app that uses none of them. In `cipi app edit` the check comes before anything else in the command is applied, a `--domain` included. `cipi app clone` follows, since it creates the copy on the source's PHP. In cipi.yml, `php:` on such a version is a blocker of the plan, as a version that is not installed already was, and the message gives the `cipi app edit … --force` command. A Node app is let through: its PHP only runs Deployer and the webhook receiver. The panel gets the same refusal as the failed job's output; it has no way to send `--force`, which is a decision for the command line. The rule ends by itself: when `cipi php upgrade` has installed the extensions the list is empty.
- **Legacy PHP (7.4–8.2) is managed where it is still installed.** Since 4.5.4 an app runs on 8.3 or later and the older versions cannot be installed or assigned; a server set up before that can still have them, with apps on them. `cipi php list`, `cipi php remove`, `cipi service` and the panel pools already knew them. Two places did not: `cipi status` listed the running PHP-FPM of 8.3 and later only, and a server-wide `cipi ini set`, `unset` or `reset` wrote 8.3 and later only, so an app still on 8.2 kept the old value of a setting changed "server-wide". Both now cover every installed version. Nothing else changes for them: no install, no assignment, no deploy under Deployer 8. The README said "PHP 7.4 to 8.5" selectable per app, which stopped being true with 4.5.4: it says 8.3 to 8.6.
- **`cipi app create` without `--php` uses the server's PHP** instead of 8.5 written in the code: 8.6 on a server installed with 8.6, 8.5 on the ones installed before, whatever `cipi php switch` chose since. This is what the panel already proposed. With 8.5 hard-coded, an app created without `--php` on a new server would have stopped at "PHP 8.5 not installed". A Node app, which uses PHP only for Deployer and the webhook, takes the same one. `cipi yml example` writes the app's PHP, or the server's, instead of `"8.5"`.
- **A branch that is new in the repository installs without the extensions it does not have yet.** PHP's own packages are published first; redis, memcached and imagick are separate projects and follow later (today packages.sury.org has `php8.6-fpm` and no `php8.6-redis`, `-memcached` or `-imagick`). `cipi php install` used to fail on the first missing package. It now asks apt what it can install, stops only if PHP itself (`fpm`, `common`, `cli`) is missing, installs the rest and writes the missing extensions to `/var/lib/cipi/php-ext-pending`. The daily `cipi php upgrade` installs them as soon as apt has them and restarts that version's FPM; `cipi pending` lists them until then. The install says so in plain words, including what it means: Laravel's default Redis client is the redis extension.
- **An app's `composer.lock` may have to be refreshed before it moves to 8.6.** Not Cipi's doing, but it is the first thing a deploy on 8.6 runs into: every Laravel app depends on `nette/schema` and `nette/utils` (through `league/commonmark`), and their releases before 20 October 2026 declare PHP up to 8.5, so `composer install` refuses the lock. `composer update nette/schema nette/utils` in the project fixes it (1.3.7+ and 4.1.6+). A deploy that fails this way leaves the release that was live in place.
- **A release candidate is called one.** `cipi php list`, `cipi php upgrade` and `cipi pending` show `prerelease` for a PHP whose `PHP_EXTRA_VERSION` is `RC…`, `beta…`, `alpha…` or `-dev`, instead of judging it against the security floor. 8.6's floor is 8.6.0. `cipi php upgrade` moves an installed release candidate to the release when the repository has it.

### Fixed

- **`cipi api <domain>`, `cipi api update`, `cipi api upgrade` and `cipi self-update` restarted PHP-FPM 8.5 by name** after writing the panel's FPM pool, while the pool is written for the system PHP (`cipi php switch`). On a server switched to 8.4 — or 8.6 — the new pool was not loaded until something else restarted that FPM. They restart the FPM of the system PHP.
- `cipi help php` and the message of `cipi service upgrade php` still said the PHP upgrade is weekly; it is daily since 5.6.3.

### Verification

`tests/verify-5.9.1.sh` (167 checks) runs the real libraries and the migration under `set -euo pipefail` against a fake root, with apt, dpkg, nginx, systemctl and `/proc` as stubs that keep state: both kinds of server, apt refusing the move, the installer's choice of PHP with 8.6 released, as a release candidate, without its extensions and absent, an app asked onto a PHP that is waiting for extensions (create, edit, cipi.yml, with and without `--force`, a Node app), a configuration that would not survive it, nginx refusing the adapted file, the old binary staying in memory, a second run. **Not verified on a real Ubuntu server before this release**: that apt resolves the move from the archive's nginx packages to nginx.org's as expected (the code simulates it first and stops if it does not), what the two packages' maintainer scripts do to the running nginx during the swap (the code handles both a stopped nginx and an old binary left running), and Deployer on PHP 8.6. PHP 8.6.0 came out while this release was being prepared, and nothing here was run on it: the workstation had 8.6.0RC5. On that build: the test suites of cipi/gui (228 tests, on Laravel 13 and Livewire 4), cipi/agent (50) and cipi/sdk (112), and for cipi/api — which has no framework test suite — its standalone checks (83) and a syntax check of every file. The new patch levels of 8.2–8.5 were not installed anywhere either: what was checked is that the fixed packages are in the repository and that the floors are compared correctly. PHP 8.6 on the panel API (cipi/api 1.39.2) and in `cipi.yml` from the app's side (cipi/agent 2.1.1) need those releases.

---

## [5.9.0] — 2026-11-16

Two security reports, both verified and both closed in this release. They came in through the private channel in SECURITY.md and had not been shared elsewhere; thanks to the two researchers.

The first: every app user was a member of the `www-data` group, and every PHP-FPM socket on a Cipi server — each app's, the stock `www` pool's, the panel API's and the GUI's — is group `www-data` with mode 0660. So an app user, or code running inside an app (an RCE, a malicious Composer or npm dependency, an SFTP password shared with a freelancer), could open any other app's socket, send it a FastCGI request for a script under `/tmp` (in every pool's `open_basedir`) and run PHP as that app: read its `.env`, its database credentials, its keys. The stock `www` pool runs as `www-data` without `open_basedir`, and `/etc/sudoers.d/cipi-api` — written by `setup.sh` on every server, API installed or not — lets `www-data` run `cipi ssh add`, which appends a key to the `cipi` admin user; from there `sudo cipi credentials` prints the root password. One compromised tenant, the whole server. The membership was never needed: nginx and the panel reach an app the other way round, `www-data` is in each app's group.

The second: every app user may run `cipi-app-notify <app> *` as root through sudo (that is how a failed webhook deploy sends its alert), and the helper compared its exit-code argument with `-eq`. bash evaluates the operand of `-eq` as an arithmetic expression, and an arithmetic expression evaluates array subscripts, command substitutions included: `sudo cipi-app-notify myapp deploy 'BASH_VERSINFO[$(id > /tmp/pwned)]'` ran `id` as root. One command from any app shell to root.

Reviewing the second one turned up the same mistake in one more place. Every `cipi` command reads its options through `parse_args`, which stores `--name=value` with `printf -v "ARG_name"`: bash evaluates an array subscript in the name it is given there too, so an option written `--x[$(id > /tmp/pwned)]` ran `id` — as root, like everything `cipi` does. An app user cannot run `cipi`, with one exception: an app with `cipi yml auto <app> on` has the sudo rule `cipi yml node-sync <app> *` (the Node recipe calls it during a deploy), and that rule lets it pass arguments. Opt-in and per app, but for those apps the same road to root.

Going back over the first report's open points turned up a third problem, not reported by anyone: root wrote in a directory the app user owns. `~/logs` belongs to the app, and three things wrote there as root — nginx (the master opens every `access_log` and `error_log` when it loads its configuration), supervisord (it opens a program's `stdout_logfile` each time it starts it) and Cipi itself, which on every `cipi deploy` ran `mkdir`, `chown <app>:www-data` and `chmod 2775` on `~/logs` and appended to and then `chown`ed `~/logs/deploy.log`. None of them refuses a symlink. Reproduced with Cipi's own code: with `~/logs/deploy.log` a symlink to a root-only file, the next `cipi deploy <app>` run by an admin or by the panel left that file owned by the app user, mode 664 — `/etc/shadow`, say; with `~/logs` itself a symlink, the directory it pointed at became the app's. The same directory was *read* as root too: `cipi app logs` and `cipi-read-app-logs` (the panel's log viewer) printed whatever a symlink called `x.log` pointed at, and the latter also accepted `..` in its pattern.

Then the same question was asked of everything else root does under `/home/<app>` — some eighty places where `cipi` wrote, read, chowned or chmodded a name the app user can replace with a link, in `cipi deploy`, `cipi app env`, `cipi app edit`, `cipi auth`, `cipi git`, `cipi sync`, `cipi yml`, `cipi scan` and the helpers an app user may call through sudo. The answer was the same nearly everywhere, and it is now one rule: **root does not open, create, delete, chown or chmod a path inside the home of an app that exists, and does not run a program on a tree it finds there; it asks the app user to** (`sudo -u`), so a link to a root-only file is a "permission denied" for that user and not a file handed over. Reproduced with the previous code and an unprivileged user, each with one symlink: `~/.deployer/deploy.php` (every `cipi deploy` appends the audit hook and ran `chown`), `~/.deployer/node-build.sh` and `node.json`, `shared/.env` (`cipi app env --set`, which the panel can run), `shared/auth.json`, `shared/cipi-databases.env`, `~/.ssh` and what is in it (`cipi git` key rotation, `cipi deploy --trust-host`), a `cipi.yml` saved into a linked directory, and `.env`, `auth.json` and `shared/storage` on `cipi sync` — the target ended up owned by the app or overwritten; `cipi app env --show`, `cipi auth show`, the deploy key shown by `cipi app show` and the `cipi.yml` parser printed or read what the link pointed at. Most of these run when an admin or the panel runs a command on that app; an app with `cipi yml auto on` can also reach some of them alone, through the sudo rules that setting gives it (`cipi yml apply <app> --yes --auto`, `cipi yml node-sync`) — that path was read in the code, not run end to end.

One of the findings is not a symlink. `cipi app clone`, the Reverb and Meilisearch settings and `cipi sync` copied values *out of an app's `.env`* into a `sed -i "s|^KEY=.*|KEY=<value>|"` run by root. A `|` in the value ends the replacement, and GNU sed's `e` flag runs what follows: a line like `MAIL_PASSWORD=;<command>;|e;s|a|b` in an app's `.env` ran `<command>` as root the next time an admin cloned that app or synced it. Reproduced; the value is now escaped, and the edit is made by the app user.

The second part of the release is what a look at the rest of the stack, and at the security releases of the last months, said was missing. Three places were left where root worked on names it does not control: the panel's two trees, where `cipi api update`, `cipi gui update` and the nightly `cipi self-update` ran Composer as root in a directory `www-data` owns — the user every request to the panel runs as — and so ran, as root, whatever plugin or script that user had put there; the `.env` of those trees, edited by root with `sed`, `>>` and `chown`; and logrotate, which copied, truncated and compressed each app's Laravel and PHP-FPM logs as root inside the app's home. All three now work the way the app homes do: root asks the owner. Then the things nothing looked after: nginx, MariaDB, PostgreSQL and Valkey are kept out of `unattended-upgrades` on purpose and waited for someone to run `cipi … upgrade`, Composer and the Node.js runtimes were never updated on a server once installed, and a kernel update did nothing until a reboot nobody was told about. Cipi now patches the first six every night and says, every morning, what is waiting for a person. And Valkey: one instance and one password for every app meant every app could read the others' cache, sessions and queues; an app now has an instance of its own.

The third part is what people who run Cipi every day asked for, on the command line first — the panel API (1.39.0) and the GUI (4.2.0) are built on these commands.

One of the requests was a bug report: "deploys started by the webhook do not save how long they took". They do — both deploy paths write the same end banner, with the duration, to the deploy log. What loses it is the night: `deploy.log` is rotated daily (`copytruncate`), so the banners of yesterday's runs are in `deploy.log.1` and older ones in `deploy.log.N.gz`, and the panel read `deploy.log` alone. A deploy somebody starts is watched while it runs; one a push starts is looked at the day after, when its banner is no longer in the file. The history is now a command that reads the rotated files too.

What was prepared as 5.8.6 was never published on its own: all of it is here, with one migration (`5.9.0`) and this one entry.

### Security

- **App users are no longer in `www-data`.** `cipi app create` and `cipi sync` create them in `cipi-apps` only; `www-data` still joins each app's group, which is all nginx and the panel need. Migration 5.9.0 removes every app user (members of `cipi-apps`, keys of `apps.json`; nothing else) from `www-data` on installed servers, restarts PHP-FPM — a worker keeps the groups it was forked with — and then what each of those apps has running under supervisor, what every deploy restarts anyway: only what is running, so a program stopped with `cipi worker stop` stays stopped. A Node SSR app is restarted the way a deploy does it, blue/green with no downtime; if the new process does not come up the old one keeps serving and the migration says so (`cipi node restart <app>`). An app whose name `cipi app create` would not give out today (a reserved word) is reported and left as it is. Open SSH/SFTP sessions of app users keep the old membership until they log out.
- **The stock `www` pool socket is 0600** (`setup.sh`, `cipi php install`; the migration adds the line to the placeholder Cipi wrote and leaves a hand-edited `www.conf` alone, with a note). No vhost points at that pool and `www-data` owns the socket, so nothing changes for nginx.
- **`/etc/sudoers.d/cipi-api` exists only while a panel is installed.** `setup.sh` no longer writes it on every server; `cipi api <domain>` and `cipi gui <domain>` write it when they install, `cipi api remove` / `cipi gui remove` drop it with the last panel. The migration removes it from servers with neither. Servers with the API or the GUI keep it as it is: nothing in the panels changes.
- **`cipi-app-notify` validates every argument before it uses one.** The exit code must be 1–3 digits and is compared as a string, never with `-eq` or `(( ))`; the label a short word; the app name app-shaped and, when called through sudo, the caller's own; the log file a regular file that resolves under `/home/<app>/` or `/var/log/cipi-apps/<app>/` (symlinks followed — a link to `/etc/shadow` is "no log", not a read as root) and is read as the app user; the free text bounded to 4 KB and stripped of control characters. The environment of a sudo caller is ignored. Legitimate calls (`cipi-app-deploy`, with `deploy`, `deploy-ok`, a numeric status, the app's own `logs/deploy.log`) are unchanged. No migration: self-update installs the new helper before anything else.
- **An option name is a name.** `parse_args` accepts letters, digits, `-` and `_` in the name of an option and ignores anything else, so nothing a caller writes before the `=` reaches `printf -v` as an expression. Values were never evaluated and still are not. Every real option (`--force`, `--per-page=20`, `--301`, `--set=KEY=a=b`, quoted values from the panel API) parses as before. No migration: self-update installs `common.sh` before anything else.
- **Root builds and backs up in private directories.** `cipi self-update` cloned into `/tmp/cipi-update-$$` after removing it: a local user who recreated the empty directory in between owned the tree root copies over `/opt/cipi`. `cipi api <domain>` and `cipi api upgrade` built in `/tmp/cipi-api-build` and backed the panel `.env` and token database up to `/tmp/cipi-api-backup-<epoch>`, the GUI's upgrade to `/var/tmp/cipi-gui-backup-<epoch>`. All of them are `mktemp -d` now, mode 0700; `cipi api remove` and `cipi gui remove` clean the new names as well as the old. So is the directory `cipi gui` copies its bundled package into (`/tmp/cipi-gui-pkg-$$`, the line the first report pointed at), and the one `cipi sync export` stages in: that was `/tmp/cipi-sync-<time>`, world-readable for as long as the export ran, with every exported app's `.env`, the decrypted `apps.json`, `databases.json`, `smtp.json` and the database dumps in it.
- **What root writes for an app is no longer in the app's home.** nginx access and error logs, the logs of supervisor programs (queue workers, Horizon, Octane, Reverb, the two Node slots) and `deploy.log` are in `/var/log/cipi-apps/<app>/`: a directory of root's (`root:<app>`, 0750) that the app user reads and cannot write, so nothing in it can be swapped for a symlink. `deploy.log`, which both `cipi deploy` (root) and a webhook deploy (the app user) append to, is a file the app user owns inside that directory. `~/logs` stays the app's, with a symlink per moved log — made by the app user, not by root — so `~/logs/nginx-access.log`, `tail -f ~/logs/worker-default.log`, the paths in the docs and in your own scripts keep working; the app's own logs (`php-fpm-error.log`, `cron.log`) do not move. The app's PHP pool gets `/var/log/cipi-apps/<app>/` in `open_basedir`, so code that reads `~/logs` from PHP (cipi/agent) still can. logrotate, CrowdSec's acquisition, the 5xx monitor and the compliance report follow the logs.
- **Migration 5.9.0 moves every app, and puts back what a service refuses.** Vhosts: `nginx -t` first (a configuration that already fails is not touched), the edit, `nginx -t` again, one reload — refused, every vhost goes back byte for byte and nginx is not reloaded. Supervisor: the program files are edited and re-read; a running program is restarted once on its new configuration, a stopped one is not started (its new configuration is applied, and it starts, with the next deploy on the server). Node SSR apps are switched blue/green. PHP-FPM is tested before its restart, and a pool whose `open_basedir` someone rewrote is left alone. The log files from before the move stay in `~/logs` as `<name>.old`, with their old rotations: delete them when you no longer need them; `deploy.log` starts from the last lines of the old one, so the deploy history in the panel is still there. A copy of every file edited is in `/var/lib/cipi/app-logs-backup/<time>/`. Whatever could not be moved is listed at the end and keeps working where it was; `cipi app fix-permissions [app]` runs the move again.
- **Root does not follow a link in an app's home when it restores permissions.** `cipi app fix-permissions` and every `cipi deploy` ran plain `chown` and `chmod` on names under the home (`~/.ssh/*.pub`, `shared/.env`, `shared/storage/*`, `~/logs`): a symlink of that name aimed them at any file. Ownership is now `chown -h -R` on the home, which walks the tree by descriptor and changes a link, never what it points at, and every `chmod` and `setfacl` inside the home is done as the app user. Log files root left in `~/logs` and `shared/storage/logs` are handed back from *inside* that directory (`cd`, then `chown -h -R --from=root .`) and only when its physical path is the one its name says: with `shared` or `shared/storage` a link, the name alone led somewhere else.
- **Root does not write, read or change a file inside an existing app's home; the app user does.** New helpers in `lib/common.sh` (`app_as`, `app_read`, `app_write`, `app_append`, `app_sed`, `app_rm`, `app_mkdir`, `app_call`) run the operation with `sudo -u <app>`, and everything that touched a home goes through them: `deploy.php` (generated, the audit hook, `cipi app edit --branch/--repository/--php`, `cipi auth`), `~/.deployer/node-build.sh` and `node.json`, `~/.cipi/webhook.json`, `shared/.env` (`cipi app env` including the editor, `--show` and `--json`; domain, SSL, environment, branch, PHP version, database and Valkey password, webhook token, Octane, Reverb, Meilisearch), `shared/auth.json`, `shared/cipi-databases.env`, `~/.ssh` (deploy key and its rotation, `authorized_keys`, `known_hosts`, `config`, the CodeCommit key), `~/.bashrc`, the deploy lock, a generated `cipi.yml`. A file that exists keeps its inode and its mode, as before; a new one gets the mode it always got. What root still does itself is on names an app cannot swap — `/home/<app>` — or follows nothing: `chown -h -R`, `rm -rf`, a test. A file or directory root left as `root:root` inside a home in the past is handed back whole (`chown -h -R` on the top-level entry) the first time it is in the way. Not changed: `cipi app create` and `cipi sync import` of a new app, where nobody can be that user before the command has finished.
- **A value from an app's `.env` is data, never part of a command.** The functions that set a key (`cipi app clone`, Reverb, Octane, Meilisearch, `cipi sync`) escape `\`, `&` and `|` before sed sees the value, run as the app user, and `cipi sync` rebuilds the `.env` with awk reading the kept `DB_*` values from the environment. Before, such a value ran as a command of root's (above).
- **`cipi sync` reads and writes an existing app as that app's user.** `export` copied `.env`, `auth.json`, `deploy.php` and the SSH files with `cp`, which follows a link: any root-only file could be carried into the archive. The files are now read by the app user (same content, same modes in the archive), `shared/storage` is archived and unpacked by the app user, and an update writes `.env`, `auth.json` and `deploy.php` through the helpers. The passphrase reaches `openssl` through its environment (`-pass env:`), no longer on a command line every local user can read in `ps`; archives made either way open with either.
- **git reads a release as the app user.** Root's git refuses a repository owned by someone else, because its configuration is the owner's; `cipi-deploy-audit`, which any app user may run through sudo, turned that check off (`git -c safe.directory='*'`) to read a custom app's commit. No way to abuse the one command it ran was found, and it is gone all the same: the helper reads the commit, `REVISION` and Deployer's `releases_log` as the app user, and so do `cipi deploy --releases` and the deploy notifications.
- **`cipi scan` hashes a tree inside the app's home, or none.** `current` and `htdocs` are the app's names. Pointed outside the home — at `/etc` in the test — the nightly scan had root read and hash that tree, and so did `sudo cipi-scan-manifest <app>`, which the app user may run whenever it likes: `/` would be the whole disk. Both check the physical path first; a release that is not inside the home is not hashed and is reported as a pass that could not complete, with the reason.
- **Smaller ones.** The path of the pre-deploy database snapshot is kept in memory, not in `/tmp/cipi-predeploy-<app>.path` (a name any local user could create first). When Cipi asks an app's own FrankenPHP binary for its PHP version, the binary runs in a session of its own (`setsid`, no terminal): before, it shared the terminal of the admin who ran the command and, where the kernel still allows `TIOCSTI`, could type into it. `_cipi_remount_rw` writes its error to a `mktemp` file.
- **App logs are read as the app user.** `cipi app logs`, `cipi app logs read`, `cipi-read-app-logs` (the panel API's log viewer) and the log excerpt in a failed-deploy email drop to the app user before they open anything under its home; `cipi-read-app-logs` also refuses `..`, a second path and anything that is not a number as page or page size. Same output, same paths for the panel.
- **A new server starts with SSH/SFTP for app users closed from outside.** `setup.sh` writes the `cipi-nossh` rule `cipi ssh apps` already used and sets the default to disabled: a new app gets its SSH password as before, `cipi app create` says access from outside is off, and `cipi ssh apps enable <app>` (or `enable --all`) opens it. Deploys use `ssh localhost` and are not affected. **Servers already installed are not changed**: their default stays what it was.

- **In the panel's trees, Composer, artisan and `.env` edits run as `www-data`.** `/opt/cipi/api` and `/opt/cipi/gui` belong to `www-data`. `cipi api update`, `cipi gui update`, `cipi api status` and the nightly `cipi self-update` ran `composer config`, `composer require`, `composer reinstall` and `composer show` there as root: Composer loads the plugins in `vendor/` and runs the scripts in `composer.json`, both files of `www-data`'s — whoever could run code as the panel's user (a bug in the panel, in one of its dependencies) became root at the next update, which is every night. They now run as `www-data` (`panel_composer` in `lib/common.sh`), with a Composer home of its own in `/var/lib/cipi-panel/composer`. A tree is recognised by where it is, not by who owns it at that moment: `self-update` chowns all of `/opt/cipi` to root before it updates the panel, and what is in the tree is still what `www-data` wrote. The `.env` of both trees — `APP_URL`, `LOG_STACK`, `SESSION_DRIVER`, the SSO keys of `cipi gui sso` — is edited and read as `www-data` too: root's `sed -i`, `>>` and `chown www-data` on that name went wherever a symlink led, and the `chown` handed the file over. The same for `token-abilities.txt`, the SQLite pragmas (root ran `sqlite3` on the path the `.env` names), the copies `cipi api upgrade` / `cipi gui upgrade` take of `.env` and the database before a rebuild (a link there ended up, as a regular file owned by `www-data`, in the new tree), and the permission repair, which chowned and chmodded `storage`, `.env` and `database.sqlite` by name. `cipi gui reset-user` writes the new password in a file of root's making under `/run`, not in `storage/app`. A build directory, which is root's until it is moved into place, is worked on by root as before.
- **logrotate rotates an app's own logs as the app user.** `/etc/logrotate.d/cipi-app-logs` named `/home/*/shared/storage/logs/*.log` and `/home/*/logs/php-fpm-*.log`: root copied, truncated and compressed files by path in directories the app user owns. Each app now has a rule of its own, `/etc/logrotate.d/cipi-home-<app>`, with `su <app> <group>`, and the two `/home/*` lines are gone from the shared rule. No script in the rule — logrotate runs those as root even with `su`. Logs whose group is `www-data` from before the first half of this release are put in the app's own group by the app user: logrotate gives each copy the owner and group of the log, and cannot give a group its user is not in. Written at `cipi app create`, at every deploy and import, removed with the app; the migration does it for every app, shared rule first. A shared rule someone has rearranged is left as it is, and said.
- **One Valkey per app.** Every app got the same `REDIS_PASSWORD`, the server's: any app could read and write the cache, the sessions and the queued jobs of every other app, and one `FLUSHDB` emptied them all. A new Laravel app now gets an instance of its own — `cipi-valkey@<app>.service`, running as the app's user, on its own localhost port (from 6400), with its own password, `/etc/cipi-valkey/<app>.conf` (root:<app> 0640) and `/var/lib/cipi-valkey/<app>` (0700). Instances rather than ACL users on the shared one: an ACL confines an app to a key prefix, and Laravel's prefix is a setting of the app — two apps with the same `APP_NAME` share it. **Apps that exist are not touched**: `cipi valkey isolate <app>` (or `--all`) moves one when you say so — the app goes into maintenance mode, its workers stop, its keys are copied with their expiry (by the prefix the app itself reports, `MIGRATE … COPY`), the `.env` is switched, the config cache rebuilt, workers restarted, maintenance mode off. A copy that is refused leaves the app exactly where it was. An app whose prefix cannot be read is not moved unless you ask for `--no-copy`; one whose `.env` points Redis at another host is left alone. `cipi valkey share <app>` goes back; `cipi valkey flush-shared` empties the shared instance and changes its password once nobody uses it. `cipi app clone` no longer copies `REDIS_HOST`, `REDIS_PORT`, `REDIS_PASSWORD` from the source; `cipi sync` keeps this server's Valkey settings for an app that exists and gives an imported one an instance here (its `.env` arrived with the other server's password, good for nothing). No password is ever on a command line: the client gets it in its environment, the copy on its standard input.
- **The server's SSH keys log in as any app user — and a disabled app accepts nothing else.** `sshd` asks `/usr/local/bin/cipi-ssh-keys` (run as `cipi`) for the keys of the `cipi` user at every login as an app user: no copies to keep in step, and a key removed with `cipi ssh remove` stops working for the apps at once. Those keys already reach root, so this hands out nothing new; what it removes is the reason to enable an app's password just to look at it. An app with SSH access disabled (`cipi ssh apps disable`, the default on a new server) was closed from outside altogether; it now takes the server's keys and nothing else — `AuthenticationMethods publickey`, `AuthorizedKeysFile none` — while an enabled one takes its password and its own keys as before, next to them. Cipi's two older blocks in `sshd_config` become one managed section, validated by `sshd -t` before it replaces the live file; a block someone added lines to is kept. On every server, for every app, by the migration. `cipi ssh apps sync` rewrites the section.
- **`cipi db restore <name> <file>` opens the file as the owner of the tree it is in**: the app user for a dump in an app's home, `www-data` for one in the panel's storage (where the API keeps the dumps uploaded through it). Root opening a name another user controls lends its rights to whatever the name points at — the rule 5.9.0 applied everywhere else under `/home/<app>`. A dump in a directory of root's is read as before.

### Added

- **`cipi autoupdate`** — nginx, MariaDB, PostgreSQL, Valkey, the Node.js runtimes (`/opt/cipi/node` and the system package) and Composer are patched every night at 04:20, with the code of the manual commands: patch releases only, Cipi's configuration kept, `nginx -t` before the reload, a Node runtime checked against its published SHA-256 and SSR apps restarted blue/green only when their runtime changed, Composer rolled back if the new phar does not start. One component after the other, the databases last; a database waits for the next night while a dump or a deploy is running. The four packages stay out of `unattended-upgrades`, which would restart them at any hour. `cipi autoupdate off <name>` for a component you want to patch by hand, `cipi autoupdate run [name]` for now. On for everything unless switched off — on existing servers too, from the migration: **a database patch restarts the database, at 04:20, on the night it arrives.** Composer below 2.10.3 (the security release of 2026-08-27) is updated by the migration itself; `setup.sh` installs nothing older.
- **`cipi pending`** — what is waiting for a person: a reboot installed updates need (Ubuntu's flag, and the newest kernel in `/boot` against the running one), PHP below its security release or end of life, a newer package where the automatic update is off or its last run failed, Composer and Node.js below their security releases, apps that share one Valkey, Ubuntu's security updates switched off, a Cipi logrotate rule that logrotate refuses — and **PHP extensions installed with PECL**. Cipi installs extensions from apt only and has never used PECL; an extension built with `pecl install` is a file no package owns, nothing updates it, and PECL is deprecated by the PHP project in favour of PIE. Checked every morning at 07:30 and mailed when the list changes, then again after a week while it lasts (trigger `pending_report`); `cipi status` shows the list when there is one; `--json` for a script.
- **`cipi reboot`** — whether a reboot is required and since when; `cipi reboot now`; and `cipi reboot auto on [--at=HH:MM]`, off by default: a nightly job that restarts the server only on the nights a reboot is required, after a notification and a two-minute warning, and not while a package installation, a dump, a deploy or another `cipi` command is running.
- **`cipi api token create --full-access`** — a token with the wildcard ability instead of a list: every endpoint and the MCP server, and the abilities later versions of the API add (a token holding today's whole list does not get those). `f` in the checklist. Also `--name=`, `--abilities=a,b` and `--expires=YYYY-MM-DD`, so a token can be created without the prompts — the command the GUI shows when you add a server now works as written.
- **A failed deploy releases its lock.** The Laravel recipes end with `after('deploy:failed', 'deploy:unlock')`, and the migration adds the line to the `deploy.php` of the apps that exist: the deploy after a failed one starts, without `cipi deploy <app> --unlock`. A deploy refused because another one is running is not a failure for Deployer and releases nothing.
- **`cipi auth create <app>` opens the editor** when it is run on a terminal (`--no-edit` to skip): an `auth.json` without credentials is of no use, and getting there took a second command.
- **`cipi deploy <app> --history [--limit=30] [--json]`** — past deploys and rollbacks, newest first: result, release, duration, exit code, trigger, branch, when it started and ended. It reads `deploy.log` and its rotated files, newest first and only as far back as it takes. `--json` gives each run the keys of `last` in `--status --json`, with ISO 8601 times. **`cipi deploy --last [--json]`** is every app's last run in one call (and `cipi deploy <app> --last` one app's). Both also exist with the flag first — `cipi deploy --history <app>` — because a Cipi older than 5.9.0 answers "App '--history' not found" to that form and would *deploy* on the other: the panel uses the safe one. `cipi deploy <app> --releases` finds a release's duration in the rotated logs as well.
- **Horizon is detected at deploy.** When a deploy finds `laravel/horizon` installed, `QUEUE_CONNECTION=redis` in the app's `.env` and no queue worker configured, it enables Horizon (what `cipi worker horizon enable <app>` does) — an app in that state has nothing processing its jobs. In the other two cases it says what to do, once per situation, and changes nothing: with `queue:work` workers already there (they are never replaced on their own) and with another queue connection (the two commands to run are printed; the `.env` is never edited). `cipi worker horizon disable <app>` is remembered: Horizon is not turned back on. Webhook deploys run as the app user and cannot enable it; `cipi pending` lists the apps left without a worker.
- **Databases linked to an app.** `cipi db create --app=<app>` creates a database and shows it as that app's — the WordPress of a custom app, a second database of a Laravel app. `cipi db link <database> <app>` and `cipi db unlink <database>` do the same for one that exists. A link is a line in the app's entry of `apps.json` (`databases: [{name, engine}]`): it is in the projection the panel reads, travels with `cipi sync`, and is gone with the app — the database is not, and `cipi app delete` says which ones it left. It is a label: the database keeps its own user and password. `cipi db list` has an APP column on a terminal, and `--json` carries `app` and `link` for every database — `linked`, `own` (the one created with a Laravel app) or `namespace` (`<app>_…`, what `cipi.yml` lets an app declare). `cipi app show` lists the linked ones.
- **`cipi backup status --json`** — what a backup page is drawn from: the destinations (never their keys), every profile with the apps and databases its globs cover right now, its last run, whether it is overdue or running, and the apps and databases no enabled profile takes. It only reads: no default profile is created and no "overdue" mail is sent, however often it is asked. **`cipi backup list --json [--profile=]`** lists the runs each destination holds with one listing per profile and bucket.
- **`cipi backup run --detach [--profile=NAME]`** starts the run and returns; the output goes to `backup.log`, like the scheduled runs, and `cipi backup status` says how it ended. Under systemd the run gets a transient unit of its own, otherwise a session of its own — the panel's queue worker gives a command ten minutes and takes its children with it when it is recycled.
- **`cipi backup profile edit <name> --exclude-databases=`** (and `--exclude-tables=`) with nothing after the equals sign empties the list; until now an exclusion could be changed but not removed.
- **An optional Git provider step in `setup.sh`.** After the install the wizard asks where the repositories are — GitHub, GitLab (gitlab.com or self-hosted), Bitbucket, Azure DevOps, or Enter to skip — shows where the token is created and which permissions it needs, and saves it with `cipi git <provider>-token` (read without echo). With a token, `cipi app create` adds the deploy key and the webhook to each repository by itself. Skipping changes nothing, and without a terminal the step only prints the command for later.
- **The panel may manage Node runtimes, backup profiles and database links.** `/etc/sudoers.d/cipi-api` gains `cipi node install|default|upgrade|remove`, `cipi db link|unlink`, `cipi backup status --json`, `backup list --json`, `backup run --detach`, `backup verify`, `backup profile add|edit|remove|enable|disable` and `backup destination test`. Migration 5.9.0 rewrites the file on servers with a panel, checks it with `visudo` and puts the previous one back if it is refused. Not there, on purpose: `backup configure` and `backup destination add|edit|remove` (an S3 secret on a command line, which the panel would also keep in its jobs table), `backup key`, `backup fetch`, `backup prune`, and a backup run that is not detached.

### Changed

- `cipi db list`, piped or run by the panel, prints the four columns it always had: the panel API before 1.39 reads that table with a regex.

### Fixed

- **A custom app without a repository can be created from the panel.** `cipi app create --custom` asked "Git — leave empty to use SFTP only" whenever `--repository` was not on the command line — also with no terminal, where the answer is end-of-file: the command stopped there and the panel showed the question as the error (creating a WordPress or any SFTP-only app from the GUI). It now asks on a terminal only. The summary and the prompt also say what a custom app's docroot is: a path inside `~/htdocs`, `/` being `htdocs` itself.
- **`sudo cipi node restart <app>` works.** `cipi-node-switch` accepts a sudo caller only when it is the app itself — right for the rule an app user has, wrong for `cipi`, which is root and merely *started* with sudo by the `cipi` admin or by the panel. `cipi node restart`, `cipi node upgrade --restart`, the process lines of `cipi node status` and the stop in `cipi app delete` were all refused with "cipi cannot manage <app>". `cipi` now calls the switch as root's own action.
- **The daily swap flush cannot take the server down.** Root's crontab ran `swapoff -a && swapon -a` every morning with no check: on a small server whose swap was really in use, everything in it was pushed back into RAM at once and the OOM killer picked what to stop. It now runs only when there is something in swap and the available memory is more than twice that. `setup.sh` for new servers; the migration rewrites that one line of root's crontab and leaves every other line as it is.
- **A failed migration says what state the server is in.** The message read "installation unchanged"; the new release's files were already in place, only `/etc/cipi/version` had not moved. It now says so, that the migration runs again on the next update (the nightly one too), and where the previous files are kept.

- **`cipi scan` notices a hash pass that lost files.** The name of the error file was chosen in a subshell and never reached the caller, so the check for "could not read every file" always found nothing: `cipi scan manifest` installed the short list as the new baseline, and the nightly comparison reported the unread files as removed. The errors are now seen: the manifest is left as it was and the app is reported as not checked, as the code always meant.
- **`cipi app clone` copies a `.env` value with `|`, `&` or `\` in it as it is.** A `|` made sed fail and the clone stopped half way; an `&` came out as the old value pasted into the new one.
- **`cipi sync` updates an app whose `.env` has no `DB_HOST` (or any other `DB_*` key).** The missing key ended the command there without a word — an SQLite app, for one — and the apps after it in the archive were not synced either.
- **`cipi deploy --releases` and the deploy emails show the commit again where a release has its `.git`.** Run by root, git refused a repository owned by another user and the columns stayed empty.

### Tests

- `bash tests/verify-5.9.0.sh`, in two halves. The first: both proofs of concept, the log reader against `..` and a second path, the swap check on sample `/proc/meminfo` values, and the migration run for real against a fake root (every command that would touch the machine stubbed): who leaves `www-data` and who does not, the move of the logs with nginx, supervisor or PHP-FPM refusing the new configuration and everything going back, the stopped worker that stays stopped, the Node switch, one app at a time, a second run that changes nothing. It also runs the new helpers, the `.env` functions with a value that carries a command, the sync `.env` merge, the integrity hashing and the Laravel recipe under `set -e`, on a fake home with `sudo` stubbed. What needs real accounts was run by hand as root against unprivileged users planting symlinks, the previous code and this one side by side on the same fixture, with and without `set -e`: where the previous code changed the owner of the target, overwrote it or printed it, this one leaves it untouched, and on an ordinary home both leave the same files, content, owners and modes (the differences are the ones listed here). `nginx`, `supervisord`, `sshd` and `ssh-keygen` themselves were not run, and none of this ran on a real server: try `cipi deploy`, `cipi app env`, `cipi app edit --php` and a `cipi sync` on a staging server before the release. The older suites that write a vhost or a supervisor program learn the new log directory.
- The second half: the Horizon states and the advice given once; the history across rotated and gzipped logs, a run that starts before a rotation and ends after it, a time `date` cannot read, a control character in a banner, the forms that must never deploy; links (one app at most, own and namespace databases, the four columns checked with the old panel's regex); who opens a dump; the backup JSON (no key in it, covers, overdue, uncovered, nothing written), a detached run really started in its own session; the sudoers rules, parsed by `visudo`.

### Ecosystem

- **cipi/api 1.39.0** — names the full-access role on its side (`cipi:token-create --full-access`, `* (full access)` in the token list); the CLI flag works with older versions of the package too, since the wildcard is Sanctum's own. New with it: deploy history and last deploys, Node runtimes (install, default, upgrade, remove), backup profiles, database links, the upload of a database dump in chunks.
- **cipi/gui 4.2.0** — a security fix of its own (what a user may do on an app is asked of the grants at every request, never taken from the page) and the pages for all of the above: a backup matrix, Node runtimes, the last deploy in the app list, dump upload, a confirmation dialog in place of the browser's, saved Artisan commands, deferred loading everywhere.
- What changes for a server that updates: the server's keys log in as app users; the panel's Composer runs as `www-data`; six components are patched at night (`cipi autoupdate off` to opt out); a mail when something is waiting; a deploy that finds Horizon installed, the queues on Redis and no worker turns Horizon on; where a panel is installed its sudoers file is rewritten. What does not: no app's Valkey, no reboot, no SSH setting of an app.
- Not run for real before the release, and worth a look on a staging server: the per-app logrotate rules (logrotate is not on the machine the release was prepared on — `cipi pending` reports a rule logrotate refuses), the `cipi-valkey@` systemd unit (the instances themselves were run with the unit's command line, as real users, against a real server), the apt side of `cipi autoupdate`, and `systemd-run` for `cipi backup run --detach` (its fallback, a session of its own, was). The sshd section was checked with a real OpenSSH 9.6 on the layouts of existing servers; the panel helpers with the real `www-data` and a real Composer.
- cipi/sdk, cipi-cli, cipi/agent: no change needed. The panels run `cipi` through the same sudoers whitelist, which is written by their own install from now on; `cipi ssh add` from the panel still works. The panel's log viewer asks for the same `~/logs/…` paths and gets the same pages, and cipi/agent reads `~/logs` through the symlinks. A server that had the API or the GUI removed by hand and the sudoers file left behind loses that file with the migration — expected, it reappears with the next `cipi api <domain>` / `cipi gui <domain>`.
- Left as they are, by choice: `open_basedir` keeps `/tmp/` for every app (packages that hard-code it would break with a per-app directory; a sibling app can no longer reach the pool, so it is no longer a cross-app vector), and the nightly self-update follows the `latest` branch without a signature check. On servers installed before this release, password SSH/SFTP for app users stays as it was (`cipi ssh apps disable --all` turns it off for every app user and for apps created later).
- Still as it was: `cipi app create` and `cipi sync import` of a new app write the new home as root (no one can be that user yet); `cipi sync push` passes the passphrase to the remote `cipi sync import` on its command line, visible in `ps` on the target while it runs; `cipi compliance` and `cipi disk` read one line of `REVISION` and of `shared/.env` as root after checking that no link is on the way, and keep only a commit hash or a database name from it.

---

## [5.8.5] — 2026-10-29

From the field: the IP tab of the panel refused every change with `mv: inter-device move failed: '/tmp/tmp.…' to '/etc/cipi/api-ip-whitelist'; unable to remove target: Read-only file system`. Two defects in one line. `cipi api ip-whitelist` built the new list under `/tmp` and moved it into place: when `/tmp` is a filesystem of its own — tmpfs, the default on recent Ubuntu and Debian, or the private `/tmp` of a systemd unit — that move is not a rename but a remove-then-copy, so for a moment there was no whitelist at all (allow all, for the API) and a crash or a full disk in between left none. And the whitelist writer was the one `/etc/cipi` writer without the read-only handling the vault, SMTP and basicauth received in 5.0.x: a root the kernel had remounted read-only after a disk error, or a caller sandboxed by systemd, surfaced as that raw `mv` message, with nothing about the cause.

### Fixed

- **`cipi api ip-whitelist add|remove|set|allow-all` replace the list atomically**: the new content is written to a temporary file next to `/etc/cipi/api-ip-whitelist` and renamed over it. A crash leaves the old list or the new one, never none, and the rename never crosses a filesystem.
- **A read-only `/etc/cipi` is handled like every other mutating write**: the same remount attempt as `vault_write`, then — when it does not help — one error that says which cause it is and what to do, and nothing changed. A root the kernel remounted read-only (`errors=remount-ro`): the mount line, the remount error, `dmesg` and `mount -o remount,rw /`. A process in a mount namespace of its own (a systemd unit with `ProtectSystem=` or `ReadOnlyPaths=`, where `/etc` is read-only for that process alone and looks fine from a shell): the unit that started cipi, read from its cgroup, and the `systemctl show` to run. The panel API answers 422 with the CLI's output, so this is what the IP tab now shows.
- **`cipi api ip-whitelist show` on a read-only `/etc/cipi` no longer aborts**: creating the default file is best-effort and a missing file reads as allow all, as the API middleware already treats it.
- **`cipi api ip-whitelist add|remove|set|allow-all` from the panel no longer wait for the public-IP hint.** The summary printed after every change looks the server's public IP up with a `curl` capped at 5 seconds, a hint for a person at a terminal; the panel API discards that output but waited for it on every click of the IP tab. The hint is computed only when stdout is a terminal.
- **`vault_write` and `vault_seal` write next to the file as well.** Every vault file (`apps.json`, `server.json`, `databases.json`, …) went through the same `mktemp` + `mv`: on a server with a tmpfs `/tmp`, each save of the server's configuration removed the live file and copied the new one in. Now a rename; a failed encryption removes its temporary file and returns an error instead of leaving a half-written one behind.

### Ecosystem

- cipi/api needs no change: the message reaches the IP tab as soon as the server runs 5.8.5 (`cipi self-update`, or the nightly update at 03:50). A server whose root is already read-only cannot self-update until it is remounted: `mount -o remount,rw /` first.
- cipi/gui 4.1.1: every button that calls the server — the IP tab's included — ignores further clicks while the request is out and shows a spinner when the answer takes longer than 150 ms. One Livewire action interceptor for the whole panel; buttons with a `wire:loading` of their own keep it. And a time zone per account (Settings → Profile, UTC until chosen) that every time the panel shows follows.
- Tests: `bash tests/verify-5.8.5.sh`.

## [5.8.4] — 2026-10-29

From the field: a deploy started by a Git push is invisible while it runs — whoever watches the panel sees nothing until the ledger shows the result — and a release that fails its post-deploy healthcheck is a surprise to someone who never meant to set one (the log read `Healthcheck FAILED after 5 attempts — got 404`, on an app whose `/up` route does not exist). Three things change: Cipi can now say whether a deploy is running, whoever started it; the failed check says where it comes from and how to turn it off; and `cipi yml example` no longer arms a healthcheck when committed as it is.

### Added

- **`cipi deploy <app> --status [--json] [--tail=N]`** — is a deploy running right now? Both deploy paths write the same start and end banners to `/home/<app>/logs/deploy.log`, so the answer covers `cipi deploy`, the panel, a Git push through the webhook, cipi/agent and rollbacks alike. `state` is `running` (with `phase` `deploy` while Deployer builds the release, `post-deploy` while the post-deploy steps, cipi.yml and the healthcheck run after it), `queued` (a push the per-minute cron has not picked up yet), `interrupted` (a start banner with no end and nothing alive any more — a reboot or a kill; the lock left behind is what `--unlock` removes) or `idle`. `current` names the trigger, the branch, the previous release, the start time and the seconds elapsed; `last` the result, kind (deploy or rollback), release, duration, exit code and trigger of the last finished run; `--tail=N` adds the last lines of the log. Timestamps carry the server's UTC offset. Read-only and safe to poll: the panel does, every few seconds, to show a deploy it did not start (cipi/gui 4.1.0 through cipi/api 1.37.0, `GET /api/apps/{name}/deploy/status`).
- The start banner of a `cipi deploy` run by the panel API says `trigger=panel` (it said `cli`); the audit ledger already told the two apart. `--status` and the panel now do too, while the deploy runs.

### Fixed

- **A failed post-deploy healthcheck says where the check comes from** — `cipi health set`, the panel's "Enable healthcheck", or a `health:` block in cipi.yml — and how to change it: `--url=`, `--no-postdeploy` to keep the five-minute probe but skip the one after deploys, `cipi health unset` to remove it. A 404 adds the usual cause: Laravel serves `/up` only with the health route on (`bootstrap/app.php`, `health: '/up'`). In the deploy log and in the alert email. Nothing about the check itself changes: it still runs only for an app that has a `health_url`, and it never alters the deploy's exit code.
- **`cipi health set <app> --no-postdeploy`** (or any switch on its own) **keeps the URL and the status already set**; it reset them to `https://<domain>/up` and 200, silently re-aiming a custom URL.
- **`cipi yml example` ships its `health:` block commented out**, as `cipi yml generate` does for an app without one. Committed as it was, with auto-apply on, the example set a healthcheck on `/up` — and the post-deploy verdict that goes with it — on the first deploy. Its header now says what the file is: a catalogue of every section, to prune before committing; applied whole it would also add aliases, redirects, a proxy, databases and backup profiles.

### Ecosystem

- cipi/api 1.37.0: `GET /api/apps/{name}/deploy/status[?tail=N]` (`deploy-manage`), refused with a 503 on a server older than Cipi 5.8.4, and the matching MCP tool. cipi/gui 4.1.0: a deploy in progress — Git push, command line, panel or rollback — is shown on the app page with its live log tail, listed in the Deploy tab, and announced when it ends; every audit row opens its own deploy log; the app page links to its server; the healthcheck card says the check also runs after every deploy.
- Tests: `bash tests/verify-5.8.4.sh`.

## [5.8.3] — 2026-10-28

A security report on the panel API, verified and closed. `GET /api/jobs/{id}` was the one route without an ability: any token of the API, however narrow it had been scoped with `cipi api token create --abilities=…`, could read the result and the CLI output of any job by its id. The output of an app create holds the SSH and database passwords, that of a database create or password change the database password. The id is a UUID that only the caller of the job receives, so it had to leak first (a CI log, a shared screen); still, a scoped token must not read what it could not do.

### Security

- **cipi/api 1.36.1 — a job is shown only to a token holding the ability the job was created under**: `apps-create` for `app-create`, `dbs-manage` for `db-password`, `deploy-manage` for a deploy, `apps-artisan` for `app-artisan`, one ability per job type, the same one the route that queued it enforces. Any other token gets the `404 Job not found` of an unknown id, so an id alone tells nothing. Every token that could start a job can still poll it: the GUI's token has every ability, a CI token reads the deploy it started. MCP is unchanged (`mcp-access` is the one ability of every MCP tool). Installed servers get it with the nightly `cipi self-update`, which updates cipi/api from Packagist in the same run, or now with `cipi api update`.
- **Jobs that hold a password are kept one day, not fourteen.** The daily maintenance of the panel API (`cipi-api-maintain`, 04:15) already pruned finished jobs after 14 days; `app-create`, `db-create` and `db-password` jobs are now pruned after 24 hours. The panel, cipi-cli and the SDK read the result as the job completes; nothing reads it later. Migration 5.8.3 rewrites the maintenance script on servers with the API installed and runs it once.

### Ecosystem

- cipi/sdk, cipi-cli and cipi/agent need no code change: `wait()`, `jobs show|wait` and `panel_job` run with the token that queued the job. Their docs now say which ability a job read needs. The GUI's token holds every ability and is not affected.

## [5.8.2] — 2026-10-28

From the field again: a new server, and the end of the install lost the one line that mattered. The credentials were followed by a page of optional commands, the "save these" warning scrolled past, and a fresh server whose root password nobody wrote down is a server to reinstall. Three things change: the installer, the two panel commands, and a way to get the passwords back — with two fixes that were waiting in the same tree, the GUI that never updated and a `cipi yml plan` that never settled.

### Changed — the installer: keys, a plan, the credentials, then the rest

- **More than one SSH key.** After the first key the installer asks `Add another SSH public key? [y/N]` until Enter; each key is checked and shown with its type, fingerprint and comment, a duplicate is refused. `SSH_PUBKEY` (non-interactive) may hold several keys, one per line. Without a terminal and without `SSH_PUBKEY` it stops with the command to use, instead of looping on an empty read.
- **A plan before anything is installed**: the server (IP, hostname, OS), the SSH access it will set up (the keys, root without SSH login, passwords off), the stack, which passwords will be generated, and `Proceed with the installation? [Y/n]`. `n` leaves the machine untouched.
- **The credentials in one layout** at the end: a title, then `User:` and `Password:` under it, the same rows for every block — Root, MariaDB, Valkey, and PostgreSQL, Meilisearch, the backup key when they exist — so one block is one password-manager entry. The warning comes first, and the installer **waits until `y` to "Have you saved these credentials?"** before it prints anything else.
- **The optional layers are questions**, after that confirmation: `Install the panel API now?`, then `Install the web GUI on this server now?`. Each asks its domain and runs the normal command (stdin on the terminal: the script's own stdin is the pipe from wget), and offers another go when it fails. What was a page of five numbered steps is four lines of commands for later.

### Changed — `cipi api <domain>` and `cipi gui <domain>` finish the job

- **DNS check first.** Both resolve the domain before touching anything: it must point at this server — its public address or one of the machine's own; the Cloudflare proxy ranges count, HTTP-01 is answered through the proxy. A name that does not resolve, or points elsewhere, stops the command with the record to create and nothing installed: `DNS: api.example.com points to 1.2.3.4, this server is 5.6.7.8`. `--skip-dns-check` for a NAT or a proxy Cipi cannot see through. `cipi api ssl`, `cipi gui ssl`, `cipi api move` and `cipi gui move` run the same check (`move --no-ssl` does not: a move staged on purpose).
- **The certificate is part of the setup.** `cipi api <domain>` and `cipi gui <domain>` end with the Let's Encrypt certificate, and their summary shows `https://`. When certbot fails anyway (port 80 closed, a rate limit) the summary says so, names `cipi api ssl` / `cipi gui ssl`, and the command exits 1. `--no-ssl` skips it on purpose.
- **A token offered at the end of `cipi api`.** On a terminal, after the summary: `Create an API token now? [Y/n]` runs the token wizard, so a first install ends with what the GUI panel, cipi-cli and CI need. A script (no terminal) and `--no-token` get the command instead.
- `cipi gui` ends with the next step: Connections → Add this server with its API URL and a token when the API is on the same server, `cipi api <domain>` on each server to manage otherwise.
- Help, shell completion (`--no-ssl --no-token --skip-dns-check` after the domain, `--skip-dns-check` after `ssl`), README and docs follow.

### Added — `cipi credentials`: the install summary again, and exported

- `cipi credentials` prints the same card as the installer from the encrypted `/etc/cipi`: root, MariaDB root, PostgreSQL, Valkey, the Meilisearch master key and the backup encryption key, each when it exists. Logged in as `cipi`: `sudo cipi credentials`.
- `cipi credentials export [--output=FILE]` writes them as plain CSV, `title,url,username,password,notes`: the layout 1Password, Bitwarden, Apple Passwords, Chrome, KeePassXC, Proton Pass and the rest import (one entry per row, a confirmation of the column mapping at most). Stdout by default, so nothing is left on the server: from your own machine, `ssh cipi@<ip> sudo cipi credentials export > cipi.csv`. `--output` writes mode 600 and refuses to overwrite an existing file.
- Every show or export is logged (`cipi.log`) and raises the notification trigger `credentials_show` (Security), on by default like `su` and `sudo`.
- `cipi help credentials`, shell completion; `cipi help reset` points to it.

### Added — `cipi gui sso`: single sign-on for the panel (issue #515)

- `cipi gui sso set --issuer=<url> --client-id=<id> --client-secret=<secret> [--label=<text>] [--domains=<a.com,b.com>] [--only] [--scopes=<list>]` turns on OpenID Connect sign-in in the panel: Microsoft Entra ID (`https://login.microsoftonline.com/<tenant>/v2.0`), Google Workspace, Okta, Keycloak, Authentik — anything with a discovery document. It writes the settings to the panel's `.env` (Cipi's file to write), clears the config cache and prints the **Redirect URI** to register at the identity provider (`https://<panel>/auth/sso/callback`). The secret is asked on the terminal when the flag is omitted.
- Who gets in: people who already have an account (seeded, invited) are matched by email and linked to their identity on first sign-in; with `--domains`, a first sign-in from one of those email domains creates an account with role `user` and no access, to be granted in Team. Anyone else is refused. The identity provider is the authority for MFA: the panel's TOTP step is skipped after an SSO sign-in.
- `set` with a new issuer or client id forgets the identities linked so far (an identity's `sub` is per provider, and Entra ID's is per app registration): everyone links again at the next sign-in. Entra ID wants the tenant-specific issuer, `https://login.microsoftonline.com/<tenant-id>/v2.0`, not `common`.
- `cipi gui sso only on` switches password sign-in off for everyone; `cipi gui sso only off` and `cipi gui sso disable` are the break-glass, from the server, so a misconfigured provider never locks the panel. `cipi gui sso status` shows it all with the secret masked. Logged, notification trigger `gui_sso` (Security).
- Needs cipi/gui 4.0.2 (`cipi gui update`); the command warns when the panel is older.

### Fixed — the GUI never updated: every panel stayed on the version of its last `composer.json`

`cipi gui update`, and the nightly `cipi self-update` that calls the same step, download the current cipi/gui into `/opt/cipi/cipi-gui` and run `composer require cipi/gui:@dev` on a path repository copied into `vendor/` (no symlink, because of PHP-FPM's `open_basedir`). Composer identifies a path repository by the sha1 of its `composer.json`, not by its files: with an unchanged `composer.json` (cipi/gui's last changed at 3.0.0) it reports nothing to change and leaves `vendor/cipi/gui` as it was. The synced package moved on every night, the panel did not.

- The update step now runs `composer reinstall cipi/gui` after the require (`composer update cipi/gui` when reinstall is not available), then compares the version in `vendor/cipi/gui` with the synced package and fails loudly when they differ: `vendor/cipi/gui is 3.3.0, the synced package is 4.0.0 — the panel did not update (run: cipi gui update)`. The success line names the version installed. Migrations, config publish and the theme refresh run as before.
- Nothing to do on installed servers: the next `cipi self-update` (03:50 nightly) runs the fixed step and brings every panel to the current cipi/gui.

### Fixed — `cipi yml plan` never reached "in sync" (the panel kept saying "N changes to apply")

Some comparisons of the plan could not converge after an apply, so the cipi.yml tab counted them as pending forever.

- `update backup profile <name>` was emitted for every declared profile that existed, with no comparison at all. The plan now builds the profile the file asks for (the same code apply saves, `_yml_backup_profile_desired`) and lists it only when the stored one differs.
- `update queue worker <queue>` was emitted for every declared queue whose Supervisor program existed. The plan now reads processes, tries and timeout back from the program (as `cipi yml generate` already did) and lists only a worker that differs.
- `healthcheck …`: a `grace` set earlier (`cipi health set --grace`, an older file) was never cleared when the file omits it; apply now unsets it.
- `php.ini <key> = 1 (was On)`: the plan compared the raw value with the one `cipi ini` stores (On/Off for flags). It now compares the normalised value, and a value `cipi ini` would refuse blocks the plan with its name instead of ending the apply halfway (`_ini_set` exits; it runs in a subshell now, so a refused key fails its own action only). `opcache.jit: off` as a YAML boolean arrived as `Off` and was refused: the spelling is normalised.
- `enable search`: an app Meilisearch knew but `apps.json` had lost (restored or rewritten) was "applied" every time without `search: true` coming back; it does now.
- `scheduled commands — N managed cron entries` came back once more after an apply that also changed the PHP version: the lines are now built at apply time with the version in force. `cipi schedule on|off` (and the `schedule:` action) dropped the `# cipi-yml` lines from the crontab; they are kept. A managed cron running `artisan schedule:run` no longer counts as the Laravel scheduler, which made `schedule: false` and `crons` undo each other on every apply.

No migration: nothing to do on installed servers beyond the nightly `cipi self-update`.

### Ecosystem

- cipi/gui 4.0.2: **single sign-on over OpenID Connect** (the `cipi gui sso` settings above: a "Sign in with …" button, PKCE, identity from the provider's userinfo endpoint, accounts matched by email, optional auto-created accounts per domain, SSO-only mode, a read-only card in Settings → Panel). From the same field report as this release: the header's server switcher and the per-server sidebar entries follow the Connections page without a reload (a server added, renamed, removed, enabled or disabled, a test that changed its state), the header follows Settings → Profile, a job closed with "Run in background" keeps being polled and reloads what it changed when it finishes, a failed job reloads the Apps, Databases and Server pages, App → Deploy re-reads its ledger after a deploy started elsewhere on the page, and App → Logs refreshes after a job of the app. `cipi gui update` (or the nightly self-update) brings it in.

---

## [5.8.1] — 2026-10-27

### Fixed — `cipi deploy` exited 1 after a successful deploy (the panel and the API showed it as *Failed*)

Since 5.2.3 the success branch of `cipi deploy` ended on `[[ $post_rc -ne 0 ]] && return "$post_rc"`. With the post-deploy steps fine — or none declared — the test is false, the line's status is 1, and under `set -e` that 1 became the exit code of a command that had just printed `✓ Deploy completed`. In a shell `$?` was 1; cipi/api marks a job by the exit code, so every deploy started from the GUI, the API, the CLI client or an MCP tool ended as **Failed**, with the success line quoted as the error and the Git-key hints under it. The release was live each time and nothing was rolled back. Webhook deploys take another path (`cipi-app-deploy`) and were not affected.

- The branch returns the post-deploy status itself: 0 when the steps passed, the step's code when one failed with `post_on_failure: abort`, 1 with `warn`.
- `cipi deploy` prints the post-deploy steps as they run and ends them with `✓ Post-deploy: <summary>` (`[ERROR] Post-deploy: …` when one failed). The heading, the per-step lines and the verdict were captured into the summary before, so they reached the notification mail and never the terminal or the panel's job output; the mail keeps the one-line summary. `cipi yml post-deploy <app>` shows its steps the same way.
- No migration.

### Ecosystem

- cipi/gui 4.0.1 tells a deploy that published and then failed from a failed one, and names this bug for servers before 5.8.1.

---

## [5.8.0] — 2026-10-27

A request from the field: one repository deployed as a staging app and as a production app, and one `cipi.yml` that could not serve both — its databases must be named after the app, its healthcheck must sit on the app's domain, its aliases differ. The file now follows the app's environment, and it can say which branch to deploy.

### Added — `cipi app create --env`: an environment label per app

- `cipi app create --env=staging` (default `production`; lowercase letters, digits, `-` and `_`, max 32 chars). The wizard asks it after the branch, with the default on Enter. `cipi app edit <app> --env=…` changes it, `cipi app clone <src> --env=staging` names the copy (without the flag the clone keeps the source's label), `cipi app show` prints it, and `apps-public.json` carries `env` for the API, the GUI and the CLI — `production` when an app predates 5.8.0 and has no key.
- The label is written to the app's `shared/.env`: `APP_ENV=<env>` (Laravel's own switch, hard-wired to `production` until now) and `CIPI_ENV=<env>` (Laravel and Node apps). `cipi app edit --env` updates both, `cipi app clone` no longer copies the source's `APP_ENV` over the clone's, and `cipi sync import|update` keeps them in step. Migration 5.8.0 adds `CIPI_ENV` to existing apps that lack it and leaves `APP_ENV` alone.

### Added — `cipi-<env>.yml`: a cipi.yml per environment

- An app with label `<env>` reads `cipi-<env>.yml` (or `.yaml`) before `cipi.yml`, in each place it already looked: the live release, a custom app's `htdocs/`, then `shared/`. A production app reads `cipi-production.yml` then `cipi.yml`, so a repository with the plain file alone behaves as before. One repository can now carry `cipi-staging.yml` next to `cipi.yml` and each app finds its own.
- The server picks the file from the app's label; the file never says which app it is for. A `cipi-<env>.yml` that fails validation is an error naming the file, never a silent fall back on `cipi.yml` — a staging app must not apply production's configuration because of a typo. The post-deploy runner, which runs as the app user and cannot read `apps.json`, takes the label from `CIPI_ENV` in `.env`; `cipi deploy` and the webhook therefore read the same file.
- `cipi yml auto <app> status` prints the environment and the file in use; `cipi yml plan --json` and `cipi yml auto --json` carry `env`. `cipi yml generate` names the file to commit (`cipi-staging.yml` for a staging app; `--save` writes it under that name) and the "No cipi.yml found" message lists the names it looked for.
- nginx denies `/cipi-<anything>.yml|yaml` as it denied `/cipi.yml` (lib/app.sh `_nginx_cipi_yml_deny_block`). Migration 5.8.0 widens the rule on every vhost written before it, keeps the previous vhosts in `/var/lib/cipi/vhost-backup-5.8.0` and puts them back if `nginx -t` refuses.

### Added — `deploy.branch` in cipi.yml

- `deploy: { branch: develop }` declares the git branch the app deploys, with the validation of `cipi app edit --branch` (letters, digits, `.`, `_`, `/` and `-`, max 191 chars, never `..`). `cipi yml plan` shows `deploy branch: main → develop (from the next deploy)`; `cipi yml apply` goes through the same code as `cipi app edit --branch` (`app_branch_set`: `apps.json`, the Deployer recipe, `CIPI_DEPLOY_BRANCH` in `.env` or the Node webhook config), so the two paths cannot drift. Blocked for an app without a repository. `cipi yml generate` emits it, `cipi yml example` documents it.
- The usual pair: `cipi-staging.yml` with `branch: develop`, `cipi.yml` with `branch: main`.

### Ecosystem

- cipi/api, cipi-cli, the PHP SDK, the GUI, cipi/agent and Cipi Studio take and show `env` on app create, edit and show, and `env` on the cipi.yml endpoint, in their own releases.

---

## [5.7.2] — 2026-10-27

Six reports from one user in the field, and the PHP advisory of 2026-10-21 taken one step further.

### Fixed — `deploy.post` steps never ran on webhook deploys (`post-deploy summary:  (exit=127)`)

`cipi-app-post-deploy` runs as the app user and sources `/opt/cipi/lib/yml.sh` for the `deploy.post` steps of `cipi.yml`. `setup.sh` and `cipi self-update` installed every lib `0700 root`, so the source failed, the runner's function did not exist, and each webhook deploy logged `post-deploy summary:  (exit=127)` followed by `post-deploy steps failed — see above` — with no step declared at all. `cipi deploy` from a shell or the panel runs as root and never showed it.

- `yml.sh` is installed `0644` (the lib directories `0755`); migration 5.7.2 fixes servers already installed.
- The runner now checks that it can read and load the lib before it starts, and says what is wrong in the deploy log (`post-deploy runner: cannot read … (mode 700)`), with exit 2 kept apart from a failed step.
- `cipi-app-deploy` reads the post-deploy summary from the lines of this run only: the log is cumulative, and an older deploy's summary could stand in for a missing one.

### Fixed — a refused GitHub deploy key said `HTTP 404: Not Found` and rotated the key

GitHub answers 404, not 403, to a token that may not see or administer a repository. `cipi git refresh` took every refusal for "this key is already used on another repository", generated a new key, failed again with the same 404 and left the app with a key no repository knew. `cipi app create` swallowed the forge's answer altogether (`Could not add deploy key — add it manually`), and the panel showed nothing.

- Every forge call that fails says what the code means and what to do: a GitHub 404 names the repository and the token permissions it needs (fine-grained: *Administration: Read and write* for deploy keys, *Webhooks: Read and write*; classic: `repo` and `admin:repo_hook`); 401 is a revoked token; the same for GitLab (`api` scope, Maintainer) and Bitbucket (*Repositories: Admin*).
- `cipi git refresh` rotates the key only when the token can see the repository; otherwise it stops and says so.
- The `cipi app create` summary carries the forge's answer, and when the deploy key is in but the webhook is not it says that a push will not deploy until `cipi git refresh <app>` (or the hand-added webhook) exists. A forge without HTTP webhooks (Origin, CodeCommit) is told apart from a refused one.

### Fixed — `cipi www force-from-root|force-to-root` refused an app on a wildcard domain

An app whose primary domain is `*.example.com` was refused (`there is no www/apex pair to redirect`), which left a multi-tenant app with no way to send `example.com` to `www.example.com`. The pair of a wildcard primary is the one of its base: the wildcard serves `www.example.com` in nginx, the apex joins as an alias, and the dedicated server block of the redirect host wins over the wildcard. `cipi.yml` (`app.www`) and `cipi yml generate` follow. When the redirect added the pair alias, the certificate hint is printed, as `cipi alias add` does.

### Added — `cipi use <app>`: a default app for the per-app commands

`cipi use shop` makes `shop` the app `cipi deploy`, `cipi app logs|env|artisan|edit`, `cipi yml plan|apply`, `cipi worker list`, `cipi ssl install`, `cipi www …`, `cipi alias …`, `cipi health …` and the other per-app commands act on when no app is given; they print `→ shop (default app — cipi use)` on stderr. `cipi use` shows it, `cipi use --clear` removes it; `CIPI_APP=<app>` does the same for one shell and wins over the file. It is filled in only where the app is a required argument today, so nothing that works changes meaning: `cipi git refresh|check` and `cipi scan` without an app still mean every app, and `cipi app delete|reset-password|reset-db-password|convert|clone` and `cipi db …` still want the name. The panel API runs as `www-data` and never gets a default. Tab-completion and `cipi help use` know it.

### Added — `CIPI_DEPLOY_BRANCH` and `REDIS_*` in a new Laravel app's `.env`

- `CIPI_DEPLOY_BRANCH=<branch>` is written at `cipi app create` and kept in step by `cipi app edit --branch` and `cipi sync import`: the webhook of cipi/agent deploys a push to that branch and answers "skipped" to every other one (before, every push deployed). Migration 5.7.2 adds the key to existing Laravel apps that lack it; a value already there is left alone.
- `REDIS_HOST`, `REDIS_PASSWORD` and `REDIS_PORT` point at the local Valkey with the password Cipi set at install. Cache, session and queue stay on the database; switching one is now a one-line change instead of a hunt for the password. `cipi reset valkey-password` updates `REDIS_PASSWORD` in every app `.env` that still holds the previous password and names the apps it touched; a value set by hand is left alone.

### Added — `cipi backup profile remove <name> --purge`

Removing a profile kept its archives until a remaining profile's age-based retention took them, and with none they stayed for good. `--purge` deletes every run of the profile now, on every destination; on a terminal the question is asked after the removal is confirmed. `--purge` also works for a profile that is already gone, to clear what it left behind. Without it the message says how many runs stay and how to delete them.

### Added — `cipi deploy <app> --releases` shows how long each deploy took

A `TOOK` column, read from the end banner of the deploy log (`duration=54s`), next to the date and the commit of each release.

### Security — PHP advisory mitigations in `fpm/conf.d/99-cipi.ini` and the Node webhook pool

- `session.upload_progress.enabled = 0` and `fatal_error_backtraces = 0` (the 2026-10-21 advisory, CVE-2026-109618/109619) are written to each PHP version's `/etc/php/X.Y/fpm/conf.d/99-cipi.ini` by `cipi php install`, `setup.sh` and migration 5.7.2, so the stock `www` pool and any pool written by hand carry them too. Every Cipi pool had them as `php_admin_flag` since 5.6.3; the Octane ini is unchanged and now shares the generator.
- The Node webhook pool sets `file_uploads = off`: the receiver reads a JSON body and nothing else, so the multipart request path of CVE-2026-109618 is closed there.
- `cipi ini keys` lists the two hardening keys under *Not settable here* with the reason, instead of "Unknown or non-settable key".

### Migration

`lib/migrations/5.7.2.sh`: makes `yml.sh` readable by app users; appends the missing hardening lines to each installed version's `fpm/conf.d/99-cipi.ini` (matched by key, a hand-set value is kept); renders the Node webhook pools again with a backup in `/var/lib/cipi/fpm-pool-backup-5.7.2/` and a rollback on a refused `php-fpm -t`; adds `CIPI_DEPLOY_BRANCH` where it is missing; restarts the PHP-FPM versions whose ini or pools changed. `tests/verify-5.7.2.sh` runs the migration with stubs, the post-deploy runner against an unreadable and a readable lib, and the new helpers.

---

## [5.7.1] — 2026-10-23

### Security — PHP hardening for Octane apps (CVE-2026-115560)

On 2026-10-23 the PHP project disclosed CVE-2026-115560, a remote code execution in session handling with no fixed release yet. Its mitigation is the one the 2026-10-21 advisory already gave for CVE-2026-109619: `session.upload_progress.enabled=0`. Since 5.6.3 every PHP-FPM pool Cipi writes carries it, so PHP-FPM apps, Node webhooks and the panel API and GUI need nothing new. Octane apps did not have it: FrankenPHP runs the PHP inside its own binary and never reads an FPM pool.

- **Every Octane app now loads `/etc/php/cipi-octane.d/99-cipi-hardening.ini`** with `session.upload_progress.enabled = 0` and `fatal_error_backtraces = 0`, the same settings as `fpm_pool_hardening`. The `<app>-octane` Supervisor program sets `PHP_INI_SCAN_DIR=":/etc/php/cipi-octane.d"`. The leading `:` keeps the compiled-in scan directory, so the `php` that starts Octane still loads its `conf.d`, and Octane passes the variable on to the FrankenPHP binary. The settings load at startup, so `ini_set()` cannot turn upload progress back on. `fatal_error_backtraces` exists only from PHP 8.5; earlier PHP ignores the key.
- The exploit needs an app that sets `session.serialize_handler` to `php_binary` or `php_serialize` and switches it to `php` with `ini_set()` before `session_start()`. Laravel does not use PHP's native sessions, so Laravel apps on Octane were not exposed to this CVE. The setting still closes the upload-progress path of CVE-2026-109619 on a FrankenPHP binary that is not yet on a patched PHP.

### Migration

`lib/migrations/5.7.1.sh`, on servers with Octane apps:

1. Writes `/etc/php/cipi-octane.d/99-cipi-hardening.ini`.
2. Renders each Octane app's Supervisor program again. The previous file is kept in `/var/lib/cipi/supervisor-backup-5.7.1/` and put back if `supervisorctl reread` refuses the new one.
3. Restarts each rewritten Octane program, since the settings load at startup. Expect a few seconds without answers on those apps. A program that was stopped stays stopped.

---

## [5.7.0] — 2026-10-23

### Added — move the panel API and GUI to another domain, remove the API

The API and the GUI each run on a domain of their own, with their own Nginx vhost and certificate. Until now, changing that domain meant running `cipi api <domain>` again. That rewrote the vhost without the lines certbot had added, so the API went back to plain HTTP. The certificate for the old domain stayed on the server and certbot kept trying to renew it.

- **`cipi api move <domain>`** moves the API, MCP server and Swagger docs to a new domain. It keeps the same Laravel app, tokens, job history and IP whitelist. It rewrites the vhost, updates `api.json` and `APP_URL`, restarts the queue worker, deletes the old domain's certificate (including any `-0001` copies), then issues one for the new domain. `--no-ssl` skips the new certificate. If certbot fails, the move still completes and the output says what to fix before running `cipi api ssl`. If the new vhost fails `nginx -t`, the old vhost goes back and nothing else changes. Every client of the server needs the new URL: GUI connections, cipi-cli, the PHP SDK and MCP clients.
- **`cipi gui move <domain>`** does the same for the control panel. Admins, 2FA and saved connections stay; admins sign in again, since sessions belong to the old domain. A GUI routed through Cloudflare Zero Trust is refused until `cipi zt hostname remove --gui`, because the tunnel route, DNS record and Access app belong to the old hostname. Afterwards run `cipi zt hostname add --gui`.
- **`cipi api remove [--force]`** (alias `uninstall`) removes everything `cipi api <domain>` set up:
  - the `cipi-queue` service
  - the Nginx vhost and PHP-FPM pool
  - the scheduler, maintenance and nightly update crons and their logrotate files
  - the certificate
  - `/opt/cipi/api`, `/opt/cipi/api.old` and the upgrade backups, which hold the panel `.env` and the token database
  - `api.json`, the IP whitelist and the API logs

  Apps, databases and the GUI are not touched. `/etc/sudoers.d/cipi-api` stays: every Cipi install has it, and migrations keep it current.
- **`cipi gui remove`** also refuses a GUI that is still on the tunnel, and keeps a certificate that an app still uses.

### Changed — a panel's domain is its own

Customers put the API or the GUI on the domain of an app. Nginx then has two vhosts with the same `server_name`, serves only one of them, and the certificates overwrite each other's lines. Cipi now refuses that in both directions:

- `cipi api <domain>`, `cipi gui <domain>` and both `move` commands refuse a domain or alias that belongs to an app, and refuse the other panel's domain. The error suggests a subdomain, for example `api.example.com`.
- `cipi app create`, `cipi app edit --domain`, `cipi alias add`, `cipi app clone`, `cipi sync import` and cipi.yml aliases refuse the API or GUI domain.
- `cipi api <domain>` and `cipi gui <domain>` on a panel that is already configured at another domain stop, and point to `move` (or to `remove` and a fresh setup). This replaces the silent change of domain.
- `cipi api status` and `cipi gui status` warn when an existing panel shares its domain with an app or with the other panel, and suggest `move`.

### Fixed

- **`cipi gui ssl` reported success when certbot failed.** It now exits 1 with the same message as `cipi api ssl`, and names the certificate after the domain (`--cert-name`). The interactive certbot fallback is only offered when a terminal is attached.
- **`cipi gui remove` deleted the certificate of its domain even when an app used the same domain.** It now keeps it, and says so.

No migration: nothing on installed servers changes until one of these commands runs.

---

## [5.6.4] — 2026-10-22

### Fixed — `cipi yml auto <app> on` did nothing on Git-webhook deploys

A push deployed the code and never applied cipi.yml, even with auto-apply on. The webhook path runs as the app user (`cipi-app-deploy`, from the app's crontab), and it decided whether to apply by checking `test -f /etc/sudoers.d/cipi-<app>-yml`. On Debian and Ubuntu `/etc/sudoers.d` is `0750 root:root`, so the app user cannot see into it: the test was always false and the step was skipped without a word in the deploy log. `cipi deploy` (from a shell or the panel) runs as root and was not affected.

- **The wrapper asks sudo instead** (`sudo -n -l` for the exact command line the rule allows, the way the Node recipe already checks for `cipi yml node-sync`), and runs the apply with `sudo -n`, so a missing rule can never wait for a password.
- **`cipi app delete` removes `/etc/sudoers.d/cipi-<app>-yml` too.** It was left behind, and a new app created later with the same name inherited the rule.
- **`cipi sync import` and `cipi sync update` write the rule** when the imported app has auto-apply on. `apps.json` carried `yml_auto` across, `/etc/sudoers.d` did not, so the imported app applied cipi.yml on `cipi deploy` and skipped it on a push.
- **`cipi yml auto <app> status` says when the rule is missing** while auto-apply is on. `cipi yml auto <app> on` writes it again.

### Added — cipi.yml for the panel API and its clients

- **`cipi yml plan <app> --json`** prints the whole picture as one object: `file` (null when the release has none), `auto`, `valid` with `errors` and `warnings`, `changes` (`kind`, `summary`), `blockers`, `notes`, `in_sync`. A missing, invalid or blocked file is still a plan and exits 0; only an unknown app is an error.
- **`cipi yml auto <app> status --json`** prints `{app, auto, sudoers, file}`. `cipi yml auto <app> --json` is the same.
- **The panel API may run `cipi yml plan *`, `cipi yml apply *` and `cipi yml auto *`** ([cipi/api](https://github.com/cipi-sh/api) 1.35.0: `GET /api/apps/{name}/yml`, `POST …/yml/apply`, `POST …/yml/auto/enable|disable`, abilities `yml-view` and `yml-manage`). The GUI, `cipi-cli yml`, the PHP SDK and Cipi Studio use them. The sudoers wildcard cannot keep `--file=` out, and a parser pointed at another file would quote its lines back in the errors, so **`--file` is refused when the caller is www-data**.

### Migration

`lib/migrations/5.6.4.sh`:

1. Installs the fixed `/usr/local/bin/cipi-app-deploy`.
2. Rewrites `/etc/sudoers.d/cipi-api` with the three `yml` entries.
3. Brings every app's `/etc/sudoers.d/cipi-<app>-yml` in line with `yml_auto` in `apps.json`: written where auto-apply is on, removed where it is off.
4. Removes the rules of apps that no longer exist.

Steps 3 and 4 run only when `apps.json` could be read, so an unreadable vault never looks like a server without apps.

---

## [5.6.3] — 2026-10-21

### Security — PHP security release of 2026-10-21 (CVE-2026-109618, CVE-2026-109619)

PHP 8.5.12, 8.4.27, 8.3.36 and 8.2.35 fix two unauthenticated remote code execution bugs (CVSS v4.0 9.2) in every SAPI that serves web requests: PHP-FPM, mod_php, php-cgi, FrankenPHP and LiteSpeed. One corrupts request data when PHP runs out of memory (CVE-2026-109618). In the other, request state survives after its memory is freed and the next request on the same worker uses it (CVE-2026-109619). The PHP project says only the update is a complete fix. This release brings it in and narrows the attack paths until it is in.

- **The patch goes in on self-update.** The migration runs `cipi php upgrade` straight away. If the repository already has the patched packages, they are installed and every PHP-FPM service is restarted: a stale worker is exactly what CVE-2026-109619 exploits, so a restart is required, not a reload.
- **PHP packages come from packages.sury.org first.** Same maintainer and packages as the Launchpad `ppa:ondrej/php`, but sury.org publishes first: on release day it had the fixed builds for Ubuntu 24.04 while the PPA was still building them. New installs and `cipi php install` now pick sury.org → PPA → Ubuntu archive (it was PPA → sury.org → archive). The migration moves existing servers off the PPA when sury.org has their suite. The PPA is removed only after the sury.org keyring and source are in place, so a failed download leaves the server as it was. Packages already installed from the PPA stay until a newer version replaces them.
- **`cipi php upgrade` runs every night**, not every Sunday. The weekly schedule could leave a server six days behind a release like this one. With nothing to upgrade, a run costs one `apt-get update` and restarts nothing. A schedule changed by hand is left as it is.
- **`cipi php upgrade` reports the patch level** of each installed version against the oldest patched release: *patched*, *VULNERABLE* (the fix exists but this server does not have it, typically because the repository has not published it yet), *distro* (a build from the Ubuntu archive, which backports fixes without changing the version number, so check `apt changelog php8.3-fpm`), or *END OF LIFE*. A vulnerable version makes the run exit 1, so the nightly cron mails a failure until the fix is in. `cipi php list` shows the same status, and `--json` adds `patch`, `security` and `security_floor`.
- **Octane apps are checked too.** FrankenPHP runs on the PHP built into the binary that Octane downloads into the release, and apt never updates that binary. `cipi php upgrade` runs `current/frankenphp -v` as the app user and flags any build on PHP older than the fixed release. To fix one, run `php artisan octane:install --server=frankenphp` as the app user in `current/`, then `supervisorctl restart <app>-octane`.
- **Every FPM pool Cipi writes turns off the two confirmed paths** of CVE-2026-109619: `php_admin_flag[session.upload_progress.enabled] = off`, and `php_admin_flag[fatal_error_backtraces] = off` on PHP 8.5 (the setting does not exist earlier). This covers app pools, Node webhook pools and the panel API and GUI pools. They are set as `php_admin_flag` so that they apply before the request is parsed, and `.user.ini` or `ini_set()` cannot turn them back on.

PHP 8.1 and older no longer get fixes from the PHP project: `cipi php list` marks them END OF LIFE. Cipi installs 8.3 and later only, so this affects servers set up before 4.5.4. PHP 8.2 gets its last fixes on 31 December 2026, and the report says so.

Not changed on purpose: the advisory also suggests `memory_limit=-1` and a lower `post_max_size` for servers that cannot update. Neither is a default, since an unlimited memory limit trades this bug for runaway workers and a 32M body limit would break uploads that work today. Both stay available through `cipi ini set`, server-wide or per app (`--app=`): `upload_max_filesize=30M` and then `post_max_size=32M`, or `memory_limit=-1` together with a memory cap on the `phpX.Y-fpm` service (systemd `MemoryMax=`). Do not use `RLIMIT_AS` or `RLIMIT_DATA` for this: the advisory warns that they can trigger the allocation failure behind the bug.

### Migration

`lib/migrations/5.6.3.sh`:

1. Renders the app and Node webhook pools again and adds the two lines to the `cipi-api` and `cipi-gui` pools. Their generators would also empty the panel logs, so those two pools are edited in place. The previous pools are kept in `/var/lib/cipi/fpm-pool-backup-5.6.3/`, and a version whose new pools fail `php-fpm -t` gets the old ones back.
2. Moves the `cipi php upgrade` cron from weekly to daily.
3. Moves the PHP package source from the ondrej PPA to packages.sury.org when sury.org has the server's suite (24.04 and 26.04 do).
4. Runs `cipi php upgrade` and prints the patch level of each version and of each Octane app.
5. Restarts every PHP-FPM service whose configuration passes `php-fpm -t`.

If the repository did not have the packages yet when the migration ran, the nightly 03:30 run installs them. To install them sooner, run `cipi php upgrade`.

---

## [5.6.2] — 2026-10-20

### Fixed — a failed PostgreSQL restore no longer empties the database

`cipi db restore <name> <file>` on a PostgreSQL database dropped the `public` schema before the dump was read. A truncated `.gz`, an empty file or a statement failing halfway through left the database empty or half imported, even when the command reported failure. The same path runs the database copy of `cipi app clone` and the database step of `cipi sync import`.

- **Wipe and import run in one transaction.** `COMMIT` is sent only after the whole dump has been read. Any failure closes the session without it, so the wipe rolls back and the database stays as it was.
- **An empty dump is refused.** A backup taken while `pg_dump` failed is a valid archive of nothing — `db_dump_database` sends `pg_dump`'s errors to `/dev/null` and gzips what is left — and the file's size cannot tell it from a real dump. The check runs on the stream in the preamble filter's own pass; without one non-blank line the filter exits 1, so no `COMMIT` follows and the wipe rolls back. The file is read once either way.
- **The new schema goes to the database owner**, not a role named after the database, which does not exist for databases created with `--user`.
- **`Restore failed` names gunzip on BSD too**, where gzip reports as `gunzip:` rather than `gzip:`.

Version 5.6.0 already stopped at the first failed statement, showed the error, rejected dumps that do not uncompress, and dropped preamble `SET` lines this server does not have. This release closes the gap where a failed restore could still leave PostgreSQL empty behind a failure message.

### Migration

None. The self-update copies `lib/db.sh`.

---

## [5.6.1] — 2026-10-15

### Fixed — `deploy.post` artisan steps never ran

Every `artisan` step declared under `deploy.post` failed with `bash: /usr/bin/php8.5artisan: No such file or directory`: the runner glued the PHP binary and `artisan` together without a space. `npm`, `composer`, `php` and the other runners were not affected. The steps now run as `/usr/bin/phpX.Y artisan …` from the live release, on `cipi deploy`, on the Git webhook and with `cipi yml post-deploy`.

### Fixed — a failed post-deploy step reports its exit code, and `abort` aborts

The log always said `post-deploy FAILED (0)`, because the exit code was read after the `!` that negated it. With `post_on_failure: abort` that 0 was also what the step returned, so the deploy did not fail. The log and the alert now carry the step's real exit code, and `abort` makes `cipi deploy` fail with it.

### Migration

None. The self-update copies `lib/yml.sh`; the next deploy runs the steps.

---

## [5.6.0] — 2026-10-15

Four suggestions from users, in one release: a guided `cipi app create`, the asset build asked at creation, the deploy key tested on the spot, and backup profiles that ship to several buckets. Two fixes come with them: a PostgreSQL restore that failed is no longer reported as done, and a `cipi.yml` cron expression with a newline no longer passes validation. Bitbucket Cloud and Azure DevOps, also suggested, have been supported since 5.2.3 (`cipi git bitbucket-token`, `cipi git azure-token`); the app create summary now names them in its deploy-key hints.

### Added — `cipi app create` starts with menus: type, runtime, database engine

The wizard asked for a username before anything else, and the choice that shapes everything — Laravel, custom, Node — existed only as flags (`--custom`, `--node=`, `--octane`). On a terminal, with no type flag, `cipi app create` now opens with numbered menus, the default pre-selected: Enter takes it, a number or the value picks another.

- **App type**: `laravel` (default), `custom`, or a Node app — `spa`, `static`, `ssr`.
- **Runtime** (Laravel): `fpm` (default) or `octane`, Laravel Octane (FrankenPHP), the same as `--octane`.
- **Database engine** (Laravel): MariaDB or PostgreSQL, the server default marked, asked right after the runtime and only when both engines are installed.
- A Node app asks for its framework (`vite` for spa; `next`, `nuxt`, `sveltekit`, `astro`, `remix` for ssr, or none with a start command of your own) or, for a static site, the build command and the output directory.

Then the details as before: username, domain, repository, branch, PHP version. Any type flag skips the menus. Without a terminal (the panel API, a script) every default applies and nothing is printed, so the non-interactive form is unchanged.

`cipi db create` asks the engine the same way: without `--engine`, on a terminal and with both engines installed, a menu — MariaDB or PostgreSQL, the server default (`cipi db default`) pre-selected — comes before the database name. A script or a server with one engine gets the default, as before.

### Added — the asset build is asked at creation

The build most Laravel apps need (`npm ci && npm run build`) could only be set afterwards, with `cipi app edit --node-build` or `deploy.node_build` in `cipi.yml`, so the first deploy shipped without compiled assets. The wizard now asks for it after the PHP version — **Build command**, empty for none — and `--node-build=CMD` sets it without a prompt. It is stored as `node_build`, written to `.deployer/node-build.sh`, run by the recipe inside every deploy after `composer install` and before the release goes live, and shown in the summary (`Build:`). The allowlist of the edit command applies: npm, npx, yarn, pnpm, bun or node, no shell syntax. Node apps keep `--build=`; custom apps have no build step. `deploy.post` in `cipi.yml` remains the place for steps that run after the release is live.

### Added — the deploy key is tested against the repository on the spot

`cipi app create` printed the deploy key, and the first deploy failed later with `Could not read from remote repository` when the key had never been added, the forge token had expired, or the branch did not exist. The key is now tested as soon as it is in place — `git ls-remote` as the app user, with the identity Deployer uses, the branch included — and the summary carries the result: `Repository reachable ✓ (branch main)`, `reachable, but it has no branch 'x'`, or `not readable with the deploy key`.

- **On a terminal**, when the repository is on a forge Cipi knows (GitHub, GitLab, Bitbucket Cloud, Azure DevOps, Cursor Origin) and the key cannot read it, Cipi says why and offers to **save the forge token** (none saved yet) or **replace it** (expired, or not covering this repository). With the token it registers the deploy key and the webhook, as `cipi git` does, and checks again. Declining, or a script, gets the exact commands: `cipi git <forge>-token <token> && cipi git refresh <app>`; for an unknown host, where to add the key and `cipi deploy <app> --trust-host=`.
- **`cipi app edit --repository=` and `--branch=`** run the same check, with the same offer.
- **`cipi git check [app]`** repeats it at any time: one app (with the token offer), or every app with a repository, exit 1 when one cannot be read. In `cipi help git` and tab-completion.
- A key the forge has just accepted can take a moment to serve: a refused read is tried once more after three seconds. A read that does not answer within 60 seconds counts as refused. The check never blocks the creation.
- The deploy-key hint in the summary names the place for the forge of the repository — GitHub, GitLab, Bitbucket, Azure DevOps, Origin, CodeCommit — instead of GitHub and GitLab only.

The app-created mail reports `Repository access` and `Build`.

### Added — backup profiles ship to several S3 buckets

`cipi backup configure` held one bucket, shared by every profile, so a copy on another provider, in another region or in a customer's own account was not possible. A server now has **named destinations** next to the default bucket.

- **`cipi backup destination add <name> --bucket= --key= --secret= [--region=] [--endpoint=]`**: another bucket with its own credentials, on any S3-compatible endpoint as for the default. Without flags the values are asked. The bucket is listed with those credentials **before** anything is saved: a destination that cannot be reached would fail every run of every profile naming it. Also `edit`, `show`, `test` (reach every bucket, or one), `list` (local, `s3` and every named one, with the profiles using each) and `remove` (refused while a profile still names it; the archives in the bucket stay, and Cipi stops pruning them).
- **A profile names any of them**: `--dest=local,s3,offsite`; in `cipi.yml`, `destinations: [s3, offsite]`. A name not configured on the server is refused by `profile add/edit` and blocks the `cipi.yml` plan, with the command to run.
- **Every run uploads the same layout** (`cipi/<profile>/<timestamp>/`) to each bucket, with the credentials of each. Retention deletes a run from every destination that holds it; `cipi backup list` shows on which it is; `verify` and `fetch` take the first destination that has the run when there is no local copy; orphaned archives are pruned on every bucket. A failed upload names the destination (`dest:offsite`).
- **The existing bucket is the default.** It stays in the top-level keys of `backup.json`, is `s3` in every profile, and keeps the credentials `cipi backup configure` wrote to `/root/.aws`. Named destinations live under `s3_destinations` and hand their keys to the AWS CLI per call. A server configured before this release carries on unchanged; `cipi backup configure` keeps the named destinations it finds, and `cipi backup status` lists them. `cipi help backup` and tab-completion know the commands.

### Fixed — a PostgreSQL restore that failed was reported as done

`cipi db restore <name> <file>` on a PostgreSQL database wipes the `public` schema and then feeds the dump to `psql` with `ON_ERROR_STOP=0`: psql went on after every failed statement and exited 0, so an incompatible or corrupted dump left the database **empty** while the command printed `'<name>' restored`. The same path runs the database copy of `cipi app clone` and the database step of `cipi sync import`.

- psql now runs with `ON_ERROR_STOP=1`: it stops at the first failed statement and exits non-zero, which the callers already handle (`Restore failed` and exit 1; a warning in clone and sync). The MariaDB client has always stopped at the first error, so both engines now behave the same.
- **The error is shown.** The client's output went to `/dev/null`, so `Restore failed` said nothing about what to fix. The first error line the client printed is now reported — `PostgreSQL restore: ERROR: relation "users" already exists` — for MariaDB as well.
- **A dump that does not uncompress fails too.** The restore pipelines run with their own `pipefail`: a truncated or corrupted `.gz` no longer counts as restored because `psql` was fed an empty input.
- **Dumps taken on a newer PostgreSQL keep restoring.** Stopping at the first error would have broken them: `pg_dump` 17 writes `SET transaction_timeout = 0;` in its preamble, which PostgreSQL 16 (Ubuntu 24.04) rejects as an unknown parameter, so the restore would have stopped on its first line with the database empty. That is a `cipi sync` from a 26.04 server to a 24.04 one, or a `cipi db restore` of a file made elsewhere. The preamble's `SET` lines whose parameter this server does not have (`pg_settings`) are dropped before `psql` sees them. Nothing past the preamble is touched: a `COPY` data line that happens to start with `SET` goes through as is. When the settings cannot be read, the dump passes unchanged.

A dump made with `pg_dump --clean` but without `--if-exists` now fails at its first `DROP TABLE` — Cipi has already emptied the schema — and says so, where before those errors were skipped and the import went on. Cipi's own dumps (`pg_dump --no-owner --no-acl`) are not affected.

### Fixed — a cron expression with a newline passed `cipi.yml` validation

The `cron:` validator of `cipi.yml` (`crons:` and `backup.profiles[].cron`) allowed `\s`, which matches a newline and a tab, not just a space. A double-quoted YAML value such as `cron: "0 0 1 1\n*"` passed — five fields, every character allowed — and was written as is into the app user's crontab, where the newline split the line in two and `crontab` refused the **whole** managed block: every scheduled command of the app stopped, from a file that comes from the repository. The same character class guarded `cipi backup profile add --cron=`.

- Only a plain space between fields, everywhere: a newline, a tab and trailing garbage (`0 0 * * *;id`) are refused with the usual `expected five cron fields` error. Valid five-field expressions (`*/5 0-6,18 * * 1-5`) are unchanged.
- The expression is stored with one space between fields, so the crontab line Cipi writes always reads the same as the one it compares against on the next `cipi yml plan`.

No migration: `crontab` itself refused a block containing such a line, so no installed app carries one.

### Fixed — lists lose their columns with long names

Every list printed its columns at fixed widths, sized for short values. An app name can be 32 characters, a backup profile `cernuscoinsieme-db-quarterly`, a database 64, a domain or a proxy upstream much more: the value pushed the rest of its row out of line, and the table no longer read as one.

- **Columns now take the width of their longest value**, the header included, with two spaces between them. Colour codes do not count towards the width, numeric columns of `cipi disk` stay right-aligned, and nothing is padded after the last column.
- **The lists that changed**: `cipi app list`, `cipi backup status`, `cipi backup profile list`, `cipi backup destination list`, `cipi db list`, `cipi disk` and `cipi disk db`, `cipi deploy <app> --audit`, `cipi git status`, `cipi ini list` and `cipi ini keys`, `cipi redirect list` and `cipi proxy list`, `cipi search list`, `cipi ssh apps`, `cipi ssl status` and `cipi ssl dns list`, `cipi sync list`, `cipi worker list`, `cipi health list`, `cipi notifications channel list`, and the account and config-file tables of the `cipi compliance report` evidence.
- One shared helper does it (`lib/table.sh`, loaded by `common.sh`). The lists built on fixed catalogs — notification triggers, monitor checks, compliance controls, token abilities, services — already fit their columns and are unchanged.
- The panel API parses `cipi db list` with any amount of whitespace between columns, so it reads the new layout as before. `cipi app list` loses the line of `━` under its header; the header is bold.

No migration for this release: a server configured before it keeps working as it is.

---

## [5.5.2] — 2026-10-09

### Changed — `cipi disk` is available to the panel API

`cipi disk` and `cipi disk db` were the only host insights still CLI-only. The panel API ([cipi/api](https://github.com/cipi-sh/api) ≥ 1.33.0) now serves the same figures, read-only: `GET /api/disk` (the filesystem `/home` is on, then every app with files, database, total, percentage of the disk, soft limit and whether it is over) and `GET /api/disk/dbs` (every database of every installed engine, in MB), both behind the new token ability `disk-view`. `cipi-cli disk` and the Server → Disk tab of the GUI read them. Sizes are still measured when asked, so a request on a server with large apps takes a few seconds.

Nothing changes in what `cipi disk` prints or measures. Setting a limit (`cipi app limits <app> --disk=`) was already in the API (1.32.0).

### Fixed — `cipi.yml` uses the same deploy names as `cipi app deploy-config`

The file said `deploy.snapshot`. The command prints and stores `predeploy_snapshot`. The file now uses `predeploy_snapshot`. A file that still says `snapshot` is read as before.

`deploy.node_build` is the asset build (`cipi app deploy-config --node-build`, for example `npm ci && npm run build`). It runs inside the deploy, after `composer install` and before the release goes live. `deploy.post` runs only after the release is already serving, so it was the wrong place for that build, and `cipi yml generate` was suggesting `npm run build` there. Generate and `cipi yml example` now show `node_build`. `false` removes the build. A Node app declares its build as `node.build`; putting `deploy.node_build` on a Node app blocks the plan.

### Fixed — `cipi yml apply` removes backup profiles the file dropped

Renaming a profile in `cipi.yml` created the new one and left the old one on the schedule. Profiles this file created (recorded on the app as `backup_profiles`) that the file no longer names are removed. The archives stay; `cipi backup prune` ages them out with whatever retention the remaining profiles still have. A profile created with `cipi backup profile add` is left alone unless the file names it.

A new profile that does not say `destinations` is written where a copy can actually land: S3 when a bucket is configured, this server otherwise. Before, the stored default was S3, and every run failed when there was no bucket.

Declaring `backup:` when backup was never configured, with every profile staying on this server, initialises a local-only configuration (an empty bucket, no server-wide `default` profile) instead of refusing the plan.

### Changed — `cipi yml generate` can write the file

The command still prints the file, which is why `cipi yml generate myapp` left nothing on disk. `--save` writes `/home/<app>/cipi.yml` (outside the release, so the next deploy does not wipe it). `--save=PATH` writes that path. `--force` overwrites. Apply keeps reading the copy committed in the repository.

### Fixed — a failed automatic `cipi.yml` apply shows up on the deploy

With `cipi yml auto <app> on`, apply runs after a successful deploy. A blocked or invalid file was written to the deploy log, and a separate alert was sent only when notifications were configured, so the "deploy succeeded" mail said nothing about it. That mail (from `cipi deploy` and from the Git webhook) now carries one line: applied, already matches, no file in the release, or not applied and why. The deploy itself still succeeds — the code is live either way.

### Migration

`lib/migrations/5.5.2.sh` regenerates `/etc/sudoers.d/cipi-api` so `www-data` may run `cipi disk` and `cipi disk *` (`--json`, `db --json`). Nothing else changes on the server; nothing is deployed.

---

## [5.5.1] — 2026-10-07

### Fixed — wildcard certificates were issued but never installed

`cipi ssl install <app> --dns=cloudflare --wildcard` obtained the certificate and then stopped with:

```
Could not install certificate
Missing command line flag or config entry for this setting:
Which server blocks would you like to modify?
[ERROR] Certificate issued but nginx install failed.
```

Cipi put a certificate into a vhost with `certbot install --nginx`. For a wildcard name (`*.example.com`) certbot's nginx installer **always** asks which server blocks to modify, whatever the vhost contains, and `--non-interactive` cannot answer that question. So every certificate holding a wildcard — `--wildcard`, or an app with a `*.example.com` alias — failed at that step. The same call ran after every vhost regeneration (alias, www, basic auth, redirects, proxies, Octane, Reverb, suspend, PHP), silently (`|| true`), so the app could end up with a valid certificate on disk and no HTTPS at all. Behind the Cloudflare proxy that is the classic trap: HTTPS works only with SSL mode **Flexible**, and Flexible loops forever as soon as an HTTPS redirect is in place.

**Cipi now writes the HTTPS server block itself.** certbot only issues and renews certificates (`certbot certonly`); it never edits an app vhost again.

- `_create_nginx_vhost` writes the plain-HTTP vhost as before, then — when the app has a certificate — its HTTPS form: every server block moves to `:443` with `ssl_certificate`, `ssl_certificate_key` and `include /etc/nginx/snippets/cipi-ssl.conf` (TLS 1.2/1.3, Mozilla intermediate ciphers), and one `:80` block answers **every** name of the vhost with `301 https://$host$request_uri`. ACME challenges stay reachable on `:80`. Every regeneration therefore keeps HTTPS by itself, and nothing is put back afterwards.
- Tenants of a wildcard app are redirected to HTTPS too. certbot's own redirect block listed only the names it had been given and answered `404` to every other host, i.e. every tenant.
- Apps published through the Cloudflare tunnel keep serving on `:80` (cloudflared talks HTTP to the origin): their blocks listen on `:80` and `:443`, without a redirect, as before. `force_https: "false"` does the same.
- **Cloudflare Origin CA** (`cipi zt origin-cert`) goes through the same path, so it works on an app that never had HTTPS. Before, the certificate was only saved, with a note to re-run the command after a `:443` block appeared — and the next vhost regeneration dropped it again.
- `cipi ssl force <app>` sets `force_https` and rewrites the vhost; no certbot call.

### Fixed — certificate names Let's Encrypt refused

- An app with a wildcard alias issued over DNS-01 sent the wildcard **and** the names it covers (`*.example.com` + `www.example.com`), which Let's Encrypt rejects as redundant. The list is now built once (`cert_names_for`): primary and aliases, plus `*.<apex>` for `--wildcard`, without the names a wildcard of the list already covers. A name two labels down (`a.b.example.com`) stays, since a certificate wildcard covers one label only.
- The names reach certbot as an array: `*.example.com` can no longer meet pathname expansion.
- More than 100 names is refused before certbot runs, with a hint that one wildcard alias covers every subdomain.
- `--wildcard` is remembered (`ssl_wildcard` on the app), so a later reissue keeps `*.<apex>`; `--no-wildcard` drops it. `--wildcard` without DNS-01 is now an error instead of being ignored.
- When the certificate covers `*.<apex>` but the app does not serve it, the install says so: the certificate does not route anything, `cipi alias add <app> '*.<apex>'` does.

### Fixed — a DNS-01 certificate is reissued over DNS-01

`cipi ssl install <app>` without `--dns` always used HTTP-01. On an app whose certificate was issued over DNS-01 — `cipi alias add` itself suggested running it — certbot replaced the names of the lineage, dropping the wildcard, and its renewals moved from the Cloudflare token to port 80. It now reissues over DNS-01 with the account the certificate was issued with, and says so. `--http` goes back to HTTP-01 on purpose. The panel API and MCP, which call `cipi ssl install <app>` without flags, get the same behaviour.

### Fixed — renewals

- **nginx reloads after every renewal.** certbot.timer (twice a day, from the Ubuntu package) renews certificates without the post-hook of Cipi's weekly cron, so after it renewed a DNS-01 certificate nothing reloaded nginx, which kept serving the old certificate until it expired. A deploy hook, `/etc/letsencrypt/renewal-hooks/deploy/cipi-reload-nginx` (`nginx -t -q && systemctl reload nginx`), now runs after every renewed certificate, however the renewal was started.
- **The weekly cron no longer passes `--nginx`** to `certbot renew`. On the command line it overrides what each certificate was issued with, so a DNS-01 wildcard would have been renewed over HTTP-01 — which cannot validate a wildcard — whenever the cron, and not the timer, got to it first. Every certificate now renews the way it was issued.

### Added — `cipi ssl status` per app

After the certificate list, every app with what it is served with — Let's Encrypt HTTP-01, Let's Encrypt DNS-01 with the Cloudflare account, Cloudflare Origin CA, or HTTP only — and the names it serves that its certificate does **not** cover. A browser shows those as not secure, and Cloudflare in Full (strict) answers 526 for them. `cipi alias add` and `cipi www add` say whether the new name is already covered, or which command adds it (HTTP-01, DNS-01 for a wildcard, Origin CA).

### Fixed — `cipi app list` showed every PHP-FPM app as Octane

The list is read with `IFS=$'\t'`, and tab is IFS whitespace: the empty Octane column was folded into the next one, so every app without Octane read `-` as its Octane server. It was listed with runtime `octane` and a red dot (the status check looked for a `<app>-octane` Supervisor program). Only the list was wrong — the apps ran on PHP-FPM. Empty columns are now emitted as `-`.

### Changed — `cipi app create` says to add the deploy key before deploying

When the Git provider is not configured with a token, the summary prints the deploy key and then `Next: … cipi deploy <app>`, and the first deploy fails because the repository does not know the key yet. The key is now flagged as a required step before the first deploy, with where to add it on GitHub and GitLab.

### Migration

`lib/migrations/5.5.1.sh`:

1. Writes the certbot deploy hook that reloads nginx.
2. Removes `--nginx` from the `certbot renew` line of root's crontab.
3. Writes `/etc/nginx/snippets/cipi-ssl.conf`.
4. Apps whose certificate renews over DNS-01 (its renewal config names a Cloudflare credentials file) but are not recorded as DNS-01 — the install stopped at the `certbot install` step — get `ssl_dns_provider` and `ssl_dns_account`; a certificate issued with `--wildcard` gets `ssl_wildcard`. The next `cipi ssl install` then keeps DNS-01 and the wildcard.
5. Rewrites, with the HTTPS block written by Cipi, the vhost of every app that has a certificate and: a wildcard name on it, a wildcard name among its domains, a Cloudflare Origin CA certificate, or no HTTPS in the vhost at all. One app at a time, with `nginx -t` after each: the previous file is kept in `/var/lib/cipi/vhost-backup-5.5.1` and put back if nginx refuses the new one. Other apps keep their certbot-written vhost until it is next regenerated (any alias, www, basic auth, redirect… change), which switches it.

No certificate is requested or renewed, nothing is deployed.

---

## [5.5.0] — 2026-10-01

### Fixed — Laravel app logs were rotated twice and never expired

`cipi app create` wrote `LOG_CHANNEL=daily` into every Laravel app's `.env`, so Laravel named one file per day (`laravel-2026-09-24.log`). The `cipi-app-logs` logrotate rule then rotated `storage/logs/*.log` on top of that, with `copytruncate`. Each daily file was rotated exactly once, a day or two after it was written:

- its content moved to `laravel-<date>.log.1`, which was **never compressed** (`delaycompress` waits for a second rotation, and an empty file is not rotated again) and **never deleted** (`rotate 365` counts rotations per file, and every date is its own file), so the 12-month retention did not apply to Laravel logs;
- an empty `laravel-<date>.log` stayed behind, and that is the file `cipi app logs <app> --type=laravel` and the panel read: the log looked empty while the entries sat in the `.log.1` next to it;
- Laravel's own pruning never saw the `.log.1` files.

Apps now log to a single `storage/logs/laravel.log`, and logrotate alone rotates it: daily, compressed from the second day, 365 rotations.

- **New apps**: `shared/.env` is created with `LOG_CHANNEL=single`.
- **logrotate** (`/etc/logrotate.d/cipi-app-logs`): the Laravel pattern is now `storage/logs/*[!0-9].log`, which leaves out any log whose name ends in a date. An app that sets `LOG_CHANNEL=daily` again on purpose gets what Laravel does by itself: one file per day, pruned after `LOG_DAILY_DAYS`. Every other `.log` in `storage/logs` (and `laravel.log`) is rotated as before.
- **`cipi sync import`**: an `.env` exported by a server still on `daily` is switched to `single`, and dated logs that arrive with `--with-storage` are folded into `laravel.log`.

### Added — `cipi firewall attempts`: how many failed SSH logins ban an address

fail2ban has banned an address after **3** failed SSH logins (within 1 hour, for 24 hours and longer at each repeat, up to 7 days) since 4.3.0, and the only way to change that number was to edit `/etc/fail2ban/jail.local` by hand — a file Cipi owns.

- **`cipi firewall attempts`** shows the threshold fail2ban is running with, the counting window and the ban time, and whether the value is the default.
- **`cipi firewall attempts <1-100>`** sets it. **`cipi firewall attempts default`** goes back to 3.
- The value is written to `/etc/fail2ban/jail.d/cipi-attempts.local` (`[sshd] maxretry`). fail2ban reads `jail.d/*.local` after `jail.local`, so the value wins and no update resets it. `jail.local` itself is not edited.
- The configuration is checked with `fail2ban-client -t` before the reload. If fail2ban refuses it, the previous state is put back and nothing changes. With fail2ban stopped the value is saved and applies when it starts.
- Only the `sshd` jail changes. Window, ban time and the `recidive` jail stay as they are. `1` is accepted, with a warning: one mistyped password then bans its owner.
- CLI only (root), logged in `cipi.log`. `cipi compliance report` adds the drop-in to its fail2ban evidence. README documents the defaults.

Servers keep the default of 3 until the command is used: the migration does not touch fail2ban.

### Added — `cipi disk`: disk usage of the server and of every app

`cipi status` printed one line for `/`, and `cipi monitor` only says that the disk is filling up. Neither says which app takes the space.

- **`cipi disk`** prints every local filesystem (size, used, free, use %) and then every app, largest first: **files** (the app's home: releases, shared storage, logs), **database**, **total**, and the **percentage of the disk** that holds `/home`. Two closing rows give all apps together and everything else (system, packages, logs, local backups, other databases).
- The database figure covers the database named after the app and, when `shared/.env` points at another one, the one in `DB_DATABASE`. The size is what the database server reports (`information_schema` for MariaDB, `pg_database_size` for PostgreSQL); for MariaDB it is compared with the database's directory in the server's data dir and the larger of the two is used. If the server does not answer, the directory alone is measured. Custom and Node apps have no database and show 0.
- Sizes below 0.01 GB are printed in MB (`4.2 MB`), so a small database does not read as `0.00 GB`. `--json` carries the exact `files_kb`, `database_kb` and `total_kb` next to the rounded GB.
- **`cipi disk --json`** returns the same figures for scripts.
- Sizes are measured with `du` when the command runs: nothing is stored, and a server with large apps takes a few seconds. Read-only, root CLI. `cipi help server` and tab-completion know it.

### Added — `cipi disk db`: every database, in MB

Next to the per-app figure there is a listing of the databases themselves, per engine, for every engine installed on the server. It shows what the app table cannot: databases that belong to no app, and the engines that are not SQL.

- **MariaDB** — one row per database. The size is the larger of what the server reports (`information_schema`) and the database's directory in the server's data dir, since the files include space the server has not handed back. Empty databases are listed too. These are the same figures the DATABASE column of `cipi disk` uses.
- **PostgreSQL** — one row per database (`pg_database_size`).
- **Valkey** — one row per logical database (`db0`, `db1`, …) with its number of keys. Valkey does not know the size of a single database, so the size is the instance's: memory in use and files on disk. The password reaches `valkey-cli` through the environment, not the command line.
- **Meilisearch** — one row per index with its number of documents, and the size of its documents where the installed version reports it. The total is the `data.ms` directory.
- Every engine closes with its size on disk as a whole (data directory, logs included). An engine that is installed but does not answer gets a note and still shows that total; an engine that is not installed is left out. `cipi disk db --json` returns the same figures.

### Added — soft disk limit per app, with an alert

No app has a limit unless one is set: the default is unlimited, on new and existing servers alike.

- **`cipi app limits <app> --disk=<GB>`** (e.g. `10`, `2.5`) sets a limit for the app's files and database together, the TOTAL of `cipi disk`; **`--disk=none`** removes it. The command reports what the app uses now and warns if it is already over. Setting only `--disk` does not rebuild the FPM pool or restart workers.
- **It is soft.** Nothing is blocked when the limit is passed and the app keeps working. The limit is a threshold for a notification.
- **New monitor check `app_disk`**, on by default like the others. An app at **90%** of its limit raises a warning, an app over it a critical alert, and a recovery follows when it is back under, with the usual reminder every 4 hours in between. Each app has its own alert state, so a second app going over is not hidden behind the first. Trigger `monitor_app_disk`, through email and every configured channel.
- **Cost.** Only apps with a limit are measured, and a measurement is reused for 30 minutes, so the 5-minute cron does not walk the homes every time. A manual `cipi monitor` measures afresh. `cipi monitor set app_disk --warn=90 --minutes=30` changes both; `cipi monitor disable app_disk` turns the check off.
- **`cipi disk`** has a `LIMIT` column (`10 GB (64%)`, `over` once passed) and `--json` adds `limit_gb`, `limit_percent` and `over_limit` to every app.
- The limit is stored next to the app as `disk_limit_gb`, not inside `limits`: that object is what `cipi.yml` reconciles, and an app's repository must not be able to raise the space its server grants it. `cipi sync` carries it with the app.
- A hard limit (filesystem quotas) is deliberately not part of this: it cannot cover the database, needs quotas enabled on the filesystem, and takes a site down when it is reached.

The whole-server disk alert is not new and did not change: the `disk` check has warned at 80% and gone critical at 90% of any filesystem since 5.3.0, on by default. README now states those defaults.

### Fixed — tab-completion did not work where cipi is actually typed

Completion has been installed since 5.2.0, but in three everyday situations `<Tab>` did nothing:

- **`sudo cipi …`** — how the `cipi` user runs every command. It relied on the sudo completion of the `bash-completion` package, which `setup.sh` installs only since 5.2.0. Without the package sudo has no completion and `<Tab>` offered file names. The script now brings its own for that case (`_cipi_sudo_complete`): it skips sudo's options, completes `cipi` as the command even though the binary is root-only, and hands the rest of the line to the cipi completion. With `bash-completion` loaded nothing changes, and if it is loaded later the line is handed back to it.
- **Non-login shells** — `sudo -s`, `su`, tmux, screen. The loader lived only in `/etc/profile.d`, which those shells do not read. Root and the `cipi` user, the two who can run cipi, now also get a loader in `~/.bashrc`: added once, existing content untouched, active in interactive shells only.
- **App names for the `cipi` user** — they came from `/etc/cipi/apps-public.json`, which only root (or the `cipi-api` group) can read, so `sudo cipi deploy <Tab>` offered nothing. When the file is not readable the names now come from the members of the `cipi-apps` group, which every user can list.

New servers get all of this from `setup.sh`. Existing servers get it from the next `cipi self-update`, which already rewrites the completion files on every run: no migration step, no package to install. A shell that is already open needs to be reopened.

### Added — `cipi ssh apps`: SSH/SFTP access of app users, per app or for all

Every app user can log in over SSH and SFTP with its password, and there was no way to turn that off short of editing `sshd_config` by hand.

- **`cipi ssh apps`** lists every app user with its access, `enabled` or `disabled`, and what new apps get. `--json` for scripts.
- **`cipi ssh apps disable <app>`** / **`enable <app>`** changes one app user.
- **`cipi ssh apps disable --all`** / **`enable --all`** changes every app user, whatever the single settings were, and sets what apps created afterwards get (`cipi app create`, `cipi sync import`). After a `disable --all`, single users can still be enabled one by one.
- **Disabled means no login from another machine.** Logins from the server itself stay allowed, because Deployer reaches the app user over `ssh localhost`: deploys, webhooks and rollbacks keep working. Sessions already open stay open until they close. The `cipi` user and `root` are refused by the command.
- **How.** The state is membership of the group `cipi-nossh`. One rule at the end of `/etc/ssh/sshd_config` (`Match Group cipi-nossh Address *,!127.0.0.1,!::1` → `DenyUsers *`) denies that group from every non-local address. It is added the first time a user is disabled: on a copy that `sshd -t` validates before it replaces the live file, followed by a reload, not a restart; a rejected copy changes nothing. After that, enabling or disabling a user is only a group change, with no rewrite and no reload.
- After a `disable` the command asks sshd itself (`sshd -T -C`) whether the rule applies to the user from outside and not from localhost, and warns if it does not.
- Default: every app user has access, on new and existing servers. Nothing changes until the command is used. Changes are logged and notified (trigger `app_ssh_access`). CLI only (root).

### Added — several Cloudflare accounts for DNS-01 certificates

`cipi ssl dns set` stored one Cloudflare token, in one file, for the whole server. A wildcard certificate needs a token of the account that holds its zone, so a server hosting domains of clients with their own Cloudflare accounts could serve only one of them. Setting a second token overwrote the first, and the certificates issued with the first then stopped renewing.

- **`cipi ssl dns set --name=NAME --token=TOKEN`** adds a named account, any number of them. Without `--name` it is the `default` account, in the same file as before (`/etc/cipi/cloudflare.ini`): servers with one token need to change nothing. Named accounts are stored next to it, one file each in `/etc/cipi/cloudflare/`, root-only. Running it again on an existing name replaces the token (rotation).
- **`cipi ssl install <app> --dns=cloudflare --account=NAME [--wildcard]`** issues with that account. Without `--account` the app keeps the account its certificate was last issued with, else `default`. The account is stored on the app and named in the log and the notification. An account that is not configured is refused before certbot runs, with the list of the ones that are.
- **Renewals need nothing.** certbot records the credentials file in each certificate's renewal config, so every certificate renews with the token of its own account.
- **`cipi ssl dns list`** shows every account with the certificates that renew with it (`--json` too). Tokens are never printed. **`cipi ssl status`** adds the account next to each DNS-01 certificate.
- **`cipi ssl dns remove <NAME>`** removes an account, and refuses while a certificate still renews with it: without its token that certificate would fail to renew, silently, until it expired.
- Account names are lowercase letters, digits, `-` and `_`. The credentials file is created with a umask that keeps the token unreadable by others even while it is written; before, it was world-readable for an instant inside `/etc/cipi`.
- When issuance fails the error now says which account was used and that it must hold the zone.

### Fixed — installer: a container was reported as a wrong Ubuntu version

`setup.sh` compared the Ubuntu release with `bc`, which the same script installs only later. On an image without `bc` — container images above all — the comparison failed for every release, and the installer stopped with `requires Ubuntu 24.04+ (found: 24.04)`. In a container that hid the real reason: Cipi is not supported on shared-kernel virtualization.

- **The environment is checked first and named.** `systemd-detect-virt --container` where it exists, otherwise `/.dockerenv`, `/run/.containerenv`, a Microsoft or OrbStack kernel, `/proc/vz` without `/proc/bc`, and `container=` in PID 1's environment. The error says what was found (OpenVZ / Virtuozzo, LXC, Docker, Podman, WSL, OrbStack, systemd-nspawn, or the raw type), why Cipi cannot run there, and what to use instead: full virtualization (KVM, VMware, Hyper-V, Xen HVM) or bare metal. Full VMs and bare metal are not affected.
- **The version check no longer needs `bc`** (`sort -V`), so a minimal image of a supported release on a real VM passes.
- README requirements now state the virtualization requirement.

### Migration

`lib/migrations/5.5.0.sh`, for every Laravel app (custom and Node apps are not touched):

1. Rewrites `/etc/logrotate.d/cipi-app-logs`.
2. `shared/.env`: `LOG_CHANNEL=daily` becomes `single`, and so does a `daily` inside `LOG_STACK`. Any other channel (`stack`, `stderr`, `slack`, …) is left as it is. The rewrite runs as the app user and goes through a copy that replaces the `.env` in one rename, with the same owner and mode: the file is never truncated in place, so a write that fails (a full disk) leaves it exactly as it was. An `.env` the app user cannot rewrite is reported with a warning.
3. Where the `.env` changed, so that no process keeps the old channel in memory:
   - `artisan config:cache` as the app user, if the current release has a cached config. Other `.env` edits that were waiting for a deploy become active with it.
   - SIGTERM to the app's **running** Supervisor programs (queue workers, Horizon, Octane, Reverb). They finish the job in hand and Supervisor starts them again; stopped programs stay stopped. Octane and Reverb drop their connections for the few seconds of the restart, as on a deploy.
   - one `systemctl reload` of PHP-FPM per PHP version in use by those apps.
4. Folds the dated files into `laravel.log`, oldest first: `laravel-<date>.log`, `.log.N`, `.log.N.gz` and the empty stubs. It runs as the app user. A file is removed only after its content is in `laravel.log`; an existing `laravel.log` is appended to, never replaced; a file a process still has open, or an archive that cannot be read, is left where it is and named in the output. The history then leaves through the normal rotation.

The migration needs free disk space for one uncompressed copy of an app's dated logs while it folds them; if that fails, the app's files are left as they were. A second run finds nothing to do.

---

## [5.4.1] — 2026-09-17

Opens redirects, proxies and Node app management to the panel API. The commands themselves exist since 5.3.1 (`cipi redirect`, `cipi proxy`) and 5.4.0 (`cipi node`); until now they were CLI-root only, so a panel (cipi/api ≥ 1.20.0) could not offer them.

### Changed

- **Panel API sudoers** (`/etc/sudoers.d/cipi-api`): `www-data` may now run `cipi redirect set|enable|disable|unset|add|remove|list`, `cipi proxy add|remove|list` and `cipi node list|status|restart`. Every rule is the usual exact command line, nothing broader.
- **What deliberately stays CLI-root:** Node runtime management (`cipi node install|default|upgrade|remove`), `cipi search install|upgrade|key-rotate`, `cipi package install|remove` and every `zt` mutation — installing software on the server is not something a web panel should be able to do, compromised or not. The redirect/proxy validation is the CLI's own (loops, collisions, reserved paths, loopback and metadata upstreams), so the panel gets exactly the same refusals.

### Migration

`lib/migrations/5.4.1.sh`: regenerates `/etc/sudoers.d/cipi-api` and checks it with `visudo -cf` afterwards, warning if it does not validate. Nothing is deployed, reloaded or restarted.

---

## [5.4.0] — 2026-09-17

### Added — Deploy audit ledger (every deploy, whatever started it)

Until now only `cipi deploy` and the webhook wrapper wrote deploy banners, into a log the app user owns. A deploy started any other way left no record: cipi/agent running `dep` inside the app, the panel, or `dep deploy` typed over SSH. The one thing all of these share is the app's Deployer recipe, so the record is written from there.

- **`/usr/local/bin/cipi-deploy-audit`** (root, reached through one per-app sudoers rule) is called by the recipe after `deploy:symlink` (published), on `deploy:failed` (failed) and after `rollback`. Custom apps: after `deploy` and on its failure. The hook runs with `runLocally`, so the process chain of whoever ran `dep` stays visible. A missing helper or rule never fails a deploy.
- **Root does not take the caller's word for anything.** From `/proc` it reads the release `current` points at, its commit (Deployer's `REVISION`, or `htdocs` HEAD for custom apps) and Deployer's own `releases_log` entry. From the process chain it reads the **origin**: `cipi-cli` (trigger `cli`, `rollback`, `auto-rollback`, `sync`), `panel` (`cipi deploy` started by www-data), `webhook`, `app-web` (PHP-FPM), `app-queue`, `ssh`, `cron` or `root-shell`. It also records the **operator** (audit login uid, set by PAM and not changeable by the user), the SSH client **IP** and the chain itself.
- **Claims are kept apart.** What only the app can say goes under `claimed`, e.g. who pressed deploy in an MCP client. `cipi-app-deploy` now reads it from the trigger file: the cron moves `~/.deploy-trigger` to `~/.deploy-trigger.run` instead of deleting it, and the file may carry `source`, `actor`, `ip`, `ref` and `request_id` as JSON or `KEY=VALUE`. Code that runs `dep` in-process can set the same `CIPI_DEPLOY_*` environment variables. A known `source` also names the trigger in `deploy.log` (`trigger=mcp`).
- **`/var/log/cipi/deploys.jsonl`**, root-only, one JSON line per event. Each line carries its sequence number and the SHA-256 of the line before it, and is also sent to syslog (`cipi-deploy`), so forwarding keeps a copy off the server. Repeated calls for a release already recorded are ignored.
- **`cipi deploy <app> --audit [--days=90] [--json]`** — the app's records.
- **`cipi compliance deploys`** now uses the ledger. It **fails** when the hash chain is broken. It **warns** when an app's `deploy.php` lacks the hook (edited by hand), when an app's sudoers lacks the rule, or when Deployer's `releases_log` has a release the ledger never saw. Only releases since auditing began count (`/var/lib/cipi/deploy-audit-since`). Evidence: `deploy-audit.jsonl`, `deploy-audit.tsv`, `deploy-audit-chain.txt`, `deploy-audit-hooks.txt`, `deploy-audit-unaudited.tsv`, plus the existing `deploys.tsv` from the banners. Without the ledger (not yet updated) the control warns instead of passing.
- **Honest about gaps.** The chain proves that nothing before the newest record was changed or removed. Root can still rewrite the newest records or the whole file, and the report says so: the syslog copy forwarded off the server is the independent one. The ledger records deploys, not every file change: an app user can still edit `current/` over SFTP (covered by `cipi scan` integrity) or remove the hook from their own `deploy.php` (flagged by compliance and cross-checked against `releases_log`).

### Added — Node frontend apps (`cipi app create --node`) and Node runtimes (`cipi node`)

Until now a React/Vue SPA could only be a `--custom` app serving a build committed to git. It had no build step, and client-side routes returned 404 on reload. SSR frameworks had no way to run at all. Node apps are a new app type with the same lifecycle as Laravel ones: releases, rollback, webhook, SSL, basic auth, redirects/proxies, audit ledger.

- **`cipi app create --node=spa|static|ssr [--framework=next|nuxt|sveltekit|astro|remix|vite]`** with `--node-version=22|24`, `--build=`, `--start=` (SSR), `--output=` (spa/static) and `--health-path=` (SSR). Presets fill in each framework's defaults; explicit flags win. Next.js starts with `next start -H 127.0.0.1`.
  - **spa**: nginx serves `current/<output>`, unknown paths fall back to `/index.html`, `assets/ _astro/ _nuxt/ _app/immutable/ static/` are `immutable`, and `*.html` is `no-cache`.
  - **static**: the same without the fallback (`$uri.html`, then a real 404 with `/404.html`).
  - **ssr**: nginx proxies to an upstream (`/etc/nginx/conf.d/cipi-node-<app>.conf`) with WebSocket upgrade and `X-Forwarded-*` headers.
- **Blue/green deploys** (`/usr/local/bin/cipi-node-switch`, root, one sudoers rule per app). The recipe calls it before `deploy:symlink`:
  - the release starts on the idle Supervisor program (`<app>-node-blue` / `<app>-node-green`, each on its own localhost port in 3100–3999, in `/etc/supervisor/conf.d/<app>-node.conf` so `cipi-worker restart` cannot bounce both);
  - it must answer below 500 on the health path within 60 s;
  - then the upstream moves (`nginx -t`, reload) and the old slot stops after a short drain.
  - A process that exits or never answers is stopped, the old slot keeps serving and the deploy fails before `current` moves. `dep rollback` switches back the same way.
  - Only the release path comes from the caller, and it must be a release of that app. Ports, start command, Node version and health path come from `/var/lib/cipi/node/<app>.json`, which only root writes.
- **`cipi-node-run`** (app user) reads `.env` as `KEY=VALUE` data and never sources it. `PORT`/`HOST` cannot be overridden, `HOST`, `HOSTNAME` and `NITRO_HOST` are forced to 127.0.0.1, and the start command is executed as argv with no shell. Start commands are limited to a Node runner (`node npm npx pnpm yarn bun`) plus plain arguments.
- **Recipe** (`lib/deployer/node.php`): installs dependencies from the lockfile (`npm ci`, `pnpm install --frozen-lockfile`, `yarn install --immutable|--frozen-lockfile`, `bun install --frozen-lockfile`; `npm install` with a warning when there is no lockfile). It then builds with `NODE_ENV=production` and telemetry off, and for spa/static checks that `<output>/index.html` exists. `shared/.env` is a shared file, so frameworks read it at build time and SSR servers at runtime.
- **Node runtimes** — `cipi node install|list|upgrade [--restart]|remove <major>`. Official nodejs.org builds (x64/arm64) are checked against `SHASUMS256.txt`, unpacked to `/opt/cipi/node/v<version>` and exposed as `/opt/cipi/node/<major>` through an atomic symlink, with corepack enabled for pnpm/yarn. Even (LTS) majors only; a major in use cannot be removed. The NodeSource Node 20 used by Laravel asset builds is untouched. `cipi yml` `deploy.post` npm/node steps use the app's major (from `~/.deployer/node.json`).
- **Webhooks without cipi/agent** — `/cipi/webhook` goes to `/usr/local/share/cipi/webhook.php` through an on-demand PHP-FPM pool running as the app user (`open_basedir` = home + receiver, `exec`-family functions disabled, 2 MB body, POST only, never behind basic auth). It verifies GitHub and Bitbucket HMAC-SHA256 and GitLab/Azure tokens, deploys only pushes to the app's branch, and writes the pusher, delivery id and commit into the trigger file, which the audit ledger records under `claimed`. Git providers get the webhook registered automatically, and `cipi git refresh` covers Node apps.
- **Server-wide Node for Laravel apps too** — `cipi node default <major>|system`:
  - **`<major>`** installs the major if needed and links `node npm npx corepack pnpm pnpx yarn yarnpkg` from `/opt/cipi/node/<major>/bin` into `/usr/local/bin`, which comes before NodeSource's `/usr/bin` on the PATH of SSH sessions (Deployer), sudo (`secure_path`, `cipi app run`) and app `.bashrc`. Laravel `--node-build` asset builds, `cipi app run <app> npm …` and `cipi.yml` `deploy.post` all use it from their next run.
  - The links point at the major, not at a patch, so `cipi node upgrade` updates every app on the default.
  - **`system`** removes only Cipi's links and falls back to the NodeSource package, which is never removed.
  - A file in `/usr/local/bin` that Cipi did not create (a global pnpm, a hand-installed node) is left alone and named in a warning.
  - `cipi node list` marks the default. New Node apps start on it unless `--node-version` says otherwise. The default major cannot be removed. Changing it sends a `node_default` notification.
- **Pin one Laravel app** — `cipi app edit <app> --node-version=24` keeps that app on its own major whatever the default is; `--node-version=default` follows the server again. Its `node-build.sh` exports that major's PATH, `cipi app run` and `deploy.post` use it too, and `cipi app show` says whether the app is pinned or on the server default. `cipi.yml` `deploy.post` from cron now has `/usr/local/bin` on PATH.
- **Per-app commands**: `cipi node status|restart|logs <app>` (restart is blue/green, so no downtime). `cipi app edit <app>` accepts `--build= --start= --output= --health-path= --node-version= --node=spa|static|ssr`. `cipi app env` works for Node apps. `app show`/`app list` show the mode and slots, and `app delete` stops and removes both slots, the upstream and the state.
- **Not yet**: `cipi sync` skips Node apps with a message, and `cipi app clone` refuses them, as it does custom apps. Databases are not created with the app: use `cipi.yml` `databases:` or `cipi db`.

### Added — `cipi.yml`: www redirect, basic auth, redirects, proxies, search

- **`app.www: to-root | from-root | none`.** The other name of the pair must be in `app.aliases` when both are declared, and a declared alias list that drops a name the current redirect needs is refused at plan time instead of failing halfway through the apply. Clearing runs before the aliases are reconciled; setting runs after.
- **`app.basic_auth`** — `users:` as names or `{name, password_hash}`, or `basic_auth: false`. **No password in the repository:** a name-only user keeps the password already set on the server (`cipi basicauth enable <app> --user=NAME`); a user the server does not know blocks the plan. `password_hash` accepts only bcrypt (cost 10+) or SHA-512 crypt; apr1/MD5 is refused. Server users not listed are removed. `cipi yml generate` emits user names only, never hashes.
- **`redirect`** (`to`, `code`, `keep_path`, `enabled`; `enabled: false` alone removes it), **`redirects[]`** (`from`, `to`, `code`, `keep_path`) and **`proxies[]`** (`prefix`, `upstream`, `strip_prefix`, `preserve_host`, `timeout`, `buffering`). A declared list replaces the current one. Every rule goes through the same validation as `cipi redirect` / `cipi proxy` (loops, collisions, reserved paths, Reverb, charset), checked against the whole declared set, so a redirect and a proxy on the same prefix collide in the plan. The routes apply as one change: one vhost regeneration, one `nginx -t`, reverted as a whole if nginx refuses it.
- **Stricter than the CLI for proxies**, because anyone who can commit controls the file: no `--force`, so Cipi's own loopback ports (MariaDB, PostgreSQL, Valkey, SSH, Meilisearch, nginx, another app's Octane/Reverb) are always refused. Link-local and `0.0.0.0/8` upstreams, cloud metadata included, are refused too, and resolved hostnames are checked as well as literal IPs.
- **`node:`** (Node apps): `framework`, `mode`, `version`, `build`, `start`, `output`, `health_path`, with the same presets and validation as `cipi app create --node`. **It is applied by the deploy itself, not by `cipi yml apply`.** Right after the checkout, the recipe's `node:config` runs `cipi yml node-sync <app> <release>` (root). That command reads the section from *that release*, updates apps.json, the build script, the blue/green state and `~/.deployer/node.json`, and the recipe re-reads them. The commit that changes the build or start command is therefore built and started with it.
  - A mode or output change moves nginx only after `current` has moved (`node:finalize`), so nginx never serves a build that does not exist yet. Going from `ssr` to `spa`/`static` retires the slots; going to `ssr` allocates the ports before the switch.
  - A Node major that is not installed fails the deploy before the build: installing runtimes stays with root (`cipi node install`).
  - An invalid file leaves the server's settings in place, and the usual `yml_fail` alert follows from the post-deploy apply.
  - Only with `cipi yml auto <app> on`, which is also what writes the sudo rule for `node-sync`: without it the recipe does not even try. `cipi yml plan` lists the changes the next deploy will make. `node:` on a Laravel app blocks the plan.
- **`search: true | false`** — Meilisearch for Laravel Scout, the same as `cipi search enable|disable <app>`: a key scoped to `<app>-*` and the `SCOUT_*` / `MEILISEARCH_*` variables in `.env`. Installing the engine stays with root: the plan is blocked until `cipi search install` has run and Meilisearch is up. `false` never drops indexes, which only root can purge (`--purge-indexes`). Refused on custom apps.
- **`deploy:` recipe options** — the same set as `cipi app deploy-config`, from the repository: `keep_releases` (1–20), the artisan hooks (`migrate`, `optimize`, `storage_link`, `queue_restart`, `horizon_terminate`), `extra_artisan` (validated, `tinker` refused) and `snapshot` (the pre-deploy database snapshot). Only declared keys are reconciled; a change regenerates `deploy.php` once. Refused on custom apps (no recipe); on Node apps only `keep_releases` and `snapshot` apply — the artisan hooks block the plan.
- **`app.limits`** — `memory_limit`, `fpm_max_children`, `octane_workers`, `worker_procs`, the same as `cipi app limits` and reapplied through it (FPM pool, Octane and worker programs regenerated). The bounds are the CLI's, but a value outside them **blocks the plan instead of being clamped**: nobody is watching an unattended apply.
- **`ssl.force_https: true`** — the HTTP → HTTPS redirect, the same as `cipi ssl force`. The plan is blocked until the certificate exists (`cipi ssl install` stays with root). It can only ever be turned **on** from the file: no cipi command disables the redirect, so `false` against an app already forced is refused rather than silently ignored.
- **`env.required`** — names (never values) the app's `.env` must carry. A missing or empty variable blocks the plan, so code that expects `STRIPE_KEY` is never deployed against a server that does not have it. Purely a gate: nothing is written.
- **`crons:`** — scheduled commands through the same allowlisted runners as `deploy.post` (`artisan`, `npm`, `composer`, `php`, `node`, …; no shell, no pipes, `%` impossible by charset), with `every: 30m` or five cron fields, the same grammar as backup profiles. The declared list replaces only the crontab lines the file manages (tagged `# cipi-yml`); the rest of the app user's crontab — the Laravel scheduler line included — is never touched. `artisan` entries on a non-Laravel app block the plan.
- `cipi yml generate` and `cipi yml example` cover the new keys.
- `lib/routes.sh`: validation moved into `_routes_build_app_redirect`, `_routes_build_redirect` and `_routes_build_proxy`, shared by the CLI and `cipi.yml`. CLI behaviour is unchanged.

### Fixed

- **Old backups were never deleted** (e.g. a `1w` profile still holding archives from August). Three causes, all fixed:
  - **The pre-5.1 layout was orphaned.** 5.1.0 turned the nightly job into the `default` profile (`s3://<bucket>/cipi/default/<ts>/`) and removed the old `cipi backup prune --weeks=N` line. That line was the only thing pruning `s3://<bucket>/cipi/<app>/<ts>/`, so every archive written before the upgrade stayed forever. The same happened to the archives of a removed profile, and to the database dumps in `/var/log/cipi/backups/`, where `cipi deploy --snapshot` still writes pre-deploy snapshots.
    - Every backup run, and `cipi backup prune`, now also prunes those orphans (local and S3). They are kept as long as the **longest** age-based retention of any profile, so nothing goes sooner than a current profile would keep it. With count-only retention (`keep: N`) there is no age to go by, and orphans are left alone. `--dry-run` lists them.
  - **S3 errors were swallowed.** Retention listed S3 with `2>/dev/null`: a denied `ListBucket`, a wrong endpoint or a missing CLI made it prune nothing, every night, with no sign. An empty prefix is still not an error. Any other listing or delete failure is now logged, sends a "Cipi backup retention failed" alert (`backup_fail`) without failing the backup itself, and makes `cipi backup prune` exit 1 with the reason.
  - **Cron PATH.** Root's crontab has no `/usr/local/bin`, where the AWS CLI installs; `lib/backup.sh` now adds it.
- **"Cipi API updated" was sent every night** by the 04:30 soft update, even when Composer changed nothing. `cipi api update` now compares a fingerprint of the locked packages (name, version, dist/source reference) before and after. Only a real change is logged (`API UPDATED: cipi/api A → B`) and notified, with the old and new `cipi/api` versions. Otherwise it prints "already up to date".
- `cipi yml example` printed `every:: command not found` (an escaped backtick in the template).
- `cipi.yml` on a custom app: `workers.queues`, `workers.horizon: true` and `schedule: true` produced artisan workers the app cannot run, or stopped the apply halfway. They now block the plan, like `workers.reverb` and `search` already did.
- `_basicauth_set_user` removed users with a regex, so a user named `a.b` also removed `axb`. It now matches the name exactly, and the temporary file is no longer created world-readable.

### Migration

`lib/migrations/5.4.0.sh`: installs `cipi-deploy-audit`, adds the sudoers rule per app (validated with `visudo`, restored if rejected), appends the audit hooks to each `deploy.php` without touching the rest of the file, switches the trigger cron from `rm` to `mv`, and writes the audit start marker.

**Node 20 → 22.** Node 20 reached end of life in April 2026.
- **Fresh installs:** `setup.sh` now installs Node 22 from NodeSource.
- **Existing servers whose Node is still 20** (the NodeSource package, or a `cipi node default 20`): the migration switches them to Node 22 with `cipi node default 22`, which downloads and verifies the official build and links it into `/usr/local/bin` ahead of `/usr/bin`. The NodeSource package is not touched, so `cipi node default system` restores 20. Laravel asset builds, `cipi app run npm` and `deploy.post` use 22 from their next run.
- **Servers already on another major**, or with no Node at all, are left as they are.
- **Failed download:** the server stays on 20, the migration says how to retry (`cipi node default 22`) and the update carries on.
- A `node_default` notification is sent.

Nothing is deployed, reloaded or restarted.

---

## [5.3.1] — 2026-09-17

### Added — Compliance evidence (`cipi compliance`)

Cipi cannot be ISO 27001 or SOC 2 certified: there is no organisation or service to audit, only software on your server. What a team under audit needs is evidence that the deploy platform meets the controls, in a form the auditor accepts. `cipi compliance` collects that evidence. It is **read-only**: no check changes the server, runs `apt update`, or writes config.

- **`cipi compliance [check] [--days=90] [--json]`** — runs 17 controls and prints pass / warn / fail / info / n/a. Exits 1 on any fail, so it can gate CI or cron.
- **`cipi compliance report [--days=90] [--out=/abs/path] [--no-archive] [--json]`** — writes `/var/log/cipi/compliance/<host>-<UTC time>/` with `report.md` (for the auditor), `report.json`, `evidence/<control>/…` (the raw command output behind each finding) and `SHA256SUMS`, plus a `.tar.gz` and its `.sha256`. Everything is root-only (700/600). The command prints the archive SHA-256 so you can record it outside the server. The run is logged to `cipi.log`.
- **`cipi compliance list`** / **`cipi compliance controls`** — past reports with their counts, and the control catalog with its mapping.
- **Controls and mapping** (ISO/IEC 27001:2022 Annex A · SOC 2 TSC): `ssh` (effective `sshd -T`), `firewall` (ufw default deny), `intrusion` (fail2ban jails, CrowdSec), `patching` (unattended-upgrades, pending security updates from the cached lists, reboot-required), `kernel` (CIS network sysctls), `tls` (`nginx -T` protocols, HSTS, Let's Encrypt expiry and key type), `accounts` (UID 0, empty passwords, accounts not managed by Cipi, sudoers), `ssh_keys` (fingerprints; RSA < 3072 and DSA flagged), `api_tokens` (no expiry, expired, unused for the period, `*` ability, IP allowlist `*`), `gui_2fa`, `secrets` (encrypted and root-only config, key file modes), `deploys` (deploy log banners: trigger, branch, release, commit SHA from Deployer's `REVISION`, result, rollbacks), `backups` (schedule freshness, off-site copy, encryption), `logging` (remote forwarding, auth.log history, journald, auditd), `monitoring` (monitor cron, disabled checks, alert delivery, muted triggers), `time` (NTP), `malware` (`cipi scan`).
- **No secrets in the bundle.** Panel SQLite databases are read as their owner with `sqlite3 -readonly` (PHP PDO fallback), using named columns only. Token hashes, password hashes and 2FA secrets are never selected. SSH keys are exported as fingerprints only, and backup credentials are not exported.
- **Honest about gaps.** `secrets` is at best a warn: the vault uses AES-256-CBC without a MAC, so it is not authenticated encryption, and the report says so before an auditor has to ask. `backups` notes that restore tests are not recorded. `deploys` notes that the person who ran a CLI deploy is in `auth.log`, not in the deploy log. Cipi's own design choices appear as notes, not failures: password SFTP login for `cipi-apps` users, and nginx, databases and PHP kept off unattended-upgrades.

### Added — Redirects (`cipi redirect`) and prefix proxies (`cipi proxy`)

Both are rendered by `_create_nginx_vhost` from `apps.json` (`redirect`, `redirects[]`, `proxies[]`), so they survive every vhost regeneration (alias, www, basic auth, PHP switch, `cipi sync import`), and certbot clones them into `:443` like every other location.

- **`cipi redirect set <app> --to=<url> [--301|--302|--307|--308] [--no-path]`** — every name of the app, www host included, redirects in one hop. The path and query are kept by default (`old.com/a?b` → `https://new.com/a?b`). ACME stays public, so the old name's certificate keeps renewing. Refuses a target served by the app itself (loop).
- **`cipi redirect enable|disable <app>`** toggles the saved target; **`unset`** forgets it.
- **`cipi redirect add <app> <from> <to> [--301|--302|--307|--308] [--no-path]`** — path redirects. `<to>` is a same-app `/path` or an `http(s)://` URL. A `<from>` ending in `/` is a prefix: the rest of the raw request URI is appended (`/blog/x?y` → `https://blog.example.com/x?y`), and `/blog` without the slash goes to the target too; `--no-path` sends everything to `<to>` as is. Otherwise `<from>` is exact and only the query string is carried over (unless `<to>` has its own). Adding an existing `<from>` updates it. **`remove`**, **`list [--json]`**.
- **`cipi proxy add <app> <prefix> <http(s)://upstream> [--strip-prefix] [--preserve-host] [--timeout=60] [--no-buffering] [--force]`** — `location ^~ <prefix>` with `proxy_pass`. Without `--strip-prefix` the URI goes upstream unchanged; with it, `/api/users` → `<upstream>/users` and `X-Forwarded-Prefix` is sent. An upstream with a path (`http://h/v1`) always replaces the prefix, so it requires `--strip-prefix`. WebSocket upgrade, `X-Real-IP`, `X-Forwarded-For/-Proto/-Host`, `proxy_ssl_server_name` for HTTPS upstreams. `Host` is the upstream's unless `--preserve-host`. `--no-buffering` is for SSE, long polling and streamed downloads. Basic auth, when on, covers the prefix. **`remove`**, **`list [--json]`**.
- **Path redirects and proxies keep working while the app redirect is on** — they are more specific than `location /`, so a moved site can keep `/api/` where it was.
- **Validation.** Paths and URLs are limited to a charset with no quotes, `$`, `;`, braces or whitespace, so a rule cannot inject nginx directives. Source paths must be written decoded (nginx matches the decoded URI). Refused: `/`, the ACME challenge, `/favicon.ico`, `/robots.txt`, `/index.php`, `/cipi/webhook`, Reverb's `/app` and `/apps` on a Reverb app, and any path another redirect or proxy already occupies (e.g. a redirect and a proxy on `/api/`). Redirects that would loop back into themselves are refused.
- **Loopback guard.** A proxy to `127.0.0.1`/`localhost` on a port Cipi already uses — nginx itself (80/443), SSH, MariaDB, PostgreSQL, Valkey, Meilisearch, another app's Octane or Reverb — is refused without `--force`. An upstream hostname that does not resolve is refused (nginx resolves it at reload); one that does not answer within 5s is only a warning.
- **Safe apply.** `nginx -t` must pass before the change. If nginx refuses the new vhost, `apps.json` and the vhost are restored and the command exits 1.
- `cipi app show` lists the app redirect, path redirects and proxy prefixes. Two notification triggers: `redirect_change`, `proxy_change` (on by default). Shell completion and `cipi help redirect|proxy`.

CLI only for now: the panel API sudoers are unchanged.

No migration: nothing is installed, scheduled or enabled.

---

## [5.3.0] — 2026-09-11

### Added — Cloudflare Zero Trust (`cipi zt`)

Opt-in, same contract as CrowdSec: **off until you ask**. `setup.sh` / `cipi self-update` never install `cloudflared` and never call `cipi zt enable`. Fail2ban and UFW stay; this feature teaches them about Cloudflare rather than replacing them.

- **`cipi zt token set --token= --account=`** — API token saved root-only at `/etc/cipi/zt.token`. Needs Account.Cloudflare Tunnel (Edit), Account.Access: Apps and Policies (Edit), Zone.DNS (Edit). Origin CA also needs Zone.SSL and Certificates (Edit). This is **not** `/etc/cipi/cloudflare.ini` (certbot DNS-01, Zone.DNS only).
- **`cipi zt enable`** — official `cloudflared` package, locally-managed tunnel, systemd unit, nginx `real_ip` from `https://api.cloudflare.com/client/v4/ips` (`CF-Connecting-IP`), fail2ban `ignoreip` backup of those ranges, CrowdSec allowlist of the same ranges when CrowdSec is already on, cron `cipi zt refresh`. **Does not close 22/80/443.**
- **`cipi zt hostname add <app|--gui>`** — CNAME to `{tunnel-id}.cfargotunnel.com`, ingress `http://127.0.0.1:80`. Public (CDN/WAF, no Access). `cipi app create` does not add this on its own; `status` lists apps not on the tunnel.
- **`cipi zt access enable <app|--gui>`** — Cloudflare Access in front of that hostname. Any authenticated user (tighten the IdP in the dashboard). If the app has a Git webhook, a Bypass application is created for `/cipi/webhook` so GitHub/GitLab/Bitbucket are not 403'd.
- **`cipi zt ssh enable --hostname=`** — ingress `ssh://127.0.0.1:22` plus an Access SSH app. Prints the `~/.ssh/config` `ProxyCommand cloudflared access ssh` block. **Port 22 stays open.** Deployer still SSHs to localhost.
- **`cipi zt lock http [--yes]`** — refuses while any app still renews Let's Encrypt over HTTP-01 (Let's Encrypt does not come from Cloudflare IPs). Then: if every HTTP hostname is on the tunnel, close 80/443 entirely (origin dark); otherwise allow 80/443 only from Cloudflare ranges. `--force` skips the HTTP-01 check.
- **`cipi zt lock ssh [--yes]`** — closes port 22 only if `cloudflared` is active **and** the tunnel already has SSH ingress. Otherwise it would lock you out. Rescue: `cipi zt ssh unlock`. CrowdSec rescue, if enabled, stays reachable.
- **`cipi zt origin-cert <app>`** — Cloudflare Origin CA (optional, 15 years). Replaces `ssl_certificate` paths when a `:443` block already exists. Marks the app so `cipi ssl install` HTTP-01 will not overwrite it. Not a default replacement for Let's Encrypt: Full (Strict) still needs *an* origin cert; the tunnel talks HTTP to `:80` and does not need one.
- **`cipi zt status` / `disable` / `refresh` / `unlock http`**. `disable` restores UFW 22/80/443, removes cloudflared and the tunnel, leaves Let's Encrypt alone.
- Panel sudoers: **`cipi zt status` only**. enable/lock stay with the operator on the CLI.
- **`cipi ssl install` HTTP-01** refuses while `lock http` is on, and while the app has Origin CA. Apps on the tunnel get certbot `--no-redirect` so origin HTTP→HTTPS does not break `cloudflared`. `cipi ssl force` refuses on a tunneled app for the same reason.
- CrowdSec's reverse-proxy check still refuses without `real_ip`; the error now points at `cipi zt enable`. After enable, `_crowdsec_nginx_has_real_ip` sees `/etc/nginx/conf.d/cipi-cloudflare-realip.conf`.

Public sites stay public (no SASE login). Staging, the GUI, and SSH take Access. Visitors of an e-commerce shop go through Cloudflare's CDN/WAF via the same tunnel, not Cloudflare One.

### Added — System monitor (`cipi monitor`)

Dashboards are only useful when someone looks at them; what actually matters is a message when something breaks. `cipi health` watches app URLs — **`cipi monitor` watches the server itself**, from cron, every 5 minutes (`/etc/cron.d/cipi-monitor` + `/usr/local/bin/cipi-monitor`). No metrics storage, no graphs, no agents: state files under `/var/log/cipi/monitor/` and a notification when it matters.

- **Seven checks, all on by default, each toggleable.** `disk` (per-filesystem, warn ≥80% / crit ≥90%), `ssl` (Let's Encrypt expiry ≤14 days), `services` (every installed Cipi service via systemd — nginx, MariaDB, PHP-FPM, Valkey, supervisor, fail2ban, and the conditional ones), `workers` (every configured `*-worker-*` / `*-horizon` supervisor program must be RUNNING), `http_5xx` (5xx in the bytes appended to each app's nginx access log since the previous run — ≥20 **and** ≥5% of requests; per-log byte offsets survive logrotate, first run only baselines), `fs` (`/etc/cipi` or `/var/log/cipi` gone read-only), `load` (1-minute load > 4× cores for 2 consecutive runs — a single spike is noise).
- **Edge-triggered alerts.** ok→fail fires once, warn↔crit escalations fire once, fail→ok sends a recovery (`monitor_ok` trigger), and a persisting failure re-alerts every `reminder_minutes` (default 240, `cipi monitor set reminder --minutes=`). The 5-minute cron never spams.
- **CLI.** `cipi monitor [--json]` runs everything now and exits 1 on warn/crit (scriptable). `cipi monitor list` shows checks, thresholds, current state and last alert. `cipi monitor enable|disable <check>`, `cipi monitor set disk --warn= --crit=`, `set ssl --days=`, `set http_5xx --count= --ratio=`, `set load --factor= --runs=`. `cipi monitor test` sends a sample alert through every delivery path.
- **Triggers.** Each check maps to a notification trigger (`monitor_disk`, `monitor_ssl`, `monitor_services`, `monitor_workers`, `monitor_http_5xx`, `monitor_fs`, `monitor_load`, `monitor_ok`) — mute any of them with `cipi notifications disable <trigger>` like everything else.

### Added — Alert channels: Slack, Discord, Telegram, ntfy, webhooks

Email was the only way out of `cipi_notify()`. It now **fans out to chat channels too**, so every existing trigger — deploys, backups, scans, SSH logins, healthchecks, and the new monitor alerts — reaches Slack/Discord/Telegram/ntfy/a custom webhook with zero changes at the call sites.

- **`cipi notifications channel add <slack|discord|ntfy|telegram|webhook> <id> --url=`** — channels live encrypted in `/etc/cipi/alerts.json`. `list` masks the secret part of webhook URLs and bot tokens; `remove`, `enable`, `disable`, `test <id|all>` round out the management.
- **Telegram** uses the Bot API directly: `channel add telegram <id> --token=<bot-token> --chat-id=<id>` (token from @BotFather; send `/start` to the bot and read `getUpdates` for the chat id). Plain-text messages, truncated at Telegram's 4096-char cap.
- **ntfy** gets `Title`/`Priority`/`Tags` headers; urgent triggers (security events, failures, monitor crits) bump a default-priority channel to `high` automatically. **Slack/Discord** get a formatted text payload (Discord truncated at its 2000-char cap). **webhook** receives structured JSON `{server, trigger, subject, body, ts}` for anything else.
- **Best-effort, never blocking.** Delivery has a 5-second timeout per channel and failures are only logged to `events.log` — a slow webhook can never stall a deploy or a cron run.
- Nothing changes until you add a channel: no channel configured = email-only, exactly as before. The 5.3.0 migration installs the monitor cron and default configs but configures no channels and touches no triggers.

### Fixed — `false` read back as `true` (jq `// true`)

jq's `//` operator treats `false` the same as "absent", so every `// true` default silently re-enabled an explicitly disabled flag. Three of them were live:

- **`cipi notifications disable <trigger>` kept firing.** The trigger was written as `false` to `notifications.json` but read back as enabled, so a muted trigger kept sending email. `cipi notifications list` also showed the wrong state.
- **`cipi smtp configure --tls=off` was ignored.** `tls: false` was stored correctly, then read back as `true` when generating `/etc/msmtprc` — msmtp always got `tls on`, which breaks a plain relay. `cipi smtp status` and `--json` reported the wrong value for the same reason.
- **`health: {enabled: false}` in `cipi.yml` did nothing.** The block was read as enabled, so the healthcheck was never removed and the project file then demanded a `health.url`.

All three now use `!= false` (or `has()`), so an explicit `false` stays false and an absent key still defaults to on. `tests/verify-5.3.0.sh` fails if the `// true` idiom comes back on a boolean flag.

---

## [5.2.3] — 2026-09-10

### Added — Git forges beyond GitHub and GitLab

- **Origin, CodeCommit, Bitbucket, Azure DevOps.** `cipi git` detects [Cursor Origin](https://cursor.com/origin) (`origin.cursor.com`), [AWS CodeCommit](https://aws.amazon.com/codecommit/) (`git-codecommit.*.amazonaws.com`), [Bitbucket Cloud](https://bitbucket.org), and [Azure DevOps](https://azure.microsoft.com/products/devops) (`dev.azure.com` / `ssh.dev.azure.com` / `*.visualstudio.com`) the same way it already does GitHub and GitLab. Save credentials, create the app with an SSH clone URL, and Cipi registers the deploy key (and the webhook, when the forge has one). `cipi git refresh` covers every provider.
- **Tokens.** `cipi git origin-token`, `bitbucket-token`, `azure-token`, `codecommit-token <access-key> <secret-key> <iam-user>`. Matching `remove-*` commands. Bearer for Origin and Bitbucket (or `email:token` Basic for Bitbucket). Azure PAT as Basic empty-user. CodeCommit uses IAM `UploadSSHPublicKey` via curl `--aws-sigv4` (IAM accepts RSA, not ed25519, so Cipi mints a 4096-bit `id_rsa` beside the usual deploy key) and writes `~/.ssh/config` so the SSH Key ID is the username (`Host git-codecommit.*.amazonaws.com`). IAM allows five SSH keys per user.
- **Webhooks.** Bitbucket Cloud: `repo:push` + HMAC `secret` (same token `cipi/agent` already verifies). Azure DevOps: service hook `git.push` with `X-Gitlab-Token` so the existing GitLab header check accepts it. Origin Apps have a single Ed25519-signed webhook, not a per-repo HMAC URL — skipped, deploy with `cipi deploy`. CodeCommit has no HTTP webhook (SNS/EventBridge only) — same.
- **Known hosts.** New apps keyscan `bitbucket.org`, `origin.cursor.com`, `ssh.dev.azure.com`, and the host of the repository URL, not only `github.com` / `gitlab.com`.
- **CrowdSec.** Bitbucket Cloud webhook egress CIDRs from `ip-ranges.atlassian.com` (product `bitbucket`, direction `egress`), fail-open like GitHub's `api.github.com/meta`. Azure / Origin webhook IPs are not a small published list — `cipi crowdsec allow` if a delivery is banned.
- **IDs in `apps.json`.** Bitbucket hook UUIDs and Azure / Origin / CodeCommit string IDs are stored as strings. Numeric GitHub/GitLab IDs stay numbers.

### Added — manual stack upgrades (nginx, MariaDB, PostgreSQL, Valkey)

- **These four stay off `unattended-upgrades` on purpose** — a MariaDB restart is not a 4am surprise. PHP already has `cipi php upgrade` (Sunday 03:30). There is now an operator-facing equivalent for the rest of the blacklisted stack, still **manual, still patch-level only**:
  - **`cipi nginx upgrade [--yes]`** — `apt --only-upgrade` of installed `nginx*` from the nginx.org mainline repo Cipi already configured, `nginx -t`, then reload. `/etc/nginx/nginx.conf` is kept (`--force-confold`); this is not the HTTP/2-bomb rewrite.
  - **`cipi db upgrade [mariadb|pgsql] [--yes]`** — same for MariaDB / PostgreSQL. No engine argument upgrades every installed engine. The prompt says there will be brief downtime.
  - **`cipi service upgrade [nginx|mariadb|postgresql|valkey] [--yes]`** — the generic entry, and the home for Valkey. No name lists installed versions against the current apt candidate. **`all` is refused** (that is what the blacklist exists to prevent). `php` is pointed at `cipi php upgrade`.
- **Shared helper `lib/stack-upgrade.sh`.** Scoped package patterns (`^nginx(-|$)`, `^mariadb-`, `^postgresql`, `^valkey`) so a loose match cannot drag PHP in. Re-asserts the nginx.org / MariaDB.org repos if they were wiped. Lock file `/run/cipi-stack-upgrade.lock`. Mail on success: `nginx_upgrade`, `mariadb_upgrade`, `pgsql_upgrade`, `valkey_upgrade`.
- **Not on a cron, not on the panel.** `setup.sh` / `self-update` do not run these. `/etc/sudoers.d/cipi-api` does not grant them — same rule as `cipi package install`.

### Fixed — `cipi.yml` was a public URL on custom apps

- **A custom app's `cipi.yml` was downloadable.** Custom apps serve `htdocs/` (or a subdirectory) as the nginx document root, so a committed `cipi.yml` answered at `https://domain/cipi.yml`. Every app vhost now denies `/cipi.yml` and `/cipi.yaml` at any path — Laravel included, in case the file is copied into `public/`. Existing servers get the location on update, without regenerating the vhost (certbot's `:443` block is left alone). `cipi yml` also looks for the file in `htdocs/`, which is where a custom app's repository actually lives.

### Added — `deploy.post` in `cipi.yml`

- **`deploy.post` — post-deploy steps that travel with the code.** After every successful deploy, Cipi can run a declared list of allowlisted commands from the live release directory — on both **`cipi deploy`** and the **Git webhook**. Unlike aliases, workers and the rest of the file, this section does **not** require `cipi yml auto <app> on`: commit `deploy.post` in the repository and the steps run as soon as the release is live.
- **Syntax.** Plain strings or structured maps; see `cipi yml example <app>` for a commented template:

  ```yaml
  deploy:
    post:
      - artisan cache:clear
      - artisan scout:import --force
      - npm run build
      - composer dump-autoload -o
      - php scripts/post-deploy.php
      - node scripts/warm-cache.mjs
    # post_on_failure: abort   # default warn
  ```

  Structured form (same allowlist, useful for explicit arguments):

  ```yaml
  deploy:
    post:
      - run: artisan
        command: scout:import
        args: [--force]
      - run: npm
        args: [run, build]
      - artisan: view:cache
  ```

- **Allowlisted runners only** — no free shell. Supported: **`artisan`** (`cache:clear`, `migrate --force`, …), **`npm` / `npx` / `yarn` / `pnpm`** (`run build`, `ci`, …), **`composer`** (`dump-autoload -o`, …), **`php` / `node`** (one relative script path under the release, e.g. `scripts/warm.mjs`). Rejected: unknown runners, `bash`, pipes, `;`, `..` in paths, `artisan tinker`, and other interactive subcommands (same spirit as `cipi app run`).
- **When it runs** — after Deployer finishes (migrate, symlink, worker restart, …), then optional **`cipi yml apply`** (only if auto-apply is on), then **`deploy.post`**, then the **post-deploy healthcheck**, then the success notification.
- **`deploy.post_on_failure: warn|abort`.** Default **`warn`**: log + email (`yml_post_fail`), release stays live. **`abort`**: post-deploy exits non-zero and **`cipi deploy`** fails too — for CI when e.g. `npm run build` must pass.
- **`cipi yml post-deploy <app>`** — run the declared steps now against `current/` (for testing). **`cipi yml plan`** lists them under **After deploy** (informational; they are not server state to reconcile).

## [5.2.2] — 2026-09-09

Two opt-in additions: Meilisearch for Laravel Scout, and an allowlisted `cipi package` for the host binaries a project sometimes needs. Neither is in the default stack, neither is installed by `setup.sh` or `cipi self-update`, and nothing on an existing server changes until someone asks for it.

### Added — `cipi package`

- **`cipi package list | install <name> | remove <name>`.** Installs host tools a Laravel project may need — image optimisers, ffmpeg, the ImageMagick CLI, `pdftotext` — from Ubuntu's own repositories. **The allowlist is the feature**: without it the command is a root apt shell with extra steps. The catalog is closed and every entry has to earn its place — a *stateless binary from an Ubuntu repo* (no daemon, no port, no credentials, no state outliving the process) with a real Laravel package behind it. Anything failing that is not a package but a service, and belongs to `cipi search`, `cipi db install` or the container branch. This is the same rule that put Meilisearch on the other side of the line, written down once.
  - `image-optimizers` → `jpegoptim optipng pngquant gifsicle webp`, exactly the set `spatie/laravel-image-optimizer` documents.
  - `ffmpeg` → `pbmedia/laravel-ffmpeg`. The install prints the warning that matters: run it from a queue worker, never from a web request — the FPM pool is `request_terminate_timeout = 300` and one ffmpeg will take every core on a box shared with MariaDB.
  - `imagemagick` → the `convert`/`magick` CLI. **This is genuinely missing today:** `php8.5-imagick` depends on `libmagickcore`/`libmagickwand` and, through them, on `imagemagick-6-common` (config files only). The binaries live in `imagemagick-6.q16`, which nothing in the chain pulls — so PHP-side Imagick works while `exec('convert …')` does not.
  - `poppler-utils` → `pdftotext`, for `spatie/pdf-to-text` and for feeding PDF content to the Scout indexes above.
  - A single package inside a group is accepted as a name of its own, so `cipi package install webp` works alongside `install image-optimizers`.
- **`install` shows what apt intends to do before doing it** — package count and disk delta, read from `apt-get install -s` on the machine rather than from a number hardcoded here — then asks. Afterwards it verifies each expected binary is on `PATH` and names any that is not, instead of letting the application discover it.
- **`remove` purges only the packages actually present** (naming an absent one turns a no-op into an apt failure), then previews the orphaned dependencies `autoremove` would take and asks before running it — server-wide autoremove on a box that also runs MariaDB and PHP is not something to do silently.
- **Two notification triggers** under a new **Packages** category: `package_install`, `package_remove`. The panel sudoers file allows `package list` only: installing packages as root stays with the operator on the CLI.

### Notes — `cipi package`

- **Chromium is deliberately not in the allowlist, and the refusal says why.** On Ubuntu 24.04 there is no `chromium` deb at all, and `chromium-browser` is a 48 kB transitional package whose dependencies are `debconf` and **`snapd` — "Daemon and tooling that enable snap packages"**. Installing it would add a daemon and a snap that updates itself outside apt's control, which is precisely what this command exists not to do. For `spatie/browsershot`, use Puppeteer's own Chromium (Node 20 is already installed) or Google's apt repository — both deliberate choices, not a side effect of an allowlist entry.
- **Ghostscript and `fonts-dejavu-core` are already installed** and are not in the list: they arrive as *Recommends* of `php-imagick`, and `setup.sh` passes no `--no-install-recommends`.
- **PDF through ImageMagick will still fail after installing it**, and not for a missing package: `imagemagick-6-common` ships `/etc/ImageMagick-6/policy.xml` with the PDF/PS/EPS coders disabled (the Ghostscript CVEs). That file exists on every Cipi server. `pdftotext` is not affected by the policy, which is part of why `poppler-utils` earned a place.

### Added — `cipi search`

- **`cipi search`** — a self-hosted search engine for Scout, wired the way the rest of Cipi is: **native, not a container**. Meilisearch is a single static Rust binary with no runtime dependencies, so it installs as a binary, a config file and a systemd unit alongside Nginx/PHP-FPM/MariaDB/Valkey. Engines that need a runtime around them (Elasticsearch, Typesense, Qdrant) belong in the container branch; this one does not, and that is the line. For a Laravel app it is `cipi search enable <app>` plus a `scout:import` — no Algolia account, no per-record billing.
  - **`cipi search install [--version=] [--port=] [--force]`.** Downloads the release binary for this architecture from GitHub (amd64/aarch64), creates the `meilisearch` system user, `/var/lib/meilisearch` (0750), `/etc/meilisearch.toml` and a hardened unit, then waits on `GET /health` before claiming success. Listens on **127.0.0.1** only — never a public address, so there is no firewall hole to open and no TLS to terminate. Meilisearch publishes no checksum beside its binaries, so the download is verified the only way available: it is executed and asked for its version before it is allowed to replace anything.
  - **`cipi search enable <app>`.** Mints an API key scoped to the index pattern `<app>-*` with exactly the actions Scout calls (`search`, `documents.*`, `indexes.*`, `settings.get`, `settings.update`, `tasks.get`, `stats.get` — **not** `keys.*`), then writes `SCOUT_DRIVER`, `SCOUT_PREFIX=<app>-`, `MEILISEARCH_HOST` and `MEILISEARCH_KEY` into `shared/.env`. The previous `SCOUT_DRIVER` is recorded so `disable` can put it back.
  - **`cipi search disable <app> [--purge-indexes]`**, **`list`**, **`status [--check] [--json]`**, **`key show <app>`**.
  - **`cipi search key rotate <app>`** and **`cipi search key rotate --master`**.
  - **`cipi search upgrade [--version=] [--reset-data] [--yes]`** and **`cipi search remove [--keep-data]`**.
- **Isolation is the design, not a note in the docs.** Meilisearch has no databases and no per-tenant separation, so one shared instance needs an explicit boundary. Cipi's is the index prefix, and **Cipi writes it — the operator does not choose it**: two apps that pick the same index name are not separated by a key pattern. It holds because a Cipi app username is `^[a-z][a-z0-9]{2,31}$` with **no hyphens**, so `blog-` can never be a prefix of `blogs-` or the reverse, and every index name belongs to exactly one app. An app that ignores `SCOUT_PREFIX` does not collide with its neighbour — it gets a 403. `enable` still asserts the non-overlap before minting a key.
- **The master key never reaches an app, an argument list, or a config file.** It lives in the vault (`/etc/cipi/search.json`) and in `/etc/cipi/meilisearch.env`, mode **0600 root:root**, read by systemd as root *before* the unit drops to the `meilisearch` user. `--master-key` on an `ExecStart` line would put it in `/proc/<pid>/cmdline`, which every app user on the box can read — the same reason `cipi search`'s own HTTP calls pass the `Authorization` header to curl through a stdin config file instead of `-H`.
- **`cipi app delete` revokes the app's key and drops its indexes.** The engine knows nothing about `apps.json`: without this, deleting an app left a live, working API key behind for a Unix user and a home that no longer exist.
- **`cipi app clone` gives the clone its own key and prefix.** The source's `MEILISEARCH_*` and `SCOUT_PREFIX` are excluded from the copied `.env` for a sharper reason than the Reverb exclusion next to it: the source's key is valid for the *source's* prefix, so a clone that inherited it would not fail — it would reindex straight into production's indexes.
- **Meilisearch appears in `cipi status`, `cipi service list|start|stop|restart` (`meilisearch`, or `search`) and shell completion**, but only where the unit exists.
- **Six notification triggers** under a new **Search** category: `search_install`, `search_enable`, `search_disable`, `search_key_rotate`, `search_upgrade`, `search_remove`.
- **The panel sudoers file** allows `search status|list|enable|disable`. `install`, `upgrade`, `key rotate` and `remove` are deliberately **not** in it: they change or destroy server state and stay with the operator on the CLI.

### Notes

- **Rotating the master key regenerates every API key on the server.** Meilisearch derives a key's value from its uid and the master key, so the uids survive and the values do not. `key rotate --master` therefore rewrites every enabled app's `.env` in the same run — otherwise the whole server loses search at once, silently, at the next master key change. It says which apps it is about to touch before it starts.
- **Upgrades are the real cost of this feature, and the command is built around that.** A Meilisearch store is readable only by the version that wrote it. `cipi search upgrade` asks the new binary which in-place upgrade flag it supports (`--upgrade-db` on current releases, `--experimental-dumpless-upgrade` on older ones) rather than guessing from a version number, applies it through a one-shot systemd drop-in, and then restarts **without** it to prove the unit still comes up on its own. If the engine refuses the store, the old binary is put back and the service restarted — nothing is dropped without an explicit answer. Only if you say so does it delete `data.ms`, reissue every app key (a wiped store has no keys, so every `.env` would otherwise be dead) and print the `scout:import` commands.
- **Meilisearch is not in `cipi backup` and that is deliberate.** A Scout index is derived data; `scout:import` rebuilds it from the database that *is* backed up. Adding it to S3 would mean paying to store a rebuildable artifact whose format is pinned to an engine version.
- **RAM.** `install` refuses below **512MB** MemAvailable (`--force` overrides) and warns below 1GB. Meilisearch memory-maps its LMDB store, so its RSS understates what it asks the kernel for; on a 1GB VPS already running MariaDB tuned to that RAM, an OOM kill is a real outcome and the kernel does not always pick Meilisearch.
- **You may not need it.** For a small dataset Scout's `database` driver — or Postgres full-text, already in the stack since 5.0 — needs no extra service, no extra memory and no upgrade path. `cipi search status` says so on a server where it is not installed.

---

## [5.2.1] — 2026-09-09

Recovery commands: re-sync GitHub/GitLab deploy keys and webhooks, and restore an app home to the permission model Cipi created it with.

### Added

- **`cipi git refresh [app]`.** Walks every app with a GitHub or GitLab repository (or one named app) and re-registers the local SSH deploy key plus the deploy webhook. Stale IDs in `apps.json` are replaced. Remote leftovers titled `cipi:<app>` or pointing at this app's webhook URL are removed first so duplicates are not left behind. Custom/SFTP apps get the key only. A missing or rejected PAT is reported per app (`cipi git github-token` / `gitlab-token` first). **`--rotate-keys`** mints a new ed25519 key and swaps it in `authorized_keys` (Deployer still SSHs to localhost with it). **`--rotate-secret`** mints a new `CIPI_WEBHOOK_TOKEN` in `apps.json` and `shared/.env`. Both ask before touching every app unless **`--force`**. If GitHub refuses the existing pubkey because it is already a deploy key on another repo, refresh generates a new key for that app and continues.
- **`cipi app fix-permissions [app]`.** The panel already had `cipi api fix-permissions` and `cipi gui fix-permissions`; apps did not. A blunt `chown -R app:app /home/<app>` is wrong: nginx writes vhost logs as `www-data` into `logs/` (2775 setgid), the home must stay **750** so `www-data` (in the app group) can read the docroot, `.ssh` must be **700** or OpenSSH StrictModes refuses the deploy key, and `shared/.env` is **640**. This command reapplies that layout — ownership of the tree except `logs/`, then the log/ACL helper, storage dirs **775**, Composer `auth.json` **640**, `cipi-databases.env` **600**. One named app, or every app. **No migration:** `self-update` copies the libs and refreshes shell completion. The panel sudoers file lists the new command so a future GUI can call it; existing servers pick that line up the next time sudoers is rewritten (the CLI runs as root and does not need it).

### Fixed

- **`self_update` mail on a same-version refresh.** The nightly cron always copies the libs even when `version.md` has not moved. The `self_update` email is now decided from a snapshot taken before `/etc/cipi/version` is rewritten, and is sent only when that snapshot differs from the downloaded version. A refresh that stays on the same release is silent.

### Notes

- Deploy keys and webhooks on GitHub/GitLab do not vanish when a PAT expires — they only become unmanageable via API. Refresh is for the case where they were deleted, the stored IDs drifted, or you just installed a new token and want every app re-attached.
- `cipi deploy` already runs the log-ACL helper before Deployer. `fix-permissions` is the full home, on demand, after someone unpacked a zip as root or chmod'd `.ssh` to 775.

---

## [5.2.0] — 2026-09-08

Opt-in CrowdSec (engine **and** a registered firewall bouncer) and a nightly integrity check. Neither is installed by `setup.sh` or `cipi self-update`. There is no WAF.

### Added

- **`cipi crowdsec enable`.** Installs the engine **and** `crowdsec-firewall-bouncer-nftables` (or `-iptables`) registered with `cscli bouncers add` — decisions without a bouncer ban nothing. Acquisition reads `/home/*/logs/nginx-{access,error}.log`, which is where every Cipi vhost actually logs; `/var/log/nginx` alone holds only the catch-all server block, so the nginx scenarios would never see application traffic. On Ubuntu 24.04 iptables is nft, so the bouncer matches fail2ban's `iptables-multiport`. enable refuses below **512MB** MemAvailable, refuses if nginx looks like a reverse proxy without `set_real_ip_from` + `real_ip_header` (would ban Cloudflare, not the attacker), and allowlists **this SSH session**. `disable` **flushes CrowdSec chains/tables, then purges**, so DROP rules cannot outlive `cscli`.
- **Rescue TLS listener.** enable starts a TLS server on a high port. The TLS handshake runs in the connection's own thread with a deadline, never in `accept()`: wrapping the listening socket lets one peer that opens a connection and sends nothing hold the break-glass path shut for as long as it likes. Concurrent connections are capped below the unit's `TasksMax`. One GET with a one-shot token allowlists the TCP peer (never `X-Forwarded-For`), unbans that IP in CrowdSec and fail2ban, mails a new token, and dies. Not a login, not an SSH key. UFW opens the port; an ACCEPT is punched at the head of the CrowdSec chain (and again on every bouncer restart) so a DROP-all ban cannot close it. `cipi crowdsec rescue token|rotate`. `status` shows the port and cert fingerprint, not the token.
- **Allowlists.** Localhost, RFC1918, Let's Encrypt HTTP-01. GitHub webhook CIDRs from `api.github.com/meta` **`.hooks`** (fail-open: a dead fetch keeps the previous file). GitLab.com egress CIDRs are hardcoded, dated **2026-09-07**, and documented as rotting.
- **`cipi ban list|unban`** includes CrowdSec when the engine is up.
- **`cipi scan`.** Nightly (04:40): **integrity** of `current/` (or `htdocs/`) against a sha256 manifest written at every successful deploy **and rollback**, then **one** ClamAV process on **upload dirs only** with rfxn PHP-webshell signatures. Manifests live in `/var/lib/cipi/manifests` as **root:root 0600**, never in the app home: `open_basedir` gives PHP all of `/home/<app>/`, so a manifest kept there is editable by the very webshell the check exists to catch. The webhook deploy runs as the app user and reaches the writer through one sudo entry pinned to its own app name, and **every re-baseline is written to `events.log`** — a manifest rewrite with no deploy beside it is the thing to look for. Comparison slices sha256sum records by offset instead of splitting on whitespace: names with spaces were truncated in the report, and GNU coreutils escapes records holding a backslash or a newline, which a hash-anchored filter dropped entirely (a webshell called `sh\ell.php` was invisible). Timeouts, failed signature updates and releases that could not be hashed in full mail **`scan_incomplete`** — not "clean". Extra/changed files mail **`scan_integrity`**. FPM `open_basedir` / pool-user drift is included in that mail. Isolation itself (per-app Unix user + `open_basedir`) was already Cipi; this only checks it is still there. `enable` refuses below **2GB** MemAvailable or 3GB free on `/var` (`--force` to override): clamscan loads the whole signature set per run, and an OOM kill at 04:40 may take MariaDB with it.
- **Shell tab-completion, installed automatically.** `setup.sh` and every `cipi self-update` write `/etc/bash_completion.d/cipi`, `/usr/share/zsh/vendor-completions/_cipi` (when that directory exists) and an `/etc/profile.d/cipi-completion.sh` loader that fires for every interactive bash and zsh shell — with or without the `bash-completion` package, which `setup.sh` now also installs. Nobody edits a dotfile; a new login shell has it. `cipi completion bash|zsh` is there only for a non-login shell or a custom rc file (`--print` emits the raw script and changes nothing). It completes the top-level verbs, each verb's sub-commands and flags, and `cipi help <topic>`; app names are filled in from `/etc/cipi/apps-public.json` when the shell's user can read it (a root session, or the `cipi-api` group), and everything else is a static word list that works for any user. `sudo cipi <TAB>` resolves through the stock sudo completion. Hand-written, not framework-generated: `tests/verify-5.2.0.sh` fails if the verb list drifts from the dispatch in `cipi`.
- **Migration 5.2.0.** Installs `cipi-scan-manifest` and the two rescue helpers, creates the manifest store, grants each existing app its manifest sudo entry, and adds `SSH_CLIENT` / `SSH_CONNECTION` to `env_keep` in `/etc/sudoers.d/cipi-sudo`. The helper install is not optional housekeeping: `self-update` never re-execs, so the copy loop running during the upgrade is the *pre-5.2.0* one and knows nothing about the new binaries — without this, `crowdsec enable` refuses to start the rescue listener and no deploy ever refreshes a manifest. `crowdsec enable` allowlists the session it is typed from, and `setup.sh` sets `PermitRootLogin no` — so the normal path is `sudo cipi`, and sudo's `env_reset` was dropping the only variables that carry the operator's IP. The candidate file is validated with `visudo -c` before it replaces the live one. Nothing else is migrated: CrowdSec and the scan stay off.

### Notes

- CrowdSec is 24/7 after enable. The scan is the nightly job.
- `cipi status` lists CrowdSec, its bouncer and the rescue listener only when those units exist. A rescue listener that has stopped is the one thing you want to find before you need it, not after.
- The rescue listener runs as root (redeeming needs it) but with `NoNewPrivileges`, `ProtectHome=read-only`, `PrivateTmp` and a `MemoryHigh` cap. `ProtectSystem` and `SystemCallFilter` are deliberately left off — hardening that can break break-glass is worse than the surface it removes.
- The rescue throttle applies to wrong tokens only. A correct token is always honoured, whatever the peer typed before it.
- `cipi ban list` reads `.decisions[]` out of `cscli decisions list -o json`, which returns *alerts*. Reading `.value` at the top level printed a decision count and then no addresses at all. `cipi ban unban` asks before it claims success, because `cscli decisions delete` exits 0 whether it removed something or nothing.
- The integrity check tells you a tree changed between deploys. An attacker who owns the app user can still re-baseline through the sudo entry, so read `events.log` alongside the alert.
- Pre-symlink checkpoint and inotify on uploads are not this release.

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
