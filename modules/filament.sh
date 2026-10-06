# shellcheck shell=bash disable=SC2154,SC2034
# ============================================================
# Module: filament — Filament admin panel
# ============================================================
# Loaded by deploy-laravel.sh (--with filament, or its alias --install-filament). It runs as root
# in the same shell as the script and uses its variables and helpers (SLUG, DOMAIN, PROJECT_DIR,
# FILAMENT_*, info, warn, error, success, random_string). See modules/README.md for the module API.
# ============================================================

MOD_FILAMENT_DESCRIPTION="Filament admin panel at /admin (needs --filament-email; the name and password are generated if not given)"
MOD_FILAMENT_REQUIRES=""

# Runs while the arguments are validated, before anything is changed
mod_filament_validate() {
    [[ -n "$FILAMENT_EMAIL" ]] || error "--filament-email is required to install Filament"
    [[ -z "$REPO_URL" ]] || error "Filament (--with filament / --install-filament) cannot be combined with --repo: the application manages its own dependencies"
}

# The module only runs on a fresh Laravel skeleton. In production, Filament requires
# an explicit authorization contract; allow the provisioned administrator only.
mod_filament_configure_access() {
    python3 - "${PROJECT_DIR}/public_html" "$FILAMENT_EMAIL" <<'PY' || error "Cannot configure Filament production access; check the User model and config/laraship.php"
import sys
from pathlib import Path

app, email = Path(sys.argv[1]), sys.argv[2]
model = app / "app/Models/User.php"
text = model.read_text(encoding="utf-8")
declaration = "class User extends Authenticatable"
if text.count(declaration) != 1 or "canAccessPanel" in text or not text.rstrip().endswith("}"):
    raise SystemExit("Unexpected User model; configure Filament production access manually")
text = text.replace(declaration, declaration + r" implements \Filament\Models\Contracts\FilamentUser", 1)
method = r"""
    public function canAccessPanel(\Filament\Panel $panel): bool
    {
        return $panel->getId() === 'admin'
            && $this->email === config('laraship.filament_admin_email');
    }
"""
text = text.rstrip()[:-1] + method + "}\n"
quoted_email = "'" + email.replace("\\", "\\\\").replace("'", "\\'") + "'"
config = app / "config/laraship.php"
if config.exists():
    raise SystemExit("config/laraship.php already exists; refusing to overwrite it")
config.write_text("<?php\n\nreturn ['filament_admin_email' => " + quoted_email + "];\n", encoding="utf-8")
model.write_text(text, encoding="utf-8")
PY
    chown 1000:1000 "${PROJECT_DIR}/public_html/config/laraship.php" || error "Cannot set Filament configuration ownership"
}

# Runs after Laravel is installed and migrated
mod_filament_install() {
    info "Installing Laravel Filament..."
    cd "${PROJECT_DIR}" || error "Failed to change to directory ${PROJECT_DIR}"

    # Generate a random name if not given (8 characters)
    if [[ -z "$FILAMENT_NAME" ]]; then
        FILAMENT_NAME=$(random_string 'a-f0-9' 8)
        info "Generated random user name: ${FILAMENT_NAME}"
    fi

    # Generate a random password if not given (10 characters)
    if [[ -z "$FILAMENT_PASSWORD" ]]; then
        FILAMENT_PASSWORD=$(random_string 'a-zA-Z0-9' 10)
        info "Generated random password: ${FILAMENT_PASSWORD}"
    fi

    info "Step 1/3: Installing the Filament package..."
    if docker compose run --rm composer require "filament/filament:${FILAMENT_VERSION}" 2>&1; then
        success "Filament package installed successfully"
    else
        error "Failed to install the Filament package"
    fi

    info "Step 2/3: Installing the Filament panel..."
    if docker compose run --rm artisan filament:install --panels 2>&1; then
        success "Filament panel installed successfully"
    else
        error "Failed to install the Filament panel"
    fi

    mod_filament_configure_access

    info "Step 3/3: Creating the Filament user..."
    if printf '%s\0' "$FILAMENT_NAME" "$FILAMENT_EMAIL" "$FILAMENT_PASSWORD" |
        docker compose run --rm --no-deps -T --entrypoint php artisan -r '
            require "vendor/autoload.php";
            $app = require "bootstrap/app.php";
            $app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
            $v = explode("\0", stream_get_contents(STDIN));
            if (!filter_var($v[1], FILTER_VALIDATE_EMAIL)) { throw new RuntimeException("Invalid administrator email"); }
            $model = config("auth.providers.users.model");
            $model::create(["name" => $v[0], "email" => $v[1], "password" => Illuminate\Support\Facades\Hash::make($v[2])]);
            echo "Filament administrator created\n";
        '; then
        success "Filament user created successfully"
        info "Filament login credentials:"
        info "  Email: ${FILAMENT_EMAIL}"
        info "  Name: ${FILAMENT_NAME}"
        info "  Password: ${FILAMENT_PASSWORD}"
        info "  URL: ${SITE_SCHEME:-http}://${DOMAIN}/admin"

        local GLOBAL_ENV="${PROJECT_DIR}/.env"
        if [[ -f "$GLOBAL_ENV" ]]; then
            info "Saving Filament credentials to the global .env file..."
            {
                echo ""
                echo "# Filament Admin Credentials"
                printf 'FILAMENT_ADMIN_NAME=%s\n' "$(db_env_value "$FILAMENT_NAME")"
                printf 'FILAMENT_ADMIN_EMAIL=%s\n' "$(db_env_value "$FILAMENT_EMAIL")"
                printf 'FILAMENT_ADMIN_PASSWORD=%s\n' "$(db_env_value "$FILAMENT_PASSWORD")"
            } >> "$GLOBAL_ENV" || error "Cannot save Filament administrator metadata"
            success "Filament credentials saved to ${GLOBAL_ENV}"
        fi
    else
        error "Failed to create the Filament user"
    fi

    cd "${SCRIPT_DIR}" || true
}

# Lines for the final summary
mod_filament_summary() {
    echo "FILAMENT:"
    echo "  URL:            ${SITE_SCHEME:-http}://${DOMAIN}/admin"
    echo "  Name:           ${FILAMENT_NAME}"
    echo "  Email:          ${FILAMENT_EMAIL}"
    echo "  Password:       ${FILAMENT_PASSWORD}"
    echo ""
}
