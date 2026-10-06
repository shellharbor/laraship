#!/usr/bin/env python3
"""Encode the stable endpoint payload from NUL-separated fields on stdin."""
import json
import sys


def build_payload(values: list) -> dict:
    if len(values) != 20:
        raise ValueError("Expected 20 endpoint fields")
    return {
        "slug": values[0], "domain": values[1], "app_type": values[2],
        "laravel_version": values[3], "db_type": values[4],
        "ports": dict(zip(("http", "https", "php", "redis"), map(int, values[5:9]))),
        "redis": {"password": values[9]},
        "database": {"type": values[4], "port": int(values[10]), "name": values[11],
                     "user": values[12], "password": values[13]},
        "basic_auth": {"enabled": values[14] == "true", "user": values[15], "password": values[16]},
        "ssl": {"enabled": values[17] == "true", "email": values[18]},
        "project_path": values[19],
    }


def main() -> int:
    try:
        raw = sys.stdin.buffer.read().decode("utf-8")
        values = raw.split("\0")
        if values[-1] != "":
            raise ValueError("Endpoint fields must end with NUL")
        values.pop()
        print(json.dumps(build_payload(values)))
    except (UnicodeError, ValueError) as exc:
        print(f"Cannot encode endpoint payload: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
