#!/bin/sh
# Chromium/Electron 的 setuid sandbox helper 必须是 root:root 4755。
#
# 容器禁止非特权 user namespace（unshare -U 被 seccomp 拒绝），Chromium 无法
# 退回 namespace sandbox；helper 不是 4755 时会在创建窗口前 abort：
#   FATAL: The SUID sandbox helper binary was found, but is not configured correctly.
# 多个 AUR -bin 包（visual-studio-code-bin 等）把 helper 装成 0755，表现为
# “从启动器点击没反应”。这个脚本由 pacman PostTransaction 钩子调用，覆盖
# 之后安装/升级的所有 Chromium/Electron 应用。
set -u

for root in /usr/share /usr/lib /usr/lib64 /opt; do
    [ -d "$root" ] || continue
    find "$root" -maxdepth 6 -type f -name chrome-sandbox 2>/dev/null | while IFS= read -r f; do
        chown root:root "$f" 2>/dev/null || true
        chmod 4755 "$f" 2>/dev/null || true
    done
done
