# Running LaraShip in Docker

Native Bash remains supported. The CLI image contains the same scripts, templates and dependencies; it manages separate application containers through the Linux server's existing Docker Engine. It does not install Docker on the host or run a second daemon.

Source builds containing the [runtime security policy](SECURITY_POLICY.md) enforce the reviewed PHP patch floors and mandatory Laravel minimum through the same engine as native Bash. Release 1.3.3 introduces this policy; earlier published images retain their original behavior. Updating the administrative image alone does not rebuild application PHP images; follow the policy's existing-installation procedure.

## Build and inspect

```bash
docker build -t laraship:local .
docker run --rm laraship:local --help
docker run --rm laraship:local --version
docker run --rm laraship:local deploy --dry-run --domain shop.example.com --db-type postgres --no-ssl
```

BuildKit is required. Docker CLI 29.8.2, kubectl 1.37.0 and Ubuntu 24.04 are the image's supported baseline. The native Kubernetes adapter requires Python 3.10+ and kubectl compatible with the target cluster.

## Publish to Docker Hub with GitHub Actions

Create a Docker Hub repository, for example `YOUR_NAMESPACE/laraship`, and a [personal access token](https://docs.docker.com/security/access-tokens/) with Read and Write permission for that repository. The login account must have push access when the namespace belongs to an organization.

In the GitHub repository, open **Settings → Secrets and variables → Actions** and configure:

| Tab | Name | Value |
|---|---|---|
| Variables | `DOCKERHUB_USERNAME` | The Docker Hub login that owns the token |
| Variables | `DOCKERHUB_IMAGE` | The full lowercase repository name, for example `your-namespace/laraship` |
| Secrets | `DOCKERHUB_TOKEN` | The Docker Hub personal access token |

Keep the token in Secrets. The namespace in `DOCKERHUB_IMAGE` can differ from the login account. With both variables absent, Docker Hub publication is skipped; partially configured settings fail with a configuration error.

The existing [Release workflow](../.github/workflows/release.yml) publishes the CLI image after GitHub release publication succeeds, including the exact-commit CI gate and VERSION/CHANGELOG checks. It checks out the verified commit by SHA, builds the root Dockerfile for `linux/amd64`, and checks version, help, deployment dry run and non-root Kubernetes rendering before login and push. The Docker Hub token is passed only to credential validation and the registry login action. This publishes the administrative CLI; application images and Compose PHP images have their own build contexts.

Commit `VERSION=1.4.0` and the matching CHANGELOG section before creating `v1.4.0`. Push the commit to main/master, wait for all required checks on its exact SHA, then tag and push that verified commit. See the [release preparation sequence](../README.md#github-actions). To publish an existing version, first put the updated workflow on the default branch, then open **Actions → Release → Run workflow**, select that branch and enter the existing tag. Its commit must pass the same CI gate, contain the CLI Dockerfile, and match VERSION and CHANGELOG. Manual publication uses the selected workflow's configuration validator and the requested release's source code.

The image uses the full version without the leading `v`: `your-namespace/laraship:1.4.0`, or `your-namespace/laraship:1.4.0-rc.1` for a prerelease. The Actions job summary records the image digest:

```bash
docker pull your-namespace/laraship:1.4.0
docker run --rm your-namespace/laraship:1.4.0 --version
```

Use the reported `your-namespace/laraship@sha256:...` reference for reproducible deployment: a rerun can rebuild a version tag from changing base packages. Substitute that reference for `laraship:local` in the examples below. Publishing is performed inside Release rather than a second release-event workflow, because [events created by GITHUB_TOKEN generally do not trigger another workflow](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow). A Docker Hub failure leaves the existing GitHub release intact; rerun Release after correcting the registry configuration.

### Troubleshooting a skipped publication

If GitHub Release succeeds but the Docker Hub repository has no tags, inspect the **Publish the CLI image to Docker Hub** job. A `skipped` job with no steps means publication was disabled by its configuration condition. The job starts when either `DOCKERHUB_USERNAME` or `DOCKERHUB_IMAGE` exists in Actions **Variables**; both are required for successful configuration validation.

Open **Settings → Secrets and variables → Actions → Variables** and create both repository variables from the table above. Saving `DOCKERHUB_USERNAME` only under **Secrets** does not populate `vars.DOCKERHUB_USERNAME`. Keep `DOCKERHUB_TOKEN` under **Secrets**. After correcting the settings, use **Actions → Release → Run workflow** on the default branch with the existing release tag. The workflow rechecks CI and existing release assets before publishing the image; configuration recovery does not require a new release version or moving the tag.

If the job reaches **Log in to Docker Hub** and reports `unauthorized: incorrect username or password`, Docker Hub rejected the login/token pair. Create or update a [personal access token](https://docs.docker.com/security/access-tokens/personal-access-tokens/) for the account named in `DOCKERHUB_USERNAME`, grant Read/Write access, and replace the repository Secret `DOCKERHUB_TOKEN`. Then rerun the failed job. The secret value is entered directly in GitHub; its presence can be checked without retrieving its contents.

## PHP runtime builds

Compose uses `laravel/.docker/php/php83.Dockerfile` by default. Its shared builder pins PECL versions/checksums and produces a runtime library list; the final image copies only PHP binaries, extensions/configuration and the pinned Composer binary into digest-pinned Debian Bookworm. It runs as UID/GID 1000 and supports a read-only root filesystem with writable application state and `/tmp`. FPM receives `SIGQUIT` directly through the exec entrypoint and has a 10-second process-control grace; Compose's 15-second stop grace allows escalation afterward. Tune both limits for longer requests. `fpm-healthcheck` checks local FastCGI liveness independently of the database; Compose enables it only on the FPM service, not the utility/worker roles.

```bash
docker build -t laraship-php83:local -f laravel/.docker/php/php83.Dockerfile laravel/.docker/php
python3 tests/php-image-smoke.py --image laraship-php83:local --variant 83
docker build -t laraship-php82:local -f laravel/.docker/php/php82.Dockerfile laravel/.docker/php
python3 tests/php-image-smoke.py --image laraship-php82:local --variant 82
```

These checks create private Docker networks/volumes and temporary PostgreSQL/MySQL containers, test real Laravel installation/migrations, then remove their own resources. They do not publish ports or require privileged containers. The E2E workflow runs both variants. See [PHP pins and upgrade notes](../README.md#php-runtime-images) and [ADR-0007](adr/0007-pinned-php-runtime.md). The Compose base image accepts external application code; the Kubernetes backend retains its separate standalone application build and workload probes.

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

## Managed application upgrades

Release 1.4.0 adds `upgrade` / `upgrade.sh` dispatch to `shellharbor/laraship:1.4.0`. Preparation, verification, application and recovery use the standard writable server mounts above. Planning alone requires identical **read-only** `/var/www` and `/var/run/docker.sock` binds, host networking and temporary space; no lock/archive mount is required. Static `upgrade --help`/`--version` need no mounts. See [supported versions, private staging, every argument and complete examples](UPGRADE.md). The read-only socket mount does not restrict Docker API capabilities; trust the administrative image. Existing Kubernetes application images and workflows remain separate.

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
