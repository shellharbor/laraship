#!/usr/bin/env python3
"""Deliver a deployment completion snapshot without logging its private values."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import time
import uuid

from endpoint import validate_url


def snapshot(raw: bytes) -> dict[str, str]:
    if len(raw) > 1024 * 1024:
        raise ValueError("Completion snapshot exceeds the size limit")
    fields = raw.decode("utf-8").split("\0")
    if fields.pop() != "" or len(fields) % 2:
        raise ValueError("Completion snapshot must contain NUL-terminated key/value pairs")
    values = dict(zip(fields[::2], fields[1::2]))
    if len(values) != len(fields) // 2:
        raise ValueError("Completion snapshot contains duplicate keys")
    return values


def trusted_file(value: str, *, executable: bool = False) -> Path:
    path = Path(value)
    if not path.is_absolute() or ".." in path.parts:
        raise ValueError("Completion files require absolute paths without '..'")
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
        raise ValueError("Completion files must be regular files owned by the invoking user")
    if info.st_mode & 0o022 or not os.access(path, os.R_OK):
        raise ValueError("Completion files must be readable and not group/other writable")
    if executable and not os.access(path, os.X_OK):
        raise ValueError("The completion script must be executable")
    if not executable and info.st_mode & 0o077:
        raise ValueError("Completion token files must be private (mode 600 or stricter)")
    for parent in path.parents:
        parent_info = parent.lstat()
        if not stat.S_ISDIR(parent_info.st_mode) or parent_info.st_uid not in (0, os.geteuid()):
            raise ValueError("Completion file parents must be trusted real directories")
        shared_temporary = parent_info.st_uid == 0 and parent_info.st_mode & stat.S_ISVTX
        if parent_info.st_mode & 0o022 and not shared_temporary:
            raise ValueError("Completion file parents must not be group/other writable")
    return path


def bearer_token(value: str) -> str | None:
    if not value:
        return None
    path = trusted_file(value)
    if path.stat().st_size > 8192:
        raise ValueError("Completion token file exceeds the size limit")
    token = path.read_text(encoding="ascii").rstrip("\r\n")
    if not token or any(character.isspace() or ord(character) < 33 or ord(character) == 127 for character in token):
        raise ValueError("Completion token file must contain a single nonempty token")
    return token


def validate(values: dict[str, str]) -> None:
    hook, url = values.get("ON_COMPLETE", ""), values.get("COMPLETION_ENDPOINT", "")
    if not hook and not url:
        raise ValueError("Completion options require --on-complete or --completion-endpoint")
    timeout = values.get("COMPLETION_TIMEOUT", "30")
    if not timeout.isascii() or not timeout.isdecimal() or not 1 <= int(timeout) <= 300:
        raise ValueError("Completion timeout must be an integer from 1 to 300 seconds")
    if hook:
        trusted_file(hook, executable=True)
    if url:
        validate_url(url, allow_http=values.get("ALLOW_INSECURE_ENDPOINT") == "true")
    if values.get("COMPLETION_TOKEN_FILE") and not url:
        raise ValueError("--completion-token-file requires --completion-endpoint")
    bearer_token(values.get("COMPLETION_TOKEN_FILE", ""))


def build_report(values: dict[str, str]) -> dict:
    def text(key):
        return values.get(key) or None

    def boolean(key):
        return values.get(key) == "true"

    def port(key):
        value = values.get(key, "")
        return int(value) if value.isdecimal() else None

    code = int(values["COMPLETION_EXIT_CODE"])
    interrupted = text("RUNTIME_LAST_SIGNAL")
    started = int(values["COMPLETION_STARTED_EPOCH"])
    ended = time.time()
    database = values.get("DB_TYPE", "")
    db_prefix = "DB_POSTGRES" if database == "postgres" else "DB_MYSQL"
    slug, domain = text("SLUG"), text("DOMAIN")
    report = {
        "schema_version": 1, "run_id": str(uuid.uuid4()), "operation": "deploy",
        "status": "cancelled" if interrupted else ("success" if code == 0 else "failed"),
        "exit_code": code, "signal": interrupted, "stage": text("COMPLETION_STAGE"),
        "toolkit_version": text("SCRIPT_VERSION"),
        "started_at": datetime.fromtimestamp(started, timezone.utc).isoformat(),
        "finished_at": datetime.fromtimestamp(ended, timezone.utc).isoformat(),
        "duration_seconds": max(0, round(ended - started, 3)),
        "project": {"slug": slug, "domain": domain,
                    "path": f"{values.get('WWW_DIR', '/var/www')}/{slug}" if slug else None,
                    "url": f"{values.get('SITE_SCHEME') or 'http'}://{domain}" if domain else None,
                    "laravel_version": text("LARAVEL_VERSION")},
        "ports": {name: port(f"PORT_{name.upper()}") for name in ("http", "https", "php", "redis")},
        "database": {"type": database or None, "native": boolean("DB_NATIVE"),
                     "port": port("PORT_POSTGRES" if database == "postgres" else "PORT_MYSQL"),
                     "name": text(db_prefix + "_NAME"), "user": text(db_prefix + "_USER")},
        "basic_auth": {"enabled": boolean("ENABLE_BASIC_AUTH"), "user": text("AUTH_USER")},
        "filament": {"requested": boolean("COMPLETION_FILAMENT"), "email": text("FILAMENT_EMAIL"),
                     "name": text("FILAMENT_NAME")},
        "ssl": {"requested": boolean("OBTAIN_SSL"), "enabled": values.get("SITE_SCHEME") == "https"},
        "readiness": {"http_checked": boolean("COMPLETION_HTTP_READY"),
                      "proxy_registered": boolean("COMPLETION_PROXY_READY")},
        "archive_path": text("BACKUP_FILE_PATH"),
        "secrets_included": boolean("COMPLETION_INCLUDE_SECRETS"),
    }
    if report["secrets_included"]:
        report["database"]["password"] = text(db_prefix + "_PASSWORD")
        report["redis"] = {"password": text("REDIS_PASSWORD")}
        if report["basic_auth"]["enabled"]:
            report["basic_auth"]["password"] = text("AUTH_PASSWORD")
        if report["filament"]["requested"]:
            report["filament"]["password"] = text("FILAMENT_PASSWORD")
    return report


def bounded_process(command: list[str], *, data: bytes, timeout: int, capture_status: bool = False) -> tuple[int, bytes]:
    """Kill the callback's process group on timeout; discard all raw diagnostics."""
    with subprocess.Popen(command, stdin=subprocess.PIPE,
                          stdout=subprocess.PIPE if capture_status else subprocess.DEVNULL,
                          stderr=subprocess.DEVNULL, start_new_session=True) as process:
        try:
            output, _ = process.communicate(data, timeout=timeout)
            return process.returncode, output or b""
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
            return 124, b""


def deliver(values: dict[str, str]) -> None:
    report = build_report(values)
    body = (json.dumps(report, ensure_ascii=False) + "\n").encode("utf-8")
    timeout = int(values["COMPLETION_TIMEOUT"])
    if values.get("ON_COMPLETE"):
        try:
            path = trusted_file(values["ON_COMPLETE"], executable=True)
            # A hook's output can contain credentials; never capture or print it.
            result, _ = bounded_process([str(path)], data=body, timeout=timeout)
            print("Completion script finished" if result == 0 else "Completion script failed or timed out")
        except (OSError, ValueError):
            print("Completion script could not be executed")
    if values.get("COMPLETION_ENDPOINT"):
        try:
            url = values["COMPLETION_ENDPOINT"]
            allow_http = values.get("ALLOW_INSECURE_ENDPOINT") == "true"
            validate_url(url, allow_http=allow_http)
            token = bearer_token(values.get("COMPLETION_TOKEN_FILE", ""))
            configuration = f"url = {json.dumps(url, ensure_ascii=False)}\ndata-binary = {json.dumps(body.decode(), ensure_ascii=False)}\n"
            if token:
                configuration += f"header = {json.dumps('Authorization: Bearer ' + token)}\n"
            command = ["curl", "-q", "--globoff", "--config", "-", "--proto", "=https,http" if allow_http else "=https",
                       "--proto-redir", "=https", "--no-location", "--connect-timeout", str(min(5, timeout)),
                       "--max-time", str(timeout), "--request", "POST", "--header", "Content-Type: application/json",
                       "--header", f"Idempotency-Key: {report['run_id']}", "--output", "/dev/null",
                       "--write-out", "%{http_code}", "--silent"]
            result, output = bounded_process(command, data=configuration.encode("utf-8"), timeout=timeout + 2,
                                             capture_status=True)
            code = output.decode("ascii", errors="ignore")
            if result == 0 and len(code) == 3 and code.isdecimal():
                print(f"Completion endpoint {'accepted' if code.startswith('2') else 'rejected'} the report (HTTP {code})")
            else:
                print("Completion endpoint delivery failed or timed out")
        except (OSError, ValueError):
            print("Completion endpoint delivery could not be started")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--validate", action="store_true")
    args = parser.parse_args()
    try:
        values = snapshot(sys.stdin.buffer.read(1024 * 1024 + 1))
        if args.validate:
            validate(values)
        else:
            deliver(values)
    except (OSError, UnicodeError, ValueError, KeyError):
        print("Completion configuration or snapshot is invalid", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
