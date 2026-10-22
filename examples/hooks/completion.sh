#!/usr/bin/env bash
# Store stdin privately; passwords may have been explicitly enabled in the report.
set -euo pipefail
umask 077
DIRECTORY=/var/log/laraship-completion
[[ ! -L "$DIRECTORY" ]] || exit 1
install -d -m 700 "$DIRECTORY"
[[ "$(stat -c %u "$DIRECTORY")" == "$EUID" ]] || exit 1
REPORT="$(mktemp "$DIRECTORY/deploy.XXXXXXXX.json")"
cat > "$REPORT"
