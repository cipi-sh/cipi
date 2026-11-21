<div align="center">

<img src="https://cipi.sh/favicon-light-192.png" width="64" height="64" alt="Cipi logo" />

# Cipi

**Easy Laravel Deployments**  
One command installs a complete production stack. One command deploys your app.<br>
No panel, no bloat — so you can focus on what you love: building your application.

[Website](https://cipi.sh) · [Docs](https://cipi.sh/docs) · [Report a bug](https://github.com/cipi-sh/cipi/issues)

<br>

<a href="https://cipi.sh/docs/gui">
  <picture>
    <source media="(prefers-color-scheme: light)" srcset="https://cipi.sh/img/gui/dashboard-light.webp">
    <img alt="Cipi control panel: dashboard with three connected servers" src="https://cipi.sh/img/gui/dashboard.webp" width="900">
  </picture>
</a>

<sub>The optional web GUI: one login for every Cipi server. The CLI does everything without it.</sub>

</div>

---

## What is Cipi?

Cipi turns any Ubuntu VPS into a **multi-app PHP hosting platform** — Laravel by default (PHP-FPM or optional **Octane/FrankenPHP**), with full isolation, zero-downtime deploys, SSL, queue workers, and S3 backups — all managed from a single CLI. Use **`--custom`** for simple sites: classic deploy (no releases/shared), configurable docroot and Nginx (try_files, entry point), no DB or cron.

No web panel. No bloat. No sleepless nights fighting Nginx configs or PHP-FPM pools.  
Just SSH and the `cipi` command.

```bash
wget -O - https://cipi.sh/setup.sh | bash
```

> Run this **on the server**, over SSH — not on your own machine — as a user with `sudo`.

> Works on DigitalOcean, AWS EC2, Hetzner, Vultr, Linode, OVH, Google Cloud, Scaleway, and more.

---

## From zero to production in 3 steps

**1. Install Cipi** on a fresh Ubuntu 24.04 or 26.04 VPS (~10 minutes).
SSH into the server first and run it there, as a user with `sudo`:

```bash
wget -O - https://cipi.sh/setup.sh | bash
```

The installer asks for the **public** half of an SSH key (`~/.ssh/id_ed25519.pub`
on your own machine; `ssh-keygen -t ed25519` creates one if you have none — on
Windows, from PowerShell or WSL), and for more keys if you have them. It shows
what it is about to set up and waits for a go. It ends with the credentials it
generated — root, MariaDB root, Valkey — one block each, and waits until you
confirm they are in your password manager; then it offers the panel API and the
web GUI as two yes/no questions. Root is reachable only by logging in as the
`cipi` user with that key and then running `su root`. Lost the summary?
`sudo cipi credentials` prints it again, and `cipi credentials export` writes it
as a CSV any password manager imports.

**2. Create your app** (Laravel by default, or `cipi app create --custom` for a simple deploy):

```bash
cipi app create
# a menu: Laravel (default) · custom · Node spa / static / ssr
# → Laravel: PHP-FPM or Octane, MariaDB or PostgreSQL, then username, domain,
#   git repo, branch, PHP version, optional asset build (npm ci && npm run build)
# → Custom: user, Nginx, PHP-FPM; Git optional (empty = SFTP-only to ~/htdocs)
# The deploy key is tested against the repository before you leave the wizard;
# if it cannot read it, Cipi offers to save the forge token and adds the key.
```

**3. Deploy and go live:**

```bash
cipi deploy myapp
cipi ssl install myapp
```

That's it. Your Laravel app is live.

---

## Stack

Every app gets a fully isolated environment. **Laravel** (default): zero-downtime deploy, DB, workers, cron, webhook — optionally **Octane (FrankenPHP)** instead of PHP-FPM. **`--custom`**: classic deploy into `htdocs`, configurable docroot only; Nginx uses `index index.html index.php`, `try_files $uri $uri/ /index.php?$args`, `error_page 404 /404.html`. No DB, no .env, no cron, no workers.

| Component          | Details                                                                                                      |
| ------------------ | ------------------------------------------------------------------------------------------------------------ |
| **Web server**     | Nginx reverse proxy with per-app virtual hosts — PHP-FPM or Octane (`proxy_pass`), optimized for Laravel     |
| **PHP & Composer** | Selectable per app — PHP 8.3 to 8.6, hot-swappable; a new server is installed with 8.6                       |
| **Runtime**        | PHP-FPM pools by default; optional **Laravel Octane (FrankenPHP)** per app (`--octane`), its FrankenPHP build pinned per app (`cipi frankenphp`); PHP JIT per app (`cipi app jit`) |
| **Database**       | MariaDB (default) + optional PostgreSQL; dedicated DB and user per Laravel app                               |
| **Search**         | Optional **Meilisearch** for Laravel Scout — native binary, loopback only, per-app scoped key + index prefix  |
| **Queue workers**  | Supervisor with per-app pools — `queue:work` or **Horizon**; optional **Reverb** for WebSockets (wss:// + credentials + fd limits) |
| **Deployments**    | Deployer 8 (8.0.5, pinned from its GitHub release, SHA-256 checked) — Laravel: atomic symlink, 5 releases, rollback, optional Node build; Custom: clone into htdocs |
| **SSL**            | Let's Encrypt via Certbot — HTTP-01 by default; optional **DNS-01 (Cloudflare)** + wildcards                 |
| **Security**       | Fail2ban + UFW, optional CrowdSec (firewall bouncer), optional **Cloudflare Zero Trust** (`cipi zt`: tunnel, Access, origin dark), and nightly integrity/upload scan, per-app Linux user + PHP-FPM/Octane + SSH key |
| **Healthchecks**   | HTTP probes every 5 minutes, plus a post-deploy check with optional automatic rollback of a broken release    |
| **Backups**        | Backup profiles: what, how often, where, how long — S3/S3-compatible/local, client-side encryption           |
| **Frontends**      | Node apps: SPA and static sites served by nginx, SSR (Next, Nuxt, SvelteKit, Astro, Remix) with blue/green deploys, per-app Node version |
| **Notifications**  | `cipi notification`: SMTP, Resend, Amazon SES, Slack, Discord, Mattermost, Google Chat, Telegram, ntfy, Pushover, signed webhooks — every trigger to every channel |
| **Configuration**  | `cipi ini` for php.ini; optional per-project `cipi.yml` for aliases, www, basic auth, redirects and proxies, search, databases, workers, Reverb, limits, deploy recipe, forced HTTPS, required .env names, scheduled commands, backups and post-deploy steps  |

---

## Features

### 🔒 Security & Isolation by Design

Each app runs under its own Linux user with an isolated filesystem, PHP-FPM pool (or Octane process), and database. A compromise in one app cannot touch the others. Configs are encrypted at rest with AES-256 (Vault). GDPR-compliant log rotation included. Per-app **resource limits** (`cipi app limits`) cap FPM children, memory, Octane workers, and queue processes. `cipi app fix-permissions` restores that layout if a deploy or a zip-as-root left the home unreadable.

**Brute-force protection is on from the first boot.** UFW denies all inbound traffic except SSH, HTTP and HTTPS, and fail2ban bans the addresses that keep failing SSH logins. These are the defaults:

| Setting                        | Default                                              |
| ------------------------------ | ---------------------------------------------------- |
| Failed SSH logins before a ban | **3**                                                |
| Counted over                   | 1 hour                                               |
| Ban                            | 24 hours, longer for each repeat, up to 7 days       |
| Repeat offenders               | 3 bans in 24 hours → banned for 7 days               |

The number of failed logins can be changed; the rest stays as above:

```bash
cipi firewall attempts            # current threshold, counting window and ban time
cipi firewall attempts 5          # ban after 5 failed SSH logins (1–100)
cipi firewall attempts default    # back to 3
cipi ban list                     # who is banned right now
cipi ban unban <IP>
```

The new value is checked with `fail2ban-client -t` and then applied with a fail2ban reload; a configuration fail2ban refuses is rolled back. It is stored in `/etc/fail2ban/jail.d/cipi-attempts.local`, so Cipi updates do not reset it.

**App users and SSH.** Every app has its own Linux user. The server's SSH keys — the ones you manage with `cipi ssh list|add|remove` — open a shell as any app user, so whoever administers the server never needs an app's password: `ssh shop@server`. What an app accepts *besides* those keys is a switch, per app or for all of them:

```bash
cipi ssh apps                     # every app user: access enabled or disabled
cipi ssh apps disable shop        # from outside: the server's keys, nothing else
cipi ssh apps enable shop         # also its password (SSH and SFTP) and its own keys
cipi ssh apps disable --all       # every app user, and the apps created from now on
cipi ssh apps enable --all        # everyone back, whatever the single settings were
cipi ssh apps sync                # rewrite Cipi's section of sshd_config
```

Disabled means no password and no `~/.ssh/authorized_keys` from another machine — only the server's keys, read by sshd at every login (remove a key with `cipi ssh remove` and it stops working for the apps in the same moment). Deploys are not affected: Deployer reaches the app user over `ssh localhost`, which stays as it was. The `cipi` user is never touched by these commands. A new server starts with access disabled for new apps.

**One Valkey per app.** A new Laravel app gets a Valkey instance of its own — `cipi-valkey@<app>`, running as the app's user on its own localhost port, with its own password and data directory — so no other app on the server can read its cache, its sessions or its queues. Apps created before 5.9.0 keep the server's shared instance until you move them:

```bash
cipi valkey list                  # which app uses which instance
cipi valkey isolate shop          # its own instance: keys copied, .env switched, workers restarted
cipi valkey isolate --all         # every app still on the shared one
cipi valkey share shop            # back to the shared instance
cipi valkey flush-shared          # once nobody uses it: empty it and change its password
```

`isolate` puts the app in maintenance mode for the seconds the copy takes, so nothing is written on the side it is leaving; `--no-copy` moves it empty, without maintenance mode. An idle instance costs about 10 MB of RAM; `cipi app create --valkey=shared` keeps the old behaviour for one app.

Optional, off until you turn them on — `setup.sh` / `self-update` never install them:

```bash
cipi crowdsec enable    # IP reputation → firewall bouncer (not a WAF)
                        # includes a TLS rescue URL: one GET allowlists your IP
cipi zt enable          # Cloudflare Zero Trust: tunnel + real_ip, ports stay open
                        # then hostname / Access / lock http / lock ssh as you choose
cipi scan enable        # nightly: release integrity + ClamAV on uploads
```

Ubuntu security updates land daily via `unattended-upgrades`. PHP patch releases are applied every night at 03:30 by `cipi php upgrade`, which restarts PHP-FPM after an upgrade and reports each version's security patch level. The mitigations of the 2026-10-21 PHP advisory (`session.upload_progress.enabled`, `fatal_error_backtraces`) are in every FPM pool, in each version's `fpm/conf.d/99-cipi.ini` and in the ini Octane apps load. **Nginx, MariaDB, PostgreSQL and Valkey are left alone until you ask** — restarting a database at 04:00 is not a surprise Cipi will create:

The rest of the stack — nginx (nginx.org), MariaDB, PostgreSQL, Valkey, the Node.js runtimes, Composer and the FrankenPHP builds of Octane apps — is patched every night at 04:20 by `cipi autoupdate`: patch releases only (`apt --only-upgrade` of what is already installed), Cipi's configuration kept, nginx tested before it is reloaded — and restarted when the binary from before the upgrade is still the one in memory —, one component after the other and the databases last. A database is left for the next night while a dump or a deploy is running. Each upgrade is mailed like any other event.

```bash
cipi autoupdate                    # what is on, how the last run went
cipi autoupdate off mariadb        # patch this one by hand
cipi autoupdate on                 # everything back on
cipi autoupdate run nginx          # now

cipi nginx upgrade                 # the same, by hand: asks first
cipi nginx security                # patch level, running binary, HTTP/2 exposure
cipi db upgrade                    # MariaDB, and PostgreSQL if installed
cipi service upgrade valkey
```

What no update can do by itself is restart the server: a new kernel is installed by `unattended-upgrades` and does nothing until the next boot. Cipi tells you, and leaves the decision to you:

```bash
cipi pending                       # what is waiting: a reboot, a patch, a warning
cipi reboot                        # is one required, since when, which kernel
cipi reboot now                    # restart in one minute
cipi reboot auto on --at=04:45     # restart at night, only on the nights one is required
cipi reboot auto off
```

`cipi pending` is checked every morning and mailed when the list changes (and again after a week, while it lasts); `cipi status` shows the same list when there is one. Besides a reboot it names PHP below its security release (or still a release candidate, or installed before its extensions were packaged), nginx below its own, on the Ubuntu archive's build or upgraded on disk but not in memory, a component whose automatic update is off or failed, Composer and Node.js below theirs, apps that still share one Valkey, and PHP extensions installed with PECL — Cipi installs extensions from apt only, nothing updates the ones built by hand, and PECL itself is deprecated by the PHP project in favour of [PIE](https://github.com/php/pie).

### ⚡ Zero-Downtime Deploys

Deployer clones your repo, runs `composer install`, links storage, runs migrations, and swaps the symlink atomically. Optional **Node build** on deploy (`cipi app edit --node-build=…`). Roll back to any of the last 5 releases instantly. Opt-in **pre-deploy DB snapshot** (`cipi deploy --snapshot`). `cipi deploy <app> --releases` lists the releases with their commit and how long each deploy took. `cipi deploy <app> --status` says whether a deploy is running right now — whoever started it, a Git push included — and how the last one ended (`--json` for scripts and the panel). `cipi deploy <app> --history` lists the past deploys with their result and duration, from the rotated deploy logs too, and `cipi deploy --last` shows every app's last one.

Every deploy is recorded in a root-owned, hash-chained **audit ledger** (`/var/log/cipi/deploys.jsonl`, also sent to syslog), whatever started it: `cipi deploy`, the Git webhook, cipi/agent, the panel, or `dep deploy` run by hand. Each record has the release, the commit, and who started the deploy, read by root from the process chain: origin, login user and SSH address. `cipi deploy <app> --audit` shows it.

### 💾 Backups That Match How You Actually Work

Backups are driven by **profiles**: each one decides what it takes (application
files, databases, or both), which apps and databases it covers, how often it
runs, where it lands and how long it is kept. A 30-minute database-only copy
kept on disk sits happily next to a nightly full copy encrypted to S3.
Removing a profile keeps its archives until retention ages them out;
`cipi backup profile remove <name> --purge` deletes them now, on every
destination (on a terminal, the question is asked).

```bash
cipi backup profile add hourly-db --scope=db \
    --databases='shop,tenant_*' --exclude-tables='*.jobs,*.telescope_*' \
    --every=30m --keep=48 --dest=local

cipi backup profile add nightly --scope=all \
    --cron='0 2 * * *' --keep-days=14 --dest=s3 --encrypt
```

`cipi backup configure` sets the default bucket (`s3` in a profile) and any
number of further buckets are **named destinations** with their own keys —
another provider, another region, a customer's own account:

```bash
cipi backup destination add offsite --bucket=acme-backups \
    --key=... --secret=... --endpoint=https://eu-central-1.your-objectstorage.com
cipi backup profile edit nightly --dest=local,s3,offsite
```

Databases are discovered from the engine, so tenant databases an app creates at
runtime are backed up too. The schedule is written to root's crontab for you.
`cipi backup verify` checks the newest run actually opens, and an overdue
profile raises an alert — a backup that quietly stopped running is worse than
none, because it still looks configured.

### 📄 cipi.yml — Configuration That Travels With the Code

An app can carry a `cipi.yml` in its repository describing the state it expects:
domain aliases, the www redirect, HTTP basic auth, redirects and prefix proxies,
Meilisearch for Scout, PHP version, settings and limits, its extra databases, its queue workers, its healthcheck,
its deploy recipe options (`keep_releases`, the artisan hooks, `predeploy_snapshot`,
and `node_build` — the asset build, which runs before the release goes live),
the forced HTTPS redirect, the `.env` variables it requires (names
only, never values), its scheduled commands (`crons`),
its backup strategy, and **post-deploy steps** (`deploy.post`).
`cipi yml plan` shows exactly what would change and `cipi yml apply` applies it.

**One repository, several apps.** Every app has an environment label
(`cipi app create --env=staging`, default `production`; `cipi app edit --env`
changes it, `cipi app clone --env=staging` names the copy) and reads
`cipi-<env>.yml` before `cipi.yml`. A staging app and a production app
deployed from the same repository each find their own file; a `cipi-<env>.yml`
that is invalid is an error, never a fall back on `cipi.yml`. The label goes
into `.env` as `APP_ENV` and `CIPI_ENV`. `deploy.branch` says which git branch
the app deploys, so the pair is typically `cipi-staging.yml` with
`branch: develop` and `cipi.yml` with `branch: main`.

Server reconciliation (aliases, PHP, workers, databases, …) is **opt-in**:
`cipi yml auto <app> on` makes every successful deploy run `cipi yml apply`
(from `cipi deploy`, the panel or the Git webhook). A release without the file is a no-op.
`cipi yml auto <app> status` says whether it is on and which file is in use.

**The same over the API.** With [cipi/api](https://github.com/cipi-sh/api) 1.35+ on the server (Cipi 5.6.4+ for the sudoers entry), `GET /api/apps/{name}/yml` returns `cipi yml plan <app> --json` (the file, auto-apply on or off, what would change, what blocks it), `POST /api/apps/{name}/yml/apply` runs `cipi yml apply` as a job, and `POST /api/apps/{name}/yml/auto/enable|disable` turn auto-apply on and off — token abilities `yml-view` and `yml-manage`. `cipi-cli yml`, the GUI's app → cipi.yml tab, the PHP SDK, Cipi Studio and the MCP tools `AppYmlShow` / `AppYmlApply` / `AppYmlAuto` use them.

**`deploy.post` is different** — it runs after every successful deploy as soon
as the section is in the committed file, with no auto switch, and only once
the release is already live. It is not where the asset build goes. Steps use
allowlisted runners only (`artisan`, `npm`, `composer`, `php`, `node`, …); no
shell, no pipes. After Deployer, optional `cipi yml apply`, then `deploy.post`,
then the post-deploy healthcheck.

```yaml
deploy:
  node_build: "npm ci && npm run build"   # before the release goes live
  # post:
  #   - artisan cache:clear               # after the release is live
  # post_on_failure: abort   # default warn — log + email, release stays live
```

```yaml
app:
  www: to-root                 # www → apex
  basic_auth:
    users: [admin]             # keeps the password set on the server
  limits:
    memory_limit: 512M         # cipi app limits, same bounds as the CLI
redirects:
  - from: /blog/
    to: "https://blog.example.com/"
proxies:
  - prefix: /api/
    upstream: "http://127.0.0.1:3000"
    strip_prefix: true
ssl:
  force_https: true            # needs a certificate; only ever turned on here
env:
  required: [STRIPE_KEY]       # names the .env must carry — plan blocks if missing
crons:
  - every: 30m                 # same allowlisted runners as deploy.post
    run: artisan queue:prune-batches
deploy:
  branch: main                 # the git branch to deploy (cipi app edit --branch)
  keep_releases: 3             # cipi app deploy-config, from the repository
  migrate: false
  predeploy_snapshot: true     # DB snapshot before each deploy
  node_build: "npm ci && npm run build"
```

```bash
cipi yml generate myapp --save       # writes /home/myapp/cipi.yml (cipi-<env>.yml for a non-production app)
cipi yml generate myapp > cipi.yml   # or print it
cipi yml example myapp > cipi.yml    # or a commented template
cipi yml plan myapp                  # server diff + "After deploy" steps
cipi yml post-deploy myapp           # run deploy.post now (test)
```

It can only *configure* an app that already exists, its databases must be named
`<app>` or `<app>_*`, its backup profiles `<app>` or `<app>-*`, and its
healthcheck URL one of the app's own domains — so a commit can never reach
beyond its own app. Passwords never go in the file: a basic auth user listed by
name keeps the password already on the server, and only bcrypt or SHA-512 crypt
hashes are accepted. Proxies declared in the file cannot publish Cipi's own local
services (databases, Valkey, another app's Octane/Reverb) or link-local and cloud
metadata addresses, even through a hostname that resolves to one. `crons` entries
go through the same allowlisted runners as `deploy.post` — never a free-form
shell line — and only replace the crontab entries the file manages, tagged
`# cipi-yml`. `app.limits` values outside the CLI's bounds block the plan instead
of being clamped, and `ssl.force_https` can only ever be turned on from the file.
A `backup:` section is the list of profiles this file owns: one it no longer
names is removed from the schedule (the archives stay until `cipi backup prune`).
A profile added with `cipi backup profile add` is not touched unless the file
names it. `deploy.snapshot` is still read; the name to write is `predeploy_snapshot`.

### ⚛️ Node Frontends: SPA, Static and SSR

React, Vue, Svelte, Next.js, Nuxt, SvelteKit, Astro and Remix get the same flow as Laravel: git push, releases, rollback, webhooks, SSL, basic auth, redirects, audit ledger.

```bash
cipi app create --user=shop --domain=shop.com --repository=git@github.com:acme/shop.git --framework=next
cipi app create --user=docs --domain=docs.com --repository=git@github.com:acme/docs.git --node=static --output=dist
cipi app create --user=dash --domain=dash.com --repository=git@github.com:acme/dash.git --framework=vite
```

- **`spa`**: built on deploy and served by nginx. Unknown paths fall back to `index.html`, fingerprinted assets are cached as immutable, HTML is revalidated.
- **`static`**: pre-rendered output (Astro, `nuxt generate`, Next `output: 'export'`) with real 404s.
- **`ssr`**: a Node server on localhost behind nginx, with **blue/green deploys**. The new release starts on the idle slot and must answer on its health path before nginx switches to it; the old process stops only after that. A release that never comes up fails the deploy and the old one keeps serving. `cipi node restart <app>` uses the same switch.

Dependencies are installed exactly as locked (`npm ci`, pnpm, yarn or bun, detected from the lockfile), and the build runs with `NODE_ENV=production`. `shared/.env` is linked into every release, so it works for build-time variables (`VITE_*`, `NEXT_PUBLIC_*`) and runtime secrets alike. Presets (`--framework=next|nuxt|sveltekit|astro|remix|vite`) fill in the mode, build, start command and output folder; `--build`, `--start`, `--output` and `--health-path` override them.

**Node per app, from nodejs.org.** `--node-version=22|24` installs the official build into `/opt/cipi/node/<major>`, verified against the release's SHA-256 list, with corepack for pnpm and yarn. Apps on different majors run side by side. `cipi node upgrade --restart` moves every app to the latest patch with no downtime.

**Laravel apps too.** `cipi node default 24` makes that major the server-wide Node for Laravel asset builds (`--node-build`), `cipi app run npm` and `cipi.yml` post-deploy steps, overriding the system Node from NodeSource without uninstalling it (`cipi node default system` goes back). One app that needs something else keeps its own: `cipi app edit legacy --node-version=22`.

The same settings can live in the repository as a `node:` section of `cipi.yml` (`framework`, `mode`, `version`, `build`, `start`, `output`, `health_path`). With `cipi yml auto <app> on`, each deploy reads them from the commit being deployed, before the build, so a change ships together with the code that needs it.

Git webhooks work without cipi/agent: Cipi verifies GitHub/Bitbucket HMAC signatures and GitLab/Azure tokens itself, in a PHP pool that can do nothing but queue the app's own deploy. The start command runs as an argument list, never through a shell. `.env` is read as data, not sourced, and the server binds to 127.0.0.1 on a port Cipi assigns.

### 🚀 Laravel Octane (FrankenPHP)

Serve Laravel via Octane instead of PHP-FPM — same server, side by side with classic apps:

```bash
cipi app create --octane
cipi app convert myapp --to=octane   # or --to=fpm
```

Nginx proxies to a localhost Octane port; Supervisor runs `${app}-octane`. Requires `laravel/octane` in the app repo (starts after the first successful deploy). FrankenPHP gets the same PHP hardening as the FPM pools (`session.upload_progress.enabled` and `fatal_error_backtraces` off), from `/etc/php/cipi-octane.d` through `PHP_INI_SCAN_DIR`.

**The FrankenPHP binary is Cipi's, not a download at every deploy.** An Octane app answers on the PHP built into its FrankenPHP binary, which apt never patches. Cipi keeps the builds in `/opt/cipi-frankenphp` (root's, read-only to the apps) and pins one per app; each deploy links the pinned build into the new release, so Octane downloads nothing and the PHP an app answers on changes only when you say so. Different apps can run builds on different PHP minors side by side — 8.5 and 8.6 on the same server.

```bash
cipi frankenphp                       # each app's build, the PHP inside, patched or not
cipi frankenphp upgrade myapp         # newest build on myapp's PHP minor; restart, check, back if it does not answer
cipi frankenphp upgrade --all
cipi frankenphp use myapp <build>     # pin a given build
cipi frankenphp import ./frankenphp   # a build made elsewhere: another PHP minor than GitHub's
cipi autoupdate off frankenphp        # no nightly patch builds
```

`upgrade` (and the nightly `cipi autoupdate`) never moves an app to another PHP minor or FrankenPHP major: a release on PHP 8.6 is announced to an app on 8.5, once, and applied when you move the app (`cipi app edit myapp --php=8.6`, then `cipi frankenphp upgrade myapp`). GitHub publishes static binaries for one PHP minor at a time; to keep an app on an older minor with its patches, build FrankenPHP on it ([static builder](https://frankenphp.dev/docs/static/)) and `import` it. A deploy whose `laravel/octane` asks for a newer FrankenPHP than the pinned build stops before the release goes live, instead of letting Octane replace the binary. `cipi php upgrade` and `cipi pending` report the PHP inside each build.

### 🔥 JIT, per app

```bash
cipi app jit myapp on                       # tracing, 128M buffer
cipi app jit myapp on --mode=function --buffer=256M
cipi app jit myapp off
cipi app jit myapp --json
```

PHP-FPM or Octane. Before anything is written, the PHP that will run the app is asked to start with JIT the same way (an extension such as Xdebug or pcov turns it off); after the restart the app's runtime has to be up, or the previous setting is put back. On PHP-FPM the JIT buffer is shared memory of the FPM of that PHP version: while an app on it has JIT, Cipi makes JIT *startable* there (`conf.d/99-zz-cipi-jit.ini`, `opcache.jit = off`, the largest buffer asked for) and turns it on in that app's pool only. JIT speeds up CPU-bound PHP; a request that waits on the database gains little — measure your app.

### 📡 Reverb, Horizon & Scheduler

First-class Laravel extras, all CLI-managed:

```bash
cipi app reverb enable myapp
cipi worker horizon enable myapp
cipi schedule on myapp
```

Enabling Reverb allocates a localhost port, writes a Supervisor program, and proxies the two paths the Pusher protocol uses — `/app/{key}` for the WebSocket and `/apps/{id}/…` for the broadcast API — through Nginx on the app's own domain. It also generates `REVERB_APP_ID/KEY/SECRET` and the `VITE_REVERB_*` copies the frontend build reads, picks `ws://` or `wss://` from whether the app has a certificate (and moves to `wss://` by itself when one is installed later), and raises the file-descriptor limits that otherwise cap a WebSocket server at about a thousand concurrent clients.

An app with its own `/app` or `/apps` route cannot use Reverb behind the same domain — those paths belong to the protocol. Reverb can also be declared in `cipi.yml` as `workers.reverb: true`.

Horizon is mutually exclusive with `queue:work` workers. Scheduler toggles the crontab `schedule:run` entry.

### 🔎 Meilisearch for Laravel Scout (optional)

A self-hosted alternative to Algolia, off by default and never installed by `setup.sh` or `cipi self-update`:

```bash
cipi search install          # binary + systemd unit on 127.0.0.1:7700
cipi search enable myapp     # scoped key + Scout settings in the app .env
```

Meilisearch is a single static Rust binary, so it installs natively like the rest of the stack — no Docker in the loop. `enable` writes `SCOUT_DRIVER`, `MEILISEARCH_HOST`, `MEILISEARCH_KEY` and `SCOUT_PREFIX` into `shared/.env`; then `composer require laravel/scout meilisearch/meilisearch-php` and `php artisan scout:import "App\Models\Post"` in the app.

**One instance, real isolation.** Meilisearch has no per-tenant databases, so Cipi gives every app an API key scoped to the index pattern `<app>-*` — with only the actions Scout calls, never key management — and **writes `SCOUT_PREFIX` itself** rather than leaving it to you. Cipi usernames contain no hyphens, so `blog-` can never overlap `blogs-`: an app that ignores the prefix gets a 403 rather than its neighbour's documents. The master key stays in the vault and in a root-only `EnvironmentFile`, never in an app `.env` and never on a command line.

`cipi search key rotate <app>` reissues one key; `--master` rotates the master key and rewrites every app's `.env` in the same run (Meilisearch derives each key from the master, so they all change at once). `cipi search upgrade` swaps the binary and does the in-place store upgrade, rolling the binary back if the engine refuses — and only dropping the indexes if you say so, since `scout:import` rebuilds them. Indexes are derived data, so they are deliberately not part of `cipi backup`.

For a small dataset you may not need any of this: Scout's `database` driver, or Postgres full-text, needs no extra service.

### 📦 Optional host tools

Some projects need a binary on the host — an image optimiser, ffmpeg, `pdftotext`. `cipi package` installs them from Ubuntu's own repositories, from a closed allowlist:

```bash
cipi package list
cipi package install image-optimizers   # or ffmpeg, imagemagick, poppler-utils
cipi package remove ffmpeg
```

The allowlist is the feature: without it this would be a root apt shell with extra steps. An entry has to be a **stateless binary from an Ubuntu repo** — no daemon, no port, no credentials, no state that outlives the process — with a real Laravel package behind it. Anything else is a service, and goes through `cipi search`, `cipi db install` or the container branch. Chromium is the instructive rejection: on Ubuntu 24.04 `chromium` isn't a deb at all and `chromium-browser` is a transitional package that depends on `snapd`, so "just apt-install it" would quietly add a self-updating daemon.

`install` shows what apt actually intends to pull — package count and disk — and asks before running. `remove` purges only what is present, then shows which orphaned dependencies `autoremove` would take before touching them.

Already in the base stack, so not in the list: the **Imagick PHP extension**, **Ghostscript** and **fonts-dejavu-core** (Recommends of `php-imagick`), and **Node 22** (`cipi node default` changes it).

### 🔗 Webhook Auto-Deploy

Native GitHub, GitLab, [Bitbucket](https://bitbucket.org), [Azure DevOps](https://azure.microsoft.com/products/devops), [Cursor Origin](https://cursor.com/origin), and [AWS CodeCommit](https://aws.amazon.com/codecommit/) integration — deploy keys (and webhooks where the forge has them) configured automatically. HMAC signature verification. Or plug in any custom Git provider. If a token expires and keys/webhooks drift, `cipi git refresh` re-registers them on every app (`--rotate-keys` / `--rotate-secret` to mint new material). `cipi app create` and `cipi app edit --repository` / `--branch` test the deploy key against the repository on the spot: when it cannot read it, Cipi says why and — on a terminal — offers to save or replace the forge token, registers the key and checks again. `cipi git check [app]` repeats the test at any time. When the forge refuses the key or the webhook, the summary and `cipi git refresh` say what it answered and what the token needs — a GitHub 404 is a token that cannot see the repository, not a missing one. The branch to deploy goes into `.env` as `CIPI_DEPLOY_BRANCH`, so a push to any other branch is ignored.

### 📦 App Types

**Laravel** (default) — zero-downtime deploy with releases, shared storage, workers, scheduler, webhook; add **`--octane`** for FrankenPHP. **`--custom`** — for simple sites (e.g. WordPress, static+PHP): classic deploy into `htdocs` (no current/shared), choose docroot only (e.g. `/`, `www`, `dist`). Nginx: `index index.html index.php`, `try_files $uri $uri/ /index.php?$args`, `error_page 404 /404.html`. No DB, no .env, no cron, no workers, no webhook — just Nginx, PHP-FPM, and deploy key.

Clone an app for staging with **`cipi app clone <src> --domain=… --env=staging`**: the clone gets its own environment label, so it reads `cipi-staging.yml` from the same repository.

### 🌐 Aliases, www & SSL

Add multiple domains or subdomains to any app. A domain can be a **wildcard** (`*.example.com`), as the app's primary domain or as an alias — multi-tenant apps get one vhost for every tenant. Manage www/apex aliases and canonical redirects with **`cipi www`** — also on a wildcard primary: `cipi www force-from-root` sends `example.com` to `www.example.com`, which `*.example.com` serves. A single SAN certificate covers all of them — HTTP-01 by default, or **DNS-01 via Cloudflare** for wildcards. Auto-renew handles the rest.

**Wildcard / multi-tenant in three commands** (DNS of the zone on Cloudflare — proxied or not — and a `*` record pointing at the server):

```bash
cipi alias add myapp '*.myapp.com'               # routes every subdomain to the app (quote it)
cipi ssl dns set --token=<CLOUDFLARE_API_TOKEN>  # once per server: Zone → DNS → Edit
cipi ssl install myapp --dns=cloudflare          # one certificate: myapp.com + *.myapp.com
```

Cipi writes the HTTPS server block itself; certbot only issues and renews the certificate. Every subdomain is redirected from HTTP to HTTPS, renewals reload nginx, and a DNS-01 certificate is always reissued over DNS-01. Behind the Cloudflare proxy set SSL/TLS to **Full (strict)** — never Flexible, which loops on the HTTPS redirect. Without Cloudflare DNS, a wildcard certificate cannot be issued by Cipi: list the subdomains as aliases instead (HTTP-01). The full decision guide — with and without Cloudflare, Origin CA, tunnel — is in the [docs](https://cipi.sh/docs/advanced#wildcard-domains). `cipi ssl status` shows, per app, what is served with which certificate and which names it does not cover.

**Domains in different Cloudflare accounts.** A wildcard certificate needs an API token of the Cloudflare account that holds the zone. One token is enough when every zone is in the same account; when your clients each have their own, give every account a name:

```bash
cipi ssl dns set --token=<TOKEN>                    # the default account
cipi ssl dns set --name=client-a --token=<TOKEN>    # another account, any number of them
cipi ssl dns list                                   # accounts and the certificates on each
cipi ssl install shop --dns=cloudflare --wildcard --account=client-a
cipi ssl dns remove client-a                        # refused while a certificate still renews with it
```

Each certificate renews with the token of the account it was issued with, and reissuing an app without `--account` keeps the account it had. `cipi ssl dns set` on an existing name replaces its token, which is how a token is rotated. Tokens are stored root-only and are never shown. `cipi ssl status` says which account every DNS-01 certificate uses.

### ↪️ Redirects & prefix proxies

Redirects and reverse proxies are written into the app's nginx vhost, so they cost nothing at runtime and never reach PHP. Every change runs `nginx -t` and is reverted if nginx refuses it.

```bash
cipi redirect set old-shop --to=https://shop.example.com   # whole app, path kept, 301
cipi redirect disable old-shop                             # serve it again, target kept
cipi redirect add shop /blog/ https://blog.example.com/ --308
cipi redirect add shop /promo /sale --302
cipi proxy add shop /api/ http://10.0.0.5:8080 --strip-prefix   # /api/users → :8080/users
cipi proxy add shop /events/ http://127.0.0.1:3000 --no-buffering
```

A proxy only takes its prefix; the rest of the app is served as usual. WebSockets pass through, `X-Forwarded-*` headers are set, and basic auth covers the prefix when it is on.

### ❤️ HTTP Healthchecks

Point Cipi at an HTTP endpoint; it probes every 5 minutes and alerts after consecutive failures:

```bash
cipi health set myapp --url=https://example.com/up --expect=200
```

### 📟 System Monitor & Chat Alerts

`cipi health` watches your apps; **`cipi monitor`** watches the server itself. Every 5 minutes it checks disk usage, SSL certificate expiry, system services (nginx, MariaDB, PHP-FPM, …), queue workers and Horizon, HTTP 5xx spikes in the access logs, read-only filesystems, and load average. Alerts fire on state changes only — one message when something breaks, one when it recovers, and a quiet reminder every 4 hours while it stays broken. No dashboards, no metrics storage: just a message when it matters.

```bash
cipi monitor                      # run all checks now
cipi monitor set disk --warn=80 --crit=90
```

**The disk is watched from the first boot.** Every filesystem of the server is checked every 5 minutes: a warning at **80%** full, a critical alert at **90%**, a recovery message when it drops back, and a reminder every 4 hours while it stays over. Those are the defaults, changed with the command above. Apps that have a soft disk limit (`cipi app limits <app> --disk=<GB>`) are watched the same way by the `app_disk` check; apps without one, the default, are not measured at all.

Alerts reach you where you actually look. **`cipi notification`** manages where every Cipi notification goes — deploys, backups, scans, logins, monitor alerts, PHP and FrankenPHP patches — and each trigger reaches every enabled channel:

```bash
cipi notification                                   # every channel and how many triggers are on
cipi notification add smtp --host=smtp.example.com --user=… --password=… --from=… --to=…
cipi notification add resend mail --api-key=re_… --from="Cipi <alerts@example.com>" --to=ops@example.com
cipi notification add ses aws --region=eu-west-1 --access-key=AKIA… --from=alerts@example.com --to=ops@example.com
cipi notification add slack ops --url=https://hooks.slack.com/services/…
cipi notification add discord ops --url=https://discord.com/api/webhooks/…
cipi notification add mattermost ops --url=https://chat.example.com/hooks/…
cipi notification add googlechat ops --url=https://chat.googleapis.com/v1/spaces/…
cipi notification add telegram ops --token=<bot-token> --chat-id=<id>
cipi notification add ntfy phone --url=https://ntfy.sh/my-topic --priority=high
cipi notification add pushover phone --token=<app token> --user=<user key>
cipi notification add webhook siem --url=https://example.com/cipi --secret=…   # X-Cipi-Signature: sha256=…
cipi notification test all
cipi notification triggers                          # which events notify (enable|disable <trigger>)
```

Email goes through your SMTP server, the [Resend](https://resend.com) API or [Amazon SES](https://aws.amazon.com/ses/) (API v2, requests signed with AWS Signature Version 4 — the IAM user needs only `ses:SendEmail`). Leave a secret out of the command (`--password`, `--api-key`, `--secret-key`, `--token`) and it is asked for on the terminal without echo; secrets are kept in Cipi's vault and never printed back (`--json` says `*_set: true`). The SMTP configuration is the one `cipi smtp configure` always wrote: `cipi smtp …` and `cipi notifications …` keep working.

### 💽 Disk Usage, Server and Per App

`cipi monitor` tells you when the disk is filling up; **`cipi disk`** tells you who is filling it. One command shows every filesystem and then every app, largest first, in GB and as a percentage of the disk:

```bash
cipi disk            # the server, then every app
cipi disk db         # databases, in MB
cipi disk --json     # the same figures for scripts (also: cipi disk db --json)
```

```
  Server disk
  MOUNT                          SIZE         USED         FREE     USE
  /                         100.00 GB     40.00 GB     60.00 GB     40%

  Apps (3) — % of the 100.00 GB on /
  APP                           FILES     DATABASE        TOTAL    DISK  LIMIT
  shop                        2.00 GB      1.00 GB      3.00 GB    3.0%  10 GB (30%)
  blog                        0.50 GB     120.4 MB      0.62 GB    0.6%  —
  front                       0.10 GB      0.00 GB      0.10 GB    0.1%  —
  All apps                                              3.72 GB    3.7%
  Everything else                                      36.28 GB   36.3%
```

**Files** is the app's home (releases, shared storage, logs). **Database** is the app's database: the one named after the app and, if `shared/.env` points at another one, that one too. Sizes below 0.01 GB are shown in MB, so a small database does not read as zero. **Everything else** is what remains of the used space: system, packages, logs, local backups, other databases. Sizes are measured when you run the command, so a server with large apps takes a few seconds.

**Every database, engine by engine.** `cipi disk db` goes through every engine installed on the server and prints sizes in MB:

```
  MariaDB
  DATABASE                                               SIZE
  blog                                                 2.0 MB
  shop                                               200.0 MB
  On disk, whole engine                              500.0 MB

  Valkey
  DATABASE                                     KEYS      SIZE
  db0                                          1204         —
  Memory in use                                       12.3 MB
  On disk, whole engine                                3.0 MB

  Meilisearch
  INDEX                                   DOCUMENTS      SIZE
  shop-products                               12000    8.4 MB
  On disk, whole engine                               45.0 MB
```

MariaDB and PostgreSQL give one size per database. Valkey only knows how many keys each of its databases holds, and Meilisearch how many documents each index has (plus the size of an index's documents on recent versions): for those two the size in MB is the engine's, in memory and on disk. An engine that is not installed is left out.

**The same figures over the API.** With [cipi/api](https://github.com/cipi-sh/api) 1.33+ on the server (Cipi 5.5.2+ for the sudoers entry), `GET /api/disk` and `GET /api/disk/dbs` return what `cipi disk --json` and `cipi disk db --json` print, read-only, behind the token ability `disk-view` — `cipi-cli disk`, the GUI's Server → Disk tab and the MCP tools `DiskUsage` / `DiskDatabases` use them.

**A soft limit per app.** No app has a limit until you give it one. A limit is a number of GB for files and database together (the TOTAL column), and it is a notification threshold: nothing is blocked and the app keeps working when it is passed.

```bash
cipi app limits shop --disk=10      # alert when shop reaches 10 GB
cipi app limits shop --disk=none    # back to no limit (the default)
```

`cipi disk` then shows the limit next to the app (`10 GB (30%)`, and `over` once it is passed), and `cipi monitor` sends the alert: a warning at 90% of the limit, a critical one when the app is over it, a message when it is back under. Each app is alerted on its own. The limit is set on the server only; it cannot be changed from the app's `cipi.yml`.

### 🎯 One App at a Time: `cipi use`

Working on one app for a while? Name it once and drop it from the commands that need one:

```bash
cipi use shop            # default for cipi deploy, app logs|env|artisan, yml plan|apply, worker, ssl install, www, alias …
cipi deploy              # → shop (default app — cipi use)
cipi app logs --type=php
cipi use --clear
```

It fills in a missing app only where one is required today, and says so on stderr. Commands where a missing app means every app (`cipi git refresh`, `cipi scan`) keep that meaning, and destructive ones (`cipi app delete`, `reset-password`, `cipi db …`) still want the name. `CIPI_APP=shop` does the same for one shell.

### ⌨️ Tab-Completion That Is Already There

Press `<Tab>` after `cipi` and the shell completes commands, sub-commands, flags and **app names**. Nothing to enable: `setup.sh` installs it on new servers and every `cipi self-update` installs or refreshes it on existing ones.

```bash
sudo cipi dep<Tab>            # → deploy
sudo cipi deploy sh<Tab>      # → shop, shop2 (your apps)
sudo cipi firewall <Tab>      # → allow  list  attempts
```

It works the way servers are really used: after `sudo cipi`, which is how the `cipi` user runs it, with or without the `bash-completion` package; in the shells that `sudo -s`, `su`, tmux and screen open, which skip `/etc/profile.d`; and with app names for every user, not only root. All of that holds for bash; zsh loads the same completion from its vendor directory and `/etc/profile.d`. `cipi completion bash|zsh` is only for another user or a custom rc file.

### 📋 Compliance Evidence (ISO 27001 / SOC 2)

Cipi is self-hosted software, so it cannot be certified itself: ISO 27001 certifies an organisation, SOC 2 attests a service. What an agency or SaaS under audit needs is **evidence** that its servers meet the controls. **`cipi compliance report`** collects it in one read-only pass: SSH hardening, firewall, fail2ban, OS patches, kernel network parameters, TLS protocols and certificates, local accounts and sudo, SSH key fingerprints, API tokens (expiry, last use, scope), GUI 2FA, config encryption at rest, the deploy audit ledger (every deploy with commit, origin and operator, hash chain verified, cross-checked against Deployer's own release log), backup freshness, log forwarding, monitoring and alert delivery, NTP, and malware scanning. Each control is mapped to ISO/IEC 27001:2022 Annex A and SOC 2 criteria.

```bash
cipi compliance                   # pass / warn / fail per control, exit 1 on fail
cipi compliance report --days=90  # report.md + report.json + raw evidence + SHA256SUMS, as a .tar.gz
```

The bundle has no secrets (no token hashes, no key material, no vault content) and is written root-only under `/var/log/cipi/compliance/`. Give the archive and its SHA-256 to your auditor. Organisational controls such as policies, risk assessment and incident response are still yours to cover.

### 🤖 AI Agent Ready (MCP)

Cipi ships with a built-in MCP server. Laravel first: install the `cipi-agent` Laravel package, point your AI client at the endpoint, and deploy, rollback, query logs, and run Artisan commands via natural language — no SSH required.

Works with Claude, Cursor, VS Code, OpenAI, Gemini, and more.

```bash
composer require cipi/agent
```

MCP tools exposed: `health`, `app_info`, `deploy`, `logs`, `db_query`, `artisan`.

### 🔌 REST API (optional)

When you need to manage apps programmatically or integrate with external pipelines, enable the optional API layer with a single command. Bearer tokens, granular permissions, OpenAPI spec available, interactive Swagger docs.

The API runs on a **domain or subdomain of its own**, pointed at the server first: not the domain of an app, and not the GUI's. `cipi api` checks the DNS before it installs anything and stops, with the record to create, when the name does not point there (`--skip-dns-check` behind a proxy or NAT it cannot see through); Cipi also refuses a domain that an app already uses.

```bash
cipi api api.example.com              # DNS check, install, certificate, token — one command
cipi api ssl                          # (re)issue the certificate
cipi api move api.newdomain.com       # change domain: old certificate out, new one in (--no-ssl to skip)
cipi api remove                       # uninstall: tokens, jobs, vhost, crons, certificate
```

### 🖥️ Web GUI (optional)

A self-hosted control panel for operators who prefer a browser over SSH. One login manages any number of Cipi servers through their REST API: register each server with a token, then switch between them from the header on any page.

<picture>
  <source media="(prefers-color-scheme: light)" srcset="https://cipi.sh/img/gui/server-overview-light.webp">
  <img alt="Cipi control panel: server overview" src="https://cipi.sh/img/gui/server-overview.webp">
</picture>

- **Apps** — create Laravel (PHP-FPM or Octane), Node (SPA, static, SSR) and custom PHP apps; deploy, roll back and unlock; the deploy audit ledger and the `deploy.php` pipeline; domains, SSL, www ↔ apex, whole-app and path redirects, prefix proxies; `.env` with masked secrets, Composer `auth.json`, Artisan and whitelisted commands; basic auth, healthchecks, Meilisearch; logs with live refresh.
- **Databases** — MariaDB and PostgreSQL: create, back up, restore, rotate passwords.
- **Server** — overview, PHP versions, Node runtimes, database engines, services, healthchecks, monitor, email notifications, SSH keys, packages, Cloudflare Zero Trust and the API IP whitelist.
- **Jobs** — long operations run on the server; the panel shows their output and lists one-time credentials (SSH and database passwords, deploy key, webhook token) with copy buttons.
- **Security** — session login with TOTP 2FA, tokens encrypted at rest, nothing installed on the managed servers besides `cipi api`.

<table>
  <tr>
    <td width="50%" valign="top"><a href="https://cipi.sh/img/gui/apps.webp"><img src="https://cipi.sh/img/gui/apps.webp" alt="Apps list in the Cipi control panel"></a><br><sub><b>Apps</b> — Laravel, Node and custom apps; filter, search, deploy from the list</sub></td>
    <td width="50%" valign="top"><a href="https://cipi.sh/img/gui/create-app.webp"><img src="https://cipi.sh/img/gui/create-app.webp" alt="Create app form with the app type picker"></a><br><sub><b>Create</b> — the app type picker, with the same Node presets as the CLI</sub></td>
  </tr>
  <tr>
    <td width="50%" valign="top"><a href="https://cipi.sh/img/gui/app-deploy.webp"><img src="https://cipi.sh/img/gui/app-deploy.webp" alt="Deploy tab with the deploy audit ledger"></a><br><sub><b>Deploy</b> — deploy, roll back, unlock, the deploy audit and the deploy.php pipeline</sub></td>
    <td width="50%" valign="top"><a href="https://cipi.sh/img/gui/app-env.webp"><img src="https://cipi.sh/img/gui/app-env.webp" alt="Environment editor with masked secrets"></a><br><sub><b>Environment</b> — shared/.env with secrets masked and changed rows highlighted</sub></td>
  </tr>
  <tr>
    <td width="50%" valign="top"><a href="https://cipi.sh/img/gui/app-routing.webp"><img src="https://cipi.sh/img/gui/app-routing.webp" alt="Routing tab with redirects and proxies"></a><br><sub><b>Routing</b> — whole-app and path redirects, prefix reverse proxies</sub></td>
    <td width="50%" valign="top"><a href="https://cipi.sh/img/gui/app-logs.webp"><img src="https://cipi.sh/img/gui/app-logs.webp" alt="Logs viewer with live refresh"></a><br><sub><b>Logs</b> — nginx, PHP-FPM, Laravel, worker and deploy logs, live</sub></td>
  </tr>
  <tr>
    <td width="50%" valign="top"><a href="https://cipi.sh/img/gui/databases.webp"><img src="https://cipi.sh/img/gui/databases.webp" alt="Databases page for MariaDB and PostgreSQL"></a><br><sub><b>Databases</b> — MariaDB and PostgreSQL: create, back up, restore, rotate passwords</sub></td>
    <td width="50%" valign="top"><a href="https://cipi.sh/img/gui/server-monitor.webp"><img src="https://cipi.sh/img/gui/server-monitor.webp" alt="Server monitor page"></a><br><sub><b>Monitor</b> — the server checks, their state and the last alert</sub></td>
  </tr>
  <tr>
    <td width="50%" valign="top"><a href="https://cipi.sh/img/gui/job-credentials.webp"><img src="https://cipi.sh/img/gui/job-credentials.webp" alt="Job overlay listing one-time credentials"></a><br><sub><b>Jobs</b> — live output, and one-time credentials with copy buttons</sub></td>
    <td width="50%" valign="top"><a href="https://cipi.sh/img/gui/connections.webp"><img src="https://cipi.sh/img/gui/connections.webp" alt="Connections page with several servers"></a><br><sub><b>Connections</b> — every server with its token; switch from the header</sub></td>
  </tr>
</table>

<p align="center">
  <img src="https://cipi.sh/img/gui/mobile-apps.webp" alt="Apps on a phone" width="240">
  <img src="https://cipi.sh/img/gui/mobile-app.webp" alt="App detail on a phone" width="240">
  <img src="https://cipi.sh/img/gui/mobile-nav.webp" alt="Navigation drawer on a phone" width="240">
  <br><sub>Light and dark themes follow the system, and the layout adapts to phones.</sub>
</p>



Install with **`cipi gui <domain>`** — DNS check, admin account and certificate in one go — on a domain or subdomain of its own, e.g. `panel.example.com`: not an app's domain and not the API's. Change it later with **`cipi gui move <domain>`** (certificate included), uninstall with **`cipi gui remove`**. The panel requires **`cipi api`** on each managed server. What is CLI-only by design (installing software, `cipi ssh apps`, firewall thresholds, dropping databases) stays on the CLI.

**Single sign-on** (cipi/gui 4.0.2+): `cipi gui sso set --issuer=… --client-id=… --client-secret=…` turns on OpenID Connect sign-in — Microsoft Entra ID, Google Workspace, Okta, Keycloak — with accounts matched by email (`--domains=` creates them on first sign-in, with no access until granted); `--only` switches passwords off, and `cipi gui sso only off` from the server is the break-glass.

[Docs and screenshots](https://cipi.sh/docs/gui#gui-tour) · [GitHub](https://github.com/cipi-sh/gui)

### 🔁 Sync Between Servers

Move entire stacks or single apps between Cipi servers — for migration, failover, or disaster recovery. Archives are encrypted in transit.

### 🖥️ CLI Client

A standalone Go binary that talks to the Cipi REST API from your local machine — no SSH required. Manage apps, databases, SSL, aliases, and deployments from any terminal. Pre-built binaries for Linux and macOS (amd64/arm64).

[Docs](https://cipi.sh/docs/cli-client) · [GitHub](https://github.com/cipi-sh/cli)

### 🛒 WHMCS Module

An official provisioning module that bridges the WHMCS lifecycle to the Cipi REST API — automate app creation, deletion, SSL certificates, deployments, and package changes for your hosting customers. Self-contained drop-in, no Composer dependencies.

[Docs](https://cipi.sh/docs/advanced#whmcs) · [GitHub](https://github.com/cipi-sh/whmcs)

---

## Who uses Cipi?

- **Solo developers** — ship Laravel first, without the DevOps overhead
- **Agencies** — one VPS, many isolated client projects (Laravel first), onboard a new client in minutes
- **Startups & SaaS** — atomic deploys, instant rollbacks, grow without changing your workflow
- **Datacenters & automation pipelines** — every Cipi command is a plain shell call, wire it into Ansible or any provisioning script

---

## Requirements

- Ubuntu **24.04 LTS** or **26.04 LTS** (no other releases)
- A VPS or VM with **full virtualization** (KVM, VMware, Hyper-V, Xen HVM) or a bare-metal server. Not shared-kernel virtualization (OpenVZ, LXC) and not container runtimes, including the desktop ones that emulate a Linux machine (Docker Desktop, Podman, OrbStack, WSL): Cipi sets up the firewall, fail2ban, swap and kernel parameters, which needs a kernel of its own. The installer stops there and says which environment it found.
- Root access
- Ports **22**, **80**, **443** open

---

## Documentation

Full docs at: **[cipi.sh/docs](https://cipi.sh/docs)**

---

## Contributing

Cipi is open source and MIT licensed. Issues, PRs, and feedback are welcome on [GitHub](https://github.com/cipi-sh/cipi).

---

<div align="center">

Made with ❤️ by [Andrea Pollastri](https://web.ap.it)

</div>
