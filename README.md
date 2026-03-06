<h1 align="center">Cipi</h1>

<p align="center">
  <strong>Version 3.x is no longer manteined. Cipi has been moved to v4</strong>
</p>

<p align="center">
  <a href="https://cipi.sh">Website</a> · <a href="https://cipi.sh/docs">Documentation</a> · <a href="https://github.com/andreapollastri/cipi/releases">Changelog</a>
</p>

---

## History

Here is a brief account of how it evolved across six years and four major versions.

### v0.1 — June 2019 · *The idea*

A collection of shell scripts to automate the tedious parts of setting up a Laravel server on a fresh Ubuntu VPS — Nginx, PHP, MariaDB, Supervisor. No web UI, no package. Just bash.

### v1.x — June 2019 · *First release — Laravel panel*

The shell scripts were wrapped in a Laravel web application acting as a server control panel. Users could create apps, manage deployments, and configure Nginx through a browser UI hosted on the same server. The project was published on GitHub and quickly attracted interest from the Laravel community.

### v2.x — May 2020 · *Feature growth*

A year of rapid iteration added SMTP configuration, local database backups, PHP-FPM permission fixes, server service management, and root password reset. The v2 series reached 2.4.9 across dozens of patch releases, establishing Cipi as a stable option for small-team Laravel hosting.

### v3.0 — March 2021 · *The big leap — API, PHP 8, real-time UI*

Built on Laravel 8, v3 introduced a fully documented REST API (Swagger / OA), PHP 8 support, real-time CPU/RAM charts, a Cronjob editor, Supervisor management, a GitHub repository manager, Node 15, Composer 2, and JWT authentication. Cipi could now manage the same server it ran on. The project reached 1k GitHub stars.

### v3.1 — December 2021 · *The last web UI — and a question*

PHP 8.1 became the default version. Node was upgraded to v16, Certbot was refreshed, and domain alias handling was fixed. The v3.1.x series was the most polished release of the web-UI era and many teams kept it running in production for years.

It was also the version that prompted a harder question: was a browser-based control panel still the right interface? Modern development workflows had moved toward SSH, CI/CD pipelines, GitOps, and — increasingly — AI agents that could orchestrate infrastructure through shell commands. A web UI required authentication, a running Laravel process, and a database just to issue a deploy. A CLI needed none of that. The answer shaped everything that came next.

### v4.x — March 2026 · *The rewrite — CLI-first, Laravel-exclusive*

After years of maintaining a full Laravel web application as the control plane, v4 made the boldest decision yet: drop the web UI entirely. Cipi became a pure CLI tool operated over SSH. The scope also narrowed from generic PHP to Laravel exclusively, allowing every part of the stack to be optimised for one framework. MySQL was replaced by MariaDB 11.4, `git pull` was replaced by Deployer zero-downtime releases, shared deploy keys became per-app `ed25519` keys, and S3 automated backups and native webhook support for GitHub and GitLab were added from day one. v4 also introduced a complete REST API for programmatic management of hosts and applications, native integration with GitHub and GitLab git providers, and a groundbreaking dual MCP server architecture — one per-app and one global — enabling full AI-driven infrastructure management directly from any MCP-compatible IDE or AI agent.

The result is the brand new version 4.x.

> The full v4 changelog is available on [GitHub Releases](https://github.com/andreapollastri/cipi/releases).
