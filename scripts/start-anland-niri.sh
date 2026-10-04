#!/usr/bin/env bash
set -euo pipefail

socket="${ANLAND_SOCKET:-/run/display.sock}"
[[ -S "$socket" ]] || { echo "缺少 Anland 显示套接字：$socket" >&2; exit 1; }
command -v xwayland-satellite >/dev/null 2>&1 || {
    echo "缺少 xwayland-satellite；请安装对应 Arch 软件包。" >&2
    exit 1
}
for process in niri niri-anland kwin_wayland Hyprland gnome-shell plasmashell startplasma-wayland; do
    if pgrep -u "$(id -u)" -f "(^|/)${process}([[:space:]]|$)" >/dev/null; then
        echo "检测到正在运行的 $process 会话，拒绝启动第二个桌面会话。" >&2
        exit 1
    fi
done

[[ -x /usr/bin/niri-anland ]] || { echo "缺少 Niri 合成器：/usr/bin/niri-anland" >&2; exit 1; }
export ANLAND=1
export ANLAND_PRESENT_BACKEND=legacy
export ANLAND_SOCKET="$socket"
export MESA_LOADER_DRIVER_OVERRIDE="${MESA_LOADER_DRIVER_OVERRIDE:-kgsl}"
export GALLIUM_DRIVER="${GALLIUM_DRIVER:-kgsl}"
export FD_FORCE_KGSL="${FD_FORCE_KGSL:-1}"
export MESA_VK_DEVICE_SELECT_FORCE_DEFAULT_DEVICE="${MESA_VK_DEVICE_SELECT_FORCE_DEFAULT_DEVICE:-1}"
export FD_DEV_FEATURES="${FD_DEV_FEATURES:-enable_tp_ubwc_flag_hint=1}"
export ANLAND_SKIP_IMPLICIT_SYNC_WAIT="${ANLAND_SKIP_IMPLICIT_SYNC_WAIT:-1}"
export ANLAND_DRM_DEVICE="${ANLAND_DRM_DEVICE:-/dev/dri/renderD128}"
export XWAYLAND_GBM_DEVICE="${XWAYLAND_GBM_DEVICE:-$ANLAND_DRM_DEVICE}"
export QT_QPA_PLATFORM="${QT_QPA_PLATFORM:-wayland}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
[[ -d "$XDG_RUNTIME_DIR" && -O "$XDG_RUNTIME_DIR" ]] || {
    echo "无效的用户 runtime 目录：$XDG_RUNTIME_DIR" >&2
    exit 1
}

# 不使用 --session，以免修改全局 D-Bus/systemd 环境。
exec /usr/bin/niri-anland "$@"
