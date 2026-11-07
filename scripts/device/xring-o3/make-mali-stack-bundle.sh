#!/usr/bin/env bash
# Build the publishable XRING-O3 Mali stack bundle (rootfs payload).
#
# Input is a staging directory that already has the layout documented in
# scripts/device/xring-o3/README.md. The script verifies that layout, then
# writes <name>.tar.zst plus <name>.tar.zst.sha256 with stable tar metadata.
# It never uploads anything and never edits the staging directory, except when
# --write-sums is given.
#
# Usage:
#   make-mali-stack-bundle.sh --dir STAGE [--version V] [--name NAME] [--out DIR]
#                             [--mtime EPOCH] [--write-sums] [--force]

set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly ZSTD_LEVEL="${ZSTD_LEVEL:-10}"

STAGE=""
VERSION=""
NAME=""
OUT_DIR=""
MTIME="${SOURCE_DATE_EPOCH:-0}"
WRITE_SUMS=false
FORCE=false

log() { printf '[make-mali-stack-bundle] %s\n' "$*"; }
die() { printf '[make-mali-stack-bundle] 错误: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法: make-mali-stack-bundle.sh --dir STAGE [选项]

  --dir STAGE      已按 scripts/device/xring-o3/README.md 摆好的 staging 目录
  --version V      版本号；缺省时读 STAGE/manifest.env 的 MALI_STACK_VERSION
  --name NAME      输出文件名（不含扩展名；默认 mali-stack-<version>）
  --out DIR        输出目录（默认当前目录）
  --mtime EPOCH    tar 内所有条目的固定 mtime（默认 SOURCE_DATE_EPOCH，否则 0）
  --write-sums     先按排序结果重写 STAGE/SHA256SUMS，再校验
  --force          允许覆盖已存在的同名产物
  -h, --help       显示帮助

输出：
  <out>/<name>.tar.zst
  <out>/<name>.tar.zst.sha256     内容为 "<sha256>  <name>.tar.zst"
EOF
}

while (($# > 0)); do
    case "$1" in
        --dir) [[ $# -ge 2 ]] || die "--dir 缺少参数"; STAGE=$2; shift 2 ;;
        --version) [[ $# -ge 2 ]] || die "--version 缺少参数"; VERSION=$2; shift 2 ;;
        --name) [[ $# -ge 2 ]] || die "--name 缺少参数"; NAME=$2; shift 2 ;;
        --out) [[ $# -ge 2 ]] || die "--out 缺少参数"; OUT_DIR=$2; shift 2 ;;
        --mtime) [[ $# -ge 2 ]] || die "--mtime 缺少参数"; MTIME=$2; shift 2 ;;
        --write-sums) WRITE_SUMS=true; shift ;;
        --force) FORCE=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "不支持的参数：$1（使用 --help 查看用法）" ;;
    esac
done

[[ -n "$STAGE" ]] || die "必须指定 --dir STAGE"
[[ -d "$STAGE" ]] || die "不是目录：$STAGE"
[[ ! -L "$STAGE" ]] || die "STAGE 不能是符号链接"
STAGE=$(cd -- "$STAGE" && pwd -P)
OUT_DIR=${OUT_DIR:-$PWD}
mkdir -p "$OUT_DIR"
OUT_DIR=$(cd -- "$OUT_DIR" && pwd -P)

case "$MTIME" in ''|*[!0-9]*) die "--mtime 必须是非负整数秒：$MTIME" ;; esac

require_cmd() {
    local name
    for name in "$@"; do
        command -v "$name" >/dev/null 2>&1 || die "缺少命令：$name"
    done
}
require_cmd awk basename comm diff find grep od sed sha256sum sort stat tar wc

ZSTD_BIN="${ZSTD:-}"
if [[ -z "$ZSTD_BIN" ]]; then
    command -v zstd >/dev/null 2>&1 || die "缺少 zstd；设置 ZSTD=/path/to/zstd 或安装 zstd。"
    ZSTD_BIN=zstd
fi

required_paths() {
    cat <<'EOF'
mesa/candidate/usr/lib/libEGL_mesa.so.0
mesa/candidate/usr/lib/dri/zink_dri.so
vkbridge/libvulkan_droidbridge.so
share/vulkan/icd.d/droidbridge_icd.json
lib/libgbm.so.1
lib/libdrmfake.so
lib/zc-run/zc-classify
bin/zc-run
bin/zc-sync
bin/mbctl
bin/mb-tray
share/applications/mb-tray.desktop
etc/budget.conf
EOF
}

find_icon() {
    local candidate
    for candidate in \
        share/icons/hicolor/scalable/apps/mb-budget.svg \
        share/icons/hicolor/256x256/apps/mb-budget.png \
        share/icons/hicolor/128x128/apps/mb-budget.png \
        share/icons/hicolor/64x64/apps/mb-budget.png \
        share/icons/hicolor/48x48/apps/mb-budget.png; do
        [[ -f "$STAGE/$candidate" ]] && { printf '%s' "$candidate"; return 0; }
    done
    return 1
}

check_tree() {
    local link special path base
    link=$(find "$STAGE" -type l -print -quit)
    [[ -z "$link" ]] || die "bundle 内不允许符号链接：$link"

    special=$(find "$STAGE" ! -type f ! -type d -print -quit)
    [[ -z "$special" ]] || die "bundle 内只允许普通文件和目录：$special"

    while IFS= read -r -d '' path; do
        base=${path##*/}
        [[ "$base" != *[[:space:]]* ]] || die "文件名不能包含空白：$path"
        [[ "$base" != -* ]] || die "文件名不能以短横线开头：$path"
    done < <(find "$STAGE" -mindepth 1 -print0)

    while IFS= read -r path; do
        [[ -f "$STAGE/$path" ]] || die "缺少必需文件：$path"
    done < <(required_paths)
    [[ -n "$(find_icon || true)" ]] || die "缺少 mb-budget 图标（svg 或 48/64/128/256 px PNG）"
}

write_sums() {
    local list="$1"
    find "$STAGE" -type f -printf '%P\n' | grep -vx 'SHA256SUMS' | LC_ALL=C sort > "$list"
    (
        cd "$STAGE"
        while IFS= read -r path; do
            printf '%s  %s\n' "$(sha256sum -- "$path" | awk '{print $1}')" "$path"
        done < "$list"
    ) > "$STAGE/SHA256SUMS.tmp"
    mv -f "$STAGE/SHA256SUMS.tmp" "$STAGE/SHA256SUMS"
    chmod 0644 "$STAGE/SHA256SUMS"
    log "已重写 SHA256SUMS（$(wc -l < "$STAGE/SHA256SUMS") 条）"
}

check_sums_format() {
    local sums="$STAGE/SHA256SUMS"
    [[ -f "$sums" ]] || die "bundle 缺少 SHA256SUMS"
    [[ ! -L "$sums" ]] || die "SHA256SUMS 不能是符号链接"
    [[ -s "$sums" ]] || die "SHA256SUMS 为空"
    LC_ALL=C awk '
        {
            sub(/\r$/, "")
            if ($0 == "" || NF != 2) exit 1
            if ($1 !~ /^[0-9A-Fa-f]{64}$/) exit 1
            if ($2 ~ /^\// || $2 ~ /(^|\/)\.\.(\/|$)/ || $2 ~ /^[-]/ || $2 ~ /[[:space:]]/) exit 1
            if ($0 !~ /^[0-9A-Fa-f]{64}  [^ ]/) exit 1
        }
    ' "$sums" || die "SHA256SUMS 必须是 sha256sum 的原始格式：64 位十六进制、两个空格、相对路径（禁止绝对路径、..、空白、以短横线开头）。"
}

check_sums_coverage() {
    local sums="$STAGE/SHA256SUMS" hash path actual
    local -a listed=()
    declare -A seen=()
    while read -r hash path; do
        [[ -n "$hash" && -n "$path" ]] || continue
        [[ -f "$STAGE/$path" ]] || die "SHA256SUMS 列出的文件不存在：$path"
        [[ -z "${seen[$path]:-}" ]] || die "SHA256SUMS 重复列出：$path"
        seen[$path]=1
        listed+=("$path")
        actual=$(sha256sum "$STAGE/$path" | awk '{print $1}')
        [[ "${actual,,}" == "${hash,,}" ]] || die "SHA-256 不匹配：$path（期望 $hash，实际 $actual）"
    done < "$sums"

    ((${#listed[@]} > 0)) || die "SHA256SUMS 没有有效条目"
    find "$STAGE" -type f -printf '%P\n' | grep -vx 'SHA256SUMS' | LC_ALL=C sort > "$WORK/actual.files"
    printf '%s\n' "${listed[@]}" | LC_ALL=C sort > "$WORK/listed.files"
    if ! diff -u "$WORK/listed.files" "$WORK/actual.files" >/dev/null 2>&1; then
        printf '未被 SHA256SUMS 覆盖的文件：\n' >&2
        comm -13 "$WORK/listed.files" "$WORK/actual.files" | sed 's/^/  /' >&2
        die "bundle 中存在未校验文件"
    fi
}

elf_is_aarch64_shared_object() {
    local file="$1" identity type_machine
    identity=$(od -An -tx1 -N6 "$file" | tr -d '[:space:]')
    type_machine=$(od -An -tx1 -j16 -N4 "$file" | tr -d '[:space:]')
    [[ "$identity" == "7f454c460201" && "$type_machine" == "0300b700" ]]
}

check_elf() {
    local file
    for file in \
        mesa/candidate/usr/lib/libEGL_mesa.so.0 \
        mesa/candidate/usr/lib/dri/zink_dri.so \
        vkbridge/libvulkan_droidbridge.so \
        lib/libgbm.so.1 \
        lib/libdrmfake.so; do
        elf_is_aarch64_shared_object "$STAGE/$file" || \
            die "$file 不是 AArch64 ELF 共享对象"
    done
    grep -q 'libvulkan_droidbridge\.so' "$STAGE/share/vulkan/icd.d/droidbridge_icd.json" || \
        die "droidbridge_icd.json 未引用 libvulkan_droidbridge.so"
}

resolve_version() {
    local manifest="$STAGE/manifest.env" count value
    if [[ -n "$VERSION" ]]; then
        return 0
    fi
    if [[ -r "$manifest" ]]; then
        count=$(grep -Ec '^[[:space:]]*MALI_STACK_VERSION[[:space:]]*=' "$manifest" || true)
        [[ "$count" == "1" ]] || die "manifest.env 中 MALI_STACK_VERSION 必须且只能出现一次"
        value=$(sed -n 's/^[[:space:]]*MALI_STACK_VERSION[[:space:]]*=[[:space:]]*//p' "$manifest" | head -n 1 | tr -d '\r')
        VERSION=$value
    fi
    [[ -n "$VERSION" ]] || die "未指定 --version，manifest.env 中也没有 MALI_STACK_VERSION"
}

validate_version() {
    [[ "$VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]{0,63}$ ]] || \
        die "版本号无效：'$VERSION'（字母、数字、点、下划线、加号、短横线；不能以短横线开头）"
    [[ "$VERSION" != "." && "$VERSION" != ".." ]] || die "版本号不能是 . 或 .."
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

log "校验 staging：$STAGE"
check_tree
if [[ "$WRITE_SUMS" == true ]]; then
    write_sums "$WORK/files.txt"
fi
check_sums_format
check_sums_coverage
check_elf
resolve_version
validate_version
NAME=${NAME:-mali-stack-$VERSION}
[[ "$NAME" =~ ^[0-9A-Za-z._+-]+$ ]] || die "输出名只能包含字母、数字、点、下划线、加号、短横线：$NAME"

ARCHIVE=$OUT_DIR/$NAME.tar.zst
SUMFILE=$OUT_DIR/$NAME.tar.zst.sha256
if [[ -e "$ARCHIVE" || -e "$SUMFILE" ]] && [[ "$FORCE" != true ]]; then
    die "产物已存在：$ARCHIVE；确认覆盖时加 --force"
fi

log "打包 $NAME（owner=0、mtime=$MTIME、level=$ZSTD_LEVEL）"
TMP_ARCHIVE=$WORK/archive.tar.zst
(
    cd -- "$STAGE"
    tar --sort=name \
        --owner=0 --group=0 --numeric-owner \
        --mtime="@$MTIME" \
        --no-acls --no-selinux --no-xattrs \
        --format=gnu \
        -cf - .
) | "$ZSTD_BIN" -q -T1 "-$ZSTD_LEVEL" --no-progress > "$TMP_ARCHIVE" || die "打包失败"

[[ -s "$TMP_ARCHIVE" ]] || die "产物为空"
HASH=$(sha256sum "$TMP_ARCHIVE" | awk '{print $1}')
FILE_COUNT=$(find "$STAGE" -type f | wc -l | tr -d ' ')

mv -f -- "$TMP_ARCHIVE" "$ARCHIVE"
printf '%s  %s\n' "$HASH" "$(basename -- "$ARCHIVE")" > "$SUMFILE"

log "产物：$ARCHIVE（$(stat -c '%s' "$ARCHIVE") 字节）"
log "校验：$SUMFILE"
log "sha256=$HASH"
log "文件数：$FILE_COUNT"
