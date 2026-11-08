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
                echo "--> [跳过] 未找到 niri 默认配置，无法写入 mb-tray 自启动：$target" >&2
                continue
            fi
            install -D -m 0644 "$default_config" "$target"
        fi
        if [[ ! -f "$target" ]]; then
            echo "--> [跳过] niri 配置不是普通文件，未写入 mb-tray 自启动：$target" >&2
            continue
        fi
        if grep -q 'droidspaces: mb-tray autostart' "$target"; then
            :
        else
            # spawn-sh 在二进制缺失时只让这条启动命令返回非零，niri 会话继续运行。
            {
                printf '\n'
                printf '%s\n' '// >>> droidspaces: mb-tray autostart (no-op without the Mali stack)'
                printf '%s\n' 'spawn-sh-at-startup "[ -x /usr/local/bin/mb-tray ] && exec /usr/local/bin/mb-tray"'
                printf '%s\n' '// <<< droidspaces: mb-tray autostart'
            } >> "$target"
            echo "--> 已写入 mb-tray 自启动：$target"
        fi
        if grep -q 'droidspaces: Noctalia shell autostart' "$target"; then
            continue
        fi
        # Noctalia 由 Mali stack 安装的 noctalia-dt 包装器启动；缺少 wrapper 时
        # 只记录一条 spawn 失败，不阻断 niri 会话。
        {
            printf '\n'
            printf '%s\n' '// >>> droidspaces: Noctalia shell autostart'
            printf '%s\n' 'spawn-sh-at-startup "[ -x /usr/local/bin/noctalia-dt ] && exec /usr/local/bin/noctalia-dt noctalia"'
            printf '%s\n' '// <<< droidspaces: Noctalia shell autostart'
        } >> "$target"
        echo "--> 已写入 Noctalia 自启动：$target"
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
fi

if [[ "$desktop" == kde ]]; then
    install -d -m 0755 "$rootfs/home/$username/.config"
    cat > "$rootfs/home/$username/.config/kwinrc" <<'EOF'
[Compositing]
Enabled=false
EOF
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
