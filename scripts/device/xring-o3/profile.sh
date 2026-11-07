#!/usr/bin/env bash
# XRING-O3 / Mali-G2-Ultra-NX device profile.
#
# This branch replaces the Adreno/KGSL path with the MaliBridge path used on
# Xiaomi Pad 9 Pro Max (XRING-O3, Mali-G2-Ultra-NX, Android 17). The device has
# no /dev/dri/renderD* node; the only DRM node is /dev/dri/card0. Mesa renders
# through Zink into MaliBridge, which forwards Vulkan over a Unix socket to a
# server process on the Android host.

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
fi

XRING_O3_PROFILE_ID="${XRING_O3_PROFILE_ID:-xring-o3}"
XRING_O3_DEVICE_NAME="${XRING_O3_DEVICE_NAME:-XRING-O3}"
XRING_O3_GPU_NAME="${XRING_O3_GPU_NAME:-Mali-G2-Ultra-NX}"
XRING_O3_ANDROID_VERSION="${XRING_O3_ANDROID_VERSION:-17}"
XRING_O3_DISPLAY_BACKEND="${XRING_O3_DISPLAY_BACKEND:-anland-wayland}"
XRING_O3_GRAPHICS_TRANSPORT="${XRING_O3_GRAPHICS_TRANSPORT:-malibridge}"
XRING_O3_HAS_RENDER_NODE="${XRING_O3_HAS_RENDER_NODE:-0}"
XRING_O3_DRM_DEVICE="${XRING_O3_DRM_DEVICE:-/dev/dri/card0}"
XRING_O3_ANLAND_SOCKET="${XRING_O3_ANLAND_SOCKET:-/run/display.sock}"
XRING_O3_MALI_STACK_ROOT="${XRING_O3_MALI_STACK_ROOT:-/opt/mali-stack}"
XRING_O3_MALI_STACK_CURRENT="${XRING_O3_MALI_STACK_CURRENT:-${XRING_O3_MALI_STACK_ROOT}/current}"
# Two coherent stacks live inside one installed bundle. mesa/candidate is the
# dt-retire build, mesa/kopper the kopper-retire build; the two ICD manifests
# select the MaliBridge client builds. Consumers pick a pair, not a mix:
#   zc-run / Chrome / DBX -> kopper + format   (conf/zc-env.conf)
#   Noctalia              -> dt-retire + hook2 (conf/noctalia-env.conf)
XRING_O3_MESA_DIR="${XRING_O3_MESA_DIR:-${XRING_O3_MALI_STACK_CURRENT}/mesa}"
XRING_O3_MESA_DT_DIR="${XRING_O3_MESA_DT_DIR:-${XRING_O3_MALI_STACK_CURRENT}/mesa}"
XRING_O3_MESA_KOPPER_DIR="${XRING_O3_MESA_KOPPER_DIR:-${XRING_O3_MALI_STACK_CURRENT}/mesa/kopper}"
XRING_O3_MALI_ICD="${XRING_O3_MALI_ICD:-${XRING_O3_MALI_STACK_CURRENT}/share/vulkan/icd.d/droidbridge_icd.json}"
XRING_O3_MALI_ICD_HOOK2="${XRING_O3_MALI_ICD_HOOK2:-${XRING_O3_MALI_STACK_CURRENT}/share/vulkan/icd.d/droidbridge_icd.json}"
XRING_O3_MALI_ICD_FORMAT="${XRING_O3_MALI_ICD_FORMAT:-${XRING_O3_MALI_STACK_CURRENT}/share/vulkan/icd.d/droidbridge-format.json}"
XRING_O3_MALI_ICD_LIBRARY="${XRING_O3_MALI_ICD_LIBRARY:-${XRING_O3_MALI_STACK_CURRENT}/vkbridge/libvulkan_droidbridge.so}"
XRING_O3_MALI_ICD_FORMAT_LIBRARY="${XRING_O3_MALI_ICD_FORMAT_LIBRARY:-${XRING_O3_MALI_STACK_CURRENT}/vkbridge/format/libvulkan_droidbridge.so}"
XRING_O3_WL_GONE_SHIM="${XRING_O3_WL_GONE_SHIM:-${XRING_O3_MALI_STACK_CURRENT}/vkbridge/shim/libvkb_wl_gone.so}"
XRING_O3_NOCTALIA_ENV="${XRING_O3_NOCTALIA_ENV:-${XRING_O3_MALI_STACK_CURRENT}/conf/noctalia-env.conf}"
XRING_O3_NOCTALIA_WRAPPER="${XRING_O3_NOCTALIA_WRAPPER:-/usr/local/bin/noctalia-dt}"
XRING_O3_NOCTALIA_BIN="${XRING_O3_NOCTALIA_BIN:-/usr/bin/noctalia}"
XRING_O3_GBM_SHIM_DIR="${XRING_O3_GBM_SHIM_DIR:-${XRING_O3_MALI_STACK_CURRENT}/lib}"
XRING_O3_GBM_SHIM="${XRING_O3_GBM_SHIM:-${XRING_O3_GBM_SHIM_DIR}/libgbm.so.1}"
XRING_O3_DRMFAKE_LIB="${XRING_O3_DRMFAKE_LIB:-${XRING_O3_GBM_SHIM_DIR}/libdrmfake.so}"
XRING_O3_BRIDGE_SOCKET="${XRING_O3_BRIDGE_SOCKET:-/opt/mb-sock/mali.sock}"
XRING_O3_BRIDGE_CONTROL_SOCKET="${XRING_O3_BRIDGE_CONTROL_SOCKET:-/opt/mb-sock/control.sock}"
XRING_O3_BUDGET_CONF="${XRING_O3_BUDGET_CONF:-/opt/mb-sock/budget.conf}"
XRING_O3_BUDGET_TEMPLATE="${XRING_O3_BUDGET_TEMPLATE:-${XRING_O3_MALI_STACK_CURRENT}/etc/budget.conf}"
XRING_O3_DEVICE_MARKER="${XRING_O3_DEVICE_MARKER:-/etc/xring-o3/device-profile}"
XRING_O3_STATE_DIR="${XRING_O3_STATE_DIR:-/var/lib/droidspaces-tui/components}"
XRING_O3_PROFILE_LIB_DIR="${XRING_O3_PROFILE_LIB_DIR:-/usr/local/lib/droidspaces/device/xring-o3}"
# Bridge readiness gate for desktop-session.service. The host server creates both
# sockets; mali.sock alone is not enough because mbctl/mb-tray need control.sock.
XRING_O3_WAIT_BRIDGE="${XRING_O3_WAIT_BRIDGE:-${XRING_O3_PROFILE_LIB_DIR}/wait-for-bridge.sh}"
XRING_O3_WAIT_BRIDGE_LINK="${XRING_O3_WAIT_BRIDGE_LINK:-/usr/local/bin/wait-for-mali-bridge}"
XRING_O3_DESKTOP_SESSION_UNIT="${XRING_O3_DESKTOP_SESSION_UNIT:-/etc/systemd/system/desktop-session.service}"
# Session-level GPU environment for the niri backend. start-desktop-session.sh
# sources this exact path, so it must exist in the profile directory.
XRING_O3_SESSION_GPU_ENV="${XRING_O3_SESSION_GPU_ENV:-${XRING_O3_PROFILE_LIB_DIR}/session-gpu-env.sh}"

export XRING_O3_PROFILE_ID XRING_O3_DEVICE_NAME XRING_O3_GPU_NAME
export XRING_O3_ANDROID_VERSION XRING_O3_DISPLAY_BACKEND
export XRING_O3_GRAPHICS_TRANSPORT XRING_O3_HAS_RENDER_NODE
export XRING_O3_DRM_DEVICE XRING_O3_ANLAND_SOCKET
export XRING_O3_MALI_STACK_ROOT XRING_O3_MALI_STACK_CURRENT
export XRING_O3_MESA_DIR XRING_O3_MESA_DT_DIR XRING_O3_MESA_KOPPER_DIR
export XRING_O3_MALI_ICD XRING_O3_MALI_ICD_HOOK2 XRING_O3_MALI_ICD_FORMAT
export XRING_O3_MALI_ICD_LIBRARY XRING_O3_MALI_ICD_FORMAT_LIBRARY
export XRING_O3_WL_GONE_SHIM XRING_O3_NOCTALIA_ENV XRING_O3_NOCTALIA_WRAPPER
export XRING_O3_NOCTALIA_BIN
export XRING_O3_GBM_SHIM_DIR XRING_O3_GBM_SHIM XRING_O3_DRMFAKE_LIB
export XRING_O3_BRIDGE_SOCKET XRING_O3_BRIDGE_CONTROL_SOCKET
export XRING_O3_BUDGET_CONF XRING_O3_BUDGET_TEMPLATE
export XRING_O3_DEVICE_MARKER XRING_O3_STATE_DIR XRING_O3_PROFILE_LIB_DIR
export XRING_O3_WAIT_BRIDGE XRING_O3_WAIT_BRIDGE_LINK XRING_O3_DESKTOP_SESSION_UNIT
export XRING_O3_SESSION_GPU_ENV

xring_o3_profile_is_active() {
    if [[ "${DROIDSPACES_DEVICE_PROFILE:-}" == "$XRING_O3_PROFILE_ID" ]]; then
        return 0
    fi
    [[ -r "$XRING_O3_DEVICE_MARKER" ]] || return 1
    grep -Eq "^[[:space:]]*${XRING_O3_PROFILE_ID}[[:space:]]*$" "$XRING_O3_DEVICE_MARKER"
}

xring_o3_require_active() {
    xring_o3_profile_is_active && return 0
    printf '%s\n' \
        "错误：当前 RootFS 未标记为 ${XRING_O3_PROFILE_ID} 设备档案。" \
        "Error: this rootfs is not marked with the ${XRING_O3_PROFILE_ID} device profile." \
        "缺少标记文件：${XRING_O3_DEVICE_MARKER}（内容应为 ${XRING_O3_PROFILE_ID}）。" \
        "Missing marker: ${XRING_O3_DEVICE_MARKER} (expected content: ${XRING_O3_PROFILE_ID})." \
        "该分支只提供 XRING-O3/Mali 路径，不包含 Adreno/KGSL 回退。" \
        "This branch provides the XRING-O3/Mali path only; there is no Adreno/KGSL fallback." >&2
    return 1
}

# Environment entries shared by the niri profile, the runtime GPU switcher and
# the Mali stack installer. Values that depend on /opt/mali-stack/current are
# stable across stack upgrades because current is switched atomically.
#
# These values are the session-wide fallback written to /etc/environment. They
# never set LD_PRELOAD and never pin a Mesa tree through LD_LIBRARY_PATH, so a
# consumer without its own wrapper cannot end up with a half-configured stack.
# The validated pairs are applied per consumer instead:
#   /usr/local/bin/zc-run      reads ${ZC_PREFIX}/conf/zc-env.conf
#                              -> mesa/kopper + droidbridge-format.json
#   /usr/local/bin/noctalia-dt reads conf/noctalia-env.conf
#                              -> mesa (dt-retire) + droidbridge_icd.json
#                                 (hook2) + vkbridge/shim/libvkb_wl_gone.so
# VK_DRIVER_FILES stays on the hook2 manifest because that file exists in both
# bundle layouts; it only decides Vulkan for consumers with no wrapper at all.
xring_o3_environment_assignments() {
    printf '%s\n' \
        "XDG_SESSION_CLASS=user" \
        "XDG_SESSION_TYPE=wayland" \
        "QT_QPA_PLATFORM=wayland" \
        "ANLAND=1" \
        "ANLAND_PRESENT_BACKEND=legacy" \
        "ANLAND_SOCKET=${XRING_O3_ANLAND_SOCKET}" \
        "ANLAND_DRM_DEVICE=${XRING_O3_DRM_DEVICE}" \
        "ANLAND_SKIP_IMPLICIT_SYNC_WAIT=1" \
        "XWAYLAND_GBM_DEVICE=${XRING_O3_DRM_DEVICE}" \
        "MESA_LOADER_DRIVER_OVERRIDE=zink" \
        "GALLIUM_DRIVER=zink" \
        "LIBGL_KOPPER_DISABLE=false" \
        "VK_DRIVER_FILES=${XRING_O3_MALI_ICD}" \
        "VKBRIDGE_SOCKET=${XRING_O3_BRIDGE_SOCKET}" \
        "WEBKIT_WEB_RENDER_DEVICE_FILE=${XRING_O3_DRM_DEVICE}" \
        "WEBKIT_DMABUF_RENDERER_DISABLE_GBM=1" \
        "WEBKIT_DISABLE_DMABUF_RENDERER=0" \
        "GDK_BACKEND=wayland" \
        "ZC_PREFIX=${XRING_O3_MALI_STACK_CURRENT}" \
        "ZC_CLASSIFY=${XRING_O3_MALI_STACK_CURRENT}/lib/zc-run/zc-classify"
}

# Values written by the old Adreno profiles. They must be deleted, not merely
# shadowed, because /etc/environment has no shell ordering semantics.
xring_o3_obsolete_environment_keys() {
    printf '%s\n' \
        "FD_FORCE_KGSL" \
        "FD_DEV_FEATURES" \
        "MESA_VK_DEVICE_SELECT_FORCE_DEFAULT_DEVICE" \
        "TU_DEBUG" \
        "LIBGL_ALWAYS_SOFTWARE" \
        "VK_ICD_FILENAMES" \
        "VKBRIDGE_WSI_SHM"
}

xring_o3_show() {
    printf 'PROFILE=%s\nDEVICE=%s\nGPU=%s\nANDROID=%s\n' \
        "$XRING_O3_PROFILE_ID" "$XRING_O3_DEVICE_NAME" \
        "$XRING_O3_GPU_NAME" "$XRING_O3_ANDROID_VERSION"
    printf 'DISPLAY_BACKEND=%s\nGRAPHICS_TRANSPORT=%s\nHAS_RENDER_NODE=%s\nDRM_DEVICE=%s\n' \
        "$XRING_O3_DISPLAY_BACKEND" "$XRING_O3_GRAPHICS_TRANSPORT" \
        "$XRING_O3_HAS_RENDER_NODE" "$XRING_O3_DRM_DEVICE"
    printf 'ANLAND_SOCKET=%s\nMALI_STACK_ROOT=%s\nMALI_STACK_CURRENT=%s\n' \
        "$XRING_O3_ANLAND_SOCKET" "$XRING_O3_MALI_STACK_ROOT" \
        "$XRING_O3_MALI_STACK_CURRENT"
    printf 'MESA_DT_DIR=%s\nMESA_KOPPER_DIR=%s\n' \
        "$XRING_O3_MESA_DT_DIR" "$XRING_O3_MESA_KOPPER_DIR"
    printf 'ZC_ICD=%s\nNOCTALIA_ICD=%s\n' \
        "$XRING_O3_MALI_ICD_FORMAT" "$XRING_O3_MALI_ICD_HOOK2"
    printf 'NOCTALIA_SHIM=%s\nNOCTALIA_WRAPPER=%s\n' \
        "$XRING_O3_WL_GONE_SHIM" "$XRING_O3_NOCTALIA_WRAPPER"
    printf 'WAIT_BRIDGE=%s (%s)\n' "$XRING_O3_WAIT_BRIDGE_LINK" \
        "$([[ -x "$XRING_O3_WAIT_BRIDGE_LINK" ]] && echo present || echo missing)"
    printf 'SESSION_GPU_ENV=%s (%s)\n' "$XRING_O3_SESSION_GPU_ENV" \
        "$([[ -r "$XRING_O3_SESSION_GPU_ENV" ]] && echo present || echo missing)"
    printf 'DESKTOP_UNIT=%s (%s)\n' "$XRING_O3_DESKTOP_SESSION_UNIT" \
        "$([[ -f "$XRING_O3_DESKTOP_SESSION_UNIT" ]] && echo present || echo missing)"
    printf 'MALI_ICD=%s\nVKBRIDGE_SOCKET=%s\nBUDGET_CONF=%s\n' \
        "$XRING_O3_MALI_ICD" "$XRING_O3_BRIDGE_SOCKET" "$XRING_O3_BUDGET_CONF"
}

xring_o3_install_marker() {
    local marker_dir temporary_file
    marker_dir="$(dirname -- "$XRING_O3_DEVICE_MARKER")"
    install -d -m 0755 -- "$marker_dir" "$XRING_O3_MALI_STACK_ROOT" \
        "$XRING_O3_STATE_DIR" /etc/mali-stack
    temporary_file="$(mktemp "${XRING_O3_DEVICE_MARKER}.tmp.XXXXXXXX")"
    printf '%s\n' "$XRING_O3_PROFILE_ID" > "$temporary_file"
    chmod 0644 "$temporary_file"
    mv -f -- "$temporary_file" "$XRING_O3_DEVICE_MARKER"
    printf 'device profile installed: %s -> %s\n' \
        "$XRING_O3_DEVICE_MARKER" "$XRING_O3_PROFILE_ID"
}

# /usr/local/bin/wait-for-mali-bridge is the ExecStartPre target of
# desktop-session.service. A symlink into the device profile directory keeps it
# in step with the script; the replace is atomic so a running boot never sees a
# half-written entry.
xring_o3_link_wait_bridge() {
    local target="$XRING_O3_WAIT_BRIDGE" link="$XRING_O3_WAIT_BRIDGE_LINK" temporary
    if [[ ! -f "$target" ]]; then
        printf '缺少 MaliBridge 就绪检查脚本：%s\n' "$target" >&2
        return 1
    fi
    if [[ ! -x "$target" ]]; then
        printf '警告：%s 不可执行；ExecStartPre 会以 203/EXEC 失败，请先 chmod +x。\n' "$target" >&2
    fi
    install -d -m 0755 -- "$(dirname -- "$link")"
    if [[ -e "$link" && ! -L "$link" && -d "$link" ]]; then
        printf '无法替换目录形式的链接目标：%s\n' "$link" >&2
        return 1
    fi
    temporary="$(dirname -- "$link")/.$(basename -- "$link").tmp.$$"
    ln -sfn -- "$target" "$temporary"
    mv -Tf -- "$temporary" "$link"
    printf 'bridge gate installed: %s -> %s\n' "$link" "$target"
}

# Session-level GPU environment for niri. start-desktop-session.sh sources this
# exact path, so --install fails when it is absent: a missing file silently
# drops the whole session back to the distribution Mesa, which is the failure
# this file exists to prevent.
xring_o3_install_session_gpu_env() {
    local helper="$XRING_O3_SESSION_GPU_ENV"
    if [[ ! -r "$helper" ]]; then
        printf '缺少会话级 GPU 环境脚本：%s（niri 会话会回退到发行版 Mesa）\n' "$helper" >&2
        return 1
    fi
    printf 'session GPU env installed: %s\n' "$helper"
}

# The unit is written by configure-desktop.sh after this profile runs, so a
# missing unit is reported, not treated as a fatal error. Once the unit exists,
# its ExecStartPre must call the gate, or the desktop can race the host server.
xring_o3_validate_desktop_unit() {
    local unit="$XRING_O3_DESKTOP_SESSION_UNIT"
    if [[ ! -f "$unit" ]]; then
        printf '提示：%s 尚未安装；configure-desktop.sh 写入后 ExecStartPre 生效。\n' "$unit"
        return 0
    fi
    if ! grep -Eq '^ExecStartPre=[[:space:]]*-?/usr/local/bin/wait-for-mali-bridge([[:space:]]|$)' "$unit"; then
        printf '警告：%s 缺少 wait-for-mali-bridge 的 ExecStartPre；桌面可能在 MaliBridge 就绪前启动。\n' "$unit" >&2
        return 0
    fi
    printf 'desktop-session bridge gate: %s\n' "$unit"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
case "${1:-}" in
    --install)
        xring_o3_install_marker || exit 1
        xring_o3_link_wait_bridge || exit 1
        xring_o3_install_session_gpu_env || exit 1
        xring_o3_validate_desktop_unit
        ;;
    --show)
        xring_o3_show
        ;;
    --env)
        xring_o3_environment_assignments
        ;;
    --check)
        xring_o3_require_active
        xring_o3_show
        ;;
    ""|--help|-h)
        cat <<EOF
用法: $0 --install | --show | --env | --check

  --install  写入 ${XRING_O3_DEVICE_MARKER}、创建 Mali stack 目录，并安装
             ${XRING_O3_WAIT_BRIDGE_LINK}（等待 mali.sock 与 control.sock）
             与会话级 GPU 环境 ${XRING_O3_SESSION_GPU_ENV}
  --show     打印设备档案
  --env      打印应写入 /etc/environment 的赋值
  --check    校验当前 RootFS 是否为 ${XRING_O3_PROFILE_ID}

该 profile 也可被其他脚本 source 后使用同名变量和函数。
EOF
        ;;
    *)
        printf '无效参数：%s\n' "$1" >&2
        exit 2
        ;;
esac
fi
