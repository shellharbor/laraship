# ADR-0009: Final deployment reports and completion callbacks

- Date: 2026-10-22
- Status: accepted, unreleased

## Context and alternatives

The user requested a script/API callback for successful and unsuccessful deployment, initially limited to deployment. Existing --post-deploy commands run inside the application container, while --endpoint sends a legacy PUT payload before ZIP creation and is skipped by early failures. Moving either would change an existing contract. A Python-only wrapper would miss direct Bash/Docker use and could duplicate notifications.

## Decision

Add explicit completion options to the Bash deployment engine. Arm an owner-process EXIT handler after full argument/config validation and before operational preflight. Track top-level stages and completed readiness checks. Release the project lock after operational cleanup and before callback delivery. Preserve original exit codes and guarded rollback/cancellation behavior. Subshell exits cannot finalize the owner's event. HUP/INT/TERM are reported; help/dry run/validation failures and SIGKILL/power loss are outside the notification contract.

Pass an allowlisted NUL-separated snapshot over stdin to a dependency-free helper. Build one versioned report/run ID for both targets. Omit password fields by default and require explicit opt-in for known application credentials; always exclude root DB credentials, API tokens, SSH keys, .env files and raw failure commands/logs. Unknown or unverified values remain distinguishable from completed HTTP/proxy checks.

Execute a trusted absolute executable with JSON on stdin, bounded runtime and discarded output. Require trusted ownership, parents and permissions for scripts/private token files. POST JSON over HTTPS using the existing URL validation policy and optional private Bearer token file. Disable redirects/curl configuration/globbing, bound transport time and suppress raw diagnostics/response bodies. Use an Idempotency-Key and one attempt per target; do not create a credential retry spool. A failure in one target does not skip the other or alter deployment status.

Keep hooks in the administrative CLI's existing privilege/container contract. A Docker hook runs inside that CLI container; it is not a new service, host process or Kubernetes workload. The Python adapter forwards options once and makes explicit read-only input mounts available during Docker inspection so validation can read hook/token files without writable server-state mounts.

## Consequences and verification

Notification is best effort, not durable exactly-once delivery. Receivers deduplicate run IDs; generated credentials in a failed report do not prove provisioning. Local hooks are trusted root-capable code; the timeout is not a sandbox. Existing toolkits/images require deliberate updates. Legacy endpoint and post-deploy contracts remain intact.

Tests exercise real shell success/failure/deferred errors, lock release, subshells, direct/guarded signals, local timeout, HTTPS/token/privacy, HTTP opt-in, redirects and endpoint timeout. The same suite can target the actual packaged Docker engine through LARASHIP_COMPLETION_TEST_ROOT. See [completion guide](../COMPLETION.md), [helper](../../lib/completion.py) and [tests](../../tests/test_completion.py).
