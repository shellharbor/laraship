---
name: deploy-laravel
description: Use when you need to deploy a Laravel or Laravel+Filament site on an Ubuntu server with deploy-laravel.sh (Docker, shared nginxproxy, Let's Encrypt SSL, PostgreSQL/MySQL in a container or a native DB), or to prepare the command for it. Also use to deploy an existing Laravel application from a git repository, to update it, and to diagnose, re-run, deactivate and remove a deployment.
---

# Deploying Laravel (+ Filament) with deploy-laravel.sh

This skill belongs to the self-contained `laraship` folder (this file sits in its root). Full documentation: [README.md](README.md). Ready-made scenarios: [examples/](examples/README.md). The README also covers migrating from the old `deploy.sh` and updating servers deployed with an older version.
`deploy-laravel.sh --version` prints the installed version (releases are on GitHub with a SHA-256 checksum; see the README, "Quick start").
Take flags only from the "Arguments" table in the README (it has been checked against `parse_args`). Do not invent flags and do not use `--type` (it is kept only for compatibility).

## What the script does

`deploy-laravel.sh` runs on an Ubuntu server as root and:
- installs Docker (if missing) and creates, once, the shared reverse proxy `/var/www/nginxproxy` on ports 80/443;
- creates the project `/var/www/<slug>` from the `laravel/` template with its own Docker network `<slug>` and the containers php (8.3-FPM), nginx, db (Docker Official Images PostgreSQL 17 / MySQL 8.4 LTS; absent with `--db-native`), redis, cron, certbot_renew, plus the utilities artisan, composer, npm and permissions;
- installs Laravel (`composer create-project laravel/laravel:^X.Y`, 13.0 by default) with composer in the same PHP 8.3 image as the `www` user, writes the DB settings and `APP_URL` to `public_html/.env` and runs migrations;
- with flags, installs Filament 5 (the `/admin` panel), enables Basic Auth, sends JSON to `--endpoint` and creates a zip archive;
- with `--repo`, deploys an existing Laravel application from git instead of a fresh skeleton (clone, `composer install --no-dev`, `.env`, migrations); `update.sh --slug <slug>` updates it later;
- named bundles of settings: `--preset NAME` (`--list-presets`: `admin-panel`, `api`, `staging`); `--dry-run` prints the effective settings and exits (no root, changes nothing) and is the way to check a command before running it;
- settings can come from a file: `--config FILE` (`KEY=VALUE`, key = the flag in upper case; flags on the command line win); default versions live in `versions.env` next to the script;
- optional features are modules: `--with filament,redis,queue,horizon,backup` (`--list-modules` shows them; `--install-filament`, `--use-redis` and `--queue-worker` are aliases; `horizon` enables `redis` by itself);
- new deployments use `APP_ENV=production`, `APP_DEBUG=false`, no Xdebug, mode 600 for both `.env` files, and project ports on 127.0.0.1 only (`--bind-local` is a compatibility flag);
- other extras: `--php-upload-max SIZE`, `--post-deploy "cmds"`;
- serves HTTP initially with HTTP APP_URL; after successful certificate application enables HTTPS and a redirect, keeping ACME open. PHP uses production ini; Certbot is pinned to v5.8.0. Backup dumps are mode 600 in mode-700 directories.

The slug, passwords, DB names and ports that are not set explicitly are generated and printed to the console.

## Where it runs

All the scripts run only on the server. Do not run them on a local Windows machine. Work over SSH (ssh is available in both Git Bash and PowerShell):

```bash
ssh user@server 'sudo bash /opt/laraship/deploy-laravel.sh --help'
```

- The `laraship` folder must be on the server **as a whole**, usually at `/opt/laraship/`; confirm the path with the user. The script looks for `laravel/` and `nginxproxy/` next to itself. If the folder is not there, offer to copy it and wait for consent: `scp -r laraship user@server:~/`, then `sudo mv ~/laraship /opt/` (or `git clone`). Details: README → "Quick start".
- LF line endings are required. With CRLF bash fails with `$'\r': command not found` (see README → "Quick start").
- Never type SSH or sudo passwords for the user. If it does not work without a password, hand the user a ready command to run themselves.

## Prerequisites

- Ubuntu 20.04+, root or sudo, with `python3`, `curl`, `ss`, `flock`, `pgrep` and `timeout` installed.
- If Docker is already installed, the `docker compose` v2 plugin is required. If Docker is missing, the script installs it.
- The A record of the final domain points to the server. **Without `--slug` the domain becomes `<random-slug>.<domain>`**, so a wildcard record `*.<domain>` is needed, otherwise SSL cannot be obtained.
- Ports 80 and 443 on the server are free (nginxproxy will take them) and open from outside.
- `--db-native`: PostgreSQL or MySQL is installed and running on the host and listens on an address reachable from containers (the Docker host address, normally `172.17.0.1`; the script reads it from Docker's `bridge` network). `pg_hba.conf` must allow the docker subnets, and for MySQL check `bind-address` (on Ubuntu it defaults to `127.0.0.1`). The script does not configure this; it is the administrator's job.

A check that changes nothing on the server:

```bash
ssh user@server 'lsb_release -ds; python3 --version; docker --version; docker compose version; \
  ls -A /opt/laraship /opt/laraship/laravel; grep -c $'"'"'\r'"'"' /opt/laraship/deploy-laravel.sh; \
  sudo ss -tlnp | grep -E ":(80|443) "; ls /var/www; getent hosts <domain>'
```
Expected: `/opt/laraship` contains `deploy-laravel.sh`, `laravel/` and `nginxproxy/`, `laravel/` contains `.config` and `.docker`, and the CR count is `0`.

Updated LaraShip scripts lock the project first and shared proxy second, validate a private candidate and restore prior configuration on apply failure. Incomplete or symlink-containing proxy trees are refused. Older sibling kits and manual edits do not share these locks. Preserve recovery files printed after a failed rollback.

## Workflow

### 1. Gather the parameters
Required parameters: `--domain`, `--db-type postgres|mysql` and `--ssl-email EMAIL` (or `--no-ssl`).
Be sure to ask the user about:
- **Laravel version**: `--laravel-version` accepts 12.0 and above (`LARAVEL_MIN_VERSION` in `versions.env`); Laravel 10.x and 11.x are no longer supported and are refused up front, because Composer blocks them over unfixed security advisories (README, "Laravel versions and conditions").
- **slug** (`--slug`). Advise setting it explicitly, in lowercase. Without it the domain gets a random prefix.
- **Filament** (module `filament`): `--install-filament` (or `--with filament`) `--filament-email EMAIL`, name and password optional. `filament/filament:^5.0` is installed; Laravel 12 and 13 are supported, with 13.0 the default and 12.0 the minimum (see the README, "Laravel versions and conditions").
- **Native DB**: `--db-native`, and for MySQL also `--db-root-password`. Check the prerequisites above.
- **Basic Auth**: `--enable-basic-auth`, optionally with `--auth-user` and `--auth-password`.
- **Existing application**: `--repo URL` with `--branch` and, for a private repository, an SSH URL plus `--deploy-key PATH`. Never put credentials in the URL (the script refuses them). `--repo` cannot be combined with `--install-filament` or `--laravel-version`. The php container has no Node: frontend assets must be committed or built afterwards with the `npm` service.
- Optional parameters: explicit DB credentials, ports, `--redis-password`, `--create-backup`, `--endpoint`, `--post-deploy "cmds"` (one line, runs in the php container), modules (`--with redis,queue` or `--with horizon`; horizon cannot be combined with `queue` or `--repo`), `--bind-local`, `--php-upload-max SIZE`.

Before running a command, check it with `--dry-run` (add it to the same command; it needs no root and prints no secrets). Settings apply in this order, later wins: `--preset`, then `--config`, then flags. For repeatable deployments put the settings in a `--config` file (README, "Configuration file and versions"; example in `examples/deploy.config.example`). Keep it at mode 600: it holds passwords.

Literal secrets are encoded for Compose, Laravel and endpoint JSON. Control characters are refused; container MySQL also rejects quotes/backslashes because of the official initializer, and its application username cannot be `root`. Prefer a mode-600 config file over secret-bearing flags to keep credentials out of shell history and the original CLI arguments.

### 2. Check the server
Run the prerequisites check and inspect `/var/www/<slug>` and the project's volumes (`docker volume ls --filter name=<slug>_`). The installer refuses an existing project path without changing its files or containers. For an application deployed with `--repo`, use `update.sh` to preserve data. A clean reinstall requires separately authorized removal and saved database dumps/uploads first (README → "Re-running the script"). Never use the reserved slug `nginxproxy`.

Existing projects keep their copied DB image/configuration. Changing `versions.env` or running `update.sh` does not migrate them. For Elestio → official images, follow README → "Moving an existing database to the official images": rehearse a logical application dump into a separate empty volume, stop writers for the final transfer, validate Laravel and retain the source for rollback. MySQL 8.0 → 8.4 is also a version upgrade. Do not attach the old volume to the replacement image or remove it during migration; obtain explicit authorization before changing a production database.

### 3. Build the command and show it before running
```bash
sudo bash /opt/laraship/deploy-laravel.sh \
  --slug shop \
  --domain shop.example.com \
  --db-type postgres \
  --ssl-email admin@example.com
```
Along with the command, list the consequences:
- containers, the `<slug>` network and `<slug>_*` volumes will be created;
- `/var/www/nginxproxy` will be changed and restarted, which briefly affects all sites on the server;
- a Let's Encrypt certificate will be requested (Let's Encrypt has issuance rate limits);
- if `/var/www/<slug>` already exists, deployment is refused without replacing the project;
- with `--db-native` the DB and user will be created in the system DBMS;
- with `--endpoint` all passwords will be sent to an external URL;
- with `--repo` the application code is cloned from the given repository, and `--post-deploy` commands run in the php container.

**Run only after an explicit "yes".** One confirmation covers one command.

### 4. Run it
- The command takes a long time: images are built and composer runs. Run it in the background or with a large timeout. You can offer the user to run it themselves in their own SSH session (`ssh -t`).
- In a verification deployment without a TTY `filament:install --panels` ran without questions. In an interactive terminal the installer may ask something; keep the panel ID as `admin`, otherwise the panel will not be at `/admin`.
- The output contains passwords. Do not retell or quote them in the chat unless necessary.
- A failed migration or Filament installation stops deployment with a nonzero exit. Fix the existing project rather than trying to install over it (README → "Troubleshooting").
- The fresh Filament module configures production access for the provisioned administrator only, using `config/laraship.php`; other users and panels are denied. Horizon's dashboard stays restricted until the application defines its production authorization gate.

### 5. Check the result
```bash
cd /var/www/<slug> && docker compose ps            # php, nginx, db, redis, cron, certbot_renew must be Up
docker compose ps -a                               # artisan/composer/npm/permissions in Exited status is normal
docker compose logs --tail=50 php nginx db
docker ps --filter name=nginxproxy && docker logs --tail=30 nginxproxy
docker compose run --rm artisan migrate:status
docker compose run --rm certbot certificates
curl -sS -o /dev/null -w '%{http_code}\n' https://<domain>/            # 200 (or 401 with Basic Auth)
curl -sS -o /dev/null -w '%{http_code}\n' https://<domain>/admin/login # with Filament: 200 (or 401)
```
Before TLS is enabled, HTTP serves the application with HTTP APP_URL. After successful TLS application, HTTP redirects to HTTPS while ACME stays reachable. A missing application route may return 404; old copied templates require the HTTP/TLS migration from the README.

### 6. Report
Report the slug, the final domain, the site and panel URLs, the SSL and container status, and where the credentials are stored. Do not include passwords in the report unless the user asks for them.

## Credentials
- `/var/www/<slug>/.env` holds the ports, the Redis, DB and Basic Auth passwords, and `FILAMENT_ADMIN_*` and `BACKUP_ARCHIVE_PATH` if they were set.
- `/var/www/<slug>/public_html/.env` is Laravel's `.env` with `DB_*` and `APP_URL`.
- The summary block in the script output.
Read these files (`sudo cat ...`) only at the user's request and put only the needed values in the chat. With `--db-native` + MySQL, the `DB_MYSQL_PASSWORD_ROOT` value and the `Root Password` line in the summary are random; they are **not** the system MySQL root password.

## Common problems

| Symptom | Cause and what to do |
|---|---|
| `--ssl-email is required to obtain an SSL certificate` | Pass `--ssl-email` or `--no-ssl`. |
| `--filament-email is required to install Filament` | The check runs at startup, before any changes. Add the flag. |
| `The --repo URL must not contain credentials` | Use an SSH URL (`git@host:owner/repo.git`) with `--deploy-key PATH`. |
| `Failed to clone <url>` | Check the URL and branch; for a private repository the deploy key needs read access and an SSH URL. |
| `composer install failed` (with `--repo`) | The application needs a PHP version or extensions the php image lacks (PHP 8.3), or a private package. Read the composer output above. |
| `update.sh`: `public_html has uncommitted changes to tracked files` | Someone edited tracked files on the server. Commit, stash or discard them, then rerun. |
| `update.sh`: `Update failed at step: ...` | The application is left in maintenance mode. Fix the cause and rerun, or roll back with the commands the script printed (`git reset --hard <previous commit>`, `composer install`, `artisan up`). |
| `Unknown key X in FILE (line N)` / `Invalid line N in FILE` (with `--config`) | Keys are flag names in upper case with `_` (`DB_TYPE`); one `KEY=VALUE` per line; `--type` and `--config` are not keys. |
| `Invalid … in versions.env` | Fix the value: `LARAVEL_VERSION` is `X.Y`, `FILAMENT_VERSION` a composer constraint, images are `name:tag`. |
| `Unknown module: X` / `Invalid module name` | There is no `modules/X.sh`. Run `deploy-laravel.sh --list-modules`; names are lowercase letters, digits and `-`. |
| Horizon not running / `/horizon` is 403 | `docker compose logs horizon`, `artisan horizon:status`. Outside `APP_ENV=local` define the `viewHorizon` gate. Horizon needs `QUEUE_CONNECTION=redis` (the `redis` module sets it). |
| `Unknown preset: X` / `A preset cannot include another preset` | `--list-presets` shows the presets (files in `presets/`). A preset cannot contain `PRESET=`; combine presets with several `--preset` flags. |
| `backup.sh`: `was not deployed with the backup module` / `The backup container ... is not running` | The project needs `--with backup`; start the project (`activate.sh` or `docker compose up -d`) before `now`. |
| `Composer refused to install the requested versions ... security advisories` | The Laravel version (or the application's framework) is no longer supported: Laravel 10.x and 11.x cannot be installed today. Use a supported version (the default in `versions.env`, currently 13; 12 also works) or upgrade the application. Do not suggest turning Composer's blocking off without telling the user it installs known-vulnerable code. |
| `Template directory not found` | The script is not next to `laravel/` and `nginxproxy/`. |
| `$'\r': command not found` | The files have CRLF. Run `sed -i 's/\r$//'` on the scripts and templates. |
| `Failed to run Laravel migrations` | Deployment aborts before modules/routing. Inspect DB connectivity, credentials and migration errors; preserve data, repair migrations, complete pending modules (including Filament access), then attach routing through the checked transaction (README → "Migrations failed"). |
| `Failed to obtain an SSL certificate` | DNS, ports 80/443 or nginxproxy. HTTP stays available. Use the checked certificate/application procedure under the project lock (README → "SSL not obtained"). |
| nginxproxy in a restart loop | Port 80/443 is busy, `host not found in upstream` (`sites/` holds a project `*.conf` whose containers are not running), or the external network of an interrupted deployment. Check `docker logs nginxproxy`. |
| `composer` says a package requires a different PHP version | Composer runs in the PHP 8.3 image and checks platform requirements. Choose a compatible `--laravel-version`/Filament or change the Dockerfile (README → "Troubleshooting"). |
| 500 or `Permission denied` in `storage/` | Run `docker compose run --rm permissions`, especially after `npm` (runs as root) and manual edits as root. |
| 502 Bad Gateway | The php container is not running. Check `docker compose logs php`. |
| 413 or "file too large" | Limits: project nginx 900M, PHP 2M/8M by default because `php.ini` is not mounted (README → "Troubleshooting"). |
| Native DB: connection refused or timeout | The DBMS does not listen on the Docker host address (normally `172.17.0.1`), `pg_hba.conf` or `bind-address` does not admit the `<slug>` network's subnet, or a firewall is in the way. |

## Lifecycle
The utilities live in `/opt/laraship/` next to `deploy-laravel.sh` and require root (details: README → "Project management"). They do not depend on the project type and work with any project in `/var/www`, including Moodle and HTML:
- `sudo bash /opt/laraship/list-projects.sh` — lists projects, their status, SSL (by docker volume) and ports.
- `sudo bash /opt/laraship/deactivate.sh --slug <slug>` — switches a project off without deleting it. The containers are stopped, `nginxproxy/sites/<slug>.conf` is renamed to `.conf.disabled`, and the entries in the proxy compose are commented out.
- `sudo bash /opt/laraship/activate.sh --slug <slug>` — restores the config, brings the containers up and reattaches the proxy to the project network.
- `sudo bash /opt/laraship/remove.sh --slug <slug> --domain <domain>` — **irreversibly** removes the containers, volumes (including DB data), the network, the proxy config (including `.disabled`), the archive and the folder. For native MySQL add `--db-root-password`; a missing password/client aborts and retains remaining project metadata. The script interactively asks for `yes`: run it through `ssh -t` or hand it to the user. Do not bypass this prompt (`echo yes |`) without an explicit request. Get a separate confirmation before running it, and let the user type the root password themselves.
- `sudo bash /opt/laraship/backup.sh --slug <slug> now | list | restore <file> [--yes]` — database dumps of a project deployed with `--with backup` (one at start, then every 24 hours in `<project>/backups`, `--backup-keep` days, default 7). `restore` validates the archive before maintenance or stopping workers, then REPLACES the current database: ask the user before running it, and get a separate yes. MySQL needs temporary space for uncompressed SQL. The dumps live on the same server and are deleted by `remove.sh`, so tell the user to copy them off the machine. Older projects must migrate their copied restore script as described in the README.
- `sudo bash /opt/laraship/update.sh --slug <slug>` — updates a project deployed with `--repo`: fetches, enables maintenance using the old code, then fast-forwards the branch, runs composer and migrations, clears caches and restarts the queue worker and php. A maintenance failure stops before code changes; later failures keep maintenance and print rollback commands. Options: `--no-migrate`, `--post-deploy "cmds"`, `--reset` (force-pushed branches), `--force`. Refuses to run over uncommitted changes to tracked files.
- Re-running `deploy-laravel.sh` with the same slug is refused. `update.sh` enables maintenance on the old code before switching commits and aborts without changing code if maintenance fails (README → "Re-running the script").
