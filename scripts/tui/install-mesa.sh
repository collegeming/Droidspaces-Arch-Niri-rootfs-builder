#!/usr/bin/env bash
# Compatibility entry point for the TUI/build that used to call install-mesa.
#
# On this branch there is no distribution Mesa path, no msm media decoder and
# no legacy GPU source selection. The installer is a thin dispatcher to the
# XRING-O3 Mali stack installer; every retired option is rejected explicitly
# instead of silently doing nothing.

set -euo pipefail

readonly PROFILE_DIR="${DROIDSPACES_DEVICE_PROFILE_DIR:-/usr/local/lib/droidspaces/device}"
readonly PROFILE_FILE="${XRING_O3_PROFILE_FILE:-${PROFILE_DIR}/xring-o3/profile.sh}"
readonly MALI_INSTALLER="$(dirname -- "$PROFILE_FILE")/install-mali-stack.sh"

log() { printf '[install-mesa] %s\n' "$*"; }
die() { printf '[install-mesa] 错误: %s\n' "$*" >&2; exit 1; }

case "${1:-}" in
    -h|--help)
        cat <<'EOF'
install-mesa 在 xring-o3 分支上是 Mali stack 安装器的转发入口。

用法与 install-mali-stack.sh 一致：
  MALI_STACK_VERSION=<版本> \
  MALI_STACK_BUNDLE_URL=<归档 URL> MALI_STACK_BUNDLE_SHA256=<64位十六进制> \
  install-mesa

  MALI_STACK_VERSION=<版本> MALI_STACK_BUNDLE_DIR=<已解压目录> install-mesa

  install-mesa --status
  install-mesa --uninstall [--version <版本>]

旧的高通 GPU 安装选项、msm 媒体解码和 -1/-2/-3 下载源参数均不可用。
EOF
        exit 0
        ;;
esac

[[ -r "$PROFILE_FILE" ]] || die \
    "缺少 XRING-O3 设备档案：$PROFILE_FILE。该分支只提供 XRING-O3/Mali 路径。"
# shellcheck source=device/xring-o3/profile.sh
source "$PROFILE_FILE"
[[ -x "$MALI_INSTALLER" ]] || die "缺少 Mali stack 安装器：$MALI_INSTALLER"

case "${1:-}" in
    -1|--1|-2|--2|-3|--3)
        die "旧的 Mesa 下载源参数（$1）已移除。XRING-O3 分支请使用 MALI_STACK_BUNDLE_URL + MALI_STACK_BUNDLE_SHA256，或 MALI_STACK_BUNDLE_DIR。"
        ;;
    --mesa-only|--media-only|--choose-version)
        die "旧的 Mesa/媒体解码选项（$1）已移除。XRING-O3 只安装 Mesa dt-retire + MaliBridge bundle。"
        ;;
esac

xring_o3_require_active
log "XRING-O3 profile: 转发到 install-mali-stack.sh"
exec "$MALI_INSTALLER" "$@"
