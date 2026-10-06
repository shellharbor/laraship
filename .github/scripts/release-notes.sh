#!/bin/bash
# Prints the body of the "## <version> ..." section of a changelog, without the heading.
#   bash .github/scripts/release-notes.sh 1.1.0 CHANGELOG.md
# Used by the Release workflow for the GitHub Release description.
set -euo pipefail

VERSION="${1:?usage: release-notes.sh VERSION [CHANGELOG]}"
FILE="${2:-CHANGELOG.md}"

awk -v v="$VERSION" '
    /^## / {
        if (found) { exit }
        if ($2 == v) { found = 1; next }
    }
    found && (started || NF) { started = 1; print }
' "$FILE"
