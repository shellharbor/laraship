# Changelog

After every task with file changes, briefly record what changed and why: features, fixes, internal work, dependencies, documentation, and AI-KIT. Keep new entries under `Unreleased` until a release is confirmed; use verified dates and versions. Tasks without file changes need no entry.

## Unreleased

### Verification

- Record authorized Docker-cache cleanup after host disk exhaustion: unused build cache and old dangling images removed, owned sandboxes/cache volume cleaned, and original application containers verified healthy; distinguish Docker-reclaimed cache from unchanged Windows VHD file size.

### AI-KIT

- Refresh verified GitHub v1.2.2/Docker Hub publication state and continuity evidence after recovering repository Variables and registry credentials, without changing the released version or tag.
- 2026-10-05: separated the language policy: all authored project files and artifacts remain English, while chat with the user uses Russian for questions, plans, progress, explanations, review summaries, and final reports. Project artifacts shown in chat retain English. Synchronized instructions, bootstrap, context, continuity skill, engineering/router rules, README, wiki, and decision log to preserve this distinction.
- 2026-10-05: replaced the former Terra-based defaults with the user's Adaptive Model Router: Luna for bounded tasks, Sol 6.1 for engineering, and justified Astra escalation. Optimizes total cost to a correct result rather than the price of one call.
- 2026-10-05: added runtime capability verification, independent reasoning/service-tier/context decisions, standard/pro criteria, the large-input pricing boundary, cache/output budgets, conditional reviewers/delegation, diagnosed retries, and compact JSON router decisions. Distinguished policy fields from supported execution controls.
- 2026-10-05: synchronized bootstrap, agent/review rules, context and continuity skill, intent, navigation, and README; recorded the routing decision and consequences in a kit ADR. Runtime availability and switching remain explicitly unverified until project adaptation.
- v0.1: added agent instructions, context, a skill, stack and engineering rules, model routing, and the bootstrap prompt.
- Summarized the available voice context; added thin adapters, the skill registry, and stack skills; recovered the user's Laravel agreements from the earlier AI-Kit task.
- Added a Docker daemon check and a request for the user to start it for container-dependent tasks.
- Added a universal `.gitignore` for PHP/Laravel/Moodle/Go, development artifacts, secrets, and local AI-KIT files.
- Added local Go cache directories and `*.out` files to `.gitignore`.
- Clarified the `composer.lock` policy: versioned by default for applications, with an optional exclusion for libraries.
- Clarified that `go.mod` and `go.sum` remain versioned for Go modules.
- Added Python script rules and a skill; `.gitignore` excludes virtual environments, caches, coverage output, and build artifacts while keeping configuration and lockfiles versioned.
- Made `CHANGELOG.md` updates mandatory after every task with file changes to preserve the history of reasons and results, including internal changes and the kit itself.
- Added a mandatory Kubernetes-ready standard for new Dockerfiles, containers, and microservices: portable images, configuration, security, shutdown, health checks, storage, and minimal manifests. Integrated the rule into instructions, context, the skill, and bootstrap so services are ready for Kubernetes from the start.
- 2026-10-04: translated all AI-KIT documents, adapters, rules, templates, and the bootstrap prompt into English; established English as the language for future kit updates.
- 2026-10-04: extended the English language requirement to all authored project content and agent communication, including code, UI text, logs, Git messages, reviews, and reports, so future project work follows one language policy.

## 1.4.0

LaraShip 1.4.0 adds managed Laravel, PHP and Filament upgrades through the same native Bash, Docker and Python interfaces. Prepare and test changes separately, review the candidate, then apply it after a validated database backup.

### Added

- Add a separate managed `upgrade` command for Compose Laravel 12/13, reviewed PHP 8.2/8.3 and existing Filament 4/5 projects, with a bounded compatibility matrix, read-only plans, isolated candidate preparation/tests and exact-candidate application.
- Require maintenance and a private validated PostgreSQL/MySQL dump before switching application code; preserve runtime data and apply the prepared PHP image across FPM/CLI/workers. Journal recovery retains patched PHP and requires explicit database review after migrations may have started.
- Require a reviewed exact upstream commit for Git applications; expose the same engine through native Bash, Docker and Python, including read-only Docker planning mounts. Preserve existing `update.sh` behavior.
- Keep immutable prepared PHP image IDs during project activation instead of attempting to rebuild them as Docker tags.
- Document all upgrade arguments, preparation/review/recovery procedures and adapter examples; add policy/lifecycle/privacy regressions and real Docker upgrade/data-retention coverage to E2E CI.

### Safety and recovery

- Refuse cached/fresh database or encryption configuration drift before preparation and backup. Clear generated bootstrap caches before booting switched/recovered code, including providers from removed development dependencies.
- Keep candidate build/test containers non-root, resource bounded and isolated from production environment files, databases and the Docker socket. Disable retained command-container logs and restrict interrupted-command cleanup to operation owner plus command-role labels.
- Retain generated frontend/Filament assets, application keys, uploads, stopped-worker state and post-backup writes through explicit code recovery. Database restoration remains a separate operator action.

### Upgrade notes

- Supported first-release scope: standard Compose Laravel 12/13, reviewed patched PHP 8.2/8.3 templates and installed Filament 4/5. Default target is the latest reviewed supported Laravel branch, currently 13; `--laravel-version X.Y[.Z]` selects a stable target explicitly. Application tests are mandatory; major application/plugin changes can require manual migration.
- Install matching 1.4.0 toolkit, Docker image or Python adapter. Updating pip/pipx alone does not replace an existing native toolkit or application PHP image. Keep the same toolkit revision throughout a saved upgrade plan.
- Run `upgrade --slug shop --json` to inspect without changing the project. Git apply requires the exact tested fast-forward upstream commit. After migrations may have started, code recovery retains maintenance until explicit `--database-verified`; no automatic database rollback occurs.
- Read [the full upgrade guide](docs/UPGRADE.md) for every argument, private candidate review, backups and recovery. Existing Compose volumes and Kubernetes rollout procedures remain unchanged.

### Documentation and verification

- Align VERSION and native/Docker/Python examples to 1.4.0; include the new command in Docker publication smoke checks and the three-case upgrade CI matrix.
- Initialize/migrate/seed the E2E database before starting database-backed queue workers; check every fixture role explicitly so slow MySQL startup cannot silently invalidate upgrade preconditions. Keep the application's intentional stopped-worker preservation unchanged.
- Verify real Laravel 12-to-13 upgrades and code recovery with PostgreSQL/Filament and MySQL/Git through the Python Docker adapter; check queue execution, encrypted-data retention and post-backup writes in a separate PostgreSQL case. Add cached database/key drift refusals and real temporary-container isolation/cleanup checks. Local 195 Bats and 140 Python tests, lint, adapter packaging and Docker CLI source checks pass; publication requires all five CI gates on the exact release commit.
- Refresh project context, navigation, continuity guidance and ADR-0011 for the supported upgrade contract and verified local evidence.

## 1.3.3

LaraShip 1.3.3 enforces patched PHP runtimes after CVE-2026-109618 and CVE-2026-109619 across Compose and Kubernetes deployment paths. It also prevents retired Laravel versions from bypassing the existing security minimum through configuration or unlocked repositories.

### Security

- Require stable PHP 8.2.35+, 8.3.36+, 8.4.27+ or 8.5.12+ within their reviewed branches after CVE-2026-109618/CVE-2026-109619; forbid PHP 8.1 and older, earlier patches, prereleases and unreviewed branches. Update Compose pins/digests to 8.3.36 and 8.2.35 and the Kubernetes Apache pin/digest to 8.3.36.
- Check actual Compose PHP before deployment/update and locked Laravel dependencies before continuing. Kubernetes migration/web/worker Pods validate their own image in a restricted init container before starting. Keep the stronger existing Laravel 12 minimum mandatory, including `versions.env`; Laravel below 10 and retired 10/11 remain unavailable.
- Resolve repositories without a lock file without installing dependencies or running scripts/plugins, then enforce the Laravel policy before installation even if the input repository disables Composer advisory blocking. Recheck dependencies after module installation.
- Run Kubernetes fixture Composer on patched PHP rather than the Composer image's independent PHP runtime. Add boundary/lockfile, downgrade, build-policy synchronization, update refusal and custom Kubernetes-image guards; document existing-installation upgrades and synchronize local agent rules.

### Upgrade notes

- Existing application PHP images must be deliberately rebuilt from the complete updated PHP build directory. Updating pip/pipx, the administrative Docker image or the toolkit alone does not replace them; `update.sh` refuses older runtimes before maintenance. Custom Kubernetes application images must provide PHP CLI and `/app/composer.lock`. See [the runtime security policy](docs/SECURITY_POLICY.md).

### Documentation and verification

- Align VERSION, Python package defaults and current native/Docker/Python/command-builder examples to 1.3.3; document the security policy, Kubernetes image requirements and existing-installation rebuild procedure.
- Verify policy boundaries, update refusal and completion reporting, real Compose/rendered Kubernetes guards, patched PHP 8.3.36/Laravel 13 and PHP 8.2.35/Laravel 12 runtimes, database I/O and graceful FPM shutdown. Real Composer refuses an unlocked retired framework before installation even when the input repository disables advisory blocking.

## 1.3.2

LaraShip 1.3.2 fixes deployment stalling at project Nginx validation/reload when the installer runs from an interactive terminal, including SSH and tmux sessions.

### Fixed

- Redirect stdin from `/dev/null` for both Nginx syntax-check and reload commands under `timeout`. `docker compose exec -T` still attaches stdin; a background process-group terminal read could stop the client with SIGTTIN and leave deployment waiting.
- Keep the existing timeout, error handling, Nginx output and HTTP readiness checks while removing the unnecessary terminal input.

### Tests and release

- Add a controlling-terminal regression test that fails with the old implementation and passes with the fix; use a monotonic deadline and drain final terminal output before asserting success. Preserve the noninteractive and Nginx-failure checks.
- Synchronize VERSION, current documentation examples, the administrative Docker image and the Python package on 1.3.2. Use the updated toolkit/image for subsequent invocations; existing application files and database volumes are not rewritten.

### Upgrade notes

- Updating pip/pipx alone does not replace an existing native toolkit directory. Update the native checkout or install 1.3.2 into a new directory and select it with `--directory`; Docker runners should use `shellharbor/laraship:1.3.2`.

## 1.3.1

LaraShip 1.3.1 is a documentation and verification patch release. It adds a complete command-builder reference and publishes PostgreSQL 18 test results while preserving the deployment behavior and database defaults of 1.3.0.

### Documentation

- Add the complete CLI reference: all 57 long deployment options, aliases, 50 config keys, defaults, validation, additive presets, module dependencies and lifecycle commands.
- Document Python native/Docker argument forwarding, completion and legacy API payloads, Kubernetes arguments, temporary Docker execution and a one-off Docker Compose tools service.
- Publish the PostgreSQL 18 verification report with the tested data-layout contract, logical-migration fixture adjustment and coverage limits.
- Link the reference and PostgreSQL report from README; retain the PyPI badge added after 1.3.0 and refresh current installation examples for 1.3.1.

### Verification

- Validate PostgreSQL 18.6 against the 1.3.0 runtime: 103 checks passed with 10 expected scenario skips across Laravel 12/13, Filament/Horizon, backup/restore, Git update/recovery and logical legacy-17-to-official-18 transfer. The migration used a corrected volume root only in the disposable test fixture; tracked runtime/tests remain unchanged.
- Verify the published 1.3.0 Python adapter through pip and pipx with native and Docker backends in four real deployment/lifecycle scenarios, including private completion delivery, persistence and argument forwarding.

### Release and compatibility

- Synchronize VERSION, Python package metadata and the administrative Docker image on 1.3.1. No new runtime options or automatic database upgrades are introduced.
- Keep PostgreSQL 17 as the default. PostgreSQL 18 validation does not make an in-place image-tag change a supported major upgrade; use a separate logical migration and test the actual application data.
- Completion hooks and Python packaging remain available from 1.3.0 onward. Existing project copies and database volumes are unchanged by upgrading the installer.

## 1.3.0

LaraShip 1.3.0 adds a dependency-free Python CLI for pip/pipx installation and deployment completion hooks for local automation and API integrations. Native Bash, the Docker CLI and the separate Kubernetes backend remain supported.

### Added

- Add deployment completion callbacks: --on-complete and --completion-endpoint receive a final versioned JSON report on success, operational failure or handled cancellation, after archive creation and before preserving the original exit status.
- Omit completion passwords by default; add explicit application-secret inclusion, private Bearer token files, HTTPS validation, bounded script/API delivery and privacy checks. Release the project lock before delivery; keep legacy endpoint/post-deploy behavior intact.
- Exercise completion behavior against both source and the packaged Docker engine in container CI; retain explicit read-only hook/config inputs during Python Docker inspection without enabling server mounts or networking.
- Add the dependency-free Python 3.10+ laraship CLI, installable through pip/pipx, with native release installation and Docker image execution using the existing deployment/lifecycle tools.
- Verify HTTPS release downloads, SHA-256 and bounded archive extraction before creating a new native toolkit directory; refuse existing/symlink paths and retain failed copies with an incomplete marker.
- Add pip/wheel/sdist/pipx checks across Python 3.10/3.12/3.14 and optional OIDC PyPI publication jobs in Release, enabled with PYPI_PUBLISH=true after configuring its Trusted Publisher.
- Test prerelease builds separately: compare Python versions by PEP 440 identity while retaining the exact GitHub archive and Docker tag spelling in the installed adapter.

### Documentation

- Document completion lifecycle, configuration, permissions, credential limits and Docker/Python use, with a private report-storage example and ADR-0009.
- Document Python installation, backend argument forwarding, privileged server operations, Docker mounts, updates and first-time PyPI setup; record the adapter and publication design in ADR-0008.
- Rename the README's optional Docker shell helper to laraship_docker so it does not shadow the installed Python CLI; update the deployment skill with Python adapter boundaries.
- Add a README website badge and introductory callout linking the LaraShip companion site, guided deployment command builder, setup guidance and FAQ, so users can configure a command before running it on their server.
- Add a Docker Hub repository badge and README examples using the release CLI image for inspection/dry run, Linux deployment/management and non-root Kubernetes rendering; update current examples to shellharbor/laraship:1.3.0.
- Explain how to diagnose a skipped Docker Hub job, distinguish GitHub Actions Variables from Secrets, recover from registry credential rejection, and retry publication for an existing release after correcting configuration.

### Release and internal changes

- Set VERSION and current native, Docker and Python installation examples to 1.3.0. Keep archive, image and Python package versions synchronized and retain exact-commit CI gates.
- Add optional PyPI Trusted Publishing through the existing Release workflow, with checked distributions built separately from the OIDC publish job. Configure the pypi environment and PYPI_PUBLISH variable before publishing.
- Synchronize local project context, continuity instructions and navigation with the new distribution, completion contracts and authorized release process.

### Upgrade notes

- Install the Python CLI with `pipx install laraship==1.3.0` or `python -m pip install laraship==1.3.0` in a virtual environment after PyPI publication. Python 3.10+ is required.
- Native toolkit archives and the CLI image use release 1.3.0; the Docker image is `shellharbor/laraship:1.3.0` for linux/amd64. Select `--backend docker` explicitly when using the Python CLI.
- Updating the adapter or toolkit does not update existing applications, database volumes or copied templates. Existing toolkit/image copies must be updated deliberately to use completion flags.
- Completion hooks are opt-in and apply only to deployment. Passwords are omitted unless `--completion-include-secrets` is set; callback errors do not change the original deployment result. Existing `--post-deploy` and legacy `--endpoint` behavior is preserved.

## 1.2.2

LaraShip 1.2.2 synchronizes release metadata, adds optional Docker Hub publication and fixes the PHP address-change E2E fixture.

### Fixed

- Set VERSION, release notes and installation/publication examples to 1.2.2. The v1.2.1 publication attempt was blocked because its source still declared VERSION=1.2.0; tag/version and exact-commit CI checks remain enforced.
- Use dynamic Docker IPAM allocation instead of a static `--ip` in the PHP address-change E2E fixture. Retry once if PHP reuses its old address, and restore PHP plus Nginx routing on every exit to prevent cascading test failures.

### Docker Hub

- Add optional CLI image publication to the Release workflow after successful GitHub release publication and exact-commit CI verification.
- Configure the Docker Hub login/image through GitHub Variables `DOCKERHUB_USERNAME` and `DOCKERHUB_IMAGE`, and the access token through Secret `DOCKERHUB_TOKEN`. Missing or malformed enabled settings fail before publication; absent variables leave the optional job disabled.
- Build `linux/amd64` from the verified release SHA, check version/help/deployment dry run/non-root Kubernetes rendering, then publish the full version tag and report its digest. Keep credentials out of image build inputs.

### Documentation and internal changes

- Document the release sequence: commit matching VERSION and CHANGELOG metadata, push main/master, wait for all five required checks on the exact SHA, then tag that commit. The new `v1.2.2` tag must include this preparation; rerunning the old tag does not incorporate later changes.
- Document Docker Hub setup, existing-release publication and digest pinning. Refresh project context, continuity instructions and navigation for release metadata, Docker Hub and the E2E fixture repair.

### Validation

- Release preparation passed 28 static Bats checks, 25 Python release-gate/publication tests and actionlint. The actual workflow metadata step accepts v1.2.2 and rejects v1.2.1; CLI, extracted notes and Docker Hub metadata agree on 1.2.2. Historical 1.2.0/1.1.1/1.1.0 release-note bodies are unchanged.
- Before this metadata-only preparation, Docker Hub automation passed 188 Bats checks, 54 Python tests, configured ShellCheck/Bash syntax and actionlint. A real linux/amd64 CLI build passed version/help/dry-run and non-root Kubernetes-render checks without network and with a read-only root filesystem.
- The E2E fixture repair passed six isolated Docker address-change/recovery cases. The PostgreSQL/Filament/Laravel 12 CI variant passed 44 checks with 8 configuration-dependent skips; the MySQL/config/Redis/queue/backup variant passed 50 checks with 2 configuration-dependent skips, including backup/restore and logical Elestio-to-official MySQL migration.
- Remote CI for the final release commit and Docker Hub authentication/publication must still succeed before this version can be considered published.

## 1.2.0

LaraShip 1.2.0 hardens deployment endpoints, reduces Compose PHP runtime images and makes GitHub release publication safe to retry.

### Security

- Deployment endpoints require HTTPS by default. HTTP requires the explicit `--allow-insecure-endpoint` flag or `ALLOW_INSECURE_ENDPOINT=true` in the deployment configuration.
- Validate endpoint URLs before project creation and sending. Keep endpoint URLs and JSON payloads off the curl command line, discard response bodies and raw diagnostics from endpoint logs, disable redirects and user curl configuration, and retain TLS certificate verification.

### PHP runtime images

- Pin PHP 8.3.35 (default), PHP 8.2.34, Composer 2.10.3, PECL Redis 6.3.0 and APCu 5.1.28. Pin base/Composer/Debian image digests and verify PECL source checksums.
- Separate compilation from the runtime image. Retain required PHP extensions and Composer/Git/SSH/ZIP tools while removing compilers, development headers, debugging tools and optional service packages.
- Reduce the PHP 8.3 image to approximately 401 MB from 2.36 GB for the old recipe rebuilt with matching PHP/Composer/PECL versions: about 83% smaller, measured as uncompressed local Docker image size.
- Preserve UID/GID 1000, add an FPM-only FastCGI liveness probe and allow active requests to drain with a 10-second FPM process-control timeout and 15-second Compose stop grace.

### Fixes

- Validate and reload project Nginx before HTTP readiness to refresh FastCGI resolution after PHP container recreation. Failures retain project data and stop before shared-proxy registration.
- Make release publication retryable: verify matching existing assets, upload only missing files, and refuse conflicting content without overwriting published assets or release notes.
- Serialize publication per tag and support manual recovery with an exact-tag checkout under the selected workflow's publication policy. Successful CI for the exact tagged commit remains required.

### Tests and documentation

- Add real PHP runtime checks for both variants: required extensions, GD/ZIP, PostgreSQL/MySQL PDO access, Laravel 13/12 installation and migrations, non-root/read-only execution and active-request draining. CI builds and checks both variants.
- Add live HTTP/HTTPS privacy tests, release-publication regressions and a controlled PHP address-change regression. Capture PHP/Nginx diagnostics before lifecycle tests alter failed deployments.
- Document PHP build upgrades and release recovery in the operation guides and ADR-0006/ADR-0007. Synchronize project context, continuity instructions and navigation with verified contracts and dated evidence.
- Prepare VERSION, the installation example, workflow example and release notes for the user-confirmed v1.2.0 release.

### Upgrade notes

- Existing HTTP endpoint integrations must switch to HTTPS or explicitly opt in to HTTP. HTTPS recipients still receive deployment credentials and must be trusted; generated-credential console output is unchanged.
- The unsupported PHP 8.1 template is removed. PHP 8.3 remains the default; PHP 8.2 is a manual alternative for compatible Laravel 12 applications.
- Existing installations are not rewritten automatically. To adopt the PHP changes, copy the complete `laravel/.docker/php/` build directory, including its helper scripts and `.dockerignore`, adapt the FPM health/stop settings from `laravel/docker-compose.yml`, and deliberately rebuild the affected PHP roles. Applications using removed optional binaries or fonts need an explicit custom image.
- Native Bash, the Docker CLI adapter and Kubernetes deployment contracts remain supported. This release does not publish a Docker Hub image or change the separate Kubernetes application image template. Database volumes are not upgraded automatically.

### Validation

- Release preparation on 2026-10-15 passed all 184 Bats and 54 Python unit checks without skips, ShellCheck, Bash syntax, actionlint and continuity-skill validation. CLI reports 1.2.0; release notes extract independently and historical 1.1.1/1.1.0 notes are unchanged.
- On 2026-10-14, both PHP variants passed real runtime/database/Laravel/shutdown checks; all 184 Bats and 54 Python unit checks, ShellCheck, Bash syntax and actionlint passed.
- The Nginx address-change fix previously passed isolated PostgreSQL and MySQL E2E scenarios. The original CI failure's exact cause remains unconfirmed.
- Full installer/Kubernetes E2E, ARM builds, registry publication and remote CI were not repeated for this release preparation. Publication still requires successful CI for the final tagged commit.

## 1.1.1

LaraShip 1.1.1 fixes Kubernetes CI fixture permissions and restores consistent release metadata.

### Fixed

- Composer fixture commands now use the invoking user's UID/GID and a writable temporary home. Non-root GitHub Actions runners can edit Laravel routes and remove temporary files after Kubernetes E2E tests.
- Restored the missing 1.1.0 changelog section that caused the version-consistency and release-note extraction checks to fail. Updated VERSION and the README installation example to 1.1.1, with a matching release section.

### Tests and documentation

- The local Kubernetes sandbox runs its test operator as non-root UID 1234 with Docker access, exercising the permissions boundary that previously failed only in CI.
- Updated the Docker/Kubernetes operation guides and restored the verified local project context, continuity profile and navigation after template divergence. Preserved dated validation evidence and the English project-content convention.

### Validation

- The CI fixes passed a complete isolated Docker unit run: 180 Bats checks, 23 Python tests and ShellCheck.
- Real Laravel 12 and 13 Kubernetes E2E passed locally on kind with a non-root operator, including migrations, two web replicas, worker reconciliation, HTTP, read-only application execution, graceful request draining, dependency outage, Pod replacement and cleanup.
- Release preparation passed three release-metadata/CLI version checks and five release-gate tests. Notes for 1.1.1 and 1.1.0 extract independently.

### Upgrade notes

This patch requires no database migration or redeployment of existing applications. Native Bash, Docker CLI and Kubernetes deployment contracts remain compatible with 1.1.0. Publication still requires successful CI for the exact tagged commit.

## 1.1.0

### Added

- A buildable Docker CLI image containing the native deployment and management scripts, templates and dependencies. Linux Compose operations validate the Docker socket, host networking and identical project, lock and archive binds before dispatch.
- An independent Kubernetes backend for existing immutable Laravel application images, with read-only rendering, explicit cluster context, immutable versioned ConfigMap/Secret references, a migration Job before workload rollout, a ClusterIP Service and separate web/worker Deployments.
- A multi-stage application image template with non-root/read-only runtime, external persistent state, startup/readiness/liveness probes, Redis support and graceful shutdown.
- Cluster Lease concurrency, validated migration Job reuse and an explicit zero-replica state when the worker is disabled. Unconfirmed migration/rollout completion retains the lock for verified manual recovery.
- Configurable private ZIP output through LARASHIP_ARCHIVE_DIR and Docker-daemon certificate-volume checks for container project listings.
- The Kubernetes GitHub Actions workflow and README badge, actual CLI/native lifecycle checks with PostgreSQL/MySQL, and real Laravel 12/13 tests in disposable kind. Release publication requires successful Kubernetes checks for the exact commit.
- Docker/Kubernetes operation guides and ADR-0005 explaining the separate distribution and deployment contracts.

### Compatibility and validation

- Native Bash remains supported. Native database provisioning/deletion stays in the native runner, and existing Compose projects/database volumes are not converted automatically. Kubernetes uses prepared application images and external database/storage, backup, scheduler and certificate services; automatic schema/workload rollback is unsupported.
- Local adapter validation on 2026-10-04 passed 180 Bats checks, 23 Python tests, syntax/ShellCheck/actionlint, independent review, actual CLI/native operations for both database engines and real Laravel 12/13 on single-node kind 1.37.0. Those E2E runs used a root test operator and did not cover the non-root GitHub Actions fixture-ownership failure fixed under Unreleased.
- Registry publication and a successful remote CI rerun are not established by local validation. Multi-node operation, production sizing and real external Redis/S3/Ingress/TLS require separate checks.
