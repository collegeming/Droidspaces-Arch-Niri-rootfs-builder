#!/bin/bash
set -euo pipefail

readonly REPOSITORY="collegeming/lamco-anland-bridge"
readonly RELEASE_TAG="anland-v0.2.0"
readonly ASSET="lamco-anland-bridge-0.2.0-aarch64-unknown-linux-gnu.tar.xz"
readonly ASSET_SHA256="593a2639f7c06bc3f453ae094114f85e03f442f5d9482d132b5662cd9a146eea"
readonly PACKAGE_ROOT="${ASSET%.tar.xz}"
readonly RELEASE_URL="https://github.com/${REPOSITORY}/releases/download/${RELEASE_TAG}/${ASSET}"
readonly SOURCE_COMMIT="03902875622f04c8c64ab52fd4dc72981bb93e64"
readonly IRONRDP_REV="33fc287b83af35ba3650519fe059db99d1cdf131"

install_root="${DESTDIR:-}"
if [[ -n "$install_root" && "$install_root" != /* ]]; then
    printf 'ERROR: DESTDIR must be an absolute path\n' >&2
    exit 1
fi

workdir="$(mktemp -d)"
trap 'rm -rf "$workdir"' EXIT
archive="$workdir/$ASSET"
stage="$workdir/extract/$PACKAGE_ROOT"

printf '==> [Lamco] Downloading pinned ARM64 release %s\n' "$RELEASE_TAG"
curl --fail --location --retry 5 --retry-delay 3 --retry-all-errors \
    --connect-timeout 20 --max-time 180 \
    --output "$archive" "$RELEASE_URL"
printf '%s  %s\n' "$ASSET_SHA256" "$archive" | sha256sum -c -
xz -t "$archive"

expected_entries="$(cat <<EOF
$PACKAGE_ROOT/
$PACKAGE_ROOT/BUILD-METADATA.txt
$PACKAGE_ROOT/INSTALL.md
$PACKAGE_ROOT/LICENSE
$PACKAGE_ROOT/LICENSE-APACHE
$PACKAGE_ROOT/README.md
$PACKAGE_ROOT/SBOM.cdx.json
$PACKAGE_ROOT/docs/
$PACKAGE_ROOT/docs/anland-bridge.md
$PACKAGE_ROOT/example-config.toml
$PACKAGE_ROOT/lamco-anland-bridge
EOF
)"
actual_entries="$(tar -tJf "$archive")"
if [[ "$actual_entries" != "$expected_entries" ]]; then
    printf 'ERROR: Lamco release archive contains an unexpected entry set\n' >&2
    exit 1
fi
if tar -tvJf "$archive" | awk 'substr($1, 1, 1) !~ /^[-d]$/ { found = 1 } END { exit !found }'; then
    printf 'ERROR: Lamco release archive contains a non-file entry\n' >&2
    exit 1
fi

mkdir -p "$workdir/extract"
tar -xJf "$archive" -C "$workdir/extract" --no-same-owner --no-same-permissions
for path in \
    "$stage/lamco-anland-bridge" \
    "$stage/BUILD-METADATA.txt" \
    "$stage/README.md" \
    "$stage/INSTALL.md" \
    "$stage/example-config.toml" \
    "$stage/docs/anland-bridge.md" \
    "$stage/LICENSE" \
    "$stage/LICENSE-APACHE" \
    "$stage/SBOM.cdx.json"
do
    [[ -f "$path" && ! -L "$path" ]] || {
        printf 'ERROR: Missing or unsafe release member: %s\n' "$path" >&2
        exit 1
    }
done

file "$stage/lamco-anland-bridge" \
    | grep -Eq 'ELF 64-bit LSB.*(ARM aarch64|AArch64)'
readelf -h "$stage/lamco-anland-bridge" \
    | grep -Eq 'Machine:[[:space:]]+AArch64'
readelf -l "$stage/lamco-anland-bridge" \
    | grep -Fq 'Requesting program interpreter: /lib/ld-linux-aarch64.so.1'

needed="$(readelf -d "$stage/lamco-anland-bridge" | grep NEEDED || true)"
if grep -Eiq 'openh264|x264|avcodec|avformat|avutil|swscale|swresample|ffmpeg' \
    <<<"$needed"; then
    printf 'ERROR: Software H.264 or FFmpeg dependency detected\n' >&2
    exit 1
fi
for library in libgcc_s.so.1 libm.so.6 libc.so.6 ld-linux-aarch64.so.1; do
    grep -Fq "[$library]" <<<"$needed"
done
if grep -F 'Shared library:' <<<"$needed" \
    | grep -Ev '\[(libgcc_s\.so\.1|libm\.so\.6|libc\.so\.6|ld-linux-aarch64\.so\.1)\]$'; then
    printf 'ERROR: Unexpected Lamco shared-library dependency detected\n' >&2
    exit 1
fi

grep -Fxq 'name=lamco-anland-bridge' "$stage/BUILD-METADATA.txt"
grep -Fxq 'version=0.2.0' "$stage/BUILD-METADATA.txt"
grep -Fxq "release_tag=$RELEASE_TAG" "$stage/BUILD-METADATA.txt"
grep -Fxq "source_ref=refs/tags/$RELEASE_TAG" "$stage/BUILD-METADATA.txt"
grep -Fxq "commit=$SOURCE_COMMIT" "$stage/BUILD-METADATA.txt"
grep -Fxq 'target=aarch64-unknown-linux-gnu' "$stage/BUILD-METADATA.txt"
grep -Fxq 'target_cpu=generic' "$stage/BUILD-METADATA.txt"
grep -Fxq 'features=anland-bridge' "$stage/BUILD-METADATA.txt"
grep -Fxq "ironrdp_rev=$IRONRDP_REV" "$stage/BUILD-METADATA.txt"
grep -Fxq 'license=BUSL-1.1' "$stage/BUILD-METADATA.txt"
jq empty "$stage/SBOM.cdx.json"

if [[ -e "$install_root/etc/lamco-anland-bridge/config.toml" || \
      -L "$install_root/etc/lamco-anland-bridge/config.toml" ]]; then
    printf 'ERROR: Refusing to replace an existing Lamco configuration\n' >&2
    exit 1
fi
install -Dm755 "$stage/lamco-anland-bridge" \
    "$install_root/usr/bin/lamco-anland-bridge"
install -d -m 0755 \
    "$install_root/usr/share/doc/lamco-anland-bridge/docs" \
    "$install_root/usr/share/licenses/lamco-anland-bridge" \
    "$install_root/usr/share/sbom/lamco-anland-bridge" \
    "$install_root/etc/lamco-anland-bridge"
install -m 0644 \
    "$stage/README.md" \
    "$stage/INSTALL.md" \
    "$stage/BUILD-METADATA.txt" \
    "$stage/example-config.toml" \
    "$install_root/usr/share/doc/lamco-anland-bridge/"
install -m 0644 "$stage/docs/anland-bridge.md" \
    "$install_root/usr/share/doc/lamco-anland-bridge/docs/"
install -m 0644 "$stage/LICENSE" "$stage/LICENSE-APACHE" \
    "$install_root/usr/share/licenses/lamco-anland-bridge/"
install -m 0644 "$stage/SBOM.cdx.json" \
    "$install_root/usr/share/sbom/lamco-anland-bridge/SBOM.cdx.json"
install -m 0644 "$stage/example-config.toml" \
    "$install_root/etc/lamco-anland-bridge/example-config.toml"

test ! -e "$install_root/etc/lamco-anland-bridge/config.toml"
test ! -L "$install_root/etc/lamco-anland-bridge/config.toml"
printf '==> [Lamco] Installed verified %s (%s)\n' "$ASSET" "$ASSET_SHA256"
