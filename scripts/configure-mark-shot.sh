#!/usr/bin/env bash
# 在 Arch rootfs 中从 AUR 构建并安装 mark-shot（Qt6 Wayland 截图标注工具）。
#
# 为什么用源码包而不是官方 aarch64 预编译包（mark-shot-bin）：
#   预编译包在 Ubuntu/FFmpeg 6 上编译，录像插件链 libavcodec.so.60 等 soname，
#   而 Arch Linux ARM 是 FFmpeg 9（.so.63）：pacman 需要 --assume-installed
#   旁路依赖，且「Record GIF / Record video」运行时必然失败。截图/标注本身
#   在两种包里都正常（前提是会话环境带 XDG_SESSION_TYPE=wayland，否则会退回
#   Qt 的 grabWindow 并报 null pixmap）。源码构建能让录像也按 Arch 的 FFmpeg 9
#   链接，功能完整；若只在意构建速度，可改用 mark-shot-bin + --assume-installed。
# 构建在无特权用户下完成，避免 makepkg 拒绝 root；依赖从 .SRCINFO 读取，
# 构建完成后仅卸载本次新装、且未被其他包依赖的 makedepends。
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

build_user=mark-shot-build
build_root=/tmp/mark-shot-build
: > /tmp/mark-shot-build-packages

cleanup() {
    if id "$build_user" >/dev/null 2>&1; then
        userdel -r "$build_user" >/dev/null 2>&1 || true
    fi
    rm -rf "$build_root"
}
trap cleanup EXIT

install -d -m 0755 "$build_root"
# base-devel 按参考实现常驻镜像（用户要用 paru 构建 AUR 包）；这里只补齐，
# 不在构建结束后卸载，避免和后续 step_archlinuxcn 的 reef 构建互相拆装。
pacman -S --noconfirm --needed base-devel git
useradd --system --create-home --home-dir "$build_root" --shell /bin/bash "$build_user"
chown -R "$build_user:$build_user" "$build_root"

# 网络抖动时 AUR 的 TLS 连接会偶发失败；重试几次再放弃。
cloned=false
for _ in 1 2 3; do
    if runuser -u "$build_user" -- env HOME="$build_root" \
        git clone --depth=1 https://aur.archlinux.org/mark-shot.git "$build_root/mark-shot"; then
        cloned=true
        break
    fi
    rm -rf "$build_root/mark-shot"
    sleep 3
done
[[ "$cloned" == true ]] || { echo "AUR mark-shot 克隆失败" >&2; exit 1; }

srcinfo="$build_root/mark-shot/.SRCINFO"
[[ -f "$srcinfo" ]] || { echo "缺少 .SRCINFO" >&2; exit 1; }
# 只用 aarch64 可构建的包；x86_64-only 时明确跳过而不是留下半成品。
if ! grep -Eq '^[[:space:]]*arch = .*aarch64' "$srcinfo"; then
    echo "AUR mark-shot 不再声明 aarch64，跳过安装" >&2
    exit 0
fi

dependencies="$(
    {
        sed -n 's/^[[:space:]]*depends = //p' "$srcinfo"
        sed -n 's/^[[:space:]]*makedepends = //p' "$srcinfo"
        sed -n 's/^[[:space:]]*\(depends\|makedepends\)_aarch64 = //p' "$srcinfo"
    } | sed 's/[<>=].*$//' | sort -u
)"
[[ -n "$dependencies" ]] || { echo "AUR 配方没有可用依赖" >&2; exit 1; }
if printf '%s\n' "$dependencies" | grep -Eqv '^[A-Za-z0-9@._+][A-Za-z0-9@._+:-]*$'; then
    echo "AUR 配方包含无效的 mark-shot 依赖" >&2
    exit 1
fi
# 配方里以 soname 形式声明的 FFmpeg 依赖（libavcodec.so 等）无法用包名安装，
# 统一由 ffmpeg 提供；其余 soname 若出现，makepkg 的依赖检查会直接报错。
soname_dependency=false
install_list=()
while IFS= read -r dependency; do
    case "$dependency" in
        *.so) soname_dependency=true ;;
        *) install_list+=("$dependency") ;;
    esac
done <<< "$dependencies"
if [[ "$soname_dependency" == true ]]; then
    install_list+=(ffmpeg)
fi

# 记录安装前已存在的包，构建结束后只卸载本次新增的 makedepends。
for package in cargo cmake ninja pkgconf; do
    if ! pacman -Qq "$package" >/dev/null 2>&1; then
        printf '%s\n' "$package" >> /tmp/mark-shot-build-packages
    fi
done

# 只安装缺失的包，避免把已显式安装的运行时包改标成依赖。
missing=()
for package in "${install_list[@]}"; do
    if ! pacman -Qq "$package" >/dev/null 2>&1; then
        missing+=("$package")
    fi
done
if [[ ${#missing[@]} -gt 0 ]]; then
    pacman -S --noconfirm --needed --asdeps "${missing[@]}"
fi

# makepkg 会自己 clone GitHub 源码（配方里是 git+https://github.com/...）。部分
# 网络下直连 GitHub 不通，此时用 git 的 insteadOf 把 clone 重定向到镜像前缀；
# 通过 GIT_CONFIG_* 传递，避免改构建用户的全局 git 配置。
build_env=(HOME="$build_root")
if ! timeout 15 git ls-remote --exit-code https://github.com/jswysnemc/mark-shot.git \
        >/dev/null 2>&1; then
    build_env+=(
        GIT_CONFIG_COUNT=1
        GIT_CONFIG_KEY_0="url.${GH_MIRROR_PREFIX:-https://gh-proxy.com/}/https://github.com/.insteadOf"
        GIT_CONFIG_VALUE_0="https://github.com/"
    )
fi
runuser -u "$build_user" -- env "${build_env[@]}" bash -c \
    'cd "$1" && makepkg --cleanbuild --clean --noconfirm' _ "$build_root/mark-shot"

package_file="$(find "$build_root/mark-shot" -maxdepth 1 -type f \
    -name 'mark-shot-*.pkg.tar.*' ! -name '*.sig' -print -quit)"
[[ -n "$package_file" ]] || { echo "makepkg 没有产出 mark-shot 包" >&2; exit 1; }

sed -e '/^[[:space:]]*LocalFileSigLevel[[:space:]]*=/d' \
    -e '/^\[options\][[:space:]]*$/a LocalFileSigLevel = Optional' \
    /etc/pacman.conf > /tmp/pacman-mark-shot.conf
[[ "$(pacman --config /tmp/pacman-mark-shot.conf -Qqp "$package_file")" = "mark-shot" ]]
LC_ALL=C pacman --config /tmp/pacman-mark-shot.conf -Qip "$package_file" | \
    grep -Eq '^Architecture[[:space:]]*: aarch64$'
pacman --config /tmp/pacman-mark-shot.conf -U --noconfirm "$package_file"

rm -f /tmp/pacman-mark-shot.conf
if [[ -s /tmp/mark-shot-build-packages ]]; then
    # 卸载失败不影响交付：mark-shot 本体已安装并通过校验，构建工具留在镜像里
    # 只是多占空间，不该让整个构建失败。
    # shellcheck disable=SC2046
    pacman -Rns --noconfirm $(cat /tmp/mark-shot-build-packages) >/dev/null 2>&1 || \
        echo "mark-shot: 构建依赖卸载失败，保留（不影响 mark-shot 使用）" >&2
fi
rm -f /tmp/mark-shot-build-packages

[[ -x "$binary" ]] || { echo "mark-shot 安装后未找到：$binary" >&2; exit 1; }
echo "--> [enabled] mark-shot 已从 AUR 构建并安装"
