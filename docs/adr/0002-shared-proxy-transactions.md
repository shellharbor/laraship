# ADR-0002: Validate and recover shared proxy changes

- Date: 2026-10-01
- Status: accepted for Unreleased

## Context

One nginxproxy serves several projects. Editing live files before validation or deleting an upstream before detaching its route can break unrelated sites. Failed operations must preserve data and recovery evidence.

## Alternatives

- Edit live files and rely on manual recovery.
- Replace deployment with release directories and symlink switching.
- Retain the layout while staging proxy changes under persistent locks.

## Decision

Keep the current layout. Lock each project, then the shared proxy. Snapshot after locking, edit a private candidate, reject symlinks, validate Compose/Nginx with candidate networks/certificate volumes, then apply and verify. Preserve bind directory inodes and restore the exact prior tree/state on failure. Retain snapshots if rollback fails. Complete routing changes before deleting project data. Forward cancellation, stop owned utility containers, wait for recovery, and ignore repeated signals during recovery.

Backup workers serialize dumps/restores with flock, keep raw SQL/credentials private, and publish completed mode-600 dumps without replacing files.

## Consequences

Network changes may briefly recreate the proxy. Locks coordinate updated LaraShip scripts; manual edits and older sibling kits require separate scheduling. A failed rollback needs operator recovery from the retained snapshot. Existing generated files require deliberate migration. Migrations are never automatically reverted.

## Verification

[Hardening](../../tests/hardening.bats), [two-site proxy E2E](../../tests/e2e-proxy.bats), [Git update E2E](../../tests/e2e-repo.bats) and [modules/backups](../../tests/e2e-modules.bats) run in the disposable sandbox. Verified results belong in PROJECT_CONTEXT.md.
