# Changelog

After every task with file changes, briefly record what changed and why: features, fixes, internal work, dependencies, documentation, and AI-KIT. Keep new entries under `Unreleased` until a release is confirmed; use verified dates and versions. Tasks without file changes need no entry.

## Unreleased

### AI-KIT

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
