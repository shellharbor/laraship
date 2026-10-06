#!/usr/bin/env python3
"""Behavioral tests for Kubernetes input, state, locks and migration ordering."""
import contextlib
import copy
import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("laraship_k8s", Path(__file__).resolve().parents[1] / "kubernetes/laraship.py")
k8s = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(k8s)


def arguments(*extra):
    return k8s.parser().parse_args(["render", "--name", "test", "--namespace", "apps", "--image", "app:1.0",
                                   "--configmap", "test-config", "--secret", "test-secret", "--revision", "v1", *extra])


class KubernetesTests(unittest.TestCase):
    def test_invalid_names_and_unversioned_images_fail(self):
        for extra in (("--name", "../escape"), ("--image", "app:latest"), ("--image", "registry/app"),
                      ("--image", "app@sha256:short"), ("--replicas", "0")):
            with self.subTest(extra=extra), contextlib.redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
                arguments(*extra)

    def test_web_is_replaceable_nonroot_and_has_no_host_access(self):
        items = k8s.resources(arguments("--worker"))
        for item in items:
            if item["kind"] not in ("Deployment", "Job"):
                continue
            pod = item["spec"]["template"]["spec"]
            self.assertFalse(pod["automountServiceAccountToken"])
            self.assertTrue(pod["securityContext"]["runAsNonRoot"])
            self.assertTrue(all("hostPath" not in volume for volume in pod["volumes"]))
            app = pod["containers"][0]
            self.assertTrue(app["securityContext"]["readOnlyRootFilesystem"])
            self.assertNotIn("docker.sock", json.dumps(pod))
        web = items[1]["spec"]["template"]["spec"]["containers"][0]
        self.assertNotEqual(web["readinessProbe"]["httpGet"]["path"], web["livenessProbe"]["httpGet"]["path"])
        self.assertNotIn("migrate", json.dumps(items[1]["spec"]["template"]))

    def test_migration_identity_changes_with_revision_or_image(self):
        name = lambda args: k8s.resources(args)[0]["metadata"]["name"]
        self.assertEqual(name(arguments()), name(arguments()))
        self.assertNotEqual(name(arguments()), name(arguments("--revision", "v2")))
        self.assertNotEqual(name(arguments()), name(arguments("--image", "app:2.0")))

    def test_deployment_requires_explicit_context(self):
        with patch.object(k8s, "kubectl") as client, self.assertRaisesRegex(ValueError, "--context"):
            args = arguments()
            k8s.deploy(args, k8s.resources(args))
        client.assert_not_called()

    def test_replicas_reject_local_state_and_credentials_in_configmap(self):
        for data in ({"SESSION_DRIVER": "file"}, {"DB_PASSWORD": "fixture-only"}):
            with self.subTest(data=data), patch.object(k8s, "kubectl", side_effect=[json.dumps({"immutable": True, "data": {"DB_CONNECTION": "pgsql", "DB_HOST": "db", **data}}), json.dumps({"immutable": True, "data": {"APP_KEY": "test"}})]):
                with self.assertRaises(ValueError):
                    k8s.validate_configuration(arguments())

    def test_external_state_and_existing_secret_are_accepted(self):
        with patch.object(k8s, "kubectl", side_effect=[json.dumps({"immutable": True, "data": {"DB_CONNECTION": "pgsql", "DB_HOST": "db", "SESSION_DRIVER": "database", "CACHE_STORE": "database", "FILESYSTEM_DISK": "s3"}}), json.dumps({"immutable": True, "data": {"APP_KEY": "test"}})]):
            k8s.validate_configuration(arguments())

    def test_mutable_configuration_is_rejected(self):
        with patch.object(k8s, "kubectl", side_effect=['{}', '{"data":{"APP_KEY":"test"}}']):
            with self.assertRaisesRegex(ValueError, "immutable"):
                k8s.validate_configuration(arguments())

    def test_disabling_worker_reconciles_to_zero_replicas(self):
        worker = k8s.resources(arguments())[-1]
        self.assertEqual(worker["metadata"]["name"], "test-worker")
        self.assertEqual(worker["spec"]["replicas"], 0)

    def test_long_wait_has_matching_request_and_process_timeouts(self):
        import subprocess
        with patch.object(k8s.subprocess, "run", return_value=subprocess.CompletedProcess([], 0, "")) as client:
            k8s.kubectl(arguments("--context", "test-cluster"), ["wait", "--timeout=310s"])
        self.assertIn("--request-timeout=330s", client.call_args.args[0])
        self.assertEqual(client.call_args.kwargs["timeout"], 340)

    def test_failed_migration_does_not_apply_web_and_retains_lock(self):
        calls = []
        lease = {"metadata": {"name": "test-deploy-lock", "uid": "one"}, "spec": {"holderIdentity": "token"}}

        def client(args, command, document=None):
            calls.append(command)
            if command[0] == "wait":
                raise RuntimeError("migration failed")
            if command[:2] == ["get", "lease"]:
                return json.dumps(lease)
            return ""

        args = arguments("--context", "test-cluster")
        with patch.object(k8s, "validate_configuration"), patch.object(k8s, "acquire_lock", return_value=lease), patch.object(k8s.uuid, "uuid4", return_value="token"), patch.object(k8s, "kubectl", side_effect=client):
            with self.assertRaisesRegex(RuntimeError, "migration failed"):
                k8s.deploy(args, k8s.resources(args))
        self.assertFalse(any(call[0] == "apply" for call in calls))
        self.assertFalse(any(call[0] == "replace" for call in calls))

    def test_competing_runner_cannot_steal_lease(self):
        with patch.object(k8s, "kubectl", side_effect=[RuntimeError("exists"), json.dumps({"metadata": {"labels": {"app.kubernetes.io/managed-by": "laraship"}}, "spec": {"holderIdentity": "other"}})]) as client:
            with self.assertRaisesRegex(ValueError, "is held"):
                k8s.acquire_lock(arguments(), "mine")
            self.assertEqual(client.call_count, 2)

    def test_idle_lease_uses_resource_version_compare_and_swap(self):
        existing = {"metadata": {"resourceVersion": "42", "labels": {"app.kubernetes.io/managed-by": "laraship"}}, "spec": {"holderIdentity": ""}}
        with patch.object(k8s, "kubectl", side_effect=[RuntimeError("exists"), json.dumps(existing), json.dumps(existing)]) as client:
            k8s.acquire_lock(arguments(), "mine")
            replacement = client.call_args.args[2]
            self.assertEqual(replacement["metadata"]["resourceVersion"], "42")
            self.assertEqual(replacement["spec"]["holderIdentity"], "mine")

    def test_foreign_resources_are_not_adopted(self):
        with patch.object(k8s, "kubectl", return_value=json.dumps({"metadata": {"labels": {"app.kubernetes.io/managed-by": "other"}}})):
            with self.assertRaisesRegex(ValueError, "Refusing to adopt"):
                k8s.validate_owned_resources(arguments())

    def test_reused_job_rejects_altered_execution_policy_before_rollout(self):
        args = arguments("--context", "test-cluster")
        job = k8s.resources(args)[0]
        for change in ({"parallelism": 2}, {"completions": 2}, {"backoffLimit": 3},
                       {"activeDeadlineSeconds": 600}, {"ttlSecondsAfterFinished": 0},
                       {"suspend": True}, {"manualSelector": True}, {"managedBy": "other/controller"},
                       {"podReplacementPolicy": "TerminatingOrFailed"}):
            existing = copy.deepcopy(job)
            existing["spec"].update(change)
            calls = []

            def client(_args, command, document=None):
                calls.append(command)
                if command[0] == "create":
                    raise RuntimeError("exists")
                if command[:2] == ["get", "job"]:
                    return json.dumps(existing)
                return ""

            with self.subTest(change=change), patch.object(k8s, "validate_configuration"), patch.object(k8s, "acquire_lock", return_value={}), patch.object(k8s, "kubectl", side_effect=client), contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaisesRegex(ValueError, "runtime contract"):
                    k8s.deploy(args, k8s.resources(args))
            self.assertFalse(any(call[0] in ("apply", "wait", "replace") for call in calls))

    def test_reused_job_accepts_api_defaults_without_command_override(self):
        job = k8s.resources(arguments())[0]
        existing = copy.deepcopy(job)
        existing["spec"]["manualSelector"] = False
        existing["spec"]["template"]["spec"]["dnsPolicy"] = "ClusterFirst"
        k8s.validate_existing_job(existing, job)
        existing["spec"]["template"]["spec"]["containers"][0]["command"] = ["sh", "-c", "exit 0"]
        with self.assertRaisesRegex(ValueError, "runtime contract"):
            k8s.validate_existing_job(existing, job)
        existing = copy.deepcopy(job)
        existing["spec"]["template"]["metadata"]["labels"]["app.kubernetes.io/component"] = "web"
        with self.assertRaisesRegex(ValueError, "runtime contract"):
            k8s.validate_existing_job(existing, job)


if __name__ == "__main__":
    unittest.main()
