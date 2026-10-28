# LaraShip CLI reference and configurator contract

Verified against repository `VERSION=1.3.2` on 2026-10-28. This is a complete reference to the public deployment, management, Python-adapter and Kubernetes arguments in that source version, intended as implementation context for the [LaraShip command builder](https://shellharbor.github.io/laraship-docs/#configure). It describes actual parser behavior, including compatibility flags and limitations that are easy to miss in short help output. Future releases may change the contract; version the configurator's option catalog with the toolkit it targets.

All examples are Bash commands for the target Linux server. `shop.example.com`, addresses and paths are examples, not credentials. Installations and management operations require the documented server permissions; the website only constructs commands. Internal helper function arguments and test-harness controls are not public deployment options.

## Contents

- [Entry points and command availability](#entry-points-and-command-availability)
- [Argument syntax](#argument-syntax)
- [Every deployment argument](#every-deployment-argument)
- [Configuration files, presets and versions](#configuration-files-presets-and-versions)
- [Dependencies and validation for a configurator](#dependencies-and-validation-for-a-configurator)
- [Deployment behavior and outputs](#deployment-behavior-and-outputs)
- [Management commands and every argument](#management-commands-and-every-argument)
- [Python CLI and every adapter argument](#python-cli-and-every-adapter-argument)
- [Run through a temporary Docker container](#run-through-a-temporary-docker-container)
- [Use the image in Docker Compose](#use-the-image-in-docker-compose)
- [Kubernetes adapter and every argument](#kubernetes-adapter-and-every-argument)
- [Configurator implementation checklist](#configurator-implementation-checklist)
- [Source map and verification scope](#source-map-and-verification-scope)

## Entry points and command availability

LaraShip has two deployment models: the original Linux/Compose provisioner and an independent Kubernetes application-image adapter. The Python package is an installer/dispatcher, not another implementation of deployment.

| Operation | Native toolkit | Docker image command | Python package command |
|---|---|---|---|
| Deploy a new Compose project | `bash deploy-laravel.sh ARGS` | `deploy ARGS` | `laraship deploy ADAPTER_ARGS -- ARGS` |
| Update a Git-backed project | `bash update.sh ARGS` | `update ARGS` | `laraship update ADAPTER_ARGS -- ARGS` |
| Database dump/list/restore | `bash backup.sh ARGS` | `backup ARGS` | `laraship backup ADAPTER_ARGS -- ARGS` |
| Activate a project | `bash activate.sh ARGS` | `activate ARGS` | `laraship activate ADAPTER_ARGS -- ARGS` |
| Deactivate a project | `bash deactivate.sh ARGS` | `deactivate ARGS` | `laraship deactivate ADAPTER_ARGS -- ARGS` |
| Remove a project and its data | `bash remove.sh ARGS` | `remove ARGS` | `laraship remove ADAPTER_ARGS -- ARGS` |
| List projects | `bash list-projects.sh` | `list` | `laraship list ADAPTER_ARGS` |
| Toolkit version | `bash deploy-laravel.sh --version` | `--version` or `-V` | `laraship toolkit-version ADAPTER_ARGS` |
| Adapter/package version | Not applicable | Not applicable | `laraship --version` |
| Install toolkit/pull CLI image | Download the release toolkit | `docker pull shellharbor/laraship:1.3.2` on the host | `laraship install INSTALL_ARGS` |
| Render/deploy Kubernetes resources | `bash kubernetes.sh render\|deploy ARGS` | `kubernetes render\|deploy ARGS` | No Kubernetes subcommand in Python CLI 1.3.2 |

Docker also accepts these script-name aliases: `deploy-laravel.sh`, `update.sh`, `backup.sh`, `activate.sh`, `deactivate.sh`, `remove.sh`, `list-projects.sh`. Its top-level help accepts `--help`, `-h`, or `help`; an omitted command shows help. An unknown Docker command exits with code 2. Python does not expose these script-name aliases.

Full native provisioning targets Ubuntu/Linux. A Windows/macOS workstation can construct commands and connect by SSH; Docker Desktop is not a supported substitute for the Linux host-bind/host-network Compose deployment contract. The independently portable Kubernetes application image has a different runtime contract.

## Argument syntax

- For Bash scripts, generate separate tokens: `--domain shop.example.com`, not `--domain=shop.example.com`. The Bash parsers do not implement the equals form, short-option bundling or a general `--` terminator.
- A value consumes exactly one token. Quote spaces and shell metacharacters, for example `--filament-name 'Site Administrator'`. Boolean switches take no following value: use `--no-ssl`, not `--no-ssl true` or `--no-ssl=false`.
- Scalar deployment options generally use the last occurrence. Modules accumulate and are deduplicated; `--preset` is repeatable; `--config` is allowed only once.
- Deployment help/version/module/preset listing is detected by an early scan, before normal required-option checks. Keep these informational requests separate from a deployment; do not generate data values equal to informational switches.
- Python adapter options go before its separator `--`; Bash backend arguments go after it. These are different option namespaces. For example, `laraship deploy --backend docker -- --dry-run ...` previews deployment, while `laraship install --dry-run` previews installing the toolkit/image.
- Do not invent generic flags such as deployment `--yes`, `--force`, `--force-recreate`, `--db-host`, `--env`, `--php-version` or `--public-ports`. They do not exist. `--force` belongs to **update**, and `--yes` belongs to **backup restore**.

## Every deployment argument

Invocation: `sudo bash /opt/laraship/deploy-laravel.sh [OPTIONS]`. The same deployment options follow Docker's `deploy`, or Python's `deploy ... --`.

The **Config key** column is the exact `KEY=VALUE` equivalent for `--config`. A dash means the option is not accepted in that file. These keys are not automatically read from the process environment.

### Inspection and configuration selection

| Argument | Config key | Value/default | Behavior |
|---|---|---|---|
| `-h`, `--help` | — | No value | Print deployment help and exit 0; no root or server mounts required. |
| `-V`, `--version` | — | No value | Print toolkit version and exit 0. |
| `--list-modules` | — | No value | List available module names/descriptions and exit 0. |
| `--list-presets` | — | No value | List available presets/descriptions and exit 0. |
| `--dry-run` | — | Off | Read, merge and validate settings, display an effective-settings summary and exit without deployment. Does not require root; no hooks/API delivery. It does not prove Docker, DNS, ports, dependencies or credentials work. |
| `--config FILE` | — | Unset | Read one configuration file. CLI values override it. File must be readable; mode 600 is recommended for credentials. |
| `--preset NAME` | `PRESET` | None; repeatable on CLI | Load `presets/NAME.conf`; shipped names are `admin-panel`, `api`, `staging`. Names match `[a-z][a-z0-9-]*`. A config file may also contain `PRESET=NAME`; a preset cannot include another preset. |

### Project identity and application source

| Argument | Config key | Value/default | Behavior |
|---|---|---|---|
| `--slug SLUG` | `SLUG` | Random 8 lowercase letters/digits | Project identity, directory, network and container prefix. If omitted, the script also changes the domain to `RANDOM_SLUG.DOMAIN`. Supply a slug to retain the exact requested hostname. |
| `--domain DOMAIN` | `DOMAIN` | **Required** | Hostname only, without URL scheme, path or port. Parser allows ASCII letters, digits, dots and hyphens; the UI should additionally validate a usable DNS hostname. |
| `--laravel-version X.Y` | `LARAVEL_VERSION` | `13.0` from `versions.env` | Fresh skeleton Composer constraint `laravel/laravel:^X.Y`, not an exact patch pin. Format `X.Y`; minimum `12.0`. Cannot be explicitly combined with `--repo`, even when equal to the default. |
| `--type laravel` | — | Unset | Undocumented compatibility option for the old dispatcher. Only `laravel` is accepted. New commands should omit it. |
| `--repo URL` | `REPO` | Unset: install fresh Laravel | Clone an existing Laravel app instead of creating a skeleton. HTTPS/HTTP, SSH, `git://`, `file://` and SCP-style `user@host:path` are accepted by the parser; prefer HTTPS or SSH. Embedded URL credentials are refused. A local `file://` source must actually be visible to the runner. |
| `--branch BRANCH` | `BRANCH` | Repository default branch | Requires `--repo`. Pattern `[A-Za-z0-9][A-Za-z0-9._/-]*`; Git may reject additional invalid ref forms. |
| `--deploy-key PATH` | `DEPLOY_KEY` | Unset | Existing SSH private key, only with `--repo` and an SSH-style URL. Docker requires an explicit read-only mount. Private-repository access and host verification must work from the runner. |
| `--post-deploy COMMANDS` | `POST_DEPLOY` | Unset | One shell command string, run through `sh -c` inside the project's PHP container at `/var/www/html`. Works with fresh or Git apps. Newlines are refused; join commands using `&&` or `;`. Failure is recorded, remaining deployment stages continue, then the deployment exits nonzero. Git metadata retains commands for later updates. |

Slug validation is `[A-Za-z0-9][A-Za-z0-9_-]*`; `nginxproxy` is reserved case-insensitively. An existing `/var/www/SLUG` path, including a symlink, is refused. There is no overwrite flag. Preserve an existing project through management commands; removal is an explicit destructive operation.

### Database selection and credentials

| Argument | Config key | Value/default | Behavior |
|---|---|---|---|
| `--db-type postgres` or `--db-type mysql` | `DB_TYPE` | **Required** | Select exactly one database family. PostgreSQL maps to Laravel `DB_CONNECTION=pgsql`; MySQL maps to `mysql`. |
| `--db-native` | `DB_NATIVE` | Off: container DB | Use a database already installed on the server and provision its application DB/user. Supported by native Bash/Python-native only; operational Docker deployment refuses it, including when enabled in a config/preset. |
| `--db-root-password PASS` | `DB_ROOT_PASSWORD` | Required for native MySQL | Existing host MySQL administrative password used to create the database/user. Different from the container initialization password below. Not needed for native PostgreSQL, which uses the host `postgres` account. |
| `--db-mysql-name NAME` | `DB_MYSQL_NAME` | Generated 15-character name | Application database for MySQL. Only the selected DB family's settings take effect. |
| `--db-mysql-user USER` | `DB_MYSQL_USER` | Generated 15-character name | MySQL application user; containerized MySQL refuses the exact user `root`. |
| `--db-mysql-password PASS` | `DB_MYSQL_PASSWORD` | Generated 15-character password | MySQL application password. |
| `--db-mysql-root-password PASS` | `DB_MYSQL_ROOT_PASSWORD` | Generated 15-character password | Root initialization password of the **containerized** MySQL server. Does not authenticate to native MySQL. |
| `--db-postgres-name NAME` | `DB_POSTGRES_NAME` | Generated 15-character name | PostgreSQL application database. |
| `--db-postgres-user USER` | `DB_POSTGRES_USER` | Generated 15-character name | PostgreSQL initialization/application user. Do not label this a restricted application-only role: the official image's initialization user is privileged. |
| `--db-postgres-password PASS` | `DB_POSTGRES_PASSWORD` | Generated 15-character password | PostgreSQL initialization/application password. |

Database names/users start with an ASCII letter, digit or underscore, then contain ASCII letters/digits/underscores/hyphens. PostgreSQL names/users are at most 63 characters; MySQL database names at most 64 and users at most 32. Generated names start with a lowercase letter. Passwords reject control characters. Containerized MySQL additionally rejects single quotes, double quotes and backslashes in both initialization passwords; native MySQL and PostgreSQL have separate safe encoding paths.

Generated passwords use `A-Za-z0-9@%_+-`. Blank scalar values in a config file are skipped; omitting a credential requests generation. Native DB mode is not a generic remote-database connector: the script provisions through host-local administrative clients, and configures the application to reach the Docker bridge gateway. A nondefault native port changes the application connection but does not retarget every host provisioning client; verify that setup separately. Existing users are not guaranteed to have passwords reset by provisioning.

### Ports and Redis

| Argument | Config key | Default | Meaning |
|---|---|---|---|
| `--port-http PORT` | `PORT_HTTP` | Random free `8100–8400` | Project Nginx host HTTP port. Shared public proxy still listens on 80. |
| `--port-https PORT` | `PORT_HTTPS` | Random free `4100–4300` | Project Nginx host HTTPS port; shared proxy uses 443. With SSL disabled the project TLS block stays disabled. |
| `--port-php PORT` | `PORT_PHP` | Random free `9100–9600` | PHP-FPM host FastCGI port; not an HTTP endpoint. |
| `--port-redis PORT` | `PORT_REDIS` | Random free `6500–6800` | Redis host port; application containers use Redis's internal 6379. |
| `--port-postgres PORT` | `PORT_POSTGRES` | Random free `5500–5800`; native: `5432` | Container host publication for PostgreSQL, or the application's target port in native mode. Container-to-container DB traffic uses 5432. |
| `--port-mysql PORT` | `PORT_MYSQL` | Random free `3400–3600`; native: `3306` | Container host publication for MySQL, or the application's target port in native mode. Container-to-container DB traffic uses 3306. |
| `--redis-password PASS` | `REDIS_PASSWORD` | Generated 15-character password | Redis password, including when the Redis module is not selected. Rejects control characters. |
| `--bind-local` | `BIND_LOCAL` | Already on | Compatibility switch. All project publications are always bound to `127.0.0.1`; there is no switch to publish them publicly. Does not hide shared proxy 80/443. |

All six explicit ports must be decimal integers from 1 through 65535 (leading zeros are normalized). Active project host ports must be distinct, unused and different from reserved proxy ports 80/443. The active set is HTTP/HTTPS/PHP/Redis plus the selected container DB; a native DB's existing listening port is not checked as a new publication. Unselected DB ports have no operational effect. Random allocation happens during deployment, not in dry-run output; the actual server checks remain authoritative.

The base template always includes Redis. `--use-redis` configures Laravel to use it; it does not decide whether a Redis container exists.

### Optional modules, Filament and PHP limits

| Argument | Config key | Default | Behavior |
|---|---|---|---|
| `--with NAME[,NAME]` | `WITH` | No optional modules | Enable one or more modules. Repeatable; comma-separated values accumulate; module dependencies are enabled automatically. Available: `filament`, `redis`, `queue`, `horizon`, `backup`. |
| `--install-filament` | `INSTALL_FILAMENT` | Off | Alias for `--with filament`. Install Filament admin panel at `/admin` on a fresh skeleton. |
| `--filament-email EMAIL` | `FILAMENT_EMAIL` | Required when Filament enabled | Administrator email. The module checks presence; it is not a complete frontend email validator. |
| `--filament-name NAME` | `FILAMENT_NAME` | Generated 8 hex characters | Administrator display name; quote spaces. |
| `--filament-password PASS` | `FILAMENT_PASSWORD` | Generated 15-character password | Administrator password; rejects control characters. |
| `--use-redis` | `USE_REDIS` | Off | Alias for `--with redis`. Set Laravel `REDIS_*`, `CACHE_STORE`/legacy `CACHE_DRIVER`, `SESSION_DRIVER`, and `QUEUE_CONNECTION=redis`. |
| `--queue-worker` | `QUEUE_WORKER` | Off | Alias for `--with queue`. Add a `php artisan queue:work` container. Does **not** implicitly enable Redis; may use the application's database queue. A synchronous queue leaves the worker idle. |
| `--backup-keep DAYS` | `BACKUP_KEEP` | `7` | Retention of the `backup` module's database dumps, integer 1–3650 when that module is enabled. Does not enable the module or control project ZIP archives. |
| `--php-upload-max SIZE` | `PHP_UPLOAD_MAX` | PHP defaults: upload 2M, POST 8M | Set both `upload_max_filesize` and `post_max_size` to the same size. Parser accepts digits plus optional `K`, `M`, `G` (case-insensitive), e.g. `64M`, `1G`, `1048576`. Creates/mounts a project INI file. |

| Module | Adds/changes | Dependencies and restrictions |
|---|---|---|
| `filament` | Filament `^5.0`, `/admin`, administrator and production panel access limited to configured administrator | Needs `--filament-email`; incompatible with `--repo`. |
| `redis` | Laravel cache, session and queue drivers/configuration | No module dependency; works with Git apps. |
| `queue` | Separate queue worker container | No automatic Redis dependency; incompatible with `horizon`. |
| `horizon` | Installs Laravel Horizon; supervisor container and `/horizon` | Automatically enables `redis`; incompatible with `queue`/`--queue-worker` and `--repo`. Production dashboard authorization remains an application responsibility. |
| `backup` | A dump immediately on service start, then every 24 hours; private `backups/` files and restore helpers | Dump retention controlled by `--backup-keep`. Native PostgreSQL selects a compatible client major; a default container deployment uses its selected DB image line. |

Modules run their own validation before deployment. Filament and Horizon are forbidden for Git apps because those applications manage their own dependencies. Redis, queue and backup remain available. A custom module publishing migrations must run its own guarded migration; there is no public flag to reorder the initial migration phase.

### HTTPS and HTTP Basic Authentication

| Argument | Config key | Default | Behavior |
|---|---|---|---|
| `--ssl-email EMAIL` | `SSL_EMAIL` | Required unless `--no-ssl` | Let's Encrypt registration email. Usable DNS and public HTTP access are operational requirements. |
| `--no-ssl` | `NO_SSL` | Off | Do not request a certificate; use HTTP application URLs and keep TLS blocks disabled. |
| `--obtain-ssl` | `OBTAIN_SSL` | Already on | Compatibility/explicit enable switch accepted by the parser, although omitted from short help. Reverses an earlier `--no-ssl`; the last SSL switch wins. Requires an email in the resulting configuration. |
| `--create-dhparam` | `CREATE_DHPARAM` | Off | Generate a 2048-bit `dhparam.pem` if missing. May take minutes; does not itself enable HTTPS or request a certificate. |
| `--enable-basic-auth` | `ENABLE_BASIC_AUTH` | Off | Enable HTTP Basic Auth. ACME challenge routing remains accessible. |
| `--auth-user USER` | `AUTH_USER` | Generated 15-character name when enabled | Basic Auth username. Pattern `[A-Za-z0-9][A-Za-z0-9_.@-]*`. Giving this alone does not enable Basic Auth. |
| `--auth-password PASS` | `AUTH_PASSWORD` | Generated 15-character password when enabled | Basic Auth password; rejects control characters. Giving this alone does not enable Basic Auth. Stored HTTP credentials use bcrypt. |

The script starts with HTTP and switches `APP_URL` to HTTPS only after successful TLS setup. Certificate issuance failure can warn and leave a functioning HTTP deployment; requesting SSL is not proof SSL is enabled. Expose requested and actual TLS status as distinct concepts in the configurator/integration.

### Project ZIP, legacy API and completion hooks

| Argument | Config key | Default | Behavior |
|---|---|---|---|
| `--create-backup` | `CREATE_BACKUP` | Off | Create a private project ZIP after deployment, including project files and `.env` secrets. Native output: `/tmp`; Docker output: `/var/backups/laraship`, unless configured through `LARASHIP_ARCHIVE_DIR`. Not a logical DB dump and does not enable the `backup` module. |
| `--endpoint URL` | `ENDPOINT` | Unset | Legacy **PUT** JSON notification near the end of deployment, before ZIP creation. Sends generated project credentials. Not a general failure callback. Transport/non-2xx failure warns without changing the deployment outcome. |
| `--allow-insecure-endpoint` | `ALLOW_INSECURE_ENDPOINT` | Off | Explicitly allow plain HTTP for **both** endpoint features. Otherwise require HTTPS. Does not disable TLS certificate verification. |
| `--on-complete PATH` | `ON_COMPLETE` | Unset | Execute a trusted local program with completion JSON on stdin after success, operational failure or handled cancellation. Docker executes it inside the administrative CLI container. |
| `--completion-endpoint URL` | `COMPLETION_ENDPOINT` | Unset | **POST** the same completion JSON to an API after finalization. Different contract from `--endpoint`. Includes `Idempotency-Key: RUN_ID`. |
| `--completion-token-file PATH` | `COMPLETION_TOKEN_FILE` | Unset | Private file containing the API Bearer token; requires `--completion-endpoint`. Never pass the token value as an argument. |
| `--completion-include-secrets` | `COMPLETION_INCLUDE_SECRETS` | Off | Explicitly include known application DB/Redis/Basic Auth/Filament passwords in completion data. Never includes DB root passwords, API tokens, SSH keys, raw commands or complete `.env` contents. Requires a completion target. |
| `--completion-timeout SECONDS` | `COMPLETION_TIMEOUT` | `30` | Integer 1–300 for **each** completion target. Script and API are attempted independently, once each, sequentially. A nondefault timeout requires a completion target. Does not change legacy PUT timeouts. |

Both endpoint URLs must be absolute HTTP(S) URLs with a hostname, valid port if given, no embedded username/password, whitespace or control characters. Redirects are not followed; HTTPS certificates are verified. HTTP requires explicit opt-in. Legacy PUT uses a five-second connection timeout and 20-second total timeout. Endpoint/client diagnostics and hook output are suppressed to avoid exposing secrets in delivery logs. This does not redact all normal deployment output: generated credentials and the final summary are sensitive.

Completion is armed after full argument validation. No callback for help, listings, dry run, invalid configuration, earlier bootstrap/root failures, SIGKILL or power loss. It runs after resource cleanup and project-lock release; callback failures do not replace the original deployment status. Completion hooks apply only to initial deployment, not update/backup/activate/deactivate/remove or Kubernetes. See [completion guide](COMPLETION.md).

Hook/token paths must be absolute without `..`, refer to regular files rather than symlinks, and be owned by the invoking user (root for deployment). Files must be readable and not group/other writable; hooks must be executable; token mode must be 600 or stricter. Parent directories must be trusted, real directories owned by root/invoking user and not group/other writable, apart from a root-owned sticky temporary directory. Token content is a single nonempty ASCII token, no whitespace after trimming trailing CR/LF, at most 8192 file bytes.

### Completion and legacy API payload context

Completion `schema_version=1` contains these fields; fields not yet known may be `null` or false:

| Field | Meaning |
|---|---|
| `schema_version`, `run_id`, `operation` | Schema integer 1, generated UUID, operation `deploy`. |
| `status`, `exit_code`, `signal`, `stage` | `success`, `failed`, or `cancelled`; original process result; handled signal; last stage. |
| `toolkit_version`, `started_at`, `finished_at`, `duration_seconds` | Toolkit release, UTC ISO timestamps and elapsed duration. |
| `project` | `slug`, `domain`, `path`, effective `url`, configured `laravel_version`. For Git apps the configured version is not a probe of the installed framework. |
| `ports` | Known host `http`, `https`, `php`, `redis` ports. |
| `database` | `type`, `native`, selected host/target `port`, `name`, `user`; optional `password`. |
| `basic_auth`, `filament` | Basic Auth `enabled`/`user`; Filament `requested`/`email`/`name`; passwords only with opt-in and when applicable. |
| `ssl`, `readiness` | SSL `requested` and actually `enabled`; `http_checked` and `proxy_registered`. |
| `archive_path`, `secrets_included` | Final private ZIP path if created, and the secrets opt-in boolean. |
| `redis` | Present only with secrets opt-in; contains `password`. |

The last stage may be `preflight`, `docker_install`, `project_create`, `dhparam`, `nginx_configure`, `database_create`, `containers_start`, `application_install`, `application_configure`, `modules_install`, `post_deploy`, `http_readiness`, `proxy_register`, `ssl`, `legacy_endpoint`, `archive`, `summary` or `complete`. Treat this as diagnostic metadata, not proof an earlier stage changed nothing or a stable progress percentage. A deferred post-deploy failure reports stage `post_deploy` even after later stages ran.

Legacy PUT payload fields are `slug`, `domain`, `app_type`, `laravel_version`, `db_type`, `ports` (`http`, `https`, `php`, `redis`), `redis.password`, `database` (`type`, `port`, `name`, `user`, `password`), `basic_auth` (`enabled`, `user`, `password`), `ssl` (`enabled`, `email`), and `project_path`. Its `ssl.enabled` represents the requested SSL flag, not necessarily successful issuance. It has no final exit status, run ID or ZIP path and no completion-token option. It includes passwords without the completion secrets opt-in. Do not silently substitute one API feature for the other.

## Configuration files, presets and versions

### File format and precedence

Config files contain `KEY=VALUE` lines, blank lines and full-line `#` comments. Keys are normalized case-insensitively with underscores converted to flag hyphens; use the uppercase names in the tables. Whitespace around a value and one pair of matching outer quotes are stripped. There is no shell expansion, command substitution, escape decoding or inline-comment syntax. Values containing `#` remain literal, not a trailing comment.

```ini
# /opt/laraship-input/shop.conf -- protect with chmod 600
SLUG=shop
DOMAIN=shop.example.com
DB_TYPE=postgres
SSL_EMAIL=admin@example.com
WITH=redis,queue,backup
BACKUP_KEEP=14
PHP_UPLOAD_MAX=64M
CREATE_BACKUP=true
```

Effective order:

1. Built-in defaults and the toolkit's `versions.env`.
2. Explicit `--preset` flags, in their CLI order.
3. The single `--config` file, in line order. An inline `PRESET=NAME` inserts that preset at that point.
4. Ordinary command-line options, in their CLI order.

An accepted boolean key emits a switch for `true`, `yes`, `1`, `on` (case-insensitive). `false`, `no`, `0`, `off` or an empty value emits **nothing**; it does not undo earlier settings. Scalar empty values are also skipped. Unknown keys and invalid boolean spellings fail.

Consequences for the builder:

- Scalar values can be overridden; repeated module selections accumulate. No `--without`/module-removal flag exists.
- A true Basic Auth/module switch in a preset cannot be removed by `ENABLE_BASIC_AUTH=false`/`INSTALL_FILAMENT=false` in config.
- `NO_SSL=false` does not undo `NO_SSL=true`; explicitly emit the opposing `--obtain-ssl` if appropriate. Conversely `OBTAIN_SSL=false` does not disable the default SSL request; use `--no-ssl`.
- `BIND_LOCAL=false` cannot enable public ports, because loopback binding is the enforced default.
- `CONFIG`, `DRY_RUN`, `TYPE`, `HELP`, `VERSION`, and listing switches are not config keys. `PRESET` is a special key, not part of a deployment flag list inside presets.

### Shipped presets

| Name | Exact settings | Additional inputs/restrictions |
|---|---|---|
| `admin-panel` | `WITH=filament,redis,queue`; `BIND_LOCAL=true` | Needs Filament email; incompatible with Git apps and with Horizon. |
| `api` | `WITH=horizon`; `BIND_LOCAL=true`; `PHP_UPLOAD_MAX=16M` | Horizon enables Redis; incompatible with Git apps and plain queue. Upload size can be overridden. |
| `staging` | `ENABLE_BASIC_AUTH=true`; `WITH=redis`; `BIND_LOCAL=true` | Basic Auth credentials generated unless given; works with Git apps. |

Presets cannot contain another `PRESET`; shipped presets deliberately contain no slug, domain or credentials. Combining `admin-panel` and `api` fails because queue and Horizon conflict. An optional UI preset selector must show the resulting module/settings selection, not hide additive behavior.

### `versions.env`: toolkit-wide inputs, not deployment flags

| Key | Current value | Meaning |
|---|---|---|
| `LARAVEL_VERSION` | `13.0` | Default fresh skeleton `^13.0`; accepts `X.Y`. |
| `LARAVEL_MIN_VERSION` | `12.0` | Minimum accepted `--laravel-version`, also `X.Y`. |
| `FILAMENT_VERSION` | `^5.0` | Filament Composer constraint. |
| `POSTGRES_IMAGE` | `postgres:17` | New container PostgreSQL deployments. |
| `MYSQL_IMAGE` | `mysql:8.4` | New container MySQL deployments, 8.4 LTS. |

The file is read next to the deployment script, parsed rather than sourced. Only these keys are accepted; database image values require an `image:tag` form, not a digest. Changing it does not upgrade existing project copies or database volumes. The Docker CLI image contains its own release copy; passing `-e POSTGRES_IMAGE=...` does not override it. No public deployment flag selects PHP, PECL or Composer versions. The default PHP template is 8.3.35; changing to the supplied PHP 8.2.34 template is a manual application-compatible build change, not a configurator switch. Laravel 13 requires the PHP 8.3 path.

### Relevant runtime environment

| Name | Scope | Contract |
|---|---|---|
| `LARASHIP_ARCHIVE_DIR` | Project ZIP output | Existing absolute real directory; native default `/tmp`; image default `/var/backups/laraship`. Docker requires a writable identical host bind for the chosen directory even when ZIP creation is off. Python Docker mode exposes `--archive-dir`. |
| `KUBECONFIG` | Kubernetes deploy | Select a usable kubeconfig; explicit `--context` is still required. Mount embedded-certificate credentials read-only for container use. |
| `DOCKER_HOST`, `DOCKER_CONTEXT` | Docker client selection | Server-adapter operations require local `/var/run/docker.sock`; Python rejects a different host or explicit context. Do not advertise remote-daemon support. |
| `LARASHIP_CONTAINER` | Internal image marker | Set by the official CLI image. Do not expose it as a configuration field or override it to bypass native-database guards. |

Deployment keys such as `DB_TYPE`, `ON_COMPLETE`, `NO_SSL` and `ALLOW_INSECURE_ENDPOINT` belong in a config file or CLI arguments. Simply exporting environment variables of those names is not the deployment interface.

## Dependencies and validation for a configurator

Use these rules before command generation, then rely on server validation for actual execution:

| Condition | Required or prohibited behavior |
|---|---|
| Any normal deployment | Domain and DB type required; provide explicit slug if the domain must remain exact. |
| SSL requested | Require SSL email; preserve requested/actual status distinction. |
| Docker execution | Already running local Linux Docker Engine/Compose, root runner, host networking and identical host binds; disable native DB provisioning. |
| Native MySQL | Require host administrative password `--db-root-password`; keep separate from container root initialization password. |
| PostgreSQL vs MySQL | Emit only selected-family credential/port fields; validate name/user lengths and container MySQL password restrictions. |
| Existing Git app | Require repo; allow branch/key only with repo; SSH key only with SSH URL; omit explicit Laravel version; disable Filament/Horizon and presets adding them. |
| Filament | Require email; no Git app. Name/password may be generated. |
| Horizon | Add Redis; reject plain queue, including indirectly from presets. |
| Plain queue | Redis optional; no Horizon. |
| Basic Auth | Enable switch is separate from credentials; validate username if enabled. |
| Scheduled DB backups | Add `backup` module; validate retention 1–3650. ZIP is independent. |
| Completion token | Require completion API URL and a trusted private file. |
| Completion secrets/nondefault timeout | Require script or completion API target. |
| HTTP endpoint | Require explicit insecure-endpoint opt-in for either API type; never imply this enables insecure HTTPS. |
| Paths for container operations | Explicitly mount config, key, hook and token inputs; mount destinations must match the generated paths. |
| Existing slug/path | Refuse reinstall; offer update for Git projects or separately confirmed removal. |
| Destructive operations | Removal has an interactive literal `yes`; restore has interactive `yes` or explicit `--yes`. No generic deployment confirmation flag. |

The parser is not a complete DNS/email/Git-ref validator. Frontend checks may be stricter, but must not promise server reachability, free ports, certificate issuance, package compatibility or database authentication. Dry run validates settings and local input files, not operational readiness.

## Deployment behavior and outputs

The main sequence is: validate/arm completion; lock/check new path; select/check ports; ensure Docker for native execution; create project/configuration; optional DH parameters; configure database; build/start containers and authenticate to DB; install skeleton or clone/install app; configure Laravel and run initial migrations; install optional modules; post-deploy commands; project HTTP readiness; shared proxy registration; optional TLS; legacy PUT; optional project ZIP; summary; final completion delivery.

Important results and limits:

- Persistent project files live at `/var/www/SLUG`, application code at `public_html/`, and shared routing at `/var/www/nginxproxy`. Deleting the temporary CLI container does not delete separately deployed project containers, host files or named volumes.
- New Laravel environment defaults are production, debug off, mode-600 `.env`, PHP without Xdebug. Default loopback publications do not block public access through shared Nginx 80/443.
- Default Compose services include PHP, Nginx, cron, Redis and the selected DB, with utility roles such as Composer, Artisan and permissions. Optional modules add workers/backup; disabling Redis wiring does not remove its base container.
- An initial migration error is fatal. Project state can remain after failure, and the script will refuse reinstalling over it; inspect/recover rather than retrying destructively.
- Update/restore failures may leave maintenance mode enabled with recovery instructions. No automatic database/schema rollback is promised.
- The project ZIP is mode 600 and contains secrets; DB dumps are separate logical backups under `backups/`. A ZIP of the project directory is not a consistent snapshot of Docker database volumes.
- Normal logs/summary can contain generated credentials. A command builder should avoid saving passwords in URLs, analytics, browser history or ordinary copy logs; show generated-secret expectations without fabricating their eventual values.
- Native Bash scripts conventionally exit 0 for success and nonzero for failure. Handled HUP/INT/TERM during armed completion use 129/130/143; notification failures do not replace that result. A cancelled removal currently exits 0, while a cancelled restore is nonzero. Output is human-readable except versioned completion JSON and Kubernetes render JSON.

## Management commands and every argument

Management does not consume the deployment config/preset file. All project operations target `/var/www/SLUG`, use the same project identity rules and require root. Completion flags are not accepted here.

### `update.sh`

Only for projects originally deployed with `--repo`, with `.deploy-meta`, a running PHP service and no tracked local modifications. Pulls the recorded repository branch; this is not a new-app installer or database image upgrade.

| Argument | Default | Behavior |
|---|---|---|
| `--slug SLUG` | **Required** | Existing Git-backed project. |
| `--no-migrate` | Off | Skip `artisan migrate --force`. No corresponding initial-deploy flag exists. |
| `--post-deploy COMMANDS` | Stored deployment commands | Replace post-deploy commands for this invocation; single-line string. An explicit empty `''` suppresses stored commands. |
| `--reset` | Off: fast-forward only | Use `git reset --hard` to fetched branch, discarding local commit history; does not bypass the tracked-working-tree cleanliness check. |
| `--force` | Off | Execute steps even when fetched commit equals current commit. Does not bypass maintenance or other checks. |
| `-h`, `--help` | — | Help without root/project lookup. |

```bash
sudo bash /opt/laraship/update.sh --slug shop
sudo bash /opt/laraship/update.sh --slug shop --force --post-deploy 'php artisan config:cache'
```

The old code enters maintenance before switching commits. Then permissions, production Composer install, optional migrations, cache/worker refresh, PHP restart and post-deploy run before `artisan up`. Failure retains maintenance and prints recovery steps; the operator must assess any already-applied migration.

### `backup.sh`

Requires a project deployed with `--with backup` and generated `.config/backup/dump.sh`.

| Argument/action | Default | Behavior |
|---|---|---|
| `--slug SLUG` | **Required** | Existing backup-enabled project. |
| `now` | Exactly one action required | Create a logical DB dump now. |
| `list` | Exactly one action required | List project dump files; not the global project inventory. |
| `restore FILE` | Exactly one action required | Restore an existing dump basename inside project `backups/`; replaces current data. Filename allows letters/digits/dot/underscore/hyphen, but no `..` substring or directory components. |
| `--yes` | Off | Skip the literal `yes` confirmation for restore. Not a removal or deployment option. |
| `-h`, `--help` | — | Help without root/project lookup. |

```bash
sudo bash /opt/laraship/backup.sh --slug shop now
sudo bash /opt/laraship/backup.sh --slug shop list
sudo bash /opt/laraship/backup.sh --slug shop restore shop-REPLACE_WITH_ACTUAL_DUMP.dump
```

Choose the real dump filename from `list`. PostgreSQL uses custom-format `.dump`; MySQL uses `.sql.gz`. Restore validates the dump before maintenance/service changes, stops writers, imports and restarts services. It can retain maintenance after failure. Take a new dump before replacing data if rollback may be needed.

### `activate.sh` and `deactivate.sh`

| Command | Every accepted argument | Behavior |
|---|---|---|
| `activate.sh` | `--slug SLUG` (**required**) | Build/start project services and restore shared proxy routing; preserves DB volumes. |
| `deactivate.sh` | `--slug SLUG` (**required**) | Disable shared routing and run Compose down. Containers are removed, while project files and DB volumes remain. |

These two scripts do not implement `--help`/`-h`, `--config`, `--yes` or `--force`. Do not assume uniform help flags across Bash commands.

```bash
sudo bash /opt/laraship/deactivate.sh --slug shop
sudo bash /opt/laraship/activate.sh --slug shop
```

### `remove.sh`

| Argument | Default | Behavior |
|---|---|---|
| `--slug SLUG` | **Required** | Project to remove. |
| `--domain DOMAIN` | **Required** | Project domain supplied for the removal interface/summary; use the recorded domain rather than trusting it to select another project. |
| `--db-root-password PASS` | Required to drop native MySQL DB/user | Existing native MySQL administrative password. Not needed for a container DB or native PostgreSQL. Docker refuses removal of a native-DB project before mutations. |

No help or noninteractive confirmation flag exists. The script reads the exact word `yes` from stdin. Removal deletes project containers, named volumes/database data, network, proxy registration, eligible ZIP archive and project directory; native execution also handles native DB/user deletion. An incorrect confirmation cancels with exit 0. Do not place an automatic `yes` pipe in a generated default command.

```bash
sudo bash /opt/laraship/remove.sh --slug shop --domain shop.example.com
```

### `list-projects.sh`

No public arguments. It scans `/var/www`, displays project/service/routing information and suggested lifecycle commands. It does not parse or validate supplied arguments; do not invent filters, JSON output or a help option. In Docker mode certificate inspection uses an already available `busybox:1.37.0` helper; unavailable helper means `UNKNOWN`, not proof of a missing certificate.

```bash
sudo bash /opt/laraship/list-projects.sh
```

## Python CLI and every adapter argument

Install the published adapter in a venv or with pipx. Python requirement is 3.10+; there are no runtime package dependencies. The native toolkit/Docker image is installed or pulled separately.

```bash
pipx install laraship==1.3.2
# Alternative, inside an activated virtual environment:
python -m pip install laraship==1.3.2

laraship --version
laraship install --backend native --version 1.3.2 --directory /opt/laraship
laraship install --backend docker --version 1.3.2
```

Creating `/opt/laraship` needs sufficient permissions; use `sudo` with the absolute installed CLI path when required, or select a new directory in an existing user-owned parent. Package installation itself does not deploy applications or install a host Docker daemon.

### Top-level and `install`

| Scope/argument | Default | Behavior |
|---|---|---|
| Top-level `-h`, `--help` | — | Show adapter commands. |
| Top-level `--version` | — | Show installed **Python package** version, not toolkit version. No top-level `-V` alias. |
| `install -h`, `install --help` | — | Installation help. |
| `install --backend native\|docker` | `native` | Download/extract a native toolkit release, or pull official CLI image. |
| `install --version RELEASE` | Package release `1.3.2` | Exact raw release spelling such as `1.3.2` or `1.3.2-rc.1`, without leading `v`. Not `latest`, ranges or a Laravel version. |
| `install --directory PATH` | `/opt/laraship` | New native toolkit destination. Must be absolute, without `..` components, commas, NUL, CR or LF, no symlink components, existing parent and nonexistent destination. Ignored for Docker installation. |
| `install --dry-run` | Off | Show installation/pull plan without network or writes. A native preview still validates destination constraints. |

Native download uses the GitHub release archive and matching SHA-256 file; extraction is bounded and rejects unsafe entries. Existing directories are refused, including an already installed toolkit. To change versions, install into a new directory and explicitly select it on subsequent native commands. Docker installation of another version likewise does not change the adapter's default image. Exact release strings match `[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z]+(?:\.[0-9A-Za-z]+)*)?`; build metadata and leading `v` are not accepted by this adapter.

### Shared runner options

These apply to each of `deploy`, `update`, `backup`, `activate`, `deactivate`, `remove`, `list`, `toolkit-version`:

| Argument | Default | Behavior |
|---|---|---|
| `-h`, `--help` before `--` | — | Help for this adapter subcommand. For backend help, put it after `--`, only where supported. |
| `--backend native\|docker` | `native` | Select execution backend. Does not install it automatically. |
| `--directory PATH` | `/opt/laraship` | Installed native toolkit path. Ignored by Docker backend. |
| `--image IMAGE` | `shellharbor/laraship:1.3.2` | Docker backend only. Exact release tag or lowercase SHA-256 digest. Mutable `latest` aliases are refused. Current parser accepts lowercase repository components/slashes; it does not support a registry-host port or arbitrary nonrelease tag. |
| `--archive-dir PATH` | `/var/backups/laraship` | Docker project-ZIP directory and identical host bind. Must be separate from protected server/runtime paths. Does not change native ZIP output; use `LARASHIP_ARCHIVE_DIR` for native. |
| `--mount-readonly ABSOLUTE_PATH` | None; repeatable | Docker only: expose an existing host file/directory at that same absolute path, read-only. Refuses mounts hiding protected toolkit/server paths. Use for config, SSH key, hook/token or a local repository input. |
| `--` | Separator | Everything after it belongs to the selected Bash command. Preserve token boundaries exactly. |

`toolkit-version` accepts the shared adapter options but **no** backend arguments. Native execution uses Bash; Docker execution uses a temporary `docker run --rm --init` container. Stdin and exit status are preserved; a TTY is added only when both stdin/stdout are terminals.

For isolated Docker inspection, put `--dry-run`, `--help`, `-h`, `--version`, `-V`, `--list-modules` or `--list-presets` **first** after `--` on `deploy`. `toolkit-version` is also isolated. Explicit read-only input mounts remain available. These run without networking/server-state mounts, with a read-only root and temporary `/tmp`. Python recognizes an exact backend `--help` for other commands too; use that only for `update` and `backup`, whose image/script help paths support it. Normal server operations require Linux/root and the local socket, and create missing host directories only after validation.

```bash
laraship deploy --backend native --directory /opt/laraship -- \
  --dry-run --slug shop --domain shop.example.com --db-type postgres --no-ssl

laraship deploy --backend docker --image shellharbor/laraship:1.3.2 -- \
  --dry-run --slug shop --domain shop.example.com --db-type postgres --no-ssl

LARASHIP_CLI="$(command -v laraship)"
sudo "$LARASHIP_CLI" deploy --backend docker --image shellharbor/laraship:1.3.2 \
  --mount-readonly /opt/laraship-input -- \
  --config /opt/laraship-input/shop.conf
```

The adapter currently has no Kubernetes subcommand. Use native `kubernetes.sh` or the image's `kubernetes` command directly. See [Python guide](PYTHON.md) for installation/publication details.

## Run through a temporary Docker container

The official image is the administrative CLI, not the Laravel application's web image. It connects to the host's already running Linux Docker Engine; deployed application containers are siblings managed by that daemon. No Docker-in-Docker or `--privileged` is needed. The published 1.3.2 image targets `linux/amd64`; do not promise native ARM availability.

### Inspect without server access

```bash
docker pull shellharbor/laraship:1.3.2
docker run --rm --init --network none --read-only --tmpfs /tmp \
  shellharbor/laraship:1.3.2 --version
docker run --rm --init --network none --read-only --tmpfs /tmp \
  shellharbor/laraship:1.3.2 deploy --help
docker run --rm --init --network none --read-only --tmpfs /tmp \
  shellharbor/laraship:1.3.2 deploy --dry-run \
  --slug shop --domain shop.example.com --db-type postgres --no-ssl
```

For reproducible image selection, replace the version tag with a verified `shellharbor/laraship@sha256:...` digest. A tag can be rebuilt; a digest selects exact image content.

### Deploy and manage a project

Run on the target Linux server as an administrator. Create host directories first; long-form `--mount` fails on a missing source rather than silently creating a wrong directory.

```bash
sudo install -d -m 755 /var/www
sudo install -d -m 700 /run/lock/laraship /var/backups/laraship

sudo docker run --rm --init -it --network host \
  --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
  --mount type=bind,src=/var/www,dst=/var/www \
  --mount type=bind,src=/run/lock/laraship,dst=/run/lock/laraship \
  --mount type=bind,src=/var/backups/laraship,dst=/var/backups/laraship \
  shellharbor/laraship:1.3.2 deploy \
  --slug shop --domain shop.example.com --db-type postgres \
  --ssl-email admin@example.com --with redis,queue,backup --create-backup
```

All four binds are required and writable for operational Compose commands, including when ZIP creation is off. Keep the **identical absolute source/destination paths**. Host networking is required for occupied-port inspection and loopback readiness. Keep Docker-generated hostname/hosts files; do not override them. The socket grants administrative access to the host, so use a trusted CLI image. No published ports belong on the administrative runner itself.

Use the same invocation/mounts for `list`, `update --slug shop`, `backup --slug shop now`, `backup --slug shop list`, `activate --slug shop`, `deactivate --slug shop`, and `remove --slug shop --domain shop.example.com`. `--rm` removes only the runner after exit. Keep `-it` for interactive removal/restore; for automation, use `-i` without `-t` when stdin must be forwarded.

For repeated interactive use, a Bash helper can retain the common mounts:

```bash
laraship_docker() {
  sudo docker run --rm --init -it --network host \
    --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
    --mount type=bind,src=/var/www,dst=/var/www \
    --mount type=bind,src=/run/lock/laraship,dst=/run/lock/laraship \
    --mount type=bind,src=/var/backups/laraship,dst=/var/backups/laraship \
    shellharbor/laraship:1.3.2 "$@"
}
laraship_docker list
laraship_docker backup --slug shop now
```

### Config, SSH key, completion hook and API token

Prepare `/opt/laraship-input` on the host, owned by root with mode 700. Place only the inputs this operation needs there: e.g. `shop.conf` mode 600; SSH key/token mode 600; executable hook mode 700. Do not bake these into an image or commit them. A completion hook runs inside the runner, with its installed tools; any extra dependency must be deliberately provided.

```bash
sudo docker run --rm --init -it --network host \
  --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
  --mount type=bind,src=/var/www,dst=/var/www \
  --mount type=bind,src=/run/lock/laraship,dst=/run/lock/laraship \
  --mount type=bind,src=/var/backups/laraship,dst=/var/backups/laraship \
  --mount type=bind,src=/opt/laraship-input,dst=/opt/laraship-input,readonly \
  shellharbor/laraship:1.3.2 deploy --config /opt/laraship-input/shop.conf \
  --on-complete /opt/laraship-input/notify.sh \
  --completion-endpoint https://control.example.com/api/deployments \
  --completion-token-file /opt/laraship-input/api-token
```

This example assumes those files already exist and satisfy validation; no secret values are shown. Add `--completion-include-secrets` only when the receiver explicitly needs application passwords. The read-only input directory cannot store hook results; use a deliberately writable persistent path such as the mounted archive directory for private reports.

Set `-e LARASHIP_ARCHIVE_DIR=/absolute/custom/path` and replace the archive bind with that identical writable source/destination to change Docker ZIP output. Do not change the internal container marker. Native host DB provisioning/deletion is unavailable through this runner.

## Use the image in Docker Compose

Add a **one-off tools service** to an operator Compose project. This service invokes LaraShip and exits; it is not a web server, background agent or sidecar that should restart deployment. Existing Laravel application services remain managed by their generated project Compose files.

Prepare the same four host paths as above, plus the root-owned input directory containing `shop.conf`. Save this as `compose.yaml`, or merge the `laraship` service into an existing operator file:

```yaml
services:
  laraship:
    image: shellharbor/laraship:1.3.2
    profiles: [tools]
    user: "0:0"
    init: true
    restart: "no"
    network_mode: host
    stdin_open: true
    tty: true
    stop_grace_period: 75s
    environment:
      LARASHIP_ARCHIVE_DIR: /var/backups/laraship
    volumes:
      - type: bind
        source: /var/run/docker.sock
        target: /var/run/docker.sock
        bind:
          create_host_path: false
      - type: bind
        source: /var/www
        target: /var/www
        bind:
          create_host_path: false
      - type: bind
        source: /run/lock/laraship
        target: /run/lock/laraship
        bind:
          create_host_path: false
      - type: bind
        source: /var/backups/laraship
        target: /var/backups/laraship
        bind:
          create_host_path: false
      - type: bind
        source: /opt/laraship-input
        target: /opt/laraship-input
        read_only: true
        bind:
          create_host_path: false
    command: ["--help"]
```

No `ports`, Compose `networks`, `privileged`, custom `hostname`, overridden entrypoint or `container_name` is needed. The image entrypoint dispatches commands; Compose `command` supplies its arguments. The `tools` profile excludes this service from an ordinary `compose up`; use explicit one-off runs. There is no artificial service healthcheck for a finite administrative command. The 75-second stop grace is an example for default completion timeouts; increase it for longer hooks and required cleanup.

```bash
# Validate structure without starting or deploying anything.
sudo docker compose --profile tools config --quiet
sudo docker compose --profile tools pull laraship

# Preview, then run once. Arguments replace the service's default --help.
sudo docker compose --profile tools run --rm laraship deploy \
  --dry-run --config /opt/laraship-input/shop.conf
sudo docker compose --profile tools run --rm laraship deploy \
  --config /opt/laraship-input/shop.conf

# Existing-project operations use the same one-off service.
sudo docker compose --profile tools run --rm laraship list
sudo docker compose --profile tools run --rm laraship backup --slug shop now
sudo docker compose --profile tools run --rm laraship update --slug shop
sudo docker compose --profile tools run --rm laraship deactivate --slug shop
sudo docker compose --profile tools run --rm laraship activate --slug shop
```

`update` applies only if `shop.conf` originally deployed a Git app. For hooks, add the completion flags to the one-off `deploy` command, referencing files in the mounted input directory. For CI without a TTY, `docker compose ... run --rm -T laraship ...` disables TTY allocation; preserve stdin for interactive confirmation if required. Avoid `docker compose up laraship` as an installation scheduler, and do not use `restart: always`: retries can rerun administrative operations against existing state.

This administrative Compose runner deliberately uses root, host networking and a host socket to manage an existing server. It is not a Kubernetes application Pod template. For Kubernetes, use the separate socket-free adapter and non-root application image below; do not transfer the host-administration mounts/permissions into a workload.

## Kubernetes adapter and every argument

Native: `bash /opt/laraship/kubernetes.sh render|deploy OPTIONS`. Docker: `shellharbor/laraship:1.3.2 kubernetes render|deploy OPTIONS`. The CLI image itself is not the application image passed to `--image`; build the existing Laravel app with the [application-image template](../kubernetes/application/Dockerfile) and follow the [Kubernetes guide](KUBERNETES.md).

| Argument | Default | Contract |
|---|---|---|
| Positional `render` | Mode required | Print a Kubernetes JSON `List`, accepted by Kubernetes as a manifest. No cluster contact or Docker socket needed. |
| Positional `deploy` | Mode required | Validate existing configuration, acquire Lease, create/wait for migration Job, then apply/wait for workloads. |
| `-h`, `--help` | — | Adapter help. |
| `--name NAME` | **Required** | Application/resource name. |
| `--namespace NAME` | **Required** | Existing namespace for deployment; not created by adapter. |
| `--configmap NAME` | **Required** | Existing versioned immutable ConfigMap name. |
| `--secret NAME` | **Required** | Existing versioned immutable Secret name containing `APP_KEY` and credentials. |
| `--revision NAME` | **Required** | Release identity; changes the migration Job identity together with image/runtime contract. Use a new revision for a release or explicit retry. |
| `--image IMAGE` | **Required** | **Application** image with explicit tag or lowercase SHA-256 digest. `latest`/an untagged image is refused. This validator is different from Python CLI's administrative `--image`. |
| `--context CONTEXT` | Required for `deploy` | Explicit kubectl cluster context; do not rely on implicit active context. `render` accepts but does not use it to contact a cluster. |
| `--replicas N` | `2` | Integer 1–100 web replicas. Multiple replicas require external shared state. |
| `--worker` | Off | Enable separate queue-worker Deployment. Without it desired worker replicas are zero, so deployment also stops an old worker. |
| `--image-pull-secret NAME` | Unset | Existing registry Secret, applied to generated Pod specs. |
| `--readiness-path PATH` | `/up` | Application HTTP readiness path. Must match `/[A-Za-z0-9/_-]*`; no query, dots or hostname. Liveness is a separate internal endpoint. |

All names validated through the DNS-label helper (`name`, `namespace`, `configmap`, `secret`, `revision`, `image-pull-secret`) must be 1–40 lowercase letters/digits/hyphens, starting/ending alphanumeric. This differs from Compose slug validation. Context is a kubeconfig identifier, not subject to that label regex.

Deployment requires an external PostgreSQL/MySQL endpoint in ConfigMap (`DB_CONNECTION=pgsql|mysql`, `DB_HOST`), credentials in Secret and immutable ConfigMap/Secret objects. With more than one replica, explicitly configure shared `SESSION_DRIVER`, `CACHE_STORE`, `FILESYSTEM_DISK` rather than file/local/public/array drivers; do not override those via Secret. The adapter does not provision databases, Redis, ingress, DNS, TLS, storage buckets or credentials. Configure those separately. Rendering alone does not verify cluster configuration.

Generated resources are a migration Job, web Deployment, ClusterIP Service and worker Deployment (zero replicas when disabled). Application runtime: HTTP 8080, UID/GID 1000, production/debug-off, read-only root with writable temporary/storage/cache paths, bounded probes and graceful shutdown. Persistent/shared state belongs in external services, not Pod `emptyDir`. Migrations must remain compatible with old replicas during rollout; no automatic schema rollback or exactly-once Job guarantee. Failed/unconfirmed migration/rollout can retain a deployment Lease for explicit recovery.

```bash
docker run --rm --init --user "$(id -u):$(id -g)" \
  --network none --read-only --tmpfs /tmp \
  shellharbor/laraship:1.3.2 kubernetes render \
  --name shop --namespace shop --image registry.example.com/shop:1.0 \
  --configmap shop-config-v1 --secret shop-secret-v1 --revision release-1 \
  --replicas 2 --worker
```

For deployment, allow network access and supply a self-contained kubeconfig with embedded certificates, read-only. The target namespace, versioned config objects, external services and application image must already exist:

```bash
docker run --rm --init --user "$(id -u):$(id -g)" \
  --read-only --tmpfs /tmp \
  --mount type=bind,src="$PWD/kubeconfig",dst=/config/kubeconfig,readonly \
  -e KUBECONFIG=/config/kubeconfig \
  shellharbor/laraship:1.3.2 kubernetes deploy --context YOUR_CONTEXT \
  --name shop --namespace shop --image registry.example.com/shop:1.0 \
  --configmap shop-config-v1 --secret shop-secret-v1 --revision release-1 \
  --replicas 2 --worker
```

The Kubernetes runner needs neither root nor `/var/www`/locks/archives/Docker socket binds. Kubeconfig exec-auth plugins or certificates referenced through external files require deliberate additional provisioning; the stock image cannot supply arbitrary host plugins. Completion/legacy API flags from Compose deployment are not available in this adapter.

## Configurator implementation checklist

1. Select target release and operation first. Separate native Compose, Docker Compose runner, Python native/Docker adapter and Kubernetes application deployment in the UI.
2. Store structured argument arrays, not interpolated shell fragments. Apply Bash quoting only when rendering a command; use correct quoting for another shell if that output mode is added. Never execute untrusted user strings on the website/server merely to generate commands.
3. Classify inputs as required, conditional, optional/generated, secret, or advanced compatibility. Do not emit defaults that introduce incompatibilities: particularly an explicit Laravel version with `--repo`.
4. Expand presets/dependencies before validation. Keep aliases equivalent, deduplicate modules and detect queue/Horizon conflicts regardless of how enabled.
5. Keep blank/generated distinct from an explicit value; enforce frontend name/port rules but leave resource/DNS/authentication checks to deployment. Render optional settings only when applicable.
6. Provide separate previews for command/config output and an actual toolkit `--dry-run`. Put informational flags first after Python's `--` for isolated Docker inspection.
7. Offer secrets through a downloadable protected-config-file workflow or user-created local private files. Do not embed real credentials into examples, Compose environment files tracked in Git, endpoint URLs or image layers. Remind operators that generated credentials can appear in deployment logs.
8. Explain execution prerequisites next to the generated command: root/server, existing Docker for container mode, host directories/mounts, SSH/key visibility, trusted hook/token ownership, DNS/TLS and external Kubernetes state.
9. Show backup ZIP and scheduled DB dumps separately; show legacy PUT and final POST/script separately. Secrets in completion are an explicit opt-in; legacy PUT already includes them.
10. Keep administrative CLI image selection separate from application-image selection. Never generate a privileged/socket-mounted application Pod from the Compose runner example.
11. Expose supported lifecycle operations with their own forms/argument lists rather than reusing deployment options. Removal and restore require clear data-replacement/deletion context and their actual confirmation interface.
12. Recheck this catalog against source parsers whenever the target toolkit version changes. The document does not assert the current website has implemented every option or audited secret handling.

## Source map and verification scope

Primary sources used to build this reference:

- [Deployment parser, config allowlists, validation and main sequence](../deploy-laravel.sh).
- [Release defaults](../versions.env), [presets](../presets/README.md), [module contracts](../modules/README.md) and `modules/*.sh`.
- [Update](../update.sh), [backup](../backup.sh), [activate](../activate.sh), [deactivate](../deactivate.sh), [remove](../remove.sh), [inventory](../list-projects.sh).
- [Python parser/runner](../src/laraship/cli.py), [installer](../src/laraship/install.py), [Python guide](PYTHON.md).
- [CLI image](../Dockerfile), [entrypoint](../docker/entrypoint.sh), [bind/network preflight](../docker-preflight.py), [Docker guide](CONTAINERS.md).
- [Completion delivery](../lib/completion.py), [completion guide](COMPLETION.md), [legacy endpoint serializer](../lib/endpoint.py).
- [Kubernetes parser/resources/deploy](../kubernetes/laraship.py), [Kubernetes guide](KUBERNETES.md).

This is a documentation change. Argument coverage, configuration-key coverage, source constraints, local links, shell-example syntax, rendered Compose configuration and nonmutating CLI/render examples are checked separately from full application deployment. Destructive commands, host-native database provisioning, TLS issuance and cluster deployment are examples with prerequisites, not operations to run as part of reviewing this document. Existing dated E2E evidence does not establish a new production deployment.
