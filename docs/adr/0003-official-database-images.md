# ADR-0003: Official database images and deliberate data migration

- Date: 2026-10-01
- Status: accepted for Unreleased

## Context

The user requested Docker Official Images instead of Elestio PostgreSQL/MySQL and explicitly selected MySQL 8.4 LTS for new installations. PostgreSQL stays on major 17. Existing projects have generated Compose/backup files and persistent volumes; changing toolkit defaults does not update these copies.

## Alternatives

- Keep the Elestio images.
- Replace only the image supplier, retaining MySQL 8.0.
- Use official PostgreSQL 17 and MySQL 8.4 for new projects; migrate existing databases separately via logical dumps and empty volumes.

## Decision

Select `postgres:17` and `mysql:8.4` consistently in versions.env, built-in fallbacks, Compose templates and backup defaults. These explicit version-line tags receive upstream updates; digest pinning is outside this change. Let the official PostgreSQL entrypoint initialize the configured database/account, removing the redundant custom password-reset hook. Keep credential encoding and MySQL quote/backslash restrictions: its official initializer still interpolates values into SQL/client configuration. Reject `root` as the MySQL application account before Docker.

MySQL application dumps retain routines/triggers but omit tablespaces and replication GTIDs. No existing project or production database is migrated automatically. Rehearse a logical transfer to an independent empty volume, stop all writers for the final transfer, validate the application, and retain the source volume/configuration/image for rollback. Never mount the source data volume in the replacement image as part of this procedure.

## Consequences

The MySQL default changes from 8.0 to 8.4 and belongs in the major-release upgrade notes; VERSION and historical releases remain unchanged until a release is confirmed. Customized applications need compatibility checks for authentication, extensions, SQL objects and server configuration. Additional roles/grants, events and instance-level settings are outside the application dump. After reopening writes on the target, rollback requires reconciling new writes. PostgreSQL 18+ changes the data layout/mount and needs a separate plan.

## Verification

[Deployment E2E](../../tests/e2e.bats) checks actual Laravel/PDO, backups/restores and volume persistence. [Migration E2E](../../tests/e2e-db-migration.bats) checks Elestio PostgreSQL 17 / MySQL 8.0 → selected official images with Unicode rows, views/routines, credentials, separate volumes and untouched rollback data. [Install matrix](../../tests/install-matrix.bats) covers PostgreSQL initialization with SQL-looking passwords and quoted identifiers. Run only in the disposable sandbox; verified results belong in PROJECT_CONTEXT.md.

Sources: [official image manifests](https://github.com/docker-library/official-images/tree/master/library), [PostgreSQL image](https://github.com/docker-library/docs/blob/master/postgres/README.md), [MySQL entrypoint](https://github.com/docker-library/mysql/blob/master/8.4/docker-entrypoint.sh), [MySQL upgrade checks](https://dev.mysql.com/doc/refman/8.4/en/upgrade-prerequisites.html), [mysqldump](https://dev.mysql.com/doc/refman/8.4/en/mysqldump.html).
