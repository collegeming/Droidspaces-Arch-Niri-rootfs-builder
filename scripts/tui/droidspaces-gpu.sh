#!/usr/bin/env bash
# XRING-O3 GPU path switcher.
#
# The only supported hardware path is Zink -> MaliBridge -> Android host server
# -> Mali. llvmpipe is retained as a diagnostic fallback for OpenGL only; the
# Adreno kgsl/turnip/lavapipe options are intentionally gone.

set -uo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
readonly PROFILE_DIR="${DROIDSPACES_DEVICE_PROFILE_DIR:-/usr/local/lib/droidspaces/device}"
readonly PROFILE_FILE="${XRING_O3_PROFILE_FILE:-${PROFILE_DIR}/xring-o3/profile.sh}"

GPU_ENV_FILE="${DROIDSPACES_GPU_ENV_FILE:-/etc/environment}"
GPU_SCRIPT="${SCRIPT_DIR}/$(basename -- "${BASH_SOURCE[0]}")"
GPU_LANG="${LC_ALL:-${LC_MESSAGES:-${LANG:-C}}}"
GPU_GREEN='' GPU_YELLOW='' GPU_RESET=''
if [[ -t 1 && "${TERM:-dumb}" != dumb && -z "${NO_COLOR:-}" ]]; then
    GPU_GREEN=$'\033[32m' GPU_YELLOW=$'\033[93m' GPU_RESET=$'\033[0m'
fi

if [[ -r "$PROFILE_FILE" ]]; then
    # shellcheck source=../device/xring-o3/profile.sh
    source "$PROFILE_FILE"
fi
GPU_CARD="${XRING_O3_DRM_DEVICE:-/dev/dri/card0}"
GPU_ICD="${XRING_O3_MALI_ICD:-/opt/mali-stack/current/share/vulkan/icd.d/droidbridge_icd.json}"
GPU_SOCKET="${XRING_O3_BRIDGE_SOCKET:-/opt/mb-sock/mali.sock}"
GPU_MESA_DIR="${XRING_O3_MESA_DIR:-/opt/mali-stack/current/mesa}"

gpu_msg() { if [[ "${GPU_LANG,,}" == zh* ]]; then printf '%s' "$1"; else printf '%s' "$2"; fi; }
gpu_gl_label() {
    case "$1" in
        zink) printf 'OpenGL → Zink → MaliBridge → Mali GPU' ;;
        llvmpipe|softpipe) printf 'OpenGL → llvmpipe → CPU（仅诊断）' ;;
        '') printf 'OpenGL → Zink → MaliBridge → Mali GPU（profile 默认）' ;;
        *) printf '%s' "$1" ;;
    esac
}
gpu_vk_label() {
    case "$1" in
        ''|*droidbridge*) printf 'Vulkan → MaliBridge → Mali GPU' ;;
        *) printf '%s' "$1" ;;
    esac
}

gpu_read_saved() {
    local line key value
    GPU_LOADER='' GPU_GALLIUM='' GPU_SOFTWARE='' GPU_ICD='' GPU_OLD_ICD='' GPU_SOCKET_SAVED='' GPU_CARD_SAVED=''
    [[ ! -e "$GPU_ENV_FILE" || -r "$GPU_ENV_FILE" ]] || return 1
    [[ -r "$GPU_ENV_FILE" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Z_]+)[[:space:]]*=[[:space:]]*(.*)$ ]]; then
            key="${BASH_REMATCH[2]}" value="${BASH_REMATCH[3]}"
            value="${value%"${value##*[![:space:]]}"}"
            value="${value#\"}"; value="${value%\"}"
            value="${value#\'}"; value="${value%\'}"
            case "$key" in
                MESA_LOADER_DRIVER_OVERRIDE) GPU_LOADER="$value" ;;
                GALLIUM_DRIVER) GPU_GALLIUM="$value" ;;
                LIBGL_ALWAYS_SOFTWARE) GPU_SOFTWARE="$value" ;;
                VK_DRIVER_FILES) GPU_ICD="$value" ;;
                VK_ICD_FILENAMES) GPU_OLD_ICD="$value" ;;
                VKBRIDGE_SOCKET) GPU_SOCKET_SAVED="$value" ;;
                ANLAND_DRM_DEVICE) GPU_CARD_SAVED="$value" ;;
            esac
        fi
    done < "$GPU_ENV_FILE"
}

gpu_status() {
    local scope="$1" api="$2" loader gallium software icd
    if [[ "$scope" == saved ]]; then
        gpu_read_saved || { gpu_msg '无法读取配置' 'Configuration unreadable'; return 1; }
        loader="$GPU_LOADER" gallium="$GPU_GALLIUM" software="$GPU_SOFTWARE" icd="${GPU_ICD:-$GPU_OLD_ICD}"
    else
        loader="${MESA_LOADER_DRIVER_OVERRIDE:-}" gallium="${GALLIUM_DRIVER:-}"
        software="${LIBGL_ALWAYS_SOFTWARE:-}" icd="${VK_DRIVER_FILES:-${VK_ICD_FILENAMES:-}}"
    fi
    if [[ "$api" == opengl ]]; then
        if [[ "$software" == true || "$software" == 1 ]]; then
            gpu_gl_label "${gallium:-llvmpipe}"
        else
            gpu_gl_label "${gallium:-$loader}"
        fi
    else
        gpu_vk_label "$icd"
    fi
}

gpu_driver_file() {
    local name="$1" file
    for file in \
        "$GPU_MESA_DIR/candidate/usr/lib/dri/$name" \
        /usr/lib/aarch64-linux-gnu/dri/$name \
        /usr/lib64/dri/$name \
        /usr/lib/dri/$name; do
        [[ -f "$file" ]] && return 0
    done
    return 1
}

gpu_manifest_matches() {
    local path="$1"
    [[ "$path" == /* && -f "$path" && -r "$path" ]] || return 1
    [[ "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 1
    if command -v jq >/dev/null 2>&1; then
        jq -e '.ICD.library_path? | type == "string" and (split("/") | last | startswith("libvulkan_droidbridge.so"))' \
            "$path" >/dev/null 2>&1
    elif command -v python3 >/dev/null 2>&1 && python3 -c 'import json' >/dev/null 2>&1; then
        python3 - "$path" <<'PY'
import json, os, sys
try:
    with open(sys.argv[1], encoding='utf-8') as source:
        icd = json.load(source)['ICD']
    ok = os.path.basename(icd['library_path']).startswith('libvulkan_droidbridge.so')
except (OSError, ValueError, TypeError, KeyError, AttributeError):
    ok = False
sys.exit(0 if ok else 1)
PY
    else
        grep -q 'libvulkan_droidbridge\.so' "$path"
    fi
}

gpu_save() {
    local api="$1" mode="$2" temporary
    local pattern='MESA_LOADER_DRIVER_OVERRIDE|GALLIUM_DRIVER|LIBGL_ALWAYS_SOFTWARE|LIBGL_KOPPER_DISABLE|VK_DRIVER_FILES|VK_ICD_FILENAMES|VKBRIDGE_SOCKET|VKBRIDGE_WSI_SHM|ANLAND_DRM_DEVICE|XWAYLAND_GBM_DEVICE|WEBKIT_WEB_RENDER_DEVICE_FILE|WEBKIT_DMABUF_RENDERER_DISABLE_GBM|WEBKIT_DISABLE_DMABUF_RENDERER|GDK_BACKEND|FD_FORCE_KGSL|FD_DEV_FEATURES|TU_DEBUG|MESA_VK_DEVICE_SELECT_FORCE_DEFAULT_DEVICE'

    case "$api:$mode" in
        opengl:zink) gpu_driver_file zink_dri.so || return 1 ;;
        opengl:llvmpipe) gpu_driver_file swrast_dri.so || return 1 ;;
        vulkan:mali) gpu_manifest_matches "$GPU_ICD" || return 1 ;;
        *) return 1 ;;
    esac
    [[ ! -L "$GPU_ENV_FILE" && ( ! -e "$GPU_ENV_FILE" || -f "$GPU_ENV_FILE" ) ]] || return 1

    temporary="$(mktemp "${GPU_ENV_FILE}.tmp.XXXXXXXX")" || return 1
    if [[ -f "$GPU_ENV_FILE" ]]; then
        if ! cp -p -- "$GPU_ENV_FILE" "$temporary" || ! cp -p -- "$GPU_ENV_FILE" "${GPU_ENV_FILE}.droidspaces-gpu.bak"; then
            rm -f -- "$temporary"; return 1
        fi
    else
        chmod 0644 "$temporary" || { rm -f -- "$temporary"; return 1; }
    fi

    if [[ -f "$GPU_ENV_FILE" ]] && ! awk -v keys="$pattern" '
        $0 ~ "^[[:space:]]*(export[[:space:]]+)?(" keys ")[[:space:]]*=" { next }
        { print }
    ' "$GPU_ENV_FILE" > "$temporary"; then
        rm -f -- "$temporary"; return 1
    fi

    if ! {
        printf 'ANLAND_DRM_DEVICE=%s\n' "$GPU_CARD"
        printf 'XWAYLAND_GBM_DEVICE=%s\n' "$GPU_CARD"
        printf 'GDK_BACKEND=wayland\n'
        printf 'WEBKIT_WEB_RENDER_DEVICE_FILE=%s\n' "$GPU_CARD"
        printf 'WEBKIT_DMABUF_RENDERER_DISABLE_GBM=1\n'
        printf 'WEBKIT_DISABLE_DMABUF_RENDERER=0\n'
        case "$api:$mode" in
            opengl:zink)
                printf 'MESA_LOADER_DRIVER_OVERRIDE=zink\nGALLIUM_DRIVER=zink\nLIBGL_KOPPER_DISABLE=false\n'
                printf 'VK_DRIVER_FILES="%s"\nVKBRIDGE_SOCKET="%s"\n' "$GPU_ICD" "$GPU_SOCKET"
                ;;
            opengl:llvmpipe)
                printf 'LIBGL_ALWAYS_SOFTWARE=true\nGALLIUM_DRIVER=llvmpipe\nMESA_LOADER_DRIVER_OVERRIDE=swrast\n'
                printf 'VK_DRIVER_FILES="%s"\nVKBRIDGE_SOCKET="%s"\n' "$GPU_ICD" "$GPU_SOCKET"
                ;;
            vulkan:mali)
                printf 'MESA_LOADER_DRIVER_OVERRIDE=zink\nGALLIUM_DRIVER=zink\nLIBGL_KOPPER_DISABLE=false\n'
                printf 'VK_DRIVER_FILES="%s"\nVKBRIDGE_SOCKET="%s"\n' "$GPU_ICD" "$GPU_SOCKET"
                ;;
        esac
    } >> "$temporary"; then
        rm -f -- "$temporary"; return 1
    fi
    mv -f -- "$temporary" "$GPU_ENV_FILE" || { rm -f -- "$temporary"; return 1; }
}

gpu_option() {
    local number="$1" label="$2" description="$3" color="$GPU_YELLOW"
    [[ "$label" != "$GPU_CURRENT" ]] || color="$GPU_GREEN"
    printf '  %b[%s] %s%b\n      %s\n' "$color" "$number" "$label" "$GPU_RESET" "$description"
}

gpu_menu() {
    local api choice mode status GPU_CURRENT
    while :; do
        [[ ! -t 1 ]] || printf '\033[2J\033[H'
        printf '\n%s\n' "$(gpu_msg 'XRING-O3 / Mali-G2-Ultra-NX GPU 路径' 'XRING-O3 / Mali-G2-Ultra-NX GPU paths')"
        printf '  %s\n' "$(gpu_msg 'DRM: /dev/dri/card0（无 renderD）' 'DRM: /dev/dri/card0 (no renderD)')"
        printf '  %s\n\n' "$(gpu_msg "MaliBridge: $GPU_SOCKET" "MaliBridge: $GPU_SOCKET")"

        printf '  OpenGL — %s: %s\n' "$(gpu_msg '下次启动' 'Next start')" "$(gpu_status saved opengl)"
        GPU_CURRENT="$(gpu_status current opengl)"
        gpu_option 1 "$(gpu_gl_label zink)" \
            "$(gpu_msg '推荐路径：Mesa Zink 经 MaliBridge 使用 Mali GPU。' 'Recommended: Mesa Zink through MaliBridge to the Mali GPU.')"
        gpu_option 2 "$(gpu_gl_label llvmpipe)" \
            "$(gpu_msg 'CPU 软件渲染；只用于隔离驱动问题，Vulkan 仍保留 MaliBridge。' 'CPU software rendering for driver isolation only; Vulkan keeps MaliBridge.')"

        printf '\n  Vulkan — %s: %s\n' "$(gpu_msg '下次启动' 'Next start')" "$(gpu_status saved vulkan)"
        GPU_CURRENT="$(gpu_status current vulkan)"
        gpu_option 3 "$(gpu_vk_label "$GPU_ICD")" \
            "$(gpu_msg '重新写入 MaliBridge ICD 和 socket（不安装驱动）。' 'Rewrite the MaliBridge ICD and socket (does not install drivers).')"

        printf '\n  [0] %s\n\n' "$(gpu_msg '返回' 'Back')"
        printf '%s\n' "$(gpu_msg '保存后请重启容器。驱动未安装或 host server 未运行时，硬件路径不可用。' 'Restart the container after saving. The hardware path is unavailable without the stack and host server.')"
        printf '%s: ' "$(gpu_msg '请选择' 'Select')"
        IFS= read -r choice || return
        case "$choice" in
            1) api=opengl; mode=zink ;;
            2) api=opengl; mode=llvmpipe ;;
            3) api=vulkan; mode=mali ;;
            0|q|Q) return ;;
            *) continue ;;
        esac
        if ((EUID == 0)); then
            gpu_save "$api" "$mode"; status=$?
        elif command -v sudo >/dev/null 2>&1; then
            sudo -- env "DROIDSPACES_GPU_ENV_FILE=$GPU_ENV_FILE" bash "$GPU_SCRIPT" --set "$api" "$mode"; status=$?
        else
            status=1
        fi
        if ((status == 0)); then
            printf '\n%s\n' "$(gpu_msg '配置已保存，请重启容器后使用。' 'Configuration saved. Restart the container to apply it.')"
        else
            printf '\n%s\n' "$(gpu_msg '保存失败：请检查 root 权限、Zink/ICD 文件和配置文件。' 'Save failed: check root access, Zink/ICD files and the configuration file.')"
        fi
        printf '%s' "$(gpu_msg '按 Enter 继续...' 'Press Enter to continue...')"
        IFS= read -r choice || return
    done
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    case "${1:-}" in
        --status)
            [[ $# == 3 && ( "$2" == current || "$2" == saved ) && ( "$3" == opengl || "$3" == vulkan ) ]] || exit 2
            gpu_status "$2" "$3"
            printf '\n'
            ;;
        --set)
            [[ $# == 3 && $EUID == 0 ]] || exit 2
            gpu_save "$2" "$3" ;;
        ""|opengl|vulkan) [[ $# -le 1 ]] || exit 2; gpu_menu ;;
        *) printf '%s\n' 'Usage: droidspaces-gpu | --status current|saved opengl|vulkan | --set opengl zink|llvmpipe | --set vulkan mali' >&2; exit 2 ;;
    esac
fi
