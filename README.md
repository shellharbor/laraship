# LaraShip — deploy Laravel with Docker

![Laraship deploy Laravel with Docker Bash script](https://i.postimg.cc/Vv1vG8nL/laraship-hero-banner.jpg)

[![Lint](https://github.com/shellharbor/laraship/actions/workflows/lint.yml/badge.svg)](https://github.com/shellharbor/laraship/actions/workflows/lint.yml)
[![Tests](https://github.com/shellharbor/laraship/actions/workflows/tests.yml/badge.svg)](https://github.com/shellharbor/laraship/actions/workflows/tests.yml)
[![E2E](https://github.com/shellharbor/laraship/actions/workflows/e2e.yml/badge.svg)](https://github.com/shellharbor/laraship/actions/workflows/e2e.yml)
[![CodeQL](https://github.com/shellharbor/laraship/actions/workflows/codeql.yml/badge.svg)](https://github.com/shellharbor/laraship/actions/workflows/codeql.yml)

`deploy-laravel.sh` deploys a Laravel site, optionally with the Filament admin panel, on an Ubuntu server. Every site runs in its own set of Docker containers, and traffic is accepted by a shared reverse proxy, `nginxproxy`. The script installs Docker, creates the project from the `laravel/` template, installs Laravel, sets up PostgreSQL or MySQL (in a container or native on the host) and obtains a Let's Encrypt SSL certificate.

The `laraship` folder is self-contained: it holds the deploy script, templates, management utilities, examples and a skill for Claude Code. Copy it to the server as a whole (for example, to `/opt/laraship/`) and run the scripts **on the server as root**. From your workstation (for example, Windows) connect to the server over SSH.

---

## Contents

- [Folder contents](#folder-contents)
- [Architecture](#architecture)
- [Requirements](#requirements)
- [Quick start](#quick-start)
- [Arguments](#arguments)
- [What the script does](#what-the-script-does)
- [.env files](#env-files)
- [Database connection](#database-connection)
- [Filament](#filament)
- [Examples](#examples)
- [Useful commands](#useful-commands)
- [Project management](#project-management)
- [Re-running the script](#re-running-the-script)
- [Sending data to an endpoint](#sending-data-to-an-endpoint)
- [Security](#security)
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
├── activate.sh                    # re-enable a deactivated project
├── deactivate.sh                  # switch a project off without deleting it
├── remove.sh                      # remove a project completely
├── list-projects.sh               # list projects on the server
├── laravel/                       # project template → /var/www/<slug>
│   ├── docker-compose.yml
│   ├── .config/nginx/_site.conf
│   ├── .config/php/php.ini
│   └── .docker/                   # php/php81–83.Dockerfile, nginx/*.Dockerfile, init/postgres/01-init.sh
├── nginxproxy/                    # shared proxy template → /var/www/nginxproxy
│   ├── nginx.conf
│   ├── nginx.Dockerfile
│   └── site-template.conf
├── examples/                      # ready-made launch scenarios (see examples/README.md)
├── tests/                         # bats tests and the local sandbox runner
├── README.md                      # this file (English documentation)
├── .gitignore
```

The script looks for the `laravel/` and `nginxproxy/` templates next to itself, so the folder must be moved as a whole. `examples/`, `README.md`, `tests/` and `.claude/` are not required on the server, but they do no harm.

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
│   ├── dhparam.pem                 # Only with --create-dhparam
│   └── sites/
│       └── <slug>.conf             # upstream + server blocks 80/443; after deactivate.sh it becomes <slug>.conf.disabled
└── <slug>/                         # Site project
    ├── docker-compose.yml          # Project services, see below
    ├── .env                        # Project ports and passwords (generated by the script)
    ├── .config/
    │   ├── nginx/
    │   │   ├── _site.conf          # nginx inside the project (root = public_html/public)
    │   │   └── .htpasswd           # Only with --enable-basic-auth
    │   └── php/
    │       └── php.ini             # Copied, but not mounted by default (the line in compose is commented out)
    ├── .docker/
    │   ├── php/                    # php81/php82/php83.Dockerfile
    │   ├── nginx/                  # nginx-1.27.2/nginx-1.29.1.Dockerfile
    │   └── init/
    │       └── postgres/           # 01-init.sh — runs only on the first initialization of the containerized DB
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
| `db` | `<slug>_db` | `elestio/postgres:17` or `elestio/mysql:8.0` | The project's database. Host port `DB_PORT` → 5432/3306. The template contains `db_postgres` and `db_mysql`: the unused one is removed, the chosen one is renamed to `db`. With `--db-native` both are removed |
| `redis` | `<slug>_redis` | `redis:7-alpine` | Redis with a password (`--requirepass`) and AOF. Host port `REDIS_PORT` → 6379 |
| `certbot` | `<slug>_certbot` | `certbot/certbot` | Certificate issuance. Profile `manual`: does not start on `up`, run it with `docker compose run --rm certbot ...` |
| `certbot_renew` | `<slug>_certbot_renew` | `certbot/certbot` | Runs `certbot renew --webroot` every 12 hours (a loop set via `entrypoint`). nginx picks up the new certificate by itself thanks to the periodic reload |
| `artisan` | `<slug>_artisan` | `php83.Dockerfile` | Utility: `docker compose run --rm artisan <command>`, runs as `www` (uid 1000) |
| `composer` | `<slug>_composer` | `php83.Dockerfile` (+ composer 2) | Utility: `docker compose run --rm composer <command>`. Runs on the same PHP 8.3 as the application, as `www` (uid 1000), and checks package PHP requirements |
| `npm` | `<slug>_npm` | `node:current-alpine` | Utility: `npm ...`, runs as root |
| `cron` | `<slug>_cron` | `php83.Dockerfile` | Runs `php artisan schedule:run` every 600 seconds |
| `permissions` | `<slug>_permissions` | `busybox` | Utility: `chown 1000:1000`, permissions 644/755, and 775 for `storage` and `bootstrap/cache` |

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
- **Packages:** `python3` (used to edit configs), `curl`, `ss` (iproute2). `zip` is installed automatically with `--create-backup`.
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

Ports, passwords and database credentials that are not given explicitly are generated automatically. The script prints them to the console and saves them in `/var/www/shop/.env`. At the end it prints a summary block with the project data and next steps.

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
| `--laravel-version` | `X.Y` | `13.0` | Laravel version, installed as `laravel/laravel:^X.Y`. Minimum `10.0` |
| `--create-backup` | — | off | After deployment, create `/tmp/<slug>_<YYYYmmdd_HHMMSS>.zip` from the project folder |
| `--endpoint` | `URL` | — | Send the project data as JSON with PUT (see [below](#sending-data-to-an-endpoint)) |
| `--type` | `laravel` | — | Only for compatibility with the old `deploy.sh`. Any other value is an error. Do not use it in new commands |

### Filament

| Argument | Value | Default | Description |
|---|---|---|---|
| `--install-filament` | — | off | Install `filament/filament:^5.0` and the `/admin` panel |
| `--filament-email` | `EMAIL` | — | Administrator email. **Required** with `--install-filament`; checked immediately at startup |
| `--filament-name` | `NAME` | 8 chars `a-f0-9` | Administrator name |
| `--filament-password` | `PASS` | 10 chars `a-zA-Z0-9` | Administrator password |

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
| `--create-dhparam` | — | off | Create `/var/www/nginxproxy/dhparam.pem` (2048 bits, takes several minutes) and mount it into the project nginx (see [limitations](#known-limitations)) |
| `--enable-basic-auth` | — | off | Enable HTTP Basic Auth in the project nginx |
| `--auth-user` | `USER` | generated (15 chars) | Basic Auth user |
| `--auth-password` | `PASS` | generated (15 chars) | Basic Auth password |
| `--no-ssl` | — | — | Do not obtain an SSL certificate. `--ssl-email` is then not needed |
| `--obtain-ssl` | — | on | Obtain a certificate. This is the default behavior anyway; the flag is accepted but not listed in `--help`. Of `--no-ssl` and `--obtain-ssl` the last one wins |
| `-h`, `--help` | — | — | Show the help and exit. Checked before the root check |

---

## What the script does

The steps are listed in the order the functions are called in `main()`.

| # | Function | What it does | On error |
|---|---|---|---|
| 0 | — | If the arguments contain `-h` or `--help`, prints the help and exits | — |
| 1 | `check_root` | Checks that the script runs as root | exit |
| 2 | `ensure_www_dir` | Creates `/var/www` if it does not exist | exit |
| 3 | `parse_args` | Parses and validates flags: required ones, slug, domain and version format, root password for native MySQL, `--ssl-email`, `--filament-email`. Generates the slug (and changes the domain), Redis password, DB and Basic Auth credentials, **printing them to the console**. Checks that the `laravel/` template folder exists | exit |
| 4 | `assign_ports` | Picks free HTTP, HTTPS, PHP-FPM, Redis and DB ports | exit if no port is found |
| 5 | `install_docker` | Installs Docker CE and the compose plugin if there is no `docker` command | exit |
| 6 | `init_nginxproxy` | If `/var/www/nginxproxy` does not exist: copies `nginx.Dockerfile`, `nginx.conf` and `site-template.conf`, creates `sites/` and a base `docker-compose.yml` (ports 80/443, `nginx -s reload` every 6 hours, empty networks and volumes). An existing `nginxproxy` is left untouched | — |
| 7 | `create_dhparam` | Only with `--create-dhparam` and if `dhparam.pem` does not exist yet: generates it with `alpine/openssl` | exit |
| 8 | `create_project` | If `/var/www/<slug>` already exists, stops the containers (`docker compose down`) and **deletes the folder** without confirmation. Then copies the `laravel/` template, lays out the Dockerfiles in `.docker/php` and `.docker/nginx` and creates `.docker/init/postgres`. Creates `public_html` owned by `1000:1000`, because composer runs as `www`. Replaces `{SLUG}` in `docker-compose.yml`, configures the DB service (removes the unused one, renames the chosen one to `db`; with `--db-native` removes both together with their `depends_on`). Generates `.env`, replaces `MYSITE.COM` and `{SLUG}` in `_site.conf`. With `--create-dhparam` uncomments the `dhparam.pem` mount. With `--enable-basic-auth` creates `.htpasswd` (via `httpd:alpine`), uncomments its mount and the `auth_basic` directives | exit |
| 9 | `update_proxy_nginx_conf` | Creates `nginxproxy/sites/<slug>.conf` from `site-template.conf`. **If the file already exists, the step is skipped** | exit if the template is missing |
| 10 | `update_proxy_docker_compose` | Adds the external network `<slug>` and the volume `<slug>_ssl_certificates` (mounted at `/etc/letsencrypt/<slug>`) to `nginxproxy/docker-compose.yml` | — |
| 11 | `comment_ssl_blocks` | Comments out the `listen 443` server block in the project's `_site.conf` and in `sites/<slug>.conf`, so nginx starts without a certificate | — |
| 12 | `create_native_database` | Only with `--db-native`: creates the user and DB in the system DBMS (see [Database connection](#database-connection)) | exit if the DBMS is missing, unreachable, or the root password is wrong |
| 13 | `build_and_start_project` | Creates the `<slug>` network and volumes, runs `docker compose up -d --build`, waits 10 seconds and shows the container status | exit if `up` failed |
| 14 | `install_laravel` | Runs `docker compose run --rm composer create-project laravel/laravel:^X.Y .` (composer in the PHP 8.3 image, without `--ignore-platform-reqs`), then `docker compose run --rm permissions`. The step is skipped if `public_html/artisan` already exists | exit |
| 15 | `configure_laravel_env` | Sets `DB_CONNECTION`, `DB_HOST`, `DB_PORT`, `DB_DATABASE`, `DB_USERNAME`, `DB_PASSWORD` in `public_html/.env` (commented-out lines of Laravel 11+ are uncommented, Laravel 10 lines are replaced) and `APP_URL=https://<domain>`. Runs `artisan migrate --force` | **warning only** if migrations fail |
| 16 | `install_filament` | Only with `--install-filament`: `composer require filament/filament:"^5.0"`, then `artisan filament:install --panels`, then `artisan make:filament-user`. The credentials are appended to the project `.env` | **exit**: the following steps are not run |
| 17 | `restart_nginxproxy` | Runs `docker compose up -d` in `/var/www/nginxproxy`: attaches the project network and builds the proxy image on first start | warning |
| 18 | `obtain_ssl_certificate` | Unless `--no-ssl` is given: runs `certbot certonly --webroot` for the domain. On success uncomments the SSL blocks and restarts the project nginx and nginxproxy | **warning only**, the script continues |
| 19 | `send_project_data` | Only with `--endpoint`: sends the JSON with PUT | warning |
| 20 | `create_project_backup` | Only with `--create-backup`: creates a zip of the project folder in `/tmp` and appends the path to `.env` | exit |
| 21 | `print_summary` | Prints the summary: project, ports and **all passwords**, next steps | — |

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

The file is created by Laravel itself during `create-project`. The script changes only these lines:

```env
APP_URL=https://<domain>
DB_CONNECTION=pgsql            # or mysql
DB_HOST=<slug>_db              # native DB: 172.17.0.1
DB_PORT=5432                   # mysql: 3306; native DB — the DBMS port on the host
DB_DATABASE=...
DB_USERNAME=...
DB_PASSWORD=...
```

Everything else stays as in the standard Laravel `.env`, including `APP_ENV=local` and `APP_DEBUG=true`. Redis is **not written** to Laravel's `.env`. To use it and to move the site to production, edit the file by hand:

```env
APP_ENV=production
APP_DEBUG=false
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

The script writes the **internal** port to Laravel's `DB_PORT`. The external port is not listened on inside the project network. The published port is open on all host interfaces (see [Security](#security)).

For PostgreSQL, on the **first** initialization of an empty volume `.docker/init/postgres/01-init.sh` runs and sets the user's password (`ALTER USER`). With an existing volume neither this script nor the `POSTGRES_*`/`MYSQL_*` variables change the password.

### Native DB (`--db-native`)

- Laravel gets `DB_HOST=172.17.0.1` (the IP of the default `docker0` interface) and `DB_PORT` = `--port-postgres`/`--port-mysql`, defaulting to `5432`/`3306`. If `bip` is changed in `/etc/docker/daemon.json`, fix `DB_HOST` by hand.
- The DB is created through the default connection: `sudo -u postgres psql` or `mysql -u root -p<--db-root-password>`. The port flags do not affect **where** the DB is created. They only change Laravel's `DB_PORT`.
- **PostgreSQL:** `CREATE USER "<user>" WITH PASSWORD ...`, `CREATE DATABASE "<db>" OWNER "<user>"`, `GRANT ALL PRIVILEGES`. If the user or DB already exists, a warning is printed and the **password is not changed**.
- **MySQL:** `CREATE DATABASE IF NOT EXISTS`, `CREATE USER IF NOT EXISTS '<user>'@'%'`, `GRANT ALL PRIVILEGES ON <db>.* TO '<user>'@'%'`, `FLUSH PRIVILEGES`. The `'%'` host is needed because the application connects from a container through the docker bridge, not from localhost.

**Network reachability of the DBMS is the administrator's job; the script does not configure it.** The project containers are in the `<slug>` network, which has its own subnet. To find it:

```bash
docker network inspect <slug> -f '{{(index .IPAM.Config 0).Subnet}}'
```

- **PostgreSQL:** `listen_addresses` in `postgresql.conf` must include an address reachable from the containers (`172.17.0.1` or `*`). `pg_hba.conf` needs a line admitting the project subnet (or all docker subnets), for example `host <db> <user> 172.16.0.0/12 scram-sha-256`. After editing run `systemctl reload postgresql`.
- **MySQL:** check `bind-address` in `/etc/mysql/mysql.conf.d/mysqld.cnf`. On Ubuntu it defaults to `127.0.0.1`, and the containers will not be able to connect.
- **The firewall** (ufw/iptables) must allow traffic from the docker subnets to the DBMS port.

Check from a container: `cd /var/www/<slug> && docker compose run --rm artisan migrate:status`.

---

## Filament

With `--install-filament` (and the required `--filament-email`) the script performs three steps after migrations:

1. `docker compose run --rm composer require filament/filament:"^5.0"`
2. `docker compose run --rm artisan filament:install --panels`
3. `docker compose run --rm artisan make:filament-user --name=... --email=... --password=...`

Result:
- the admin panel at `https://<domain>/admin` (panel ID `admin` by default);
- the panel provider, usually `app/Providers/Filament/AdminPanelProvider.php`, and the published Filament assets in `public/`;
- a user in the `users` table;
- the lines `FILAMENT_ADMIN_NAME`, `FILAMENT_ADMIN_EMAIL` and `FILAMENT_ADMIN_PASSWORD` in `/var/www/<slug>/.env`, and the login credentials in the script output.

If `--filament-name`/`--filament-password` are not given, an 8-character `a-f0-9` name and a 10-character `a-zA-Z0-9` password are generated.

Important:
- **Compatibility.** The Laravel 13 + Filament 5 combination on PHP 8.3 has been verified with a real deployment. The script installs Filament `^5.0` regardless of `--laravel-version`, so for other Laravel versions (especially 10.x and 11.x) check compatibility in the Filament documentation. Composer runs in the same PHP 8.3 image as the application and checks package requirements. If they are incompatible it fails with a clear error instead of installing packages built for a different PHP version.
- **Any error in these steps terminates the script.** nginxproxy is not restarted, SSL is not obtained, and the endpoint and backup steps are not run. If migrations failed (which is only a warning), `make:filament-user` fails too: there is no `users` table.
- **Interactivity.** In a verification deployment `filament:install --panels` ran without questions. If the installer does ask for a panel ID (for example, in an interactive terminal), keep `admin`.
- **Production.** By default Filament lets users into the panel without extra checks only in the `local` environment. The script does not change `APP_ENV=local`. If you move the site to `APP_ENV=production`, the `User` model must implement `FilamentUser::canAccessPanel()`, otherwise you get 403. See the Filament documentation on production deployment for details.

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
# Result: /var/www/shop, domain shop.example.com (unchanged), MySQL 8.0 in the shop_db container
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
# Laravel: DB_HOST=172.17.0.1, DB_PORT=5432. PostgreSQL must already listen on the docker bridge,
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
# Result: DB and user 'user'@'%' created in the system MySQL; Laravel: DB_HOST=172.17.0.1, DB_PORT=3306.
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
# Result: the project and containers are created, but the HTTPS blocks are commented out; over HTTP only the ACME challenge is served,
# so the site opens after you obtain a certificate manually (see "SSL not obtained" in Troubleshooting)
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
# After deployment, manually: APP_ENV=production, APP_DEBUG=false, close the project's HTTP/HTTPS ports,
# Redis and DB with a firewall (PHP-FPM is already on 127.0.0.1 only)
```

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
docker compose run --rm artisan make:filament-user     # one more Filament administrator

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
1. runs `docker compose down` in the project folder;
2. renames `nginxproxy/sites/<slug>.conf` to `<slug>.conf.disabled`, otherwise the proxy nginx could not resolve the `<slug>_nginx` upstream and would stop starting for all sites;
3. comments out the `<slug>` lines (network and SSL volume) in `nginxproxy/docker-compose.yml`;
4. runs `docker restart nginxproxy`.

Data, volumes and the project folder are kept.

### `activate.sh` — switch back on

```bash
sudo bash /opt/laraship/activate.sh --slug <slug>
```

Steps:
1. runs `docker compose up -d --build` in the project;
2. renames `<slug>.conf.disabled` back to `<slug>.conf`;
3. uncomments the `<slug>` lines in `nginxproxy/docker-compose.yml`;
4. restarts the project's existing `php` and `nginx` services;
5. runs `docker compose up -d` in nginxproxy so the proxy reattaches to the project network, and then `docker restart nginxproxy`.

### `remove.sh` — complete removal

```bash
sudo bash /opt/laraship/remove.sh --slug <slug> --domain <domain>
# project with native MySQL: the root password is needed to remove its DB and user
sudo bash /opt/laraship/remove.sh --slug <slug> --domain <domain> --db-root-password '<root-password>'
```

`--slug` and `--domain` are required, and `--domain` is used only in messages. The script prints a warning and **asks you to type `yes`**; any other answer cancels the removal. After confirmation the steps are:

1. removes the `<slug>` network and SSL volume from `nginxproxy/docker-compose.yml`;
2. removes `nginxproxy/sites/<slug>.conf` and `<slug>.conf.disabled`;
3. runs `docker compose up -d` in nginxproxy;
4. runs `docker compose down` in the project;
5. removes the `<slug>_*` volumes listed in the project's `docker-compose.yml`, including the **DB data**;
6. removes the `<slug>` network;
7. runs `docker restart nginxproxy`;
8. removes the native DB, but only if the project `.env` has `DB_NATIVE=true`. The containerized DB is not touched by this step.
   - PostgreSQL: `DROP DATABASE` and `DROP USER` through `sudo -u postgres psql`.
   - MySQL: `DROP DATABASE` and `DROP USER '<user>'@'%', '<user>'@'localhost'` if `--db-root-password` is given. Without the password the script only prints the SQL for manual removal.
9. removes the backup archive from `BACKUP_ARCHIVE_PATH`;
10. removes `/var/www/<slug>`.

**This action is irreversible.**

---

## Re-running the script

If `/var/www/<slug>` already exists, the script, **without confirmation**:
1. looks for `<slug>_*` containers and, if any are running, runs `docker compose down` (without `-v`);
2. **deletes the whole `/var/www/<slug>` folder**: the code in `public_html`, both `.env` files and `.htpasswd`;
3. creates the project again and installs Laravel from scratch.

What **remains**:
- The Docker volumes `<slug>_db`, `<slug>_redis_data`, `<slug>_ssl_certificates` and `<slug>_certbot_www`. PostgreSQL and MySQL with a non-empty volume do not apply new `POSTGRES_*`/`MYSQL_*` values, and `01-init.sh` does not run. So **the newly generated passwords do not match the existing DB**: migrations fail with a warning, and `make:filament-user` terminates the script.
- The file `nginxproxy/sites/<slug>.conf`: it is not regenerated, so if you change the domain with the same slug, the proxy keeps the old domain.
- For a native DB, the existing user and DB. Their password is not changed.

Recommendations:
- **Clean reinstall:** first `remove.sh --slug <slug> --domain <domain>` (for native MySQL also `--db-root-password`), then `deploy-laravel.sh`.
- **You need to keep the DB data:** before re-running, copy `/var/www/<slug>/.env` and pass the previous credentials explicitly (`--db-postgres-name/-user/-password` or `--db-mysql-*`, optionally `--redis-password`). The code in `public_html` will still be deleted, so save it beforehand (`--create-backup` or `tar`).

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
- Values are not escaped. Explicit passwords containing `"` or `\` will break the JSON.
- A non-2xx response produces only a warning. The request carries all passwords in plain text, so use HTTPS endpoints only.

---

## Security

- **Secret generation.** `/dev/urandom` is used. Passwords are 15 characters from `A-Za-z0-9@%_+-`: characters that break `sed`, `.env` and docker compose (`& | / \ $ # =` and quotes) are excluded from the set. DB names, users and the Basic Auth login are 15 characters `[a-z][a-z0-9]{14}`. The Filament password is only 10 characters `a-zA-Z0-9`, so for production it is better to set your own. Compose explicit passwords from `A-Za-z0-9@%_+-` too: values are written to `.env` without quotes.
- **Where secrets live.** The script prints generated values to the console at generation time and all passwords in the final block. Keep this in mind when recording sessions and in CI logs. On disk the secrets are stored in plain text in `/var/www/<slug>/.env` and `public_html/.env`. The script does not change these files' permissions, so `chmod 600 /var/www/<slug>/.env` is recommended. `--db-root-password` is passed on the command line, so it stays in the shell history and is visible in `ps` while the script runs.
- **Published ports.** PHP-FPM is published only on `127.0.0.1:${PHP_PORT}`, because FastCGI has no authentication. The project nginx's HTTP/HTTPS ports, Redis and the containerized DB are still open on all host interfaces (`0.0.0.0`). Redis and the DB are protected only by passwords. Docker writes its own iptables rules bypassing ufw. Only 80/443 should be open from outside. Close the remaining ports with a cloud firewall or rules in the `DOCKER-USER` chain, or bind them to `127.0.0.1` in the project's `docker-compose.yml`.
- **Laravel defaults.** `APP_ENV=local` and `APP_DEBUG=true` remain, and xdebug is enabled in the PHP image. For production switch the environment (see [.env files](#env-files)).
- **TLS.** TLS 1.2/1.3 and HSTS are enabled on the project nginx. The HTTP→HTTPS redirect is not enabled, but the application is not served over HTTP anyway.
- **Basic Auth** is an extra barrier, not full protection: see [limitations](#known-limitations).

---

## Troubleshooting / FAQ

### Migrations failed (`Failed to run Laravel migrations`)

This is only a warning, the script continues. But with `--install-filament` it terminates at `make:filament-user`. Possible causes:
- the DB did not finish initializing: after `up` the script waits only 10 seconds, and the first MySQL initialization can take longer;
- after a re-run an old volume with a different password remained (see [Re-running the script](#re-running-the-script));
- the native DBMS is unreachable from the container.

```bash
cd /var/www/<slug>
docker compose logs --tail=50 db
grep '^DB_' public_html/.env
docker compose run --rm artisan migrate --force
```

If Filament did not get installed after that, run its three commands by hand (see [Filament](#filament)), then restart the proxy (`cd /var/www/nginxproxy && docker compose up -d`) and obtain SSL as described below.

### SSL not obtained

If certbot fails, the script prints a warning and **continues**. The SSL blocks in `_site.conf` and `sites/<slug>.conf` stay commented out, so the site is unreachable over both HTTPS and HTTP (over HTTP only the ACME challenge is served). Check:
- the domain's A record points to the server. For an automatic slug the `*.<domain>` record is needed.
- ports 80/443 are open, nginxproxy is running, and `curl -I http://<domain>/.well-known/acme-challenge/test` reaches the server (a 404 from nginx is normal).
- the Let's Encrypt rate limits are not exceeded.

After fixing:

```bash
cd /var/www/<slug>
docker compose run --rm certbot certonly --webroot -w /var/www/certbot \
  -d <domain> --email <email> --agree-tos --non-interactive

# Uncomment the SSL blocks: the script added exactly one '#' at the start of every block line
sed -i '/^#server {/,/^#}/ s/^#//' .config/nginx/_site.conf /var/www/nginxproxy/sites/<slug>.conf

docker compose exec nginx nginx -t && docker compose restart nginx
cd /var/www/nginxproxy && docker compose restart
```

The same procedure works after `--no-ssl`.

### nginxproxy does not start or restarts in a loop

Look at `docker logs --tail=50 nginxproxy` and `cd /var/www/nginxproxy && docker compose up -d`:
- **`address already in use` on 80/443** — the port is taken by another web server on the host (`sudo ss -tlnp | grep -E ':(80|443) '`).
- **`host not found in upstream "<slug>_nginx..."`** — `sites/` holds a project `*.conf` whose containers are not running: they did not start during deployment, were stopped by hand without `deactivate.sh`, or were removed without `remove.sh`. Start the project, switch it off with `deactivate.sh`, or rename the config to `<slug>.conf.disabled`.
- **`network <slug> declared as external, but could not be found`** — the deployment was interrupted after step 10, before the network was created (for example, on a native DB). Repeat the deployment or remove the `<slug>` entries from `nginxproxy/docker-compose.yml` and `sites/<slug>.conf`.
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
- PHP. The project's `.config/php/php.ini` is **not mounted** by default, so the defaults `upload_max_filesize = 2M` and `post_max_size = 8M` apply.

To allow large uploads:
1. raise these values in `.config/php/php.ini`;
2. uncomment the line `- ./.config/php/php.ini:/usr/local/etc/php/php.ini:ro` in the `php` service;
3. run `docker compose up -d php`.

Servers deployed with an old version, without the proxy's `nginx.conf` fix, reject uploads over 1 MB (see [Updating an already deployed server](#updating-an-already-deployed-server)).

### Other

- **502 Bad Gateway.** The `<slug>_php` container is not running: look at `docker compose ps` and `docker compose logs php`.
- **`http://domain` returns 404.** By design: the project nginx's HTTP block serves only `/.well-known/acme-challenge/`, and the `return 301` line is commented out. Use `https://`.
- **The certificate was renewed, but the browser sees the old one.** The project nginx and `nginxproxy` reload certificates by themselves every 6 hours. To apply a new certificate immediately, run `docker exec nginxproxy nginx -s reload` and `docker compose exec nginx nginx -s reload`. On servers deployed with an old version there is no periodic reload until you perform the steps from [Updating an already deployed server](#updating-an-already-deployed-server). The renewal log: `docker compose logs certbot_renew`.
- **A port is busy after activating an old project.** Auto-selection considers only ports that are being listened on right now. Ports of stopped projects may be handed out to a new one. If you have deactivated projects, set ports explicitly.
- **Scheduler tasks run irregularly.** `cron` calls `schedule:run` every 10 minutes. Change `sleep 600` to `sleep 60` in the project's `docker-compose.yml` and run `docker compose up -d cron`.
- **How to change the PHP version.** Change `dockerfile: php83.Dockerfile` for the `php`, `artisan`, `composer` and `cron` services to `php81.Dockerfile` or `php82.Dockerfile` and run `docker compose up -d --build`. Composer is built into all three Dockerfiles.

---

## Known limitations

- **Basic Auth does not protect the PHP location.** `auth_basic` is enabled only in `location /` of the HTTPS block in `_site.conf`. A request straight to `/index.php` (including `/index.php/<route>`) hits `location ~ [^/]\.php(/|$)`, which has no `auth_basic`, and bypasses the protection.
- **The native MySQL root password is not stored.** `--db-root-password` is written nowhere, so to remove such a DB pass it to `remove.sh` again. The `Root Password` line in the final output and `DB_MYSQL_PASSWORD_ROOT` in `.env` with `--db-native` contain a random value, not the system MySQL root password.
- **`--create-dhparam` has almost no effect.** The file is created and mounted into the project nginx, but the `_site.conf` template has no `#ssl_dhparam` line, so the directive is not enabled. nginxproxy, which terminates TLS for clients, does not use this file. Add `ssl_dhparam` by hand for an effect.
- **Scheduler and queues.** `cron` calls `schedule:run` every 10 minutes, not every minute. There is no queue worker (`queue:work`).
- **PHP is fixed at 8.3.** The script does not pick PHP for `--laravel-version`. If the chosen Laravel version or a package needs a different PHP, composer refuses and you have to change the PHP version by hand (see [Troubleshooting](#troubleshooting--faq)).
- **PHP upload limit** is 2M/8M by default because the project's `php.ini` is not mounted (see [Troubleshooting](#troubleshooting--faq)).
- **HTTP.** The application is not served over HTTP, and there is no redirect to HTTPS. With `--no-ssl` the site is unreachable until a certificate is obtained manually.
- **Re-running** deletes the project folder without confirmation and does not update an existing `sites/<slug>.conf` (see [Re-running the script](#re-running-the-script)).
- **Special characters in explicit values** (`$`, `#`, spaces, quotes, `\`) can break the project `.env` (read by docker compose), the Laravel `.env` or the endpoint JSON.
- **The project's HTTP/HTTPS ports, Redis and the DB are open on all interfaces** (PHP-FPM only on `127.0.0.1`), see [Security](#security).
- **Laravel defaults:** `APP_ENV=local`, `APP_DEBUG=true`, xdebug is enabled in the PHP image (see [Security](#security)).
- **Backup** is a zip of the `/var/www/<slug>` folder in `/tmp`. It contains neither the DB data from the Docker volume nor certificates, and `/tmp` may be cleared on reboot.

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

The script does not overwrite an existing `/var/www/nginxproxy` or already created projects. To get the fixes on a server deployed with an old version, perform the steps below. Template paths are given for `/opt/laraship`.

**1. The shared proxy.** This step is done once per server and affects all sites.
- In `/var/www/nginxproxy/nginx.conf`, add the line `client_max_body_size 2048m;` to the `http { … }` block.
- In `/var/www/nginxproxy/docker-compose.yml`, add periodic certificate reloading to the `nginxproxy` service:
  ```yaml
      command: /bin/sh -c 'while :; do sleep 21600 & wait $${!}; nginx -s reload; done & exec nginx -g "daemon off;"'
  ```
- Apply the changes: `cd /var/www/nginxproxy && docker compose up -d`. The proxy is recreated, and sites are unavailable for a few seconds.

**2. Each Laravel project** (`/var/www/<slug>/docker-compose.yml`). The reference is `laravel/docker-compose.yml` in this folder; replace `{SLUG}` in it with the project slug.
- `php`: port `"${PHP_PORT}:9000"` → `"127.0.0.1:${PHP_PORT}:9000"`.
- `nginx`: add the same `command:` line as for the proxy in step 1.
- `certbot_renew`: replace `command: >` with `entrypoint: >`. The line with `docker kill --signal=HUP` can be removed, it does not work.
- `composer`: replace the service with the variant from the template (built from `php83.Dockerfile`, `entrypoint: [ 'composer' ]`, without `--ignore-platform-reqs`).
- `cron`: `dockerfile: php82.Dockerfile` → `php83.Dockerfile`.
- Copy the updated Dockerfiles with the built-in composer:
  ```bash
  cp /opt/laraship/laravel/.docker/php/php8*.Dockerfile /var/www/<slug>/.docker/php/
  cd /var/www/<slug> && docker compose up -d --build
  ```

**3. If the application is already broken** by packages installed by the old composer for a foreign PHP (`syntax error` in `vendor/`), rebuild the dependencies for PHP 8.3. The old composer ran as root, so first give the files back to the `www` user:
```bash
cd /var/www/<slug>
docker compose run --rm permissions
docker compose run --rm composer update      # composer.lock is updated for PHP 8.3
docker compose run --rm artisan migrate --force
```

---

## Tests and CI

The `tests/` folder holds a set of automated tests built on [bats](https://github.com/bats-core/bats-core). It checks that the script works as expected and that the created site matches the arguments passed.

| Suite | What it checks | Needs | Time |
|---|---|---|---|
| `static.bats` | `bash -n` syntax, no CRLF, shebang, templates present, `--help`, that every flag from `parse_args` is described in the help | bash only | seconds |
| `validation.bats` | 13 invalid-argument scenarios: the script must refuse (`exit 1`) with a clear message **before** any change to the system | root | seconds |
| `e2e.bats` | a real deployment: containers, ports, `.env`, Laravel version, DB and migrations, Redis, Basic Auth, Filament (admin and password), the application's HTTP responses, backup; then `list-projects`, `deactivate`, `activate`, `remove` (removes containers, volumes, network, proxy config and folder) | root, Docker, internet | 10–20 minutes |

### Running locally

Only Docker is needed. The tests run in an isolated sandbox (Ubuntu with its own Docker daemon) and do not touch the host's Docker:

```bash
bash tests/run-local.sh                                    # unit: shellcheck + static + validation
bash tests/run-local.sh e2e                                # real deployment: PostgreSQL + Filament
E2E_DB=mysql E2E_FILAMENT=0 bash tests/run-local.sh e2e    # MySQL, no Filament
bash tests/run-local.sh all
```

The e2e parameters are set through environment variables: `E2E_DB` (`postgres`|`mysql`), `E2E_FILAMENT` (`1`|`0`), `E2E_LARAVEL` (for example `12.0`; empty means the script's default version), `E2E_SSL` (`1` requests a certificate without DNS and checks that the script only warns). The sandbox image cache lives in the `laraship-tests-docker` volume.

> **Do not run `tests/e2e.bats` on a live server.** It writes to `/var/www`, takes ports 80/443 and creates Docker resources. Without `E2E_ALLOW=1` the test refuses to start.

### GitHub Actions

The workflow files are in `.github/workflows/`:

| Workflow | What it does | When |
|---|---|---|
| `lint.yml` | `bash -n`, CRLF check, ShellCheck, actionlint | push, PR |
| `tests.yml` | `static.bats` and `validation.bats` | push, PR |
| `e2e.yml` | `e2e.bats` on a clean runner, matrix: PostgreSQL + Filament (Laravel 12) and MySQL (default version) | push and PR when scripts, templates or tests change; on Mondays; manually |
| `codeql.yml` | CodeQL analysis of the workflow files themselves (language `actions`) | push, PR, weekly |

CodeQL does not support Bash, so it checks only GitHub Actions, while the scripts themselves are covered by ShellCheck and the tests. Requesting a Let's Encrypt certificate (`E2E_SSL=1`) runs in CI only on schedule and manually, to avoid hitting rate limits on every PR. Dependabot proposes version updates for the actions (`.github/dependabot.yml`).

The badges at the top of the file point to the `shellharbor/laraship` repository; if you rename or fork it, update the path in all four links.
