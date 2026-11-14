#!/usr/bin/env bash
# Fedora 45 + KDE (Anland Wayland) 用户态偏好固化。
#
# 仅在 Fedora 镜像构建末尾运行（ROOTFS_DIR 为空）。职责：
#   - 安装/复制 kitty、fish+tide+reef、foot、Nemo、fastfetch、fcitx5/Rime；
#   - 写入与 Arch 侧一致的终端/文件管理器/输入法偏好；
#   - 预部署 Maple Mono NF CN 与雾凇拼音，避免首次登录等待；
#   - Mark Shot 的 RPM 由 Dockerfile 安装，F1/F3 由 configure-desktop 注册。
#
# 本脚本不启用 fcitx5 自启动：KDE 下必须由 KWin 根据
# [Wayland] InputMethod=<org.fcitx.Fcitx5.desktop> 启动它，才能拿到
# KWin 私有连接上的 zwp_input_method_v1/zwp_input_panel_v1。
set -euo pipefail

username="${1:-${USERNAME:-}}"
[[ -n "$username" ]] || { echo "configure-fedora-kde: 缺少用户名" >&2; exit 1; }

rootfs="${ROOTFS_DIR:-}"
home_rel="/home/$username"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
assets="$script_dir/assets"
if [[ ! -d "$assets" ]]; then
    assets=/usr/local/lib/droidspaces/preferences/assets
fi
[[ -d "$assets" ]] || { echo "configure-fedora-kde: 缺少偏好资产目录：$assets" >&2; exit 1; }

GH_MIRROR_PREFIX="${GH_MIRROR_PREFIX:-https://gh-proxy.com/}"
FONT_SIZE="${PREFERENCES_FONT_SIZE:-12.0}"
MAPLE_URL="https://github.com/subframe7536/maple-font/releases/download/v7.9/MapleMono-NF-CN.zip"
RIME_REPO="https://github.com/iDvel/rime-ice"

log() { printf '%s\n' "--> [fedora-kde] $*"; }
warn() { printf '%s\n' "--> [fedora-kde][warn] $*" >&2; }

install_asset() {
    local rel="$1" dest="$2" mode="${3:-0644}"
    install -D -m "$mode" "$assets/$rel" "$rootfs$dest"
}

user_chown() {
    chown -R "$username:$username" "$rootfs$home_rel" 2>/dev/null || true
}

# ---------------------------------------------------------------- packages
# kde.sh 已把桌面包一并装好；这里只补偏好脚本自身需要的工具，重复安装是幂等的。
if command -v dnf >/dev/null 2>&1; then
    dnf install -y --setopt=install_weak_deps=False \
        curl ca-certificates git unzip fontconfig librime-tools >/dev/null
fi

# ---------------------------------------------------------------- fonts
if ! fc-list 2>/dev/null | grep -qi 'Maple Mono'; then
    font_tmp="$(mktemp -d /tmp/maple-font.XXXXXX)"
    font_zip="$font_tmp/MapleMono-NF-CN.zip"
    downloaded=false
    for candidate in "$MAPLE_URL" "${GH_MIRROR_PREFIX%/}/$MAPLE_URL"; do
        if curl -fL --retry 2 --retry-delay 2 --max-time 300 -o "$font_zip" "$candidate"; then
            downloaded=true
            break
        fi
    done
    if [[ "$downloaded" == true ]]; then
        install -d -m 0755 "$rootfs/usr/share/fonts/MapleMono"
        unzip -q -o "$font_zip" -d "$rootfs/usr/share/fonts/MapleMono"
        fc-cache -f >/dev/null 2>&1 || true
        log "已安装 Maple Mono NF CN"
    else
        warn "Maple Mono NF CN 下载失败；终端会回退到系统等宽字体"
    fi
    rm -rf "$font_tmp"
else
    log "Maple Mono 已存在"
fi

# ---------------------------------------------------------------- Rime
if [[ ! -f "$rootfs/usr/share/rime-data/rime_ice.schema.yaml" ]]; then
    rime_tmp="$(mktemp -d /tmp/rime-ice.XXXXXX)"
    if git clone --depth=1 "$RIME_REPO" "$rime_tmp/src" >/dev/null 2>&1; then
        install -d -m 0755 "$rootfs/usr/share/rime-data"
        cp -a "$rime_tmp/src/." "$rootfs/usr/share/rime-data/"
        rm -rf "$rootfs/usr/share/rime-data/.git" "$rootfs/usr/share/rime-data/build"
        log "已安装雾凇拼音共享数据"
    else
        warn "rime-ice 克隆失败；fcitx5 将在首次使用时尝试部署"
    fi
    rm -rf "$rime_tmp"
fi
install -d -m 0755 "$rootfs/usr/share/rime-data" "$rootfs$home_rel/.local/share/fcitx5/rime"
install_asset fcitx5/rime/default.custom.yaml "$home_rel/.local/share/fcitx5/rime/default.custom.yaml"
user_chown
# 共享数据已存在时，用户目录只保留覆盖项，避免同一份 schema 出现两份副本。
if command -v rime_deployer >/dev/null 2>&1 && [[ -z "$rootfs" ]]; then
    if runuser -u "$username" -- env HOME="$home_rel" \
        rime_deployer --build "$home_rel/.local/share/fcitx5/rime" /usr/share/rime-data \
        "$home_rel/.local/share/fcitx5/rime/build" >/dev/null 2>&1; then
        log "Rime 构建目录已预生成"
    else
        warn "rime_deployer 预构建失败；首次登录时由 fcitx5 再部署"
    fi
fi

# ---------------------------------------------------------------- fish/tide/reef
if [[ -d "$assets/fish-fedora" ]]; then
    install -d -m 0755 "$rootfs$home_rel/.config/fish"
    cp -a "$assets/fish-fedora/." "$rootfs$home_rel/.config/fish/"
    log "已复制 fish + tide 配置"
fi
if [[ -f "$assets/reef/reef" ]]; then
    install -D -m 0755 "$assets/reef/reef" "$rootfs/usr/local/bin/reef"
    install -D -m 0644 "$assets/reef/reef.fish" "$rootfs/usr/share/fish/vendor_conf.d/reef.fish"
    log "已安装 reef"
fi
if command -v usermod >/dev/null 2>&1; then
    usermod -s /usr/bin/fish "$username" 2>/dev/null || warn "无法把 $username 的登录 shell 改为 fish"
fi
user_chown
if [[ -z "$rootfs" ]] && command -v fish >/dev/null 2>&1; then
    # tide 的 universal 变量由 tide-apply.fish 一次性写入；失败不阻断构建。
    runuser -u "$username" -- env HOME="$home_rel" fish -c \
        'test -r ~/.config/fish/tide-apply.fish; and source ~/.config/fish/tide-apply.fish' \
        >/dev/null 2>&1 || warn "tide-apply.fish 执行失败，首次登录时再应用"
fi

# ---------------------------------------------------------------- terminals
install -d -m 0755 "$rootfs$home_rel/.config/kitty"
sed "s/@FONT_SIZE@/$FONT_SIZE/" "$assets/kitty/kitty.conf" \
    > "$rootfs$home_rel/.config/kitty/kitty.conf.tmp"
install -m 0644 "$rootfs$home_rel/.config/kitty/kitty.conf.tmp" \
    "$rootfs$home_rel/.config/kitty/kitty.conf"
rm -f "$rootfs$home_rel/.config/kitty/kitty.conf.tmp"
# Fedora/KDE 使用 KWin 的服务端窗口装饰（关闭/最大化/最小化按钮），
# 关闭 kitty 自己绘制的内部标题栏；同时把默认窗口放大到 140x38 单元格。
# Arch+niri 仍保留原来的无按钮紧凑样式，不做这两项覆盖。
kitty_conf="$rootfs$home_rel/.config/kitty/kitty.conf"
sed -i \
    -e 's/^hide_window_decorations yes$/hide_window_decorations no/' \
    -e 's/^window_title_bar_min_windows 1$/window_title_bar_min_windows 0/' \
    -e '/^initial_window_width /d' \
    -e '/^initial_window_height /d' \
    "$kitty_conf"
cat >> "$kitty_conf" <<'EOF'

# Fedora KDE: KWin server-side decorations + larger default window
initial_window_width 140c
initial_window_height 38c
EOF
install_asset kitty/themes/frappe.conf "$home_rel/.config/kitty/themes/frappe.conf"
install_asset foot/foot.ini "$home_rel/.config/foot/foot.ini"
install_asset xdg-terminal-exec/terminal-exec "$home_rel/.config/xdg-terminal-exec/xdg-terminals.list"

# ---------------------------------------------------------------- file manager / terminal opener
install_asset nemo/open-terminal /usr/local/bin/open-terminal 0755
install_asset nemo/open-terminal.nemo_action /usr/share/nemo/actions/open-terminal.nemo_action

# ---------------------------------------------------------------- fastfetch
install_asset fastfetch/config-fedora.jsonc "$home_rel/.config/fastfetch/config.jsonc"
install_asset fastfetch/ff-shell-stack /usr/local/bin/ff-shell-stack 0755
install_asset fastfetch/ff-sdks /usr/local/bin/ff-sdks 0755

# ---------------------------------------------------------------- fcitx5 / GTK / fontconfig
install_asset fcitx5/config "$home_rel/.config/fcitx5/config"
install_asset fcitx5/profile "$home_rel/.config/fcitx5/profile"
install_asset fcitx5/conf/classicui.conf "$home_rel/.config/fcitx5/conf/classicui.conf"
install_asset fontconfig/fonts.conf "$home_rel/.config/fontconfig/fonts.conf"
install_asset gtk-3.0/settings.ini "$home_rel/.config/gtk-3.0/settings.ini"
install_asset gtk-3.0/gtk.css "$home_rel/.config/gtk-3.0/gtk.css"
install_asset gtk-4.0/settings.ini "$home_rel/.config/gtk-4.0/settings.ini"
install_asset gtk-4.0/gtk.css "$home_rel/.config/gtk-4.0/gtk.css"
install_asset environment.d/gtk.conf "$home_rel/.config/environment.d/gtk.conf"

# 只保留 XWayland 兼容变量，不设置 QT_IM_MODULE/GTK_IM_MODULE：
# KDE Wayland 下 Qt/GTK 应使用 KWin 的 text-input-v3，再由 KWin 的
# input-method-v1 转给 fcitx5；设置 immodule 会绕过 Wayland 原生前端，
# fcitx5 会弹出“Wayland 诊断”提示，并且不同应用的输入状态不一致。
install -d -m 0755 "$rootfs$home_rel/.config/environment.d"
cat > "$rootfs$home_rel/.config/environment.d/99-ime.conf" <<'EOF'
XMODIFIERS=@im=fcitx
INPUT_METHOD=fcitx
EOF
chmod 0644 "$rootfs$home_rel/.config/environment.d/99-ime.conf"

# fcitx5 Classic UI 主题：classicui.conf 引用 catppuccin-mocha-mauve，
# 但 Fedora 包只带 default/default-dark；不装主题会退化成默认样式。
install -d -m 0755 "$rootfs/usr/share/fcitx5/themes"
cp -a "$assets/fcitx5/themes/catppuccin-mocha-mauve" "$rootfs/usr/share/fcitx5/themes/"
chmod -R a+rX "$rootfs/usr/share/fcitx5/themes/catppuccin-mocha-mauve"

# 旧的 fcitx5 autostart（包括被改名成 .disabled 的文件）必须清掉：
# KWin 启动的实例才是 Wayland 输入法，额外的 systemd autostart 会抢总线名。
rm -f "$rootfs$home_rel/.config/autostart/fcitx5.desktop" \
      "$rootfs$home_rel/.config/autostart/fcitx5.desktop.disabled"

# ---------------------------------------------------------------- user dirs
install_asset xdg-user-dirs/user-dirs.dirs "$home_rel/.config/user-dirs.dirs"
user_chown
if command -v xdg-user-dirs-update >/dev/null 2>&1 && [[ -z "$rootfs" ]]; then
    runuser -u "$username" -- env HOME="$home_rel" xdg-user-dirs-update >/dev/null 2>&1 || true
fi

user_chown
log "Fedora KDE 用户态偏好已应用"
