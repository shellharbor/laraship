# Deployment completion hooks

Run a local executable, POST a JSON report to an API, or do both when a deployment succeeds, fails or handles cancellation. Completion runs after the final deployment step, including ZIP creation and deferred post-deploy errors. Callback failures do not change the deployment's original exit status.

This feature belongs to the deployment Bash engine. Native Bash, Docker and the Python CLI share it when the selected toolkit/image includes the feature. It does not add hooks to update, backup, activation, removal or the Kubernetes backend. Published images and copied toolkits do not acquire new flags automatically.

## Options

| Flag | Config key | Default | Meaning |
| --- | --- | --- | --- |
| `--on-complete PATH` | `ON_COMPLETE` | unset | Trusted executable receiving completion JSON on stdin |
| `--completion-endpoint URL` | `COMPLETION_ENDPOINT` | unset | HTTPS API receiving the same JSON by POST |
| `--completion-include-secrets` | `COMPLETION_INCLUDE_SECRETS` | false | Include known application passwords in both targets' reports |
| `--completion-token-file PATH` | `COMPLETION_TOKEN_FILE` | unset | Private file containing the API Bearer token |
| `--completion-timeout SECONDS` | `COMPLETION_TIMEOUT` | 30 | Per-target timeout, from 1 to 300 seconds |
| `--allow-insecure-endpoint` | `ALLOW_INSECURE_ENDPOINT` | false | Explicitly permit HTTP for either endpoint feature |

No target runs unless configured. Config files retain preset → config → CLI precedence. Snapshot data, URLs and token contents go to the delivery helper/curl through stdin, without adding them to those child processes' arguments. Explicit values in the original deploy command retain their existing command-line visibility.

## Local script

The script must be an executable regular file owned by the invoking user, without group/other write permission, on a filesystem that permits execution. Parents must be real directories owned by root/the invoking user, without group/other write permission; root-owned sticky temporary directories are accepted. Symlinks are refused. For root deployment, install root-owned hooks in a location such as `/opt/laraship-hooks`:

```bash
sudo install -d -m 700 /opt/laraship-hooks
sudo install -m 700 examples/hooks/completion.sh /opt/laraship-hooks/notify.sh

sudo bash deploy-laravel.sh \
  --slug shop --domain shop.example.com --db-type postgres \
  --ssl-email admin@example.com \
  --on-complete /opt/laraship-hooks/notify.sh
```

The [example script](../examples/hooks/completion.sh) stores stdin in a mode-600 JSON file in a mode-700 directory. Replace it with your automation. The handler runs as the deploy user, normally root, as trusted administrative code. It receives no command-string evaluation or extra arguments. stdout/stderr are discarded because they may contain credentials; use your own private storage when needed and set retention for reports containing passwords.

The project lock is released before delivery, after deployment/rollback work finishes. Queue long-running orchestration at the receiver instead of performing it synchronously inside a bounded hook.

## API and passwords

```bash
sudo bash deploy-laravel.sh \
  --slug shop --domain shop.example.com --db-type postgres \
  --ssl-email admin@example.com \
  --completion-endpoint https://api.example.com/deployments/completed \
  --completion-token-file /root/laraship-api.token \
  --completion-include-secrets
```

The token file contains one nonempty ASCII Bearer token, optionally ending in a newline. It must be owned by the invoking user with mode 600 or stricter and trusted parents. Token contents are never printed or put in CLI arguments. Omit this option for an unauthenticated API; use a script for custom authentication/protocols.

Requests use POST, `Content-Type: application/json` and `Idempotency-Key: <run_id>`. Both targets receive the same report/run ID; API delivery is attempted even after a script failure. Completion logs contain only generic delivery messages or a validated HTTP status. Response bodies, raw curl errors, hook output, URLs and tokens are not echoed by this feature. The engine's existing generated-credential summary is unchanged.

HTTPS verification remains enabled. Redirects, user curl configuration and URL globbing are disabled. HTTP requires the explicit existing opt-in; included passwords then travel without transport encryption. Each target is attempted once, without automatic retries or a credential spool. A timeout or receiver error is not durable delivery; receivers should deduplicate run IDs and control credential storage.

## Report and lifecycle

Version-1 JSON contains `run_id`, `operation=deploy`, `status=success|failed|cancelled`, original `exit_code`, signal, current top-level `stage`, toolkit version and timing. Project fields include slug/domain/path/planned URL/requested Laravel version; known ports, database mode/name/user, Basic Auth and Filament settings; completed HTTP/proxy checks; established HTTPS; and the ZIP path when known.

Password fields are omitted by default. Explicit opt-in includes known application database, Redis, enabled Basic Auth and requested Filament passwords. Database root passwords, API tokens, SSH keys, `.env` contents and raw error/command text are never added to the report. On failure, fields can be null or unverified: generated/configured credentials do not prove successful provisioning. Read status, stage and readiness together. Deployment duration excludes callback delivery time.

Completion is armed after full argument/configuration validation and before operational preflight. It covers preflight/lock failures and later operational errors. Help, version, module/preset listing, dry run, invalid configuration and earlier root/toolkit-loading failures do not execute hooks. Dry run validates settings without invoking hooks or contacting endpoints.

Only the owner process finalizes; subshell exits do not send extra reports. HUP/INT/TERM cancellation is reported. Guarded work retains its existing cancellation/rollback exit status, and timed-out callbacks have their process group killed. SIGKILL, power loss or OS failure cannot run an exit handler.

`--post-deploy` remains an application setup command in the PHP container. `--endpoint` retains its existing JSON PUT contract before ZIP creation. Configure the new options for a final outcome notification.

## Docker and Python CLI

A Docker hook runs inside the administrative CLI container with its available tools. Mount hook/token files read-only at the same absolute paths, with the required Linux ownership/permissions. Completion support starts with release 1.3.0; the examples use image 1.3.1:

```bash
laraship install --backend docker --version 1.3.1
LARASHIP_CLI="$(command -v laraship)"
sudo "$LARASHIP_CLI" deploy --backend docker --image shellharbor/laraship:1.3.1 \
  --mount-readonly /opt/laraship-hooks -- \
  --slug shop --domain shop.example.com --db-type postgres \
  --ssl-email admin@example.com \
  --on-complete /opt/laraship-hooks/notify.sh
```

For native Python use, select a toolkit containing the feature with `--directory` and put deployment flags after `--`. The adapter does not register a second callback. Explicit read-only inputs also work in Docker inspection/dry-run, allowing hook/token validation without server-state mounts or networking.
