#!/usr/bin/env bash
set -euo pipefail
ROOT=/opt/laraship
COMMAND="${1:---help}"
shift || true
case "$COMMAND" in
    --help|-h|help)
        cat <<'HELP'
LaraShip: native Bash tools, packaged with their dependencies.
  deploy [arguments]                 deploy-laravel.sh
  update|backup|activate|deactivate|remove|list [arguments]
  kubernetes render|deploy [arguments]  immutable application backend
  --version
Compose operations require the Linux server's Docker socket, host network,
and identical /var/www and /run/lock/laraship bind mounts. See docs/CONTAINERS.md.
HELP
        exit 0 ;;
    --version|-V) exec bash "$ROOT/deploy-laravel.sh" --version ;;
    kubernetes) exec python3 "$ROOT/kubernetes/laraship.py" "$@" ;;
    deploy|deploy-laravel.sh) SCRIPT=deploy-laravel.sh ;;
    list|list-projects.sh) SCRIPT=list-projects.sh ;;
    update|backup|activate|deactivate|remove) SCRIPT="$COMMAND.sh" ;;
    update.sh|backup.sh|activate.sh|deactivate.sh|remove.sh) SCRIPT="$COMMAND" ;;
    *) echo "Unknown LaraShip command: $COMMAND" >&2; exit 2 ;;
esac
# Supported informational commands do not need Docker or host mounts.
for ARG in "$@"; do
    case "$ARG" in --help|-h|--version|-V|--list-modules|--list-presets|--dry-run)
        if [[ "$SCRIPT" == deploy-laravel.sh || ( "$ARG" == --help && ( "$SCRIPT" == update.sh || "$SCRIPT" == backup.sh ) ) ]]; then
            exec bash "$ROOT/$SCRIPT" "$@"
        fi ;;
    esac
done
python3 "$ROOT/docker-preflight.py" || {
    echo "Container Compose preflight failed. Mount the Linux server's /var/www, /run/lock/laraship and Docker socket at identical paths, and use --network host. See docs/CONTAINERS.md." >&2
    exit 1
}
exec bash "$ROOT/$SCRIPT" "$@"
