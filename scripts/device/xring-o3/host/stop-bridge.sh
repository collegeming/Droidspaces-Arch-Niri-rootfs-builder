#!/system/bin/sh
# Stop the XRING-O3 MaliBridge host server and its supervisor, then remove the
# sockets and pid files. Logs are kept for diagnosis.
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

for _key in CTR ROOTFS SRV SOCK_DIR SERVER BUDGET_CONF; do
    load_key "$_key"
done

: "${CTR:=archniri}"
: "${SRV:=/data/local/tmp/xring-o3-host}"
: "${ROOTFS:=/data/local/Droidspaces/Containers/$CTR/rootfs}"
: "${SOCK_DIR:=$ROOTFS/opt/mb-sock}"
: "${SERVER:=$SRV/mbsrv/vkbridge-server}"

SUPERVISOR=$SRV/bridge-supervisor.sh
MALI_SOCK=$SOCK_DIR/mali.sock
CONTROL_SOCK=$SOCK_DIR/control.sock

log() { printf '[xring-o3-host] %s\n' "$*"; }
die() { printf '[xring-o3-host] 错误: %s\n' "$*" >&2; exit 1; }

pid_of() {
    _pid=$(cat "$1" 2>/dev/null || true)
    case "$_pid" in ''|*[!0-9]*) return 1 ;; esac
    [ -d "/proc/$_pid" ] || return 1
    printf '%s' "$_pid"
}

cmdline_of() {
    tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null
}

stop_pid() {
    _pid=$1
    _name=$2
    kill -TERM "$_pid" 2>/dev/null || return 0
    _n=0
    while [ "$_n" -lt 20 ]; do
        [ -d "/proc/$_pid" ] || break
        _n=$((_n + 1))
        sleep 0.25
    done
    if [ -d "/proc/$_pid" ]; then
        log "$_name pid=$_pid 未在 5 秒内退出，发送 SIGKILL。"
        kill -KILL "$_pid" 2>/dev/null || true
        sleep 0.2
    fi
    return 0
}

case "${1:-}" in
    -h|--help)
        cat <<EOF
用法: $0 [--help]

停止 vkbridge-server 和 bridge-supervisor.sh，删除 $MALI_SOCK 与
$CONTROL_SOCK，并清理 pid 文件。server.log 与 stdout.log 保留。

配置来源：环境变量 > $HOST_ENV > 内置默认值。
EOF
        exit 0
        ;;
    '') ;;
    *) die "不支持的参数：$1" ;;
esac

[ "$(id -u)" = 0 ] || die "需要 root；用 su -c '$0' 运行。"

_stopped=0

S=$(pid_of "$SRV/server.pid" || true)
if [ -n "${S:-}" ] && cmdline_of "$S" | grep -q 'vkbridge-server'; then
    log "停止 server pid=$S"
    stop_pid "$S" server
    _stopped=1
fi

# Orphans whose pid file was lost or overwritten.
for _p in $(pgrep -f "$SERVER" 2>/dev/null); do
    [ "$_p" = "${S:-}" ] && continue
    if cmdline_of "$_p" | grep -q 'vkbridge-server'; then
        log "停止残留 server pid=$_p"
        stop_pid "$_p" server
        _stopped=1
    fi
done

V=$(pid_of "$SRV/supervisor.pid" || true)
if [ -n "${V:-}" ] && cmdline_of "$V" | grep -q 'bridge-supervisor.sh'; then
    log "停止 supervisor pid=$V"
    stop_pid "$V" supervisor
    _stopped=1
fi

rm -f "$SRV/server.pid" "$SRV/supervisor.pid"
rm -f "$MALI_SOCK" "$CONTROL_SOCK"

if [ "$_stopped" = 1 ]; then
    log "已停止并清理 socket 与 pid 文件。日志保留在 $SOCK_DIR。"
else
    log "未发现运行中的 server 或 supervisor；已清理 socket 与 pid 文件。"
fi
