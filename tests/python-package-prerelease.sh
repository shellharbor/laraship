#!/usr/bin/env bash
# Check PEP 440 distribution identity without changing the checkout's VERSION.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/laraship-prerelease.XXXXXX")"
trap 'rm -rf -- "$WORK"' EXIT

mkdir -p "$WORK/project/src" "$WORK/project/docs"
cp -R "$ROOT/src/laraship" "$WORK/project/src/"
cp "$ROOT/pyproject.toml" "$ROOT/.gitignore" "$WORK/project/"
cp "$ROOT/docs/PYTHON.md" "$WORK/project/docs/"
printf '1.3.0-rc.1\n' > "$WORK/project/VERSION"

python3 -m build --outdir "$WORK/dist" "$WORK/project"
python3 "$ROOT/.github/scripts/check-python-dist.py" "$WORK/dist" 1.3.0-rc.1
python3 -m venv "$WORK/venv"
"$WORK/venv/bin/python" -m pip install --no-deps "$WORK"/dist/*.whl
OUTPUT="$("$WORK/venv/bin/laraship" install --backend docker --dry-run)"
[[ "$OUTPUT" == *"shellharbor/laraship:1.3.0-rc.1"* ]]
printf 'Prerelease metadata and exact runtime release spelling verified.\n'
