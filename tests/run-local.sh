#!/usr/bin/env bash
# Локальный запуск тестов в изолированной песочнице (нужен только Docker).
#
#   bash tests/run-local.sh            # unit: shellcheck + статика + валидация аргументов
#   bash tests/run-local.sh e2e        # реальный деплой Laravel (PostgreSQL + Filament)
#   E2E_DB=mysql E2E_FILAMENT=0 bash tests/run-local.sh e2e
#   bash tests/run-local.sh all
#
# Песочница работает с --privileged и своим Docker-демоном: контейнеры, сети и порты
# 80/443 создаются внутри неё, Docker хоста не затрагивается. Кэш образов лежит в
# volume laravel-deploy-tests-docker (удалить: docker volume rm laravel-deploy-tests-docker).
set -euo pipefail

MODE="${1:-unit}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Git Bash на Windows: не даём MSYS переписывать пути и берём Windows-путь для -v.
export MSYS_NO_PATHCONV=1
MOUNT="${ROOT}"
if command -v cygpath >/dev/null 2>&1; then
    MOUNT="$(cygpath -w "${ROOT}")"
fi

docker build -q -t laravel-deploy-tests -f "${MOUNT}/tests/Dockerfile" "${MOUNT}" >/dev/null

docker run --rm --privileged \
    -v "${MOUNT}:/repo:ro" \
    -v laravel-deploy-tests-docker:/var/lib/docker \
    -e E2E_DB="${E2E_DB:-postgres}" \
    -e E2E_FILAMENT="${E2E_FILAMENT:-1}" \
    -e E2E_LARAVEL="${E2E_LARAVEL:-}" \
    -e E2E_SSL="${E2E_SSL:-0}" \
    laravel-deploy-tests "${MODE}"
