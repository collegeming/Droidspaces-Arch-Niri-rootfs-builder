#!/bin/bash
# scripts/build-remote-lamco.sh
# 构建并安装 Lamco RDP Server（IronRDP 标准协议，PC 端 mstsc 直连 3389）。
# aarch64 无预编译包，需从源码构建（Rust 1.89+）。
# 供 Arch-Niri.Dockerfile 的 REMOTE_ARG=lamco 调用，硬失败。
set -euo pipefail

echo "==> [远程] 克隆并构建 Lamco RDP Server..."
git clone --depth=1 https://github.com/lamco-admin/lamco-rdp-server.git /tmp/lamco
cd /tmp/lamco

# 安装 Rust 工具链（ALARM 有 rustup）
rustup default stable
rustup toolchain install stable

# 构建（wayland + portal-generic 策略）
cargo build --release 2>&1 || {
    echo "错误: lamco-rdp-server 构建失败"
    exit 1
}

install -Dm755 target/release/lamco-rdp-server /usr/bin/lamco-rdp-server

# 默认配置
mkdir -p /etc/lamco
cat > /etc/lamco/config.toml <<'CONF'
[server]
listen = "0.0.0.0:3389"

[security]
# PAM 认证：连接时输入容器内系统用户名+密码（如 colle / 1234）
auth_method = "pam"

[capture]
backend = "portal"
max_fps = 30

[encoder]
backend = "openh264"
quality = 75

[input]
backend = "portal-generic"

[clipboard]
enabled = true

[audio]
enabled = false
CONF

# 清理构建工具链
cd /
rm -rf /tmp/lamco
rustup self uninstall -y 2>/dev/null || true
# 清理 cargo 缓存
rm -rf /root/.cargo /root/.rustup 2>/dev/null || true

echo "==> [远程] Lamco RDP Server 构建成功"
