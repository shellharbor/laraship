#!/usr/bin/env python3
"""Validate the Linux Compose adapter before it can modify shared server state."""
import json
import os
from pathlib import Path
import re
import subprocess
import sys


def main() -> int:
    if os.geteuid() != 0:
        raise ValueError("Compose operations require root")
    if os.environ.get("DOCKER_HOST", "unix:///var/run/docker.sock") != "unix:///var/run/docker.sock":
        raise ValueError("Only the local Linux Docker socket is supported")
    # Host networking inherits the host hostname. Identify this container through
    # Docker's generated hostname/hosts bind instead of accidentally inspecting the host.
    mountinfo = Path("/proc/self/mountinfo").read_text(encoding="utf-8")
    identities = set(re.findall(r"/containers/([0-9a-f]{64})/(?:hostname|hosts)(?=\s)", mountinfo))
    if len(identities) != 1:
        raise ValueError("Cannot identify this Docker container; keep Docker's generated hostname/hosts files")
    identifier = identities.pop()
    result = subprocess.run(["docker", "inspect", identifier], check=True,
                            capture_output=True, text=True, timeout=15)
    container = json.loads(result.stdout)[0]
    if container["HostConfig"]["NetworkMode"] != "host":
        raise ValueError("Host networking is required for server port and HTTP checks")
    mounts = {item["Destination"]: item for item in container["Mounts"]}
    for path in ("/var/www", "/run/lock/laraship", "/var/run/docker.sock"):
        item = mounts.get(path, {})
        if item.get("Type") != "bind" or item.get("Source") != path or not item.get("RW"):
            raise ValueError(f"Required writable, identical host bind: {path}")
    archive_path = os.environ.get("LARASHIP_ARCHIVE_DIR", "/var/backups/laraship")
    output = mounts.get(archive_path, {})
    if output.get("Type") != "bind" or output.get("Source") != archive_path or not output.get("RW"):
        raise ValueError("Archive directory requires a writable, identical host bind")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (ValueError, KeyError, OSError, subprocess.SubprocessError, json.JSONDecodeError) as exc:
        print(f"Container preflight: {exc}", file=sys.stderr)
        sys.exit(1)
