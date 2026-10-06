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

@test "module files pass bash -n" {
    for f in "${REPO_ROOT}"/modules/*.sh; do
        run bash -n "${f}"
        [ "${status}" -eq 0 ] || { echo "${f}: ${output}" >&2; return 1; }
    done
}

@test "every module has a description and only mod_<name>_ functions and MOD_<NAME>_ variables" {
    local f name fn_prefix var_prefix bad
    for f in "${REPO_ROOT}"/modules/*.sh; do
        name="$(basename "${f}" .sh)"
        [[ "${name}" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "invalid module file name: ${name}" >&2; return 1; }
        fn_prefix="mod_${name//-/_}_"
        var_prefix="MOD_$(printf '%s' "${name//-/_}" | tr 'a-z' 'A-Z')_"
        grep -q "^${var_prefix}DESCRIPTION=" "${f}" || { echo "${name}: no ${var_prefix}DESCRIPTION" >&2; return 1; }
        bad="$(grep -oE '^[A-Za-z_][A-Za-z0-9_]*\(\)' "${f}" | tr -d '()' | grep -v "^${fn_prefix}" || true)"
        [ -z "${bad}" ] || { echo "${name}: functions must start with ${fn_prefix}: ${bad}" >&2; return 1; }
        # top level = before the first function; the bodies of heredocs inside hooks are not variables of the module
        bad="$(awk '/^[A-Za-z_][A-Za-z0-9_]*\(\)/ { exit } { print }' "${f}" | grep -oE '^[A-Z][A-Z0-9_]*=' | tr -d '=' | grep -v "^${var_prefix}" || true)"
        [ -z "${bad}" ] || { echo "${name}: top-level variables must start with ${var_prefix}: ${bad}" >&2; return 1; }
    done
}

@test "--list-modules works without root and lists every module" {
    run bash "${DEPLOY}" --list-modules
    [ "${status}" -eq 0 ]
    for f in "${REPO_ROOT}"/modules/*.sh; do
        [[ "${output}" == *"$(basename "${f}" .sh)"* ]] || { echo "$(basename "${f}") is not listed" >&2; return 1; }
    done
}

@test "the module aliases and --with are described in --help" {
    run bash "${DEPLOY}" --help
    [[ "${output}" == *"--with NAME"* ]]
    [[ "${output}" == *"--list-modules"* ]]
}

@test "VERSION is a semantic version and is the newest release in CHANGELOG.md" {
    local ver top
    ver="$(tr -d '[:space:]' <"${REPO_ROOT}/VERSION")"
    [[ "${ver}" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || { echo "VERSION is not semver: ${ver}" >&2; return 1; }
    top="$(grep -m1 -E '^## [0-9]+\.[0-9]+\.[0-9]+' "${REPO_ROOT}/CHANGELOG.md" | awk '{print $2}')"
    [ "${top}" = "${ver}" ] || { echo "VERSION is ${ver} but the newest release in CHANGELOG.md is ${top}" >&2; return 1; }
}

@test "--version prints the version and exits with code 0 (even without root)" {
    run bash "${DEPLOY}" --version
    [ "${status}" -eq 0 ]
    [ "${output}" = "deploy-laravel.sh $(tr -d '[:space:]' <"${REPO_ROOT}/VERSION")" ]
    run bash "${DEPLOY}" -V
    [ "${status}" -eq 0 ]
}

@test "release-notes.sh extracts exactly the section of a release" {
    local ver; ver="$(tr -d '[:space:]' <"${REPO_ROOT}/VERSION")"
    run bash "${REPO_ROOT}/.github/scripts/release-notes.sh" "${ver}" "${REPO_ROOT}/CHANGELOG.md"
    [ "${status}" -eq 0 ]
    [ -n "${output}" ]
    [[ "${output}" != "## "* ]]
    # only this release: no other release heading, no other top-level section
    if printf '%s\n' "${output}" | grep -qE '^## '; then echo "another section leaked into the notes" >&2; return 1; fi
    run bash "${REPO_ROOT}/.github/scripts/release-notes.sh" 0.0.0-none "${REPO_ROOT}/CHANGELOG.md"
    [ "${status}" -eq 0 ]
    [ -z "${output}" ]
}

@test "the release workflow needs a tag that matches VERSION (files exist)" {
    [ -f "${REPO_ROOT}/.github/workflows/release.yml" ]
    [ -f "${REPO_ROOT}/.gitattributes" ]
    grep -q '^\* text=auto eol=lf' "${REPO_ROOT}/.gitattributes"
}

@test "the install matrix cases in the workflow, the entrypoint and the test file agree" {
    local listed case_id in_entry
    in_entry="$(sed -n '/^INSTALL_CASES=(/,/)/p' "${REPO_ROOT}/tests/sandbox-entrypoint.sh" | tr -d '()' | sed 's/^INSTALL_CASES=//' | tr -s '[:space:]' ' ')"
    [ -n "${in_entry}" ]
    # every case of the workflow is known to the entrypoint
    listed="$(grep -E '^          - [a-z0-9.-]+$' "${REPO_ROOT}/.github/workflows/install-matrix.yml" | sed 's/^ *- //')"
    [ -n "${listed}" ]
    for case_id in ${listed}; do
        [[ " ${in_entry} " == *" ${case_id} "* ]] || { echo "${case_id} is in the workflow but not in INSTALL_CASES" >&2; return 1; }
    done
    # every case of the entrypoint has an entry in the case table of install-matrix.bats
    # (plain repo-<branch> cases run tests/e2e-repo.bats instead)
    for case_id in ${in_entry}; do
        case "${case_id}" in
            repo-blocked-*) grep -q '^    repo-blocked-\*)' "${REPO_ROOT}/tests/install-matrix.bats" || { echo "repo-blocked-* is missing in install-matrix.bats" >&2; return 1; } ;;
            repo-*) ;;
            *) grep -qE "^    ${case_id}\)" "${REPO_ROOT}/tests/install-matrix.bats" || { echo "${case_id} has no entry in tests/install-matrix.bats" >&2; return 1; } ;;
        esac
    done
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

@test "update.sh --help prints the usage and exits with code 0 (even without root)" {
    run bash "${REPO_ROOT}/update.sh" --help
    [ "${status}" -eq 0 ]
    for flag in --slug --no-migrate --post-deploy --reset --force; do
        [[ "${output}" == *"${flag}"* ]] || { echo "${flag} is missing from update.sh --help" >&2; return 1; }
    done
}

@test "backup.sh --help prints the usage and exits with code 0 (even without root)" {
    run bash "${REPO_ROOT}/backup.sh" --help
    [ "${status}" -eq 0 ]
    for word in now list restore --yes --slug; do
        [[ "${output}" == *"${word}"* ]] || { echo "${word} is missing from backup.sh --help" >&2; return 1; }
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
        case "${flag}" in --type|--obtain-ssl|--list-modules) continue ;; esac
        [[ "${help}" == *"${flag}"* ]] || { echo "flag ${flag} is not described in --help" >&2; return 1; }
    done
}

@test "--config, --preset and --dry-run are described in --help" {
    run bash "${DEPLOY}" --help
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"--config FILE"* ]]
    [[ "${output}" == *"--preset NAME"* ]]
    [[ "${output}" == *"--list-presets"* ]]
    [[ "${output}" == *"--dry-run"* ]]
}

@test "every command-line flag can be set in a --config file" {
    local flags flag list
    flags="$(grep -oE '^\s+--[a-z0-9-]+\)' "${DEPLOY}" | tr -d ' )' | sed 's/^--//' | sort -u)"
    list=" $(grep -E '^CONFIG_(VALUE|BOOL)_FLAGS=' "${DEPLOY}" | sed -e 's/^[^(]*(//' -e 's/)$//' | tr '\n' ' ') "
    [ -n "${flags}" ]
    for flag in ${flags}; do
        # --type is a compatibility flag; --list-*, --preset, --config and --dry-run are handled outside parse_args
        case "${flag}" in type|list-modules|list-presets|config|preset|dry-run) continue ;; esac
        [[ "${list}" == *" ${flag} "* ]] || { echo "flag --${flag} cannot be set in a config file (CONFIG_*_FLAGS)" >&2; return 1; }
    done
}

@test "versions.env exists and defines the versions" {
    for key in LARAVEL_VERSION LARAVEL_MIN_VERSION FILAMENT_VERSION POSTGRES_IMAGE MYSQL_IMAGE; do
        grep -qE "^${key}=.+" "${REPO_ROOT}/versions.env" || { echo "versions.env has no ${key}" >&2; return 1; }
    done
}

@test "the database images in the compose template match versions.env" {
    grep -q "image: $(env_val "${REPO_ROOT}/versions.env" POSTGRES_IMAGE)\$" "${REPO_ROOT}/laravel/docker-compose.yml"
    grep -q "image: $(env_val "${REPO_ROOT}/versions.env" MYSQL_IMAGE)\$" "${REPO_ROOT}/laravel/docker-compose.yml"
}

@test "the compose template has exactly one top-level services, networks and volumes section" {
    local key
    for key in services networks volumes; do
        [ "$(grep -c "^${key}:" "${REPO_ROOT}/laravel/docker-compose.yml")" -eq 1 ]             || { echo "expected exactly one top-level ${key}: section" >&2; return 1; }
    done
    # modules insert their services right before the top-level networks: section
    [ "$(grep -n '^services:' "${REPO_ROOT}/laravel/docker-compose.yml" | cut -d: -f1)" -lt "$(grep -n '^networks:' "${REPO_ROOT}/laravel/docker-compose.yml" | cut -d: -f1)" ]
}

@test "the project docker-compose template contains the required services" {
    for svc in php nginx redis cron certbot_renew artisan composer npm permissions; do
        grep -qE "^  ${svc}:" "${REPO_ROOT}/laravel/docker-compose.yml" \
            || { echo "missing service ${svc}" >&2; return 1; }
    done
}

@test "the repository contains no Cyrillic text (scripts, templates, tests, examples, workflows, docs)" {
    # Scan only what exists in this checkout: some files (for example SKILL.md) may be
    # git-ignored and therefore absent on CI.
    cd "${REPO_ROOT}"
    local targets=() p
    for p in *.sh laravel nginxproxy modules presets tests examples .github README.md SKILL.md CHANGELOG.md VERSION .gitattributes .claude; do
        [ -e "${p}" ] && targets+=("${p}")
    done
    [ "${#targets[@]}" -gt 0 ]
    # Match the UTF-8 lead bytes of the Cyrillic block (U+0400-U+04FF) in the C locale.
    run env LC_ALL=C grep -rlIP '[\xD0\xD1][\x80-\xBF]' "${targets[@]}"
    [ "${status}" -eq 1 ] || { echo "Cyrillic found in: ${output}" >&2; return 1; }
}
