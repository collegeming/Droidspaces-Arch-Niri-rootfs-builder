#!/usr/bin/env bash
# Fedora 45 + KDE Plasma (Anland Wayland) desktop profile for XRING-O3 Mali.
#
# KDE 会话的显示端是 Anland 打补丁的 KWin（patched kwin RPM），GPU 端是
# 发行版 Mesa 的 zink + MaliBridge format ICD；具体环境由
# /usr/local/lib/droidspaces/kde-session-env.sh 在会话启动时注入。
set -euo pipefail

source "${ROOTFS_DIR:-}/etc/os-release"

configure_environment() {
    local backend="${1:-}"
    local environment_file="${ROOTFS_DIR:-}/etc/environment"
    local assignment key
    local -a assignments=(XCURSOR_SIZE=48 XDG_SESSION_CLASS=user)

    case "$backend" in
        anland-wayland)
            # ANLAND_SOCKET 是宿主 display daemon 的 socket；KWin 的 anland
            # backend 直接连它。KWIN_RENDER_NODES / ANLAND_DRM_DEVICE 指向容器
            # 唯一的 DRM 节点（设备没有 renderD）。GPU 细节（zink/ICD/shim）由
            # kde-session-env.sh 负责，这里只写桌面会话本身的变量。
            assignments+=(
                WAYLAND_DISPLAY=wayland-0
                QT_QPA_PLATFORM=wayland
                ANLAND=1
                ANLAND_SOCKET=/run/display.sock
                ANLAND_DRM_DEVICE=/dev/dri/card0
                ANLAND_SKIP_IMPLICIT_SYNC_WAIT=1
                ANLAND_DISABLE_AUDIO=1
                KWIN_RENDER_NODES=/dev/dri/card0
                XWAYLAND_GBM_DEVICE=/dev/dri/card0
                XDG_SESSION_TYPE=wayland
            )
            ;;
        x11)
            assignments+=(DISPLAY=:5)
            ;;
        *)
            echo "KDE 显示后端无效：$backend" >&2
            return 1
            ;;
    esac

    touch "$environment_file"
    for assignment in "${assignments[@]}"; do
        key="${assignment%%=*}"
        sed -i "/^${key}=/d" "$environment_file"
        printf '%s\n' "$assignment" >> "$environment_file"
    done
}

install_fedora() {
    case "${VERSION_ID:-}" in
        45) ;;
        *)
            echo "KDE profile 只支持 Fedora 45（当前：${VERSION_ID:-未知}）。" >&2
            return 1
            ;;
    esac

    # kwin-x11 / plasma-workspace-x11 在 KWin 6.8 已移除，不要安装。
    # mesa-libgbm 提供 shim 依赖的真实 libgbm；mesa-dri-drivers 提供 zink。
    dnf install -y --setopt=install_weak_deps=False \
        dbus-x11 xrandr xset xrdb xhost \
        google-noto-cjk-fonts google-noto-emoji-color-fonts \
        plasma-desktop plasma-workspace kwin kscreen plasma-pa powerdevil \
        kio-extras xdg-user-dirs konsole dolphin kate kinfocenter \
        plasma-systemmonitor kfind filelight systemsettings kscreenlocker \
        kf6-kimageformats plasma-browser-integration breeze-icon-theme plasma-breeze \
        qt6-qtsvg kf6-kirigami \
        pipewire pipewire-alsa pipewire-pulseaudio wireplumber \
        glx-utils pulseaudio-utils vulkan-tools clinfo dmidecode libdisplay-info \
        wayland-utils xorg-x11-server-Xwayland \
        dolphin-plugins ffmpegthumbs kdegraphics-thumbnailers \
        gstreamer1-plugins-base gstreamer1-plugins-good sound-theme-freedesktop \
        mesa-libgbm mesa-dri-drivers
}

install_profile() {
    case "$ID" in
        fedora) install_fedora ;;
        *)
            echo "KDE profile 只支持 Fedora 45（当前：${ID:-未知}）。" >&2
            return 1
            ;;
    esac
}

case "${1:-install}" in
    install) install_profile ;;
    configure-environment) configure_environment "${2:-}" ;;
    *)
        echo "KDE profile 操作无效：$1" >&2
        exit 1
        ;;
esac
