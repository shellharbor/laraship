# Modules

A module is an optional feature of `deploy-laravel.sh`, kept in one file: `modules/<name>.sh`. It is loaded only when enabled, so a deployment without `--with` behaves exactly as before.

**Modules ship with the script.** There is no download step: `--with NAME` uses `modules/NAME.sh` from the folder you installed, and a new module reaches you with a new release of the folder. This is deliberate, because a module runs as root and code fetched from the network during a deployment would be code you never reviewed. New modules are added to this repository by pull request (see [Contributing a module](#contributing-a-module)).

```bash
sudo bash deploy-laravel.sh --domain shop.example.com --db-type postgres --ssl-email admin@example.com \
  --with filament,horizon --filament-email admin@example.com

bash deploy-laravel.sh --list-modules          # no root needed
```

`--with` takes a comma-separated list. In a `--config` file the key is `WITH` (`WITH=filament,horizon`).

| Module | What it does | Alias |
|---|---|---|
| `filament` | Filament admin panel at `/admin` (needs `--filament-email`; name and password are generated if not given) | `--install-filament` |
| `redis` | Wires Redis into Laravel: `REDIS_*`, and cache, session and queue on `redis` | `--use-redis` |
| `queue` | A queue worker container (`php artisan queue:work`) | `--queue-worker` |
| `backup` | Scheduled database dumps in `<project>/backups` (at start, then every 24 hours, kept `--backup-keep` days, default 7). `backup.sh` takes a dump on demand, lists dumps and restores one | — |
| `horizon` | Laravel Horizon: a Redis queue supervisor and the `/horizon` dashboard. Enables `redis`; cannot be combined with `queue` or `--repo` | — |

The aliases are the same as `--with <module>` and keep working, in flags and in config files.

## Writing a module

Modules are **sourced into the deploy script** and run as root, like the script itself: treat the `modules/` folder as code you trust. Only files in that folder, named `[a-z][a-z0-9-]*.sh`, can be enabled.

Create `modules/<name>.sh`. In function and variable names `-` becomes `_` (module `my-mod` uses `mod_my_mod_…` and `MOD_MY_MOD_…`).

```bash
# shellcheck shell=bash disable=SC2154,SC2034

MOD_HELLO_DESCRIPTION="One line shown by --list-modules"
MOD_HELLO_REQUIRES=""            # modules enabled automatically before this one, space-separated

mod_hello_validate() { :; }      # while arguments are validated, before anything changes
mod_hello_env()      { :; }      # after Laravel is installed and migrated; $1 = path of Laravel's .env
mod_hello_install()  { :; }      # after Laravel is installed and migrated (composer, artisan, ...)
mod_hello_compose()  { :; }      # print docker compose service definitions to stdout
mod_hello_summary()  { :; }      # print lines for the final summary
```

Everything except `MOD_<NAME>_DESCRIPTION` is optional.

| Hook | When | Typical use |
|---|---|---|
| `mod_<name>_validate` | End of argument parsing, before any change | Check the module's options, reject conflicts (`error "…"`) |
| `mod_<name>_env` | After Laravel is installed and migrated, for all modules, before any `install` hook | Write settings into Laravel's `.env` (`set_env_var "$1" KEY value`) |
| `mod_<name>_install` | After every `env` hook | `composer require`, `artisan …`. Run in the project folder (`cd "${PROJECT_DIR}"`) and go back with `cd "${SCRIPT_DIR}"` |
| `mod_<name>_compose` | After every `install` hook | Print YAML for one or more services, indented by two spaces. `{SLUG}` is replaced. The script inserts it before the top-level `networks:` of the project's `docker-compose.yml` and runs `docker compose up -d` once |
| `mod_<name>_summary` | Final summary | Print a section (end it with `echo ""`) |

Modules run in the order they were enabled, with required modules first.

Why services are added late: a container started before Laravel exists (a worker, Horizon) would restart in a loop until `artisan` appears, so the definitions are inserted only after the application is installed.

### What a module can use

Variables of the script: `SLUG`, `DOMAIN`, `PROJECT_DIR`, `SCRIPT_DIR`, `REDIS_PASSWORD`, `REPO_URL`, `DB_TYPE`, the `FILAMENT_*` options, and so on. Helpers: `info`, `warn`, `error` (exits), `success`, `random_string`, `set_env_var FILE KEY VALUE`, `module_enabled NAME`.

Keep the following in mind:
- Name every function `mod_<name>_…` and every variable `MOD_<NAME>_…` (or `local`), so modules cannot collide. `tests/static.bats` checks this.
- A module's own command-line flags are not supported yet: options live in the script (for example `--filament-email`). Modules should validate them in `mod_<name>_validate`.
- Modules that install Composer packages must refuse `--repo` in `mod_<name>_validate` (the application manages its own dependencies), as `filament` and `horizon` do.
- `update.sh` knows about the `queue` and `horizon` services: it runs `queue:restart` and `horizon:terminate` after an update.

## Contributing a module

Modules are added to this repository by pull request. Start from [TEMPLATE.sh.example](TEMPLATE.sh.example) (copy it to `modules/<name>.sh`) and check the list below before you open the request.

**The module**
- One file, `modules/<name>.sh`; the name is `[a-z][a-z0-9-]*`. The file name, `MOD_<NAME>_DESCRIPTION`, and every function (`mod_<name>_...`) and top-level variable (`MOD_<NAME>_...`) must agree. `tests/static.bats` enforces this, and that `--list-modules` shows the module.
- `MOD_<NAME>_DESCRIPTION` is one line that says what the module does and what it needs.
- Validate options and conflicts in `mod_<name>_validate`, so a bad combination fails before anything changes. A module that installs Composer packages must refuse `--repo`.
- Declare dependencies in `MOD_<NAME>_REQUIRES` instead of failing when another module is missing.
- Put services in `mod_<name>_compose` (added after Laravel installation), not in the base template. Nonzero hooks or invalid YAML abort before replacing Compose. Initial migrations run before install hooks; a module publishing migrations must run its own guarded `artisan migrate --force` afterwards.
- Guard critical operations explicitly (`command || error "..."`). Hooks are called while checking their status, so Bash errexit alone does not stop every intermediate failure; a later successful message must not mask a failed write/install. `set_env_var` handles write failures itself.

**What a module must not do**
- Download or run code from the network: no `curl | sh`, no fetching scripts. `composer require` and `artisan` inside the project's own containers are fine; anything else is discussed in the pull request first.
- Touch files outside `PROJECT_DIR`, change the host (packages, services, firewall) or read other projects.
- Print or store secrets other than in the final summary and the project's own `.env`, as the `filament` module does for the administrator password.

**With the pull request**
- `bash -n modules/<name>.sh` and ShellCheck (`shellcheck -S warning -e SC2155 modules/<name>.sh`) are clean.
- The module is documented: a row in the table of this file and in the README "Modules" table, and an entry under `Unreleased` in `CHANGELOG.md`.
- It has a test. `tests/static.bats` covers the structure for free; a module that installs packages or adds a service needs an end-to-end check like `tests/e2e-modules.bats`. Run `bash tests/run-local.sh` and, for such a module, `bash tests/run-local.sh e2e-modules`.
- `--with <name>` on its own, and with the modules it is likely to be combined with, is checked with `--dry-run`.

Container backup services derive from the selected DB image and add flock when missing. Native PostgreSQL chooses the official client image matching `server_version_num` from the application's authenticated connection; the probe is bounded and failed/invalid detection aborts. For native PostgreSQL 16 this selects `postgres:16` without changing container defaults. Dump/restore scripts share a lock, keep credentials/raw data private, publish completed mode-600 dumps without overwriting, and clean staging on failures. The next locked worker cleans staging orphaned by SIGKILL. Existing generated server copies require explicit migration; see the README's instructions for the native PostgreSQL 16 backup build argument.
