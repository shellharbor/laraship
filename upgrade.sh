#!/usr/bin/env bash
# Managed Laravel/PHP/Filament upgrades. Planning is read-only; prepare/apply are explicit.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
if ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' 2>/dev/null; then
    echo 'LaraShip upgrade requires Python 3.10 or newer; use the matching Docker CLI image if unavailable.' >&2
    exit 1
fi
exec python3 "$SCRIPT_DIR/lib/upgrade.py" "$@"
