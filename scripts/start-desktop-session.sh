#!/usr/bin/env bash
set -euo pipefail

config="${DROIDSPACES_DESKTOP_CONFIG:-/etc/droidspaces-desktop.conf}"
[[ -r "$config" ]] || { echo "缺少桌面配置文件：$config" >&2; exit 1; }
source "$config"

case "${DESKTOP:-}:${DISPLAY_BACKEND:-}" in
    none:x11) command_line='exit 0' ;;
    kde:x11) command_line='export DISPLAY="${DISPLAY:-:5}"; exec startplasma-x11' ;;
    kde:anland-wayland) command_line='exec startplasma-wayland' ;;
    kde-mobile:anland-wayland) command_line='exec startplasmamobile' ;;
    gnome:anland-wayland) command_line='exec gnome-session --session=gnome' ;;
    # Anland Next 的会话本体就是包内的 anland-session（会话 D-Bus + wayland
    # 链接 + rootless Xwayland + mini-wm），不经过任何桌面环境。用 /usr/bin 下
    # 的系统路径，不依赖用户家目录里的副本；XDG_RUNTIME_DIR 由脚本自己算，
    # systemd 用户管理器不可用时它只告警继续，所以不需要用户级单元先起来。
    anland-next:anland-wayland) command_line='exec /usr/bin/anland-session' ;;
    # niri 会话使用设备上已验证的 kopper + format 组合：会话级环境与 Android host 侧
    # gpu-app-bridge 一致，niri、Xwayland 和 niri 派生的应用都从这套 Mesa/ICD 启动。
    # 未安装 Mali stack 时该脚本不导出任何变量，回退到 /etc/environment。
    niri:anland-wayland)
        session_gpu_env="${XRING_O3_SESSION_GPU_ENV:-/usr/local/lib/droidspaces/device/xring-o3/session-gpu-env.sh}"
        if [[ -r "$session_gpu_env" ]]; then
            # shellcheck source=device/xring-o3/session-gpu-env.sh
            source "$session_gpu_env"
        fi
        command_line='exec /usr/bin/niri-anland'
        ;;
    hyprland:anland-wayland) command_line='exec /usr/bin/hyprland-anland' ;;
    mango:anland-wayland) command_line='exec /usr/bin/mango-anland' ;;
    denial:anland-wayland) command_line='exec /usr/bin/denial-anland' ;;
    *)
        echo "不支持的桌面会话：${DESKTOP:-未设置}/${DISPLAY_BACKEND:-未设置}" >&2
        exit 1
        ;;
esac

if [[ "${DROIDSPACES_SESSION_DRY_RUN:-false}" == true ]]; then
    printf '%s\n' "$command_line"
    exit 0
fi

# Wayland 下剪贴板内容由持有它的进程（wl-copy）提供。上一次会话或测试脚本
# 残留的 wl-copy 会继续占用所有权、把内容覆盖成旧数据，表现为“复制了却粘贴
# 不出来”。进入新会话前清掉本用户的旧 wl-copy：旧进程连接的是上一个
# compositor，已经无法为新会话服务，清理不会丢失当前会话的剪贴板。
pkill -u "$(id -u)" -x wl-copy 2>/dev/null || true

exec /bin/bash -lc "$command_line"
