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

# 上一次会话的 fcitx5 可能由 D-Bus/systemd 用户实例拉起（没有 WAYLAND_DISPLAY，
# 报 "Failed to open wayland connection"），并占着 org.fcitx.Fcitx5 总线名。
# 新会话由 niri spawn 启动带正确环境的实例，所以先清掉旧进程。fcitx5 收到
# SIGTERM 会先保存状态，多个残留实例叠在一起时会拖住退出，补一次 KILL。
pkill -u "$(id -u)" -x fcitx5 2>/dev/null || true
sleep 1
pkill -9 -u "$(id -u)" -x fcitx5 2>/dev/null || true

# droidspaces 把宿主（Android）的 TMPDIR=/data/local/tmp 继承进来，但这个路径在
# 容器里不存在也建不出来。Chromium 的 ProcessSingleton 在创建临时 socket 目录时
# 直接失败并以 "Failed to create socket directory" 退出，表现为双击图标没反应。
export TMPDIR=/tmp

# 会话总线地址不一定由 pam_systemd 传进来。缺了它，niri spawn 的 fcitx5 无法
# 注册 org.fcitx.Fcitx5（实测表现为 fcitx5-remote 无回复、D-Bus 激活又起第二个
# 实例），所有需要会话总线的服务都会退化成“各自为政”。缺失时按标准路径补上。
if [ -z "${DBUS_SESSION_BUS_ADDRESS:-}" ] && [ -S "/run/user/$(id -u)/bus" ]; then
    export DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$(id -u)/bus"
fi

exec /bin/bash -lc "$command_line"
