#!/usr/bin/env bash
set -euo pipefail

source "${ROOTFS_DIR:-}/etc/os-release"

configure_environment() {
    local backend="${1:-}"
    local environment_file="${ROOTFS_DIR:-}/etc/environment"
    local assignment key
    local -a assignments=(
        XDG_SESSION_TYPE=wayland
        XDG_CURRENT_DESKTOP=niri
        XDG_SESSION_DESKTOP=niri
        QT_QPA_PLATFORM=wayland
        ANLAND=1
        ANLAND_PRESENT_BACKEND=legacy
        ANLAND_SOCKET=/run/display.sock
        ANLAND_DRM_DEVICE=/dev/dri/renderD128
        ANLAND_SKIP_IMPLICIT_SYNC_WAIT=1
        XWAYLAND_GBM_DEVICE=/dev/dri/renderD128
    )

    [[ "$backend" == anland-wayland ]] || {
        echo "Niri 显示后端无效：$backend" >&2
        return 1
    }
    touch "$environment_file"
    for assignment in "${assignments[@]}"; do
        key="${assignment%%=*}"
        if grep -q "^${key}=" "$environment_file"; then
            sed -i "s|^${key}=.*|${assignment}|" "$environment_file"
        else
            printf '%s\n' "$assignment" >> "$environment_file"
        fi
    done
}

install_arch() {
    pacman -S --noconfirm --needed \
        xdg-desktop-portal xdg-desktop-portal-gtk \
        alacritty fuzzel mako waybar swaybg swaylock wl-clipboard \
        noto-fonts noto-fonts-cjk noto-fonts-emoji
}

install_profile() {
    case "$ID" in
        arch|archarm|archlinux) install_arch ;;
        *) echo "Niri 不支持当前发行版：$ID $VERSION_ID" >&2; return 1 ;;
    esac
}

case "${1:-install}" in
    install) install_profile ;;
    configure-environment) configure_environment "${2:-}" ;;
    *) echo "Niri profile 操作无效：$1" >&2; exit 1 ;;
esac
