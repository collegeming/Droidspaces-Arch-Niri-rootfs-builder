#!/bin/bash
# scripts/build-remote-lamco.sh
# 构建并安装 Lamco RDP Server（IronRDP 标准协议，PC 端 mstsc 直连 3389）。
# aarch64 无预编译包，需从源码构建（Rust 1.89+）。
# 供 Arch-Niri.Dockerfile 的 REMOTE_ARG=lamco 调用，硬失败。
set -euo pipefail
USERNAME="${1:-colle}"

echo "==> [远程] 克隆并构建 Lamco RDP Server..."

# 确保构建依赖（libspa-sys 的 bindgen 需要 libclang，libopus_sys 需要 cmake）
for dep in clang pkg-config cmake; do
    command -v "$dep" >/dev/null 2>&1 || pacman -S --noconfirm --needed "$dep"
done

git clone --depth=1 https://github.com/lamco-admin/lamco-rdp-server.git /tmp/lamco
cd /tmp/lamco

# 仓库漏提交了 licenses/OpenH264-BINARY_LICENSE.txt，include_str! 编译时读不到。
# 从 Cisco 官方下载 OpenH264 二进制许可证文本（v1.0），补齐缺失文件。
if [ ! -f licenses/OpenH264-BINARY_LICENSE.txt ]; then
    mkdir -p licenses
    curl -fsSL -o licenses/OpenH264-BINARY_LICENSE.txt \
        "https://www.openh264.org/BINARY_LICENSE.txt" || \
        printf 'Cisco OpenH264 Binary License v1.0\n\nSee https://www.openh264.org/BINARY_LICENSE.txt\n' \
            > licenses/OpenH264-BINARY_LICENSE.txt
fi

# 安装 Rust 工具链（ALARM 有 rustup）
rustup default stable
rustup toolchain install stable

# 构建（wayland + portal-generic 策略）
cargo build --release 2>&1 || {
    echo "错误: lamco-rdp-server 构建失败"
    exit 1
}

install -Dm755 target/release/lamco-rdp-server /usr/bin/lamco-rdp-server

# 默认配置：用 lamco 自带的 --generate-config 生成完整 schema（避免手写漏字段）。
# auth_method=none（PAM 与 mstsc 的 NLA/CredSSP 不兼容，mstsc 在 TLS 模式下不传用户名），
# 安全靠局域网隔离，远程用 SSH 隧道（与 VNC 同策略）。
CERT_DIR="/home/${USERNAME}/.config/lamco-rdp-server"
mkdir -p /etc/lamco
/usr/bin/lamco-rdp-server --generate-config 2>/dev/null > /etc/lamco/config.toml

# 生成自签名 TLS 证书（security_mode=tls 需要）
mkdir -p "$CERT_DIR"
openssl req -x509 -newkey rsa:2048 \
    -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" \
    -days 3650 -nodes -subj "/CN=localhost" 2>/dev/null
chown -R "${USERNAME}:${USERNAME}" "$CERT_DIR"

# 清理构建工具链
cd /
rm -rf /tmp/lamco
rustup self uninstall -y 2>/dev/null || true
# 清理 cargo 缓存
rm -rf /root/.cargo /root/.rustup 2>/dev/null || true

echo "==> [远程] Lamco RDP Server 构建成功"
