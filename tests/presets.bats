#!/usr/bin/env bats
# Presets (--preset, --list-presets) and --dry-run. --dry-run parses and validates the settings, prints
# the effective ones and exits: it changes nothing and needs no root, which lets these tests check how
# presets, --config files and flags combine without deploying anything.

load helpers

# dry_run <args>: run deploy-laravel.sh --dry-run with valid required settings
dry_run() {
    run timeout 30 bash "${DEPLOY}" --dry-run --slug okslug --domain x.test --db-type postgres --no-ssl "$@"
    output="$(printf '%s' "${output}" | strip_ansi)"
}

# dry_run_at <dir> <args>: the same for a copy of the script in another folder (custom presets)
dry_run_at() {
    local dir="$1"; shift
    run timeout 30 bash "${dir}/deploy-laravel.sh" --dry-run --slug okslug --domain x.test --db-type postgres --no-ssl "$@"
    output="$(printf '%s' "${output}" | strip_ansi)"
}

# A folder with a copy of the script, versions.env, modules and a custom preset "custom" with the given content
preset_dir() {
    local dir="${BATS_TEST_TMPDIR}/pre"
    mkdir -p "${dir}/presets"
    cp "${DEPLOY}" "${dir}/deploy-laravel.sh"
    cp -r "${REPO_ROOT}/lib" "${dir}/lib"
    cp "${REPO_ROOT}/versions.env" "${dir}/versions.env"
    cp -r "${REPO_ROOT}/modules" "${REPO_ROOT}/laravel" "${REPO_ROOT}/nginxproxy" "${dir}/"
    printf '%b' "$1" >"${dir}/presets/custom.conf"
    printf '%s' "${dir}"
}

field() { printf '%s\n' "${output}" | grep -E "^  $1:" | sed -E "s/^  $1: *//"; }

# ---------- --dry-run ----------

@test "--dry-run prints the effective settings and says nothing was changed" {
    dry_run
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"dry run: nothing was changed"* ]]
    [ "$(field Slug)" = "okslug" ]
    [ "$(field Domain)" = "x.test" ]
    [[ "$(field Database)" == *"postgres"* ]]
    [ "$(field Modules)" = "none" ]
}

@test "--dry-run needs no root and creates nothing" {
    local before after nr
    before="$(find /var/www -mindepth 1 -maxdepth 1 2>/dev/null | sort)"
    if [ "$(id -u)" -eq 0 ]; then
        command -v runuser >/dev/null || skip "runuser is not available"
        # An unprivileged user needs read access to the script: use a world-readable copy in /tmp
        nr="$(mktemp -d /tmp/laraship-noroot.XXXXXX)"
        chmod 755 "${nr}"
        cp -r "${REPO_ROOT}/deploy-laravel.sh" "${REPO_ROOT}/versions.env" "${REPO_ROOT}/modules" "${REPO_ROOT}/presets"               "${REPO_ROOT}/laravel" "${REPO_ROOT}/nginxproxy" "${REPO_ROOT}/lib" "${nr}/"
        chmod -R a+rX "${nr}"
        run runuser -u nobody -- timeout 30 bash "${nr}/deploy-laravel.sh" --dry-run --slug okslug --domain x.test --db-type postgres --no-ssl
        rm -rf "${nr}"
    else
        run timeout 30 bash "${DEPLOY}" --dry-run --slug okslug --domain x.test --db-type postgres --no-ssl
    fi
    [ "${status}" -eq 0 ] || { echo "${output}" >&2; return 1; }
    after="$(find /var/www -mindepth 1 -maxdepth 1 2>/dev/null | sort)"
    [ "${before}" = "${after}" ]
}

@test "--dry-run still validates the settings" {
    run timeout 30 bash "${DEPLOY}" --dry-run --domain x.test --db-type oracle --no-ssl
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"DB type must be"* ]]
}

@test "--dry-run does not print generated secrets" {
    run timeout 30 bash "${DEPLOY}" --dry-run --domain x.test --db-type postgres --no-ssl --enable-basic-auth
    output="$(printf '%s' "${output}" | strip_ansi)"
    [ "${status}" -eq 0 ]
    [[ "${output}" == *"Generated Redis password: <generated>"* ]]
    [[ "${output}" == *"Generated Basic Auth password: <generated>"* ]]
    if printf '%s' "${output}" | grep -qE 'password: [A-Za-z0-9@%_+-]{15}'; then return 1; fi
}

@test "--dry-run shows the source, options and modules" {
    dry_run --repo "https://github.com/acme/shop.git" --branch main --bind-local --php-upload-max 64M --with redis,queue --enable-basic-auth
    [ "${status}" -eq 0 ]
    [[ "$(field Source)" == *"https://github.com/acme/shop.git"* ]]
    [[ "$(field Source)" == *"main"* ]]
    [ "$(field Modules)" = "redis, queue" ]
    [[ "$(field 'Ports')" == *"127.0.0.1"* ]]
    [[ "$(field 'PHP uploads')" == *"64M"* ]]
    [[ "$(field 'Basic Auth')" == *"on"* ]]
}

@test "--dry-run shows the database dumps of the backup module" {
    dry_run
    [ "$(field 'DB dumps')" = "off" ]
    dry_run --with backup
    [[ "$(field 'DB dumps')" == *"7 days"* ]]
    dry_run --with backup --backup-keep 14
    [[ "$(field 'DB dumps')" == *"14 days"* ]]
}

@test "--backup-keep can be set in a config file" {
    dry_run --config "$(write_config 'WITH=backup\nBACKUP_KEEP_DAYS=x\n')"
    [ "${status}" -eq 1 ]
    dry_run --config "$(write_config 'WITH=backup\nBACKUP_KEEP=30\n')"
    [ "${status}" -eq 0 ]
    [[ "$(field 'DB dumps')" == *"30 days"* ]]
}

@test "--dry-run is not a config key" {
    run timeout 30 bash "${DEPLOY}" --dry-run --config "$(write_config 'DRY_RUN=true\n')"
    [ "${status}" -eq 1 ]
    [[ "$(printf '%s' "${output}" | strip_ansi)" == *"Unknown key DRY_RUN"* ]]
}

# ---------- presets ----------

@test "--list-presets lists every preset file with its description (no root needed)" {
    run bash "${DEPLOY}" --list-presets
    [ "${status}" -eq 0 ]
    for f in "${REPO_ROOT}"/presets/*.conf; do
        local name; name="$(basename "${f}" .conf)"
        [[ "${output}" == *"${name}"* ]] || { echo "${name} is not listed" >&2; return 1; }
        [[ "${output}" == *"$(grep -m1 '^# Description:' "${f}" | sed 's/^# Description: *//')"* ]] || { echo "${name}: description missing" >&2; return 1; }
    done
}

@test "the shipped presets have a description, hold no secrets, and are accepted by the script" {
    local f name
    for f in "${REPO_ROOT}"/presets/*.conf; do
        name="$(basename "${f}" .conf)"
        [[ "${name}" =~ ^[a-z][a-z0-9-]*$ ]] || { echo "invalid preset name ${name}" >&2; return 1; }
        grep -q '^# Description: ' "${f}" || { echo "${name}: no '# Description:' line" >&2; return 1; }
        # A shipped preset is shared: no passwords, keys, emails, domain, slug or repository
        if grep -qiE '^[[:space:]]*(.*(PASSWORD|SECRET|TOKEN|EMAIL|DEPLOY_KEY)|DOMAIN|SLUG|REPO|ENDPOINT|PRESET)[[:space:]]*=' "${f}"; then
            echo "${name}: presets must not set secrets, identity or another preset" >&2
            return 1
        fi
        dry_run --preset "${name}" --filament-email admin@example.test
        [ "${status}" -eq 0 ] || { echo "${name}: $(printf '%s' "${output}" | tail -n 3)" >&2; return 1; }
    done
}

@test "--preset admin-panel enables the modules it names" {
    dry_run --preset admin-panel --filament-email admin@example.test
    [ "${status}" -eq 0 ]
    [ "$(field Modules)" = "filament, redis, queue" ]
    [ "$(field Presets)" = "admin-panel" ]
    [[ "$(field Ports)" == *"127.0.0.1"* ]]
}

@test "--preset admin-panel still needs --filament-email" {
    dry_run --preset admin-panel
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"--filament-email is required"* ]]
}

@test "--preset api: a module that requires another enables it" {
    dry_run --preset api
    [ "${status}" -eq 0 ]
    [ "$(field Modules)" = "redis, horizon" ]
    [[ "$(field 'PHP uploads')" == *"16M"* ]]
}

@test "--preset staging turns Basic Auth on" {
    dry_run --preset staging
    [ "${status}" -eq 0 ]
    [[ "$(field 'Basic Auth')" == *"on"* ]]
    [ "$(field Modules)" = "redis" ]
}

@test "several presets combine, in order" {
    dry_run --preset api --preset staging
    [ "${status}" -eq 0 ]
    [ "$(field Presets)" = "api, staging" ]
    [ "$(field Modules)" = "redis, horizon" ]
    [[ "$(field 'Basic Auth')" == *"on"* ]]
}

@test "a flag overrides a value set by a preset" {
    dry_run --preset api --php-upload-max 256M
    [ "${status}" -eq 0 ]
    [[ "$(field 'PHP uploads')" == *"256M"* ]]
}

@test "a --config file overrides a preset, and a flag overrides the file" {
    local cfg; cfg="$(write_config 'PHP_UPLOAD_MAX=64M\n')"
    dry_run --preset api --config "${cfg}"
    [[ "$(field 'PHP uploads')" == *"64M"* ]]
    dry_run --preset api --config "${cfg}" --php-upload-max 512M
    [[ "$(field 'PHP uploads')" == *"512M"* ]]
}

@test "a --config file can name a preset with PRESET=" {
    dry_run --config "$(write_config 'PRESET=staging\n')"
    [ "${status}" -eq 0 ]
    [ "$(field Presets)" = "staging" ]
    [[ "$(field 'Basic Auth')" == *"on"* ]]
}

@test "modules from a preset and from --with accumulate" {
    dry_run --preset api --with filament --filament-email admin@example.test
    [ "${status}" -eq 0 ]
    [ "$(field Modules)" = "redis, horizon, filament" ]
}

@test "--preset: an unknown preset" {
    dry_run --preset nonexistent
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Unknown preset: nonexistent"* ]]
}

@test "--preset: an invalid name (no path tricks)" {
    dry_run --preset "../secret"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Invalid preset name"* ]]
}

@test "--preset requires a name" {
    run timeout 30 bash "${DEPLOY}" --dry-run --preset
    [ "${status}" -eq 1 ]
    [[ "$(printf '%s' "${output}" | strip_ansi)" == *"--preset requires a name"* ]]
}

@test "a custom preset in presets/ is picked up and its errors are reported" {
    dry_run_at "$(preset_dir 'WITH=redis\nBIND_LOCAL=true\n')" --preset custom
    [ "${status}" -eq 0 ]
    [ "$(field Modules)" = "redis" ]
    dry_run_at "$(preset_dir 'FOO=1\n')" --preset custom
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"Unknown key FOO"* ]]
}

@test "a preset cannot include another preset" {
    dry_run_at "$(preset_dir 'PRESET=api\n')" --preset custom
    [ "${status}" -eq 1 ]
    [[ "${output}" == *"cannot include another preset"* ]]
}

@test "a preset file readable by others does not trigger the secrets warning" {
    dry_run --preset api
    [[ "${output}" != *"accessible to other users"* ]]
}
