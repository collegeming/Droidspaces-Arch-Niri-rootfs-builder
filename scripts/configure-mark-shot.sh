#!/usr/bin/env bash
# 安装 AUR mark-shot-arch-bin（Arch/ALARM 双架构预编译包）。
#
# 与旧的 mark-shot-bin 相比：
# - 包由本项目的 aur-release 工作流按 Arch Linux / Arch Linux ARM 分别构建，
#   依赖对齐各发行版的 FFmpeg（ALARM 为 FFmpeg 9），不需要 soname 旁路；
# - aarch64 包自带 libmark-shot-layer-shell.so，截图覆盖层和贴图窗口使用
#   layer-shell，tiling 合成器不会再把它当普通窗口重排；
# - 安装仍然只下载预编译 .pkg.tar.zst，不在镜像构建里编译 Qt。
set -euo pipefail

desktop="${1:-}"
display_backend="${2:-}"
rootfs="${ROOTFS_DIR:-}"
binary="${rootfs}/usr/bin/mark-shot"
layer_shell="${rootfs}/usr/lib/mark-shot/libmark-shot-layer-shell.so"

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

# 已装任意一个 mark-shot 提供者时跳过（三者 provides/conflicts 同名）。
for pkg in mark-shot mark-shot-bin mark-shot-arch-bin; do
    if pacman -Qq "$pkg" >/dev/null 2>&1; then
        echo "$pkg 已安装，跳过 mark-shot-arch-bin"
        exit 0
    fi
done

# 与仓库其它下载一致：GitHub 直连在部分网络下不可用，默认走镜像前缀。
GH_MIRROR_PREFIX=${GH_MIRROR_PREFIX:-https://gh-proxy.com/}

work=$(mktemp -d /tmp/mark-shot.XXXXXX)
trap 'rm -rf "$work"' EXIT

pacman -S --needed --noconfirm git libarchive >/dev/null

# AUR 的 TLS 连接会偶发中断；重试几次再放弃。
cloned=false
for _ in 1 2 3; do
    if git clone --depth=1 https://aur.archlinux.org/mark-shot-arch-bin.git "$work/aur" >/dev/null 2>&1; then
        cloned=true
        break
    fi
    rm -rf "$work/aur"
    sleep 3
done
[[ "$cloned" == true ]] || { echo "AUR mark-shot-arch-bin 克隆失败" >&2; exit 1; }

srcinfo="$work/aur/.SRCINFO"
[[ -f "$srcinfo" ]] || { echo "缺少 .SRCINFO" >&2; exit 1; }
if ! grep -Eq '^[[:space:]]*arch = .*aarch64' "$srcinfo"; then
    echo "AUR mark-shot-arch-bin 不再声明 aarch64，跳过安装" >&2
    exit 0
fi

asset_url=$(sed -n 's/^[[:space:]]*source_aarch64 = //p' "$srcinfo" | head -n1)
asset_sha=$(sed -n 's/^[[:space:]]*sha256sums_aarch64 = //p' "$srcinfo" | head -n1)
[[ -n "$asset_url" && -n "$asset_sha" ]] || {
    echo "AUR 配方缺少 aarch64 产物 URL 或校验和" >&2
    exit 1
}

package_file="$work/mark-shot-arch-bin.pkg.tar.zst"
downloaded=false
# 镜像可能返回 200 的错误页，所以每个源都做完整 sha256 校验，失败换下一个。
for candidate in "${GH_MIRROR_PREFIX%/}/${asset_url}" "$asset_url"; do
    if curl -fsSL --retry 2 --retry-delay 2 --max-time 300 -o "$package_file" "$candidate" && \
        printf '%s  %s\n' "$asset_sha" "$package_file" | sha256sum -c - >/dev/null 2>&1; then
        downloaded=true
        break
    fi
    echo "mark-shot: 下载或校验失败，尝试下一个源：$candidate" >&2
done
[[ "$downloaded" == true ]] || { echo "mark-shot 下载失败" >&2; exit 1; }

[[ "$(pacman -Qqp "$package_file")" = "mark-shot-arch-bin" ]]
LC_ALL=C pacman -Qip "$package_file" | grep -Eq '^Architecture[[:space:]]*: aarch64$'

# 依赖由 .PKGINFO 给出。正常情况全是包名（可带版本约束）；只有配方回退到
# 上游产物时才可能出现 soname，这类依赖用 --assume-installed 兜底，避免整次
# 构建因单个 soname 失败。mark-shot-arch-bin 的依赖应与 ALARM 完全对齐。
assume=()
deps=()
while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    name="${dep%%[<>=]*}"
    if pacman -T "$dep" >/dev/null 2>&1; then
        continue
    fi
    if [[ "$name" == *".so"* ]]; then
        assume+=(--assume-installed "$dep")
        echo "mark-shot: 依赖 $dep 无法由仓库满足，按 assume-installed 放行" >&2
    else
        deps+=("$name")
    fi
done < <(bsdtar -xOf "$package_file" .PKGINFO | sed -n 's/^depend = //p')

if [[ ${#deps[@]} -gt 0 ]]; then
    mapfile -t deps < <(printf '%s\n' "${deps[@]}" | sort -u)
    pacman -S --noconfirm --needed --asdeps "${deps[@]}"
fi

# CI 的基础镜像把 LocalFileSigLevel 设成 Required，未签名的 AUR -bin 包会被
# 拒绝（`package missing required signature`）。用临时 pacman 配置只放宽本
# 次安装，不改系统策略。
pacman_conf=/tmp/pacman-mark-shot.conf
sed -e '/^[[:space:]]*LocalFileSigLevel[[:space:]]*=/d' \
    -e '/^\[options\][[:space:]]*$/a LocalFileSigLevel = Optional' \
    /etc/pacman.conf > "$pacman_conf"
pacman --config "$pacman_conf" -U --noconfirm --needed "${assume[@]}" "$package_file"
rm -f "$pacman_conf"

[[ -x "$binary" ]] || { echo "mark-shot 安装后未找到：$binary" >&2; exit 1; }
[[ -f /usr/share/applications/mark-shot.desktop ]] || {
    echo "mark-shot 安装后缺少桌面入口" >&2
    exit 1
}
[[ -f "$layer_shell" ]] || {
    echo "mark-shot 安装后缺少 layer-shell 插件：$layer_shell" >&2
    exit 1
}
echo "--> [enabled] mark-shot-arch-bin 已安装（含 layer-shell 插件，依赖对齐 ALARM）"
