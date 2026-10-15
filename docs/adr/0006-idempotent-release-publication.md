# ADR-0006: Idempotent release publication

- Status: accepted, targeted for v1.2.0
- Date: 2026-10-14

## Context

The release workflow always called `gh release create`. An existing v1.1.1 release, published on 2026-10-07 without the archive/checksum assets, made subsequent publication fail even after the exact-commit CI gate passed.

## Decision

Keep the exact-tag CI, version and changelog checks. Add a standard-library Python publisher using the authenticated GitHub CLI. Verify the remote tag against the checked-out commit before publication. Create absent releases with their assets; for an existing published release, compare every expected existing file by size and SHA-256 before uploading any missing file. Download older assets when digest metadata is unavailable. Never use `--clobber`, replace notes, move tags or delete releases. Refuse conflicting/incomplete assets, drafts and immutable releases with missing files. Reinspect state after an uncertain create/upload outcome instead of blindly retrying a mutation.

Serialize workflow jobs per tag without interrupting publication. Add manual dispatch with a validated tag input. Preserve the selected workflow's current publisher and CI policy in the runner temporary directory, then check out the exact tag for CI/version validation and archive generation. This permits completing an older existing release after the workflow update reaches the default branch, without modifying that tag.

## Alternatives

- Delete and recreate the release: risks losing metadata and previously downloaded assets.
- Upload with `--clobber`: silently changes published bytes.
- Skip any existing release: reports success while required download files can remain absent.
- Run only the workflow stored in the old tag: cannot recover an existing release using a later publication fix.

## Consequences

Reruns are read-only when expected files already match and can complete a partial published release. Inconsistent content requires explicit operator review or a new version. Draft releases remain under manual control. Binary reproduction matters: a differing archive is refused even if it was produced from the same Git tree by a different toolchain. Maintainers must preserve release tags; independent external tag changes cannot be atomically locked by a sequence of API calls. Real publication still requires GitHub authentication with repository write access.

References: [GitHub CLI release upload](https://cli.github.com/manual/gh_release_upload), [release assets API](https://docs.github.com/en/rest/releases/assets), [workflow](../../.github/workflows/release.yml), [publisher](../../.github/scripts/publish-release.py).
