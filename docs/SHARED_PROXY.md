# Existing shared proxies

**Available in 1.4.1:** earlier published versions require a LaraShip `sites/` directory and do not contain this adapter. Update the complete toolkit before using the recovery procedure below. Updating only `deploy-laravel.sh` is insufficient: shared lifecycle helpers and `lib/proxy_config.py` must match. The matching Docker CLI image and Python package are `shellharbor/laraship:1.4.1` and `laraship==1.4.1`; upgrading the Python adapter alone does not replace an existing native toolkit or application image.

## What is preserved

A working standalone `/var/www/nginxproxy/docker-compose.yml` can use its own image or Dockerfile, network-list/mapping syntax, aliases, command, environment, ports and certificate volumes. Existing inline Nginx upstreams/server blocks remain in their original main configuration. LaraShip adds its `sites/*.conf` include inside the existing `http` block and mounts that directory read-only. Existing TLS settings and certificate volume references are retained.

The existing `nginxproxy` container's Compose project name and immutable image ID are reused. Adding a site does not rebuild its custom runtime or start unrelated dependencies. Changes to networks or mounts can briefly recreate the proxy container; the feature does not promise uninterrupted connections during first adoption.

Compose's own parser reads YAML, anchors and merge keys. The edited `docker-compose.yml` is then saved as formatted JSON, which is valid Compose YAML. This changes its presentation and expands anchors; it preserves the effective configuration rather than YAML comments. Interpolation expressions and env-file references stay unresolved. External relative host paths are anchored to the original proxy directory so private staging does not change their meaning.

Before the first conversion, a private copy of the original proxy directory is saved under:

```text
/var/www/.laraship-proxy-backups/<UTC timestamp>.<random>/original/
```

The backup root and operation directory use mode 700. Keep this backup through acceptance; it can contain private configuration. Review retention manually. The transaction also keeps its own original snapshot for automatic rollback.

## Validation and supported topology

The adapter expects a service named `nginxproxy`, with `container_name: nginxproxy`, using Docker bridge networks. The main Nginx configuration must be bind-mounted from a real file inside the proxy directory (a nested configuration directory is supported) and contain one explicit `http` block. Files inside the proxy tree cannot be symlinks. Existing inline routes do not need LaraShip files or markers.

The complete effective proxy topology must be represented by the standalone Compose file. Additional override files, manually added network connections/aliases, `network_mode` proxies and dynamically constructed host bind/build paths require explicit consolidation or another adapter. The operation refuses these unsupported/conflicting shapes before writing the live proxy; it does not replace them with a template. Static addresses or external build/include layouts may also prevent candidate validation and must be reviewed separately.

The shared lock covers snapshotting, candidate edits, validation, application and rollback. Compose configuration and a separate Nginx container are checked before live writes. Duplicate/conflicting hostnames are refused, including conflicts reported by Nginx as warnings. Missing networks, certificate volumes, bad Nginx syntax and resource-name collisions abort adoption. Apply failure restores the previous tree and image; rollback failure retains recovery files and reports their location.

Application and rollback copy only entries changed by the operation. Unrelated runtime files updated or created during validation are retained; conflicting external edits to the same configuration file abort instead of being overwritten. Keep substantial mutable application data outside the proxy configuration directory, since preparing and backing up that directory still snapshots its contents.

Activation, deactivation and removal of a newly managed site edit its own network/certificate references. Existing unrelated routes, aliases and certificates stay configured. Do not use a LaraShip lifecycle command to manage an unrelated inline legacy application.

## Recover an already-created application

If deployment stopped at shared-proxy registration, the application directory/database can already be complete. Use the checked registration and certificate helpers instead of rerunning the installer or deleting that project.

After installing the updated complete toolkit, replace the placeholders and run on the target Linux server:

```bash
sudo bash -s <<'BASH'
set -euo pipefail
source /opt/laraship-1.4.1/deploy-laravel.sh
SLUG='app2'
DOMAIN='app2.example.com'
SSL_EMAIL='admin@example.com'
PROJECT_DIR="$WWW_DIR/$SLUG"
OBTAIN_SSL=true
check_root
runtime_require python3 flock pgrep docker
[[ -f "$PROJECT_DIR/docker-compose.yml" && -f "$PROJECT_DIR/.env" ]] || error 'Project is not ready for proxy recovery'
[[ "$(sed -n 's/^SITE_HOST=//p' "$PROJECT_DIR/.env" | head -n1)" == "$DOMAIN" ]] || error 'Project hostname mismatch'
project_lock
check_project_security "$PROJECT_DIR" /var/www/html/composer.lock || error 'Application runtime security check failed'
proxy_transaction prepare_proxy_site
obtain_ssl_certificate
BASH
```

Use the updated toolkit's actual path in `source`. This procedure retains the application's existing HTTP-auth credentials and Filament/database accounts. Certificate issuance still requires correct DNS and reachable ports 80/443. If issuance fails, HTTP routing remains configured and the script reports the certificate problem.

## Install the complete release toolkit

Download the versioned archive and checksum from the GitHub release on the target server, then install into a new directory:

```bash
curl -fLO https://github.com/shellharbor/laraship/releases/download/v1.4.1/laraship-1.4.1.tar.gz &&
curl -fLO https://github.com/shellharbor/laraship/releases/download/v1.4.1/laraship-1.4.1.tar.gz.sha256 &&
sha256sum -c laraship-1.4.1.tar.gz.sha256 &&
sudo mkdir -m 755 /opt/laraship-1.4.1 &&
sudo tar -xzf laraship-1.4.1.tar.gz \
  -C /opt/laraship-1.4.1 --strip-components=1
```

Keep the current toolkit directory until acceptance. The new-directory check deliberately refuses to overwrite a previous installation. New applications can use the release's ordinary `deploy-laravel.sh`; an already-created application uses the recovery procedure above. No application redeployment or database-volume replacement is part of this toolkit update.

## Verification

The [legacy Docker suite](../tests/e2e-proxy-legacy.bats) uses a sanitized copy of the supplied inline HTTP/TLS layout, a custom Compose project name and real certificate volumes. It checks initial/candidate failure, private original backups, repeated registration, custom image/long binds/dotenv preservation, Basic Auth/ACME, image retention, rollback, TLS activation and managed lifecycle operations while the legacy site remains served. The [standard proxy suite](../tests/e2e-proxy.bats) covers new installations and concurrency. [Python regressions](../tests/test_proxy_config.py) cover parser, resource ownership and unsupported topology boundaries.

This is Compose compatibility. Kubernetes uses its existing separate Ingress/Service and rollout process; no cluster adoption is implied.
