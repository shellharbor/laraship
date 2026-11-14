# ADR-0012: adapt existing standalone shared proxies

Status: Accepted, 1.4.1
Date: 2026-11-14

## Context

A working existing proxy can keep all upstream/server blocks in its main Nginx configuration, use a custom Compose project/image and have no LaraShip sites directory. Rejecting it as incomplete leaves a successfully created application without routing. Replacing its files or rebuilding its runtime can break unrelated production sites.

## Decision

Retain inline Nginx configuration and add the managed-sites include within its explicit HTTP context. Read standalone Compose through Compose's parser with interpolation, env-file resolution, path resolution and normalization disabled; save the edited model as JSON-compatible YAML. Preserve custom fields and original path semantics, adding/removing only the selected project's connections.

Resolve the existing container's Compose owner and image ID. Validate candidates and apply/recover with that runtime without rebuilding it or starting unrelated services. Refuse unrepresented runtime networks/aliases, incompatible modes/mounts/override layouts and hostname/resource conflicts before live writes. Keep a private original backup before first conversion and reuse the shared transaction lock, candidate validation and automatic rollback.

Apply and recover the candidate/original file delta rather than overwriting the entire working tree. Retain unrelated runtime updates and newly created files, refuse conflicting edits, and claim a new proxy directory exclusively before writing it.

## Alternatives

- Replace the proxy with LaraShip templates: rejected because custom TLS, routes and runtime settings may be lost.
- Extend positional YAML edits: rejected because valid custom layouts, anchors and long mount/network forms differ.
- Add a Python YAML dependency: unnecessary because Compose already provides the authoritative parser and accepts JSON as YAML.
- Silently absorb runtime-only topology or consolidate arbitrary overrides: rejected because the intended configuration cannot be inferred safely.

## Consequences

Compose comments/anchor spelling are retained in the original private backup rather than the normalized working file. First network/mount changes can briefly recreate the proxy. The generic adapter remains bounded to an explicit, self-contained main configuration and standalone bridge-network Compose model. Full toolkit updates are required across native/Docker/Python runners. Existing application/database data is retained; an interrupted initial deployment can attach its existing project through the documented source helpers.

See [operations and recovery](../SHARED_PROXY.md), [adapter](../../lib/proxy_config.py), [transaction](../../lib/proxy.sh) and [real legacy tests](../../tests/e2e-proxy-legacy.bats).
