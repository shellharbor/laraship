# Changelog

After every task with file changes, briefly record what changed and why: features, fixes, internal work, dependencies, documentation, and AI-KIT. Keep new entries under `Unreleased` until a release is confirmed; use verified dates and versions. Tasks without file changes need no entry.

## Unreleased

### Documentation

- Add a dynamic PyPI version badge to the README linking to the published laraship package, alongside the Docker Hub and project badges.

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
