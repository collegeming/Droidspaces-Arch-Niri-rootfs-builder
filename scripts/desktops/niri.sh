#!/usr/bin/env bash
set -euo pipefail

source "${ROOTFS_DIR:-}/etc/os-release"

desktop=niri
xdg_desktop=niri

# This branch is device-specific: the XRING-O3 profile owns the DRM node,
# Mali stack paths and MaliBridge socket. There is no renderD/KGSL fallback.
profile_dir="${DROIDSPACES_DEVICE_PROFILE_DIR:-/usr/local/lib/droidspaces/device}"
profile_file="${XRING_O3_PROFILE_FILE:-${profile_dir}/xring-o3/profile.sh}"
if [[ ! -r "$profile_file" ]]; then
    echo "缺少 XRING-O3 设备档案：$profile_file" >&2
    echo "该分支不包含 Adreno/KGSL 环境；请使用 xring-o3-mali-device 构建。" >&2
    exit 1
fi
# shellcheck source=../device/xring-o3/profile.sh
source "$profile_file"

configure_environment() {
    local backend="${1:-}"
    local environment_file="${ROOTFS_DIR:-}/etc/environment"
    local temporary_file keys_file assignment key
    local -a assignments=() managed_keys=()

    [[ "$backend" == anland-wayland ]] || {
        echo "$desktop 显示后端无效：$backend" >&2
        return 1
    }
    xring_o3_require_active || return 1

    mapfile -t assignments < <(xring_o3_environment_assignments)
    assignments+=("XDG_CURRENT_DESKTOP=$xdg_desktop" "XDG_SESSION_DESKTOP=$xdg_desktop")

    for assignment in "${assignments[@]}"; do
        managed_keys+=("${assignment%%=*}")
    done
    while IFS= read -r key; do
        [[ -n "$key" ]] && managed_keys+=("$key")
    done < <(xring_o3_obsolete_environment_keys)

    touch "$environment_file"
    temporary_file="$(mktemp "${environment_file}.tmp.XXXXXXXX")"
    keys_file="$(mktemp)"
    printf '%s\n' "${managed_keys[@]}" | sort -u > "$keys_file"

    # Overwrite managed keys instead of appending. The old profiles appended
    # only when a key was absent, which left renderD128/kgsl values in place
    # after an upgrade.
    awk -v keys_file="$keys_file" '
        BEGIN {
            while ((getline k < keys_file) > 0) {
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
                if (k != "") drop[k] = 1
            }
        }
        {
            line = $0
            for (k in drop) {
                if (line ~ "^[[:space:]]*(export[[:space:]]+)?" k "[[:space:]]*=") {
                    next
                }
            }
            print
        }
    ' "$environment_file" > "$temporary_file"

    printf '%s\n' "${assignments[@]}" >> "$temporary_file"
    chmod 0644 "$temporary_file"
    cat "$temporary_file" > "$environment_file"
    rm -f -- "$temporary_file" "$keys_file"
}

install_niri_arch() {
    pacman -S --noconfirm --needed \
        xdg-desktop-portal xdg-desktop-portal-gtk \
        alacritty fuzzel mako waybar swaybg swaylock wl-clipboard \
        brightnessctl playerctl \
        pipewire pipewire-alsa pipewire-pulse wireplumber upower \
        mesa-utils vulkan-tools vulkan-icd-loader libdrm zstd clinfo dmidecode wayland-utils \
        xdg-user-dirs glmark2 vkmark \
        gst-plugins-base gst-plugins-good libcanberra sound-theme-freedesktop \
        noto-fonts noto-fonts-cjk noto-fonts-emoji
}

install_minimal_deb() {
    apt-get install -y --no-install-recommends \
        xdg-desktop-portal xdg-desktop-portal-gtk \
        alacritty fuzzel waybar swaylock brightnessctl playerctl \
        wl-clipboard pipewire pipewire-alsa pipewire-pulse wireplumber upower \
        mesa-utils vulkan-tools wayland-utils xdg-user-dirs \
        fonts-noto-core fonts-noto-cjk fonts-noto-color-emoji
}

install_minimal_fedora() {
    dnf install -y --setopt=install_weak_deps=False \
        xdg-desktop-portal xdg-desktop-portal-gtk \
        alacritty fuzzel waybar swaylock brightnessctl playerctl \
        wl-clipboard pipewire pipewire-alsa pipewire-pulseaudio wireplumber upower \
        glx-utils vulkan-tools wayland-utils xdg-user-dirs \
        google-noto-sans-fonts google-noto-sans-cjk-fonts google-noto-color-emoji-fonts
}

install_profile() {
    case "$ID:${VERSION_ID:-}" in
        debian:13*|ubuntu:26.04*) install_minimal_deb ;;
        fedora:43*|fedora:44*) install_minimal_fedora ;;
        arch:*|archarm:*|archlinux:*) install_niri_arch ;;
        *) echo "$desktop 不支持当前发行版：$ID $VERSION_ID" >&2; return 1 ;;
    esac
}

case "${1:-install}" in
    install) install_profile ;;
    configure-environment) configure_environment "${2:-}" ;;
    *) echo "$desktop profile 操作无效：$1" >&2; exit 1 ;;
esac
