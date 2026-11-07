#!/usr/bin/env bash
# Build the publishable XRING-O3 Android-host bundle.
#
# The rootfs bundle deliberately does not contain vkbridge-server: it is a
# bionic executable that needs /dev/mali0 and the vendor Mali driver, so it
# stays on the Android host. This script packages it together with the host
# scripts, host.env.example and a manifest.env.
#
# Input is either a staging directory or a running device over adb.
#
# Usage:
#   make-host-bundle.sh --device [--serial SN] [--device-server PATH]
#   make-host-bundle.sh --dir STAGE
#   make-host-bundle.sh --server PATH
#   [--version V] [--out DIR] [--mtime EPOCH] [--force]
#
# Output layout inside mali-host-<version>.tar.zst:
#   mali-host/bin/vkbridge-server
#   mali-host/scripts/*.sh
#   mali-host/host.env.example
#   mali-host/manifest.env
#   mali-host/SHA256SUMS

set -euo pipefail

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly HOST_DIR="$SCRIPT_DIR/host"
readonly DEFAULT_DEVICE_SERVER=/data/local/tmp/mbsrv/vkbridge-server
readonly ZSTD_LEVEL="${ZSTD_LEVEL:-10}"

MODE=""
STAGE=""
SERVER_PATH=""
DEVICE_SERVER=$DEFAULT_DEVICE_SERVER
SERIAL=""
VERSION="${MALI_HOST_VERSION:-}"
OUT_DIR=""
MTIME="${SOURCE_DATE_EPOCH:-0}"
FORCE=false

log() { printf '[make-host-bundle] %s\n' "$*"; }
die() { printf '[make-host-bundle] 错误: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法: make-host-bundle.sh (--device | --dir STAGE | --server PATH) [选项]

输入（三选一）：
  --device              从 adb 设备读取 vkbridge-server 和设备属性
  --serial SN           指定 adb 序列号
  --device-server PATH  设备上的 server 路径（默认 /data/local/tmp/mbsrv/vkbridge-server）
  --dir STAGE           staging 目录，含 bin/vkbridge-server（或 mali-host/bin/…）
  --server PATH         本机已有的 vkbridge-server

选项：
  --version V           版本号（缺省读 staging/manifest.env，再缺省为 UTC 日期）
  --out DIR             输出目录（默认当前目录）
  --mtime EPOCH         tar 内条目的固定 mtime（默认 SOURCE_DATE_EPOCH，否则 0）
  --force               允许覆盖已存在的同名产物
  -h, --help            显示帮助

校验：
  server 必须是 AArch64 Android（bionic，/system/bin/linker64）可执行文件，
  拒绝 glibc 版本；打包时权限固定为 0755。

输出：
  <out>/mali-host-<version>.tar.zst
  <out>/mali-host-<version>.tar.zst.sha256
EOF
}

while (($# > 0)); do
    case "$1" in
        --device) MODE=device; shift ;;
        --dir) [[ $# -ge 2 ]] || die "--dir 缺少参数"; MODE=dir; STAGE=$2; shift 2 ;;
        --server) [[ $# -ge 2 ]] || die "--server 缺少参数"; MODE=server; SERVER_PATH=$2; shift 2 ;;
        --device-server) [[ $# -ge 2 ]] || die "--device-server 缺少参数"; DEVICE_SERVER=$2; shift 2 ;;
        --serial) [[ $# -ge 2 ]] || die "--serial 缺少参数"; SERIAL=$2; shift 2 ;;
        --version) [[ $# -ge 2 ]] || die "--version 缺少参数"; VERSION=$2; shift 2 ;;
        --out) [[ $# -ge 2 ]] || die "--out 缺少参数"; OUT_DIR=$2; shift 2 ;;
        --mtime) [[ $# -ge 2 ]] || die "--mtime 缺少参数"; MTIME=$2; shift 2 ;;
        --force) FORCE=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "不支持的参数：$1（使用 --help 查看用法）" ;;
    esac
done

[[ -n "$MODE" ]] || die "必须指定 --device、--dir 或 --server 之一"
case "$MTIME" in ''|*[!0-9]*) die "--mtime 必须是非负整数秒：$MTIME" ;; esac

require_cmd() {
    local name
    for name in "$@"; do
        command -v "$name" >/dev/null 2>&1 || die "缺少命令：$name"
    done
}
require_cmd awk basename cp find od sed sha256sum sort stat tar

ZSTD_BIN="${ZSTD:-}"
if [[ -z "$ZSTD_BIN" ]]; then
    command -v zstd >/dev/null 2>&1 || die "缺少 zstd；设置 ZSTD=/path/to/zstd 或安装 zstd。"
    ZSTD_BIN=zstd
fi

[[ -d "$HOST_DIR" ]] || die "找不到 host 脚本目录：$HOST_DIR"
[[ -f "$HOST_DIR/host.env.example" ]] || die "缺少 $HOST_DIR/host.env.example"

OUT_DIR=${OUT_DIR:-$PWD}
mkdir -p "$OUT_DIR"
OUT_DIR=$(cd -- "$OUT_DIR" && pwd -P)

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

adb_ready() {
    command -v adb >/dev/null 2>&1 || die "缺少 adb"
    if [[ -n "$SERIAL" ]]; then
        adb -s "$SERIAL" get-state >/dev/null 2>&1 || die "adb 设备不可用：$SERIAL"
        return 0
    fi
    local devices count
    devices=$(adb devices | tr -d '\r' | awk '$2 == "device" { print $1 }')
    count=$(printf '%s\n' "$devices" | grep -c . || true)
    if [[ "$count" == "1" ]]; then
        SERIAL=$devices
        return 0
    fi
    [[ "$count" == "0" ]] && die "没有已授权的 adb 设备"
    die "检测到多台设备，请用 --serial 指定：$(printf '%s' "$devices" | tr '\n' ' ')"
}

device_prop() {
    adb -s "$SERIAL" shell "getprop '$1'" 2>/dev/null | tr -d '\r' | head -n 1
}

pull_from_device() {
    local destination="$1" remote_sha local_sha
    adb_ready
    adb -s "$SERIAL" shell "su -c 'test -f $DEVICE_SERVER'" >/dev/null 2>&1 || \
        die "设备上找不到 $DEVICE_SERVER（需要 root）"
    log "从设备读取 $DEVICE_SERVER"
    adb -s "$SERIAL" exec-out su -c "cat '$DEVICE_SERVER'" > "$destination" || \
        die "读取 $DEVICE_SERVER 失败"
    [[ -s "$destination" ]] || die "读取到的 server 为空"
    remote_sha=$(adb -s "$SERIAL" shell "su -c 'sha256sum $DEVICE_SERVER'" 2>/dev/null | awk '{print $1}' | tr -d '\r')
    local_sha=$(sha256sum "$destination" | awk '{print $1}')
    [[ -n "$remote_sha" ]] || die "无法读取设备上的 server 校验值"
    [[ "$remote_sha" == "$local_sha" ]] || die "传输校验失败（设备 $remote_sha，本地 $local_sha）"
    log "传输校验通过：sha256=$local_sha"
}

elf_is_aarch64_bionic() {
    local file="$1" identity machine etype
    identity=$(od -An -tx1 -N6 "$file" | tr -d '[:space:]')
    [[ "$identity" == "7f454c460201" ]] || return 1
    etype=$(od -An -tx1 -j16 -N2 "$file" | tr -d '[:space:]')
    machine=$(od -An -tx1 -j18 -N2 "$file" | tr -d '[:space:]')
    [[ "$etype" == "0200" || "$etype" == "0300" ]] || return 1
    [[ "$machine" == "b700" ]] || return 1
    if grep -aq '/system/bin/linker64' "$file"; then
        return 0
    fi
    if grep -aq 'ld-linux-aarch64' "$file"; then
        return 1
    fi
    grep -aq -e 'liblog\.so' -e 'libandroid\.so' "$file"
}

manifest_version_from_stage() {
    local manifest="$1/manifest.env" count value
    [[ -r "$manifest" ]] || return 1
    count=$(grep -Ec '^[[:space:]]*MALI_HOST_BUNDLE_VERSION[[:space:]]*=' "$manifest" || true)
    [[ "$count" == "1" ]] || return 1
    value=$(sed -n 's/^[[:space:]]*MALI_HOST_BUNDLE_VERSION[[:space:]]*=[[:space:]]*//p' "$manifest" | head -n 1 | tr -d '\r')
    [[ -n "$value" ]] || return 1
    printf '%s' "$value"
}

resolve_stage() {
    local base="$1"
    [[ -d "$base" ]] || die "不是目录：$base"
    [[ ! -L "$base" ]] || die "staging 不能是符号链接"
    base=$(cd -- "$base" && pwd -P)
    if [[ -f "$base/bin/vkbridge-server" ]]; then
        SERVER_PATH="$base/bin/vkbridge-server"
    elif [[ -f "$base/mali-host/bin/vkbridge-server" ]]; then
        SERVER_PATH="$base/mali-host/bin/vkbridge-server"
    else
        die "staging 内缺少 bin/vkbridge-server 或 mali-host/bin/vkbridge-server"
    fi
    if [[ -d "$base/scripts" ]] && [[ -n "$(find "$base/scripts" -maxdepth 1 -name '*.sh' -print -quit)" ]]; then
        SCRIPTS_SRC="$base/scripts"
    elif [[ -d "$base/mali-host/scripts" ]] && [[ -n "$(find "$base/mali-host/scripts" -maxdepth 1 -name '*.sh' -print -quit)" ]]; then
        SCRIPTS_SRC="$base/mali-host/scripts"
    fi
    if [[ -z "$VERSION" ]]; then
        VERSION=$(manifest_version_from_stage "$base" || true)
    fi
}

SCRIPTS_SRC=$HOST_DIR
SOURCE_MODE=$MODE

case "$MODE" in
    dir) resolve_stage "$STAGE" ;;
    server)
        [[ -f "$SERVER_PATH" ]] || die "找不到 server：$SERVER_PATH"
        ;;
    device) ;;
esac

if [[ "$MODE" == "device" ]]; then
    PULLED=$WORK/vkbridge-server
    pull_from_device "$PULLED"
    SERVER_PATH=$PULLED
fi

[[ -f "$SERVER_PATH" ]] || die "找不到 server：$SERVER_PATH"
elf_is_aarch64_bionic "$SERVER_PATH" || \
    die "$SERVER_PATH 不是 AArch64 Android（bionic）可执行文件；架构不符，或为 glibc 版本"

[[ -d "$SCRIPTS_SRC" ]] || die "找不到脚本目录：$SCRIPTS_SRC"
[[ -n "$(find "$SCRIPTS_SRC" -maxdepth 1 -name '*.sh' -print -quit)" ]] || die "$SCRIPTS_SRC 下没有 .sh 脚本"

VERSION=${VERSION:-$(date -u '+%Y.%m.%d')}
[[ "$VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]{0,63}$ ]] || \
    die "版本号无效：'$VERSION'（字母、数字、点、下划线、加号、短横线；不能以短横线开头）"

ARCHIVE=$OUT_DIR/mali-host-$VERSION.tar.zst
SUMFILE=$OUT_DIR/mali-host-$VERSION.tar.zst.sha256
if [[ -e "$ARCHIVE" || -e "$SUMFILE" ]] && [[ "$FORCE" != true ]]; then
    die "产物已存在：$ARCHIVE；确认覆盖时加 --force"
fi

ROOT=$WORK/mali-host
mkdir -p "$ROOT/bin" "$ROOT/scripts"
cp -f -- "$SERVER_PATH" "$ROOT/bin/vkbridge-server"
chmod 0755 "$ROOT/bin/vkbridge-server"

for script in "$SCRIPTS_SRC"/*.sh; do
    [[ -f "$script" ]] || continue
    cp -f -- "$script" "$ROOT/scripts/$(basename -- "$script")"
    chmod 0755 "$ROOT/scripts/$(basename -- "$script")"
done
cp -f -- "$HOST_DIR/host.env.example" "$ROOT/host.env.example"
chmod 0644 "$ROOT/host.env.example"

SERVER_HASH=$(sha256sum "$ROOT/bin/vkbridge-server" | awk '{print $1}')
SERVER_SIZE=$(stat -c '%s' "$ROOT/bin/vkbridge-server")
SCRIPT_COUNT=$(find "$ROOT/scripts" -maxdepth 1 -name '*.sh' | wc -l | tr -d ' ')

SOURCE_DEVICE=""
SOURCE_MODEL=""
SOURCE_PRODUCT=""
SOURCE_ANDROID=""
if [[ "$MODE" == "device" ]]; then
    SOURCE_DEVICE=$SERIAL
    SOURCE_MODEL=$(device_prop ro.product.model)
    SOURCE_PRODUCT=$(device_prop ro.product.device)
    SOURCE_ANDROID=$(device_prop ro.build.version.release)
fi

{
    printf 'MALI_HOST_BUNDLE_VERSION=%s\n' "$VERSION"
    printf 'MALI_HOST_SOURCE_MODE=%s\n' "$SOURCE_MODE"
    printf 'MALI_HOST_SOURCE_DEVICE=%s\n' "${SOURCE_DEVICE:-local}"
    printf 'MALI_HOST_SOURCE_MODEL=%s\n' "${SOURCE_MODEL:-unknown}"
    printf 'MALI_HOST_SOURCE_PRODUCT=%s\n' "${SOURCE_PRODUCT:-unknown}"
    printf 'MALI_HOST_SOURCE_ANDROID=%s\n' "${SOURCE_ANDROID:-unknown}"
    printf 'MALI_HOST_SERVER_SHA256=%s\n' "$SERVER_HASH"
    printf 'MALI_HOST_SERVER_SIZE_BYTES=%s\n' "$SERVER_SIZE"
    printf 'MALI_HOST_SERVER_ELF=bionic-aarch64\n'
    printf 'MALI_HOST_SCRIPT_COUNT=%s\n' "$SCRIPT_COUNT"
} > "$ROOT/manifest.env"
chmod 0644 "$ROOT/manifest.env"

write_sums() {
    local root="$1"
    (
        cd -- "$root"
        find . -type f ! -name SHA256SUMS -printf '%P\n' | LC_ALL=C sort | while IFS= read -r path; do
            printf '%s  %s\n' "$(sha256sum -- "$path" | awk '{print $1}')" "$path"
        done
    ) > "$root/SHA256SUMS"
    chmod 0644 "$root/SHA256SUMS"
}
write_sums "$ROOT"

log "打包 mali-host-$VERSION（owner=0、mtime=$MTIME、level=$ZSTD_LEVEL）"
TMP_ARCHIVE=$WORK/archive.tar.zst
(
    cd -- "$WORK"
    tar --sort=name \
        --owner=0 --group=0 --numeric-owner \
        --mtime="@$MTIME" \
        --no-acls --no-selinux --no-xattrs \
        --format=gnu \
        -cf - mali-host
) | "$ZSTD_BIN" -q -T1 "-$ZSTD_LEVEL" --no-progress > "$TMP_ARCHIVE" || die "打包失败"

[[ -s "$TMP_ARCHIVE" ]] || die "产物为空"
HASH=$(sha256sum "$TMP_ARCHIVE" | awk '{print $1}')

mv -f -- "$TMP_ARCHIVE" "$ARCHIVE"
printf '%s  %s\n' "$HASH" "$(basename -- "$ARCHIVE")" > "$SUMFILE"

log "产物：$ARCHIVE（$(stat -c '%s' "$ARCHIVE") 字节）"
log "校验：$SUMFILE"
log "server sha256=$SERVER_HASH"
log "脚本数：$SCRIPT_COUNT"
[[ -z "$SOURCE_DEVICE" ]] || log "来源设备：$SOURCE_DEVICE ${SOURCE_MODEL:-} ${SOURCE_PRODUCT:-} Android ${SOURCE_ANDROID:-}"
