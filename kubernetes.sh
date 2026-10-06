#!/usr/bin/env bash
# The Kubernetes adapter shares no Docker or host filesystem requirements.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$ROOT/kubernetes/laraship.py" "$@"
