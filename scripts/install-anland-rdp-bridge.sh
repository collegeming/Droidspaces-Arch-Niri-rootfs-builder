#!/bin/bash
# install-anland-rdp-bridge — download, verify, and install the pinned
# aarch64-linux anland-rdp-bridge release binary.
#
# Minimal hardening (per the rootfs builder's anland-rdp variant policy):
# sha256 + ELF/AArch64 architecture check. The release archive is a single
# `anland_rdp_bridge` binary (no SBOM/BUILD-METADATA sidecar). Pinning is
# hardcoded here — the same self-contained style as install-lamco-anland-bridge.
set -euo pipefail

readonly REPOSITORY="collegeming/anland-rdp-bridge"
readonly RELEASE_TAG="v0.1.0"
readonly ASSET="anland-rdp-bridge-aarch64-linux.tar.gz"
readonly ASSET_SHA256="2109226b53268bc7781bd5690290b165f18027973a6df99c18112a1dd92ce447"
readonly BINARY_NAME="anland_rdp_bridge"
readonly RELEASE_URL="https://github.com/${REPOSITORY}/releases/download/${RELEASE_TAG}/${ASSET}"

install_root="${DESTDIR:-}"
if [[ -n "$install_root" && "$install_root" != /* ]]; then
    printf 'ERROR: DESTDIR must be an absolute path\n' >&2
    exit 1
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
archive="$workdir/$ASSET"

printf '==> [anland-rdp] Downloading pinned ARM64 release %s\n' "$RELEASE_TAG"
curl --fail --location --retry 5 --retry-delay 3 --retry-all-errors \
    --connect-timeout 20 --max-time 180 \
    --output "$archive" "$RELEASE_URL"

printf '%s  %s\n' "$ASSET_SHA256" "$archive" | sha256sum -c -
gzip -t "$archive"

# The release archive contains exactly one member: the binary at the root.
actual_entries="$(tar -tzf "$archive")"
if [[ "$actual_entries" != "$BINARY_NAME" ]]; then
    printf 'ERROR: anland-rdp release archive contains an unexpected entry set:\n%s\n' \
        "$actual_entries" >&2
    exit 1
fi

mkdir -p "$workdir/extract"
tar -xzf "$archive" -C "$workdir/extract" --no-same-owner --no-same-permissions
binary="$workdir/extract/$BINARY_NAME"
[[ -f "$binary" && ! -L "$binary" ]] || {
    printf 'ERROR: release binary missing or unsafe: %s\n' "$binary" >&2
    exit 1
}

# Architecture check: 64-bit AArch64 ELF with the aarch64 loader.
file "$binary" | grep -Eq 'ELF 64-bit LSB.*(ARM aarch64|AArch64)'
readelf -h "$binary" | grep -Eq 'Machine:[[:space:]]+AArch64'
readelf -l "$binary" | grep -Fq 'Requesting program interpreter: /lib/ld-linux-aarch64.so.1'

install -Dm755 "$binary" "$install_root/usr/bin/$BINARY_NAME"
install -d -m 0755 "$install_root/usr/share/doc/anland-rdp-bridge"
printf '==> [anland-rdp] Installed verified %s (%s)\n' "$ASSET" "$ASSET_SHA256"
