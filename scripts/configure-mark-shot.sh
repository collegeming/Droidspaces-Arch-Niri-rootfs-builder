#!/usr/bin/env bash
# 安装 mark-shot（Qt6 Wayland 截图标注工具）的官方 aarch64 预编译包。
#
# 为什么用 mark-shot-bin 而不是源码包：源码在设备/CI 上要编译约 13 分钟
# （1489 个 ninja 步骤 + cargo），而官方 Release 直接提供 aarch64 产物。
# 代价：该产物在 Ubuntu 上用 FFmpeg 6 编译，录像插件链 libavcodec.so.60 等
# soname，Arch Linux ARM 是 FFmpeg 9（.so.63），所以「Record GIF / Record
# video」运行时不可用；截图、标注、QR/翻译插件不受影响（实测 3408×2272 正常）。
set -euo pipefail

desktop="${1:-}"
display_backend="${2:-}"
rootfs="${ROOTFS_DIR:-}"
binary="${rootfs}/usr/bin/mark-shot"

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

# 已装源码版时不重复安装（两个包 provides/conflicts 同名）。
if pacman -Qq mark-shot >/dev/null 2>&1; then
    echo "mark-shot（源码包）已安装，跳过 mark-shot-bin"
    exit 0
fi

# 与仓库其它下载一致：GitHub 直连在部分网络下不可用，默认走镜像前缀。
GH_MIRROR_PREFIX=${GH_MIRROR_PREFIX:-https://gh-proxy.com/}

work=$(mktemp -d /tmp/mark-shot.XXXXXX)
trap 'rm -rf "$work"' EXIT

pacman -S --needed --noconfirm git libarchive >/dev/null

# AUR 的 TLS 连接会偶发中断；重试几次再放弃。
cloned=false
for _ in 1 2 3; do
    if git clone --depth=1 https://aur.archlinux.org/mark-shot-bin.git "$work/aur" >/dev/null 2>&1; then
        cloned=true
        break
    fi
    rm -rf "$work/aur"
    sleep 3
done
[[ "$cloned" == true ]] || { echo "AUR mark-shot-bin 克隆失败" >&2; exit 1; }

srcinfo="$work/aur/.SRCINFO"
[[ -f "$srcinfo" ]] || { echo "缺少 .SRCINFO" >&2; exit 1; }
if ! grep -Eq '^[[:space:]]*arch = .*aarch64' "$srcinfo"; then
    echo "AUR mark-shot-bin 不再声明 aarch64，跳过安装" >&2
    exit 0
fi

asset_url=$(sed -n 's/^[[:space:]]*source_aarch64 = //p' "$srcinfo" | head -n1)
asset_sha=$(sed -n 's/^[[:space:]]*sha256sums_aarch64 = //p' "$srcinfo" | head -n1)
[[ -n "$asset_url" && -n "$asset_sha" ]] || {
    echo "AUR 配方缺少 aarch64 产物 URL 或校验和" >&2
    exit 1
}

package_file="$work/mark-shot-bin.pkg.tar.zst"
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

[[ "$(pacman -Qqp "$package_file")" = "mark-shot-bin" ]]
LC_ALL=C pacman -Qip "$package_file" | grep -Eq '^Architecture[[:space:]]*: aarch64$'

# 依赖分两类：包名（qt6-base/grim/...）先补齐；soname（libavcodec.so=60-64）
# 用 --assume-installed 旁路，因为 Arch Linux ARM 的 FFmpeg 9 无法满足 FFmpeg 6
# 的 soname，硬解析会让整次安装失败。
assume=()
deps=()
while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    case "$dep" in
        *.so=*) assume+=(--assume-installed "$dep") ;;
        *) deps+=("$dep") ;;
    esac
done < <(bsdtar -xOf "$package_file" .PKGINFO | sed -n 's/^depend = //p')

missing=()
for dep in "${deps[@]}"; do
    pacman -Qq "$dep" >/dev/null 2>&1 || missing+=("$dep")
done
if [[ ${#missing[@]} -gt 0 ]]; then
    pacman -S --noconfirm --needed --asdeps "${missing[@]}"
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
if [[ ${#assume[@]} -gt 0 ]]; then
    echo "mark-shot: 已旁路 ${#assume[@]} 个 FFmpeg 6 soname 依赖（录像/GIF 不可用，截图/标注正常）"
fi
echo "--> [enabled] mark-shot 已安装（官方 aarch64 预编译包）"
