#!/bin/sh
# session-gpu-env.sh: session-wide GPU environment for the XRING-O3 Mali stack.
#
# Sourced by start-desktop-session.sh for the niri backend, after
# install-mali-stack.sh has written conf/zc-env.conf. It exports the same pair
# zc-run uses (kopper-retire Mesa + format-capacity MaliBridge client), so niri,
# Xwayland, terminals and every app niri spawns start on the validated stack
# instead of the distribution Mesa that /etc/environment selects.
#
# This file is sourced, not executed.
#
# When conf/zc-env.conf is absent (no bundle installed yet) or names files that
# are not present, nothing is exported and the script returns 0: /etc/environment
# stays authoritative and the session boots on the distribution Mesa.
#
# Noctalia is not affected. /usr/local/bin/noctalia-dt applies its own
# dt-retire + hook2 + wl-gone pair on top of this session environment.

xring_session_conf="${XRING_O3_SESSION_CONF:-${XRING_O3_MALI_STACK_CURRENT:-/opt/mali-stack/current}/conf/zc-env.conf}"
xring_session_mesa_dir=''
xring_session_egl_json=''
xring_session_icd=''
xring_session_socket=''
xring_session_log_level=''
xring_session_drm=''
xring_session_key=''
xring_session_value=''
xring_session_cr=''

if [ -r "$xring_session_conf" ]; then
    xring_session_cr=$(printf '\r')
    while IFS='=' read -r xring_session_key xring_session_value || [ -n "$xring_session_key" ]; do
        case "$xring_session_key" in
            ''|'#'*) continue ;;
        esac
        # Tolerate CRLF conf files edited on a Windows host.
        xring_session_value=${xring_session_value%"$xring_session_cr"}
        case "$xring_session_key" in
            ZC_MESA_DIR) xring_session_mesa_dir=$xring_session_value ;;
            ZC_EGL_VENDOR_JSON) xring_session_egl_json=$xring_session_value ;;
            ZC_ICD) xring_session_icd=$xring_session_value ;;
            ZC_BRIDGE_SOCKET) xring_session_socket=$xring_session_value ;;
            ZC_BRIDGE_LOG_LEVEL) xring_session_log_level=$xring_session_value ;;
            ZC_DRM_DEVICE) xring_session_drm=$xring_session_value ;;
        esac
    done < "$xring_session_conf"
fi

# A conf that points at files the bundle did not install would only move the
# failure into niri's renderer setup; leave the session environment untouched.
if [ -z "$xring_session_mesa_dir" ] || [ -z "$xring_session_icd" ] \
    || [ ! -f "$xring_session_mesa_dir/candidate/usr/lib/libEGL_mesa.so.0" ] \
    || [ ! -f "$xring_session_icd" ]; then
    unset xring_session_conf xring_session_mesa_dir xring_session_egl_json \
        xring_session_icd xring_session_socket xring_session_log_level \
        xring_session_drm xring_session_key xring_session_value xring_session_cr
    return 0 2>/dev/null || exit 0
fi

export LD_LIBRARY_PATH="$xring_session_mesa_dir/candidate/usr/lib"
export __EGL_VENDOR_LIBRARY_FILENAMES="${xring_session_egl_json:-$xring_session_mesa_dir/default-egl-vendor.json}"
export VK_DRIVER_FILES="$xring_session_icd"
export VKBRIDGE_SOCKET="${xring_session_socket:-/opt/mb-sock/mali.sock}"
export VKBRIDGE_LOG_LEVEL="${xring_session_log_level:-1}"
export MESA_LOADER_DRIVER_OVERRIDE=zink
export GALLIUM_DRIVER=zink
export LIBGL_KOPPER_DISABLE=false
export XWAYLAND_GBM_DEVICE="${xring_session_drm:-/dev/dri/card0}"
unset VKBRIDGE_WSI_SHM LIBGL_ALWAYS_SOFTWARE VK_ICD_FILENAMES LD_PRELOAD MESA_KOPPER_LIFECYCLE_TRACE

unset xring_session_conf xring_session_mesa_dir xring_session_egl_json \
    xring_session_icd xring_session_socket xring_session_log_level \
    xring_session_drm xring_session_key xring_session_value xring_session_cr
