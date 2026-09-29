#!/usr/bin/env bats
# Статические проверки: не требуют root и Docker.

load helpers

@test "все скрипты проходят bash -n" {
    for f in "${SCRIPTS[@]}"; do
        run bash -n "${REPO_ROOT}/${f}"
        [ "${status}" -eq 0 ] || { echo "${f}: ${output}" >&2; return 1; }
    done
}

@test "в скриптах и шаблонах нет CRLF" {
    run grep -rlI $'\r' \
        "${REPO_ROOT}"/*.sh "${REPO_ROOT}/laravel" "${REPO_ROOT}/nginxproxy"
    [ "${status}" -eq 1 ] || { echo "CRLF в: ${output}" >&2; return 1; }
}

@test "у скриптов есть shebang" {
    for f in "${SCRIPTS[@]}"; do
        run head -n1 "${REPO_ROOT}/${f}"
        [[ "${output}" == '#!'*bash* ]] || { echo "${f}: ${output}" >&2; return 1; }
    done
}

@test "шаблоны на месте: laravel/ и nginxproxy/" {
    for p in laravel/docker-compose.yml laravel/.config laravel/.docker \
             nginxproxy/nginx.conf nginxproxy/nginx.Dockerfile nginxproxy/site-template.conf; do
        [ -e "${REPO_ROOT}/${p}" ] || { echo "нет ${p}" >&2; return 1; }
    done
}

@test "--help печатает справку и выходит с кодом 0 (даже без root)" {
    run bash "${DEPLOY}" --help
    [ "${status}" -eq 0 ]
    for flag in --domain --db-type --slug --ssl-email --no-ssl --install-filament \
                --enable-basic-auth --db-native --create-backup --endpoint; do
        [[ "${output}" == *"${flag}"* ]] || { echo "в справке нет ${flag}" >&2; return 1; }
    done
}

@test "каждый флаг из parse_args описан в справке" {
    local flags flag
    flags="$(grep -oE '^\s+--[a-z0-9-]+\)' "${DEPLOY}" | tr -d ' )' | sort -u)"
    [ -n "${flags}" ]
    help="$(bash "${DEPLOY}" --help)"
    for flag in ${flags}; do
        # --type (совместимость) и --obtain-ssl (поведение по умолчанию) намеренно
        # не указаны в --help; README это оговаривает.
        case "${flag}" in --type|--obtain-ssl) continue ;; esac
        [[ "${help}" == *"${flag}"* ]] || { echo "флаг ${flag} не описан в --help" >&2; return 1; }
    done
}

@test "docker-compose шаблона проекта содержит нужные сервисы" {
    for svc in php nginx redis cron certbot_renew artisan composer npm permissions; do
        grep -qE "^  ${svc}:" "${REPO_ROOT}/laravel/docker-compose.yml" \
            || { echo "нет сервиса ${svc}" >&2; return 1; }
    done
}
