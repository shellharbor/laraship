# PostgreSQL 18 verification

Verified on 2026-10-28 against the LaraShip 1.3.0 runtime at source commit `285641c460f85519a76f97dbdcf9a76ade5fb2dd`. Release 1.3.1 publishes these results and documentation; it does not change the database default or deployment implementation.

**Result: 103 checks passed, 10 expected scenario-specific skips and no failed checks across five completed suites.** The default remains `postgres:17`; only disposable test copies selected `POSTGRES_IMAGE=postgres:18`.

## Image and test environment

The official `postgres:18` image reported PostgreSQL 18.6 (`18.6-1.pgdg13+2`), with digest `sha256:979bccfde35445db618c65107d27d08c6c21339d8dc3ad4c830c6633947be0e4`. This identifies the tested image; it is not a new project-wide image pin.

Tests ran as real deployments in disposable Ubuntu/Docker-in-Docker environments with separate daemons, without a host Docker socket or application-directory binds. Following an initial host-storage interruption, only the unfinished suites were rerun with bounded RAM-backed Docker/project storage. The completed first two suites were retained. These results combine successful final runs, not the interrupted setup attempts.

## Coverage

| Scenario | Passed | Expected skips | What was checked |
|---|---:|---:|---|
| Laravel 13, extras and config mode | 34 | 2 | Migrations, HTTP, config precedence, Redis/queue, database recreation, private dumps, restore/retention and project lifecycle. |
| Laravel 12 with Filament | 28 | 8 | Administrator access, migrations, HTTP/security defaults, persistence/authentication and lifecycle. |
| Filament/Horizon/Redis/backup modules | 18 | 0 | Real queued job, production panel authorization, backup/restore, cancellation and lifecycle. |
| Git application and update/recovery | 17 | 0 | Deployment, dependencies, updates/migrations, local-change refusal, failed-migration recovery, cancellation and `--no-migrate`. |
| Legacy PostgreSQL 17 to official PostgreSQL 18 | 6 | 0 | Authentication, rows/Unicode/view/function, private logical transfer, target persistence and an independent retained source. |
| **Total** | **103** | **10** | **No failed final checks.** |

The native backup-client version selector also returned `postgres:18` from a real authenticated server-version query while its configured default was deliberately 17. A test-only TCP relay exposed the fixture's loopback publication to the bridge endpoint. This checks client-major selection, not host-native PostgreSQL installation/provisioning.

## Data directory and migration fixture

The current Compose template explicitly sets `PGDATA=/var/lib/postgresql/data` and mounts its named volume at that path. Under that explicit configuration, PostgreSQL 18 initialized successfully and preserved records/authentication after database recreation. Backup and restore passed with the same layout.

The [official PostgreSQL 18+ image contract](https://github.com/docker-library/docs/blob/master/postgres/README.md#pgdata) instead defaults to a versioned directory (`/var/lib/postgresql/18/docker`) under a volume rooted at `/var/lib/postgresql`. A separate reproduction using the old mount without explicit PGDATA exited with the image's layout guard.

The existing [logical migration fixture](../tests/e2e-db-migration.bats) mounts `/var/lib/postgresql/data` without setting PGDATA. To run its six checks against 18, only the disposable fixture copy changed the official target mount to `/var/lib/postgresql`; the legacy 17 source retained its original mount. The adjustment was:

```bash
local mount_path=/var/lib/postgresql/data
if [ "$image" = postgres:18 ]; then mount_path=/var/lib/postgresql; fi
# In the PostgreSQL docker run invocation:
# -v "$volume:$mount_path"
```

All six migration checks then passed. This fixture-only adjustment is not committed to the test implementation in 1.3.1. Do not treat the unmodified fixture as supporting the 18+ default layout automatically.

## Upgrade and coverage limits

Changing a running PostgreSQL 17 project's image tag to 18 does not upgrade its data files. Use a separate target volume and a planned logical migration, retain the source for recovery and validate the actual schema, extensions, ownership/grants, collation and application records. See [database-image migration guidance](../README.md#moving-an-existing-database-to-the-official-images) and the [official-image decision](adr/0003-official-database-images.md).

Host-native PostgreSQL 18 provisioning, Kubernetes with PostgreSQL 18, ARM and certificate issuance were not covered by this run. A successful fixture transfer is not a blanket migration guarantee for a production database. Existing generated projects/volumes are not changed by upgrading LaraShip.
