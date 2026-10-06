#!/usr/bin/env bash
# Install checksum-verified, versioned test clients into a caller-owned directory.
set -euo pipefail
DEST="${1:?usage: kubernetes-tools.sh DIRECTORY}"
mkdir -p "$DEST"
case "$(uname -m)" in x86_64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;; *) echo 'Unsupported architecture' >&2; exit 1 ;; esac
curl --retry 3 --connect-timeout 10 --max-time 120 -fsSLo "$DEST/kind" "https://kind.sigs.k8s.io/dl/v0.33.0/kind-linux-$ARCH"
curl --retry 3 --connect-timeout 10 --max-time 30 -fsSLo "$DEST/kind.sha256" "https://kind.sigs.k8s.io/dl/v0.33.0/kind-linux-$ARCH.sha256sum"
printf '%s  %s\n' "$(awk '{print $1}' "$DEST/kind.sha256")" "$DEST/kind" | sha256sum -c -
curl --retry 3 --connect-timeout 10 --max-time 120 -fsSLo "$DEST/kubectl" "https://dl.k8s.io/release/v1.37.0/bin/linux/$ARCH/kubectl"
curl --retry 3 --connect-timeout 10 --max-time 30 -fsSLo "$DEST/kubectl.sha256" "https://dl.k8s.io/release/v1.37.0/bin/linux/$ARCH/kubectl.sha256"
printf '%s  %s\n' "$(cat "$DEST/kubectl.sha256")" "$DEST/kubectl" | sha256sum -c -
chmod 755 "$DEST/kind" "$DEST/kubectl"
rm "$DEST/kind.sha256" "$DEST/kubectl.sha256"
