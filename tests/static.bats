#!/usr/bin/env bats
# Static checks: no root and no Docker required.

load helpers

@test "all scripts pass bash -n" {
    for f in "${SCRIPTS[@]}"; do
        run bash -n "${REPO_ROOT}/${f}"
        [ "${status}" -eq 0 ] || { echo "${f}: ${output}" >&2; return 1; }
    done
}

@test "scripts and templates contain no CRLF" {
    run grep -rlI $'\r' \
        "${REPO_ROOT}"/*.sh "${REPO_ROOT}/laravel" "${REPO_ROOT}/nginxproxy"
    [ "${status}" -eq 1 ] || { echo "CRLF in: ${output}" >&2; return 1; }
}

@test "scripts have a shebang" {
    for f in "${SCRIPTS[@]}"; do
        run head -n1 "${REPO_ROOT}/${f}"
        [[ "${output}" == '#!'*bash* ]] || { echo "${f}: ${output}" >&2; return 1; }
    done
}

@test "templates are in place: laravel/ and nginxproxy/" {
    for p in laravel/docker-compose.yml laravel/.config laravel/.docker \
             nginxproxy/nginx.conf nginxproxy/nginx.Dockerfile nginxproxy/site-template.conf; do
        [ -e "${REPO_ROOT}/${p}" ] || { echo "missing ${p}" >&2; return 1; }
    done
}

@test "--help prints the usage and exits with code 0 (even without root)" {
    run bash "${DEPLOY}" --help
    [ "${status}" -eq 0 ]
    for flag in --domain --db-type --slug --ssl-email --no-ssl --install-filament \
                --enable-basic-auth --db-native --create-backup --endpoint; do
        [[ "${output}" == *"${flag}"* ]] || { echo "${flag} is missing from --help" >&2; return 1; }
    done
}

@test "every flag handled in parse_args is described in --help" {
    local flags flag
    flags="$(grep -oE '^\s+--[a-z0-9-]+\)' "${DEPLOY}" | tr -d ' )' | sort -u)"
    [ -n "${flags}" ]
    help="$(bash "${DEPLOY}" --help)"
    for flag in ${flags}; do
        # --type (compatibility) and --obtain-ssl (default behaviour) are
        # intentionally left out of --help; the README says so.
        case "${flag}" in --type|--obtain-ssl) continue ;; esac
        [[ "${help}" == *"${flag}"* ]] || { echo "flag ${flag} is not described in --help" >&2; return 1; }
    done
}

@test "the project docker-compose template contains the required services" {
    for svc in php nginx redis cron certbot_renew artisan composer npm permissions; do
        grep -qE "^  ${svc}:" "${REPO_ROOT}/laravel/docker-compose.yml" \
            || { echo "missing service ${svc}" >&2; return 1; }
    done
}

@test "the repository contains no Cyrillic text (scripts, templates, tests, examples, workflows, docs)" {
    # Match the UTF-8 lead bytes of the Cyrillic block (U+0400-U+04FF) in the C locale.
    run env LC_ALL=C grep -rlIP '[\xD0\xD1][\x80-\xBF]' \
        "${REPO_ROOT}"/*.sh "${REPO_ROOT}/laravel" "${REPO_ROOT}/nginxproxy" \
        "${REPO_ROOT}/tests" "${REPO_ROOT}/examples" "${REPO_ROOT}/.github" \
        "${REPO_ROOT}/README.md" "${REPO_ROOT}/SKILL.md" "${REPO_ROOT}/CHANGELOG.md"
    [ "${status}" -eq 1 ] || { echo "Cyrillic found in: ${output}" >&2; return 1; }
}
