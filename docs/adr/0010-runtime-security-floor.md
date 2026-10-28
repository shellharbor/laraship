# ADR-0010: Enforce reviewed PHP patch floors and retain the Laravel security minimum

- Date: 2026-10-28
- Status: accepted, introduced in v1.3.3

## Context

The user requires PHP 8.2.35+, 8.3.36+, 8.4.27+ and 8.5.12+ after CVE-2026-109618/CVE-2026-109619, forbids PHP 8.1 and older, and excludes Laravel below 10. Existing templates use PHP 8.3.35/8.2.34, while LaraShip already refuses retired Laravel 10/11 and defaults to Laravel 13 with a configurable minimum of 12. A documentation-only rule cannot prevent an old existing or custom image from running.

## Options

- Only refresh image tags: leaves existing images, custom Kubernetes images and configurable Laravel downgrades unchecked.
- Change the default PHP branch: introduces unrelated compatibility risk and does not enforce other branches.
- Keep existing branches and add actual runtime/dependency checks, with one shared policy and a synchronized standalone build copy.

## Decision

Use stable, branch-specific PHP floors and fail closed on older patches, unsupported branches and prereleases. Refresh official image digests. Keep the stronger existing Laravel 12 minimum and forbid lowering it in `versions.env`; do not restore retired Laravel 10/11. Check real Compose PHP before deployment/update and resulting Laravel locks. Check committed/generated locks before installing dependencies. Resolve missing locks with `--no-install --no-scripts --no-plugins`, then apply the independent policy before permitting installation/scripts. Retain Composer's advisory/platform protections; an input repository disabling advisory blocking must not bypass this policy. Check the lock again after module installation.

For Kubernetes, guard every workload with an init container using the actual application image and enforce policy at template build time. Keep the canonical policy in the PHP build context and embed an identical copy in the standalone Dockerfile, whose application-only context cannot import repository files. Test exact synchronization. Generate test fixture dependencies using Composer's pinned binary on patched PHP.

## Consequences

Older application images must be deliberately rebuilt before updates. Native toolkit/Python adapter/administrative image upgrades do not rewrite application runtimes. Custom Kubernetes images need PHP CLI and `/app/composer.lock`. The init container adds a short startup check, bounded resources and no new service or privilege. PHP 8.4/8.5 are policy branches, not new bundled templates. Historical releases remain immutable.

## Verification

Boundary and lockfile checks run inside the patched PHP smoke images. Unit tests enforce pins, standalone policy synchronization, custom Kubernetes guards, minimum-version downgrade rejection and refusal before update maintenance. Existing PHP smoke, Compose E2E and Kubernetes E2E retain their respective roles. Record actual local/remote execution and limitations in the dated project context; do not infer passing cluster deployment from rendering alone.
