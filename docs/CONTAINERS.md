# Running LaraShip in Docker

Native Bash remains supported. The CLI image contains the same scripts, templates and dependencies; it manages separate application containers through the Linux server's existing Docker Engine. It does not install Docker on the host or run a second daemon.

## Build and inspect

```bash
docker build -t laraship:local .
docker run --rm laraship:local --help
docker run --rm laraship:local --version
docker run --rm laraship:local deploy --dry-run --domain shop.example.com --db-type postgres --no-ssl
```

The image is built locally; these changes do not publish a registry image. BuildKit is required. Docker CLI 29.8.2, kubectl 1.37.0 and Ubuntu 24.04 are the image's supported baseline. The native Kubernetes adapter requires Python 3.10+ and kubectl compatible with the target cluster.

## Compose on a Linux server

Docker must already be installed and running on the target Linux server. Create these host directories first:

```bash
sudo install -d -m 755 /var/www
sudo install -d -m 700 /run/lock/laraship /var/backups/laraship
docker run --rm -it --network host \
  --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
  --mount type=bind,src=/var/www,dst=/var/www \
  --mount type=bind,src=/run/lock/laraship,dst=/run/lock/laraship \
  --mount type=bind,src=/var/backups/laraship,dst=/var/backups/laraship \
  laraship:local deploy --slug shop --domain shop.example.com --db-type postgres --no-ssl
```

Use the same mounts for `update`, `backup`, `activate`, `deactivate`, `remove` and `list`. Their arguments are the native scripts' arguments. Keep Docker's default container hostname: preflight inspects the running CLI container. Remote Docker endpoints and Docker Desktop filesystem mappings are not supported by this Compose adapter.

Identical paths matter: bind mounts are resolved on the daemon's host, and native scripts must read the same project/archive paths. Host networking lets the runner inspect occupied server ports and check loopback HTTP. The shared lock directory serializes native Bash and container operations. Preflight rejects missing, mismatched or read-only required mounts before dispatch. `--privileged` is unnecessary. Access to the host Docker socket gives administrative control; use a trusted image.

`--create-backup` publishes its private ZIP under `/var/backups/laraship` in container mode. To change that location, set `LARASHIP_ARCHIVE_DIR` and bind the host directory at the identical container path. Native Bash keeps `/tmp` by default. Both runners preserve private staging, exclusive publication and file mode 600. Native database provisioning and deletion require the native Bash runner: container deployment refuses `--db-native`, including settings from a config file. Removing an existing native-DB project is also refused before routing or data changes.

Mount `--config` and `--deploy-key` files read-only at explicit paths when using them. Do not bake credentials into the image. Help, version, deploy dry run and module/preset listings do not require server mounts; `update --help` and `backup --help` are also supported without them. Certificate presence is checked through a read-only helper using `busybox:1.37.0` already on the daemon; `list` does not pull it automatically and reports `UNKNOWN` if that helper image is unavailable.

## Kubernetes from the same CLI

The Kubernetes adapter needs only a kubeconfig and temporary writable space. It can run without root or a Docker socket:

```bash
docker run --rm --user "$(id -u):$(id -g)" --read-only --tmpfs /tmp \
  --mount type=bind,src="$PWD/kubeconfig",dst=/config/kubeconfig,readonly \
  -e KUBECONFIG=/config/kubeconfig \
  laraship:local kubernetes render \
  --name shop --namespace shop --image registry.example.com/shop:1.0 \
  --configmap shop-config-v1 --secret shop-secret-v1 --revision v1
```

Use a self-contained kubeconfig with embedded certificates, and change `render` to `deploy --context YOUR_CONTEXT` to run migrations and roll out resources. This uses the Kubernetes API rather than Compose. See [Kubernetes contracts and examples](KUBERNETES.md).

## Verification

`bash tests/run-local.sh unit` checks the original Bash behavior and the new guards. `bash tests/run-local.sh container` exercises actual CLI/native interoperability with PostgreSQL; `E2E_DB=mysql` selects MySQL. `bash tests/run-local.sh kubernetes` builds both images and exercises a real Laravel application in disposable kind, with an independent Docker daemon; `K8S_LARAVEL=12.0.0` selects Laravel 12 instead of 13. Run these modes sequentially because their Docker cache must not be shared by running daemons. The production CLI image is separate from `tests/Dockerfile`; that privileged sandbox is exclusively for tests.

The local Kubernetes test operator runs as UID 1234 with access to the sandbox's Docker daemon, matching non-root GitHub Actions execution. Composer creates fixture files with the operator's UID/GID and a writable temporary home so route edits and cleanup work without root. The deployed application still runs as UID 1000.

References: [Docker bind mounts](https://docs.docker.com/engine/storage/bind-mounts/), [Docker daemon security](https://docs.docker.com/engine/security/#docker-daemon-attack-surface).
