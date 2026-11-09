#!/usr/bin/env bash
# 编译并安装本地化的 mb-tray（MaliBridge 内存上限托盘工具）。
#
# MaliBridge 的离线包只带预编译 mb-tray，界面文案硬编码英文；用户要求按系统
# 语言自动切中文。这里用仓库内 vendored 的 mb-tray-zh.c（上游同一 commit，
# 只加 tr 层）编译出替换二进制，并顺手修正图标 viewBox 的内边距。
set -euo pipefail

desktop="${1:-}"
display_backend="${2:-}"
rootfs="${ROOTFS_DIR:-}"

if [[ "$display_backend" != anland-wayland ]]; then
    exit 0
fi
case "$desktop" in
    niri) ;;
    *) exit 0 ;;
esac
if [[ -n "$rootfs" ]]; then
    exit 0
fi

# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != arch && "${ID:-}" != archarm && "${ID:-}" != archlinux ]]; then
    exit 0
fi

script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd)
vendor_dir=/usr/local/share/droidspaces/mb-tray
[[ -d "$vendor_dir" ]] || vendor_dir="$script_dir/vendor/mb-tray"
src="$vendor_dir/mb-tray-zh.c"
svg="$vendor_dir/mb-budget.svg"
[[ -r "$src" ]] || { echo "缺少 $src" >&2; exit 1; }

# gcc 由 base-devel 提供；GTK3 头文件要显式装（mb-tray 只用 glib/gio，但源码
# 上游用 gtk+-3.0 的 pkg-config 段）。
pacman -S --needed --noconfirm --asdeps base-devel gtk3 pkgconf >/dev/null

tmpbin=$(mktemp /tmp/mb-tray-zh.XXXXXX)
trap 'rm -f "$tmpbin"' EXIT
# shellcheck disable=SC2046
gcc -O2 -Wall -o "$tmpbin" "$src" $(pkg-config --cflags --libs gtk+-3.0 gio-unix-2.0)

# /usr/local/bin/mb-tray 原本是指向 /opt/mali-stack/current/bin 的软链；替换成
# 真实文件，避免覆盖 bundle 里的二进制（升级 mali stack 仍可回退到原版）。
rm -f /usr/local/bin/mb-tray
install -m 0755 "$tmpbin" /usr/local/bin/mb-tray

# 图标内容只占 24 单元中的 19（上下左右各约 2.5 留白），比 Noctalia 其他图标
# 显得更“空”，托盘里左右间距看起来不一致；放在 /usr/local/share 覆盖
# /usr/share 里的原文件，viewBox 收紧到内容边界。
if [[ -r "$svg" ]]; then
    install -D -m 0644 "$svg" /usr/local/share/icons/hicolor/scalable/apps/mb-budget.svg
    gtk-update-icon-cache -f -t /usr/local/share/icons/hicolor >/dev/null 2>&1 || true
fi

# 构建期没有会话总线，--print-menu 仍可直接验证翻译层。
if ! LC_ALL=zh_CN.UTF-8 LANG=zh_CN.UTF-8 /usr/local/bin/mb-tray --print-menu 2>/dev/null | grep -q '总预算'; then
    echo "mb-tray 中文化验证失败（--print-menu 未出现“总预算”）" >&2
    exit 1
fi
if ! LC_ALL=C LANG=C /usr/local/bin/mb-tray --print-menu 2>/dev/null | grep -q 'Total budget'; then
    echo "mb-tray 英文回退验证失败（--print-menu 未出现 Total budget）" >&2
    exit 1
fi
echo "--> [enabled] mb-tray 已本地化安装（zh/en 自动切换）"
