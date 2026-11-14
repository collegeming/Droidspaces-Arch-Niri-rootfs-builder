#!/usr/bin/env bash
#固化启动参数
set -euo pipefail

desktop="${1:-}"
backend="${2:-}"
autostart="${3:-}"
username="${4:-}"
rootfs="${ROOTFS_DIR:-}"
templates="${START_TEMPLATES_DIR:-/tmp/droidspaces-start}"
profile_dir="${DROIDSPACES_DESKTOP_PROFILE_DIR:-/usr/local/lib/droidspaces/desktops}"
config="$rootfs/etc/droidspaces-desktop.conf"

if [[ -r "$rootfs/etc/os-release" ]]; then
    source "$rootfs/etc/os-release"
fi

configure_anland_next_runtime() {
    local bashrc="$rootfs/home/$username/.bashrc"
    local kate_source="$rootfs/usr/share/applications/org.kde.kate.desktop"
    local kate_override="$rootfs/usr/local/share/applications/org.kde.kate.desktop"
    local kate_wrapper="$rootfs/usr/local/bin/kate"

    install -d -m 0755 "$(dirname "$bashrc")" "$(dirname "$kate_wrapper")"
    touch "$bashrc"

    sed -i '/^# BEGIN droidspaces-anland-next shell environment$/,/^# END droidspaces-anland-next shell environment$/d' "$bashrc"
    cat >> "$bashrc" <<'EOF'
# BEGIN droidspaces-anland-next shell environment
if [ -r "$HOME/.anlandx-env" ]; then
    while IFS= read -r droidspaces_anland_env; do
        case "$droidspaces_anland_env" in
            ''|'#'*) ;;
            *=*) export "$droidspaces_anland_env" ;;
        esac
    done < "$HOME/.anlandx-env"
fi
if [ -r "$HOME/.anlandx" ]; then
    droidspaces_anland_display=''
    IFS= read -r droidspaces_anland_display < "$HOME/.anlandx" || true
    case "$droidspaces_anland_display" in
        :[0-9]*) export DISPLAY="$droidspaces_anland_display" ;;
    esac
fi
unset droidspaces_anland_env droidspaces_anland_display
# END droidspaces-anland-next shell environment
EOF

    if [[ -f "$kate_source" ]]; then
        install -d -m 0755 "$(dirname "$kate_override")"
        if ! awk '
            /^\[Desktop Entry\]$/ { in_main_group = 1 }
            /^\[/ && $0 != "[Desktop Entry]" { in_main_group = 0 }
            in_main_group && /^Exec=/ && !replaced {
                print "Exec=kate -b %U"
                replaced = 1
                next
            }
            { print }
            END { exit replaced ? 0 : 1 }
        ' "$kate_source" > "$kate_override"; then
            cp "$kate_source" "$kate_override"
        fi
        chmod 0644 "$kate_override"
    fi

    cat > "$kate_wrapper" <<'EOF'
#!/bin/sh
for droidspaces_kate_arg in "$@"; do
    case "$droidspaces_kate_arg" in
        -b|--block) exec /usr/bin/kate "$@" ;;
    esac
done
exec /usr/bin/kate -b "$@"
EOF
    chmod 0755 "$kate_wrapper"
}

configure_niri_output_config() {
    local target="$1"
    local scale="${OUTPUT_SCALE:-2}"
    local mode="${OUTPUT_MODE:-native}"
    local tmp

    [[ -f "$target" ]] || return 0

    case "$scale" in
        1|1.5|2|2.5) ;;
        *)
            echo "无效的 Anland 输出缩放：$scale（只支持 1、1.5、2、2.5）" >&2
            exit 1
            ;;
    esac
    if [[ "$mode" != native && ! "$mode" =~ ^[0-9]+x[0-9]+(@[0-9]+(\.[0-9]+)?)?$ ]]; then
        echo "无效的 Anland 输出模式：$mode（应为 native、<宽>x<高> 或 <宽>x<高>@<刷新率>）" >&2
        exit 1
    fi

    tmp="$(mktemp)"
    # 只重写受管块：先删除旧块及其尾部空行，再按当前构建参数追加一次，重复执行结果一致。
    awk '
        /^\/\/ >>> droidspaces: output scale \(managed\)\r?$/ { managed = 1; next }
        /^\/\/ <<< droidspaces: output scale \(managed\)\r?$/ { managed = 0; next }
        managed { next }
        { lines[++count] = $0 }
        END {
            while (count > 0 && lines[count] ~ /^[[:space:]]*$/) count--
            for (i = 1; i <= count; i++) print lines[i]
        }
    ' "$target" > "$tmp"

    {
        printf '\n'
        printf '%s\n' '// >>> droidspaces: output scale (managed)'
        printf '%s\n' 'output "anland-0" {'
        if [[ "$mode" != native ]]; then
            printf '    mode "%s"\n' "$mode"
        fi
        printf '    scale %s\n' "$scale"
        printf '%s\n' '}'
        printf '%s\n' '// <<< droidspaces: output scale (managed)'
    } >> "$tmp"

    chmod 0644 "$tmp"
    mv "$tmp" "$target"
}

configure_niri_output_config_all() {
    local username="$1"
    local seed="$rootfs/usr/local/share/droidspaces/niri-default-config.kdl"
    local -a targets=(
        "$rootfs/home/$username/.config/niri/config.kdl"
        "$rootfs/etc/skel/.config/niri/config.kdl"
    )
    local target

    # 镜像内的默认配置和已铺设的用户配置都使用同一组构建参数，避免两处不一致。
    configure_niri_output_config "$seed"
    for target in "${targets[@]}"; do
        configure_niri_output_config "$target"
    done
}

configure_niri_tray_autostart() {
    local username="$1"
    local default_config="" candidate target
    local -a targets=(
        "$rootfs/home/$username/.config/niri/config.kdl"
        "$rootfs/etc/skel/.config/niri/config.kdl"
    )

    for candidate in \
        "$rootfs/usr/local/share/droidspaces/niri-default-config.kdl" \
        "$rootfs/usr/share/doc/niri/default-config.kdl" \
        "$rootfs/usr/share/doc/niri-anland/default-config.kdl"; do
        if [[ -f "$candidate" ]]; then
            default_config="$candidate"
            break
        fi
    done

    for target in "${targets[@]}"; do
        if [[ ! -e "$target" ]]; then
            if [[ -z "$default_config" ]]; then
                echo "--> [跳过] 未找到 niri 默认配置，无法写入 Noctalia 自启动：$target" >&2
                continue
            fi
            install -D -m 0644 "$default_config" "$target"
        fi
        if [[ ! -f "$target" ]]; then
            echo "--> [跳过] niri 配置不是普通文件，未写入 Noctalia 自启动：$target" >&2
            continue
        fi
        if ! grep -q 'droidspaces: Noctalia shell autostart' "$target"; then
            # Noctalia 由 Mali stack 安装的 noctalia-dt 包装器启动；缺少 wrapper 时
            # 只记录一条 spawn 失败，不阻断 niri 会话。当前 Noctalia CLI 不接受
            # `noctalia` 子命令（会报 unknown command），包装器后不能再带参数。
            {
                printf '\n'
                printf '%s\n' '// >>> droidspaces: Noctalia shell autostart'
                printf '%s\n' 'spawn-sh-at-startup "[ -x /usr/local/bin/noctalia-dt ] && exec /usr/local/bin/noctalia-dt"'
                printf '%s\n' '// <<< droidspaces: Noctalia shell autostart'
            } >> "$target"
            echo "--> 已写入 Noctalia 自启动：$target"
        fi
        if ! grep -q 'droidspaces: Noctalia IP location sync' "$target"; then
            # 按公网 IP 的城市写 Noctalia [location]，避免内置 IP 定位返回国家
            # 质心；脚本自己每 30 分钟刷新，不阻塞 niri 启动。
            {
                printf '\n'
                printf '%s\n' '// >>> droidspaces: Noctalia IP location sync'
                printf '%s\n' 'spawn-sh-at-startup "[ -x /usr/local/bin/noctalia-location-sync ] && setsid /usr/local/bin/noctalia-location-sync >/dev/null 2>&1 &"'
                printf '%s\n' '// <<< droidspaces: Noctalia IP location sync'
            } >> "$target"
            echo "--> 已写入 Noctalia IP 定位同步：$target"
        fi
    done
}

[[ "$desktop" =~ ^(none|[a-z][a-z0-9-]*)$ ]] || { echo "无效的桌面：$desktop" >&2; exit 1; }
case "$backend" in x11|anland-wayland) ;; *) echo "无效的显示后端：$backend" >&2; exit 1 ;; esac
case "$autostart" in true|false) ;; *) echo "无效的桌面自启动值：$autostart" >&2; exit 1 ;; esac
[[ -n "$username" ]] || { echo "必须指定桌面用户名" >&2; exit 1; }

if [[ "$desktop" == none && "$backend" != x11 ]]; then
    echo "不支持的桌面与显示后端组合：$desktop/$backend" >&2
    exit 1
fi
if [[ "$desktop" == kde && "$backend" == x11 && "$ID" =~ ^(arch|archarm|archlinux)$ ]]; then
    echo "Arch Linux 不支持 KDE X11；请使用 Anland Wayland。" >&2
    exit 1
fi
if [[ "$desktop" == kde-mobile && "$backend" != anland-wayland ]]; then
    echo "不支持的桌面与显示后端组合：$desktop/$backend" >&2
    exit 1
fi
if [[ "$desktop" == gnome && "$backend" != anland-wayland ]]; then
    echo "不支持的桌面与显示后端组合：$desktop/$backend" >&2
    exit 1
fi
if [[ "$desktop" == anland-next && "$backend" != anland-wayland ]]; then
    echo "不支持的桌面与显示后端组合：$desktop/$backend" >&2
    exit 1
fi
if [[ "$desktop" =~ ^(niri|hyprland|mango|denial)$ && "$backend" != anland-wayland ]]; then
    echo "不支持的桌面与显示后端组合：$desktop/$backend" >&2
    exit 1
fi

cat > "$config" <<EOF
DESKTOP=$desktop
DISPLAY_BACKEND=$backend
EOF
chmod 0644 "$config"

# upower 在容器里的 systemd 单元默认带 PrivateUsers=yes 和 IPAddressDeny=any：
# 前者需要 user namespace（Droidspaces 禁止非特权 userns），服务以 217/USER
# 反复失败；后者需要 BPF attach，容器内被拒绝。两者失败后 UPower 的 D-Bus
# 名不可用，Noctalia / Plasma 的电池组件就完全不显示电量。
# 这里写入 drop-in：upower 本身不联网，关闭这两项不影响功能。
install -d -m 0755 "$rootfs/etc/systemd/system/upower.service.d"
cat > "$rootfs/etc/systemd/system/upower.service.d/container.conf" <<'EOF'
[Service]
PrivateUsers=no
IPAddressDeny=
EOF
chmod 0644 "$rootfs/etc/systemd/system/upower.service.d/container.conf"

# PipeWire 的 libpipewire-module-rt 会按 realtime portal 的返回值重写整个
# 进程的 RLIMIT_RTTIME；本机 portal 报 0，于是任何 RT 线程一运行就收到
# SIGKILL。niri 启动时会创建 PipeWire 客户端，实测 desktop-session 因此
# 每隔几分钟以 9/KILL 退出并重启（Noctalia 也会被一起带走）。在客户端
# 配置里禁用 module-rt 即可保留普通音频路径，同时不再改动 rlimit。
install -d -m 0755 "$rootfs/etc/pipewire/client.conf.d"
cat > "$rootfs/etc/pipewire/client.conf.d/99-no-rt.conf" <<'EOF'
# RLIMIT_RTTIME must stay unlimited in this container: the realtime portal
# reports rt.time = 0, and module-rt would then set the whole process to 0.
context.properties = {
    module.rt = false
}
EOF
chmod 0644 "$rootfs/etc/pipewire/client.conf.d/99-no-rt.conf"

# 桌面专属环境必须在 Dockerfile 完成 /etc/environment 后配置。
if [[ "$desktop" != none ]]; then
    profile="$profile_dir/$desktop.sh"
    [[ -x "$profile" ]] || { echo "桌面配置脚本不存在或不可执行：$profile" >&2; exit 1; }
    ROOTFS_DIR="$rootfs" DROIDSPACES_DESKTOP="$desktop" "$profile" configure-environment "$backend"
fi

if [[ "$desktop" == anland-next ]]; then
    configure_anland_next_runtime
fi

if [[ "$desktop" == niri ]]; then
    configure_niri_tray_autostart "$username"
    configure_niri_output_config_all "$username"
fi

if [[ "$desktop" == kde ]]; then
    install -d -m 0755 "$rootfs/home/$username/.config"
    # XRING-O3：KDE 走 Anland 的 patched KWin，合成必须保持开启。之前为了
    # 无 GPU 的 X11 容器写 Enabled=false，会把 Anland backend 的输出层变成
    # 纯 CPU 合成；这里固定 OpenGL（zink -> MaliBridge）并关闭会阻塞首帧的
    # 启动检测。
    cat > "$rootfs/home/$username/.config/kwinrc" <<'EOF'
[Compositing]
Enabled=true
Backend=OpenGL
OpenGLIsUnsafe=false
LatencyPolicy=Low
EOF
    # KWin 的 [Wayland] InputMethod 是 **fcitx5 的 .desktop 文件路径**，不是
    # 可执行文件路径。KWin 会自己拉起 fcitx5，并通过私有 WAYLAND_SOCKET 把
    # zwp_input_method_v1/zwp_input_panel_v1 只暴露给这个进程；普通客户端（包括
    # systemd 自启动的 fcitx5）看不到这两个全局，Wayland text-input 客户端
    # （kitty/foot）会退化成只能输入 ASCII。不要同时启用 fcitx5 自启动，否则
    # 两个实例会争抢 org.fcitx.Fcitx5 总线名，KWin 启动的实例反而拿不到名字。
    if [[ -f "$rootfs/usr/share/applications/org.fcitx.Fcitx5.desktop" ]]; then
        cat >> "$rootfs/home/$username/.config/kwinrc" <<'EOF'

[Wayland]
InputMethod=/usr/share/applications/org.fcitx.Fcitx5.desktop
EOF
    fi
    if [[ -n "$rootfs" ]]; then
        chmod 0644 "$rootfs/home/$username/.config/kwinrc"
    fi

    # Plasma 6.8 / KWin 6.8 的输出缩放持久化在 kwinoutputconfig.json，而不是
    # KScreen 5 的 ~/.local/share/kscreen。把系统级默认值写进 /etc/xdg，KWin
    # 首次启动（用户文件尚不存在）会读取它；匹配到 anland-1 后按 200% 应用，
    # 再把同样的配置写回 ~/.config/kwinoutputconfig.json。
    # connectorName 由 Anland KWin backend 固定为 "anland-1"（anland_backend.cpp）；
    # 若后续版本改名，可用 KDE_OUTPUT_CONNECTOR 覆盖。
    kde_scale="${OUTPUT_SCALE:-2}"
    case "$kde_scale" in
        1|1.5|2|2.5) ;;
        *)
            echo "无效的 KDE 输出缩放：$kde_scale（只支持 1、1.5、2、2.5）" >&2
            exit 1
            ;;
    esac
    kde_connector="${KDE_OUTPUT_CONNECTOR:-anland-1}"
    install -d -m 0755 "$rootfs/etc/xdg"
    cat > "$rootfs/etc/xdg/kwinoutputconfig.json" <<EOF
[
  {
    "name": "outputs",
    "data": [
      {
        "connectorName": "$kde_connector",
        "scale": $kde_scale
      }
    ]
  },
  {
    "name": "setups",
    "data": [
      {
        "lidClosed": false,
        "outputs": [
          {
            "enabled": true,
            "outputIndex": 0,
            "priority": 1,
            "position": { "x": 0, "y": 0 }
          }
        ]
      }
    ]
  }
]
EOF
    chmod 0644 "$rootfs/etc/xdg/kwinoutputconfig.json"
    # 用户级配置优先于 /etc/xdg；构建时清掉可能遮蔽默认值的旧文件。
    rm -f "$rootfs/home/$username/.config/kwinoutputconfig.json" \
          "$rootfs/etc/skel/.config/kwinoutputconfig.json"

    # KWin 自己保留 zink（surfaceless EGL + MaliBridge）；客户端会话不能再带
    # GALLIUM_DRIVER=zink，否则 Mesa 在无 renderD 的容器里会走 swrast 平台，
    # zink 无法写回 wl_shm（缺 VK_EXT_external_memory_host），kitty/es2gears
    # 等 Wayland GL 客户端 buffer 全 0、窗口全透明。把 zink 限定在 KWin
    # service 的 Environment 里，plasmashell/终端/浏览器沿会话环境走 llvmpipe。
    install -d -m 0755 "$rootfs/etc/systemd/user/plasma-kwin_wayland.service.d"
    cat > "$rootfs/etc/systemd/user/plasma-kwin_wayland.service.d/10-gpu.conf" <<'EOF'
[Service]
Environment=GALLIUM_DRIVER=zink
Environment=QSG_RHI_BACKEND=opengl
EOF
    chmod 0644 "$rootfs/etc/systemd/user/plasma-kwin_wayland.service.d/10-gpu.conf"
    gpu_env_file="$rootfs/etc/environment.d/90-xring-gpu.conf"
    if [[ -f "$gpu_env_file" ]]; then
        sed -i '/^GALLIUM_DRIVER=/d' "$gpu_env_file"
    fi

    # Plasma 的 QML 表面（桌面壁纸、面板）在 zink → MaliBridge 下会整块
    # 透明/黑色，只剩光标和客户端窗口可见；把 plasmashell 的 Qt Quick
    # 后端切到 software 后壁纸和面板恢复正常，KWin 合成仍是 GPU。
    install -d -m 0755 "$rootfs/etc/systemd/user/plasma-plasmashell.service.d"
    cat > "$rootfs/etc/systemd/user/plasma-plasmashell.service.d/10-software-qml.conf" <<'EOF'
[Service]
Environment=QT_QUICK_BACKEND=software
Environment=QSG_RHI_BACKEND=opengl
EOF
    chmod 0644 "$rootfs/etc/systemd/user/plasma-plasmashell.service.d/10-software-qml.conf"

    # KDE 锁屏 greeter 同样走 QML；当前 GPU 栈下会显示成黑屏/巨型 logo，
    # 且遮住桌面。先关闭自动锁屏，避免用户误以为桌面没有启动。
    install -d -m 0755 "$rootfs/etc/xdg"
    cat > "$rootfs/etc/xdg/kscreenlockerrc" <<'EOF'
[Daemon]
Autolock=false
LockOnResume=false
EOF
    chmod 0644 "$rootfs/etc/xdg/kscreenlockerrc"
    cat > "$rootfs/home/$username/.config/kscreenlockerrc" <<'EOF'
[Daemon]
Autolock=false
LockOnResume=false
EOF
    chmod 0644 "$rootfs/home/$username/.config/kscreenlockerrc"

    # Mark Shot 0.2.x：KDE 没有 niri 的 F1/F3 直接绑定，改用 KGlobalAccel 的
    # 命令快捷键。desktop 文件必须带 X-KDE-GlobalAccel-CommandShortcut=true，
    # kglobalshortcutsrc 里只需保存 [services][<desktop 文件名>] 的 _launch。
    # 只追加缺失的组，保留 KGlobalAccel 自动生成/用户已有的其他快捷键。
    if [[ -e "$rootfs/usr/sbin/mark-shot" || -e "$rootfs/usr/bin/mark-shot" ]]; then
        install -d -m 0755 "$rootfs/home/$username/.local/share/applications"
        cat > "$rootfs/home/$username/.local/share/applications/mark-shot-region.desktop" <<'EOF'
[Desktop Entry]
Exec=/usr/sbin/mark-shot
Name=Mark Shot Region
NoDisplay=true
StartupNotify=false
Type=Application
X-KDE-GlobalAccel-CommandShortcut=true
EOF
        cat > "$rootfs/home/$username/.local/share/applications/mark-shot-pin.desktop" <<'EOF'
[Desktop Entry]
Exec=/usr/sbin/mark-shot --pin-clipboard
Name=Mark Shot Pin
NoDisplay=true
StartupNotify=false
Type=Application
X-KDE-GlobalAccel-CommandShortcut=true
EOF
        chmod 0644 "$rootfs/home/$username/.local/share/applications/mark-shot-region.desktop" \
            "$rootfs/home/$username/.local/share/applications/mark-shot-pin.desktop"
        kglobal="$rootfs/home/$username/.config/kglobalshortcutsrc"
        touch "$kglobal"
        if ! grep -q '^\[services\]\[mark-shot-region\.desktop\]' "$kglobal"; then
            cat >> "$kglobal" <<'EOF'

[services][mark-shot-region.desktop]
_launch=F1

[services][mark-shot-pin.desktop]
_launch=F3
EOF
        fi
        chmod 0644 "$kglobal"
    fi
fi

if [[ -z "$rootfs" ]]; then
    chown -R "$username:$username" "/home/$username"
fi

if [[ "$desktop" == none ]]; then
    [[ "$autostart" == false ]] || { echo "桌面为 none 时不能启用自动启动" >&2; exit 1; }
    exit 0
fi

if [[ "$autostart" == true ]]; then
    install -Dm0644 "$templates/desktop-session.service" \
        "$rootfs/etc/systemd/system/desktop-session.service"
    install -d -m 0755 "$rootfs/etc/systemd/system/multi-user.target.wants"
    ln -sfn /etc/systemd/system/desktop-session.service \
        "$rootfs/etc/systemd/system/multi-user.target.wants/desktop-session.service"
fi
