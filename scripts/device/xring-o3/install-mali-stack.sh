#!/usr/bin/env bash
# Install the XRING-O3 Mali stack into /opt/mali-stack/<version>.
#
# Inputs (environment or matching options):
#   MALI_STACK_BUNDLE_URL + MALI_STACK_BUNDLE_SHA256   download and verify an archive
#   MALI_STACK_BUNDLE_DIR                              use an already extracted bundle
#   MALI_STACK_VERSION                                 install directory name
#
# A bundle is a directory containing SHA256SUMS plus the payload described in
# scripts/device/xring-o3/README.md. Missing inputs or files are hard failures;
# this installer never falls back to Adreno/KGSL or to an empty placeholder.

set -euo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly PROFILE_FILE="${SCRIPT_DIR}/profile.sh"
readonly MAX_ARCHIVE_BYTES=$((512 * 1024 * 1024))
readonly MAX_EXTRACTED_BYTES=$((4 * 1024 * 1024 * 1024))

# shellcheck source=profile.sh
source "$PROFILE_FILE"

BUNDLE_URL="${MALI_STACK_BUNDLE_URL:-}"
BUNDLE_SHA256="${MALI_STACK_BUNDLE_SHA256:-}"
BUNDLE_DIR="${MALI_STACK_BUNDLE_DIR:-}"
VERSION="${MALI_STACK_VERSION:-}"
STACK_ROOT="$XRING_O3_MALI_STACK_ROOT"
FORCE=false
UNINSTALL=false
WORK_DIR=""
STAGE_DIR=""
BUNDLE_ROOT=""
ICON_REL=""

log() { printf '[install-mali-stack] %s\n' "$*"; }
die() { printf '[install-mali-stack] 错误: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法: install-mali-stack.sh [选项]

环境变量:
  MALI_STACK_VERSION             安装目录名（必填，或由 bundle 内 manifest.env 提供）
  MALI_STACK_BUNDLE_URL          下载 Mali stack 归档
  MALI_STACK_BUNDLE_SHA256       归档的 SHA-256（URL 模式必填）
  MALI_STACK_BUNDLE_DIR          已解压的 bundle 目录（与 URL 二选一）

选项:
  --version VERSION              覆盖 MALI_STACK_VERSION
  --bundle-url URL               覆盖 MALI_STACK_BUNDLE_URL
  --bundle-dir DIR               覆盖 MALI_STACK_BUNDLE_DIR
  --sha256 HEX                   覆盖 MALI_STACK_BUNDLE_SHA256
  --force                        同版本已存在时重新安装
  --uninstall                    移除 current 链接（指定 --version 时删除该版本）
  --status                       显示当前安装状态
  -h, --help                     显示帮助

bundle 必须包含（详见 scripts/device/xring-o3/README.md）:
  SHA256SUMS
  mesa/candidate/usr/lib/libEGL_mesa.so.0
  mesa/candidate/usr/lib/dri/zink_dri.so
  vkbridge/libvulkan_droidbridge.so
  share/vulkan/icd.d/droidbridge_icd.json
  lib/libgbm.so.1
  lib/libdrmfake.so
  lib/zc-run/zc-classify
  bin/zc-run bin/zc-sync bin/mbctl bin/mb-tray
  share/applications/mb-tray.desktop
  share/icons/hicolor/.../mb-budget.(svg|png)
  etc/budget.conf
EOF
}

parse_arguments() {
    while (($# > 0)); do
        case "$1" in
            --version) [[ $# -ge 2 ]] || die "--version 缺少参数"; VERSION="$2"; shift 2 ;;
            --bundle-url) [[ $# -ge 2 ]] || die "--bundle-url 缺少参数"; BUNDLE_URL="$2"; shift 2 ;;
            --bundle-dir) [[ $# -ge 2 ]] || die "--bundle-dir 缺少参数"; BUNDLE_DIR="$2"; shift 2 ;;
            --sha256) [[ $# -ge 2 ]] || die "--sha256 缺少参数"; BUNDLE_SHA256="$2"; shift 2 ;;
            --force) FORCE=true; shift ;;
            --uninstall) UNINSTALL=true; shift ;;
            --status) status_mode=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "不支持的参数：$1（使用 --help 查看用法）" ;;
        esac
    done
}

status_mode=false

require_root() {
    ((EUID == 0)) && return 0
    command -v sudo >/dev/null 2>&1 || die "请以 root 运行此脚本。"
    log "通过 sudo 重新运行安装器..."
    exec sudo --preserve-env=MALI_STACK_BUNDLE_URL,MALI_STACK_BUNDLE_SHA256,MALI_STACK_BUNDLE_DIR,MALI_STACK_VERSION,DROIDSPACES_DEVICE_PROFILE,XRING_O3_MALI_STACK_ROOT \
        bash "$0" "$@"
}

require_commands() {
    local name
    for name in awk basename cat chmod comm cp date diff dirname du find grep install ln mkdir mktemp mv od readlink rm sed sha256sum sort stat tar; do
        command -v "$name" >/dev/null 2>&1 || die "缺少命令：$name"
    done
    if [[ -n "$BUNDLE_URL" ]]; then
        command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 || \
            die "URL 模式需要 curl 或 wget。"
    fi
}

archive_kind() {
    local path="${1%%\?*}"
    case "$path" in
        *.tar.gz|*.tgz) printf 'gzip' ;;
        *.tar.xz|*.txz) printf 'xz' ;;
        *.tar.zst|*.tzst) printf 'zstd' ;;
        *.tar) printf 'tar' ;;
        *) return 1 ;;
    esac
}

download_file() {
    local url="$1" destination="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 5 --retry-all-errors --connect-timeout 20 --max-time 600 \
            --continue-at - "$url" -o "$destination"
    else
        wget -q --continue --tries=5 --timeout=20 --waitretry=3 --retry-connrefused \
            -O "$destination" "$url"
    fi
}

validate_version() {
    [[ "$VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]{0,63}$ ]] || \
        die "MALI_STACK_VERSION 无效：'${VERSION}'。只允许字母、数字、点、下划线、加号和短横线，且不能以短横线开头。"
    [[ "$VERSION" != "." && "$VERSION" != ".." ]] || die "MALI_STACK_VERSION 不能是 . 或 .."
}

manifest_version() {
    local bundle="$1" value count
    [[ -r "$bundle/manifest.env" ]] || return 1
    value="$(sed -n 's/^[[:space:]]*MALI_STACK_VERSION[[:space:]]*=[[:space:]]*//p' "$bundle/manifest.env" | head -n 1)"
    count="$(grep -Ec '^[[:space:]]*MALI_STACK_VERSION[[:space:]]*=' "$bundle/manifest.env" || true)"
    [[ "$count" == "1" ]] || die "manifest.env 中 MALI_STACK_VERSION 必须且只能出现一次。"
    [[ -n "$value" ]] || return 1
    printf '%s' "$value"
}

resolve_version() {
    if [[ -z "$VERSION" ]]; then
        VERSION="$(manifest_version "$BUNDLE_ROOT" || true)"
    fi
    [[ -n "$VERSION" ]] || die \
        "未指定 MALI_STACK_VERSION，bundle 内也没有 manifest.env 提供版本号。需要 MALI_STACK_VERSION 或 bundle/manifest.env 中的 MALI_STACK_VERSION。"
    validate_version
}

required_paths() {
    printf '%s\n' \
        "mesa/candidate/usr/lib/libEGL_mesa.so.0" \
        "mesa/candidate/usr/lib/dri/zink_dri.so" \
        "vkbridge/libvulkan_droidbridge.so" \
        "share/vulkan/icd.d/droidbridge_icd.json" \
        "lib/libgbm.so.1" \
        "lib/libdrmfake.so" \
        "lib/zc-run/zc-classify" \
        "bin/zc-run" \
        "bin/zc-sync" \
        "bin/mbctl" \
        "bin/mb-tray" \
        "share/applications/mb-tray.desktop" \
        "etc/budget.conf"
}

find_icon() {
    local root="$1" candidate
    for candidate in \
        "share/icons/hicolor/scalable/apps/mb-budget.svg" \
        "share/icons/hicolor/256x256/apps/mb-budget.png" \
        "share/icons/hicolor/128x128/apps/mb-budget.png" \
        "share/icons/hicolor/64x64/apps/mb-budget.png" \
        "share/icons/hicolor/48x48/apps/mb-budget.png"; do
        if [[ -f "$root/$candidate" ]]; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

validate_bundle() {
    local root="$1" path missing=0 icon
    while IFS= read -r path; do
        [[ -f "$root/$path" ]] || { printf '  缺少: %s\n' "$path" >&2; missing=1; }
    done < <(required_paths "$root")
    icon="$(find_icon "$root" || true)"
    if [[ -z "$icon" ]]; then
        printf '  缺少: share/icons/hicolor/.../apps/mb-budget.svg 或 .png\n' >&2
        missing=1
    fi
    if ((missing != 0)); then
        die "bundle 缺少必需文件；这不是可安装的 XRING-O3 Mali stack。发布/准备完整 artifact 后再重试。"
    fi
    ICON_REL="$icon"
}

validate_checksum_manifest() {
    local root="$1"
    local checksums="$root/SHA256SUMS"
    local -a listed=()
    local hash path actual

    [[ -f "$checksums" ]] || die "bundle 缺少 SHA256SUMS；无法校验任何 artifact，拒绝安装。"
    [[ ! -L "$checksums" ]] || die "SHA256SUMS 不能是符号链接。"
    [[ -s "$checksums" ]] || die "SHA256SUMS 为空。"
    if [[ -n "$(find "$root" -type l -print -quit)" ]]; then
        die "bundle 内不允许符号链接。"
    fi

    awk '
        {
            sub(/\r$/, "")
            if (NF != 2 || $1 !~ /^[0-9A-Fa-f]{64}$/ || $2 ~ /^\// ||
                $2 ~ /(^|\/)\.\.(\/|$)/ || $2 ~ /^[-]/ || $2 ~ /[[:space:]]/) {
                exit 1
            }
        }
    ' "$checksums" || die "SHA256SUMS 格式无效：每行必须是 <64位十六进制> <相对路径>，禁止绝对路径、..、空白和以短横线开头的路径。"

    while read -r hash path; do
        [[ -n "$hash" && -n "$path" ]] || continue
        hash="${hash,,}"
        path="${path#\*}"
        path="${path#./}"
        [[ -f "$root/$path" ]] || die "SHA256SUMS 列出的文件不存在：$path"
        actual="$(sha256sum "$root/$path" | awk '{print $1}')"
        [[ "$actual" == "$hash" ]] || die "SHA-256 校验失败：$path（期望 $hash，实际 $actual）"
        listed+=("$path")
    done < "$checksums"

    ((${#listed[@]} > 0)) || die "SHA256SUMS 没有有效条目。"

    # Every regular file in the bundle must be covered, so no unverified
    # payload can ride along with the checked files.
    local actual_file="$WORK_DIR/bundle.files" listed_file="$WORK_DIR/bundle.listed"
    find "$root" -type f -printf '%P\n' | grep -vx 'SHA256SUMS' | sort > "$actual_file"
    printf '%s\n' "${listed[@]}" | sort -u > "$listed_file"
    if ! diff -u "$listed_file" "$actual_file" >/dev/null 2>&1; then
        printf '%s\n' '未被 SHA256SUMS 覆盖的文件：' >&2
        comm -13 "$listed_file" "$actual_file" | sed 's/^/  /' >&2
        die "bundle 中存在未校验文件，拒绝安装。"
    fi
}

validate_aarch64_shared_object() {
    local file="$1" identity type_machine
    identity="$(od -An -tx1 -N6 "$file" | tr -d '[:space:]')"
    type_machine="$(od -An -tx1 -j16 -N4 "$file" | tr -d '[:space:]')"
    [[ "$identity" == "7f454c460201" && "$type_machine" == "0300b700" ]]
}

validate_binaries() {
    local root="$1" file
    for file in \
        "mesa/candidate/usr/lib/libEGL_mesa.so.0" \
        "mesa/candidate/usr/lib/dri/zink_dri.so" \
        "vkbridge/libvulkan_droidbridge.so" \
        "lib/libgbm.so.1" \
        "lib/libdrmfake.so"; do
        validate_aarch64_shared_object "$root/$file" || \
            die "$file 不是 AArch64 ELF 共享对象；bundle 与设备架构不匹配。"
    done
    grep -q 'libvulkan_droidbridge\.so' "$root/share/vulkan/icd.d/droidbridge_icd.json" || \
        die "droidbridge_icd.json 未引用 libvulkan_droidbridge.so。"
}

prepare_bundle_dir() {
    local directory="$1"
    [[ -d "$directory" ]] || die "MALI_STACK_BUNDLE_DIR 不是目录：$directory"
    [[ ! -L "$directory" ]] || die "MALI_STACK_BUNDLE_DIR 不能是符号链接。"
    BUNDLE_ROOT="$(cd -- "$directory" && pwd -P)"
    [[ -f "$BUNDLE_ROOT/SHA256SUMS" ]] || die \
        "MALI_STACK_BUNDLE_DIR 下找不到 SHA256SUMS。bundle 必须是已解压、带 SHA256SUMS 的完整目录。"
}

prepare_bundle_url() {
    local url="$1" archive kind extract_root
    [[ -n "$BUNDLE_SHA256" ]] || die \
        "URL 模式必须提供 MALI_STACK_BUNDLE_SHA256（64 位十六进制）。没有校验值就不下载。"
    [[ "$BUNDLE_SHA256" =~ ^[0-9A-Fa-f]{64}$ ]] || die "MALI_STACK_BUNDLE_SHA256 格式无效。"
    kind="$(archive_kind "$url")" || die \
        "无法识别归档格式：$url。支持 .tar、.tar.gz、.tar.xz、.tar.zst。"
    if [[ "$kind" == "zstd" ]]; then
        command -v zstd >/dev/null 2>&1 || die "解压 .tar.zst 需要 zstd。"
    fi

    archive="$WORK_DIR/mali-stack.bundle"
    log "下载 Mali stack bundle..."
    download_file "$url" "$archive" || die "下载失败：$url"
    local size actual
    size="$(stat -c '%s' "$archive")"
    ((size > 0 && size <= MAX_ARCHIVE_BYTES)) || die "归档大小异常：$size 字节。"
    actual="$(sha256sum "$archive" | awk '{print $1}')"
    [[ "${actual,,}" == "${BUNDLE_SHA256,,}" ]] || die \
        "归档 SHA-256 校验失败（期望 ${BUNDLE_SHA256,,}，实际 $actual）。"

    extract_root="$WORK_DIR/extract"
    mkdir -p "$extract_root"
    case "$kind" in
        tar) tar -xf "$archive" -C "$extract_root" --no-same-owner ;;
        gzip) tar -xzf "$archive" -C "$extract_root" --no-same-owner ;;
        xz) tar -xJf "$archive" -C "$extract_root" --no-same-owner ;;
        zstd) zstd -d -c -- "$archive" | tar -xf - -C "$extract_root" --no-same-owner ;;
    esac || die "归档解压失败。"

    local extracted_bytes
    extracted_bytes="$(du -sb "$extract_root" | awk '{print $1}')"
    ((extracted_bytes <= MAX_EXTRACTED_BYTES)) || die "归档解压后超过大小限制。"

    local checksum_files=()
    mapfile -t checksum_files < <(find "$extract_root" -maxdepth 2 -name SHA256SUMS -type f -print)
    case "${#checksum_files[@]}" in
        0) die "归档中没有 SHA256SUMS。" ;;
        1) BUNDLE_ROOT="$(dirname -- "${checksum_files[0]}")" ;;
        *)
            if [[ -f "$extract_root/SHA256SUMS" ]]; then
                BUNDLE_ROOT="$extract_root"
            else
                die "归档中有多个 SHA256SUMS，无法确定 bundle 根目录。"
            fi
            ;;
    esac
}

generate_stack_config() {
    local version_dir="$1" current="$XRING_O3_MALI_STACK_CURRENT" mesa_prefix
    local vendor_json="$version_dir/mesa/default-egl-vendor.json"
    mesa_prefix="${current}/mesa/candidate/usr/lib"

    if [[ ! -f "$vendor_json" ]]; then
        cat > "$vendor_json" <<EOF
{
  "file_format_version": "1.0.0",
  "ICD": {
    "library_path": "${mesa_prefix}/libEGL_mesa.so.0"
  }
}
EOF
    fi

    install -d -m 0755 "$version_dir/conf"
    cat > "$version_dir/conf/zc-env.conf" <<EOF
# Generated by install-mali-stack.sh; paths track /opt/mali-stack/current.
ZC_MESA_DIR=${current}/mesa
ZC_EGL_VENDOR_JSON=${current}/mesa/default-egl-vendor.json
ZC_ICD=${current}/share/vulkan/icd.d/droidbridge_icd.json
ZC_BRIDGE_SOCKET=${XRING_O3_BRIDGE_SOCKET}
ZC_BRIDGE_LOG_LEVEL=1
ZC_DRM_DEVICE=${XRING_O3_DRM_DEVICE}
EOF
}

atomic_symlink() {
    local target="$1" link="$2" temporary
    install -d -m 0755 "$(dirname -- "$link")"
    if [[ -e "$link" && ! -L "$link" && -d "$link" ]]; then
        die "无法替换目录形式的链接目标：$link"
    fi
    temporary="$(dirname -- "$link")/.$(basename -- "$link").tmp.$$"
    ln -sfn -- "$target" "$temporary"
    mv -Tf -- "$temporary" "$link"
}

install_compat_links() {
    local current="$XRING_O3_MALI_STACK_CURRENT" icon_target name
    for name in zc-run zc-sync mbctl mb-tray; do
        atomic_symlink "$current/bin/$name" "/usr/local/bin/$name"
    done
    atomic_symlink "$current/lib/zc-run/zc-classify" "/usr/local/lib/zc-run/zc-classify"
    atomic_symlink "$current/share/applications/mb-tray.desktop" "/usr/share/applications/mb-tray.desktop"
    icon_target="/usr/share/icons/${ICON_REL#share/icons/}"
    atomic_symlink "$current/$ICON_REL" "$icon_target"
}

install_budget_template() {
    local version_dir="$1" budget_dir
    budget_dir="$(dirname -- "$XRING_O3_BUDGET_CONF")"
    if [[ ! -d "$budget_dir" ]]; then
        install -d -m 0777 -- "$budget_dir"
    fi
    if [[ -e "$XRING_O3_BUDGET_CONF" || -L "$XRING_O3_BUDGET_CONF" ]]; then
        log "保留已有 budget.conf：$XRING_O3_BUDGET_CONF"
    else
        install -m 0644 -- "$version_dir/etc/budget.conf" "$XRING_O3_BUDGET_CONF"
        log "已安装 budget.conf 模板：$XRING_O3_BUDGET_CONF"
    fi
}

record_version() {
    local version="$1" state_file="${XRING_O3_STATE_DIR}/mali-stack.version" temporary
    install -d -m 0755 "$XRING_O3_STATE_DIR"
    temporary="$(mktemp "${state_file}.tmp.XXXXXXXX")"
    printf '%s\n' "$version" > "$temporary"
    chmod 0644 "$temporary"
    mv -f -- "$temporary" "$state_file"
}

install_stack() {
    local version_dir="$STACK_ROOT/$VERSION" existing_backup=""

    install -d -m 0755 "$STACK_ROOT"
    [[ "$STACK_ROOT" == /* ]] || die "MALI_STACK_ROOT 必须是绝对路径：$STACK_ROOT"
    [[ ! -L "$STACK_ROOT" ]] || die "MALI_STACK_ROOT 不能是符号链接：$STACK_ROOT"

    STAGE_DIR="$(mktemp -d "${STACK_ROOT}/.staging.${VERSION}.XXXXXX")"
    log "暂存 bundle 到 $STAGE_DIR ..."
    cp -a -- "$BUNDLE_ROOT/." "$STAGE_DIR/"
    chmod 0755 "$STAGE_DIR"/bin/* "$STAGE_DIR"/lib/zc-run/zc-classify
    validate_checksum_manifest "$STAGE_DIR"
    validate_bundle "$STAGE_DIR"
    validate_binaries "$STAGE_DIR"
    generate_stack_config "$STAGE_DIR"

    if [[ -e "$version_dir" || -L "$version_dir" ]]; then
        if [[ "$FORCE" != true ]]; then
            validate_bundle "$version_dir"
            validate_binaries "$version_dir"
            log "版本 ${VERSION} 已存在且通过校验；使用 --force 可强制替换。"
            rm -rf -- "$STAGE_DIR"
            STAGE_DIR=""
        else
            existing_backup="${STACK_ROOT}/.previous.${VERSION}.$(date +%Y%m%d%H%M%S).$$"
            mv -- "$version_dir" "$existing_backup"
            log "旧版本已移到 $existing_backup"
        fi
    fi

    if [[ -n "$STAGE_DIR" ]]; then
        mv -- "$STAGE_DIR" "$version_dir"
        STAGE_DIR=""
    fi

    atomic_symlink "$version_dir" "$STACK_ROOT/current"
    rm -rf -- "$existing_backup"
    install_budget_template "$version_dir"
    install_compat_links
    record_version "$VERSION"

    log "安装完成：$version_dir"
    log "current -> $(readlink -f -- "$STACK_ROOT/current")"
    log "下一步：确保 Android host 侧 MaliBridge server 正在监听 ${XRING_O3_BRIDGE_SOCKET}，并重启桌面会话。"
}

uninstall_stack() {
    local current="$STACK_ROOT/current" target version_dir
    if [[ -L "$current" ]]; then
        target="$(readlink -f -- "$current")"
        if [[ -n "$VERSION" ]]; then
            [[ "$(basename -- "$target")" == "$VERSION" ]] || \
                die "current 指向 $(basename -- "$target")，不是请求卸载的 ${VERSION}；请先切换或使用匹配版本。"
        fi
        rm -f -- "$current"
        log "已移除 current 链接（原目标 $target）。"
    fi
    if [[ -n "$VERSION" ]]; then
        validate_version
        version_dir="$STACK_ROOT/$VERSION"
        if [[ -e "$version_dir" ]]; then
            rm -rf -- "$version_dir"
            log "已删除版本目录：$version_dir"
        fi
    fi
    rm -f -- "${XRING_O3_STATE_DIR}/mali-stack.version"
    log "卸载完成。兼容链接仍指向 /opt/mali-stack/current，重新安装前会失效。"
}

show_status() {
    local current="$STACK_ROOT/current"
    printf 'profile=%s\nstack_root=%s\ncurrent=%s\n' \
        "$XRING_O3_PROFILE_ID" "$STACK_ROOT" \
        "$([[ -L "$current" ]] && readlink -f -- "$current" || echo "(未安装)")"
    printf 'version_file=%s\n' \
        "$([[ -r "${XRING_O3_STATE_DIR}/mali-stack.version" ]] && cat "${XRING_O3_STATE_DIR}/mali-stack.version" || echo "(无)")"
    printf 'icd=%s (%s)\n' "$XRING_O3_MALI_ICD" \
        "$([[ -f "$XRING_O3_MALI_ICD" ]] && echo present || echo missing)"
    printf 'bridge_socket=%s (%s)\n' "$XRING_O3_BRIDGE_SOCKET" \
        "$([[ -S "$XRING_O3_BRIDGE_SOCKET" ]] && echo listening || echo absent)"
}

cleanup() {
    if [[ -n "$STAGE_DIR" && -d "$STAGE_DIR" ]]; then
        rm -rf -- "$STAGE_DIR" || true
    fi
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR" || true
    fi
}
trap cleanup EXIT

main() {
    parse_arguments "$@"
    if [[ "$status_mode" == true ]]; then
        show_status
        return 0
    fi
    require_root "$@"
    xring_o3_require_active
    require_commands

    if [[ "$UNINSTALL" == true ]]; then
        uninstall_stack
        return 0
    fi

    [[ -z "$BUNDLE_URL" || -z "$BUNDLE_DIR" ]] || \
        die "MALI_STACK_BUNDLE_URL 与 MALI_STACK_BUNDLE_DIR 只能二选一。"
    if [[ -z "$BUNDLE_URL" && -z "$BUNDLE_DIR" ]]; then
        cat >&2 <<EOF
[install-mali-stack] 错误: 没有 Mali stack bundle 可安装。

需要以下任一输入：
  MALI_STACK_BUNDLE_URL + MALI_STACK_BUNDLE_SHA256 [+ MALI_STACK_VERSION]
  MALI_STACK_BUNDLE_DIR [+ MALI_STACK_VERSION，或 bundle/manifest.env]

bundle 必须包含 SHA256SUMS 与以下 artifact：
  mesa/candidate/usr/lib/libEGL_mesa.so.0
  mesa/candidate/usr/lib/dri/zink_dri.so
  vkbridge/libvulkan_droidbridge.so
  share/vulkan/icd.d/droidbridge_icd.json
  lib/libgbm.so.1（完整 38 符号垫片）
  lib/libdrmfake.so
  lib/zc-run/zc-classify
  bin/zc-run bin/zc-sync bin/mbctl bin/mb-tray
  share/applications/mb-tray.desktop
  share/icons/hicolor/.../mb-budget.svg 或 .png
  etc/budget.conf

目前没有已发布的 bundle；请先构建并发布上述 artifact，再带 URL 或本地目录运行。
EOF
        exit 1
    fi

    WORK_DIR="$(mktemp -d -t install-mali-stack.XXXXXXXX)"
    chmod 0700 "$WORK_DIR"
    if [[ -n "$BUNDLE_DIR" ]]; then
        prepare_bundle_dir "$BUNDLE_DIR"
    else
        prepare_bundle_url "$BUNDLE_URL"
    fi
    resolve_version
    validate_checksum_manifest "$BUNDLE_ROOT"
    validate_bundle "$BUNDLE_ROOT"
    validate_binaries "$BUNDLE_ROOT"
    install_stack
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
