#!/usr/bin/env bash
# 本分支只交付 Arch + niri + XRING-O3 Mali。
# 该文件保留是为了不破坏 COPY/chmod 通配和历史构建入口，但不再安装桌面。
set -euo pipefail

desktop="$(basename -- "${BASH_SOURCE[0]}" .sh)"

echo "错误：本分支只支持 Arch + niri + XRING-O3 Mali；桌面配置 ${desktop} 已停用。" >&2
echo "Error: this branch supports Arch + niri with XRING-O3 Mali only; desktop profile '${desktop}' is disabled." >&2
exit 1
