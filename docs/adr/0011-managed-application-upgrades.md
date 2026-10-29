# ADR-0011: staged managed application upgrades

Status: Accepted, introduced in v1.4.0
Date: 2026-10-28

## Context

Git updates install committed dependencies. Laravel/PHP/Filament upgrades also require application/plugin migration and database recovery review. Native, Docker and Python interfaces must share one engine and locks.

## Decision

Add a separate Bash entry point backed by standard-library Python policy/runtime modules; preserve `update.sh`. Bound the first version to reviewed Compose Laravel 12/13, PHP 8.2/8.3 and Filament 4/5 paths, existing security floors and support end dates.

Separate inspection, private preparation/tests, exact-candidate application and journaled recovery. Build vetted PHP images; test under non-root, resource-bounded containers with synthetic settings; preserve live runtime data. Apply requires maintenance and a validated private dump before changing code. Share immutable image IDs across PHP roles and retain a patched baseline for recovery.

Git requires the tested patch committed upstream and the exact fast-forward branch head. Once migrations may have run, recover code while retaining maintenance until explicit database verification. Never automatically overwrite a database. Read-only Docker planning uses read-only project bindings; apply uses the existing administrative runner. Kubernetes rollout architecture remains separate.

Compare effective cached/fresh database and encryption configuration before preparation and backup. Clear generated bootstrap caches before booting switched or recovered code, since cached providers may belong to removed development packages. Disable retained logs for temporary commands; distinguish their owner/role labels from application image provenance so interrupted-command cleanup cannot select live roles.

## Alternatives

- Production `composer update`: rejected because partial dependency/code changes are unreviewable and can break Git deployment state.
- Merge into `update.sh`: rejected to preserve its committed-upstream contract.
- Automatic dump restoration on any error: rejected because post-backup writes may be destroyed and schema compatibility is unknown.
- Release directories/symlinks: deferred; converting existing bind mounts/persistent state is a separate migration.

## Consequences

Extra build resources, registry access and application tests are required. Major application/plugin changes remain reviewable work. Live/toolkit changes invalidate saved plans. Keep private workspaces/images through acceptance; review database state before resuming recovery. Custom layouts are refused until explicitly supported. Old published packages/images remain unchanged.

See [operations](../UPGRADE.md), [policy](../../lib/upgrade-policy.json), [unit regressions](../../tests/test_upgrade.py) and [real Docker E2E](../../tests/upgrade-e2e.py).
