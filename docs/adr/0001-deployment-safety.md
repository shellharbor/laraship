# ADR-0001: Safe deployment defaults and data preservation

- Date: 2026-09-30
- Status: accepted for Unreleased; no release version assigned

## Context

LaraShip deploys as root and shares one nginxproxy across sites. Review of the working copy and isolated regression probes confirmed deletion of an existing project on reinstall, replacement of the proxy directory through its reserved name, code changes before maintenance, unsafe production defaults, a successful exit after initial migration failure, and lost gzip errors during MySQL restore.

## Alternatives

- Keep the existing behavior and rely on warnings and manual hardening.
- Add optional safety flags while retaining unsafe defaults.
- Make safety the default now, document the breaking behavior, and keep existing server configuration changes explicit.

## Decision

The user explicitly authorized all five P1 fixes. Reject existing target paths before Docker/proxy changes and reserve nginxproxy across management commands. Fetch Git updates before maintenance but switch commits only after the old application successfully enters maintenance. Stop installation on migration failure. Validate dumps before service changes and fully decompress MySQL SQL before import. New installations use production mode, disabled debug, loopback-only project ports, private .env files and PHP without Xdebug; generated Filament access permits only the provisioned administrator.

## Consequences

Reinstallation requires saved data and explicit removal; code updates use update.sh where supported. Changed defaults require a major release under the compatibility policy; VERSION and historical release notes stay unchanged. Replacing the toolkit does not rewrite existing templates or backup scripts on a server. MySQL preflight and restore need temporary space for uncompressed SQL. Database migrations are not automatically rolled back.

## Verification

See [safety.bats](../../tests/safety.bats), [E2E deployment](../../tests/e2e.bats), [Git updates](../../tests/e2e-repo.bats) and [modules](../../tests/e2e-modules.bats). Run in the isolated Docker sandbox; no production deployment is needed for these checks. Actual results are recorded in PROJECT_CONTEXT.md.
