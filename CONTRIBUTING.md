# Contributing

Thank you for helping. Bug reports, fixes, docs and new modules are welcome.

## Before you start

- Bugs and ideas: open an issue with the version (`bash deploy-laravel.sh --version`), the arguments (no secrets) and the output. Security problems go through [SECURITY.md](SECURITY.md), not a public issue.
- For a larger change, open an issue first so the approach can be agreed.
- Read the [Compatibility policy](CHANGELOG.md#compatibility-policy): in 1.x flags keep working, new flags are additive, and a change to an observable default waits for 2.0.

## Ground rules

- Bash only, for Ubuntu with Docker. Keep the style of the surrounding code, and keep scripts LF-terminated (`.gitattributes` enforces it).
- **English only** in code, comments, messages and docs.
- Never source user-provided files: config, versions and meta files are parsed line by line.
- Never print generated secrets in `--dry-run`, and keep secret files at mode 600.
- Do not commit secrets, real domains or personal data; use `example.com` in examples.

## Checks

The scripts must pass ShellCheck, and the tests run in a sandbox container (no changes to your host):

```bash
shellcheck -S warning -e SC2155 -- *.sh tests/*.sh modules/*.sh .github/scripts/*.sh
bash tests/run-local.sh unit           # fast: static, validation, preset and safety tests (bats)
bash tests/run-local.sh e2e            # real deployments in the sandbox (needs Docker, long)
bash tests/run-local.sh full           # all supported launch scenarios; saved per-case results (long)
```

The other suites (`e2e-proxy`, `e2e-db-migration`, `e2e-repo`, `e2e-modules`, `install`) and full-matrix options are described in the README, "Tests and CI". Add or update tests for what you change: `tests/validation.bats` for argument handling, `tests/safety.bats` for failures that must preserve data and service state, `tests/e2e*.bats` for real deployments. CI runs Lint, Tests, E2E and CodeQL on every pull request. Breaking changes stay in `Unreleased` until a major release is prepared; the current P1 safety changes require that release.

## Contributing a module

Modules ship with the script: there is no download step, because a module runs as root. A new module is added to this repository by pull request.

1. Copy `modules/TEMPLATE.sh.example` to `modules/<name>.sh` (`[a-z][a-z0-9-]*`), and implement the hooks described in [modules/README.md](modules/README.md).
2. Keep it small and reviewable: no network downloads of code, no `eval` of external input, no changes outside the project folder.
3. Add tests (`tests/e2e-modules.bats` and the validation tests) and a row in the module table of the README.
4. Mention it in the CHANGELOG.

## Pull requests

- One topic per pull request, with a short description of what and why.
- Update the [README](README.md), [CHANGELOG](CHANGELOG.md) (under "Unreleased") and [SKILL.md](SKILL.md) when behavior, flags or messages change.
- Do not bump `VERSION` or tag releases: the maintainer does it.
- Make sure the checks above pass.
