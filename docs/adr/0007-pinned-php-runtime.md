# ADR-0007: Pin PHP build inputs and separate compilation from runtime

- Date: 2026-10-14
- Status: accepted, targeted for v1.2.0

The original PHP patch pins below are historical. [ADR-0010](0010-runtime-security-floor.md) supersedes them with mandatory patched versions and actual runtime/dependency checks.

## Context

Compose PHP templates used floating PHP/Composer images and unversioned PECL installs. Compilation tools, development headers, editors, debuggers and optional mail/media/antivirus packages remained in the application image. Cleanup in a later layer could not remove bytes from earlier layers. The same image serves FPM and separate Composer/Artisan/cron/worker commands.

## Alternatives

- Pin versions but retain all packages and layers: stabilizes inputs without reducing runtime contents.
- Compile and purge in the official PHP image: cannot remove compiler/header bytes already present in the pinned upstream image layers.
- Compile against official PHP Bookworm and copy its runtime artifacts into a clean Bookworm image: reduces contents while preserving the distro ABI and verified PHP extensions.
- Switch to Alpine or a new PHP minor: changes libc/package/runtime compatibility beyond this optimization.

## Decision

Use exact PHP 8.3.35 and 8.2.34 FPM versions and Composer 2.10.3 with multi-architecture image-index digests. Keep PECL Redis 6.3.0/APCu 5.1.28 and their SHA-256 archive checks in one shared builder script. Derive runtime Debian packages from the actual PHP/FPM/extension ELF dependencies and install them into digest-pinned Debian Bookworm. Copy only runtime binaries, extensions, configuration, the official exec entrypoint and Composer; retain Git/SSH, curl/OpenSSL, ZIP/unzip and a small FastCGI client. Do not ship compilers, PHP headers, PECL or optional administration/media/mail services.

Preserve UID/GID 1000, external application/configuration/state and production PHP ini. Explicitly retain the official FPM `SIGQUIT` stop contract, with a 10-second process-control timeout and 15-second Compose stop grace: the inherited zero timeout aborted the tested active request before it completed. Add a bounded local FastCGI ping helper and enable it on the Compose FPM service only; attaching image-wide FPM health to Composer or workers would incorrectly mark those roles unhealthy. Keep authenticated DB/application HTTP readiness checks. The Kubernetes application backend and its standalone Apache image remain separate under ADR-0005.

Remove the unsupported PHP 8.1 template at the user's explicit request. PHP 8.2 is a manual alternative for compatible Laravel 12 applications; Laravel 13 requires PHP 8.3 or newer.

## Consequences and verification

Existing deployments are not rewritten. Operators must copy the entire PHP build directory, including scripts and `.dockerignore`, before rebuilding; custom optional binaries/fonts need explicit image changes or external services. Bookworm repository packages may receive updates, so this is not a complete byte-for-byte build lock. Release application images still need immutable output references and deliberate updates.

The new `tests/php-image-smoke.py` runs actual images with read-only rootfs, dropped capabilities and non-root PHP, verifies pins/required extensions/GD/ZIP, real PostgreSQL/MySQL I/O, Laravel 12/13 installation/migrations and graceful FastCGI request draining. Its resources are private and cleaned by their recorded IDs. CI builds/checks both FPM variants. Record measured sizes and dated validation evidence in PROJECT_CONTEXT.md rather than inferring them from the Dockerfile.

References: [PHP image sources](https://github.com/docker-library/php), [PECL Redis](https://pecl.php.net/package/redis/6.3.0), [PECL APCu](https://pecl.php.net/package/APCu/5.1.28), [Composer release](https://github.com/composer/composer/releases/tag/2.10.3), [Docker build guidance](https://docs.docker.com/build/building/best-practices/).
