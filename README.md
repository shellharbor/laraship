# LaraShip — deploy Laravel with Docker

![Laraship deploy Laravel with Docker Bash script](https://i.postimg.cc/Vv1vG8nL/laraship-hero-banner.jpg)

[![Lint](https://github.com/shellharbor/laraship/actions/workflows/lint.yml/badge.svg)](https://github.com/shellharbor/laraship/actions/workflows/lint.yml)
[![Tests](https://github.com/shellharbor/laraship/actions/workflows/tests.yml/badge.svg)](https://github.com/shellharbor/laraship/actions/workflows/tests.yml)
[![E2E](https://github.com/shellharbor/laraship/actions/workflows/e2e.yml/badge.svg)](https://github.com/shellharbor/laraship/actions/workflows/e2e.yml)
[![Kubernetes](https://github.com/shellharbor/laraship/actions/workflows/kubernetes.yml/badge.svg)](https://github.com/shellharbor/laraship/actions/workflows/kubernetes.yml)
[![CodeQL](https://github.com/shellharbor/laraship/actions/workflows/codeql.yml/badge.svg)](https://github.com/shellharbor/laraship/actions/workflows/codeql.yml)

`deploy-laravel.sh` deploys a Laravel site, optionally with the Filament admin panel, on an Ubuntu server. Every site runs in its own set of Docker containers, and traffic is accepted by a shared reverse proxy, `nginxproxy`. The script installs Docker, creates the project from the `laravel/` template, installs Laravel, sets up PostgreSQL or MySQL (in a container or native on the host) and obtains a Let's Encrypt SSL certificate.

The `laraship` folder is self-contained: it holds the deploy script, templates, management utilities, examples and a skill for Claude Code. Copy it to the server as a whole (for example, to `/opt/laraship/`) and run the scripts **on the server as root**. From your workstation (for example, Windows) connect to the server over SSH.

LaraShip also has a **CLI Docker image** with the same Bash tools and their dependencies, plus a separate **Kubernetes backend** for existing applications built into immutable images. Native Bash remains supported. See [Docker runner](docs/CONTAINERS.md) and [Kubernetes deployment, image contract and scope](docs/KUBERNETES.md). Existing Compose projects and database volumes are not converted automatically.

---

## Contents

- [Folder contents](#folder-contents)
- [Architecture](#architecture)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [LaraShip CLI image](docs/CONTAINERS.md)
- [Kubernetes backend](docs/KUBERNETES.md)
- [Arguments](#arguments)
- [Configuration file and versions](#configuration-file-and-versions)
- [Presets and dry run](#presets-and-dry-run)
- [What the script does](#what-the-script-does)
- [.env files](#env-files)
- [Database connection](#database-connection)
- [Filament](#filament)
- [Modules](#modules)
- [Database backups](#database-backups)
- [Deploying an existing application](#deploying-an-existing-application)
- [Examples](#examples)
- [Useful commands](#useful-commands)
- [Project management](#project-management)
- [Re-running the script](#re-running-the-script)
- [Sending data to an endpoint](#sending-data-to-an-endpoint)
- [Security](#security)
- [Laravel versions and conditions](#laravel-versions-and-conditions)
- [Troubleshooting / FAQ](#troubleshooting--faq)
- [Known limitations](#known-limitations)
- [Migrating from the old deploy.sh](#migrating-from-the-old-deploysh)
- [Updating an already deployed server](#updating-an-already-deployed-server)
- [Tests and CI](#tests-and-ci)

---

## Folder contents

```
laraship/
├── deploy-laravel.sh              # deploys Laravel (+ Filament); help: --help
├── VERSION                        # the version of this release (deploy-laravel.sh --version)
├── versions.env                   # default versions: Laravel, Filament, database images
├── modules/                       # optional features enabled with --with (filament, redis, queue, horizon)
├── presets/                       # named bundles of settings for --preset (admin-panel, api, staging)
├── activate.sh                    # re-enable a deactivated project
├── deactivate.sh                  # switch a project off without deleting it
├── remove.sh                      # remove a project completely
├── list-projects.sh               # list projects on the server
├── update.sh                      # update a project deployed with --repo
├── backup.sh                      # database dumps of a project deployed with --with backup: now, list, restore
├── laravel/                       # project template → /var/www/<slug>
│   ├── docker-compose.yml
│   ├── .config/nginx/_site.conf
│   ├── .config/php/php.ini, project.ini
│   └── .docker/                   # php/php81–83.Dockerfile, nginx/*.Dockerfile
├── nginxproxy/                    # shared proxy template → /var/www/nginxproxy
│   ├── nginx.conf
│   ├── nginx.Dockerfile
│   └── site-template.conf
├── examples/                      # ready-made launch scenarios (see examples/README.md)
├── tests/                         # bats tests and the local sandbox runner
├── README.md                      # this file (English documentation)
├── CONTRIBUTING.md, SECURITY.md   # how to contribute; how to report a vulnerability
├── .gitignore
```

The script looks for the `laravel/` and `nginxproxy/` templates next to itself, so the folder must be moved as a whole. `examples/`, `README.md`, `tests/` and `SKILL.md` are not required on the server, but they do no harm.

**The utilities do not depend on the project type.** `activate.sh`, `deactivate.sh`, `remove.sh` and `list-projects.sh` work with any project in `/var/www`, including ones deployed by the Moodle or HTML kits.

**`/var/www/nginxproxy` is shared by all projects on the server.** It is created once from the `nginxproxy/` template of whichever kit's deploy script runs on the server first. The proxy templates are identical in all three kits (Laravel, Moodle, HTML), and the script never overwrites an existing `/var/www/nginxproxy`. If you edit the `nginxproxy/` template or the utilities in this folder, carry the change over to the other kits so that the copies do not diverge.

---

## Architecture

```
/var/www/
├── nginxproxy/                     # Shared reverse proxy, the only one listening on 80/443
│   ├── docker-compose.yml          # Generated on first run; per-site networks and SSL volumes are added here
│   ├── nginx.conf                  # include /etc/nginx/sites/*.conf, client_max_body_size 2048m
│   ├── nginx.Dockerfile            # nginx:1.29.1-alpine
│   ├── site-template.conf          # Site config template (SLUG and DOMAIN placeholders)
│   └── sites/
│       └── <slug>.conf             # upstream + server blocks 80/443; after deactivate.sh it becomes <slug>.conf.disabled
└── <slug>/                         # Site project
    ├── docker-compose.yml          # Project services, see below
    ├── .env                        # Project ports and passwords (generated by the script)
    ├── .config/
    │   ├── nginx/
    │   │   ├── _site.conf          # HTTP/TLS server blocks inside the project nginx
    │   │   ├── _app.conf           # Shared Laravel routes and Basic Auth
    │   │   ├── dhparam.pem         # Only with --create-dhparam
    │   │   └── .htpasswd           # Only with --enable-basic-auth
    │   └── php/
    │       ├── php.ini             # Copied, but not mounted by default (the line in compose is commented out)
    │       └── project.ini         # Project PHP overrides, mounted into the php container (empty by default; see --php-upload-max)
    ├── .docker/
    │   ├── php/                    # php81/php82/php83.Dockerfile
    │   └── nginx/                  # nginx-1.27.2/nginx-1.29.1.Dockerfile
    └── public_html/                # Laravel code (created during installation)
```

Besides files, a project has:
- a Docker network `<slug>`;
- volumes `<slug>_db` (absent with `--db-native`), `<slug>_redis_data`, `<slug>_ssl_certificates` and `<slug>_certbot_www`.

### Project services (`laravel/docker-compose.yml`)

| Service | Container | Image | Purpose |
|---|---|---|---|
| `php` | `<slug>_php` | `php83.Dockerfile` (PHP 8.3-FPM) | Runs Laravel. Port 9000 is published only on `127.0.0.1:${PHP_PORT}` |
| `nginx` | `<slug>_nginx` | `nginx-1.29.1.Dockerfile` | The project's web server, `root /var/www/html/public`. Ports `SITE_PORT_HTTP` → 80 and `SITE_PORT_HTTPS` → 443. Runs `nginx -s reload` every 6 hours to pick up a renewed certificate |
| `db` | `<slug>_db` | Docker Official Image `postgres:17` or `mysql:8.4` | The project's database. Host port `DB_PORT` → 5432/3306. The template contains `db_postgres` and `db_mysql`: the unused one is removed, the chosen one is renamed to `db`. With `--db-native` both are removed |
| `redis` | `<slug>_redis` | `redis:7-alpine` | Redis with a password (`--requirepass`) and AOF. Host port `REDIS_PORT` → 6379 |
| `certbot` | `<slug>_certbot` | `certbot/certbot` | Certificate issuance. Profile `manual`: does not start on `up`, run it with `docker compose run --rm certbot ...` |
| `certbot_renew` | `<slug>_certbot_renew` | `certbot/certbot` | Runs `certbot renew --webroot` every 12 hours (a loop set via `entrypoint`). nginx picks up the new certificate by itself thanks to the periodic reload |
| `artisan` | `<slug>_artisan` | `php83.Dockerfile` | Utility: `docker compose run --rm artisan <command>`, runs as `www` (uid 1000) |
| `composer` | `<slug>_composer` | `php83.Dockerfile` (+ composer 2) | Utility: `docker compose run --rm composer <command>`. Runs on the same PHP 8.3 as the application, as `www` (uid 1000), and checks package PHP requirements |
| `npm` | `<slug>_npm` | `node:current-alpine` | Utility: `npm ...`, runs as root |
| `cron` | `<slug>_cron` | `php83.Dockerfile` | Runs `php artisan schedule:run` every 60 seconds |
| `queue` | `<slug>_queue` | `php83.Dockerfile` | **Optional**, added by the `queue` module (`--with queue`): a queue worker (`php artisan queue:work`). Not part of the template |
| `horizon` | `<slug>_horizon` | `php83.Dockerfile` | **Optional**, added by the `horizon` module (`--with horizon`): `php artisan horizon` |
| `permissions` | `<slug>_permissions` | `busybox` | Utility: `chown 1000:1000`, permissions 644/755, 775 for `storage` and `bootstrap/cache`, and 600 for Laravel `.env` |

The `artisan`, `composer`, `npm` and `permissions` utilities have no profile. Because of that `docker compose up -d` also creates their containers, which exit immediately. The `Exited` status for them is normal.

### How it works

- **A separate network per project.** All project containers live in the `<slug>` network and reach each other by name (`<slug>_db`, `<slug>_redis`, and so on).
- **A single nginxproxy on 80/443.** The `nginxproxy` container is attached to all project networks as external ones (`external: true`). By `server_name` it proxies HTTP to `<slug>_nginx:80` and HTTPS to `<slug>_nginx:443`. nginxproxy takes the site certificate from the `<slug>_ssl_certificates` volume mounted at `/etc/letsencrypt/<slug>`.
- **Each site's config is a separate file:** `nginxproxy/sites/<slug>.conf`.
- **Certificates are picked up automatically.** Both the project nginx and `nginxproxy` (in new installations) run `nginx -s reload` every 6 hours. How to add this to a server deployed with an older version is described in [Updating an already deployed server](#updating-an-already-deployed-server).
- **The proxy is shared by the whole server.** Laravel, Moodle and HTML projects on one server use the same `/var/www/nginxproxy` (see [Folder contents](#folder-contents)).

---

## Requirements

- **OS:** Ubuntu 20.04+ on the server.
- **Privileges:** root (`sudo`).
- **Packages:** `python3`, `curl`, `ss` (iproute2), `flock` (util-linux), `pgrep` (procps) and `timeout` (coreutils). `zip` is installed automatically with `--create-backup`.
- **Docker:** if there is no `docker` command, the script installs Docker CE and the compose plugin from the download.docker.com repository. If Docker is already installed, the `docker compose` v2 plugin is required.
- **DNS:** the A record of the final domain points to the server. Without `--slug` the domain becomes `<random-slug>.<domain>`, so a wildcard record `*.<domain>` is needed.
- **Ports 80 and 443** are free on the server (nginxproxy will take them) and reachable from the internet: Let's Encrypt validates the domain over HTTP.
- **Internet access:** Docker Hub, packagist, npm, Let's Encrypt.
- **For `--db-native`:** PostgreSQL or MySQL installed and running on the host with the network configuration described in [Database connection](#database-connection).

---

## Quick start

### 1. Copy the folder to the server

Copy the `laraship` folder **as a whole**, for example to `/opt/laraship/`. The script looks for the `laravel/` and `nginxproxy/` templates next to itself, including the hidden `laravel/.config/` and `laravel/.docker/`. The layout is described in [Folder contents](#folder-contents).

From your workstation (PowerShell or Git Bash), from the directory that contains `laraship`:

```bash
# if you have SSH access as root
scp -r laraship root@server:/opt/

# as a regular user with sudo
scp -r laraship user@server:~/
ssh user@server 'sudo rm -rf /opt/laraship && sudo mv ~/laraship /opt/'
```

You can also put the folder into a separate git repository and run `git clone` on the server into `/opt/laraship`.

**Or install a release.** Every release is published on GitHub as a tarball with a SHA-256 checksum:

```bash
VERSION=1.1.1
curl -fsSLO https://github.com/shellharbor/laraship/releases/download/v${VERSION}/laraship-${VERSION}.tar.gz
curl -fsSLO https://github.com/shellharbor/laraship/releases/download/v${VERSION}/laraship-${VERSION}.tar.gz.sha256
sha256sum -c laraship-${VERSION}.tar.gz.sha256
tar xzf laraship-${VERSION}.tar.gz
sudo rm -rf /opt/laraship && sudo mv laraship-${VERSION} /opt/laraship
bash /opt/laraship/deploy-laravel.sh --version
```

**Upgrading** is the same: replace the folder. Projects that are already deployed are never modified by the scripts; the notes of each release in [CHANGELOG.md](CHANGELOG.md) say what to change by hand in older projects, if anything.

If the files passed through Windows, check the line endings. With CRLF, bash fails with `$'\r': command not found`:

```bash
grep -c $'\r' /opt/laraship/deploy-laravel.sh      # should be 0
# fix:
sudo find /opt/laraship -type f \( -name '*.sh' -o -name '*.yml' -o -name '*.conf' -o -name '*Dockerfile' \) \
  -exec sed -i 's/\r$//' {} +
```

### 2. Run it

```bash
sudo bash /opt/laraship/deploy-laravel.sh \
  --slug shop \
  --domain shop.example.com \
  --db-type postgres \
  --ssl-email admin@example.com
```

Ports, passwords and database credentials that are not given explicitly are generated automatically. The script prints them to the console and saves them in `/var/www/shop/.env` (mode 600). New applications use `APP_ENV=production`, `APP_DEBUG=false`, and loopback-only project ports. The shared proxy accepts public traffic on 80/443. An existing project path is refused without replacing its files; `nginxproxy` is a reserved slug.

Flag reference (root is not needed):

```bash
bash /opt/laraship/deploy-laravel.sh --help
```

---

## Arguments

The table follows `parse_args` and the `--help` header of the script. An unknown flag produces the error `Unknown argument`.

### Required

| Argument | Value | Description |
|---|---|---|
| `--domain` | `DOMAIN` | The site domain. Allowed characters: `A-Za-z0-9.-`. If `--slug` is not given, a random slug is prepended to the domain: `example.com` → `a3f7k2m9.example.com` |
| `--db-type` | `postgres` \| `mysql` | Database type |
| `--ssl-email` | `EMAIL` | Email for Let's Encrypt. Required unless `--no-ssl` is given |

### Project

| Argument | Value | Default | Description |
|---|---|---|---|
| `--slug` | `SLUG` | random 8 chars `a-z0-9` | Project identifier: folder name, network, prefix of containers and volumes. Format `^[A-Za-z0-9][A-Za-z0-9_-]*$`, lowercase is recommended. If given, the domain is **not** changed |
| `--laravel-version` | `X.Y` | `LARAVEL_VERSION` from `versions.env` (13.0) | Laravel version, installed as `laravel/laravel:^X.Y`. Minimum `12.0` (`LARAVEL_MIN_VERSION` in `versions.env`): Laravel 10.x and 11.x are no longer supported and are refused up front |
| `--create-backup` | — | off | After deployment, create `/tmp/<slug>_<YYYYmmdd_HHMMSS>.zip` from the project folder |
| `--endpoint` | `URL` | — | Send the project data as JSON with PUT (see [below](#sending-data-to-an-endpoint)) |
| `--type` | `laravel` | — | Only for compatibility with the old `deploy.sh`. Any other value is an error. Do not use it in new commands |

### Modules

| Argument | Value | Default | Description |
|---|---|---|---|
| `--with` | `NAME[,NAME]` | — | Enable modules (see [Modules](#modules)), for example `--with filament,horizon`. In a `--config` file the key is `WITH` |
| `--list-modules` | — | — | Print the available modules and exit (no root needed) |
| `--backup-keep` | `DAYS` | `7` | Days to keep the database dumps of the `backup` module (1-3650) |

`--install-filament`, `--use-redis` and `--queue-worker` are aliases of `--with filament`, `--with redis` and `--with queue`.

### Filament

| Argument | Value | Default | Description |
|---|---|---|---|
| `--install-filament` | — | off | Alias of `--with filament`. Install `filament/filament` (constraint `FILAMENT_VERSION` from `versions.env`, `^5.0`) and the `/admin` panel |
| `--filament-email` | `EMAIL` | — | Administrator email. **Required** with `--install-filament`; checked immediately at startup |
| `--filament-name` | `NAME` | 8 chars `a-f0-9` | Administrator name |
| `--filament-password` | `PASS` | 10 chars `a-zA-Z0-9` | Administrator password |

### Configuration file

| Argument | Value | Default | Description |
|---|---|---|---|
| `--config` | `FILE` | — | Read settings from a `KEY=VALUE` file (see [Configuration file and versions](#configuration-file-and-versions)). Flags on the command line override the file. Can be given once |

### Presets and dry run

| Argument | Value | Default | Description |
|---|---|---|---|
| `--preset` | `NAME` | — | Apply a preset from `presets/` (repeatable). Order: presets, then the `--config` file, then command-line flags; a later one overrides an earlier one. In a `--config` file: `PRESET=name` |
| `--list-presets` | — | — | Print the available presets and exit (no root needed) |
| `--dry-run` | — | — | Print the effective settings (no secrets) and exit. Changes nothing and needs no root |

### Existing application

Instead of a fresh Laravel skeleton, deploy your own application from git (see [Deploying an existing application](#deploying-an-existing-application)).

| Argument | Value | Default | Description |
|---|---|---|---|
| `--repo` | `URL` | — | Git repository of a Laravel application: `https://…`, `ssh://…`, `git@host:owner/repo.git` (or `file://` for a local repository). The URL must **not contain credentials** (`https://user:pass@…`, `https://token@…` are refused). Cannot be combined with `--install-filament` or `--laravel-version` |
| `--branch` | `BRANCH` | the repository's default branch | Branch to deploy; `update.sh` follows the same branch. Requires `--repo` |
| `--deploy-key` | `PATH` | — | SSH private key for a private repository. Requires `--repo` with an SSH URL. The key is copied into the project (`.config/deploy_key`, mode 600) so that `update.sh` can reuse it |
| `--post-deploy` | `"COMMANDS"` | — | A single line of shell commands run inside the php container (`/var/www/html`) after the deployment, for example `php artisan db:seed --force`. Works with or without `--repo`. `update.sh` reruns them after each update |

### Database

| Argument | Value | Default | Description |
|---|---|---|---|
| `--db-native` | — | off | Use the host's DBMS instead of the `db` container |
| `--db-root-password` | `PASS` | — | Root password of the **native** MySQL. Required with `--db-native` + `--db-type mysql`. Never stored |
| `--db-postgres-name` | `NAME` | generated | PostgreSQL database name |
| `--db-postgres-user` | `USER` | generated | PostgreSQL user |
| `--db-postgres-password` | `PASS` | generated | PostgreSQL password |
| `--db-mysql-name` | `NAME` | generated | MySQL database name |
| `--db-mysql-user` | `USER` | generated | MySQL user |
| `--db-mysql-password` | `PASS` | generated | MySQL user password |
| `--db-mysql-root-password` | `PASS` | generated | MySQL root password **inside the container** (`MYSQL_ROOT_PASSWORD`). Not used with `--db-native` |

The `--db-postgres-*` flags are honored only with `--db-type postgres`, and the `--db-mysql-*` flags only with `--db-type mysql`. Generated names are 15 characters, the first being a letter: `[a-z][a-z0-9]{14}`. Generated passwords are 15 characters from the set `A-Za-z0-9@%_+-`.

Explicit database names and users must match `[A-Za-z0-9_][A-Za-z0-9_-]*`: PostgreSQL allows at most 63 characters, MySQL database names 64 and MySQL users 32. Native databases and containerized PostgreSQL accept password quotes, backslashes, spaces, `$` and `#`. Containerized MySQL rejects single/double quotes and backslashes in both user and root passwords before Docker starts: the official image's initializer still embeds these values in SQL/client configuration. Its application user cannot be `root`; use `--db-root-password` for the separate root account. All DB passwords reject control characters. Separate Compose/Laravel encoding preserves literal credential values.

### Ports

Explicitly given ports are used as is, without checking whether they are busy. The rest are picked randomly from a range. A port counts as free if nothing is currently listening on it according to `ss`. Up to 100 attempts are made.

| Argument | Service | Auto range | Note |
|---|---|---|---|
| `--port-http` | project nginx HTTP | 8100–8400 | `SITE_PORT_HTTP` |
| `--port-https` | project nginx HTTPS | 4100–4300 | `SITE_PORT_HTTPS` |
| `--port-php` | PHP-FPM | 9100–9600 | `PHP_PORT`, published only on `127.0.0.1` |
| `--port-redis` | Redis | 6500–6800 | `REDIS_PORT` |
| `--port-postgres` | PostgreSQL | 5500–5800 | With `--db-native` defaults to `5432` |
| `--port-mysql` | MySQL | 3400–3600 | With `--db-native` defaults to `3306` |

For a containerized DB this is the port **published on the host**. Inside the project network the DB always listens on 5432/3306. For a native DB it is the DBMS port on the host, and it is written to Laravel's `DB_PORT`.

### Other

| Argument | Value | Default | Description |
|---|---|---|---|
| `--redis-password` | `PASS` | generated | Redis password |
| `--create-dhparam` | — | off | Create `/var/www/<slug>/.config/nginx/dhparam.pem` (2048 bits, takes several minutes) and mount it into the project nginx (see [limitations](#known-limitations)) |
| `--enable-basic-auth` | — | off | Enable HTTP Basic Auth in the project nginx |
| `--auth-user` | `USER` | generated (15 chars) | Basic Auth user |
| `--auth-password` | `PASS` | generated (15 chars) | Basic Auth password |
| `--no-ssl` | — | — | Do not obtain an SSL certificate. `--ssl-email` is then not needed |
| `--bind-local` | — | on | Compatibility flag; all project ports are loopback-only by default. The shared nginxproxy reaches projects over their Docker networks |
| `--use-redis` | — | off | Alias of `--with redis`: wire Redis into Laravel's `.env` (`REDIS_CLIENT`, `REDIS_HOST=<slug>_redis`, `REDIS_PORT=6379`, `REDIS_PASSWORD`) and switch the cache (`CACHE_STORE`, or `CACHE_DRIVER` on Laravel 10), `SESSION_DRIVER` and `QUEUE_CONNECTION` to `redis` |
| `--queue-worker` | — | off | Alias of `--with queue`: run the `<slug>_queue` container (`php artisan queue:work`). The worker uses the `QUEUE_CONNECTION` from Laravel's `.env`; with `sync` (or unset) the script warns because the worker would stay idle. Combine with `--with redis` for a Redis queue |
| `--php-upload-max` | `SIZE` | PHP defaults (2M/8M) | Set `upload_max_filesize` and `post_max_size` to `SIZE` (for example `64M`, `1G`) in `.config/php/project.ini` |
| `--obtain-ssl` | — | on | Obtain a certificate. This is the default behavior anyway; the flag is accepted but not listed in `--help`. Of `--no-ssl` and `--obtain-ssl` the last one wins |
| `-h`, `--help` | — | — | Show the help and exit. Checked before the root check |
| `-V`, `--version` | — | — | Print the version (from the `VERSION` file) and exit |

## Configuration file and versions

### Configuration file (`--config`)

Every setting of the command line can live in a `KEY=VALUE` file, which makes a deployment repeatable and reviewable:

```bash
cp /opt/laraship/examples/deploy.config.example /root/shop.conf
chmod 600 /root/shop.conf        # it holds passwords
sudo bash /opt/laraship/deploy-laravel.sh --config /root/shop.conf
```

```env
# /root/shop.conf
SLUG=shop
DOMAIN=shop.example.com
DB_TYPE=postgres
SSL_EMAIL=admin@example.com
INSTALL_FILAMENT=true
FILAMENT_EMAIL=admin@example.com
USE_REDIS=true
QUEUE_WORKER=true
PHP_UPLOAD_MAX=64M
```

Rules:
- The key is the flag name in upper case with `_` for `-`: `DB_TYPE` is `--db-type`, `PORT_HTTP` is `--port-http`, `POST_DEPLOY` is `--post-deploy`. Every flag except `--type`, `--config` and `--list-modules` works as a key.
- Boolean flags (`INSTALL_FILAMENT`, `NO_SSL`, `USE_REDIS`, `DB_NATIVE`, …): `true`, `yes`, `1` or `on` turns the flag on; `false`, `no`, `0`, `off` or an empty value leaves it off. Any other value is an error.
- One `KEY=VALUE` per line. `#` starts a comment, blank lines are ignored, spaces around `=` are allowed, and a value may be wrapped in `"…"` or `'…'`. Windows (CRLF) line endings work.
- The file is **parsed, never sourced**: nothing is expanded or executed, `$` and backticks are literal. A value ends at the end of the line.
- An empty value is ignored (`SLUG=` behaves as if the flag was not given, so the slug is generated).
- **Flags on the command line override the file**, so one value can be changed without editing it: `--config shop.conf --slug shop-staging --no-ssl`.
- An unknown key, a line that is not `KEY=VALUE`, an invalid boolean, a missing file or a second `--config` stops the script before anything is changed.
- If the file is readable by other users the script warns; keep it at mode 600, because it can hold passwords and `DEPLOY_KEY` paths.

### Versions (`versions.env`)

The versions the script installs live in one file next to the script, `versions.env`, instead of being scattered through the code:

```env
LARAVEL_VERSION=13.0                    # default of --laravel-version
LARAVEL_MIN_VERSION=12.0                # the oldest version --laravel-version accepts
FILAMENT_VERSION=^5.0                   # composer constraint for --install-filament
POSTGRES_IMAGE=postgres:17             # Docker Official Image, PostgreSQL 17
MYSQL_IMAGE=mysql:8.4                  # Docker Official Image, MySQL 8.4 LTS
```

Editing this file selects versions for **new deployments**. Database major upgrades also need compatibility checks and a data migration; see [Moving an existing database to the official images](#moving-an-existing-database-to-the-official-images). These tags follow their explicit version lines, rather than `latest`; they are not digest pins. `--laravel-version` (or `LARAVEL_VERSION` in a `--config` file) overrides the default for a single deployment. The file uses the same strict parsing (never sourced); an invalid value or an unknown key stops the script. If the file is missing, the built-in defaults above are used. PHP (8.3), Redis, nginx, Node and the other service images are still chosen by the template Dockerfiles and `laravel/docker-compose.yml`.

## Presets and dry run

### Presets (`--preset`)

A preset is a named bundle of settings: a `--config` file shipped with the script in `presets/<name>.conf`. It makes a common choice easy to repeat without copying a list of flags.

```bash
bash /opt/laraship/deploy-laravel.sh --list-presets

sudo bash /opt/laraship/deploy-laravel.sh \
  --domain api.example.com --db-type postgres --ssl-email admin@example.com \
  --preset api
```

| Preset | What it sets |
|---|---|
| `admin-panel` | Modules `filament`, `redis`, `queue`; ports on `127.0.0.1` only. Needs `--filament-email` |
| `api` | Module `horizon` (which enables `redis`); ports on `127.0.0.1` only; 16M PHP uploads |
| `staging` | HTTP Basic Auth (generated credentials unless given), module `redis`; ports on `127.0.0.1` only |

Settings are applied in this order, and a later one overrides an earlier one: **presets** (in the order of the `--preset` flags), then the **`--config` file** (which can name a preset with `PRESET=name`), then the **command-line flags**. A preset can only **add**: modules accumulate, and a boolean flag a preset turns on cannot be turned off by a later `false`. Values can be overridden: `--preset api --php-upload-max 256M` gives 256M.

Your own presets are files in `presets/` (`[a-z][a-z0-9-]*.conf`, the [`--config` format](#configuration-file-and-versions), first line `# Description: …`). Shipped presets hold no secrets, domain or slug; see [presets/README.md](presets/README.md).

### Dry run (`--dry-run`)

`--dry-run` parses and validates everything, prints what would be deployed and exits. It changes nothing, needs no root and never prints generated passwords (they are shown as `<generated>`), so it is a safe way to check a preset, a config file or a set of flags:

```bash
bash /opt/laraship/deploy-laravel.sh --dry-run --preset api \
  --domain api.example.com --db-type postgres --ssl-email admin@example.com
```

```
Effective settings (dry run: nothing was changed)

  Presets:      api
  Config file:  none
  Slug:         2h8f3k1q
  Domain:       2h8f3k1q.api.example.com
  Source:       fresh Laravel ^13.0
  Database:     postgres, in a container
  Modules:      redis, horizon
  Ports:        published on 127.0.0.1 only
  PHP uploads:  upload_max_filesize = post_max_size = 16M
  ...
```

Errors are reported exactly as in a real run, so a dry run that succeeds will pass validation when deployed.

---

## What the script does

The deployment follows these stages. Fatal errors prevent the final success summary.

| Stage | Behavior |
|---|---|
| Validation | Parse presets/config/flags; validate identifiers, secrets and ports. Dry run stops here. |
| Preflight | Require runtime tools, lock the project, reject an existing target, assign ports and reject occupied/duplicate bindings. Ports 80/443 belong to the shared proxy. |
| Project | Install Docker if needed, copy templates, write private .env, create Basic Auth credentials through stdin, and generate optional project-local DH parameters. TLS remains disabled without certificates. |
| Database | Provision native SQL safely if requested, build/start services, and retry authenticated application DB connections for up to 120 seconds. |
| Application | Install a skeleton or Git checkout, configure production settings and HTTP APP_URL, and require initial migrations to succeed. |
| Modules | Run hooks, require successful Compose generation, validate the candidate YAML before replacing the file, then start added services. Initial migrations precede module install hooks. |
| Readiness | Run post-deploy commands and check project HTTP with bounded retries. An API root 404 is accepted; connection/server errors abort. |
| Shared proxy | Lock, snapshot, edit a private candidate, validate Compose and Nginx with candidate networks/volumes, apply and check readiness. Restore prior configuration on failure; retain recovery files if rollback fails. |
| SSL | Request a certificate unless --no-ssl. Request failure leaves HTTP available. Validate/reload project TLS, transact proxy TLS, enable the redirect and update APP_URL after successful application. |
| Delivery | Optionally send encoded JSON with finite timeouts and publish a mode-600 ZIP without replacing a path; print the resulting scheme, credentials and next steps. |

Operations on one project share a persistent lock under `/run/lock/laraship`. Proxy edits acquire the global proxy lock after the project lock. Locks coordinate updated LaraShip scripts; manual Docker commands and older sibling kits need separate scheduling. Incomplete or symlink-containing proxy trees are refused.

A failed proxy rollback prints its private recovery directory. Preserve it, restore configuration from `original`, validate Compose/Nginx and start the proxy before retrying. Deactivation/removal commit routing changes before stopping containers or deleting data.

---

## .env files

### `/var/www/<slug>/.env` — the project file

It is generated by the `write_project_env` function. There is no template `laravel/.env` any more. The file is read by `docker compose` when substituting variables into `docker-compose.yml`. The PostgreSQL format:

```env
SITE_HOST=shop.example.com
SITE_PORT_HTTP=8231
SITE_PORT_HTTPS=4175

PHP_PORT=9342

REDIS_PORT=6621
REDIS_PASSWORD=<15 chars>

DB_PORT=5634
DB_POSTGRES_NAME=<15 chars>
DB_POSTGRES_USER=<15 chars>
DB_POSTGRES_PASSWORD=<15 chars>

DB_NATIVE=false
```

For MySQL, this is written instead of the `DB_POSTGRES_*` block:

```env
DB_PORT=3478
DB_MYSQL_NAME=...
DB_MYSQL_USER=...
DB_MYSQL_PASSWORD=...
DB_MYSQL_PASSWORD_ROOT=...
```

What is appended to the file depending on flags:

```env
# with --enable-basic-auth (right at generation, after DB_NATIVE)
AUTH_USER=...
AUTH_PASSWORD=...

# with --install-filament (after the user is created successfully)
# Filament Admin Credentials
FILAMENT_ADMIN_NAME=...
FILAMENT_ADMIN_EMAIL=...
FILAMENT_ADMIN_PASSWORD=...

# with --create-backup (at the very end)
# Backup Archive
BACKUP_ARCHIVE_PATH=/tmp/<slug>_<YYYYmmdd_HHMMSS>.zip
```

`DB_PORT` here is the port on the **host**: the published port of the containerized DB or the port of the native DBMS. Laravel does not use it (see [Database connection](#database-connection)). A full example is in [examples/project.env.example](examples/project.env.example).

### `/var/www/<slug>/public_html/.env` — the Laravel file

The file is created by Laravel itself during `create-project`, or copied from `.env.example` with `--repo`. It belongs to uid 1000 and has mode 600. The script sets:

```env
APP_URL=https://<domain>
APP_ENV=production
APP_DEBUG=false
DB_CONNECTION=pgsql            # or mysql
DB_HOST=<slug>_db              # native DB: the Docker host (normally 172.17.0.1)
DB_PORT=5432                   # mysql: 3306; native DB — the DBMS port on the host
DB_DATABASE=...
DB_USERNAME=...
DB_PASSWORD=...
```

Other settings stay as in the application's `.env`; `APP_KEY` is preserved. Redis is **not written** to Laravel's `.env` unless you pass `--use-redis` (or `--with redis`). Without it, configure Redis by hand if needed:

```env
REDIS_HOST=<slug>_redis
REDIS_PORT=6379                # the internal port, not REDIS_PORT from the project .env
REDIS_PASSWORD=<REDIS_PASSWORD from /var/www/<slug>/.env>
# optionally: CACHE_STORE=redis (Laravel 11+) / CACHE_DRIVER=redis (Laravel 10), SESSION_DRIVER=redis, QUEUE_CONNECTION=redis
```

After editing, run `docker compose run --rm artisan config:cache`. If Filament is installed, read about production in the [Filament](#filament) section.

---

## Database connection

### Containerized DB (default)

| Connecting from | Host | Port |
|---|---|---|
| Laravel and other project containers | `<slug>_db` | `5432` (PostgreSQL) / `3306` (MySQL) — internal |
| From the host (psql, mysql, SSH tunnel) | `127.0.0.1` | `DB_PORT` from `/var/www/<slug>/.env` — published |

The script writes the **internal** port to Laravel's `DB_PORT`. The external port is not listened on inside the project network. The published port binds to loopback (see [Security](#security)).

The official entrypoints create the configured database and account on the **first initialization of an empty volume**. PostgreSQL uses `POSTGRES_USER`, `POSTGRES_DB` and `POSTGRES_PASSWORD`; MySQL uses `MYSQL_USER`, `MYSQL_DATABASE`, `MYSQL_PASSWORD` and `MYSQL_ROOT_PASSWORD`. No additional PostgreSQL password-reset script is needed. With an existing volume these variables do not change the stored password. PostgreSQL 17 keeps its data at `/var/lib/postgresql/data`, MySQL at `/var/lib/mysql`.

### Native DB (`--db-native`)

- Laravel gets `DB_HOST` = the address of the Docker host as a container sees it: the gateway of Docker's default `bridge` network, read with `docker network inspect bridge` (`172.17.0.1` unless `bip` was changed in `/etc/docker/daemon.json`; the script falls back to `172.17.0.1` if it cannot read it). `DB_PORT` = `--port-postgres`/`--port-mysql`, defaulting to `5432`/`3306`.
- The DB is created through the default connection: `sudo -u postgres psql` or `mysql` with a temporary private option file. The port flags do not affect **where** the DB is created. They only change Laravel's `DB_PORT`.
- **PostgreSQL:** quoted `psql` variables create the user and database and grant privileges. Existing users/databases are checked explicitly and the **password is not changed**. Other SQL errors abort deployment.
- **MySQL:** `CREATE DATABASE IF NOT EXISTS`, `CREATE USER IF NOT EXISTS '<user>'@'%'`, `GRANT ALL PRIVILEGES ON <db>.* TO '<user>'@'%'`, `FLUSH PRIVILEGES`. The `'%'` host is needed because the application connects from a container through the docker bridge, not from localhost.
  Password literals escape quotes with backslash interpretation disabled for this provisioning session only. SQL errors abort deployment; existing account passwords stay unchanged.

**Network reachability of the DBMS is the administrator's job; the script does not configure it.** The project containers are in the `<slug>` network, which has its own subnet. To find it:

```bash
docker network inspect <slug> -f '{{(index .IPAM.Config 0).Subnet}}'
```

- **PostgreSQL:** `listen_addresses` in `postgresql.conf` must include an address reachable from the containers (the Docker host address above, or `*`). `pg_hba.conf` needs a line admitting the project subnet (or all docker subnets), for example `host <db> <user> 172.16.0.0/12 scram-sha-256`. After editing run `systemctl reload postgresql`.
- **MySQL:** check `bind-address` in `/etc/mysql/mysql.conf.d/mysqld.cnf`. On Ubuntu it defaults to `127.0.0.1`, and the containers will not be able to connect.
- **The firewall** (ufw/iptables) must allow traffic from the docker subnets to the DBMS port.

Check from a container: `cd /var/www/<slug> && docker compose run --rm artisan migrate:status`.

---

## Filament

Filament is the `filament` module (`--with filament`, or its alias `--install-filament`). With the required `--filament-email`, after migrations the script:

1. `docker compose run --rm composer require filament/filament:"^5.0"`
2. `docker compose run --rm artisan filament:install --panels`
3. configures the production access rule described below;
4. creates the administrator through Laravel using stdin values and a hashed password, without a password-bearing child argument.

Result:
- the admin panel at the applied HTTP/HTTPS scheme under `/admin` (panel ID `admin` by default);
- the panel provider, usually `app/Providers/Filament/AdminPanelProvider.php`, and the published Filament assets in `public/`;
- a user in the `users` table;
- the lines `FILAMENT_ADMIN_NAME`, `FILAMENT_ADMIN_EMAIL` and `FILAMENT_ADMIN_PASSWORD` in `/var/www/<slug>/.env`, and the login credentials in the script output.

If `--filament-name`/`--filament-password` are not given, an 8-character `a-f0-9` name and a 10-character `a-zA-Z0-9` password are generated.

Important:
- **Compatibility.** The Laravel 13 + Filament 5 combination on PHP 8.3 has been verified with a real deployment. The script installs Filament `^5.0` regardless of `--laravel-version`, so for other Laravel versions (especially 10.x and 11.x) check compatibility in the Filament documentation. Composer runs in the same PHP 8.3 image as the application and checks package requirements. If they are incompatible it fails with a clear error instead of installing packages built for a different PHP version.
- **Any error in these steps terminates the script.** nginxproxy is not restarted, SSL is not obtained, and the endpoint and backup steps are not run. A failed migration stops deployment before the modules are installed.
- **Interactivity.** In a verification deployment `filament:install --panels` ran without questions. If the installer does ask for a panel ID (for example, in an interactive terminal), keep `admin`.
- **Production access.** On a fresh skeleton the module adds the `FilamentUser` contract and `canAccessPanel()` to `app/Models/User.php`. Only the `admin` panel and the email given with `--filament-email` are allowed, using `config/laraship.php`. Other users are denied. Extend this rule deliberately when adding administrators. Applications deployed with `--repo` manage their own authentication and cannot use this module.

## Modules

Optional features are modules: one file each in `modules/`, loaded only when enabled. Without `--with` or an alias, optional modules are not installed; the same production settings and private port bindings apply.

```bash
bash /opt/laraship/deploy-laravel.sh --list-modules

sudo bash /opt/laraship/deploy-laravel.sh \
  --slug app --domain app.example.com --db-type postgres --ssl-email admin@example.com \
  --with filament,horizon --filament-email admin@example.com
```

| Module | What it does | Alias |
|---|---|---|
| `filament` | Filament admin panel at `/admin`; needs `--filament-email` (name and password are generated if not given); cannot be combined with `--repo` | `--install-filament` |
| `redis` | Wires Redis into Laravel: `REDIS_*`, and cache, session and queue on `redis` | `--use-redis` |
| `queue` | A queue worker container `<slug>_queue` | `--queue-worker` |
| `backup` | Scheduled **database dumps** (a `<slug>_backup` container): one at start, then every 24 hours, in `/var/www/<slug>/backups`; dumps older than `--backup-keep` days (default 7) are deleted. `backup.sh` takes a dump on demand and restores one (see [Database backups](#database-backups)) | — |
| `horizon` | Laravel Horizon: installs `laravel/horizon`, runs `php artisan horizon` in `<slug>_horizon`, dashboard at `/horizon`. **Enables `redis` automatically**; cannot be combined with `queue` (it replaces the plain worker) or `--repo` | — |

How it works:
- `--with` takes a comma-separated list; the key in a `--config` file is `WITH`. The aliases are identical to `--with <name>` and keep working in flags and in config files.
- A module can require other modules: they are enabled first, with a message (`Module horizon requires redis: enabling it`).
- Hooks run in a fixed order: `validate` while the arguments are checked, then after Laravel is installed and migrated the `env` hooks of all modules, then their `install` hooks, and last the services the modules add are inserted into the project's `docker-compose.yml` and started once. Services are added only after the application exists, because a worker started earlier would restart in a loop until `artisan` appears.
- Because the service lives in the project's own `docker-compose.yml`, `activate.sh`, `deactivate.sh`, `remove.sh` and `docker compose` handle it like any other service, and `update.sh` restarts it after an update (`queue:restart` for `queue`, `horizon:terminate` for `horizon`; Docker starts Horizon again with the new code).
- Only files in `modules/` named `[a-z][a-z0-9-]*.sh` can be enabled. **Modules are sourced into the script and run as root**, like the script itself: treat `modules/` as code you trust.
- **Modules ship with the script; nothing is downloaded at deployment time.** `--with NAME` (or `WITH=NAME` in a config file) uses `modules/NAME.sh` from the folder you installed, so an unknown name stops the script with `Unknown module`. New modules are contributed by pull request; see [modules/README.md](modules/README.md#contributing-a-module).

New projects use `APP_ENV=production`, so unauthenticated requests to Horizon's dashboard are denied. Define the `viewHorizon` gate in your application to authorize administrators.

Writing your own module is described in [modules/README.md](modules/README.md).

## Database backups

`--with backup` adds a `<slug>_backup` container that dumps the project's database **once at start and then every 24 hours** into `/var/www/<slug>/backups`, and deletes dumps of this project older than `--backup-keep` days (default 7).

```bash
sudo bash /opt/laraship/deploy-laravel.sh --domain shop.example.com --db-type postgres \
  --ssl-email admin@example.com --with backup --backup-keep 14
```

- **Formats:** PostgreSQL `slug-YYYYmmdd-HHMMSS.dump` (custom format, `pg_dump -Fc`), MySQL `slug-YYYYmmdd-HHMMSS.sql.gz` (`mysqldump --single-transaction --no-tablespaces --set-gtid-purged=OFF --routines --triggers`). MySQL dumps contain the application database without instance tablespaces or replication GTIDs. Container backup tools derive from the selected database image. For native PostgreSQL, installation queries `server_version_num` through the application's authenticated connection and uses the official `postgres:<server-major>` backup image; failed or invalid detection aborts. For native MySQL, select a client image compatible with the host server.
- **Native PostgreSQL 16:** `--db-native --with backup` automatically selects `postgres:16` for its dump/restore tools. No `versions.env` change is needed; the container PostgreSQL default remains 17. This does not upgrade the native server. A 17-client dump failed to restore on the tested 16 host (`transaction_timeout`), so verify a fresh backup with the matching client.
- **On demand and restore:** [`backup.sh`](#backupsh--database-dumps-and-restore) (`now`, `list`, `restore`).
- **Retention** counts days since the file was written. A failed dump is reported in the container log (`docker compose logs backup`) and retried at the next round; it never stops the container.
- **This is not `--create-backup`.** `--create-backup` makes a one-time zip of the project folder (code and configuration, no database). The backup module dumps the database and keeps doing it.

**Read this before you rely on it:**
- The dumps live **on the same server and disk** as the database. They protect against a bad migration or a deleted table, not against losing the server. Copy `/var/www/<slug>/backups` off the machine (rsync, object storage) on your own schedule.
- `remove.sh` deletes the project folder, **including `backups/`**. Copy the dumps first if you may need them.
- A dump contains all of your data in plain form and is written by root: keep the folder private (it is not readable by other users by default) and encrypt what you copy elsewhere.
- Dumps are not encrypted and are not verified by restoring them automatically. Restore one on a test project now and then.

## Deploying an existing application

`--repo` deploys your own Laravel application instead of a fresh skeleton, and `update.sh` brings it up to date later.

```bash
# public repository
sudo bash /opt/laraship/deploy-laravel.sh \
  --slug shop --domain shop.example.com --db-type postgres --ssl-email admin@example.com \
  --repo https://github.com/acme/shop.git --branch main

# private repository: an SSH URL and a deploy key (read-only access is enough)
sudo bash /opt/laraship/deploy-laravel.sh \
  --slug shop --domain shop.example.com --db-type postgres --ssl-email admin@example.com \
  --repo git@github.com:acme/shop.git --branch main --deploy-key /root/shop_deploy_key \
  --post-deploy 'php artisan db:seed --force'
```

What happens: the repository is cloned into `public_html`, `composer install --no-dev --optimize-autoloader` runs in the php image, `.env` is created from `.env.example` (an existing `.env` in the repository is kept), `APP_KEY` is generated when empty, the script writes the database settings and `APP_URL` into `.env` (as for a fresh Laravel) and runs the migrations.

**What the application needs:**
- a Laravel application at the repository root (`artisan` and `composer.json`); the check fails the deployment otherwise;
- the frontend assets already built and committed, or built by you afterwards: the php container has no Node. Run `docker compose run --rm npm ci && docker compose run --rm npm run build` in the project folder, then `docker compose run --rm permissions`;
- `--install-filament` and `--laravel-version` are not accepted: the application manages its own dependencies.

**Private repositories.** Use an SSH URL with `--deploy-key`. Credentials in the URL are refused, because they would end up in `.git/config`, `ps` and logs. The key is copied to `/var/www/<slug>/.config/deploy_key` (mode 600) and the server's host key is trusted on first use and stored in `.config/known_hosts`.

**`.deploy-meta`.** The script records the source in `/var/www/<slug>/.deploy-meta` (mode 600): `REPO_URL`, `REPO_BRANCH`, `DEPLOY_KEY_FILE`, `POST_DEPLOY`. `update.sh` reads it; it is plain `KEY=VALUE` lines and is never sourced.

**Updating.** `sudo bash /opt/laraship/update.sh --slug shop` (see [Project management](#project-management)).

**`--post-deploy`** runs arbitrary shell commands in the php container as the application user, so treat the value like code you deploy. It must be a single line. If it fails, the deployment continues and the script exits with an error at the end.

---

## Examples

Ready-made scripts with these scenarios are in [examples/](examples/README.md). By default they call `deploy-laravel.sh` from their own `laraship` folder, so they run from anywhere: `bash /opt/laraship/examples/02-mysql-explicit-slug.sh`. The examples use `example.com` and fake `ChangeMe_...` passwords. If the folder is not at `/opt/laraship`, fix the path in the commands below.

### 1. Minimal: PostgreSQL, generated slug

```bash
sudo bash /opt/laraship/deploy-laravel.sh \
  --domain example.com \
  --db-type postgres \
  --ssl-email admin@example.com
# Result: slug like a3f7k2m9, domain a3f7k2m9.example.com (a wildcard record *.example.com is needed),
# Laravel ^13.0, PostgreSQL 17 in a container; ports and passwords are generated and stored in /var/www/a3f7k2m9/.env
```

### 2. MySQL with an explicit slug

```bash
sudo bash /opt/laraship/deploy-laravel.sh \
  --slug shop \
  --domain shop.example.com \
  --db-type mysql \
  --ssl-email admin@example.com
# Result: /var/www/shop, domain shop.example.com (unchanged), MySQL 8.4 LTS in the shop_db container
```

### 3. Explicit DB credentials and ports

```bash
sudo bash /opt/laraship/deploy-laravel.sh \
  --slug crm \
  --domain crm.example.com \
  --db-type postgres \
  --db-postgres-name crm_db \
  --db-postgres-user crm_user \
  --db-postgres-password ChangeMe_CrmDb1 \
  --redis-password ChangeMe_Redis1 \
  --port-http 8150 \
  --port-https 4150 \
  --port-php 9150 \
  --port-redis 6550 \
  --port-postgres 5550 \
  --ssl-email admin@example.com
# Result: DB crm_db / crm_user with the given password; host ports 8150/4150/9150/6550/5550
# (PHP-FPM 9150 — only on 127.0.0.1)
# (the script does not check whether explicitly given ports are busy); Laravel connects to crm_db:5432
```

### 4. Native PostgreSQL

```bash
sudo bash /opt/laraship/deploy-laravel.sh \
  --slug blog \
  --domain blog.example.com \
  --db-type postgres \
  --db-native \
  --ssl-email admin@example.com
# Result: no db container; user and DB created through `sudo -u postgres psql`;
# Laravel: DB_HOST=<the Docker host, normally 172.17.0.1>, DB_PORT=5432. PostgreSQL must already listen on the docker bridge,
# and pg_hba.conf must admit the blog network's subnet
```

### 5. Native MySQL

```bash
sudo bash /opt/laraship/deploy-laravel.sh \
  --slug wiki \
  --domain wiki.example.com \
  --db-type mysql \
  --db-native \
  --db-root-password ChangeMe_MysqlRoot1 \
  --port-mysql 3306 \
  --ssl-email admin@example.com
# Result: DB and user 'user'@'%' created in the system MySQL; Laravel: DB_HOST=<the Docker host, normally 172.17.0.1>, DB_PORT=3306.
# The root password is stored nowhere: pass it again to remove.sh via --db-root-password.
# MySQL's bind-address must admit connections from the containers
```

### 6. Filament with generated name and password

```bash
sudo bash /opt/laraship/deploy-laravel.sh \
  --slug cms \
  --domain cms.example.com \
  --db-type postgres \
  --install-filament \
  --filament-email admin@example.com \
  --ssl-email admin@example.com
# Result: panel https://cms.example.com/admin; name (8 hex) and password (10 chars) are printed to the console
# and appended to /var/www/cms/.env as FILAMENT_ADMIN_*
```

### 7. Filament with explicit administrator data

```bash
sudo bash /opt/laraship/deploy-laravel.sh \
  --slug backoffice \
  --domain backoffice.example.com \
  --db-type mysql \
  --install-filament \
  --filament-email admin@example.com \
  --filament-name "Admin" \
  --filament-password ChangeMe_Filament1 \
  --ssl-email admin@example.com
# Result: panel https://backoffice.example.com/admin, login admin@example.com / ChangeMe_Filament1
```

### 8. Basic Auth (closed staging)

```bash
sudo bash /opt/laraship/deploy-laravel.sh \
  --slug staging \
  --domain staging.example.com \
  --db-type postgres \
  --enable-basic-auth \
  --auth-user staging \
  --auth-password ChangeMe_Staging1 \
  --ssl-email admin@example.com
# Result: .config/nginx/.htpasswd, auth_basic in the location / of the project nginx's HTTPS block;
# AUTH_USER/AUTH_PASSWORD in .env. Requests to /index.php bypass the protection (see limitations)
```

### 9. Without SSL (`--no-ssl`)

```bash
sudo bash /opt/laraship/deploy-laravel.sh \
  --slug preview \
  --domain preview.example.com \
  --db-type postgres \
  --no-ssl
# Result: the application is available over HTTP with HTTP APP_URL; HTTPS stays disabled.
# To enable HTTPS later, follow "SSL not obtained" in Troubleshooting.
```

### 10. Production: full set + endpoint + backup

```bash
sudo bash /opt/laraship/deploy-laravel.sh \
  --slug app \
  --domain app.example.com \
  --laravel-version 13.0 \
  --db-type postgres \
  --db-postgres-name app_prod \
  --db-postgres-user app_prod \
  --db-postgres-password ChangeMe_PgProd1 \
  --redis-password ChangeMe_Redis1 \
  --port-http 8200 \
  --port-https 4200 \
  --port-php 9200 \
  --port-redis 6600 \
  --port-postgres 5600 \
  --install-filament \
  --filament-email admin@example.com \
  --filament-name "Admin" \
  --filament-password ChangeMe_Filament1 \
  --endpoint https://api.example.com/deployments \
  --create-backup \
  --ssl-email admin@example.com
# Result: site https://app.example.com with Filament; JSON with the project data sent by PUT
# to the endpoint; archive /tmp/app_<date>.zip (path in BACKUP_ARCHIVE_PATH).
# New deployments already use production mode, closed project ports and mode 600 for .env.
# Add application-specific cache and administrator access rules after deployment.
```

### 11. Existing application from git

```bash
sudo bash /opt/laraship/deploy-laravel.sh \
  --slug shop \
  --domain shop.example.com \
  --db-type postgres \
  --repo git@github.com:acme/shop.git \
  --branch main \
  --deploy-key /root/shop_deploy_key \
  --post-deploy 'php artisan db:seed --force' \
  --ssl-email admin@example.com
# Result: the application is cloned into /var/www/shop/public_html, dependencies installed with
# composer (no dev packages), .env created and configured, migrations and the seeder run.
# Later: sudo bash /opt/laraship/update.sh --slug shop
```

### 12. Optional services and hardening

```bash
sudo bash /opt/laraship/deploy-laravel.sh \
  --slug api \
  --domain api.example.com \
  --db-type postgres \
  --use-redis \
  --queue-worker \
  --bind-local \
  --php-upload-max 256M \
  --ssl-email admin@example.com
# Result: Redis wired into Laravel (cache, session, queue), a queue worker container api_queue,
# HTTP/HTTPS/Redis/DB ports published on 127.0.0.1 only, PHP upload limits raised to 256M

### 13. Everything in a config file

```bash
sudo bash /opt/laraship/deploy-laravel.sh --config /root/shop.conf
# Result: the same as passing every setting as a flag (see "Configuration file and versions").
# Flags after --config override the file, e.g.: --config /root/shop.conf --slug shop-staging --no-ssl
```

### 14. Modules

```bash
bash /opt/laraship/deploy-laravel.sh --list-modules

sudo bash /opt/laraship/deploy-laravel.sh \
  --slug app \
  --domain app.example.com \
  --db-type postgres \
  --with filament,horizon \
  --filament-email admin@example.com \
  --ssl-email admin@example.com
# Result: the Filament panel at /admin, Redis wired into Laravel (enabled by horizon),
# laravel/horizon installed and the container app_horizon running `php artisan horizon`

---

## Useful commands

All commands are run from the project folder: `cd /var/www/<slug>`.

```bash
# Status and logs
docker compose ps                     # running containers
docker compose ps -a                  # including finished utilities
docker compose logs -f --tail=100 nginx php
docker compose logs --tail=100 db

# Artisan (the container runs as user www, uid 1000)
docker compose run --rm artisan migrate --force
docker compose run --rm artisan migrate:status
docker compose run --rm artisan optimize:clear
docker compose run --rm artisan config:cache
docker compose run --rm artisan storage:link
docker compose run --rm artisan tinker
docker compose run --rm artisan make:filament-user     # creates a user; extend canAccessPanel deliberately to allow another administrator

# Composer (in the PHP 8.3 image, as www, uid 1000)
docker compose run --rm composer install --no-dev --optimize-autoloader
docker compose run --rm composer require vendor/package

# npm (runs as root, run permissions afterwards)
docker compose run --rm npm install
docker compose run --rm npm run build

# File permissions
docker compose run --rm permissions

# Certificates (renewal — certbot_renew every 12 h, nginx reload — automatically every 6 h)
docker compose run --rm certbot certificates
docker compose run --rm certbot renew --dry-run
docker compose logs --tail=20 certbot_renew
docker exec nginxproxy nginx -s reload && docker compose exec nginx nginx -s reload   # pick up a certificate immediately, without waiting for the reload

# Check nginx configs
docker compose exec nginx nginx -t
docker exec nginxproxy nginx -t

# DB console (containerized)
docker compose exec db psql -U <DB_POSTGRES_USER> -d <DB_POSTGRES_NAME>
docker compose exec db mysql -u <DB_MYSQL_USER> -p <DB_MYSQL_NAME>

# Rebuild after editing docker-compose.yml or a Dockerfile
docker compose up -d --build
```

### Docker: containers, proxy, networks, volumes

```bash
# Containers
docker ps -a --filter "name=<slug>_"                 # project containers
docker logs <container_name> --tail 50               # logs; -f to follow in real time
docker restart <container_name>                      # also stop / start

# All project containers
cd /var/www/<slug> && docker compose restart
cd /var/www/<slug> && docker compose down
cd /var/www/<slug> && docker compose up -d
cd /var/www/<slug> && docker compose up -d --build   # with a rebuild

# Proxy (shared by all projects on the server)
cd /var/www/nginxproxy && docker compose up -d && docker restart nginxproxy
docker exec nginxproxy nginx -t                      # check the configuration
docker logs nginxproxy --tail 50

# Networks and volumes
docker network ls
docker network inspect <slug>
docker volume ls --filter "name=<slug>_"
docker volume inspect <volume_name>

# Cleanup and monitoring
docker container prune          # stopped containers (finished utilities are recreated on the next up)
docker image prune              # unused images
docker volume prune             # unused volumes; careful: with --all named ones are removed too, including DB data
docker stats                    # container resources
docker system df                # disk usage
```

---

## Project management

The utilities live in the `laraship` folder next to `deploy-laravel.sh`, require root and work with `/var/www`. They **do not depend** on the project type: you can manage any project on the server with them, including Moodle or HTML deployed by another kit. The slug is compared exactly in all utilities: `lms` does not affect `lms2`.

### `list-projects.sh` — list projects

```bash
sudo bash /opt/laraship/list-projects.sh
```

The script shows every `/var/www/*` folder that has a `docker-compose.yml` (except `nginxproxy`). For each it prints the domain (`SITE_HOST`), container status (RUNNING/STOPPED), presence of an SSL certificate (it checks `live/<domain>/fullchain.pem` in the `<slug>_ssl_certificates` volume), DB type and port, HTTP, HTTPS and PHP ports, the first 5 containers and command hints. At the end: the nginxproxy status and the number of configs in `sites/`.

### `deactivate.sh` — switch off without deleting

```bash
sudo bash /opt/laraship/deactivate.sh --slug <slug>
```

Steps:

1. locks the project, then validates a private proxy candidate with the site's config renamed to `.conf.disabled` and its network/certificate entries disabled;
2. applies and checks the proxy, restoring its previous configuration if application fails;
3. runs `docker compose down` in the project only after routing is detached.

Data, volumes and the project folder are kept.

### `activate.sh` — switch back on

```bash
sudo bash /opt/laraship/activate.sh --slug <slug>
```

Steps:

1. locks the project, starts its containers with `docker compose up -d --build` and restarts existing PHP/Nginx services;
2. prepares a private proxy candidate with the site's config and network/certificate entries enabled;
3. validates, applies and checks the proxy, restoring its previous configuration if application fails. Repeated activation is safe.

### `remove.sh` — complete removal

```bash
sudo bash /opt/laraship/remove.sh --slug <slug> --domain <domain>
# project with native MySQL: the root password is needed to remove its DB and user
sudo bash /opt/laraship/remove.sh --slug <slug> --domain <domain> --db-root-password '<root-password>'
```

`--slug` and `--domain` are required. The domain must match `SITE_HOST` in the project metadata. The script locks the project, prints a warning and **asks you to type `yes`**; any other answer cancels removal. After confirmation it:

1. validates and commits a shared proxy candidate without the site's routes/network/certificate entries;
2. stops project containers and removes the project's volumes (including **DB data**) and network;
3. removes the native DB/user when the metadata identifies a native DB: PostgreSQL through `sudo -u postgres psql`, MySQL using `--db-root-password` in a private client option file;
4. removes the recorded ZIP archive and `/var/www/<slug>`.

A failed routing transaction prevents data deletion. A later deletion/client failure stops removal and retains remaining project files and metadata for recovery; previously deleted data is not restored. Native MySQL without its root password or a missing native DB client is an error.

**This action is irreversible.**

### `update.sh` — update a project deployed with `--repo`

```bash
sudo bash /opt/laraship/update.sh --slug <slug>
sudo bash /opt/laraship/update.sh --slug <slug> --no-migrate --post-deploy "php artisan db:seed --force"
```

Options: `--no-migrate`, `--post-deploy "CMDS"` (replaces the commands stored at deployment time), `--reset` (`git reset --hard` to the remote branch, for force-pushed branches), `--force` (run the steps even without new commits), `-h`/`--help`.

Steps:
1. checks the project: it has a `.deploy-meta`, the php container is running, and `public_html` has no uncommitted changes to tracked files (untracked files such as `composer.lock` are ignored);
2. fetches the branch and checks fast-forward compatibility without changing application files. With no new commits it stops with "Already up to date";
3. requires maintenance mode on the old code (`artisan down`), then switches to the fetched commit. If maintenance cannot be enabled, the old code and dependencies stay untouched;
4. `permissions`, then `composer install --no-dev --optimize-autoloader`;
5. `artisan migrate --force` (unless `--no-migrate`) and `artisan optimize:clear`;
6. `artisan queue:restart` if a queue worker exists, and restarts the php container (clears OPcache);
7. runs the post-deploy commands;
8. `artisan up`.

**If a step fails after maintenance was enabled, the application stays in maintenance mode** and the script prints the commands to roll back to the previous commit (`git reset --hard <previous commit>`, `composer install`, `artisan up`). Nothing is rolled back automatically, because a migration may already have changed the database; use `artisan migrate:rollback` if needed.

### `backup.sh` — database dumps and restore

For projects deployed with `--with backup` (see [Database backups](#database-backups)).

```bash
sudo bash /opt/laraship/backup.sh --slug <slug> now                 # take a dump now
sudo bash /opt/laraship/backup.sh --slug <slug> list                # list the dumps
sudo bash /opt/laraship/backup.sh --slug <slug> restore <file>      # asks you to type yes
sudo bash /opt/laraship/backup.sh --slug <slug> restore <file> --yes
```

`restore` checks the dump before stopping services (`pg_restore --list`, or full MySQL decompression to a nonempty temporary file); a failed check leaves the application and database untouched. It then requires maintenance mode to succeed, stops `php`, `cron` and the workers, restores, starts the services and brings the application back. New backup scripts fully decompress MySQL SQL before importing it and use `pg_restore --exit-on-error` for PostgreSQL. Temporary files need space for the uncompressed SQL. A failed import keeps maintenance mode and prints recovery instructions; the original dump is never modified. Take a fresh dump with `now` first if you may need the current data.

---

## Re-running the script

An existing `/var/www/<slug>` path (including a file or symlink) is refused **before Docker installation, container changes or shared proxy changes**. The installer never removes the project directory. `nginxproxy` is reserved in both deployment and management commands.

- **Update code while keeping data:** use `update.sh --slug <slug>` for an application deployed with `--repo`. For other projects update the application deliberately, preserving `.env`, storage and the database.
- **Clean reinstall:** copy the database dumps, uploaded files and configuration off the server first. Then explicitly use `remove.sh --slug <slug> --domain <domain>` (for native MySQL also `--db-root-password`), which asks for confirmation and deletes the database data, before deploying again.
- **Recover a failed first installation:** fix the error in the existing project; do not rerun the installer over it. A failed migration now exits with an error and prints the command to retry after fixing the cause.

If you choose to remove a failed first installation, `remove.sh` handles a shared proxy that was never created. A proxy container without its configuration still blocks deletion; restore or inspect that proxy first. A subsequent clean install rebuilds generated module images, including a backup image left from another database engine.

---

## Sending data to an endpoint

With `--endpoint URL`, after the SSL attempt (and before the backup) the script runs:

```bash
curl -X PUT -H "Content-Type: application/json" -d '<JSON>' URL
```

Request body (values are fake; a sample file is [examples/endpoint-payload.json](examples/endpoint-payload.json)):

```json
{
  "slug": "app",
  "domain": "app.example.com",
  "app_type": "laravel",
  "laravel_version": "13.0",
  "db_type": "postgres",
  "ports": {
    "http": 8231,
    "https": 4175,
    "php": 9342,
    "redis": 6621
  },
  "redis": {
    "password": "ChangeMe_Redis1"
  },
  "database": {
    "type": "postgres",
    "port": 5634,
    "name": "exampledbname01",
    "user": "exampledbuser01",
    "password": "ChangeMe_DbPwd1"
  },
  "basic_auth": {
    "enabled": true,
    "user": "exampleauthuser",
    "password": "ChangeMe_Auth01"
  },
  "ssl": {
    "enabled": true,
    "email": "admin@example.com"
  },
  "project_path": "/var/www/app"
}
```

Notes:
- `database.port` is the host port (like `DB_PORT` in the project `.env`).
- `ssl.enabled` reflects the flag (`--no-ssl` or not), not whether a certificate was actually obtained.
- Without Basic Auth the fields `basic_auth.user` and `basic_auth.password` are empty strings.
- There is no Filament data, no native-DB flag and no root passwords in the JSON.
- Python JSON serialization preserves quotes, backslashes and Unicode. Curl reads the payload from stdin with a 5-second connection timeout and a 20-second total timeout.
- A non-2xx response produces only a warning. The request carries all passwords in plain text, so use HTTPS endpoints only.

---

## Security

- **Secret generation.** Passwords come from `/dev/urandom`. Explicit database, Redis, Basic Auth and Filament secrets are encoded for Compose/Laravel; control characters are rejected. Container MySQL also rejects quotes/backslashes because of its bundled initializer. Basic Auth usernames use letters, digits, `_`, `.`, `@` and `-`.
- **Where secrets live.** The script prints generated values to the console and summary, so protect recorded sessions and CI logs. `/var/www/<slug>/.env` is root-owned, mode 600; `public_html/.env` belongs to uid 1000, mode 600. The permissions utility preserves this restriction. `--db-root-password` is passed on the command line and can appear in shell history and `ps`.
- **Published ports.** PHP-FPM, project HTTP/HTTPS, Redis and containerized DB ports bind to `127.0.0.1` by default. Only the shared proxy publishes 80/443 publicly. `--bind-local` remains accepted for compatibility; no flag is needed. A native DB's listener is configured separately by its administrator.
- **Laravel defaults.** New deployments set `APP_ENV=production`, `APP_DEBUG=false`; PHP templates do not install Xdebug. `update.sh` preserves the existing application's environment, so apply these settings deliberately to older deployments.
- **TLS.** HTTP serves the application until a certificate is usable, with HTTP `APP_URL`. After successful certificate validation/application, ordinary HTTP requests redirect to HTTPS and `APP_URL` changes to HTTPS. ACME remains reachable over HTTP. Certbot issuance/renewal use `certbot/certbot:v5.8.0`.
- **Basic Auth** is an extra barrier, not full protection: see [limitations](#known-limitations).
- **`--repo` and deploy keys.** URLs with credentials are refused. A deploy key is stored in the project (`.config/deploy_key`, mode 600) and used with `IdentitiesOnly=yes`; the server's host key is trusted on first use. Give the key read-only access to the one repository. `.deploy-meta` has mode 600.
- **`--post-deploy`** runs shell commands from the command line in the php container; anyone who can run the deploy script can already run code as root, but do not put secrets in the command (they stay in `ps` and in `.deploy-meta`).
- **`--config` files hold secrets.** Keep them at mode 600 (the script warns otherwise) and out of shared repositories, or keep only the non-secret settings in the file and pass passwords as flags. The file is parsed, never executed, so a malicious value cannot run code, but it is still plain text on disk.

## Laravel versions and conditions

What installs today, verified by real deployments (`tests/install-matrix.bats`, run weekly by CI; last checked **2026-09-30**):

| Condition | Result |
|---|---|
| Laravel **13** (the default), MySQL or PostgreSQL in a container | installs and runs |
| Laravel **13** with the `filament` module | installs and runs |
| Laravel **12**, PostgreSQL in a container | installs and runs |
| Laravel **12** with the `filament` module, MySQL | installs and runs |
| Database **installed on the host** (`--db-native`): PostgreSQL 16 and MySQL 8 | installs and runs |
| An existing application with `--repo` (branches 12.x and 13.x of `laravel/laravel`), then `update.sh` | installs and updates |
| Laravel **10.x** and **11.x** (`--laravel-version 10.0` / `11.0`) | **refused up front** (minimum 12.0), see below |
| An existing application on Laravel 10.x or 11.x (`--repo`) | **fails** at `composer install`, see below |
| A Laravel version that does not exist (`--laravel-version 99.0`) | stops with `Failed to install Laravel` |

**Why Laravel 10.x and 11.x are not supported.** Composer (2.9+) refuses package versions that are affected by security advisories (`audit.block-insecure`). Every release of Laravel 10 and 11 is affected: those versions are no longer supported and their advisories are not going to be fixed, so they cannot be installed. `--laravel-version` therefore refuses anything below `LARAVEL_MIN_VERSION` (12.0) immediately, before any container is built, and says why. The script does not switch Composer's blocking off: installing a framework with known vulnerabilities is a decision for you to make outside this script. Raise `LARAVEL_MIN_VERSION` in `versions.env` when the next version is retired.

For an existing application (`--repo`) the script cannot check the framework version in advance. A `composer install` without a `composer.lock` has to resolve versions and is refused for an unsupported framework; the script recognises the refusal and explains it (`Composer refused to install the requested versions because they are affected by security advisories ...`). Upgrade the framework, or commit a `composer.lock` that Composer accepts.

The other conditions (the Redis, queue, Horizon and backup modules, presets, config files) are covered by the end-to-end suites in [Tests and CI](#tests-and-ci).

---

## Troubleshooting / FAQ

### Migrations failed (`Failed to run Laravel migrations`)

An initial migration failure aborts deployment before module installation and shared proxy routing. Before migrations the installer waits up to 120 seconds for an authenticated DB connection. Possible causes:
- initialization exceeded the readiness limit, or a migration itself failed;
- a database volume from an older or incomplete deployment has different credentials;
- the native DBMS is unreachable from the container.

```bash
cd /var/www/<slug>
docker compose logs --tail=50 db
grep '^DB_' public_html/.env
docker compose run --rm artisan migrate --force
```

Preserve data and inspect which stages completed. The installer refuses the existing project path; it has no automatic resume. After migrations succeed, complete pending module environment/install/service steps before attaching routing. For a fresh skeleton where Filament installation has not started, invoke its complete module under the project lock (replace the placeholders):

```bash
sudo bash -s <<'BASH'
set -euo pipefail
source /opt/laraship/deploy-laravel.sh
source "$SCRIPT_DIR/modules/filament.sh"
SLUG='<slug>'
DOMAIN='<domain>'
PROJECT_DIR="$WWW_DIR/$SLUG"
FILAMENT_EMAIL='<admin-email>'
check_root
runtime_require python3 flock docker
project_lock
load_versions
mod_filament_validate
mod_filament_install
BASH
```

This installs the package/panel, configures production access and creates the administrator. If installation partially completed or the model/config is customized, inspect and complete those steps deliberately; do not overwrite custom access rules or recreate an existing user. Other enabled modules need their full hooks/services too (see [Modules](#modules)).

Verify the project's HTTP response, using Basic Auth when enabled. For an initial deployment that stopped before routing, attach the ready project through the checked proxy transaction rather than restarting an unchanged proxy:

```bash
sudo bash -s <<'BASH'
set -euo pipefail
source /opt/laraship/deploy-laravel.sh
SLUG='<slug>'
DOMAIN='<domain>'
PROJECT_DIR="$WWW_DIR/$SLUG"
check_root
runtime_require python3 flock pgrep docker
project_lock
proxy_transaction prepare_proxy_site
BASH
```

Then enable TLS using the checked procedure below if needed. Templates copied by older releases first require the migration in "Updating an already deployed server".

### SSL not obtained

If Certbot fails, the script warns and continues with the application available over HTTP and HTTP `APP_URL`. HTTPS remains disabled. Check:

- the domain's A record points to the server. For an automatic slug the `*.<domain>` record is needed;
- ports 80/443 are open, nginxproxy is running, and `curl -I http://<domain>/.well-known/acme-challenge/test` reaches the server (a 404 is normal for a missing token);
- the Let's Encrypt rate limits are not exceeded.

For a project created from the current templates, replace the placeholders below and use the same checked certificate/application procedure under the project lock:

```bash
sudo bash -s <<'BASH'
set -euo pipefail
source /opt/laraship/deploy-laravel.sh
SLUG='<slug>'
DOMAIN='<domain>'
SSL_EMAIL='<email>'
PROJECT_DIR="$WWW_DIR/$SLUG"
OBTAIN_SSL=true
check_root
runtime_require python3 flock pgrep docker
project_lock
obtain_ssl_certificate
BASH
```

This requests the certificate, validates/reloads project TLS, applies shared proxy TLS through a transaction and changes `APP_URL` after success. The same procedure works after `--no-ssl`. Older generated configurations first need the migration described in [Updating an already deployed server](#updating-an-already-deployed-server).

### nginxproxy does not start or restarts in a loop

Look at `docker logs --tail=50 nginxproxy` and `cd /var/www/nginxproxy && docker compose up -d`:
- **`address already in use` on 80/443** — the port is taken by another web server on the host (`sudo ss -tlnp | grep -E ':(80|443) '`).
- **`host not found in upstream "<slug>_nginx..."`** — `sites/` holds a project `*.conf` whose containers are not running: they did not start during deployment, were stopped by hand without `deactivate.sh`, or were removed without `remove.sh`. Start the project, switch it off with `deactivate.sh`, or rename the config to `<slug>.conf.disabled`.
- **`network <slug> declared as external, but could not be found`** — the proxy references a deleted/missing project network, usually from an older deployment or a manual edit. Restore the project's containers/network before retrying management. Do not reinstall over an existing project; preserve the proxy snapshot and custom configuration.
- **A certificate error** — the SSL block is uncommented but there is no certificate. Check `docker compose run --rm certbot certificates` in the project.

### Permissions on storage, 500 Internal Server Error

PHP-FPM, `artisan` and `composer` run as the user `www` (uid 1000). `npm` and commands run on the host as root create files owned by root. The script runs `permissions` after installing Laravel. If files ended up owned by someone else (for example, after `npm` or a copy as root), run:

```bash
cd /var/www/<slug> && docker compose run --rm permissions
docker compose logs --tail=50 php
tail -n 50 public_html/storage/logs/laravel.log
```

### Composer: "requires php ..." / package incompatible with the PHP version

Composer runs in the same PHP 8.3 image as the application and checks package PHP requirements. If `create-project` or `composer require` refuses because of the PHP version, you have two options:
- choose compatible versions (`--laravel-version`, the package version);
- change the project's PHP version (see below).

Do not bypass the check with `--ignore-platform-reqs`. That is exactly how the old script installed packages for a foreign PHP, and the application crashed with `syntax error`.

### Large file uploads (413, "file too large")

Three limits apply, and the smallest one wins:
- `nginxproxy`: `client_max_body_size 2048m`;
- the project nginx (`_site.conf`): `client_max_body_size 900M`;
- PHP. The defaults `upload_max_filesize = 2M` and `post_max_size = 8M` apply unless you change them (the full `.config/php/php.ini` is not mounted by default).

To allow large uploads:
- deploy with `--php-upload-max 512M`, or
- on an existing project set `upload_max_filesize` and `post_max_size` in `.config/php/project.ini` (mounted into the php container by the current template) and run `docker compose restart php`. Projects created by an older version need the mount line from `laravel/docker-compose.yml` first.

Servers deployed with an old version, without the proxy's `nginx.conf` fix, reject uploads over 1 MB (see [Updating an already deployed server](#updating-an-already-deployed-server)).

### Other

- **502 Bad Gateway.** The `<slug>_php` container is not running: look at `docker compose ps` and `docker compose logs php`.
- **`http://domain` returns 404.** Current templates serve the application over HTTP before TLS is enabled. Check the application route, project Nginx logs and the site's proxy config. Older copied templates may serve only ACME over HTTP; migrate them as described in "Updating an already deployed server".
- **The certificate was renewed, but the browser sees the old one.** The project nginx and `nginxproxy` reload certificates by themselves every 6 hours. To apply a new certificate immediately, run `docker exec nginxproxy nginx -s reload` and `docker compose exec nginx nginx -s reload`. On servers deployed with an old version there is no periodic reload until you perform the steps from [Updating an already deployed server](#updating-an-already-deployed-server). The renewal log: `docker compose logs certbot_renew`.
- **A port is busy after activating an old project.** Auto-selection considers only ports that are being listened on right now. Ports of stopped projects may be handed out to a new one. If you have deactivated projects, set ports explicitly.
- **Scheduler tasks run irregularly.** `cron` calls `schedule:run` every 60 seconds. Projects created by an older version used 600 seconds: change `sleep 600` to `sleep 60` in the project's `docker-compose.yml` and run `docker compose up -d cron`.
- **How to change the PHP version.** Change `dockerfile: php83.Dockerfile` for the `php`, `artisan`, `composer` and `cron` services to `php81.Dockerfile` or `php82.Dockerfile` and run `docker compose up -d --build`. Composer is built into all three Dockerfiles.
- **`--repo`: `Failed to clone`.** Check the URL and branch, and for a private repository the deploy key (read access, SSH URL). Try the same clone by hand: `GIT_SSH_COMMAND='ssh -i <key> -o IdentitiesOnly=yes' git clone <url>`.
- **`--repo`: `composer install failed`.** The application needs PHP extensions or a PHP version the php image does not provide (PHP 8.3 by default; see "How to change the PHP version" above), or a private package that composer cannot reach.
- **`update.sh`: `public_html has uncommitted changes to tracked files`.** Someone edited tracked files on the server. Commit, stash or discard the changes (`git -C /var/www/<slug>/public_html status`).
- **`update.sh`: `Update failed at step: ...`.** The application is in maintenance mode. Read the message above the rollback commands, fix the cause and rerun `update.sh`, or roll back with the printed commands.
- **`--config`: `Unknown key X in FILE (line N)`.** The key is not a flag of the script. Keys are the flag names in upper case with `_` (`DB_TYPE`, not `DBTYPE`); `--type` and `--config` cannot be keys.
- **`--config`: `Invalid line N in FILE`.** Every non-comment line must be `KEY=VALUE`. Multi-line values are not supported (join `--post-deploy` commands with `&&`).
- **`versions.env`: `Invalid … in versions.env`.** Fix the value: `LARAVEL_VERSION` is `X.Y`, `FILAMENT_VERSION` a composer constraint, the images `name:tag`.
- **`Unknown module: X`.** There is no `modules/X.sh`. `--list-modules` shows what is available; names are lowercase letters, digits and `-`.
- **Horizon is not running.** `cd /var/www/<slug> && docker compose logs horizon` and `docker compose run --rm artisan horizon:status`. Horizon needs Redis and `QUEUE_CONNECTION=redis` (the `redis` module sets both). After changing jobs or config run `docker compose run --rm artisan horizon:terminate`; Docker restarts it.
- **`/horizon` returns 403.** Outside `APP_ENV=local` Horizon denies everyone until you define the `viewHorizon` gate in `app/Providers/HorizonServiceProvider.php`.
- **`Composer refused to install the requested versions because they are affected by security advisories`.** The Laravel version (or the application's framework) is no longer supported. See [Laravel versions and conditions](#laravel-versions-and-conditions).

---

## Known limitations

- **Basic Auth on projects created by an older version does not cover the PHP location.** New projects protect both `location /` and the PHP location; older ones bypass it with a request to `/index.php`. To fix an old project, add the two `auth_basic` lines from `laravel/.config/nginx/_app.conf` to its `location ~ [^/]\.php(/|$)` block.
- **The native MySQL root password is not stored.** `--db-root-password` is written nowhere, so to remove such a DB pass it to `remove.sh` again. The `Root Password` line in the final output and `DB_MYSQL_PASSWORD_ROOT` in `.env` with `--db-native` contain a random value, not the system MySQL root password.
- **DH parameters.** `--create-dhparam` generates a project-local PEM before containers start and enables the project nginx directive. The shared proxy uses its own TLS configuration.
- **Queues.** There is no queue worker unless you deploy with `--queue-worker`. Only one worker process runs; scale it by hand (`docker compose up -d --scale queue=N`, after removing `container_name` from the service).
- **PHP is fixed at 8.3.** The script does not pick PHP for `--laravel-version`. If the chosen Laravel version or a package needs a different PHP, composer refuses and you have to change the PHP version by hand (see [Troubleshooting](#troubleshooting--faq)).
- **PHP upload limit** is 2M/8M by default; use `--php-upload-max` to change it (see [Troubleshooting](#troubleshooting--faq)).
- **HTTP on older projects.** New templates serve Laravel over HTTP and redirect after successful HTTPS application. Previously copied `_site.conf` files need explicit migration.
- **Re-running** refuses an existing project path; use `update.sh` for code updates or explicitly remove a project for a clean reinstall (see [Re-running the script](#re-running-the-script)).
- **Literal secrets.** Compose, Laravel and endpoint JSON preserve supported password values. Control characters are refused; container MySQL also has the quote/backslash restriction described under database credentials.
- **Older deployments retain their original ports and environment.** Replacing the toolkit does not change their Compose files, PHP images or generated backup scripts; apply the security changes deliberately (see [Security](#security)).
- **`--create-backup`** is a zip of the `/var/www/<slug>` folder in `/tmp`. It contains neither the DB data from the Docker volume nor certificates, and `/tmp` may be cleared on reboot. For database dumps use the `backup` module (see [Database backups](#database-backups)).
- **`--repo` does not build frontend assets** (the php image has no Node): commit them or build them afterwards with the `npm` service. `update.sh` does not run `npm` either; use `--post-deploy` only for commands that exist in the php container.
- **`update.sh` is single-branch and fast-forward only** (use `--reset` for rewritten history). It does not roll back by itself.
- **SSH deploy keys** are checked by a key-only loopback SSH clone/update fixture; remote Git providers and their access policies need separate verification.
- **Modules cannot define their own command-line flags yet**: their options are flags of the script (for example `--filament-email`), validated in the module's `validate` hook. `update.sh` does not run module hooks; it only restarts the `queue` and `horizon` workers.
- **Not covered by the automated e2e tests:** `update.sh` restarting Horizon (`horizon:terminate`) and the `queue` module together with `--repo`.

---

## Migrating from the old deploy.sh

The generic `deploy.sh --type <type>` was replaced by separate kits; for Laravel it is the `laraship` folder with the `deploy-laravel.sh` script. The flags stayed the same: change the script path and drop `--type`.

```bash
# Before
sudo bash deploy.sh --type laravel --domain example.com --db-type postgres --ssl-email admin@example.com
# After
sudo bash /opt/laraship/deploy-laravel.sh --domain example.com --db-type postgres --ssl-email admin@example.com
```

For compatibility `--type laravel` is accepted and ignored. With any other value the script exits with a hint about which `deploy-<type>.sh` is needed.

What changed for Laravel compared with the old script (verified with a real deployment: Laravel 13 + PostgreSQL + Filament 5 + Basic Auth):

- **Laravel did not install on current versions.** Composer ran in the `composer:latest` image (PHP 8.5) with `--ignore-platform-reqs` and installed packages for PHP 8.4+. The application runs on PHP 8.3, so Symfony crashed with `syntax error`, and migrations and Filament with it. Now composer runs in the same PHP image as the application, as the `www` user. The `cron` container was moved from PHP 8.2 to 8.3.
- **SSL certificates were not renewed.** `certbot_renew` sat in a restart loop (`certbot sh -c …`), and the signal telling nginx to reload the certificate never arrived. Now renewal works, and both the project nginx and `nginxproxy` reload their configuration every 6 hours.
- **PHP-FPM was exposed** (`0.0.0.0:<PHP_PORT>`, FastCGI without authentication). Now it is published only on `127.0.0.1`.
- **Uploads over 1 MB** were rejected by the proxy with a 413. `client_max_body_size 2048m` was added to `nginxproxy/nginx.conf`.
- **Connecting to the containerized DB.** Laravel's `.env` got the port published on the host (for example, 5623), although inside the Docker network the DB listens on 5432/3306, and migrations failed. Now the internal port is used.
- **Native MySQL.** The user is created as `'user'@'%'`: with `'localhost'` the container could not connect.
- **Laravel 10.** DB parameters in `.env` are set even when they are not commented out.
- **Passwords** are generated without characters that break `sed`, `.env` and compose (`&`, `$`, `/`, `=`, and so on). User-supplied values are escaped when written to Laravel's `.env`.
- **A certbot failure** no longer aborts the script: the deployment finishes and the SSL blocks stay commented out.
- **The `dhparam.pem` path** in the project compose is fixed (`../../nginxproxy` → `../nginxproxy`).
- **The project `.env`** is generated by the script; the template `laravel/.env` is no longer needed.
- **New and changed flags.** Added `--port-php`, `--port-redis` and `--help`. `--port-postgres`/`--port-mysql` also apply to the containerized DB. `--filament-email` is checked immediately at startup.
- **A slug with a hyphen** (`my-site`) no longer duplicates entries in the proxy compose on re-deployment.

The management utilities were fixed as well:

- `deactivate.sh` no longer takes down `nginxproxy`, and with it all sites: the site config is disabled by renaming it to `.conf.disabled`.
- `activate.sh` restores the config, restarts only the existing `php`/`nginx` services and reattaches the proxy to the project network.
- `remove.sh` was fixed in several places:
  - it no longer fails on MySQL projects;
  - it no longer confuses the containerized DB with the native one (before it could run `DROP DATABASE` in the system PostgreSQL);
  - it removes the native MySQL user `'user'@'%'`;
  - it accepts `--db-root-password` and removes `.conf.disabled`.
- `activate.sh`, `deactivate.sh` and `remove.sh` compare the slug exactly: `lms` no longer affects `lms2`.
- `list-projects.sh` shows SSL presence correctly: the certificate is looked up in the docker volume.

---

## Updating an already deployed server

Replacing the toolkit does not automatically migrate an existing `/var/www/nginxproxy` or a project's copied templates. To get the fixes on a server deployed with an old version, perform the steps below. Template paths are given for `/opt/laraship`. Save database dumps and uploads before changing a deployed project; the installer now refuses its existing directory.

**1. The shared proxy.** This step is done once per server and affects all sites.
- In `/var/www/nginxproxy/nginx.conf`, add the line `client_max_body_size 2048m;` to the `http { … }` block.
- In `/var/www/nginxproxy/docker-compose.yml`, add periodic certificate reloading to the `nginxproxy` service:
  ```yaml
      command: /bin/sh -c 'while :; do sleep 21600 & wait $${!}; nginx -s reload; done & exec nginx -g "daemon off;"'
  ```
- Apply the changes: `cd /var/www/nginxproxy && docker compose up -d`. The proxy is recreated, and sites are unavailable for a few seconds.

**2. Each Laravel project** (`/var/www/<slug>/docker-compose.yml`). The reference is `laravel/docker-compose.yml` in this folder; replace `{SLUG}` in it with the project slug.
- `php`: port `"${PHP_PORT}:9000"` → `"127.0.0.1:${PHP_PORT}:9000"`.
- `nginx`, `redis` and the containerized `db`: prefix each published project port with `127.0.0.1:` too. Keep the shared proxy's ports 80/443 public; it reaches projects over Docker networks.
- `permissions`: copy its explicit `/bin/sh -ec` command from the current template, which preserves mode 600 for `public_html/.env`.
- `nginx`: add the same `command:` line as for the proxy in step 1.
- `certbot_renew`: replace `command: >` with `entrypoint: >`. The line with `docker kill --signal=HUP` can be removed, it does not work.
- `composer`: replace the service with the variant from the template (built from `php83.Dockerfile`, `entrypoint: [ 'composer' ]`, without `--ignore-platform-reqs`).
- `cron`: `dockerfile: php82.Dockerfile` → `php83.Dockerfile`.
- Copy the updated Dockerfiles with the built-in composer:
  ```bash
  cp /opt/laraship/laravel/.docker/php/php8*.Dockerfile /var/www/<slug>/.docker/php/
  cd /var/www/<slug> && docker compose up -d --build
  ```

Set `APP_ENV=production` and `APP_DEBUG=false` in `public_html/.env`, keep its existing `APP_KEY`, and run `chmod 600 .env public_html/.env` from the project directory. Clear cached settings with `docker compose run --rm artisan config:clear`. Older Filament installations need a deliberate `FilamentUser::canAccessPanel()` authorization rule before switching to production; use the [fresh-install rule](#filament) as a reference. Define Horizon's `viewHorizon` gate if administrators need its dashboard.

Existing backup scripts in `.config/backup/` are generated copies. Port current dump/restore/loop scripts and the generated Dockerfile from `modules/backup.sh`, plus its Compose build stanza, without replacing credentials/data. The derived DB image supplies `flock`. Apply mode 700 to the backups directory and mode 600 to existing dump files; test against a disposable database before using a real restore.

For an already deployed native PostgreSQL 16 project, set only `services.backup.build.args.DB_IMAGE` to `postgres:16` in its copied `docker-compose.yml`, validate with `docker compose config --quiet`, then run `docker compose up -d --build --force-recreate --no-deps backup` from the project directory. Keep existing dump files and take/rehearse a new backup with client 16. This change does not repair dumps already produced by client 17; updating the toolkit does not rewrite existing project Compose files.

For HTTP/TLS migration, copy `_app.conf`, add its read-only mount, and port the two server blocks from `_site.conf` while preserving domain, custom routes and certificate paths. Move custom Basic Auth directives into the shared include. Keep HTTP APP_URL until certificates are usable and validate Nginx before reload. New hashes are bcrypt, owned by nginx uid 101 with mode 600.

Pin both Certbot services, rebuild PHP with production ini, and deliberately migrate upload limits (the production ini defaults are 2M/8M). Copy `lib/` with the toolkit; management scripts need these shared helpers. Keep backups of custom proxy configuration before applying the new management workflow.

**3. If the application is already broken** by packages installed by the old composer for a foreign PHP (`syntax error` in `vendor/`), rebuild the dependencies for PHP 8.3. The old composer ran as root, so first give the files back to the `www` user:
```bash
cd /var/www/<slug>
docker compose run --rm permissions
docker compose run --rm composer update      # composer.lock is updated for PHP 8.3
docker compose run --rm artisan migrate --force
```

### Moving an existing database to the official images

New installations use `postgres:17` and `mysql:8.4` (LTS). Previously deployed projects keep their copied Elestio image configuration. Updating the toolkit, running `update.sh`, or editing `versions.env` does **not** migrate their database.

Use a **logical dump and a separate empty volume**, rehearsed with a copy of the real application. Do not attach the old data volume to the replacement image: MySQL 8.0 → 8.4 also changes the server version, and custom settings, authentication plugins, extensions and SQL objects need compatibility checks.

1. Record the running server version, exact old image/digest, Compose configuration, credentials and actual volume name (`docker compose config`). Save these together with `APP_KEY`, uploads and an off-server backup. Keep the old image and volume for rollback. Check disk space for both databases, dumps and uncompressed MySQL SQL.
2. Prepare the replacement on a separate network/volume without the production container name or published ports. Initialize it with the intended application credentials. PostgreSQL 17 mounts `/var/lib/postgresql/data`; MySQL mounts `/var/lib/mysql`. Use the matching target client for restore. Do not copy the old PostgreSQL `01-init.sh` mount: the official entrypoint initializes the account itself.
3. Rehearse an application-only dump using a client compatible with the **source** server, then restore into the target. For MySQL use `--single-transaction --no-tablespaces --set-gtid-purged=OFF --routines --triggers`; do not import the old `mysql` system database. Migrate required additional accounts/grants separately, and inspect routine/view definers and scheduled events. PostgreSQL extensions and roles other than the configured account also need deliberate preparation. The backup module covers the application database, not all instance configuration.
4. Before the final dump, schedule downtime and coordinate with other management/backup jobs. Enable maintenance, stop all writers (`php`, `cron`, queue/Horizon and external integrations), then take and verify a fresh source dump. Keep writers stopped through the final restore and validation. Nontransactional MySQL tables require their own consistency precautions; `--single-transaction` alone does not protect them.
5. Switch only the project's `db` image **and named volume mapping** to the restored target. Preserve credentials and the service/network aliases. Rebuild its generated backup client with the target image and current dump flags; keep the previous backup configuration for rollback. Validate Compose, authenticated Laravel/PDO access, table counts and representative data, views/routines, migrations and HTTP before resuming writers. Take a fresh target backup and rehearse restoring it.
6. If validation fails before reopening writes, stop the target and restore the saved Compose/backup configuration pointing to the untouched source volume. Once writes have resumed on the target, switching back would discard those new writes: reconcile them deliberately first. Retain the source and backups until the migration is accepted. Do not run `remove.sh` or `docker compose down -v` during this process.

The isolated migration suite exercises both Elestio → official paths with rows, Unicode, views/routines, authentication, private dumps, persistence and an independent rollback database. It is a fixture, not a guarantee for a customized production schema. See the [official PostgreSQL image documentation](https://github.com/docker-library/docs/blob/master/postgres/README.md), [official MySQL image documentation](https://github.com/docker-library/docs/blob/master/mysql/README.md), [MySQL upgrade prerequisites](https://dev.mysql.com/doc/refman/8.4/en/upgrade-prerequisites.html) and [mysqldump options](https://dev.mysql.com/doc/refman/8.4/en/mysqldump.html). PostgreSQL 18+ changes the default data layout and volume mount; selecting that version requires a separate migration plan.

---

## Tests and CI

The `tests/` folder holds a set of automated tests built on [bats](https://github.com/bats-core/bats-core). It checks that the script works as expected and that the created site matches the arguments passed.

| Suite | What it checks | Needs | Time |
|---|---|---|---|
| `static.bats` | `bash -n` syntax, no CRLF, shebang, templates present, `--help`, that every flag from `parse_args` is described in the help | bash only | seconds |
| `presets.bats` | presets, `--list-presets` and `--dry-run` (no root: the effective settings after presets, config files and flags are combined; no secrets printed; custom presets and their errors) | bash | seconds |
| `validation.bats` | invalid-argument scenarios, including `--repo`, `--deploy-key`, `--post-deploy` and `update.sh`: the script must refuse (`exit 1`) with a clear message **before** any change to the system | root | seconds |
| `safety.bats` | P1 regressions on temporary data: projects/proxy, SQL input and errors, Compose credential parsing, private ZIP publication and cleanup, production settings, migrations, restore preflight, Git updates and maintenance | Bash, Git, Python 3, gzip, zip, Compose CLI (no daemon); some cases need root | seconds |
| `hardening.bats` | private dumps/client credentials, literal endpoint JSON/timeouts, ports, module failures, proxy candidates/rollback/symlinks/concurrency/cancellation and release gating | root, Bash, Python, util-linux/procps, Compose CLI (no daemon) | seconds |
| `e2e-proxy.bats` | two real sites, invalid/missing-network/TLS candidates, failed apply recovery, HTTPS redirect/ACME, parallel operations and last-site removal | root, Docker | minutes |
| `e2e-db-migration.bats` | logical Elestio PostgreSQL 17 / MySQL 8.0 → official images, independent volumes, authentication, Unicode, views/routines, private dump/restore, persistence and retained rollback data | root, Docker, internet | minutes |
| `e2e.bats` | a real deployment: containers, ports, `.env`, Laravel version, DB and migrations, Redis, Basic Auth, Filament (admin and password), the application's HTTP responses, backup; then `list-projects`, `deactivate`, `activate`, `remove` (removes containers, volumes, network, proxy config and folder) | root, Docker, internet | 10–20 minutes |
| `e2e-repo.bats` | `--repo` and `update.sh` on a real application (a clone of `laravel/laravel`): deployment, `.deploy-meta`, production dependencies, `.env`, `--post-deploy`, then `update.sh` with a new commit and migration, refusal on local changes, a failing migration that keeps maintenance mode and prints the rollback | root, Docker, internet, git | 8–12 minutes |
| `e2e-modules.bats` | `--with filament,horizon`: the automatic `redis` dependency, valid Compose services, Filament admin and login page, production access rules and private defaults, Horizon running with its dashboard restricted, a queued job processed by Horizon, then `deactivate` / `activate` / `remove` | root, Docker, internet | 8–12 minutes |
| `e2e-options.bats` | generated slug/ports/credentials, real endpoint PUT and DH/ZIP, each preset, native DB dump/restore, local key-only SSH repository clone and update; `E2E_OPTION_CASE` selects the scenario | root, Docker, internet | minutes per case |
| `install-matrix.bats` | Does Laravel install under different conditions? One case per run (`INSTALL_CASE`): Laravel 12 and 13 with PostgreSQL or MySQL, with Filament, a database installed on the host, and the cases that must fail cleanly (`--repo` on the 10.x and 11.x branches, a version that does not exist). Each deployment is checked (version, `.env`, migrations, `artisan about` and `route:list`, HTTP 200, writable storage) and removed. See [Laravel versions and conditions](#laravel-versions-and-conditions) | root, Docker, internet | 5-15 minutes per case |

### Running locally

Only Docker is needed. The tests run in an isolated sandbox (Ubuntu with its own Docker daemon) and do not touch the host's Docker:

```bash
bash tests/run-local.sh                                    # unit: shellcheck + static + validation
bash tests/run-local.sh container                         # actual CLI image + native Bash, PostgreSQL
E2E_DB=mysql bash tests/run-local.sh container             # the same CLI lifecycle with MySQL
bash tests/run-local.sh kubernetes                        # real Laravel 13 on disposable kind
K8S_LARAVEL=12.0.0 bash tests/run-local.sh kubernetes       # the Kubernetes runtime with Laravel 12
bash tests/run-local.sh e2e                                # real deployment: PostgreSQL + Filament
bash tests/run-local.sh e2e-proxy                          # real two-site proxy and TLS regression
bash tests/run-local.sh e2e-db-migration                   # Elestio PostgreSQL 17 → official PostgreSQL 17
E2E_DB=mysql bash tests/run-local.sh e2e-db-migration       # Elestio MySQL 8.0 → official MySQL 8.4 LTS
bash tests/run-local.sh e2e-repo                           # deploy an existing app with --repo, then update.sh
bash tests/run-local.sh e2e-modules                        # --with filament,horizon
bash tests/run-local.sh install                                # the install matrix: every case, one after another (long)
bash tests/run-local.sh install laravel12-postgres native-mysql   # chosen cases only
E2E_DB=mysql E2E_FILAMENT=0 bash tests/run-local.sh e2e    # MySQL, no Filament
bash tests/run-local.sh all
bash tests/run-local.sh full                              # all 42 launch scenarios, sequentially
```

`full` runs all Laravel 12/13 × PostgreSQL/MySQL × Filament combinations, extras/config for both databases, modules and Git updates for both engines/branches, both logical migrations, the complete install matrix (including native databases and expected failures), proxy/TLS and unavailable-certificate checks, then each preset, generated settings/endpoint/DH/ZIP, native backups and key-only SSH clone/update for each database. The local SSH/endpoint fixtures use loopback inside the sandbox. It uses one disposable Docker daemon/cache and resets its resources between scenarios; do not share the cache with another running sandbox.

The full run can take more than an hour; each scenario has a 30-minute timeout. It continues after a failed case and returns nonzero if any case failed. `results.tsv`, per-case TAP and private deployment logs are saved under the printed `tmp/test-results/<run>` directory (Git-ignored, mode 700/600); generated files and their directory are assigned to the invoking user's UID/GID so a Linux Docker operator can read them. `LARASHIP_TEST_RESULTS=/absolute/path` chooses another local results directory; it must be empty and cannot be a symlink, so prior public files are never overwritten with secrets. `FULL_PHASE=base` selects the 30 base cases and `FULL_PHASE=options` the 12 additional option cases. `FULL_SCENARIOS=repo-mysql-13.x,options-ssh-repo-mysql` reruns exact IDs from the report; unknown IDs fail. `all` remains a shorter run for the selected DB. Repo/modules suites now accept `E2E_DB=mysql` too.

Successful Let's Encrypt issuance requires a real public domain/DNS and is not reproduced by these local fixtures; TLS routing is checked with a test certificate and issuance failure must leave HTTP working. The sandbox has Docker preinstalled, so installing Docker on a fresh systemd host is outside this matrix.

The e2e parameters are set through environment variables: `E2E_DB` (`postgres`|`mysql`), `E2E_FILAMENT` (`1`|`0`), `E2E_LARAVEL` (for example `12.0`; empty means the script's default version), `E2E_SSL` (`1` requests a certificate without DNS and checks that the script only warns), `E2E_EXTRAS` (`1` — also deploy with `--bind-local --use-redis --queue-worker --php-upload-max 64M` and check each of them; with `0`, check production settings and private ports without additional flags, no queue container, and unchanged PHP upload limits). The sandbox image cache lives in the `laraship-tests-docker` volume.

> **Do not run the E2E or migration suites on a live server.** They write to `/var/www` and create/remove Docker resources; site suites also take ports 80/443. Use the disposable sandbox. Without `E2E_ALLOW=1` they refuse to start.

### GitHub Actions

The workflow files are in `.github/workflows/`:

| Workflow | What it does | When |
|---|---|---|
| `lint.yml` | `bash -n`, CRLF check, ShellCheck, actionlint | push, PR |
| `tests.yml` | `static.bats`, `validation.bats`, `presets.bats`, `safety.bats`, `hardening.bats`, Python helper/release behavior tests | push, PR |
| `kubernetes.yml` | build the CLI/application images, CLI/native lifecycle with PostgreSQL/MySQL, API schema validation and real Laravel 12/13 migrations, replicas, HTTP and worker in disposable kind | push, PR, manually |
| `e2e.yml` | deployment, two-site proxy and legacy-to-official DB migration suites on a clean runner, matrix: PostgreSQL + Filament (Laravel 12, default options) and MySQL (default Laravel version, with the new options and the settings given through `--config`) | push and PR when scripts, helpers, templates, versions, changelog or tests change; on Mondays; manually |
| `codeql.yml` | CodeQL analysis of the workflow files themselves (language `actions`) | push, PR, weekly |

The E2E workflow has two more jobs, `e2e-repo` (for `--repo` and `update.sh`) and `e2e-modules` (for `--with filament,horizon`). The Install matrix workflow runs every case of `install-matrix.bats` once a week and on demand (Composer, Packagist and Laravel change over time), one job per case. CodeQL does not support Bash, so it checks only GitHub Actions, while the scripts themselves are covered by ShellCheck and the tests. Requesting a Let's Encrypt certificate (`E2E_SSL=1`) runs in CI only on schedule and manually, to avoid hitting rate limits on every PR. Dependabot proposes version updates for the actions (`.github/dependabot.yml`).

The badges at the top of the file point to the `shellharbor/laraship` repository; if you rename or fork it, update the paths in all badge links.

Release publication requires completed successful `lint.yml`, `tests.yml`, `e2e.yml`, `codeql.yml` and `kubernetes.yml` main/master push runs for the exact tagged commit. Missing, failed or running checks block publication; an earlier green commit is insufficient. Prepare VERSION and matching release notes deliberately before tagging. Major default changes remain in Unreleased until a release is assigned.
