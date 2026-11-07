#!/system/bin/sh
# Start the XRING-O3 MaliBridge host server under a detached supervisor.
#
# Manual start only: this script never runs at boot and never modifies boot.
# It must run as root on the Android host (outside the container).
# Configuration: environment > $SRV/host.env > defaults (see host.env.example).

set -u

SELF_DIR=$(cd -- "$(dirname -- "$0")" && pwd -P)
ENV_SRV=${SRV:-/data/local/tmp/xring-o3-host}
: "${HOST_ENV:=$ENV_SRV/host.env}"
if [ ! -r "$HOST_ENV" ] && [ -r "$SELF_DIR/host.env" ]; then
    HOST_ENV=$SELF_DIR/host.env
fi

load_key() {
    _key=$1
    eval "_current=\${$_key-}"
    [ -n "$_current" ] && return 0
    [ -r "$HOST_ENV" ] || return 0
    _value=$(sed -n "s/^[[:space:]]*$_key[[:space:]]*=[[:space:]]*//p" "$HOST_ENV" 2>/dev/null | tail -n 1 | tr -d '\r')
    _value=${_value#\"}; _value=${_value%\"}
    _value=${_value#\'}; _value=${_value%\'}
    [ -n "$_value" ] && eval "$_key=\$_value"
    return 0
}

for _key in CTR ROOTFS SRV ANLAND_LINK BUDGET_TOTAL_MB BUDGET_PID_MB \
            BUDGET_FLOOR_MB MAP_LIMIT CONTROL_UIDS SOCK_DIR SERVER \
            BUDGET_CONF MEM_STATS DROIDSPACES_BIN; do
    load_key "$_key"
done

: "${CTR:=archniri}"
: "${SRV:=/data/local/tmp/xring-o3-host}"
: "${ROOTFS:=/data/local/Droidspaces/Containers/$CTR/rootfs}"
: "${ANLAND_LINK:=/data/local/tmp/$CTR-display.sock}"
: "${BUDGET_TOTAL_MB:=4096}"
: "${BUDGET_PID_MB:=2048}"
: "${BUDGET_FLOOR_MB:=2048}"
: "${MAP_LIMIT:=60000}"
: "${CONTROL_UIDS:=1000}"
: "${MEM_STATS:=1}"
: "${SOCK_DIR:=$ROOTFS/opt/mb-sock}"
: "${SERVER:=$SRV/mbsrv/vkbridge-server}"
: "${BUDGET_CONF:=$SOCK_DIR/budget.conf}"

SUPERVISOR=$SRV/bridge-supervisor.sh
MALI_SOCK=$SOCK_DIR/mali.sock
CONTROL_SOCK=$SOCK_DIR/control.sock

log() { printf '[xring-o3-host] %s\n' "$*"; }
die() { printf '[xring-o3-host] 错误: %s\n' "$*" >&2; exit 1; }

is_server_pid() {
    _pid=${1:-}
    case "$_pid" in ''|*[!0-9]*) return 1 ;; esac
    [ -d "/proc/$_pid" ] || return 1
    tr '\0' ' ' < "/proc/$_pid/cmdline" 2>/dev/null | grep -q 'vkbridge-server'
}

is_live_socket() {
    _path=$1
    [ -S "$_path" ] || return 1
    [ -r /proc/net/unix ] || return 0
    awk -v p="$_path" '$NF == p && $(NF - 2) == "01" { found = 1 } END { exit found ? 0 : 1 }' /proc/net/unix
}

print_status() {
    log "server pid=$(cat "$SRV/server.pid" 2>/dev/null || echo '?') supervisor pid=$(cat "$SRV/supervisor.pid" 2>/dev/null || echo '?')"
    log "socket=$MALI_SOCK"
    log "control=$CONTROL_SOCK"
    log "budget.conf=$BUDGET_CONF"
    log "container view: /opt/mb-sock/mali.sock"
}

case "${1:-}" in
    -h|--help)
        cat <<EOF
用法: $0 [--help]

按当前配置启动 vkbridge-server（后台 supervisor 托管），只启动一次：
  已运行时只打印 pid 与 socket 路径，不重复启动。
  配置来源：环境变量 > $HOST_ENV > 内置默认值。

不做的事：不写开机启动、不重启设备、不修改 boot、不自动提权。
EOF
        exit 0
        ;;
    '') ;;
    *) die "不支持的参数：$1" ;;
esac

[ "$(id -u)" = 0 ] || die "需要 root；用 su -c '$0' 运行。"
[ -f "$SUPERVISOR" ] || die "缺少 $SUPERVISOR；先运行 install-host.sh。"
[ -x "$SERVER" ] || die "缺少可执行文件 $SERVER；用 install-host.sh --server/--bundle 安装 mali-host-*.tar.zst。"
[ -c /dev/mali0 ] || die "缺少 /dev/mali0；vendor Mali 驱动未就绪，server 无法工作。"

if [ -f "$SRV/server.pid" ] && is_server_pid "$(cat "$SRV/server.pid" 2>/dev/null)"; then
    log "已在运行，未重复启动。"
    print_status
    exit 0
fi

# A server from another directory (for example the legacy /data/local/tmp/mbsrv
# layout) may still own the socket. Binding a second one would unlink its
# sockets and leave two processes alive.
if is_live_socket "$MALI_SOCK"; then
    die "$MALI_SOCK 已被其他进程监听（server.pid 缺失或不属于 $SRV）。先停止占用者，再重试。"
fi

# Stale pid files from a killed run would otherwise confuse stop-bridge.sh.
rm -f "$SRV/server.pid" "$SRV/supervisor.pid"

[ -d "$SOCK_DIR" ] || mkdir -p "$SOCK_DIR" || die "无法创建 $SOCK_DIR"
chmod 0777 "$SOCK_DIR" 2>/dev/null || true
rm -f "$MALI_SOCK" "$CONTROL_SOCK"

export CTR ROOTFS SRV ANLAND_LINK SOCK_DIR SERVER BUDGET_CONF HOST_ENV
export VKBRIDGE_CONTROL_CONF=$BUDGET_CONF
export VKBRIDGE_CONTROL_SOCK=$CONTROL_SOCK
export VKBRIDGE_CONTROL_UIDS=$CONTROL_UIDS
export VKBRIDGE_MEM_BUDGET_TOTAL_MB=$BUDGET_TOTAL_MB
export VKBRIDGE_MEM_BUDGET_PID_MB=$BUDGET_PID_MB
export VKBRIDGE_MEM_MIN_AVAIL_MB=$BUDGET_FLOOR_MB
export VKBRIDGE_MAP_LIMIT=$MAP_LIMIT
export VKBRIDGE_MEM_STATS=$MEM_STATS

log "启动 supervisor：$SUPERVISOR"
setsid "$SUPERVISOR" </dev/null >/dev/null 2>&1 &
echo $! > "$SRV/supervisor.pid"

_n=0
while [ "$_n" -lt 40 ]; do
    [ -S "$MALI_SOCK" ] && [ -S "$CONTROL_SOCK" ] && break
    _n=$((_n + 1))
    sleep 0.3
done

# setsid forks when the caller is already a session leader; recover the pid.
if ! [ -f "$SRV/supervisor.pid" ] || ! kill -0 "$(cat "$SRV/supervisor.pid" 2>/dev/null)" 2>/dev/null; then
    _found=$(pgrep -f "$SUPERVISOR" 2>/dev/null | head -n 1)
    [ -n "$_found" ] && echo "$_found" > "$SRV/supervisor.pid"
fi

chmod 0666 "$MALI_SOCK" "$CONTROL_SOCK" 2>/dev/null || true

if ! [ -S "$MALI_SOCK" ] || ! [ -S "$CONTROL_SOCK" ]; then
    log "socket 未就绪，server.log 末尾："
    tail -n 12 "$SOCK_DIR/server.log" 2>/dev/null
    die "启动失败；先运行 stop-bridge.sh 清理，再重试。"
fi

log "已启动。"
print_status
