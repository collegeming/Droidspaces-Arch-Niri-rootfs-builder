#!/usr/bin/env bash
set -euo pipefail

VERSION="${VERSION:-dev}"
DOCKERFILE="Droidspaces-Arch-Niri.Dockerfile"
USERNAME="colle"
TERMINAL="kitty"
REMOTE="wayvnc"
NIRI_AUTOSTART="true"
ENABLE_ZH_LOCALE="true"
ENABLE_FCITX_RIME="true"
ENABLE_QUALCOMM_MESA="true"
ENABLE_SYSTEMD257="true"
ENABLE_USB_MANAGER="true"
ENABLE_FIRMWARE="false"
ENABLE_BINFMT="false"
ENABLE_CONTAINER_INTEGRATION="true"
ENABLE_8GEN2_WAYLAND="false"
ENABLE_DEV_TOOLS="false"
ENABLE_COMPRESSION_TOOLS="true"
ENABLE_DOCKER="false"
ENABLE_TMOE="false"

usage() {
    cat <<'EOF'
Usage: build_rootfs-qemu-aarch64.sh [options]
  -i FILE   Active Dockerfile (default: Droidspaces-Arch-Niri.Dockerfile)
  -v VALUE  Artifact version label
  -u USER   RootFS desktop user
  -T VALUE  Terminal: kitty|ghostty|both
  -R VALUE  Remote access: none|wayvnc|lamco
  -N BOOL   Auto-start niri
  -g BOOL   Chinese locale and Asia/Shanghai timezone
  -h BOOL   Fcitx5 + Rime-Ice
  -c BOOL   Qualcomm KGSL Mesa
  -S BOOL   systemd 257 compatibility runtime
  -U BOOL   Droidspaces USB Manager
  -F BOOL   Linux firmware packages
  -a BOOL   In-RootFS binfmt helpers
  -b BOOL   Droidspaces hardware/network integration
  -t BOOL   Snapdragon 8 Gen 2 Wayland UBWC hint
  -d BOOL   Development toolchain
  -e BOOL   Compression tools
  -f BOOL   Docker packages
  -j BOOL   TMOE
EOF
}

while getopts ":i:v:u:T:R:N:g:h:c:S:U:F:a:b:t:d:e:f:j:" opt; do
    case "$opt" in
        i) DOCKERFILE="$OPTARG" ;;
        v) VERSION="$OPTARG" ;;
        u) USERNAME="$OPTARG" ;;
        T) TERMINAL="$OPTARG" ;;
        R) REMOTE="$OPTARG" ;;
        N) NIRI_AUTOSTART="$OPTARG" ;;
        g) ENABLE_ZH_LOCALE="$OPTARG" ;;
        h) ENABLE_FCITX_RIME="$OPTARG" ;;
        c) ENABLE_QUALCOMM_MESA="$OPTARG" ;;
        S) ENABLE_SYSTEMD257="$OPTARG" ;;
        U) ENABLE_USB_MANAGER="$OPTARG" ;;
        F) ENABLE_FIRMWARE="$OPTARG" ;;
        a) ENABLE_BINFMT="$OPTARG" ;;
        b) ENABLE_CONTAINER_INTEGRATION="$OPTARG" ;;
        t) ENABLE_8GEN2_WAYLAND="$OPTARG" ;;
        d) ENABLE_DEV_TOOLS="$OPTARG" ;;
        e) ENABLE_COMPRESSION_TOOLS="$OPTARG" ;;
        f) ENABLE_DOCKER="$OPTARG" ;;
        j) ENABLE_TMOE="$OPTARG" ;;
        :) printf 'Error: -%s requires a value.\n' "$OPTARG" >&2; usage >&2; exit 2 ;;
        \?) printf 'Error: unknown option -%s.\n' "$OPTARG" >&2; usage >&2; exit 2 ;;
    esac
done

is_bool() {
    [[ "$1" == "true" || "$1" == "false" ]]
}

[[ -f "$DOCKERFILE" ]] || { printf 'Error: active Dockerfile not found: %s\n' "$DOCKERFILE" >&2; exit 1; }
[[ "$(basename "$DOCKERFILE")" == "Droidspaces-Arch-Niri.Dockerfile" ]] || {
    printf 'Error: this active builder only accepts Droidspaces-Arch-Niri.Dockerfile.\n' >&2
    exit 1
}
[[ "$VERSION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { printf 'Error: VERSION contains unsafe characters.\n' >&2; exit 1; }
[[ "$USERNAME" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || { printf 'Error: USERNAME is invalid.\n' >&2; exit 1; }
case "$TERMINAL" in kitty|ghostty|both) ;; *) printf 'Error: terminal must be kitty, ghostty, or both.\n' >&2; exit 1 ;; esac
case "$REMOTE" in none|wayvnc|lamco) ;; *) printf 'Error: remote must be none, wayvnc, or lamco.\n' >&2; exit 1 ;; esac
for value in "$NIRI_AUTOSTART" "$ENABLE_ZH_LOCALE" "$ENABLE_FCITX_RIME" "$ENABLE_QUALCOMM_MESA" "$ENABLE_SYSTEMD257" "$ENABLE_USB_MANAGER" "$ENABLE_FIRMWARE" "$ENABLE_BINFMT" "$ENABLE_CONTAINER_INTEGRATION" "$ENABLE_8GEN2_WAYLAND" "$ENABLE_DEV_TOOLS" "$ENABLE_COMPRESSION_TOOLS" "$ENABLE_DOCKER" "$ENABLE_TMOE"; do
    is_bool "$value" || { printf 'Error: boolean options must be true or false (got %s).\n' "$value" >&2; exit 1; }
done

case "$(uname -m)" in
    x86_64|amd64) ;;
    aarch64|arm64)
        printf 'Error: this is the QEMU script; use build_rootfs-native.sh on ARM64.\n' >&2
        exit 1
        ;;
    *) printf 'Error: QEMU builder requires an x86_64 host.\n' >&2; exit 1 ;;
esac

if [[ "$TERMINAL" == "both" ]]; then
    combined_outputs=(
        "Droidspaces-Arch-Niri-Anland-aarch64-${VERSION}-${REMOTE}-kitty.tar.xz"
        "Droidspaces-Arch-Niri-Anland-aarch64-${VERSION}-${REMOTE}-ghostty.tar.xz"
    )
    trap 'rm -f -- "${combined_outputs[@]}"' EXIT
    for terminal_variant in kitty ghostty; do
        "$0" \
            -i "$DOCKERFILE" -v "$VERSION" -u "$USERNAME" \
            -T "$terminal_variant" -R "$REMOTE" -N "$NIRI_AUTOSTART" \
            -g "$ENABLE_ZH_LOCALE" -h "$ENABLE_FCITX_RIME" \
            -c "$ENABLE_QUALCOMM_MESA" -S "$ENABLE_SYSTEMD257" \
            -U "$ENABLE_USB_MANAGER" -F "$ENABLE_FIRMWARE" \
            -a "$ENABLE_BINFMT" -b "$ENABLE_CONTAINER_INTEGRATION" \
            -t "$ENABLE_8GEN2_WAYLAND" -d "$ENABLE_DEV_TOOLS" \
            -e "$ENABLE_COMPRESSION_TOOLS" -f "$ENABLE_DOCKER" \
            -j "$ENABLE_TMOE"
    done
    trap - EXIT
    printf 'Build completed: %s\n' "${combined_outputs[@]}"
    exit 0
fi

BUILDER_REPOSITORY="${BUILDER_REPOSITORY:-collegeming/Droidspaces-Arch-Niri-rootfs-builder}"
BUILDER_COMMIT="${BUILDER_COMMIT:-$(git rev-parse HEAD 2>/dev/null || printf unknown)}"
PREFIX="Droidspaces-Arch-Niri"
TARGET_ARCH="aarch64"
PLATFORM="linux/arm64"
TEMP_TAR="custom-${PREFIX}-${REMOTE}-${TERMINAL}-rootfs.tar"
FINAL_NAME="${PREFIX}-Anland-${TARGET_ARCH}-${VERSION}-${REMOTE}-${TERMINAL}.tar.xz"

cleanup() { rm -f -- "$TEMP_TAR" "${TEMP_TAR}.xz"; }
trap cleanup EXIT

printf '%s\n' \
    "=========================================================" \
    " Build target : $PREFIX" \
    " Build mode   : x86_64 host with explicit QEMU ARM64" \
    " Platform     : $PLATFORM" \
    " Version      : $VERSION" \
    " Terminal     : $TERMINAL" \
    " Remote       : $REMOTE" \
    "========================================================="

docker run --privileged --rm tonistiigi/binfmt:qemu-v9.2.2 --install arm64
if ! docker buildx inspect droidspaces-builder >/dev/null 2>&1; then
    docker buildx create --name droidspaces-builder --driver docker-container --use
else
    docker buildx use droidspaces-builder
fi
docker buildx inspect --bootstrap

build_args=(
    --platform "$PLATFORM"
    --target export
    --output "type=tar,dest=$TEMP_TAR"
    --build-arg "USERNAME=$USERNAME"
    --build-arg "TERMINAL_ARG=$TERMINAL"
    --build-arg "REMOTE_ARG=$REMOTE"
    --build-arg "NIRI_AUTOSTART_ARG=$NIRI_AUTOSTART"
    --build-arg "ENABLE_ZH_LOCALE_ARG=$ENABLE_ZH_LOCALE"
    --build-arg "ENABLE_FCITX_RIME_ARG=$ENABLE_FCITX_RIME"
    --build-arg "ENABLE_QUALCOMM_MESA_ARG=$ENABLE_QUALCOMM_MESA"
    --build-arg "ENABLE_SYSTEMD257_ARG=$ENABLE_SYSTEMD257"
    --build-arg "ENABLE_USB_MANAGER_ARG=$ENABLE_USB_MANAGER"
    --build-arg "ENABLE_FIRMWARE_ARG=$ENABLE_FIRMWARE"
    --build-arg "ENABLE_BINFMT_ARG=$ENABLE_BINFMT"
    --build-arg "ENABLE_CONTAINER_INTEGRATION_ARG=$ENABLE_CONTAINER_INTEGRATION"
    --build-arg "ENABLE_8GEN2_WAYLAND_ARG=$ENABLE_8GEN2_WAYLAND"
    --build-arg "ENABLE_DEV_TOOLS_ARG=$ENABLE_DEV_TOOLS"
    --build-arg "ENABLE_COMPRESSION_TOOLS_ARG=$ENABLE_COMPRESSION_TOOLS"
    --build-arg "ENABLE_DOCKER_ARG=$ENABLE_DOCKER"
    --build-arg "ENABLE_TMOE_ARG=$ENABLE_TMOE"
    --build-arg "BUILDER_REPOSITORY=$BUILDER_REPOSITORY"
    --build-arg "BUILDER_COMMIT=$BUILDER_COMMIT"
)
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    build_args+=(--secret "id=github_token,env=GITHUB_TOKEN")
fi

docker buildx build "${build_args[@]}" -f "$DOCKERFILE" .
xz -T0 -9 -f "$TEMP_TAR"
mv -- "${TEMP_TAR}.xz" "$FINAL_NAME"
trap - EXIT
printf 'Build completed: %s\n' "$FINAL_NAME"
