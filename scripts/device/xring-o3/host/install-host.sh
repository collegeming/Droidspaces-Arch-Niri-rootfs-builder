#!/usr/bin/env bash
# Install the XRING-O3 MaliBridge host scripts on the Android host.
#
# Runs on a PC (drives adb) or on the device (installs locally); the mode is
# detected, not selected. The body sticks to POSIX/mksh constructs so the same
# file runs under bash on the PC and under /system/bin/sh on Android.
#
# It only writes files: nothing is started, no boot image or init script is
# touched, and no root is granted by this script. Re-running it is safe; an
# existing $DEST/host.env is never overwritten.
#
# Two release assets complement each other:
#   mali-stack-<version>.tar.zst  rootfs payload, installed inside the container
#   mali-host-<version>.tar.zst   this side: vkbridge-server plus these scripts
#
# Usage:
#   install-host.sh [--dest DIR] [--serial SERIAL] [--server PATH | --bundle PATH]
#                   [--uninstall] [--help]

set -eu

# adb arguments are Android paths; stop MSYS/Git Bash from rewriting them.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

SELF_DIR=$(cd -- "$(dirname -- "$0")" && pwd -P)
DEFAULT_DEST=/data/local/tmp/xring-o3-host
MANIFEST_NAME=.install-manifest
SERVER_NAME=vkbridge-server

DEST=$DEFAULT_DEST
SERIAL=""
SERVER_SRC=""
BUNDLE_SRC=""
UNINSTALL=false
ON_DEVICE=false
WORK_DIR=""
BUNDLE_DIR=""
SCRIPTS_SRC=$SELF_DIR
ENV_SRC=$SELF_DIR/host.env.example

log() { printf '[install-host] %s\n' "$*"; }
die() { printf '[install-host] 错误: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法: install-host.sh [选项]

  --dest DIR       安装目录（默认 /data/local/tmp/xring-o3-host）
  --serial SN      adb 设备序列号（PC 模式；默认要求只有一台设备）
  --server PATH    安装 vkbridge-server 可执行文件到 DIR/mbsrv/
  --bundle PATH    从 mali-host-<version>.tar.zst 取 server 与脚本
  --uninstall      只删除本脚本安装过的文件（依据 DIR/.install-manifest）
  -h, --help       显示帮助

行为：
  1. 安装目录与 DIR/mbsrv 不存在时创建。
  2. 脚本复制为 0755；DIR/host.env.example 一并安装。
  3. DIR/host.env 不存在时从示例生成一次，之后不再覆盖。
  4. 写入 DIR/.install-manifest，记录本次安装的文件，供 --uninstall 使用；
     多次运行的文件清单会累积，避免先装 server 再补脚本后丢失归属。
  5. 不启动 server、不写开机启动、不修改 boot、不申请 root。
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dest) [ "$#" -ge 2 ] || die "--dest 缺少参数"; DEST=$2; shift 2 ;;
        --serial) [ "$#" -ge 2 ] || die "--serial 缺少参数"; SERIAL=$2; shift 2 ;;
        --server) [ "$#" -ge 2 ] || die "--server 缺少参数"; SERVER_SRC=$2; shift 2 ;;
        --bundle) [ "$#" -ge 2 ] || die "--bundle 缺少参数"; BUNDLE_SRC=$2; shift 2 ;;
        --uninstall) UNINSTALL=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "不支持的参数：$1（使用 --help 查看用法）" ;;
    esac
done

case "$DEST" in
    /*) ;;
    *) die "--dest 必须是绝对路径：$DEST" ;;
esac
case "$DEST" in
    *"'"*) die "--dest 不能包含单引号" ;;
    *" "*) die "--dest 不能包含空格" ;;
esac

detect_mode() {
    if command -v getprop >/dev/null 2>&1; then
        if [ -n "$(getprop ro.build.version.sdk 2>/dev/null || true)" ]; then
            ON_DEVICE=true
        fi
    fi
}

adb_ready() {
    command -v adb >/dev/null 2>&1 || die "PC 模式需要 adb；或在设备上运行本脚本。"
    local devices count
    if [ -n "$SERIAL" ]; then
        adb -s "$SERIAL" get-state >/dev/null 2>&1 || die "adb 设备不可用：$SERIAL"
        return 0
    fi
    devices=$(adb devices | tr -d '\r' | awk '$2 == "device" { print $1 }')
    count=$(printf '%s\n' "$devices" | grep -c . || true)
    if [ "$count" = 1 ]; then
        SERIAL=$devices
        return 0
    fi
    [ "$count" = 0 ] && die "没有已授权的 adb 设备。"
    die "检测到多台设备，请用 --serial 指定：$(printf '%s' "$devices" | tr '\n' ' ')"
}

adb_shell() { adb -s "$SERIAL" shell "$1"; }

adb_root() { adb -s "$SERIAL" shell "su -c '$1'"; }

# adb on Windows cannot read MSYS paths such as /tmp/x; remote Android paths
# must stay untouched, so only local paths go through cygpath.
local_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -w -- "$1"
    else
        printf '%s' "$1"
    fi
}

remote_exists() {
    local attempt
    attempt=0
    while [ "$attempt" -lt 3 ]; do
        if adb_shell "test -e '$1'" >/dev/null 2>&1; then
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 0.2
    done
    return 1
}

# adb exec-out can return a stray shell error on stdout when the device is busy;
# a manifest that does not look like a path list is treated as a read failure.
remote_read() {
    local path destination attempt
    path=$1
    destination=$2
    attempt=0
    while [ "$attempt" -lt 3 ]; do
        : > "$destination"
        if adb -s "$SERIAL" exec-out cat "$path" > "$destination" 2>/dev/null && [ -s "$destination" ]; then
            if ! grep -qv '^[A-Za-z0-9._/+@-]*$' "$destination"; then
                return 0
            fi
        fi
        attempt=$((attempt + 1))
        sleep 0.2
    done
    return 1
}

# Whether the server binary is already installed, checked on the side that owns
# the filesystem (the PC cannot see $DEST).
server_present() {
    if [ "$ON_DEVICE" = true ]; then
        [ -x "$DEST/mbsrv/$SERVER_NAME" ]
    else
        adb_shell "test -x '$DEST/mbsrv/$SERVER_NAME'" >/dev/null 2>&1
    fi
}

elf_is_aarch64_bionic() {
    local file identity machine
    file=$1
    identity=$(od -An -tx1 -N6 "$file" | tr -d '[:space:]')
    [ "$identity" = 7f454c460201 ] || return 1
    machine=$(od -An -tx1 -j18 -N2 "$file" | tr -d '[:space:]')
    [ "$machine" = b700 ] || return 1
    if grep -aq '/system/bin/linker64' "$file"; then
        return 0
    fi
    if grep -aq 'ld-linux-aarch64' "$file"; then
        return 1
    fi
    grep -aq -e 'liblog\.so' -e 'libandroid\.so' "$file"
}

prepare_bundle() {
    local bundle
    bundle=$1
    [ -f "$bundle" ] || die "找不到 bundle：$bundle"
    [ "$ON_DEVICE" = false ] || die "设备上没有 zstd；请在 PC 上解压后改用 --server。"
    command -v tar >/dev/null 2>&1 || die "解压 bundle 需要 tar。"
    command -v zstd >/dev/null 2>&1 || die "解压 .tar.zst 需要 zstd；也可在有 zstd 的机器解压后用 --server 指定二进制。"
    BUNDLE_DIR=$(mktemp -d)
    if ! tar --zstd -xf "$bundle" -C "$BUNDLE_DIR" 2>/dev/null; then
        zstd -dc -- "$bundle" | tar -xf - -C "$BUNDLE_DIR" || die "bundle 解压失败：$bundle"
    fi
    [ -f "$BUNDLE_DIR/mali-host/bin/$SERVER_NAME" ] || die "bundle 内缺少 mali-host/bin/$SERVER_NAME"
    [ -d "$BUNDLE_DIR/mali-host/scripts" ] || die "bundle 内缺少 mali-host/scripts/"
    SCRIPTS_SRC=$BUNDLE_DIR/mali-host/scripts
    ENV_SRC=$BUNDLE_DIR/mali-host/host.env.example
    SERVER_SRC=$BUNDLE_DIR/mali-host/bin/$SERVER_NAME
}

install_files() {
    local manifest name target env_exists generated
    manifest=$WORK_DIR/$MANIFEST_NAME
    : > "$manifest"

    if [ -n "$BUNDLE_SRC" ]; then
        prepare_bundle "$BUNDLE_SRC"
    fi
    [ -d "$SCRIPTS_SRC" ] || die "找不到脚本目录：$SCRIPTS_SRC"
    [ -f "$ENV_SRC" ] || die "找不到 host.env.example：$ENV_SRC"

    if [ "$ON_DEVICE" = true ]; then
        mkdir -p "$DEST" "$DEST/mbsrv"
        chmod 0755 "$DEST" "$DEST/mbsrv" 2>/dev/null || true
    else
        adb_ready
        if ! adb_shell "mkdir -p '$DEST' '$DEST/mbsrv'" >/dev/null 2>&1; then
            adb_root "mkdir -p '$DEST' '$DEST/mbsrv'" >/dev/null 2>&1 || die "无法创建 $DEST"
        fi
        adb_root "chown 0:2000 '$DEST' '$DEST/mbsrv' 2>/dev/null; chmod 0775 '$DEST' '$DEST/mbsrv'" >/dev/null 2>&1 || true
    fi

    for target in "$SCRIPTS_SRC"/*.sh; do
        [ -f "$target" ] || continue
        name=$(basename -- "$target")
        if [ "$ON_DEVICE" = true ]; then
            if [ "$(readlink -f "$target")" != "$(readlink -f "$DEST/$name" 2>/dev/null || printf '%s' "$DEST/$name")" ]; then
                cp -f -- "$target" "$DEST/$name"
            fi
            chmod 0755 "$DEST/$name"
        else
            adb -s "$SERIAL" push -- "$(local_path "$target")" "$DEST/$name" >/dev/null
            adb_shell "chmod 0755 '$DEST/$name'" >/dev/null 2>&1 || adb_root "chmod 0755 '$DEST/$name'" >/dev/null
        fi
        printf '%s\n' "$name" >> "$manifest"
    done

    if [ "$ON_DEVICE" = true ]; then
        cp -f -- "$ENV_SRC" "$DEST/host.env.example"
        chmod 0644 "$DEST/host.env.example"
    else
        adb -s "$SERIAL" push -- "$(local_path "$ENV_SRC")" "$DEST/host.env.example" >/dev/null
        adb_shell "chmod 0644 '$DEST/host.env.example'" >/dev/null 2>&1 || adb_root "chmod 0644 '$DEST/host.env.example'" >/dev/null
    fi
    printf '%s\n' host.env.example >> "$manifest"

    # host.env is created once; later runs keep local edits.
    env_exists=false
    if [ "$ON_DEVICE" = true ]; then
        [ -e "$DEST/host.env" ] && env_exists=true
    else
        remote_exists "$DEST/host.env" && env_exists=true
    fi

    if [ "$env_exists" = true ]; then
        log "保留已有 $DEST/host.env"
    else
        generated=$WORK_DIR/host.env
        sed "s|^SRV=.*|SRV=$DEST|" "$ENV_SRC" > "$generated"
        if [ "$ON_DEVICE" = true ]; then
            cp -f -- "$generated" "$DEST/host.env"
            chmod 0644 "$DEST/host.env"
        else
            adb -s "$SERIAL" push -- "$(local_path "$generated")" "$DEST/host.env" >/dev/null
            adb_shell "chmod 0644 '$DEST/host.env'" >/dev/null 2>&1 || adb_root "chmod 0644 '$DEST/host.env'" >/dev/null
        fi
        printf '%s\n' host.env >> "$manifest"
        log "已从 host.env.example 生成 $DEST/host.env"
    fi

    if [ -n "$SERVER_SRC" ]; then
        [ -f "$SERVER_SRC" ] || die "找不到 server 二进制：$SERVER_SRC"
        elf_is_aarch64_bionic "$SERVER_SRC" || \
            die "$SERVER_SRC 不是 AArch64 bionic 可执行文件（架构不符，或缺少 /system/bin/linker64）。"
        if [ "$ON_DEVICE" = true ]; then
            if [ "$(readlink -f "$SERVER_SRC")" != "$(readlink -f "$DEST/mbsrv/$SERVER_NAME" 2>/dev/null || printf '%s' "$DEST/mbsrv/$SERVER_NAME")" ]; then
                cp -f -- "$SERVER_SRC" "$DEST/mbsrv/$SERVER_NAME"
            fi
            chown 0:0 "$DEST/mbsrv/$SERVER_NAME" 2>/dev/null || true
            chmod 0755 "$DEST/mbsrv/$SERVER_NAME"
        else
            adb -s "$SERIAL" push -- "$(local_path "$SERVER_SRC")" "$DEST/mbsrv/.$SERVER_NAME.new" >/dev/null
            adb_root "mv -f '$DEST/mbsrv/.$SERVER_NAME.new' '$DEST/mbsrv/$SERVER_NAME' && chown 0:0 '$DEST/mbsrv/$SERVER_NAME' && chmod 0755 '$DEST/mbsrv/$SERVER_NAME'" \
                >/dev/null || die "安装 $SERVER_NAME 失败"
        fi
        printf 'mbsrv/%s\n' "$SERVER_NAME" >> "$manifest"
        log "已安装 server：$DEST/mbsrv/$SERVER_NAME"
    elif server_present; then
        log "沿用已有 $DEST/mbsrv/$SERVER_NAME"
    else
        log "警告：$DEST/mbsrv/$SERVER_NAME 尚不存在；用 --bundle mali-host-*.tar.zst 或 --server PATH 安装，否则 start-bridge.sh 会拒绝启动。"
    fi

    # The manifest records what this script installed, so --uninstall never
    # touches hand-written files or runtime logs. Entries accumulate across
    # runs: installing scripts only must not orphan an earlier server install.
    if [ "$ON_DEVICE" = true ]; then
        if [ -r "$DEST/$MANIFEST_NAME" ]; then
            cat "$DEST/$MANIFEST_NAME" >> "$manifest"
        fi
    else
        if remote_read "$DEST/$MANIFEST_NAME" "$WORK_DIR/previous.manifest"; then
            cat "$WORK_DIR/previous.manifest" >> "$manifest"
        fi
    fi
    sort -u -o "$manifest" "$manifest"

    if [ "$ON_DEVICE" = true ]; then
        cp -f -- "$manifest" "$DEST/$MANIFEST_NAME"
        chmod 0644 "$DEST/$MANIFEST_NAME"
    else
        adb -s "$SERIAL" push -- "$(local_path "$manifest")" "$DEST/$MANIFEST_NAME" >/dev/null
        adb_root "chmod 0644 '$DEST/$MANIFEST_NAME'" >/dev/null 2>&1 || true
    fi

    log "安装完成：$DEST"
    log "下一步（手动）："
    log "  su -c '$DEST/anland-link.sh'"
    log "  su -c '$DEST/start-bridge.sh'"
    log "  su -c '$DEST/verify-host.sh'"
}

uninstall_files() {
    local manifest line count quoted
    manifest=$WORK_DIR/$MANIFEST_NAME
    if [ "$ON_DEVICE" = true ]; then
        [ -r "$DEST/$MANIFEST_NAME" ] || die "找不到 $DEST/$MANIFEST_NAME；无法判断哪些文件由本脚本安装。"
        cp -f -- "$DEST/$MANIFEST_NAME" "$manifest"
    else
        adb_ready
        if ! remote_read "$DEST/$MANIFEST_NAME" "$manifest"; then
            if remote_exists "$DEST/$MANIFEST_NAME"; then
                die "无法读取 $DEST/$MANIFEST_NAME（已重试 3 次）；拒绝删除。"
            fi
            die "找不到 $DEST/$MANIFEST_NAME；无法判断哪些文件由本脚本安装。"
        fi
    fi

    if [ "$ON_DEVICE" = true ]; then
        [ -f "$DEST/server.pid" ] && die "server.pid 仍存在；先运行 $DEST/stop-bridge.sh。"
    else
        remote_exists "$DEST/server.pid" && die "server.pid 仍存在；先运行 $DEST/stop-bridge.sh。"
    fi

    count=0
    quoted=""
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
            /*) die "manifest 含绝对路径，拒绝删除：$line" ;;
            *..*) die "manifest 含 ..，拒绝删除：$line" ;;
            *"'"*) die "manifest 含单引号，拒绝删除：$line" ;;
            *" "*) die "manifest 含空格，拒绝删除：$line" ;;
        esac
        count=$((count + 1))
        quoted="$quoted '$DEST/$line'"
    done < "$manifest"

    [ "$count" -gt 0 ] || die "manifest 没有可删除的条目。"

    if [ "$ON_DEVICE" = true ]; then
        eval "rm -f -- $quoted"
        rm -f -- "$DEST/$MANIFEST_NAME"
        rmdir "$DEST/mbsrv" 2>/dev/null || true
        rmdir "$DEST" 2>/dev/null || true
    else
        adb_root "rm -f $quoted" >/dev/null || die "删除文件失败"
        adb_root "rm -f '$DEST/$MANIFEST_NAME'; rmdir '$DEST/mbsrv' 2>/dev/null; rmdir '$DEST' 2>/dev/null" >/dev/null 2>&1 || true
    fi

    log "已删除 $count 个文件；socket、日志与容器数据未触碰。"
}

detect_mode
if [ "$ON_DEVICE" = true ]; then
    WORK_DIR=${TMPDIR:-/data/local/tmp}/install-host.$$
    mkdir -p "$WORK_DIR"
else
    WORK_DIR=$(mktemp -d)
fi
trap 'rm -rf "$WORK_DIR"; [ -n "$BUNDLE_DIR" ] && rm -rf "$BUNDLE_DIR"' EXIT

if [ "$ON_DEVICE" = true ]; then
    log "运行模式：设备本地"
else
    log "运行模式：PC + adb"
fi

if [ "$UNINSTALL" = true ]; then
    uninstall_files
else
    install_files
fi
