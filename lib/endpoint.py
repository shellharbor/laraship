#!/usr/bin/env python3
"""Validate endpoint URLs and encode private curl input from stdin."""
import argparse
import json
import sys
from urllib.parse import urlsplit


def validate_url(url: str, *, allow_http: bool = False) -> None:
    """Reject unsafe transports and malformed URLs without echoing credentials."""
    if not url or any(character.isspace() or ord(character) < 32 or ord(character) == 127 for character in url):
        raise ValueError("Endpoint must be an absolute URL without whitespace or control characters")
    try:
        parsed = urlsplit(url)
        host, port = parsed.hostname, parsed.port
    except ValueError:
        raise ValueError("Endpoint must be a valid absolute HTTP(S) URL") from None
    if parsed.scheme not in ("http", "https") or not host:
        raise ValueError("Endpoint must be an absolute HTTPS URL")
    if parsed.username is not None or parsed.password is not None:
        raise ValueError("Endpoint must not contain embedded credentials")
    if port is not None and not 1 <= port <= 65535:
        raise ValueError("Endpoint port must be between 1 and 65535")
    if parsed.scheme == "http" and not allow_http:
        raise ValueError("Endpoint requires HTTPS; HTTP needs --allow-insecure-endpoint")


def curl_config(url: str, values: list[str], *, allow_http: bool = False) -> str:
    validate_url(url, allow_http=allow_http)
    payload = json.dumps(build_payload(values))
    # JSON string quoting matches curl's double-quoted configuration escapes.
    # Keep Unicode literal in the outer strings; curl does not decode \u escapes.
    return f"url = {json.dumps(url, ensure_ascii=False)}\ndata-binary = {json.dumps(payload, ensure_ascii=False)}\n"


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
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--validate-url", action="store_true", help="Validate the URL on stdin without printing it")
    modes.add_argument("--curl-config", action="store_true", help="Encode a URL and 20 NUL-separated payload fields")
    parser.add_argument("--allow-http", action="store_true", help="Permit explicitly requested HTTP endpoints")
    args = parser.parse_args()
    try:
        raw = sys.stdin.buffer.read().decode("utf-8")
        if args.validate_url:
            validate_url(raw, allow_http=args.allow_http)
            return 0
        values = raw.split("\0")
        if values[-1] != "":
            raise ValueError("Endpoint fields must end with NUL")
        values.pop()
        if args.curl_config:
            if len(values) != 21:
                raise ValueError("Expected a URL and 20 endpoint fields")
            print(curl_config(values[0], values[1:], allow_http=args.allow_http), end="")
        else:
            print(json.dumps(build_payload(values)))
    except (UnicodeError, ValueError) as exc:
        print(f"Cannot encode endpoint payload: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
