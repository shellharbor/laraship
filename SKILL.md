---
name: deploy-laravel
description: Use when you need to deploy a Laravel or Laravel+Filament site on an Ubuntu server with deploy-laravel.sh (Docker, shared nginxproxy, Let's Encrypt SSL, PostgreSQL/MySQL in a container or a native DB), or to prepare the command for it. Also use to diagnose, re-run, deactivate and remove such a deployment.
---

# Deploying Laravel (+ Filament) with deploy-laravel.sh

This skill belongs to the self-contained `laravel-deploy` folder (this file sits in its root). Full documentation: [README.md](README.md). Ready-made scenarios: [examples/](examples/README.md). The README also covers migrating from the old `deploy.sh` and updating servers deployed with an older version.
Take flags only from the "Arguments" table in the README (it has been checked against `parse_args`). Do not invent flags and do not use `--type` (it is kept only for compatibility).

## What the script does

`deploy-laravel.sh` runs on an Ubuntu server as root and:
- installs Docker (if missing) and creates, once, the shared reverse proxy `/var/www/nginxproxy` on ports 80/443;
- creates the project `/var/www/<slug>` from the `laravel/` template with its own Docker network `<slug>` and the containers php (8.3-FPM), nginx, db (PostgreSQL 17 / MySQL 8.0; absent with `--db-native`), redis, cron, certbot_renew, plus the utilities artisan, composer, npm and permissions;
- installs Laravel (`composer create-project laravel/laravel:^X.Y`, 13.0 by default) with composer in the same PHP 8.3 image as the `www` user, writes the DB settings and `APP_URL` to `public_html/.env` and runs migrations;
- with flags, installs Filament 5 (the `/admin` panel), enables Basic Auth, sends JSON to `--endpoint` and creates a zip archive;
- obtains a Let's Encrypt certificate (webroot) and enables the nginx HTTPS blocks.

The slug, passwords, DB names and ports that are not set explicitly are generated and printed to the console.

## Where it runs

All the scripts run only on the server. Do not run them on a local Windows machine. Work over SSH (ssh is available in both Git Bash and PowerShell):

```bash
ssh user@server 'sudo bash /opt/laravel-deploy/deploy-laravel.sh --help'
```

- The `laravel-deploy` folder must be on the server **as a whole**, usually at `/opt/laravel-deploy/`; confirm the path with the user. The script looks for `laravel/` and `nginxproxy/` next to itself. If the folder is not there, offer to copy it and wait for consent: `scp -r laravel-deploy user@server:~/`, then `sudo mv ~/laravel-deploy /opt/` (or `git clone`). Details: README → "Quick start".
- LF line endings are required. With CRLF bash fails with `$'\r': command not found` (see README → "Quick start").
- Never type SSH or sudo passwords for the user. If it does not work without a password, hand the user a ready command to run themselves.

## Prerequisites

- Ubuntu 20.04+, root or sudo, with `python3`, `curl` and `ss` installed.
- If Docker is already installed, the `docker compose` v2 plugin is required. If Docker is missing, the script installs it.
- The A record of the final domain points to the server. **Without `--slug` the domain becomes `<random-slug>.<domain>`**, so a wildcard record `*.<domain>` is needed, otherwise SSL cannot be obtained.
- Ports 80 and 443 on the server are free (nginxproxy will take them) and open from outside.
- `--db-native`: PostgreSQL or MySQL is installed and running on the host and listens on an address reachable from containers (`172.17.0.1`). `pg_hba.conf` must allow the docker subnets, and for MySQL check `bind-address` (on Ubuntu it defaults to `127.0.0.1`). The script does not configure this; it is the administrator's job.

A check that changes nothing on the server:

```bash
ssh user@server 'lsb_release -ds; python3 --version; docker --version; docker compose version; \
  ls -A /opt/laravel-deploy /opt/laravel-deploy/laravel; grep -c $'"'"'\r'"'"' /opt/laravel-deploy/deploy-laravel.sh; \
  sudo ss -tlnp | grep -E ":(80|443) "; ls /var/www; getent hosts <domain>'
```
Expected: `/opt/laravel-deploy` contains `deploy-laravel.sh`, `laravel/` and `nginxproxy/`, `laravel/` contains `.config` and `.docker`, and the CR count is `0`.

If `/var/www/nginxproxy` already exists, the proxy is shared: it may have been created by the Moodle or HTML kit, and that is fine. The script does not overwrite it, it only adds a network, a volume and `sites/<slug>.conf`.

## Workflow

### 1. Gather the parameters
Required parameters: `--domain`, `--db-type postgres|mysql` and `--ssl-email EMAIL` (or `--no-ssl`).
Be sure to ask the user about:
- **slug** (`--slug`). Advise setting it explicitly, in lowercase. Without it the domain gets a random prefix.
- **Filament**: `--install-filament --filament-email EMAIL`, name and password optional. Warn that `filament/filament:^5.0` is installed and that compatibility with the chosen `--laravel-version` (13.0 by default, minimum 10.0) must be checked in the Filament documentation.
- **Native DB**: `--db-native`, and for MySQL also `--db-root-password`. Check the prerequisites above.
- **Basic Auth**: `--enable-basic-auth`, optionally with `--auth-user` and `--auth-password`.
- Optional parameters: explicit DB credentials, ports, `--redis-password`, `--create-backup`, `--endpoint`.

Compose explicit passwords from the characters `A-Za-z0-9@%_+-`. Values go into `.env` without quotes and into JSON without escaping.

### 2. Check the server
Run the prerequisites check and find out whether `/var/www/<slug>` and the project's volumes already exist (`docker volume ls --filter name=<slug>_`). If they do, this is a **re-run**: the folder is deleted without asking, while the DB volume stays, and the new passwords will not apply to it. In that case offer to run `remove.sh` first or to pass the previous DB credentials explicitly (README → "Re-running the script").

### 3. Build the command and show it before running
```bash
sudo bash /opt/laravel-deploy/deploy-laravel.sh \
  --slug shop \
  --domain shop.example.com \
  --db-type postgres \
  --ssl-email admin@example.com
```
Along with the command, list the consequences:
- containers, the `<slug>` network and `<slug>_*` volumes will be created;
- `/var/www/nginxproxy` will be changed and restarted, which briefly affects all sites on the server;
- a Let's Encrypt certificate will be requested (Let's Encrypt has issuance rate limits);
- if `/var/www/<slug>` already exists, the containers will be stopped and the folder **deleted** together with the code;
- with `--db-native` the DB and user will be created in the system DBMS;
- with `--endpoint` all passwords will be sent to an external URL.

**Run only after an explicit "yes".** One confirmation covers one command.

### 4. Run it
- The command takes a long time: images are built and composer runs. Run it in the background or with a large timeout. You can offer the user to run it themselves in their own SSH session (`ssh -t`).
- In a verification deployment without a TTY `filament:install --panels` ran without questions. In an interactive terminal the installer may ask something; keep the panel ID as `admin`, otherwise the panel will not be at `/admin`.
- The output contains passwords. Do not retell or quote them in the chat unless necessary.
- If migrations fail, the script only warns. If the Filament installation fails, the script terminates: nginxproxy is not restarted and SSL is not obtained (README → "Troubleshooting").

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
The application is not served over HTTP: only the ACME challenge is served there, and there is no redirect to HTTPS. So a 404 over `http://` is normal, not an error.

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
| `Template directory not found` | The script is not next to `laravel/` and `nginxproxy/`. |
| `$'\r': command not found` | The files have CRLF. Run `sed -i 's/\r$//'` on the scripts and templates. |
| Warning `Failed to run Laravel migrations` | The DB did not come up within 10 s, wrong `DB_*`, or an old volume with a different password remained. Repeat `docker compose run --rm artisan migrate --force`. |
| `Failed to obtain an SSL certificate` | DNS, ports 80/443 or nginxproxy. The SSL blocks stay commented out. Obtain the certificate and uncomment the blocks manually (README → "SSL not obtained"). |
| nginxproxy in a restart loop | Port 80/443 is busy, `host not found in upstream` (`sites/` holds a project `*.conf` whose containers are not running), or the external network of an interrupted deployment. Check `docker logs nginxproxy`. |
| `composer` says a package requires a different PHP version | Composer runs in the PHP 8.3 image and checks platform requirements. Choose a compatible `--laravel-version`/Filament or change the Dockerfile (README → "Troubleshooting"). |
| 500 or `Permission denied` in `storage/` | Run `docker compose run --rm permissions`, especially after `npm` (runs as root) and manual edits as root. |
| 502 Bad Gateway | The php container is not running. Check `docker compose logs php`. |
| 413 or "file too large" | Limits: project nginx 900M, PHP 2M/8M by default because `php.ini` is not mounted (README → "Troubleshooting"). |
| Native DB: connection refused or timeout | The DBMS does not listen on `172.17.0.1`, `pg_hba.conf` or `bind-address` does not admit the `<slug>` network's subnet, or a firewall is in the way. |

## Lifecycle
The utilities live in `/opt/laravel-deploy/` next to `deploy-laravel.sh` and require root (details: README → "Project management"). They do not depend on the project type and work with any project in `/var/www`, including Moodle and HTML:
- `sudo bash /opt/laravel-deploy/list-projects.sh` — lists projects, their status, SSL (by docker volume) and ports.
- `sudo bash /opt/laravel-deploy/deactivate.sh --slug <slug>` — switches a project off without deleting it. The containers are stopped, `nginxproxy/sites/<slug>.conf` is renamed to `.conf.disabled`, and the entries in the proxy compose are commented out.
- `sudo bash /opt/laravel-deploy/activate.sh --slug <slug>` — restores the config, brings the containers up and reattaches the proxy to the project network.
- `sudo bash /opt/laravel-deploy/remove.sh --slug <slug> --domain <domain>` — **irreversibly** removes the containers, volumes (including DB data), the network, the proxy config (including `.disabled`), the archive and the folder. For native MySQL add `--db-root-password`, otherwise the script only prints the SQL for manual removal. The script interactively asks for `yes`: run it through `ssh -t` or hand it to the user. Do not bypass this prompt (`echo yes |`) without an explicit request. Get a separate confirmation before running it, and let the user type the root password themselves.
- Re-running `deploy-laravel.sh` with the same slug means reinstalling the code from scratch (README → "Re-running the script").
