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

    # KDE 的 fcitx5 由 KWin 作为 Wayland 输入法进程启动（见 configure-desktop
    # 写入的 [Wayland] InputMethod）。Qt/GTK 客户端仍通过 immodule 接入 fcitx5，
    # 这里给整个会话补齐前端变量；Wayland 原生 text-input 客户端（kitty/foot）
    # 由 KWin 的 input-method-v1 通道处理，不依赖这些变量。
    if [[ -x "${ROOTFS_DIR:-}/usr/bin/fcitx5" ]]; then
        assignments+=(
            QT_IM_MODULE=fcitx
            GTK_IM_MODULE=fcitx
            SDL_IM_MODULE=fcitx
            XMODIFIERS=@im=fcitx
            INPUT_METHOD=fcitx
        )
    fi

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
        kio-extras xdg-user-dirs kate kinfocenter \
        plasma-systemmonitor kfind filelight systemsettings kscreenlocker \
        kf6-kimageformats plasma-browser-integration breeze-icon-theme plasma-breeze \
        qt6-qtsvg kf6-kirigami \
        pipewire pipewire-alsa pipewire-pulseaudio wireplumber \
        glx-utils pulseaudio-utils vulkan-tools clinfo dmidecode libdisplay-info \
        wayland-utils xorg-x11-server-Xwayland \
        ffmpegthumbs kdegraphics-thumbnailers \
        gstreamer1-plugins-base gstreamer1-plugins-good sound-theme-freedesktop \
        mesa-libgbm mesa-dri-drivers \
        kitty kitty-kitten kitty-shell-integration kitty-terminfo \
        fish foot nemo nemo-extensions nemo-python nemo-search-helpers folder-color-switcher-nemo \
        xdg-terminal-exec wl-clipboard kdotool \
        fcitx5 fcitx5-qt fcitx5-gtk fcitx5-rime fcitx5-configtool \
        librime-lua librime-octagram librime-predict librime-tools \
        unzip fontconfig
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
