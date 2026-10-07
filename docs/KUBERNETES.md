# Kubernetes application backend

LaraShip offers an independent Kubernetes adapter alongside the original Linux/Compose scripts. It deploys an existing Laravel application from a built image. It does not convert an existing `/var/www` project or move its data automatically.

## Application image

Build from the application's directory, with its committed `composer.lock` and already compiled frontend assets:

```bash
docker build -f /path/to/laraship/kubernetes/application/Dockerfile \
  -t registry.example.com/shop:1.0 /path/to/shop
```

Push that application image through your normal release process. Use its digest for production. The supplied multi-stage template uses PHP 8.3.35 Apache, Composer 2.10.3 and phpredis 6.2.0. Runtime contains application code and vendor dependencies, not Composer, Docker or LaraShip. Standard `.env`, auth files and private keys are excluded from image layers even without the caller's `.dockerignore`. Dependencies are installed only during build; custom Composer plugins/scripts and extra PHP extensions require an explicit application-specific build adaptation.

The runtime contract is HTTP on 8080, UID/GID 1000, stdout/stderr logging and writable `/tmp`, `/app/storage`, `/app/bootstrap/cache`. It runs with a read-only root filesystem, no capabilities, no service-account token and no host mounts. Web SIGTERM is translated to Apache's graceful stop; PHP workers receive SIGTERM directly. `/up` checks Laravel boot by default; choose `--readiness-path` for an application's stronger readiness endpoint. `/_laraship/live` checks the local HTTP process independently of the database. Startup has a five-minute budget. No replica performs database migrations during startup.

State is external: DB, cache, sessions and queue use configurable service DNS/endpoints, and durable uploads use object storage such as S3. Per-Pod `emptyDir` directories are scratch space, not backups or upload storage. Two or more replicas require explicit external `SESSION_DRIVER`, `CACHE_STORE` and `FILESYSTEM_DISK` in ConfigMap. Queue jobs must tolerate retries/duplicate delivery; the worker's timeout is 45 seconds and termination grace 60 seconds. Resources (100m/128Mi requests, 1 CPU/512Mi limits) are starting assumptions for smoke tests, not measured production sizing. Applications with slower jobs/requests must adapt the contract and termination/resources accordingly.

Use a digest for production deployments. If using a version tag, the registry must enforce tag immutability; never overwrite it. Every rebuild or configuration change needs a new revision and, for changed configuration, new immutable object names. A mutable tag with `IfNotPresent` can give different Pods different contents and invalidate migration identity.

## Configuration and access

Create a dedicated namespace and **immutable, versioned** ConfigMap/Secret first. This prevents migrations and new replicas reading different configurations during a release. Never delete/recreate a referenced configuration object while a deployment is running; create new names instead.

Example non-secret configuration:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: shop-config-v1
  namespace: shop
immutable: true
data:
  APP_URL: https://shop.example.com
  DB_CONNECTION: pgsql
  DB_HOST: postgres.database.svc.cluster.local
  DB_PORT: "5432"
  DB_DATABASE: shop
  DB_USERNAME: shop
  SESSION_DRIVER: redis
  CACHE_STORE: redis
  QUEUE_CONNECTION: redis
  REDIS_CLIENT: phpredis
  REDIS_HOST: redis.database.svc.cluster.local
  FILESYSTEM_DISK: s3
  AWS_BUCKET: shop-uploads
  AWS_DEFAULT_REGION: eu-central-1
```

Use existing Secret data for `APP_KEY`, DB/Redis passwords and object-storage credentials, or use workload identity supported by the application. A namespace-scoped operator can create an immutable Secret from a protected env file:

```bash
kubectl --context YOUR_CONTEXT -n shop create secret generic shop-secret-v1 \
  --from-env-file=/secure/shop-secret.env --dry-run=client -o json |
  python3 -c 'import json,sys; d=json.load(sys.stdin); d["immutable"]=True; print(json.dumps(d))' |
  kubectl --context YOUR_CONTEXT -n shop create -f -
```

The file contains a valid application key and credentials; keep it outside Git and the build context with mode 600. ConfigMap must not contain password/secret/token keys. `APP_ENV=production`, `APP_DEBUG=false` and `LOG_CHANNEL=stderr` are enforced in the Pod. `--image-pull-secret NAME` references an existing registry Secret.

The operator's kubeconfig needs namespace-scoped permissions to get ConfigMaps/Secrets; create/get/update Leases and Jobs; get/create/patch/update Deployments and Services; and get/watch Deployments/Jobs for readiness. Workloads do not receive that credential or API access.

## Render and deploy

```bash
bash kubernetes.sh render \
  --name shop --namespace shop --image registry.example.com/shop:1.0 \
  --configmap shop-config-v1 --secret shop-secret-v1 --revision release-1 --worker > shop.json

# JSON is accepted natively by the Kubernetes API.
kubectl --context YOUR_CONTEXT -n shop apply --dry-run=server -f shop.json

bash kubernetes.sh deploy --context YOUR_CONTEXT \
  --name shop --namespace shop --image registry.example.com/shop:1.0 \
  --configmap shop-config-v1 --secret shop-secret-v1 --revision release-1 --worker
```

`render` is read-only and returns a Job, web Deployment, ClusterIP Service and worker Deployment. Without `--worker`, desired worker replicas are zero, so an old worker is also stopped on the next deploy. `deploy` requires an explicit context; it checks configuration, acquires a cluster Lease, creates and waits for migration completion **before** applying workloads, then waits for rollout. Failure is nonzero; a failed migration does not replace the running application.

Use a new revision for each release/explicit retry. The migration Job's name includes a hash of the revision, image, runtime and controller policy. It requests one completion with parallelism one, no automatic retry, a five-minute deadline and replacement only after a Pod has failed. Repeating the same release reuses its Job after checking ownership labels, the Pod contract and controller policy; altered parallelism, retry/deadline settings, automatic TTL deletion and custom controller policies are refused. Failed Jobs are not deleted or retried silently. Retain Jobs for diagnosis and clean old history explicitly. Kubernetes Jobs do not guarantee exactly-once execution: migrations must tolerate recovery and remain compatible with the old web/worker replicas during a rolling release (expand, migrate, then remove obsolete schema in a later release). Automatic migration/schema rollback is unsupported.

The Lease uses Kubernetes resource-version compare-and-swap rather than a local lock. Concurrent LaraShip deploys for the same namespace/name fail closed. If a runner is killed, the lock remains held: verify that operation really stopped, inspect workloads/Job, then clear its holderIdentity before retrying. Manual kubectl/other deploy tools must coordinate separately. Do not clear a live runner's Lease.

Expose the ClusterIP Service through the cluster's existing Ingress/Gateway controller; terminate TLS with its certificate management. A minimal Ingress example (replace the class and host) is:

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: shop
  namespace: shop
spec:
  ingressClassName: your-controller
  tls:
    - hosts: [shop.example.com]
      secretName: shop-tls
  rules:
    - host: shop.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: shop
                port:
                  number: 80
```

After a successful migration, an apply/rollout failure may leave partially updated web/worker workloads. Inspect both Deployments, ReplicaSets and the Job, then fix forward or roll back workloads to an image/configuration compatible with the migrated schema. The adapter does not provide an atomic workload or database rollback. A failure after attempting Job creation retains the Lease until migration and rollout are confirmed complete; network failure or Ctrl-C must not allow another runner to start concurrent migrations.

## Scope and checks

`.github/workflows/kubernetes.yml` builds the LaraShip CLI and application image, uses API server schema validation in disposable kind 1.37.0, and tests real Laravel 12/13 migrations, repeated deploy, two replicas, a queue worker and its disabling, Service HTTP, non-root/read-only execution, replacement of Pods and draining an active HTTP request on SIGTERM. Kubernetes 1.37.0 is the validated API baseline; older clusters require separate compatibility testing. Local tests use their own Docker daemon and kubeconfig. The GitHub badge reports this workflow; a local pass does not prove remote CI ran.

These are single-node checks with a PostgreSQL test dependency. Multi-node scheduling, real external Redis/object storage, Ingress/TLS and production sizing need separate application/infrastructure validation.

Local E2E runs the test operator without root, as GitHub Actions does. Fixture preparation runs Composer with that operator's UID/GID, preserving writable routes and removable temporary directories. The sandbox's administrative daemon remains separate from the non-root operator and application runtime.

The existing Compose backend keeps its host paths, named containers, shared proxy and DB volumes. Those deployment details are confined to its adapter; existing generated projects are not certified as portable Kubernetes workloads. Kubernetes uses the separate immutable-image contract. Native DB provisioning, Filament installation, Certbot, scheduler, backup/restore and automatic conversion/migration of an existing Compose project are not implemented in this Kubernetes backend. Prepare modules at application build time; use external database backup operations and an established cluster scheduler/certificate controller. This is not a claim that every legacy Compose utility can run as a Pod.

References: [Kubernetes Jobs](https://kubernetes.io/docs/concepts/workloads/controllers/job/), [probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/), [immutable configuration](https://kubernetes.io/docs/concepts/configuration/configmap/#immutable-configmaps), [kind](https://kind.sigs.k8s.io/docs/user/quick-start/).
