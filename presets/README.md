# Presets

A preset is a named bundle of settings: a `--config` file shipped with the script in `presets/<name>.conf`. It makes the same choice easy to repeat (`--preset api`) without copying a list of flags.

```bash
bash deploy-laravel.sh --list-presets          # no root needed

sudo bash deploy-laravel.sh --domain api.example.com --db-type postgres --ssl-email admin@example.com \
  --preset api

# see what a combination will do, without changing anything (no root needed)
bash deploy-laravel.sh --dry-run --preset api --domain api.example.com --db-type postgres --no-ssl
```

| Preset | What it sets |
|---|---|
| `admin-panel` | Modules `filament`, `redis`, `queue`; ports on `127.0.0.1` only. Needs `--filament-email` |
| `api` | Module `horizon` (and `redis`, which it enables); ports on `127.0.0.1` only; 16M PHP uploads |
| `staging` | HTTP Basic Auth (generated credentials unless given), module `redis`; ports on `127.0.0.1` only |

## How presets combine with other settings

Settings are applied in this order; a later one overrides an earlier one:

1. presets, in the order of the `--preset` flags;
2. the `--config` file (which can also name a preset with `PRESET=name`);
3. flags on the command line.

A preset can only **add**: modules from `--with` accumulate, and a boolean flag (`BIND_LOCAL`, `ENABLE_BASIC_AUTH`, ...) that a preset turns on cannot be turned off by a later `false`. Values (`PHP_UPLOAD_MAX`, `LARAVEL_VERSION`, ...) can be overridden: `--preset api --php-upload-max 256M` gives 256M.

## Writing a preset

Create `presets/<name>.conf` (`[a-z][a-z0-9-]*`), in the [`--config` format](../README.md#configuration-file-and-versions): `KEY=VALUE` lines, `#` comments. The first line should be `# Description: …`, which `--list-presets` shows.

- A preset must not hold secrets, a domain or a slug: it is meant to be shared and reused. Pass those as flags or in your own `--config` file. `tests/static.bats` checks the shipped presets for this.
- A preset cannot include another preset (`PRESET=` is rejected inside a preset); combine presets with several `--preset` flags.
- A preset is read like the script: only files in this folder are used, and the values are parsed, never executed.
