# PHP and Laravel security policy

LaraShip rejects runtimes below the following branch-specific PHP security floors:

| Reviewed PHP branch | Minimum stable patch |
| --- | --- |
| 8.2 | 8.2.35 |
| 8.3 | 8.3.36 |
| 8.4 | 8.4.27 |
| 8.5 | 8.5.12 |

PHP 8.1 and older are forbidden, even if a vendor supplies a backport. Earlier patches, prereleases, malformed versions and unreviewed branches fail closed. New branches require an explicit policy review. The [PHP release announcements](https://www.php.net/index.php) identify these patches as fixes for CVE-2026-109618 and CVE-2026-109619. This policy does not assert that the listed patches address every future vulnerability; keep current security releases under review.

Laravel below 10 is forbidden. LaraShip already requires Laravel 12 or newer because 10/11 have retired security support; that stronger minimum remains in force. `LARAVEL_MIN_VERSION` in `versions.env` may raise the fresh-install minimum and cannot lower it below 12.0. Locked repository/Kubernetes dependencies must also contain a stable production `laravel/framework` package at least 12.0.0. Do not disable Composer security blocking or ignore PHP platform requirements.

## Enforcement

- The default Compose build uses digest-pinned PHP 8.3.36-FPM; the manual compatible alternative is 8.2.35-FPM. Builds validate their actual PHP binary before extension compilation and in the final runtime.
- Native Bash and Docker CLI deployment share the same engine. Python native/Docker backends delegate to it. Before installing an application, the engine runs the policy in the actual Compose PHP image. Repository lock files are checked before dependency installation. When a repository has no lock, Composer first resolves one with `--no-install --no-scripts --no-plugins`; the policy checks that lock before packages or installation scripts may run, even if the repository disables Composer advisory blocking. Resulting locks are checked after installation and module installation, before configuration/readiness or final post-deploy commands. LaraShip itself never disables Composer advisory blocking.
- `update.sh` checks the PHP runtime before maintenance or code changes. After switching code and fixing ownership, it resolves a missing lock without installation/scripts/plugins, checks the lock before Composer installation and verifies the result afterward. Existing update failure/recovery behavior applies if a dependency check fails.
- The Kubernetes application Dockerfile validates its patched PHP and the committed lock before Composer installation. Every rendered migration Job and web/worker Deployment checks its own image in a non-root init container with a read-only filesystem, restricted capabilities and bounded resources. Custom images need PHP CLI on `PATH` and `/app/composer.lock`. The init container bypasses the application's ordinary entrypoint and runs before any migration or application process.
- PHP 8.4/8.5 floors permit reviewed custom runtimes; they do not introduce automatic PHP selection or bundled 8.4/8.5 Dockerfiles. The existing default Laravel 13 requires PHP 8.3 or newer; Composer still validates application compatibility.

The canonical implementation is [security-policy.php](../laravel/.docker/php/security-policy.php). The standalone Kubernetes Dockerfile embeds an identical copy because its build context is the application's directory. Automated tests enforce synchronization. Synthetic old version strings test rejection; they do not require running retired PHP images.

## Existing installations

Updating the LaraShip Python adapter or administrative Docker image alone does not replace application PHP images, a downloaded native toolkit directory, or existing generated project copies.

1. Update the native toolkit checkout or install a fresh toolkit directory and select it with Python `--directory`. For the Docker backend, use image 1.3.3 or newer; release 1.3.3 is the first to include this policy.
2. For a Compose project, review and copy the complete updated `laravel/.docker/php/` directory, including its `.dockerignore`, policy, build scripts and both Dockerfiles, into the project's `.docker/php/` directory. Preserve reviewed application-specific extensions/configuration. Rebuild and recreate all PHP roles with `docker compose up -d --build`; this includes PHP, Artisan, Composer, cron and any queue/Horizon workers. Verify `php -v`, application HTTP readiness and worker/backup behavior before normal use. `update.sh` deliberately refuses an older runtime instead of silently rebuilding or upgrading it.
3. For Kubernetes, rebuild the application with the updated template, publish an immutable image reference, and render/deploy with the updated toolkit. Upgrade its framework/lock first if the policy refuses it. Rollback images must satisfy the same security floors.

This change does not migrate databases, automatically rewrite applications, upgrade already running containers, alter historical releases or publish a new package version by itself.
