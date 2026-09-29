# Changelog

After every task that changes files, briefly record what changed and why: features, fixes, internal work, dependencies, documentation and AI-KIT. Keep new entries under `Unreleased` until a release is confirmed; fill in dates and versions only when they are known. A task with no file changes needs no entry.

## Unreleased

### AI-KIT

- v0.1: added agent instructions, context, skill, stack and engineering rules, model routing and the bootstrap prompt.
- Summary of the available voice context, thin adapters, a skills registry and stack skills; restored the user's Laravel conventions from the earlier AI-Kit task.
- Added a rule to check the Docker daemon and ask the user to start it for container tasks.
- Added a universal `.gitignore` for PHP/Laravel/Moodle/Go, development artifacts, secrets and the local AI-KIT.
- Added local Go cache directories and `*.out` files to `.gitignore`.
- Clarified the `composer.lock` policy: committed by default for applications, with an optional exception for libraries.
- Clarified that `go.mod` and `go.sum` stay under Git for Go modules.
- Added rules and a skill for Python scripts; `.gitignore` excludes virtual environments, caches, coverage and build artifacts while keeping configuration and lock files under Git.
- Clarified the mandatory `CHANGELOG.md` update after every task that changes files, so the history keeps both the reason and the result, including internal changes and the kit itself.

### Project

- No confirmed changes yet.
