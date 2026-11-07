#!/usr/bin/env bash
# RootFS-side expectations for Anland on XRING-O3.
#
# The Android host owns the Anland daemon and the real display socket. Droidspaces
# bind-mounts a stable host alias onto /run/display.sock inside the container.
# Nothing in the rootfs can create that socket; this script only installs the
# documented expectation and records whether the bind mount is present.
#
# Host-side setup (run as root on Android, outside the rootfs) is documented in
# scripts/device/xring-o3/README.md and deliberately not shipped into the image.

set -uo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=profile.sh
source "${SCRIPT_DIR}/profile.sh"

readonly ENV_FILE="${XRING_O3_ENV_FILE:-/etc/environment}"
readonly EXPECTATION_FILE="/etc/xring-o3/anland.conf"
readonly CHECK_UNIT="/etc/systemd/system/xring-o3-anland-check.service"
readonly CHECK_WANTS="/etc/systemd/system/multi-user.target.wants/xring-o3-anland-check.service"

log() { printf '[xring-o3-anland] %s\n' "$*"; }

install_expectation() {
    install -d -m 0755 /etc/xring-o3 /etc/systemd/system/multi-user.target.wants
    cat > "$EXPECTATION_FILE" <<EOF
# RootFS side of the Anland display path on XRING-O3.
#
# The container expects a Unix socket at:
#   ${XRING_O3_ANLAND_SOCKET}
#
# It must be provided by a Droidspaces bind mount from the Android host:
#   /data/local/tmp/<container>-display.sock -> /run/display.sock
#
# /data/local/tmp/<container>-display.sock is a stable alias that the host
# updates to the random socket recorded in
# /data/local/Droidspaces/Pids/<container>.asock. The Anland daemon and that
# alias are host assets; do not copy an APK, daemon or Magisk ZIP into the rootfs.
ANLAND_SOCKET=${XRING_O3_ANLAND_SOCKET}
ANLAND_DRM_DEVICE=${XRING_O3_DRM_DEVICE}
EOF

    cat > "$CHECK_UNIT" <<EOF
[Unit]
Description=XRING-O3: verify that ${XRING_O3_ANLAND_SOCKET} is bind-mounted
Documentation=file:/usr/local/lib/droidspaces/device/xring-o3/README.md
After=local-fs.target
Before=desktop-session.service

[Service]
Type=oneshot
ExecStart=${SCRIPT_DIR}/anland.sh --check --nonblocking
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$EXPECTATION_FILE" "$CHECK_UNIT"
    ln -sfn "/etc/systemd/system/$(basename -- "$CHECK_UNIT")" "$CHECK_WANTS"
    log "已写入 ${EXPECTATION_FILE} 并启用启动检查（缺失 socket 不会阻塞桌面）。"
}

read_environment_value() {
    local key="$1"
    [[ -r "$ENV_FILE" ]] || return 0
    sed -n "s/^[[:space:]]*\(export[[:space:]]\+\)\?${key}[[:space:]]*=[[:space:]]*//p" "$ENV_FILE" | tail -n 1
}

check_expectation() {
    local nonblocking=false status=0 socket_value drm_value bridge_value
    while (($# > 0)); do
        case "$1" in
            --nonblocking) nonblocking=true; shift ;;
            *) shift ;;
        esac
    done

    socket_value="$(read_environment_value ANLAND_SOCKET)"
    drm_value="$(read_environment_value ANLAND_DRM_DEVICE)"
    bridge_value="$(read_environment_value VKBRIDGE_SOCKET)"

    printf 'ANLAND_SOCKET(env)=%s\n' "${socket_value:-<未设置>}"
    printf 'ANLAND_DRM_DEVICE(env)=%s\n' "${drm_value:-<未设置>}"
    printf 'VKBRIDGE_SOCKET(env)=%s\n' "${bridge_value:-<未设置>}"

    if [[ -S "$XRING_O3_ANLAND_SOCKET" ]]; then
        log "已找到 socket：$XRING_O3_ANLAND_SOCKET"
    else
        log "缺少 $XRING_O3_ANLAND_SOCKET。"
        cat <<EOF
宿主侧修复步骤（在 Android root shell 中执行，rootfs 内不需要这些文件）：
  1. 确认 Anland daemon 正在运行，并读取 Droidspaces 记录的随机 socket：
       /data/local/Droidspaces/Pids/<container>.asock
  2. 将该 socket 的稳定别名指向 /data/local/tmp/<container>-display.sock：
       ln -sfn "\$(cat /data/local/Droidspaces/Pids/<container>.asock)" \\
         /data/local/tmp/<container>-display.sock
  3. 在 Droidspaces 高级选项中配置绑定挂载：
       /data/local/tmp/<container>-display.sock -> /run/display.sock
  4. 重新启动容器；完整停止/启动、宿主重启或 Anland daemon 重启后都要刷新别名。
EOF
        status=1
    fi

    if [[ -n "$socket_value" && "$socket_value" != "$XRING_O3_ANLAND_SOCKET" ]]; then
        log "警告：/etc/environment 中 ANLAND_SOCKET=${socket_value}，期望 ${XRING_O3_ANLAND_SOCKET}。"
        status=1
    fi
    if [[ -n "$drm_value" && "$drm_value" != "$XRING_O3_DRM_DEVICE" ]]; then
        log "警告：/etc/environment 中 ANLAND_DRM_DEVICE=${drm_value}，期望 ${XRING_O3_DRM_DEVICE}。"
        status=1
    fi
    if [[ -z "$bridge_value" ]]; then
        log "警告：/etc/environment 未设置 VKBRIDGE_SOCKET；MaliBridge 客户端无法连接。"
        status=1
    fi

    if [[ "$nonblocking" == true ]]; then
        return 0
    fi
    return "$status"
}

case "${1:-}" in
    --install)
        install_expectation
        ;;
    --check)
        shift
        check_expectation "$@"
        ;;
    -h|--help)
        cat <<EOF
用法: $0 --install | --check [--nonblocking]

  --install       写入 ${EXPECTATION_FILE}，并安装启动时的非阻塞检查服务
  --check         检查 ${XRING_O3_ANLAND_SOCKET} 和 /etc/environment 期望值
  --nonblocking   无论检查结果如何都返回 0（供 systemd oneshot 使用）
EOF
        ;;
    *)
        printf '无效参数：%s\n' "$1" >&2
        exit 2
        ;;
esac
