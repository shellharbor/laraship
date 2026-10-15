#!/usr/bin/env bash
# Validate public Docker Hub settings before writing GitHub Actions outputs.
set -euo pipefail

fail() { printf '::error::%s\n' "$1" >&2; exit 1; }

tag="${1:-}"
version_file="${2:-VERSION}"
[[ "${DOCKERHUB_USERNAME:-}" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || fail 'Set DOCKERHUB_USERNAME to a Docker Hub login in GitHub Actions Variables.'
[[ "${DOCKERHUB_IMAGE:-}" =~ ^[a-z0-9][a-z0-9_-]*/[a-z0-9]+(([._]|__|-+)[a-z0-9]+)*$ ]] || fail 'Set DOCKERHUB_IMAGE to a lowercase namespace/repository in GitHub Actions Variables.'
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] || fail 'Invalid release tag for Docker Hub publication.'
version="${tag#v}"
(( ${#version} <= 128 )) || fail 'The release version exceeds the Docker tag length limit.'
[[ -f "$version_file" ]] || fail 'The selected release has no VERSION file.'
[[ "$(tr -d '[:space:]' < "$version_file")" == "$version" ]] || fail 'The release tag does not match VERSION.'
[[ -n "${GITHUB_OUTPUT:-}" ]] || fail 'GITHUB_OUTPUT is required.'

printf 'image_tag=%s:%s\nversion=%s\n' "$DOCKERHUB_IMAGE" "$version" "$version" >> "$GITHUB_OUTPUT"
