# Security policy

## Supported versions

| Version | Supported |
|---|---|
| 1.x (latest release) | yes |
| older | no |

Fixes go into the latest 1.x release. Laraship only creates new projects and never modifies existing deployments, so an already deployed server is updated by hand (see the README, "Updating an already deployed server").

## Reporting a vulnerability

Please **do not open a public issue** for a security problem.

Report it privately through GitHub: the repository's **Security** tab, then **Report a vulnerability** (private vulnerability reporting). Include:

- the version (`bash deploy-laravel.sh --version`) and the arguments you used (leave out passwords and tokens);
- what you expected, what happened, and the impact;
- steps to reproduce, if you have them.

You can expect an acknowledgement within a few days. A confirmed issue is fixed in a new release and described in the [CHANGELOG](CHANGELOG.md) under "Security"; you are credited there unless you prefer not to be.

## What is in scope

- The scripts in this repository (`deploy-laravel.sh`, `activate.sh`, `deactivate.sh`, `remove.sh`, `list-projects.sh`, `update.sh`, `backup.sh`), the modules, presets and the templates in `laravel/` and `nginxproxy/`.
- Typical problems: command or argument injection, unsafe handling of secrets (passwords, deploy keys, `.env` files, file permissions), insecure defaults in the generated nginx, PHP or Docker configuration, path traversal in `--config`, `--preset` or `--with`.

## What is out of scope

- Vulnerabilities in Laravel, Filament, Docker, nginx, PostgreSQL, MySQL or Let's Encrypt themselves: report them to those projects.
- Laravel 10.x and 11.x: they are refused by design because Composer blocks them over unfixed security advisories.
- Anything that needs you to run a module or config file you did not review. Modules run as root and are sourced from the `modules/` folder only; treat that folder as code you trust.

## Hardening notes

- Run the script on a server you control, as root, and keep `--config` files and deploy keys readable by root only (the script warns when a `--config` file is readable by other users; `chmod 600` it).
- Published ports default to public for compatibility with 1.0.0; use `--bind-local` to bind them to `127.0.0.1` (the default changes in 2.0, see the CHANGELOG).
