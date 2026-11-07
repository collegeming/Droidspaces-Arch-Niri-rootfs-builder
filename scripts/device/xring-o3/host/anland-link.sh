#!/system/bin/sh
# Point the stable Anland alias at the container's current display socket.
#
# The Anland daemon creates a random socket per container start:
#   /data/local/Droidspaces/Net/anland-<hash>.sock
# Droidspaces records one path in /data/local/Droidspaces/Pids/<ctr>.asock, and
# the container bind mount uses the stable alias below. Run this after a full
# container stop/start, an Anland daemon restart or a host reboot, before the
# container bind mount is created.
#
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

for _key in CTR SRV ANLAND_LINK DROIDSPACES_DIR; do
    load_key "$_key"
done

: "${CTR:=archniri}"
: "${SRV:=/data/local/tmp/xring-o3-host}"
: "${ANLAND_LINK:=/data/local/tmp/$CTR-display.sock}"
: "${DROIDSPACES_DIR:=/data/local/Droidspaces}"

PIDS_DIR=$DROIDSPACES_DIR/Pids
NET_DIR=$DROIDSPACES_DIR/Net
ASOCK=$PIDS_DIR/$CTR.asock

log() { printf '[xring-o3-anland-link] %s\n' "$*"; }
die() { printf '[xring-o3-anland-link] 错误: %s\n' "$*" >&2; exit 1; }

# A socket is live when it is a socket inode and the kernel lists it in
# LISTEN state (0x01) in /proc/net/unix. A leftover socket file after a daemon
# crash is not live.
is_live_socket() {
    _path=$1
    [ -S "$_path" ] || return 1
    [ -r /proc/net/unix ] || return 0
    awk -v p="$_path" '$NF == p && $(NF - 2) == "01" { found = 1 } END { exit found ? 0 : 1 }' /proc/net/unix
}

mtime_of() {
    _m=$(stat -c %Y "$1" 2>/dev/null || true)
    case "$_m" in ''|*[!0-9]*) _m=0 ;; esac
    printf '%s' "$_m"
}

check_alias() {
    if [ ! -L "$ANLAND_LINK" ]; then
        log "FAIL $ANLAND_LINK 不存在或不是符号链接。"
        return 1
    fi
    _target=$(readlink "$ANLAND_LINK" 2>/dev/null || true)
    if [ -z "$_target" ]; then
        log "FAIL $ANLAND_LINK 无法读取链接目标。"
        return 1
    fi
    if ! is_live_socket "$_target"; then
        log "FAIL $ANLAND_LINK -> $_target 不是活跃 socket。"
        return 1
    fi
    log "PASS $ANLAND_LINK -> $_target"
    return 0
}

case "${1:-}" in
    --check)
        [ "$(id -u)" = 0 ] || die "需要 root；用 su -c '$0 --check' 运行。"
        check_alias
        exit $?
        ;;
    -h|--help)
        cat <<EOF
用法: $0 [--check|--help]

默认行为：解析当前容器的真实 Anland socket，校验其处于 LISTEN 状态，
然后原子替换稳定别名 $ANLAND_LINK，并打印目标路径。

  --check   只校验现有别名，不修改任何文件
  --help    显示本帮助

解析顺序：
  1. $ASOCK（存在且可读时）
  2. $NET_DIR/anland-*.sock 中最新的活跃 socket

完整停止/启动容器、Anland 重启或宿主重启后都要重新运行一次，再创建
$ANLAND_LINK -> /run/display.sock 的绑定挂载。
EOF
        exit 0
        ;;
    '') ;;
    *) die "不支持的参数：$1" ;;
esac

[ "$(id -u)" = 0 ] || die "需要 root；用 su -c '$0' 运行。"

TARGET=""
SOURCE=""

if [ -r "$ASOCK" ]; then
    _candidate=$(tr -d '\r\n' < "$ASOCK" 2>/dev/null || true)
    if [ -n "$_candidate" ] && is_live_socket "$_candidate"; then
        TARGET=$_candidate
        SOURCE=$ASOCK
    elif [ -n "$_candidate" ]; then
        log "忽略 $ASOCK：记录的路径不是活跃 socket（$_candidate）。"
    fi
else
    log "$ASOCK 不可读；改为扫描 $NET_DIR。"
fi

if [ -z "$TARGET" ]; then
    _newest=""
    _count=0
    for _sock in "$NET_DIR"/anland-*.sock; do
        [ -S "$_sock" ] || continue
        is_live_socket "$_sock" || continue
        _count=$((_count + 1))
        if [ -z "$_newest" ]; then
            _newest=$_sock
            continue
        fi
        if [ "$(mtime_of "$_sock")" -ge "$(mtime_of "$_newest")" ]; then
            _newest=$_sock
        fi
    done
    if [ -z "$_newest" ]; then
        log "可用的活跃 socket 列表："
        ls -l "$NET_DIR" 2>/dev/null | sed -n 's/^/  /p'
        die "在 $NET_DIR 下找不到活跃的 anland-*.sock。确认容器已启动、Anland daemon 正在运行。"
    fi
    TARGET=$_newest
    SOURCE="$NET_DIR（最新活跃 socket）"
    if [ "$_count" -gt 1 ]; then
        log "警告：发现 $_count 个活跃 socket，已选择最新的一个（$TARGET）。"
    fi
fi

# Never let 'mv' follow an existing alias into a directory.
if [ -d "$ANLAND_LINK" ]; then
    die "$ANLAND_LINK 解析为目录；拒绝替换。先确认容器绑定挂载的源路径。"
fi
if [ -e "$ANLAND_LINK" ] && [ ! -L "$ANLAND_LINK" ]; then
    die "$ANLAND_LINK 已存在且不是符号链接；拒绝替换。"
fi

mkdir -p "$(dirname -- "$ANLAND_LINK")" || die "无法创建 $(dirname -- "$ANLAND_LINK")"
_tmp=$ANLAND_LINK.tmp.$$
ln -sfn "$TARGET" "$_tmp" || die "无法创建临时符号链接 $_tmp"
if ! mv -f "$_tmp" "$ANLAND_LINK"; then
    rm -f "$_tmp"
    die "无法替换 $ANLAND_LINK"
fi

log "已更新（来源：$SOURCE）"
log "$ANLAND_LINK -> $TARGET"
