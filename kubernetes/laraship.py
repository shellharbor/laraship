#!/usr/bin/env python3
"""Render portable Kubernetes resources, or migrate then deploy through kubectl."""
import argparse
import copy
import hashlib
import json
import re
import subprocess
import sys
import uuid


def dns_name(value: str) -> str:
    if len(value) > 40 or not re.fullmatch(r"[a-z0-9](?:[a-z0-9-]*[a-z0-9])?", value):
        raise argparse.ArgumentTypeError("Use a lowercase DNS label, at most 40 characters")
    return value


def image_reference(value: str) -> str:
    if not re.fullmatch(r"[a-zA-Z0-9./:_@-]+", value):
        raise argparse.ArgumentTypeError("Invalid image reference")
    if "@sha256:" in value:
        if not re.fullmatch(r".+@sha256:[0-9a-f]{64}", value):
            raise argparse.ArgumentTypeError("Invalid SHA-256 image digest")
    elif ":" not in value.rsplit("/", 1)[-1] or value.endswith(":latest"):
        raise argparse.ArgumentTypeError("Specify a version tag or digest; latest is unsupported")
    return value


def positive(value: str) -> int:
    number = int(value)
    if not 1 <= number <= 100:
        raise argparse.ArgumentTypeError("Expected an integer from 1 to 100")
    return number


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("mode", choices=("render", "deploy"))
    for name in ("name", "namespace", "configmap", "secret", "revision"):
        result.add_argument(f"--{name}", required=True, type=dns_name)
    result.add_argument("--image", required=True, type=image_reference)
    result.add_argument("--context", help="Required for deployment; never use an implicit cluster")
    result.add_argument("--replicas", type=positive, default=2)
    result.add_argument("--worker", action="store_true", help="Add a Laravel queue worker Deployment")
    result.add_argument("--image-pull-secret", type=dns_name)
    result.add_argument("--readiness-path", default="/up")
    return result


def resources(args: argparse.Namespace) -> list[dict]:
    if not re.fullmatch(r"/[a-zA-Z0-9/_-]*", args.readiness_path):
        raise ValueError("Readiness path must be an absolute HTTP path")
    labels = {"app.kubernetes.io/name": args.name, "app.kubernetes.io/managed-by": "laraship"}

    def metadata(name: str, role: str) -> dict:
        return {"name": name, "namespace": args.namespace,
                "labels": {**labels, "app.kubernetes.io/component": role}}

    container = {
        "name": "app", "image": args.image, "imagePullPolicy": "IfNotPresent",
        "envFrom": [{"configMapRef": {"name": args.configmap}}, {"secretRef": {"name": args.secret}}],
        "env": [{"name": "APP_ENV", "value": "production"}, {"name": "APP_DEBUG", "value": "false"},
                {"name": "LOG_CHANNEL", "value": "stderr"}],
        "securityContext": {"allowPrivilegeEscalation": False, "readOnlyRootFilesystem": True,
                            "capabilities": {"drop": ["ALL"]}},
        # Starting values, not production sizing; measured workloads must tune them.
        "resources": {"requests": {"cpu": "100m", "memory": "128Mi"},
                      "limits": {"cpu": "1", "memory": "512Mi"}},
        "volumeMounts": [{"name": "tmp", "mountPath": "/tmp"},
                         {"name": "storage", "mountPath": "/app/storage"},
                         {"name": "cache", "mountPath": "/app/bootstrap/cache"}],
    }
    pod = {
        "automountServiceAccountToken": False, "terminationGracePeriodSeconds": 60,
        "securityContext": {"runAsNonRoot": True, "runAsUser": 1000, "runAsGroup": 1000,
                            "fsGroup": 1000, "seccompProfile": {"type": "RuntimeDefault"}},
        "containers": [container],
        "volumes": [{"name": name, "emptyDir": {"sizeLimit": "256Mi"}}
                    for name in ("tmp", "storage", "cache")],
    }
    if args.image_pull_secret:
        pod["imagePullSecrets"] = [{"name": args.image_pull_secret}]
    migration_pod = copy.deepcopy(pod)
    migration_pod["restartPolicy"] = "Never"
    migration_pod["containers"][0]["args"] = ["php", "artisan", "migrate", "--force", "--no-interaction"]
    job_policy = {"backoffLimit": 0, "activeDeadlineSeconds": 300, "parallelism": 1,
                  "completions": 1, "completionMode": "NonIndexed", "suspend": False,
                  "podReplacementPolicy": "Failed"}
    fingerprint = hashlib.sha256(json.dumps([args.revision, migration_pod, job_policy], sort_keys=True).encode()).hexdigest()[:12]
    job_name = f"{args.name}-migrate-{fingerprint}"
    job = {"apiVersion": "batch/v1", "kind": "Job", "metadata": metadata(job_name, "migration"),
           "spec": {**job_policy,
                    "template": {"metadata": {"labels": metadata(job_name, "migration")["labels"]},
                                 "spec": migration_pod}}}

    def deployment(role: str, spec: dict, replicas: int) -> dict:
        selector = {"app.kubernetes.io/name": args.name, "app.kubernetes.io/component": role}
        return {"apiVersion": "apps/v1", "kind": "Deployment", "metadata": metadata(f"{args.name}-{role}", role),
                "spec": {"replicas": replicas, "progressDeadlineSeconds": 300,
                         "selector": {"matchLabels": selector},
                         "template": {"metadata": {"labels": {**labels, **selector},
                                                   "annotations": {"laraship/revision": args.revision}}, "spec": spec}}}

    web_pod = copy.deepcopy(pod)
    web = web_pod["containers"][0]
    web["ports"] = [{"name": "http", "containerPort": 8080}]
    web["livenessProbe"] = {"httpGet": {"path": "/_laraship/live", "port": "http"},
                            "periodSeconds": 10, "timeoutSeconds": 2}
    web["readinessProbe"] = {"httpGet": {"path": args.readiness_path, "port": "http"},
                             "periodSeconds": 5, "timeoutSeconds": 3}
    web["startupProbe"] = {"httpGet": {"path": "/_laraship/live", "port": "http"},
                           "periodSeconds": 5, "failureThreshold": 60, "timeoutSeconds": 2}
    result = [job, deployment("web", web_pod, args.replicas),
              {"apiVersion": "v1", "kind": "Service", "metadata": metadata(args.name, "web"),
               "spec": {"selector": {"app.kubernetes.io/name": args.name, "app.kubernetes.io/component": "web"},
                        "ports": [{"name": "http", "port": 80, "targetPort": "http"}], "type": "ClusterIP"}}]
    worker_pod = copy.deepcopy(pod)
    worker_pod["containers"][0]["args"] = ["php", "artisan", "queue:work", "--sleep=3", "--tries=3", "--timeout=45", "--max-time=3600"]
    result.append(deployment("worker", worker_pod, 1 if args.worker else 0))
    return result


def kubectl(args: argparse.Namespace, command: list[str], document: dict | None = None) -> str:
    request_timeout = "330s" if command[0] in ("wait", "rollout") else "15s"
    invocation = ["kubectl", "--context", args.context, "--namespace", args.namespace,
                  "--cache-dir=/tmp/laraship-kubectl-cache", f"--request-timeout={request_timeout}", *command]
    result = subprocess.run(invocation, input=json.dumps(document) if document is not None else None,
                            capture_output=True, text=True, timeout=340, check=False)
    if result.returncode:
        # Do not dump API resource bodies (they may contain credentials).
        raise RuntimeError(f"kubectl {command[0]} failed; verify context, permissions and resource status")
    return result.stdout


def validate_configuration(args: argparse.Namespace) -> None:
    config = json.loads(kubectl(args, ["get", "configmap", args.configmap, "-o", "json"]))
    secret = json.loads(kubectl(args, ["get", "secret", args.secret, "-o", "json"]))
    if config.get("immutable") is not True or secret.get("immutable") is not True:
        raise ValueError("ConfigMap and Secret must be immutable with versioned names; create new objects for every configuration change")
    data = config.get("data", {})
    if any(re.search(r"PASSWORD|SECRET|TOKEN|^APP_KEY$", key) for key in data):
        raise ValueError("Place credentials in Secret, not ConfigMap")
    if not secret.get("data", {}).get("APP_KEY"):
        raise ValueError("Application Secret must contain APP_KEY")
    if data.get("DB_CONNECTION") not in ("pgsql", "mysql") or not data.get("DB_HOST"):
        raise ValueError("Configure an external PostgreSQL/MySQL endpoint in ConfigMap")
    if args.replicas > 1:
        for key in ("SESSION_DRIVER", "CACHE_STORE", "FILESYSTEM_DISK"):
            if key in secret.get("data", {}):
                raise ValueError(f"Configure {key} in ConfigMap; do not override the shared-state driver in Secret")
            if data.get(key) in (None, "", "file", "local", "public", "array"):
                raise ValueError(f"Multiple replicas require external state; configure {key} explicitly")


def validate_owned_resources(args: argparse.Namespace) -> None:
    for kind, name in (("deployment", f"{args.name}-web"), ("deployment", f"{args.name}-worker"), ("service", args.name)):
        raw = kubectl(args, ["get", kind, name, "--ignore-not-found", "-o", "json"])
        if raw and json.loads(raw)["metadata"].get("labels", {}).get("app.kubernetes.io/managed-by") != "laraship":
            raise ValueError(f"Refusing to adopt existing {kind}/{name} owned by another deployment tool")


def acquire_lock(args: argparse.Namespace, token: str) -> dict:
    name = f"{args.name}-deploy-lock"
    lease = {"apiVersion": "coordination.k8s.io/v1", "kind": "Lease",
             "metadata": {"name": name, "namespace": args.namespace,
                          "labels": {"app.kubernetes.io/managed-by": "laraship"}}, "spec": {"holderIdentity": token}}
    try:
        return json.loads(kubectl(args, ["create", "-f", "-", "-o", "json"], lease))
    except RuntimeError:
        existing = json.loads(kubectl(args, ["get", "lease", name, "-o", "json"]))
        if existing.get("metadata", {}).get("labels", {}).get("app.kubernetes.io/managed-by") != "laraship":
            raise ValueError(f"Refusing to adopt foreign deployment Lease {name}")
        if existing.get("spec", {}).get("holderIdentity"):
            raise ValueError(f"Deployment lock {name} is held; retry when it finishes. After a crashed runner, verify it stopped before clearing the Lease")
        existing["spec"]["holderIdentity"] = token
        # resourceVersion compare-and-swap: a competing writer fails closed.
        return json.loads(kubectl(args, ["replace", "-f", "-", "-o", "json"], existing))


def validate_existing_job(existing: dict, expected: dict) -> None:
    # API defaults may add fields; compare every expected field, not just the image.
    def contains(actual, wanted):
        if isinstance(wanted, dict):
            return isinstance(actual, dict) and all(key in actual and contains(actual[key], value) for key, value in wanted.items())
        if isinstance(wanted, list):
            return isinstance(actual, list) and len(actual) == len(wanted) and all(contains(a, e) for a, e in zip(actual, wanted))
        return actual == wanted

    actual_spec = existing["spec"]
    expected_spec = expected["spec"]
    controller = {key: value for key, value in expected_spec.items() if key != "template"}
    unsupported = ("ttlSecondsAfterFinished", "successPolicy", "podFailurePolicy", "backoffLimitPerIndex", "maxFailedIndexes")
    if (not contains(existing["metadata"].get("labels", {}), expected["metadata"]["labels"])
            or not contains(actual_spec, controller)
            or not contains(actual_spec["template"].get("metadata", {}).get("labels", {}), expected_spec["template"]["metadata"]["labels"])
            or not contains(actual_spec["template"]["spec"], expected_spec["template"]["spec"])
            or actual_spec["template"]["spec"]["containers"][0].get("command")
            or actual_spec.get("manualSelector", False)
            or actual_spec.get("managedBy") not in (None, "kubernetes.io/job-controller")
            or any(key in actual_spec for key in unsupported)):
        raise ValueError("Existing migration Job does not match this release's runtime contract")


def deploy(args: argparse.Namespace, items: list[dict]) -> None:
    if not args.context:
        raise ValueError("Deployment requires --context")
    validate_configuration(args)
    token = str(uuid.uuid4())
    lease = acquire_lock(args, token)
    migration_started = False
    migration_complete = False
    rollout_complete = False
    try:
        validate_owned_resources(args)
        job = items[0]
        name = job["metadata"]["name"]
        # Create once per revision. An existing failed Job stays failed; never delete it to retry implicitly.
        try:
            migration_started = True
            kubectl(args, ["create", "-f", "-"], job)
        except RuntimeError:
            existing = json.loads(kubectl(args, ["get", "job", name, "-o", "json"]))
            validate_existing_job(existing, job)
        kubectl(args, ["wait", "--for=condition=complete", f"job/{name}", "--timeout=310s"])
        migration_complete = True
        kubectl(args, ["apply", "-f", "-"], {"apiVersion": "v1", "kind": "List", "items": items[1:]})
        for item in items:
            if item["kind"] == "Deployment":
                kubectl(args, ["rollout", "status", f"deployment/{item['metadata']['name']}", "--timeout=310s"])
        rollout_complete = True
        print(f"Deployment ready: {args.namespace}/{args.name} (revision {args.revision})")
    finally:
        if migration_started and (not migration_complete or not rollout_complete):
            print("Migration or rollout completion is unconfirmed; Lease retained. Verify the Job and rollout state before manually clearing the lock", file=sys.stderr)
        else:
            try:
                current = json.loads(kubectl(args, ["get", "lease", lease["metadata"]["name"], "-o", "json"]))
                if current["metadata"]["uid"] == lease["metadata"]["uid"] and current.get("spec", {}).get("holderIdentity") == token:
                    current["spec"]["holderIdentity"] = ""
                    kubectl(args, ["replace", "-f", "-"], current)
            except (RuntimeError, KeyError, json.JSONDecodeError):
                print("Deployment lock could not be released; inspect the Lease before retrying", file=sys.stderr)


def main() -> int:
    args = parser().parse_args()
    try:
        items = resources(args)
        if args.mode == "render":
            print(json.dumps({"apiVersion": "v1", "kind": "List", "items": items}, indent=2))
        else:
            deploy(args, items)
    except (ValueError, RuntimeError, KeyError, OSError, subprocess.SubprocessError) as exc:
        print(f"Kubernetes operation failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
