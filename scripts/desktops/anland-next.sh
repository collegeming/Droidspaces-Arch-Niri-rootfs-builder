#!/usr/bin/env bash
set -euo pipefail

source "${ROOTFS_DIR:-}/etc/os-release"

configure_environment() {
    local backend="${1:-}"
    local environment_file="${ROOTFS_DIR:-}/etc/environment"
    local assignment key
    local -a assignments=(
        XCURSOR_SIZE=48
        XDG_SESSION_TYPE=wayland
        QT_QPA_PLATFORM=wayland
        ANLAND_RUNTIME_DIR=/run/anland
        MESA_LOADER_DRIVER_OVERRIDE=kgsl
        GALLIUM_DRIVER=kgsl
        FD_FORCE_KGSL=1
        ANLAND=1
        ANLAND_SOCKET=/run/display.sock
        ANLAND_DRM_DEVICE=/dev/dri/renderD128
    )

    [[ "$backend" == anland-wayland ]] || {
        echo "Anland Next 显示后端无效：$backend" >&2
        return 1
    }

    touch "$environment_file"
    for assignment in "${assignments[@]}"; do
        key="${assignment%%=*}"
        grep -q "^${key}=" "$environment_file" || printf '%s\n' "$assignment" >> "$environment_file"
    done
}


install_apt() {
    sed -i 's|^path-exclude=/usr/share/locale/\*/LC_MESSAGES/\*.mo|#&|' \
        /etc/dpkg/dpkg.cfg.d/excludes 2>/dev/null || true

    case "$ID:$VERSION_ID" in
        debian:13)
            apt-get install -y --no-install-recommends \
                dbus-x11 x11-xserver-utils fonts-noto-cjk fonts-noto-color-emoji pipewire pipewire-alsa pipewire-pulse \
                wireplumber ark upower konsole dolphin kate kinfocenter mesa-utils pulseaudio-utils vulkan-tools \
                dbus-user-session clinfo dmidecode wayland-utils kfind \
                filelight glmark2 vkmark kio-extras xdg-user-dirs dolphin-plugins ffmpegthumbs kdegraphics-thumbnailers \
                kimageformat6-plugins libcanberra-pulse gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
                sound-theme-freedesktop
            ;;
        ubuntu:26.04)
            apt-get install -y --no-install-recommends \
                dbus-x11 x11-xserver-utils fonts-noto-cjk fonts-noto-color-emoji pipewire pipewire-alsa pipewire-pulse \
                wireplumber ark upower konsole dolphin kate kinfocenter mesa-utils pulseaudio-utils vulkan-tools \
                dbus-user-session clinfo dmidecode wayland-utils kfind filelight \
                glmark2 vkmark kio-extras xdg-user-dirs dolphin-plugins ffmpegthumbs kdegraphics-thumbnailers \
                kimageformat6-plugins libcanberra-pulse gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
                sound-theme-freedesktop libpam-systemd libpam-modules libpam-kwallet5 language-pack-kde-zh-hans \
                language-pack-zh-hans qt6-translations-l10n
            ;;
        *)
            echo "Anland Next 不支持当前系统：$ID $VERSION_ID" >&2
            return 1
            ;;
    esac
}

install_fedora() {
    case "$VERSION_ID" in
        43|44) ;;
        *) echo "Anland Next 不支持 Fedora $VERSION_ID" >&2; return 1 ;;
    esac

    dnf install -y --setopt=install_weak_deps=False \
        dbus-x11 xrandr xset xrdb xhost google-noto-cjk-fonts google-noto-emoji-color-fonts pipewire pipewire-alsa \
        pipewire-pulseaudio wireplumber ark upower konsole dolphin kate kinfocenter glx-utils pulseaudio-utils \
        vulkan-tools clinfo dmidecode wayland-utils kfind \
        filelight glmark2 vkmark kio-extras xdg-user-dirs dolphin-plugins ffmpegthumbs kdegraphics-thumbnailers \
        kf6-kimageformats libcanberra-gtk3 gstreamer1-plugins-base gstreamer1-plugins-good sound-theme-freedesktop
}

install_arch() {
    pacman -S --noconfirm --needed \
        xorg-xrandr noto-fonts-cjk noto-fonts-emoji pipewire pipewire-alsa pipewire-pulse wireplumber ark upower konsole \
        dolphin kate kinfocenter mesa-utils libpulse vulkan-tools clinfo dmidecode wayland-utils kfind \
        filelight glmark2 vkmark kio-extras xdg-user-dirs dolphin-plugins ffmpegthumbs kdegraphics-thumbnailers \
        kimageformats libcanberra gstreamer gst-plugins-base gst-plugins-good sound-theme-freedesktop
}

install_profile() {
    case "$ID" in
        debian|ubuntu) install_apt ;;
        fedora) install_fedora ;;
        arch|archarm|archlinux) install_arch ;;
        *) echo "Anland Next 不支持当前发行版：$ID" >&2; return 1 ;;
    esac
}

case "${1:-install}" in
    install) install_profile ;;
    configure-environment) configure_environment "${2:-}" ;;
    *)
        echo "Anland Next profile 操作无效：$1" >&2
        exit 1
        ;;
esac
