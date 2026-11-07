#!/usr/bin/env bash
# XRING-O3 has no /dev/dri/renderD* node; Mesa/Zink only needs the primary
# /dev/dri/card0 char device (226:0). Droidspaces may not create it in the
# container, so this oneshot service creates it idempotently at boot.
#
# A failure here must not block the desktop: the script records the reason and
# exits 0. Use `card0.sh --check` to make the failure visible interactively.

set -uo pipefail

readonly DEVICE="${XRING_O3_DRM_DEVICE:-/dev/dri/card0}"
readonly UNIT_NAME="xring-o3-card0.service"
readonly UNIT_PATH="/etc/systemd/system/${UNIT_NAME}"
readonly WANTS_LINK="/etc/systemd/system/sysinit.target.wants/${UNIT_NAME}"
readonly SELF="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
readonly LOG_FILE="/run/xring-o3-card0.log"

log() {
    printf '[xring-o3-card0] %s\n' "$*"
    if [[ -d /run && -w /run ]]; then
        printf '%s [xring-o3-card0] %s\n' "$(date -Is 2>/dev/null || true)" "$*" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

install_unit() {
    install -d -m 0755 /etc/systemd/system/sysinit.target.wants
    cat > "$UNIT_PATH" <<EOF
[Unit]
Description=XRING-O3: create ${DEVICE}
Documentation=file:/usr/local/lib/droidspaces/device/xring-o3/README.md
DefaultDependencies=no
After=systemd-tmpfiles-setup-dev.service
Before=desktop-session.service

[Service]
Type=oneshot
ExecStart=${SELF}
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=sysinit.target
EOF
    chmod 0644 "$UNIT_PATH"
    ln -sfn "/etc/systemd/system/${UNIT_NAME}" "$WANTS_LINK"
    log "已安装并启用 ${UNIT_NAME}（不会在构建阶段创建设备节点）。"
}

create_node() {
    if [[ -c "$DEVICE" ]]; then
        log "$DEVICE 已存在，跳过。"
        return 0
    fi
    if [[ -e "$DEVICE" || -L "$DEVICE" ]]; then
        log "$DEVICE 已存在但不是字符设备，拒绝替换。"
        return 0
    fi
    if ! install -d -m 0755 "$(dirname -- "$DEVICE")"; then
        log "无法创建 $(dirname -- "$DEVICE")；容器可能未授予 CAP_MKNOD。"
        return 0
    fi
    if ! mknod -- "$DEVICE" c 226 0; then
        log "mknod ${DEVICE} 失败；容器可能未授予 CAP_MKNOD 或 /dev 只读。"
        return 0
    fi
    chmod 0660 "$DEVICE" 2>/dev/null || true
    if getent group video >/dev/null 2>&1; then
        chgrp video "$DEVICE" 2>/dev/null || true
    fi
    log "已创建 ${DEVICE} (c 226 0)。"
}

check_node() {
    if [[ -c "$DEVICE" ]]; then
        log "$DEVICE 正常：$(ls -l -- "$DEVICE" 2>/dev/null || true)"
        return 0
    fi
    log "$DEVICE 缺失或不是字符设备。"
    log "修复：确保容器启用硬件访问（CAP_MKNOD），然后 systemctl restart ${UNIT_NAME}"
    return 1
}

case "${1:-}" in
    --install) install_unit ;;
    --check) check_node ;;
    ""|--create) create_node ;;
    -h|--help)
        cat <<EOF
用法: $0 [--create|--install|--check]

  --create   幂等创建 ${DEVICE}（默认；失败仅记录，不阻塞）
  --install  安装并启用 ${UNIT_NAME} oneshot 服务
  --check    检查设备节点，缺失时返回 1
EOF
        ;;
    *)
        printf '无效参数：%s\n' "$1" >&2
        exit 2
        ;;
esac
