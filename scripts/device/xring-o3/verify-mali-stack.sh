#!/usr/bin/env bash
# Verify an XRING-O3 Mali stack bundle (directory or archive) against the
# layout install-mali-stack.sh accepts. Read-only: an archive is unpacked into a
# temporary directory that is removed before exit.
#
#   verify-mali-stack.sh <bundle-dir>
#   verify-mali-stack.sh <archive.tar|[.gz|.xz|.zst]>
#
# Prints one line per check and a final PASS/FAIL line. Exit status is 0 on
# PASS, 1 on FAIL, 2 on bad usage. Designed to run in CI and on the device.

set -uo pipefail

readonly SCRIPT_NAME="${0##*/}"
MAX_ARCHIVE_BYTES=$((512 * 1024 * 1024))
MAX_EXTRACTED_BYTES=$((4 * 1024 * 1024 * 1024))

WORK_DIR=""
BUNDLE_ROOT=""
LAYOUT=""
FAILURES=0
CHECKS=0
FILE_COUNT=0

pass() { CHECKS=$((CHECKS + 1)); printf '[PASS] %s\n' "$*"; }
fail() { CHECKS=$((CHECKS + 1)); FAILURES=$((FAILURES + 1)); printf '[FAIL] %s\n' "$*" >&2; }
info() { printf '[info] %s\n' "$*"; }

usage() {
    cat <<EOF
用法: $SCRIPT_NAME <bundle-dir | archive>

  bundle-dir   已解压、含 SHA256SUMS 的 bundle 目录
  archive      .tar / .tar.gz / .tgz / .tar.xz / .tar.zst / .tar

检查项:
  - 归档旁若有 <archive>.sha256，先校验归档本身
  - SHA256SUMS 格式、逐文件 SHA-256、覆盖率（每个普通文件都必须被覆盖）
  - 不允许符号链接或非普通文件
  - 布局：v1 必需路径；v2 双栈组必须整组存在
  - 所有 ELF 必须是 ELF64 / AArch64 / ET_DYN
  - ICD 清单必须用相对路径，且解析到 bundle 内对应客户端
  - 布局 v2 的 noctalia-dt 模板必须保留占位符并引用 conf/noctalia-env.conf
EOF
}

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}
trap cleanup EXIT

archive_kind() {
    case "${1%%\?*}" in
        *.tar.gz|*.tgz) printf 'gzip' ;;
        *.tar.xz|*.txz) printf 'xz' ;;
        *.tar.zst|*.tzst) printf 'zstd' ;;
        *.tar) printf 'tar' ;;
        *) return 1 ;;
    esac
}

# .tar.zst normally goes through the zstd CLI; hosts that only carry the Python
# module (build machines, Windows dev boxes) fall back to it so this check never
# needs a package install.
extract_tar_zst() {
    local archive="$1" dest="$2" candidate
    if command -v zstd >/dev/null 2>&1; then
        zstd -d -c -- "$archive" | tar -xf - -C "$dest"
        return $?
    fi
    local -a interpreters=()
    command -v python3 >/dev/null 2>&1 && interpreters+=("python3")
    command -v python >/dev/null 2>&1 && interpreters+=("python")
    command -v py >/dev/null 2>&1 && interpreters+=("py -3")
    for candidate in "${interpreters[@]}"; do
        # shellcheck disable=SC2086  # "py -3" is intentionally two words
        if $candidate -I - "$archive" "$dest" <<'PY' >/dev/null 2>&1
import io, sys, tarfile

try:
    import zstandard
except ImportError:
    sys.exit(3)

archive, dest = sys.argv[1], sys.argv[2]
with open(archive, 'rb') as fh:
    raw = zstandard.ZstdDecompressor().stream_reader(fh).read()
with tarfile.open(fileobj=io.BytesIO(raw), mode='r:') as tar_stream:
    try:
        tar_stream.extractall(dest, filter='data')
    except TypeError:
        tar_stream.extractall(dest)
PY
        then
            return 0
        fi
    done
    return 1
}

verify_archive_sidecar() {
    local archive="$1" sidecar="$1.sha256" expected actual
    if [[ ! -f "$sidecar" ]]; then
        info "未找到 $sidecar，跳过归档自身校验（bundle 内容仍逐文件校验）"
        return 0
    fi
    expected="$(awk 'NR == 1 { print $1 }' "$sidecar")"
    if [[ ! "$expected" =~ ^[0-9A-Fa-f]{64}$ ]]; then
        fail "归档校验文件格式无效：$sidecar"
        return 1
    fi
    actual="$(sha256sum "$archive" | awk '{print $1}')"
    if [[ "${actual,,}" == "${expected,,}" ]]; then
        pass "归档 SHA-256 与 $sidecar 一致"
        return 0
    fi
    fail "归档 SHA-256 不匹配（期望 ${expected,,}，实际 $actual）"
    return 1
}

extract_archive() {
    local archive="$1" kind extract_root size extracted
    kind="$(archive_kind "$archive")" || { fail "无法识别归档格式：$archive"; return 1; }
    size="$(stat -c '%s' "$archive" 2>/dev/null || echo 0)"
    if ((size <= 0 || size > MAX_ARCHIVE_BYTES)); then
        fail "归档大小异常：$size 字节"
        return 1
    fi
    if [[ "$kind" == "zstd" ]] && ! command -v zstd >/dev/null 2>&1 \
        && ! command -v python3 >/dev/null 2>&1 && ! command -v py >/dev/null 2>&1; then
        fail "解压 .tar.zst 需要 zstd，或带 zstandard 模块的 python3"
        return 1
    fi

    extract_root="$WORK_DIR/extract"
    mkdir -p "$extract_root" || { fail "无法创建临时目录"; return 1; }
    case "$kind" in
        tar) tar -xf "$archive" -C "$extract_root" --no-same-owner ;;
        gzip) tar -xzf "$archive" -C "$extract_root" --no-same-owner ;;
        xz) tar -xJf "$archive" -C "$extract_root" --no-same-owner ;;
        zstd) extract_tar_zst "$archive" "$extract_root" ;;
    esac || { fail "归档解压失败：$archive"; return 1; }

    extracted="$(du -sb "$extract_root" 2>/dev/null | awk '{print $1}')"
    if [[ -n "$extracted" ]] && ((extracted > MAX_EXTRACTED_BYTES)); then
        fail "归档解压后超过大小限制：$extracted 字节"
        return 1
    fi

    local -a roots=()
    mapfile -t roots < <(find "$extract_root" -maxdepth 2 -name SHA256SUMS -type f -print)
    case "${#roots[@]}" in
        0)
            fail "归档中没有 SHA256SUMS"
            return 1
            ;;
        1)
            BUNDLE_ROOT="$(cd -- "$(dirname -- "${roots[0]}")" && pwd -P)"
            ;;
        *)
            if [[ -f "$extract_root/SHA256SUMS" ]]; then
                BUNDLE_ROOT="$extract_root"
            else
                fail "归档中有多个 SHA256SUMS，无法确定 bundle 根目录"
                return 1
            fi
            ;;
    esac
    pass "归档解包完成（$(basename -- "$archive")）"
}

check_manifest_format() {
    local manifest="$1"
    if [[ ! -f "$manifest" ]]; then
        fail "缺少 SHA256SUMS"
        return 1
    fi
    if [[ -s "$manifest" ]] && awk '
        {
            sub(/\r$/, "")
            if (NF != 2 || $1 !~ /^[0-9A-Fa-f]{64}$/ || $2 ~ /^\// ||
                $2 ~ /(^|\/)\.\.(\/|$)/ || $2 ~ /^[-]/ || $2 ~ /[[:space:]]/) {
                exit 1
            }
        }
    ' "$manifest"; then
        pass "SHA256SUMS 格式有效（$(wc -l < "$manifest" | tr -d ' ') 条）"
        return 0
    fi
    fail "SHA256SUMS 格式无效：每行须为 <64位十六进制> <相对路径>，禁止绝对路径、..、空白、短横线开头"
    return 1
}

check_no_symlinks() {
    local root="$1" link extra
    link="$(find "$root" -type l -print -quit)"
    if [[ -n "$link" ]]; then
        fail "bundle 内存在符号链接：${link#"$root"/}"
        return 1
    fi
    extra="$(find "$root" ! -type f ! -type d -print -quit)"
    if [[ -n "$extra" ]]; then
        fail "bundle 内存在非普通文件：${extra#"$root"/}"
        return 1
    fi
    pass "bundle 内没有符号链接或特殊文件"
}

check_hashes_and_coverage() {
    local root="$1" manifest="$1/SHA256SUMS" hash path actual
    local actual_file="$WORK_DIR/files.actual" listed_file="$WORK_DIR/files.listed"
    local -a listed=()
    local errors=0
    while read -r hash path; do
        [[ -n "$hash" && -n "$path" ]] || continue
        hash="${hash,,}"
        path="${path#\*}"
        path="${path#./}"
        if [[ ! -f "$root/$path" ]]; then
            fail "SHA256SUMS 列出的文件不存在：$path"
            errors=$((errors + 1))
            continue
        fi
        actual="$(sha256sum "$root/$path" | awk '{print $1}')"
        if [[ "$actual" != "$hash" ]]; then
            fail "SHA-256 不匹配：$path（期望 $hash，实际 $actual）"
            errors=$((errors + 1))
            continue
        fi
        listed+=("$path")
    done < "$manifest"

    FILE_COUNT=${#listed[@]}
    if ((${#listed[@]} == 0)); then
        fail "SHA256SUMS 没有有效条目"
        return 1
    fi
    find "$root" -type f -printf '%P\n' | grep -vx 'SHA256SUMS' | sort > "$actual_file"
    printf '%s\n' "${listed[@]}" | sort -u > "$listed_file"
    if ! diff -u "$listed_file" "$actual_file" >/dev/null 2>&1; then
        while IFS= read -r path; do
            fail "文件未被 SHA256SUMS 覆盖：$path"
            errors=$((errors + 1))
        done < <(comm -13 "$listed_file" "$actual_file")
    fi
    ((errors == 0)) || return 1
    pass "SHA-256 逐文件一致，且 SHA256SUMS 覆盖全部 $FILE_COUNT 个文件"
    return 0
}

core_paths() {
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

dual_paths() {
    printf '%s\n' \
        "mesa/kopper/usr/lib/libEGL_mesa.so.0" \
        "mesa/kopper/usr/lib/dri/zink_dri.so" \
        "vkbridge/format/libvulkan_droidbridge.so" \
        "vkbridge/shim/libvkb_wl_gone.so" \
        "share/vulkan/icd.d/droidbridge-format.json" \
        "share/xring-o3/noctalia-dt"
}

check_layout() {
    local root="$1" path missing=0 present=0 icon
    while IFS= read -r path; do
        if [[ -f "$root/$path" ]]; then
            present=$((present + 1))
        else
            fail "缺少必需文件：$path"
            missing=1
        fi
    done < <(core_paths)
    icon="$(find "$root/share/icons" -type f \( -name 'mb-budget.svg' -o -name 'mb-budget.png' \) -print -quit 2>/dev/null)"
    if [[ -z "$icon" ]]; then
        fail "缺少图标：share/icons/.../mb-budget.svg 或 .png"
        missing=1
    fi

    local dual_present=0 dual_absent=0
    while IFS= read -r path; do
        if [[ -f "$root/$path" ]]; then
            dual_present=$((dual_present + 1))
        else
            dual_absent=$((dual_absent + 1))
        fi
    done < <(dual_paths)
    if ((dual_present > 0 && dual_absent > 0)); then
        while IFS= read -r path; do
            [[ -f "$root/$path" ]] || fail "双栈布局要求整组存在，缺少：$path"
        done < <(dual_paths)
        return 1
    fi
    if ((dual_present > 0)); then
        LAYOUT="v2"
    else
        LAYOUT="v1"
    fi

    if [[ "$LAYOUT" == "v2" ]]; then
        local dir count
        for dir in mesa/candidate/usr/lib mesa/kopper/usr/lib; do
            count="$(find "$root/$dir" -maxdepth 1 -type f -name 'libgallium-*.so' -print 2>/dev/null | wc -l | tr -d ' ')"
            if [[ "$count" != "1" ]]; then
                fail "$dir/libgallium-*.so 需要恰好一个，实际 $count"
                missing=1
            fi
        done
    fi
    ((missing == 0)) || return 1
    pass "布局 ${LAYOUT}：核心路径齐全$( [[ "$LAYOUT" == v2 ]] && printf '，双栈组齐全' )"
    return 0
}

check_elf() {
    local root="$1" file identity type_machine checked=0
    while IFS= read -r file; do
        identity="$(od -An -tx1 -N4 "$file" | tr -d '[:space:]')"
        [[ "$identity" == "7f454c46" ]] || continue
        checked=$((checked + 1))
        identity="$(od -An -tx1 -N6 "$file" | tr -d '[:space:]')"
        type_machine="$(od -An -tx1 -j16 -N4 "$file" | tr -d '[:space:]')"
        if [[ "$identity" != "7f454c460201" || "$type_machine" != "0300b700" ]]; then
            fail "非 AArch64 ELF64 ET_DYN：${file#"$root"/}（magic=$identity type/machine=$type_machine）"
        fi
    done < <(find "$root" -type f -print)
    if ((checked == 0)); then
        fail "bundle 中没有 ELF 文件，来源可疑"
        return 1
    fi
    pass "全部 $checked 个 ELF 均为 ELF64 / AArch64 / ET_DYN"
    return 0
}

check_icd() {
    local root="$1" icd_rel="$2" expected_rel="$3" library resolved expected
    local icd="$root/$icd_rel"
    if [[ ! -f "$icd" ]]; then
        fail "缺少 ICD 清单：$icd_rel"
        return 1
    fi
    library="$(sed -n 's/.*"library_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$icd" | head -n 1)"
    if [[ -z "$library" ]]; then
        fail "$icd_rel 缺少 ICD.library_path"
        return 1
    fi
    if [[ "$library" == /* ]]; then
        fail "$icd_rel 的 library_path 是绝对路径，换机后失效：$library"
        return 1
    fi
    case "$library" in
        *libvulkan_droidbridge.so) ;;
        *) fail "$icd_rel 未引用 libvulkan_droidbridge.so：$library"; return 1 ;;
    esac
    resolved="$(readlink -f -- "$root/$(dirname -- "$icd_rel")/$library" 2>/dev/null || true)"
    expected="$(readlink -f -- "$root/$expected_rel" 2>/dev/null || true)"
    if [[ -z "$resolved" || ! -f "$resolved" ]]; then
        fail "$icd_rel 的相对路径无法解析：$library"
        return 1
    fi
    if [[ "$resolved" != "$expected" ]]; then
        fail "$icd_rel 应指向 $expected_rel，实际解析为 ${resolved#"$root"/}"
        return 1
    fi
    pass "$icd_rel → $expected_rel（相对路径）"
    return 0
}

check_noctalia_template() {
    local root="$1" ok=0
    local template="$root/share/xring-o3/noctalia-dt"
    if [[ ! -f "$template" ]]; then
        fail "缺少 share/xring-o3/noctalia-dt 模板"
        return 1
    fi
    grep -q '@STACK_CURRENT@' "$template" || { fail "noctalia-dt 模板缺少 @STACK_CURRENT@"; ok=1; }
    grep -q '@NOCTALIA_BIN@' "$template" || { fail "noctalia-dt 模板缺少 @NOCTALIA_BIN@"; ok=1; }
    grep -q 'conf/noctalia-env\.conf' "$template" || { fail "noctalia-dt 模板未引用 conf/noctalia-env.conf"; ok=1; }
    grep -q 'LD_PRELOAD' "$template" || { fail "noctalia-dt 模板未设置 LD_PRELOAD"; ok=1; }
    grep -q 'VK_DRIVER_FILES' "$template" || { fail "noctalia-dt 模板未设置 VK_DRIVER_FILES"; ok=1; }
    ((ok == 0)) || return 1
    pass "noctalia-dt 模板占位符与 preload/ICD 接线有效"
    return 0
}

main() {
    if (($# != 1)); then
        usage >&2
        exit 2
    fi
    case "${1:-}" in
        -h|--help) usage; exit 0 ;;
    esac

    local source="$1" required=(
        awk basename cat comm diff dirname du find grep head mkdir od readlink
        rm sed sha256sum sort stat tar tr wc
    )
    local name
    for name in "${required[@]}"; do
        command -v "$name" >/dev/null 2>&1 || { printf '[FAIL] 缺少命令：%s\n' "$name" >&2; exit 1; }
    done

    WORK_DIR="$(mktemp -d -t verify-mali-stack.XXXXXXXX)" || { printf '[FAIL] 无法创建临时目录\n' >&2; exit 1; }
    chmod 0700 "$WORK_DIR"

    if [[ -d "$source" ]]; then
        BUNDLE_ROOT="$(cd -- "$source" && pwd -P)" || { printf '[FAIL] 无法进入目录：%s\n' "$source" >&2; exit 1; }
        if [[ ! -f "$BUNDLE_ROOT/SHA256SUMS" ]]; then
            printf '[FAIL] %s 下没有 SHA256SUMS\n' "$source" >&2
            exit 1
        fi
        pass "bundle 目录：$BUNDLE_ROOT"
    elif [[ -f "$source" ]]; then
        verify_archive_sidecar "$source" || true
        extract_archive "$source" || { printf '[FAIL] 无法读取归档 %s\n' "$source" >&2; exit 1; }
    else
        printf '[FAIL] 路径不存在：%s\n' "$source" >&2
        exit 2
    fi

    check_manifest_format "$BUNDLE_ROOT/SHA256SUMS" || true
    check_no_symlinks "$BUNDLE_ROOT" || true
    check_hashes_and_coverage "$BUNDLE_ROOT" || true
    check_layout "$BUNDLE_ROOT" || true
    check_elf "$BUNDLE_ROOT" || true
    check_icd "$BUNDLE_ROOT" "share/vulkan/icd.d/droidbridge_icd.json" \
        "vkbridge/libvulkan_droidbridge.so" || true
    if [[ "$LAYOUT" == "v2" ]]; then
        check_icd "$BUNDLE_ROOT" "share/vulkan/icd.d/droidbridge-format.json" \
            "vkbridge/format/libvulkan_droidbridge.so" || true
        check_noctalia_template "$BUNDLE_ROOT" || true
    fi

    if ((FAILURES == 0)); then
        printf '\nPASS layout=%s files=%s checks=%s\n' "${LAYOUT:-unknown}" "$FILE_COUNT" "$CHECKS"
        return 0
    fi
    printf '\nFAIL failures=%s checks=%s\n' "$FAILURES" "$CHECKS" >&2
    return 1
}

main "$@"
