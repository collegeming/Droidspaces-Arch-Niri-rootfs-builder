#!/system/bin/sh
# Supervise the XRING-O3 MaliBridge host server.
#
# vkbridge-server exits when its parent exits, so this shell stays attached:
# it owns server.pid, waits for the sockets, drops oom_score_adj to 0 and
# reaps the server. start-bridge.sh launches it with setsid; do not run it in
# the foreground of an interactive shell unless you want it to block.
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

for _key in CTR ROOTFS SRV BUDGET_TOTAL_MB BUDGET_PID_MB BUDGET_FLOOR_MB \
            MAP_LIMIT CONTROL_UIDS SOCK_DIR SERVER BUDGET_CONF MEM_STATS; do
    load_key "$_key"
done

: "${CTR:=archniri}"
: "${SRV:=/data/local/tmp/xring-o3-host}"
: "${ROOTFS:=/data/local/Droidspaces/Containers/$CTR/rootfs}"
: "${BUDGET_TOTAL_MB:=4096}"
: "${BUDGET_PID_MB:=2048}"
: "${BUDGET_FLOOR_MB:=2048}"
: "${MAP_LIMIT:=60000}"
: "${CONTROL_UIDS:=1000}"
: "${MEM_STATS:=1}"
: "${SOCK_DIR:=$ROOTFS/opt/mb-sock}"
: "${SERVER:=$SRV/mbsrv/vkbridge-server}"
: "${BUDGET_CONF:=$SOCK_DIR/budget.conf}"

MALI_SOCK=$SOCK_DIR/mali.sock
CONTROL_SOCK=$SOCK_DIR/control.sock
LOG=$SOCK_DIR/server.log
STDOUT=$SOCK_DIR/stdout.log

die() { printf '[bridge-supervisor] 错误: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "需要 root。"
[ -x "$SERVER" ] || die "缺少可执行文件 $SERVER。"

[ -d "$SOCK_DIR" ] || mkdir -p "$SOCK_DIR" || die "无法创建 $SOCK_DIR"
chmod 0777 "$SOCK_DIR" 2>/dev/null || true
rm -f "$MALI_SOCK" "$CONTROL_SOCK"

# Never leave a dead socket behind, even if the server dies of a signal.
cleanup() {
    rm -f "$MALI_SOCK" "$CONTROL_SOCK" 2>/dev/null || true
}
trap 'cleanup' EXIT

: "${VKBRIDGE_CONTROL_CONF:=$BUDGET_CONF}"
: "${VKBRIDGE_CONTROL_UIDS:=$CONTROL_UIDS}"
: "${VKBRIDGE_MEM_BUDGET_TOTAL_MB:=$BUDGET_TOTAL_MB}"
: "${VKBRIDGE_MEM_BUDGET_PID_MB:=$BUDGET_PID_MB}"
: "${VKBRIDGE_MEM_MIN_AVAIL_MB:=$BUDGET_FLOOR_MB}"
: "${VKBRIDGE_MAP_LIMIT:=$MAP_LIMIT}"
: "${VKBRIDGE_MEM_STATS:=$MEM_STATS}"
export VKBRIDGE_CONTROL_CONF VKBRIDGE_CONTROL_UIDS
export VKBRIDGE_MEM_BUDGET_TOTAL_MB VKBRIDGE_MEM_BUDGET_PID_MB
export VKBRIDGE_MEM_MIN_AVAIL_MB VKBRIDGE_MAP_LIMIT VKBRIDGE_MEM_STATS

"$SERVER" --socket "$MALI_SOCK" --log "$LOG" </dev/null >"$STDOUT" 2>&1 &
P=$!
echo "$P" > "$SRV/server.pid"
trap 'if [ -n "${P:-}" ]; then kill -TERM "$P" 2>/dev/null; wait "$P" 2>/dev/null; fi; exit 0' TERM INT

_n=0
while [ "$_n" -lt 40 ]; do
    [ -S "$MALI_SOCK" ] && [ -S "$CONTROL_SOCK" ] && break
    _n=$((_n + 1))
    sleep 0.3
done

# The server may create both sockets after it has loaded the vendor driver.
chmod 0666 "$MALI_SOCK" "$CONTROL_SOCK" 2>/dev/null || true
echo 0 > "/proc/$P/oom_score_adj" 2>/dev/null || true

wait "$P"
