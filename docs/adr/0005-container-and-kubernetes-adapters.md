# ADR-0005: CLI image and separate Kubernetes application adapter

- Status: accepted, Unreleased
- Date: 2026-10-04

## Context

The user requested a Docker image for LaraShip while retaining native Bash, Kubernetes-ready support, a Kubernetes GitHub workflow and a README badge. The current installer combines application setup with Linux host filesystem, native DB administration and Docker Compose operations. Running that same orchestration inside a generic Pod would retain dependencies on Docker socket, local paths, bridge addressing and local locks.

## Decision

Package the existing scripts and templates into a CLI image. Its Linux Compose adapter requires the host Docker daemon, host network and identical writable binds for projects, locks and archives; it validates these requirements before dispatch. Native Bash remains supported, including native database provisioning/deletion. The administrative image is separate from the application runtime.

Introduce an independent Kubernetes API adapter for an existing application image. Supply a multi-stage, non-root HTTP image template with compiled dependencies, external configuration/state, scratch writable paths, distinct health checks and graceful stop. Render native Kubernetes JSON resources or deploy through an explicitly selected kubectl context. Require immutable versioned ConfigMap/Secret references so migration and workloads use the same release configuration. A separate migration Job must complete before applying Deployments/Service; use a cluster Lease with compare-and-swap to serialize LaraShip releases. Queue workers use a separate Deployment, including a zero-replica desired state when disabled.

Test both distribution paths independently: real CLI/native interoperability on PostgreSQL/MySQL, and real Laravel images/migrations/HTTP/replicas/worker in disposable kind. The workflow badge represents those checks, not a general certification of all legacy Compose components.

## Alternatives

- Docker-in-Docker for production: additional privileged daemon, storage and networking complications. Retained only for isolated test infrastructure.
- Bind the host Docker socket into a Kubernetes Job and run the legacy installer: violates the portable runtime contract and does not address host provisioning/state.
- Convert Compose YAML automatically: does not produce immutable app images or solve migrations, probes, concurrency and shared state.
- Replace Compose entirely: unnecessary disruption to existing users and deployments.

## Consequences

The CLI image has administrative Docker permissions and a Linux-only Compose host contract. Kubernetes runtime images do not include LaraShip, Docker, Composer or host credentials. Existing projects are not migrated automatically. External database/Redis/object storage, Ingress/TLS, scheduling and backups require operator configuration. Migrations must be compatible with older replicas during rolling releases; automatic schema rollback is not provided. A crashed runner leaves its Lease held, requiring verified manual recovery rather than unsafe expiry/lock stealing.

See [Docker usage](../CONTAINERS.md), [Kubernetes contracts](../KUBERNETES.md) and [workflow](../../.github/workflows/kubernetes.yml).
