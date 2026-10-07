#!/usr/bin/env bash
# Disposable kind + real Laravel. Never uses the caller's kubeconfig or cluster.
set -euo pipefail
[[ "${LARASHIP_TEST_SANDBOX:-0}" == 1 || "${LARASHIP_K8S_TEST_ALLOW:-0}" == 1 ]] || {
    echo 'Kubernetes E2E requires the disposable sandbox or an explicitly allowed CI runner' >&2; exit 1;
}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK=$(mktemp -d /tmp/laraship-k8s.XXXXXX)
CLUSTER="laraship-$(basename "$WORK" | tr '[:upper:]' '[:lower:]' | tr '.' '-')"
CREATED=0
cleanup() {
    local result=$?
    if [[ "$CREATED" == 1 ]]; then
        if [[ "$result" != 0 && -f "$KUBECONFIG" ]]; then
            kubectl --kubeconfig "$KUBECONFIG" --request-timeout=5s -n smoke get pods,jobs >&2 || true
            kubectl --kubeconfig "$KUBECONFIG" --request-timeout=5s -n smoke logs -l app.kubernetes.io/component=migration --tail=50 >&2 || true
            kubectl --kubeconfig "$KUBECONFIG" --request-timeout=5s -n smoke logs -l app.kubernetes.io/component=web --tail=30 >&2 || true
        fi
        kind delete cluster --name "$CLUSTER" >/dev/null
    fi
    rm -rf -- "$WORK"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
export KUBECONFIG="$WORK/kubeconfig"
NODE_IMAGE="${K8S_NODE_IMAGE:-kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5}"
CLI_IMAGE="laraship:k8s-cli-test"
APP_IMAGE="laraship-app:k8s-test"
mkdir -p "$WORK/app"
echo "==> Kubernetes E2E operator: UID $(id -u), GID $(id -g)"
echo '==> build LaraShip CLI'
docker build -q -t "$CLI_IMAGE" "$ROOT" >/dev/null
docker run --rm "$CLI_IMAGE" --version
docker run --rm --user 1000:1000 --read-only "$CLI_IMAGE" kubernetes render \
    --name smoke --namespace smoke --image "$APP_IMAGE" --configmap smoke-config --secret smoke-secret --revision test --worker > "$WORK/render.json"
if docker run --rm "$CLI_IMAGE" list; then echo 'Compose runner accepted missing host binds' >&2; exit 1; fi
echo '==> prepare a real Laravel fixture and build the immutable application'
# Keep bind-mounted files owned by the operator, including on non-root CI runners.
COMPOSER_RUN=(docker run --rm --user "$(id -u):$(id -g)" \
    -e HOME=/tmp -e COMPOSER_HOME=/tmp/composer \
    -v "$WORK/app:/app" -w /app composer:2.10.3)
"${COMPOSER_RUN[@]}" \
    create-project --no-interaction --no-scripts --no-install laravel/laravel . "${K8S_LARAVEL:-13.0.0}" >/dev/null
# composer.lock is generated on purpose in this temporary test fixture; production uses its committed lock.
"${COMPOSER_RUN[@]}" config platform.php 8.3.35 >/dev/null
"${COMPOSER_RUN[@]}" \
    update --no-interaction --no-scripts --no-plugins --no-install >/dev/null
printf 'IMAGE_SECRET_MUST_NOT_EXIST=fixture-secret\n' > "$WORK/app/.env"
printf '\nRoute::get("/slow", static function () { sleep(8); return "slow-ok"; });\n' >> "$WORK/app/routes/web.php"
docker build -q -t "$APP_IMAGE" -f "$ROOT/kubernetes/application/Dockerfile" "$WORK/app" >/dev/null
docker run --rm --entrypoint sh "$APP_IMAGE" -ec 'test "$(id -u)" = 1000; test ! -e /app/.env; test -f /app/vendor/autoload.php; php -m | grep -qi redis; ! command -v composer; ! command -v docker'
echo '==> create isolated kind cluster'
# Refuse a collision before creation; cleanup never deletes an existing cluster.
if kind get clusters | grep -qx "$CLUSTER"; then echo 'Cluster name collision' >&2; exit 1; fi
CREATED=1
if ! kind create cluster --name "$CLUSTER" --image "$NODE_IMAGE" --kubeconfig "$KUBECONFIG" --wait 120s --retain; then
    docker logs "$CLUSTER-control-plane" >&2 || true
    exit 1
fi
CTX="kind-$CLUSTER"
K=(kubectl --context "$CTX" --namespace smoke)
kind load docker-image "$APP_IMAGE" --name "$CLUSTER"
"${K[@]}" create namespace smoke >/dev/null
"${K[@]}" apply --dry-run=server -f "$WORK/render.json" >/dev/null
# The DB is a test dependency, separate from the application runtime. No production DB is provisioned.
cat > "$WORK/db.json" <<'JSON'
{"apiVersion":"v1","kind":"List","items":[
 {"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"fixture-db"},"spec":{"replicas":1,"selector":{"matchLabels":{"app":"fixture-db"}},"template":{"metadata":{"labels":{"app":"fixture-db"}},"spec":{"containers":[{"name":"db","image":"postgres:17-bookworm","env":[{"name":"POSTGRES_DB","value":"laravel"},{"name":"POSTGRES_USER","value":"laravel"},{"name":"POSTGRES_PASSWORD","value":"fixture-only"}],"ports":[{"containerPort":5432}],"readinessProbe":{"exec":{"command":["pg_isready","-U","laravel"]},"periodSeconds":2}}]}}}},
 {"apiVersion":"v1","kind":"Service","metadata":{"name":"fixture-db"},"spec":{"selector":{"app":"fixture-db"},"ports":[{"port":5432,"targetPort":5432}]}}
]}
JSON
"${K[@]}" apply -f "$WORK/db.json" >/dev/null
"${K[@]}" rollout status deployment/fixture-db --timeout=180s
"${K[@]}" create configmap smoke-config --from-literal=DB_CONNECTION=pgsql --from-literal=DB_HOST=fixture-db \
    --from-literal=DB_PORT=5432 --from-literal=DB_DATABASE=laravel --from-literal=DB_USERNAME=laravel \
    --from-literal=SESSION_DRIVER=database --from-literal=CACHE_STORE=database --from-literal=QUEUE_CONNECTION=database \
    --from-literal=FILESYSTEM_DISK=s3 --from-literal=APP_URL=http://smoke --dry-run=client -o json |
    python3 -c 'import json,sys; d=json.load(sys.stdin); d["immutable"]=True; print(json.dumps(d))' | "${K[@]}" create -f - >/dev/null
"${K[@]}" create secret generic smoke-secret --from-literal=DB_PASSWORD=fixture-only \
    --from-literal=APP_KEY=base64:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA= --dry-run=client -o json |
    python3 -c 'import json,sys; d=json.load(sys.stdin); d["immutable"]=True; print(json.dumps(d))' | "${K[@]}" create -f - >/dev/null
ARGS=(--context "$CTX" --name smoke --namespace smoke --image "$APP_IMAGE" --configmap smoke-config --secret smoke-secret --revision test --worker)
echo '==> migrate before web/worker rollout, then repeat the same revision'
bash "$ROOT/kubernetes.sh" deploy "${ARGS[@]}"
bash "$ROOT/kubernetes.sh" deploy "${ARGS[@]}"
[[ "$("${K[@]}" get jobs -l app.kubernetes.io/component=migration -o json | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["items"]))')" == 1 ]]
"${K[@]}" get deployment smoke-web -o json | python3 -c 'import json,sys; assert json.load(sys.stdin)["status"]["readyReplicas"] == 2'
"${K[@]}" exec deployment/smoke-web -- php artisan migrate:status --no-interaction >/dev/null
check_http() {
    # Service endpoints can lag a completed rollout; the worker is a stable external client.
    "${K[@]}" exec deployment/smoke-worker -- php -r '
        $ctx=stream_context_create(["http"=>["timeout"=>2]]);
        for ($i=0; $i<20; $i++) {
            if (@file_get_contents("http://smoke/up", false, $ctx) !== false) exit(0);
            sleep(1);
        }
        exit(1);'
}
check_http
"${K[@]}" exec deployment/smoke-web -- sh -ec 'test "$(id -u)" = 1000; test ! -e /app/.env; ! touch /app/forbidden'
echo '==> SIGTERM drains an in-flight web request'
POD=$("${K[@]}" get pods -l app.kubernetes.io/component=web -o jsonpath='{.items[0].metadata.name}')
POD_IP=$("${K[@]}" get pod "$POD" -o jsonpath='{.status.podIP}')
"${K[@]}" exec deployment/smoke-worker -- php -r 'echo file_get_contents($argv[1]);' "http://$POD_IP:8080/slow" > "$WORK/slow-response" &
REQUEST_PID=$!
sleep 2
"${K[@]}" delete pod "$POD" --wait=false >/dev/null
wait "$REQUEST_PID"
grep -qx slow-ok "$WORK/slow-response"
"${K[@]}" rollout status deployment/smoke-web --timeout=120s
echo '==> delayed dependency and liveness do not cascade-restart the web pods'
"${K[@]}" patch service fixture-db --type=merge -p '{"spec":{"selector":{"app":"temporarily-unavailable"}}}' >/dev/null
sleep 15
"${K[@]}" get pods -l app.kubernetes.io/component=web -o json | python3 -c 'import json,sys; assert all(s["restartCount"] == 0 for p in json.load(sys.stdin)["items"] for s in p["status"]["containerStatuses"])'
"${K[@]}" patch service fixture-db --type=merge -p '{"spec":{"selector":{"app":"fixture-db"}}}' >/dev/null
"${K[@]}" rollout status deployment/fixture-db --timeout=120s
echo '==> replacing a web pod preserves shared database state'
"${K[@]}" rollout restart deployment/smoke-web >/dev/null
"${K[@]}" rollout status deployment/smoke-web --timeout=180s
"${K[@]}" exec deployment/smoke-web -- php artisan migrate:status --no-interaction >/dev/null
check_http
echo '==> disabling the worker reconciles a running worker to zero'
bash "$ROOT/kubernetes.sh" deploy "${ARGS[@]:0:${#ARGS[@]}-1}"
"${K[@]}" get deployment smoke-worker -o json | python3 -c 'import json,sys; assert json.load(sys.stdin)["spec"]["replicas"] == 0'
echo 'Kubernetes E2E passed: real Laravel, migrations, 2 replicas, worker, Service, read-only non-root runtime and pod replacement'
