# Managed Laravel upgrades

`upgrade.sh` plans, prepares, applies and recovers a reviewed application upgrade. Existing `update.sh` still pulls the deployment branch and installs committed dependencies. Use `upgrade` when changing Laravel, compatible PHP or Filament requirements.

**Available in 1.4.0:** use matching toolkit, Python adapter or `shellharbor/laraship:1.4.0`. Earlier releases predate this command. A new Python adapter alone does not replace an old native toolkit or image. Keep the same toolkit revision throughout an operation.

## Supported matrix

- Root on the target Linux server, Python 3.10+, local Docker Engine/Compose v2, standard LaraShip project under `/var/www/<slug>/public_html`. The CLI image includes the required Python runtime.
- Laravel 12/13 sources: compatible updates or 12 to 13. Default target: latest reviewed supported branch, currently 13. Stable `X.Y` selects compatible releases from that branch; `X.Y.Z` selects exactly that release. No downgrades or targets below the configured minimum, currently 12.
- PHP templates 8.2/8.3: keep a compatible branch at its pinned security patch; Laravel 13 moves PHP 8.2 to 8.3. Current pins: 8.2.35/8.3.36. Prepared images and Laravel locks pass the [mandatory security policy](SECURITY_POLICY.md). A newer installed PHP patch is never downgraded to an older bundled pin. Custom/other branches need separate review.
- Existing Filament 4/5 targets compatible stable Filament 5 and Livewire 4. Filament 4 uses its official upgrade tool in private staging. Third-party plugin constraints stay unchanged: conflicts stop preparation for manual review. Filament is not added when absent. Earlier major migrations are unsupported.
- PostgreSQL/MySQL in the project's `db` service. Native databases require an existing correctly configured LaraShip backup module matching the effective application database settings. No database engine/server upgrade occurs.
- Standard PHP build contexts/application mounts, file-based maintenance, installed Laravel matching `composer.lock`, and an application test suite. Custom build scripts/Dockerfiles, nested app mounts, Composer platform overrides/path repositories/advisory exceptions and custom Compose overrides are refused.
- Git deployments require clean tracked files, deployment metadata, and an exact tested fast-forward commit on the configured upstream branch. No tracked production environment files, uploads, dependencies, generated assets or submodules.

Frontend builds and generated Filament CSS/JavaScript/fonts are prepared separately from Git source, switched with dependencies and retained for recovery. Tracking these generated directories in Git is refused. Component-only Filament applications without `filament/filament` need a separate reviewed migration.

The [reviewed policy](../lib/upgrade-policy.json) includes support end dates. "Latest" never selects an unreviewed future major; Composer resolves compatible stable patches during preparation. Dependency installation cannot prove application compatibility. Review the [Laravel 13 guide](https://laravel.com/framework/docs/13.x/upgrade) and [Filament 5 guide](https://filamentphp.com/docs/5.x/upgrade-guide); major upgrades can require code/plugin changes.

## Plan, prepare, review, apply

```bash
# Inspection only: no image pulls/builds, plan writes or maintenance.
sudo bash /opt/laraship/upgrade.sh --slug shop
sudo bash /opt/laraship/upgrade.sh --slug shop --laravel-version 12.0 --json

# Live application stays available while a private candidate is prepared/tested.
sudo bash /opt/laraship/upgrade.sh --slug shop --prepare --laravel-version 13.0
```

Use the actual saved path printed by preparation:

```bash
PLAN=/var/www/shop/.laraship-upgrades/REPLACE_WITH_PRINTED_ID/plan.json
sudo less "${PLAN%/plan.json}/application.patch"
# Edit only the private candidate when application changes are needed; then retest.
sudo bash /opt/laraship/upgrade.sh --slug shop --verify "$PLAN"

# Applications originally created by LaraShip:
sudo bash /opt/laraship/upgrade.sh --slug shop --apply "$PLAN"

# Git applications: apply the patch in a clean development checkout, review/test,
# commit and push first; then supply that exact upstream branch-head commit.
git apply --index /secure/path/application.patch
git commit -m 'Upgrade Laravel and compatible Filament dependencies'
git push origin main
sudo bash /opt/laraship/upgrade.sh --slug shop --apply "$PLAN" --commit FULL_COMMIT_SHA
```

Git source trees must match the tested candidate exactly. The live checkout never gains silently uncommitted upgrade changes. Untracked generated locks are retained for recovery. Normal `update.sh` can continue using the upstream repository afterward.

Preparation excludes `.git`, `.env*`, Composer/npm credentials, conventional private-key files, dependencies, uploads, caches and generated assets. Vetted PHP images run dependency resolution, official transformations and tests as UID 1000 in resource-bounded containers with read-only root filesystems. Resolution initially disables install/scripts/plugins; candidate application scripts/tests use synthetic testing settings, in-memory SQLite and no network. Dependency downloads require network. No production environment, Docker socket or live database is mounted in candidate containers. Review source for credentials in unconventional files before executing third-party build code.

If `package.json` declares `build`, preparation respects/generates `package-lock.json`, installs with npm lifecycle scripts disabled and builds using a version/digest-pinned Node image. Existing public `VITE_*`, `APP_NAME`, `APP_URL` and `ASSET_URL` values are used for assets; never put credentials in public build variables. Projects needing npm lifecycle scripts require an explicit custom build workflow. Reviewed PHPUnit/Pest requirements are adjusted for Laravel 13.

Default tests: `php artisan test --stop-on-failure`. `--test-command 'php vendor/bin/phpunit'` selects another argv without shell expansion. A `tests/` directory and passing suite are mandatory; provide suitable isolated tests for applications that normally depend on external services. There is no verification bypass.

Apply rechecks live source/config/dependencies/assets and the sealed candidate, obtains the existing shared project lock, enters maintenance, stops PHP/workers, and validates a private logical database dump **before code replacement**. It preserves environment files, application key, storage/uploads and DB volumes; uses the prepared PHP image for every PHP role; runs migrations; reloads Nginx; checks HTTP via a signed maintenance cookie; then resumes application/workers. The bypass secret never appears in request URLs or ordinary access-log paths. Default readiness path `/up` checks application boot; Laravel normally exempts it from maintenance. A custom path should exercise database/application dependencies for stronger readiness.

Preparation and backup compare cached and fresh database/encryption configuration. Resolve stale configuration before proceeding: otherwise a dump could target another database or clearing a cache could change the effective application key. Apply and code recovery remove generated bootstrap caches before starting Artisan, including caches that reference removed development packages.

Temporary command containers disable Docker log retention while preserving attached output for the private runner. Interrupted-command cleanup requires both the operation owner and command-role labels; application images use a separate provenance label so running PHP/workers cannot be mistaken for temporary commands.

Use a maintenance window and stop external writers/deploy automation first: the local project lock cannot stop other servers/database clients. Restore-test logical backups under your application procedures. MySQL snapshot consistency requires transactional tables.

Runtime state must use the conventional environment files, `storage/` and `public/storage`; custom writable source/public directories need a separately reviewed migration. A changed Git remote/configuration or branch pointer invalidates the plan. Compose project/profile/environment overrides are refused, and the running PHP bind mount must match this project's files. Apply resumes only PHP/workers that were running before maintenance. A fresh database connection check precedes HTTP readiness and resumption.

## Recovery and artifacts

Private workspace: `/var/www/<slug>/.laraship-upgrades/<id>/`. It contains the plan/journal, candidate, patch, immutable runtime IDs, previous code/dependencies/build context, maintenance token and DB dump. Directories use mode 700; plans/patches/tokens/dumps use 600. Do not publish/commit this directory; application source and dumps can be sensitive even though errors omit credentials.

- Failed preparation leaves the live application unchanged. Adjust the candidate and `--verify`; changed live source/config requires new preparation.
- Failure before migrations restores previous code on a patched safe PHP image and resumes only after HTTP readiness succeeds.
- Once migrations may have started, recovery restores code, retains maintenance/workers stopped, and records `needs_database_review`. It never automatically overwrites/restores the database.
- Completed plans can restore previous code subject to source/ownership checks. Schema compatibility still needs explicit review before resuming.
- Catchable interruption uses recovery. After a host crash/forced kill, inspect the journal and recover explicitly. Lock-file inodes remain; kernel locks are released with the process.

```bash
sudo bash /opt/laraship/upgrade.sh --slug shop --recover "$PLAN"
# Inspect/restore the private dump separately if necessary, then verify schema/data.
sudo bash /opt/laraship/upgrade.sh --slug shop --recover "$PLAN" --database-verified
```

`--database-verified` asserts operator verification/restoration; it is not a restore command. PHP remains patched during code recovery. Keep the plan, previous files and both image IDs through acceptance; avoid image pruning meanwhile. `activate.sh` retains managed image IDs with `--no-build --pull never`; do not run `docker compose up --build` against an image-ID override. Stale plans cannot overwrite later managed upgrades; toolkit changes also invalidate saved plans. Automatic retention/pruning is not implemented: remove only a confirmed obsolete workspace during planned maintenance.

## Every argument

| Argument | Meaning |
| --- | --- |
| `--slug SLUG` | Required existing project; 1–63 letters/digits/underscores/hyphens, starting with letter/digit; `nginxproxy` reserved. |
| `--laravel-version X.Y[.Z]` | Planning/preparation target; default latest reviewed branch. Cannot modify a saved plan's target. |
| `--dry-run` | Read-only plan; also the default when no mode is selected. |
| `--json` | Planning JSON, without credential values. |
| `--prepare` | Create/build/test a private candidate. |
| `--verify /absolute/plan.json` | Resolve/build/test a manually adjusted candidate again. |
| `--apply /absolute/plan.json` | Apply an unchanged prepared candidate after backup. |
| `--commit FULL_SHA` | Required for Git apply: reviewed upstream deployment branch head. |
| `--recover /absolute/plan.json` | Restore code and patched PHP; database recovery is separate. |
| `--database-verified` | Recovery only: allow resuming after database compatibility/restoration review. |
| `--test-command 'ARGV'` | Preparation/verification tests; no shell expansion. |
| `--health-path /path` | Readiness path saved at preparation, default `/up`, no query/fragment. |
| `--help`, `-h`, `--version` | No daemon/root/server mounts required. |

Modes are mutually exclusive. Exit codes: 0 success, 1 operation/validation failure, 2 argument syntax, 130 cancellation outside a bounded child operation. Child timeout/cancellation is an operation failure with recovery as needed. Recovery that safely retains maintenance reports this explicitly and exits 0; it does not claim availability.

## Python and Docker

Install `laraship==1.4.0` with pip/pipx; native `--directory` must select the matching toolkit on the server:

```bash
sudo /absolute/path/to/laraship upgrade --directory /opt/laraship -- --slug shop --json
sudo /absolute/path/to/laraship upgrade --directory /opt/laraship -- --slug shop --prepare
sudo /absolute/path/to/laraship upgrade --directory /opt/laraship -- --slug shop --apply "$PLAN"
```

Pull the administrative CLI image (or build the reviewed 1.4.0 checkout locally):

```bash
docker pull shellharbor/laraship:1.4.0
# Source-build alternative: docker build -t shellharbor/laraship:1.4.0 .
# Read-only plan needs no writable project, lock or archive mounts.
docker run --rm --network host --read-only --tmpfs /tmp \
  --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock,readonly \
  --mount type=bind,src=/var/www,dst=/var/www,readonly \
  shellharbor/laraship:1.4.0 upgrade --slug shop --json

# Preparation/apply/recovery use standard administrative mounts.
docker run --rm -i --network host \
  --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
  --mount type=bind,src=/var/www,dst=/var/www \
  --mount type=bind,src=/run/lock/laraship,dst=/run/lock/laraship \
  --mount type=bind,src=/var/backups/laraship,dst=/var/backups/laraship \
  shellharbor/laraship:1.4.0 upgrade --slug shop --prepare

sudo /absolute/path/to/laraship upgrade --backend docker --image shellharbor/laraship:1.4.0 -- --slug shop --json
```

Create writable lock/archive directories as in [CONTAINERS.md](CONTAINERS.md) before mutating operations. A read-only socket mount does not restrict the Docker API: trust this administrative image. The engine's plan uses inspection only. This workflow targets Compose; Kubernetes retains its separate immutable-image/migration/rollout process. Shared PHP images remain portable, non-root and externally configured.
