#!/system/bin/sh
# Read-only PASS/FAIL check of the XRING-O3 MaliBridge host side.
#
# Nothing here writes, chmods, links or starts anything. Run it as root on the
# Android host after start-bridge.sh; a non-zero exit means at least one check
# failed.
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
            BUDGET_CONF DROIDSPACES_BIN DROIDSPACES_DIR; do
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
: "${SOCK_DIR:=$ROOTFS/opt/mb-sock}"
: "${SERVER:=$SRV/mbsrv/vkbridge-server}"
: "${BUDGET_CONF:=$SOCK_DIR/budget.conf}"
: "${DROIDSPACES_DIR:=/data/local/Droidspaces}"

MALI_SOCK=$SOCK_DIR/mali.sock
CONTROL_SOCK=$SOCK_DIR/control.sock
PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '[PASS] %s\n' "$*"; }
fail() { FAIL=$((FAIL + 1)); printf '[FAIL] %s\n' "$*"; }
info() { printf '[INFO] %s\n' "$*"; }

is_live_socket() {
    _path=$1
    [ -S "$_path" ] || return 1
    [ -r /proc/net/unix ] || return 0
    awk -v p="$_path" '$NF == p && $(NF - 2) == "01" { found = 1 } END { exit found ? 0 : 1 }' /proc/net/unix
}

is_server_pid() {
    _pid=${1:-}
    case "$_pid" in ''|*[!0-9]*) return 1 ;; esac
    [ -d "/proc/$_pid" ] || return 1
    tr '\0' ' ' < "/proc/$_pid/cmdline" 2>/dev/null | grep -q 'vkbridge-server'
}

pick_file() {
    for _candidate in "$@"; do
        [ -f "$_candidate" ] && { printf '%s' "$_candidate"; return 0; }
    done
    return 1
}

droidspaces_bin() {
    if [ -n "${DROIDSPACES_BIN:-}" ] && [ -x "$DROIDSPACES_BIN" ]; then
        printf '%s' "$DROIDSPACES_BIN"
        return 0
    fi
    if [ -x "$DROIDSPACES_DIR/bin/droidspaces" ]; then
        printf '%s' "$DROIDSPACES_DIR/bin/droidspaces"
        return 0
    fi
    command -v droidspaces 2>/dev/null
}

printf 'XRING-O3 host verification (%s)\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown)"

if [ "$(id -u)" = 0 ]; then
    info "root ok"
else
    fail "需要 root 运行；部分检查在非 root 下不可读。"
fi

if [ -r "$HOST_ENV" ]; then
    info "配置：$HOST_ENV"
else
    info "未找到 $HOST_ENV；使用内置默认值或环境变量。"
fi

# 1. vendor Mali device node
if [ -c /dev/mali0 ]; then
    pass "/dev/mali0 存在（$(ls -ln /dev/mali0 2>/dev/null | awk '{print $5, $6}')）"
else
    fail "/dev/mali0 缺失；vendor Mali 驱动未加载，server 无法工作。"
fi

# 2. /dev/dri/card0 must be char 226:0
if [ -c /dev/dri/card0 ]; then
    _line=$(ls -ln /dev/dri/card0 2>/dev/null)
    _major=$(printf '%s' "$_line" | awk '{print $5}' | tr -d ',')
    _minor=$(printf '%s' "$_line" | awk '{print $6}')
    if [ "$_major" = 226 ] && [ "$_minor" = 0 ]; then
        pass "/dev/dri/card0 是字符设备 226:0"
    else
        fail "/dev/dri/card0 设备号为 ${_major}:${_minor}，期望 226:0。"
    fi
else
    fail "/dev/dri/card0 缺失；Zink/WebKit 需要该节点。"
fi

# 3. container running
_ds=$(droidspaces_bin || true)
_ctr_pid=""
if [ -n "$_ds" ]; then
    _ctr_pid=$("$_ds" show 2>/dev/null | tr -d '\r' | awk -v c="$CTR" '$2 == c { print $4 }' | head -n 1)
fi
if [ -z "$_ctr_pid" ] && [ -r "$DROIDSPACES_DIR/Pids/$CTR.pid" ]; then
    _ctr_pid=$(cat "$DROIDSPACES_DIR/Pids/$CTR.pid" 2>/dev/null || true)
fi
if [ -n "$_ctr_pid" ] && [ -d "/proc/$_ctr_pid" ]; then
    pass "容器 $CTR 正在运行（pid=$_ctr_pid）"
else
    fail "容器 $CTR 未运行；用 droidspaces show 确认，先启动容器。"
fi

# 4. server process
_server_pid=$(cat "$SRV/server.pid" 2>/dev/null || true)
if is_server_pid "$_server_pid"; then
    pass "vkbridge-server 运行中（pid=$_server_pid，oom_score_adj=$(cat "/proc/$_server_pid/oom_score_adj" 2>/dev/null || echo '?')）"
else
    fail "vkbridge-server 未运行（$SRV/server.pid）；运行 start-bridge.sh。"
fi

# 5+6. sockets
if is_live_socket "$MALI_SOCK"; then
    pass "mali.sock 处于 LISTEN（$MALI_SOCK）"
else
    fail "mali.sock 缺失或不是活跃 socket（$MALI_SOCK）。"
fi
if is_live_socket "$CONTROL_SOCK"; then
    pass "control.sock 处于 LISTEN（$CONTROL_SOCK）"
else
    fail "control.sock 缺失或不是活跃 socket（$CONTROL_SOCK）。"
fi

# 7. budget.conf
if [ -r "$BUDGET_CONF" ]; then
    _bad=""
    for _key in total_mb pid_mb floor_mb map_limit; do
        _value=$(sed -n "s/^[[:space:]]*$_key[[:space:]]*=[[:space:]]*//p" "$BUDGET_CONF" 2>/dev/null | tail -n 1 | tr -d '\r')
        case "$_value" in
            ''|*[!0-9]*) _bad="$_bad $_key" ;;
        esac
        printf '       %s=%s\n' "$_key" "${_value:-<缺失>}"
    done
    if [ -z "$_bad" ]; then
        pass "budget.conf 可读且四项均为整数（$BUDGET_CONF）"
    else
        fail "budget.conf 字段缺失或不是整数：$_bad（$BUDGET_CONF）"
    fi
    _file_total=$(sed -n 's/^[[:space:]]*total_mb[[:space:]]*=[[:space:]]*//p' "$BUDGET_CONF" 2>/dev/null | tail -n 1 | tr -d '\r')
    _file_pid=$(sed -n 's/^[[:space:]]*pid_mb[[:space:]]*=[[:space:]]*//p' "$BUDGET_CONF" 2>/dev/null | tail -n 1 | tr -d '\r')
    _file_floor=$(sed -n 's/^[[:space:]]*floor_mb[[:space:]]*=[[:space:]]*//p' "$BUDGET_CONF" 2>/dev/null | tail -n 1 | tr -d '\r')
    _file_map=$(sed -n 's/^[[:space:]]*map_limit[[:space:]]*=[[:space:]]*//p' "$BUDGET_CONF" 2>/dev/null | tail -n 1 | tr -d '\r')
    if [ "$_file_total" = "$BUDGET_TOTAL_MB" ] && [ "$_file_pid" = "$BUDGET_PID_MB" ] && \
       [ "$_file_floor" = "$BUDGET_FLOOR_MB" ] && [ "$_file_map" = "$MAP_LIMIT" ]; then
        info "budget.conf 与 host.env 一致（环境变量优先于文件）。"
    else
        info "budget.conf 与 host.env 不一致：文件 ${_file_total:-?}/${_file_pid:-?}/${_file_floor:-?}/${_file_map:-?}，配置 ${BUDGET_TOTAL_MB}/${BUDGET_PID_MB}/${BUDGET_FLOOR_MB}/${MAP_LIMIT}；本次启动以环境变量为准。"
    fi
else
    fail "budget.conf 不可读（$BUDGET_CONF）；由容器内 Mali stack 安装器创建。"
fi

# 8. Anland alias
if [ -L "$ANLAND_LINK" ]; then
    _target=$(readlink "$ANLAND_LINK" 2>/dev/null || true)
    if is_live_socket "$_target"; then
        pass "Anland 别名指向活跃 socket（$ANLAND_LINK -> $_target）"
    else
        fail "Anland 别名目标不是活跃 socket（$ANLAND_LINK -> ${_target:-?}）；运行 anland-link.sh 后重启容器。"
    fi
else
    fail "Anland 别名缺失或不是符号链接（$ANLAND_LINK）；运行 anland-link.sh。"
fi

# 9. vendor libraries
_gles=$(pick_file /vendor/lib64/egl/libGLES_mali.so /vendor/lib64/libGLES_mali.so || true)
if [ -n "$_gles" ]; then
    pass "vendor GLES 驱动：$_gles"
else
    fail "缺少 vendor GLES 驱动（/vendor/lib64/egl/libGLES_mali.so 或 /vendor/lib64/libGLES_mali.so）。"
fi
_vk=$(pick_file /vendor/lib64/hw/vulkan.mali.so /vendor/lib64/vulkan.mali.so || true)
if [ -n "$_vk" ]; then
    pass "vendor Vulkan 驱动：$_vk"
else
    fail "缺少 vendor Vulkan 驱动（/vendor/lib64/hw/vulkan.mali.so 或 /vendor/lib64/vulkan.mali.so）。"
fi
_hw=""
for _candidate in /vendor/lib64/hwvulkan* /vendor/lib64/hw/vulkan*.so; do
    if [ -f "$_candidate" ]; then
        _hw=$_candidate
        break
    fi
done
if [ -n "$_hw" ]; then
    pass "vendor Vulkan HAL 模块：$_hw"
else
    fail "缺少 vendor Vulkan HAL 模块（/vendor/lib64/hw/vulkan*.so 或 /vendor/lib64/hwvulkan*）。"
fi

printf '\n合计：PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
