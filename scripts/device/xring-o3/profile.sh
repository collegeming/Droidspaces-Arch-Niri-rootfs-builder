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
XRING_O3_MESA_DIR="${XRING_O3_MESA_DIR:-${XRING_O3_MALI_STACK_CURRENT}/mesa}"
XRING_O3_MALI_ICD="${XRING_O3_MALI_ICD:-${XRING_O3_MALI_STACK_CURRENT}/share/vulkan/icd.d/droidbridge_icd.json}"
XRING_O3_MALI_ICD_LIBRARY="${XRING_O3_MALI_ICD_LIBRARY:-${XRING_O3_MALI_STACK_CURRENT}/vkbridge/libvulkan_droidbridge.so}"
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

export XRING_O3_PROFILE_ID XRING_O3_DEVICE_NAME XRING_O3_GPU_NAME
export XRING_O3_ANDROID_VERSION XRING_O3_DISPLAY_BACKEND
export XRING_O3_GRAPHICS_TRANSPORT XRING_O3_HAS_RENDER_NODE
export XRING_O3_DRM_DEVICE XRING_O3_ANLAND_SOCKET
export XRING_O3_MALI_STACK_ROOT XRING_O3_MALI_STACK_CURRENT
export XRING_O3_MESA_DIR XRING_O3_MALI_ICD XRING_O3_MALI_ICD_LIBRARY
export XRING_O3_GBM_SHIM_DIR XRING_O3_GBM_SHIM XRING_O3_DRMFAKE_LIB
export XRING_O3_BRIDGE_SOCKET XRING_O3_BRIDGE_CONTROL_SOCKET
export XRING_O3_BUDGET_CONF XRING_O3_BUDGET_TEMPLATE
export XRING_O3_DEVICE_MARKER XRING_O3_STATE_DIR XRING_O3_PROFILE_LIB_DIR

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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
case "${1:-}" in
    --install)
        xring_o3_install_marker
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

  --install  写入 ${XRING_O3_DEVICE_MARKER} 并创建 Mali stack 目录
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
