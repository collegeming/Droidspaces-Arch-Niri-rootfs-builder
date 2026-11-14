#!/usr/bin/env bash
# 安装 Mark Shot 0.2.0-preview.7 的 Arch/ALARM 原生 pacman 包。
#
# 0.2.0 是 Rust 原生重写：
#   - 上游直接发布 aarch64 .pkg.tar.zst，不再需要 AUR 的 Qt 预编译包；
#   - 包内布局为 /usr/bin/mark-shot -> ../lib/mark-shot/mark-shot，
#     录屏/GIF 媒体库在 /usr/lib/mark-shot/media/；
#   - 不再提供 0.1.62 的 libmark-shot-layer-shell.so 和 3 个旧 desktop 文件。
# 因此这里不能沿用旧的“检查 layer-shell 插件/desktop 文件”断言。
set -euo pipefail

desktop="${1:-}"
display_backend="${2:-}"
rootfs="${ROOTFS_DIR:-}"
binary="${rootfs}/usr/bin/mark-shot"
media_lib="${rootfs}/usr/lib/mark-shot/media/libmarkshot-media.so"

# mark-shot 依赖 Wayland + layer-shell，只在 niri/anland-wayland 组合下安装。
if [[ "$display_backend" != anland-wayland ]]; then
    exit 0
fi
case "$desktop" in
    niri) ;;
    *) exit 0 ;;
esac

# ROOTFS_DIR 用于隔离测试；实际 RootFS 构建时为空。
if [[ -n "$rootfs" ]]; then
    exit 0
fi

# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != arch && "${ID:-}" != archarm && "${ID:-}" != archlinux ]]; then
    echo "mark-shot 仅支持 Arch 系发行版，跳过（当前：${ID:-unknown}）" >&2
    exit 0
fi

MARK_SHOT_VERSION=0.2.0_preview.7
MARK_SHOT_PKG="mark-shot-bin-${MARK_SHOT_VERSION}-1-aarch64.pkg.tar.zst"
MARK_SHOT_URL="https://github.com/jswysnemc/mark-shot/releases/download/native-v0.2.0-preview.7/${MARK_SHOT_PKG}"
MARK_SHOT_SHA256=f19f5d3a0d735682c9572f862ce935ad34ee0329a937c238ee10395fa16661d1

# 与仓库其它下载一致：GitHub 直连在部分网络下不可用，默认走镜像前缀。
GH_MIRROR_PREFIX=${GH_MIRROR_PREFIX:-https://gh-proxy.com/}

work=$(mktemp -d /tmp/mark-shot.XXXXXX)
trap 'rm -rf "$work"' EXIT

pacman -S --needed --noconfirm curl libarchive openssl-3 >/dev/null

# 旧 0.1.62 可能是 mark-shot、mark-shot-bin 或 mark-shot-arch-bin；三者互相
# 冲突，直接覆盖安装会停在冲突提示。这里只移除旧包，不用 -Rns，避免连带删掉
# 仍被其他应用使用的 Qt/图形依赖。
for old_pkg in mark-shot mark-shot-arch-bin mark-shot-bin; do
    if pacman -Qq "$old_pkg" >/dev/null 2>&1; then
        pacman -R --noconfirm "$old_pkg"
    fi
done

package_file="$work/$MARK_SHOT_PKG"
downloaded=false
# 镜像可能返回 200 的错误页，所以每个源都做完整 sha256 校验，失败换下一个。
for candidate in "${GH_MIRROR_PREFIX%/}/${MARK_SHOT_URL}" "$MARK_SHOT_URL"; do
    if curl -fsSL --retry 2 --retry-delay 2 --max-time 300 -o "$package_file" "$candidate" && \
        printf '%s  %s\n' "$MARK_SHOT_SHA256" "$package_file" | sha256sum -c - >/dev/null 2>&1; then
        downloaded=true
        break
    fi
    echo "mark-shot: 下载或校验失败，尝试下一个源：$candidate" >&2
done
[[ "$downloaded" == true ]] || { echo "mark-shot 下载失败" >&2; exit 1; }

[[ "$(pacman -Qqp "$package_file")" = "mark-shot-bin" ]]
LC_ALL=C pacman -Qip "$package_file" | grep -Eq '^Architecture[[:space:]]*: aarch64$'

# 0.2.0 的 PKGINFO 只声明 openssl，但二进制实际需要 libssl.so.3/libcrypto.so.3；
# Arch 的 openssl 4.x 只提供 .so.4，因此显式保证 openssl-3 存在。
pacman -S --needed --noconfirm openssl-3 >/dev/null

# CI 的基础镜像把 LocalFileSigLevel 设成 Required，未签名的上游包会被拒绝；
# 用临时 pacman 配置只放宽本次安装，不改系统策略。
pacman_conf=/tmp/pacman-mark-shot.conf
sed -e '/^[[:space:]]*LocalFileSigLevel[[:space:]]*=/d' \
    -e '/^\[options\][[:space:]]*$/a LocalFileSigLevel = Optional' \
    /etc/pacman.conf > "$pacman_conf"
pacman --config "$pacman_conf" -U --noconfirm --needed "$package_file"
rm -f "$pacman_conf"

[[ -x "$binary" ]] || { echo "mark-shot 安装后未找到：$binary" >&2; exit 1; }
[[ -f "$media_lib" ]] || { echo "mark-shot 安装后缺少媒体库：$media_lib" >&2; exit 1; }
echo "--> [enabled] mark-shot-bin ${MARK_SHOT_VERSION} 已安装（native，含录屏/GIF 媒体库）"
