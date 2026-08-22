#!/bin/bash
# scripts/terminal/setup-beautify.sh
# 终端美化一键安装：fish + reef + fisher + tide + Maple Mono 字体 +
# kitty/ghostty 配置 + Nemo 中文 + niri 背景模糊。
# 供 Arch-Niri.Dockerfile 调用（RUN 阶段，root 执行，需网络）。
# 用法: setup-beautify.sh [USERNAME]
set -euo pipefail
USERNAME="${1:-Gold}"
USERHOME="/home/${USERNAME}"

echo "==> [美化] 1. 安装 fish + cinnamon-translations（Nemo 中文翻译）"
pacman -S --noconfirm --needed fish cinnamon-translations unzip

echo "==> [美化] 2. 下载安装 Maple Mono NF CN 字体"
wget -q --tries=5 --waitretry=3 -O /tmp/MapleMono-NF-CN.zip \
    "https://github.com/subframe7536/maple-font/releases/download/v7.9/MapleMono-NF-CN.zip"
install -d /usr/share/fonts/MapleMono
bsdtar -xf /tmp/MapleMono-NF-CN.zip -C /usr/share/fonts/MapleMono/
fc-cache -f
rm -f /tmp/MapleMono-NF-CN.zip
# 确认字体家族名
fc-list | grep -i "maple" | head -3 || echo "警告: 未找到 Maple 字体"

echo "==> [美化] 3. 安装 reef + reef-tools（AUR，需临时 aurbuild 用户）"
useradd -m aurbuild 2>/dev/null || true
echo 'aurbuild ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/aurbuild
sudo -u aurbuild paru -S --noconfirm --needed reef reef-tools || {
    echo "警告: reef AUR 构建失败，跳过（reef.fish 的 reef on 会静默失败，不影响 fish）"
}
userdel -r aurbuild 2>/dev/null || true
rm -f /etc/sudoers.d/aurbuild

echo "==> [美化] 4. 部署 fish 配置到 /etc/skel"
install -d /etc/skel/.config/fish/conf.d
install -d /etc/skel/.config/fish/functions
install -Dm644 /tmp/beautify/fish/config.fish        /etc/skel/.config/fish/config.fish
install -Dm644 /tmp/beautify/fish/conf.d/reef.fish   /etc/skel/.config/fish/conf.d/reef.fish
install -Dm644 /tmp/beautify/fish/conf.d/theme.fish  /etc/skel/.config/fish/conf.d/theme.fish
install -Dm644 /tmp/beautify/fish/conf.d/mirrors.fish /etc/skel/.config/fish/conf.d/mirrors.fish
install -Dm644 /tmp/beautify/fish/tide-apply.fish    /etc/skel/.config/fish/tide-apply.fish

echo "==> [美化] 5. 下载 fisher（fish 插件管理器）"
wget -q --tries=5 --waitretry=3 -O /etc/skel/.config/fish/functions/fisher.fish \
    "https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish"

echo "==> [美化] 6. 下载 kitty Catppuccin Frappe 主题 + 部署 kitty.conf"
install -d /etc/skel/.config/kitty/themes
wget -q --tries=5 --waitretry=3 -O /etc/skel/.config/kitty/themes/frappe.conf \
    "https://raw.githubusercontent.com/catppuccin/kitty/main/themes/frappe.conf"
install -Dm644 /tmp/beautify/kitty.conf /etc/skel/.config/kitty/kitty.conf

echo "==> [美化] 7. 部署 ghostty 配置 + 光标拖尾 shader（仅 ghostty 已安装时）"
if command -v ghostty >/dev/null 2>&1; then
    install -d /etc/skel/.config/ghostty
    install -Dm644 /tmp/beautify/ghostty-config /etc/skel/.config/ghostty/config
    git clone --depth=1 https://github.com/sahaj-b/ghostty-cursor-shaders \
        /etc/skel/.config/ghostty/shaders 2>/dev/null || \
        echo "警告: ghostty-cursor-shaders 克隆失败，custom-shader 配置可能无效"
    echo "    ghostty 配置已部署（含 background-blur + cursor_warp shader）"
else
    echo "    ghostty 未安装，跳过 ghostty 配置"
fi

echo "==> [美化] 8. 同步到用户家目录"
cp -r /etc/skel/.config/fish  "${USERHOME}/.config/"
cp -r /etc/skel/.config/kitty "${USERHOME}/.config/"
if [ -d /etc/skel/.config/ghostty ]; then
    cp -r /etc/skel/.config/ghostty "${USERHOME}/.config/"
fi
chown -R "${USERNAME}:${USERNAME}" "${USERHOME}/.config"

echo "==> [美化] 9. 安装 Tide 提示符 + 应用配置（以用户身份运行 fish）"
sudo -u "${USERNAME}" env HOME="${USERHOME}" fish -c \
    'fisher install ilancosman/tide@v6' 2>&1 || \
    echo "警告: tide 安装失败，可运行后手动 fish -c 'fisher install ilancosman/tide@v6'"

# 应用 tide 配置（universal 变量写入 ~/.config/fish/fish_variables）
sudo -u "${USERNAME}" env HOME="${USERHOME}" fish \
    "${USERHOME}/.config/fish/tide-apply.fish" 2>&1 || \
    echo "警告: tide-apply 执行失败"

echo "==> [美化] 10. 设 fish 为默认 shell"
chsh -s /usr/bin/fish "${USERNAME}" 2>/dev/null || \
    echo "警告: chsh 失败，用户可运行 chsh -s /usr/bin/fish 手动设置"

echo "==> [美化] 完成"
echo "  - fish + reef + fisher + tide 已配置"
echo "  - Maple Mono NF CN 字体已安装"
echo "  - kitty 配置（Catppuccin Frappe + 光标拖尾）已部署"
[ -d /etc/skel/.config/ghostty ] && echo "  - ghostty 配置（含 background-blur + shader）已部署"
echo "  - fish 已设为默认 shell"
