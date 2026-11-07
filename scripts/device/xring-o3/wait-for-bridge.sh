#!/bin/sh
# Wait until the Android host MaliBridge server is listening.
#
# desktop-session.service runs this as ExecStartPre. niri must not start before
# both MaliBridge sockets exist: a session that comes up first finds no
# renderer, aborts with VK_ERROR_DEVICE_LOST, and Noctalia never spawns.
#
# Readiness covers both sockets. mali.sock carries Vulkan/GL traffic;
# control.sock is what mbctl and mb-tray talk to. A server that has created only
# one of them is not ready for the desktop.
#
# Exit status is 0 on success and 0 on timeout, with one warning line on stderr.
# A desktop without the GPU is recoverable with `systemctl restart
# desktop-session`; a session that never starts is not, so this script never
# blocks the boot path.
set -u

BRIDGE_SOCKET="${XRING_O3_BRIDGE_SOCKET:-/opt/mb-sock/mali.sock}"
CONTROL_SOCKET="${XRING_O3_BRIDGE_CONTROL_SOCKET:-/opt/mb-sock/control.sock}"
TIMEOUT=30
QUIET=0

usage() {
    cat <<EOF
用法: $0 [SECONDS] [--timeout SECONDS] [--quiet]

  SECONDS              等待上限，默认 30 秒；0 表示只检查一次
  --timeout SECONDS    同上
  --quiet              就绪时不输出，超时仍告警

等待的 socket:
  ${BRIDGE_SOCKET}
  ${CONTROL_SOCKET}

两个都是 Unix socket 时立即返回 0。超时输出告警并返回 0。
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --timeout)
            if [ "$#" -lt 2 ]; then
                printf '%s: --timeout 缺少参数\n' "$0" >&2
                exit 2
            fi
            TIMEOUT=$2
            shift 2
            ;;
        --timeout=*)
            TIMEOUT=${1#--timeout=}
            shift
            ;;
        --quiet)
            QUIET=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        -*)
            printf '%s: 不支持的参数 %s\n' "$0" "$1" >&2
            exit 2
            ;;
        *)
            TIMEOUT=$1
            shift
            ;;
    esac
done

case "$TIMEOUT" in
    ''|*[!0-9]*)
        printf '%s: 等待秒数必须是非负整数：%s\n' "$0" "$TIMEOUT" >&2
        exit 2
        ;;
esac

# `test -S` is not in POSIX but every shell on the target carries it; fall back
# to a plain existence test only on a shell that rejects the operator.
socket_test=1
if [ -S / ]; then
    :
else
    [ $? -eq 2 ] && socket_test=0
fi

is_socket() {
    if [ "$socket_test" = 1 ]; then
        [ -S "$1" ]
    else
        [ -e "$1" ]
    fi
}

# A fraction-capable sleep gives a 0.2 s poll; otherwise poll every second and
# count in seconds so the wall-clock budget stays the same.
if sleep 0.2 2>/dev/null; then
    ticks_per_second=5
    poll_delay=0.2
else
    ticks_per_second=1
    poll_delay=1
fi

total_ticks=$((TIMEOUT * ticks_per_second))
tick=0
announced=0
missing=''

while :; do
    missing=''
    if ! is_socket "$BRIDGE_SOCKET"; then
        missing=$BRIDGE_SOCKET
    fi
    if ! is_socket "$CONTROL_SOCKET"; then
        if [ -n "$missing" ]; then
            missing="$missing
$CONTROL_SOCKET"
        else
            missing=$CONTROL_SOCKET
        fi
    fi

    if [ -z "$missing" ]; then
        if [ "$QUIET" = 0 ]; then
            printf '[wait-for-mali-bridge] 就绪：%s、%s（%s 秒内）\n' \
                "$BRIDGE_SOCKET" "$CONTROL_SOCKET" "$((tick / ticks_per_second))"
        fi
        exit 0
    fi

    if [ "$announced" = 0 ] && [ "$QUIET" = 0 ]; then
        announced=1
        printf '[wait-for-mali-bridge] 等待 MaliBridge socket（最多 %s 秒）：%s\n' \
            "$TIMEOUT" "$(printf '%s' "$missing" | tr '\n' ' ')"
    fi

    if [ "$tick" -ge "$total_ticks" ]; then
        break
    fi
    sleep "$poll_delay"
    tick=$((tick + 1))
done

printf '%s\n' \
    "[wait-for-mali-bridge] 警告: ${TIMEOUT} 秒内未就绪：$(printf '%s' "$missing" | tr '\n' ' ')" \
    "[wait-for-mali-bridge] 桌面将无 GPU 渲染器启动。请先启动 Android host 侧 vkbridge-server 并确认 mali.sock 与 control.sock 都已创建；恢复后执行 systemctl restart desktop-session。" >&2
exit 0
