#!/bin/bash
# scripts/build-ghostty.sh
# 构建并安装 ghostty 稳定版 1.3.1（Arch 官方 PKGBUILD + 官方 zig 0.15.2 aarch64 二进制）。
# 供 Arch-Niri / Arch-KDE 等 Dockerfile 的 terminal=ghostty 复用，硬失败（任何错误 exit 1）。
#
# zig 版本：ghostty 1.3.1 稳定版 requireZig = 0.15.2（不是 0.16.0！）。
# ALARM 仓库的 zig 是 0.16.0，触发 requireZig 版本检查失败；故下载官方 0.15.2
# aarch64 二进制替换。0.15.2 是 1.3.1 原生 zig 版本，包哈希与 build.zig.zon 一致。
#
# 真实根因（Run #20 日志证实）：fetch-zig-cache.sh + --system 离线流程在 zig 0.16 下
# 对不上——build.zig.zon.txt 清单里 uucode 列了 git URL（算出的哈希）与预打包 tarball
# 声明哈希 ZZjBPq... 不一致，--system 按声明哈希找目录找不到。故对齐 ghostty CI
# （nix develop -c zig build，从不用 --system）：sed 删 --system、build 前置
# ZIG_GLOBAL_CACHE_DIR 复用 prepare() 已拉依赖、zig 0.15.2 在线 fetch 缺失项并按
# 内容哈希校验。用官方 zig 0.16.0 aarch64 二进制（ziglang.org）放 /usr/local/bin。
set -euo pipefail

# 1) 仓库直装优先（ALARM 若收录则免编译）
if pacman -S --noconfirm --needed ghostty; then
    echo "--> [终端] 已从 ALARM 仓库安装 ghostty"
    command -v ghostty
    exit 0
fi

echo "--> [终端] 仓库暂无 ghostty，用官方稳定版 1.3.1 PKGBUILD + 官方 zig 构建..."

# 2) 官方 zig 0.15.2 aarch64 二进制（ghostty 1.3.1 稳定版要求 0.15.2，
#    用官方二进制确保包哈希与 build.zig.zon 声明一致——ALARM 包是 0.16.0
#    会触发 requireZig 版本检查失败；0.15.2 官方 aarch64 二进制 ziglang 有）
wget -q --tries=5 --waitretry=3 -O /tmp/zig-off.tar.xz \
    https://ziglang.org/download/0.15.2/zig-aarch64-linux-0.15.2.tar.xz
tar -xJf /tmp/zig-off.tar.xz -C /tmp
install -m 755 /tmp/zig-aarch64-linux-0.15.2/zig /usr/local/bin/zig
cp -a /tmp/zig-aarch64-linux-0.15.2/lib /usr/local/lib/zig
rm -rf /tmp/zig-off.tar.xz /tmp/zig-aarch64-linux-0.15.2
/usr/local/bin/zig version

# 3) pandoc 官方 aarch64 二进制（aarch64 无 pandoc-cli 包；cn pandoc-bin 在 arm64 InvalidExe）
wget -q --tries=5 --waitretry=3 -O /tmp/pandoc.tar.gz \
    https://github.com/jgm/pandoc/releases/download/3.10.2/pandoc-3.10.2-linux-arm64.tar.gz
tar -xzf /tmp/pandoc.tar.gz -C /tmp
install -m 755 /tmp/pandoc-*/bin/pandoc /usr/local/bin/pandoc
rm -rf /tmp/pandoc.tar.gz /tmp/pandoc-3*

# 4) 临时 aurbuild 用户（paru/makepkg 拒绝以 root 运行）
useradd -m aurbuild
echo 'aurbuild ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/aurbuild

# 5) 下载官方稳定版 1.3.1 PKGBUILD，sed 适配 aarch64
install -d /tmp/ghostty-pkg
wget -q --tries=5 --waitretry=3 -O /tmp/ghostty-pkg/PKGBUILD \
    https://gitlab.archlinux.org/archlinux/packaging/packages/ghostty/-/raw/main/PKGBUILD
# pandoc-cli 在 aarch64 无包名，删该 makedepend（pandoc 二进制由步骤 3 提供）
sed -i '/pandoc-cli/d' /tmp/ghostty-pkg/PKGBUILD
# 删 --system 离线标志，改在线 fetch（对齐 ghostty CI，绕 build.zig.zon.txt 清单缺陷）
sed -i '/--system/d' /tmp/ghostty-pkg/PKGBUILD
# build 前置 ZIG_GLOBAL_CACHE_DIR 复用 prepare() 已拉依赖，仅在线补缺
sed -i 's#DESTDIR=build zig build#ZIG_GLOBAL_CACHE_DIR="$srcdir/zig-global-cache" DESTDIR=build zig build#' /tmp/ghostty-pkg/PKGBUILD

chown -R aurbuild:aurbuild /tmp/ghostty-pkg

# 6) 构建（PATH 优先官方 zig）
sudo -u aurbuild bash -c 'export PATH=/usr/local/bin:$PATH; cd /tmp/ghostty-pkg && export EDITOR=true && makepkg -s --noconfirm'

# 7) 安装产物
pacman -U --noconfirm /tmp/ghostty-pkg/*.pkg.tar.*
command -v ghostty
echo "--> [终端] 官方稳定版 1.3.1 构建成功，已安装 ghostty"
