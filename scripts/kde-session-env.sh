#!/bin/sh
# kde-session-env.sh: GPU environment for the KDE (Anland KWin) session on
# XRING-O3 / MaliBridge.
#
# KWin 6.8 opens a RenderDevice through GBM + EGL. The container has no render
# node, so KWIN_RENDER_NODES points at /dev/dri/card0 and the bundle libgbm shim
# keeps every allocation LINEAR (zink cannot import the AFBC modifiers the
# distribution Mesa would otherwise offer).
#
# This file deliberately does NOT put mesa/kopper on LD_LIBRARY_PATH. The
# kopper 26.3 EGL crashes (eglInitialize SIGSEGV) when it receives a gbm_device
# created by the distribution libgbm, which is exactly what KWin passes in.
# KDE therefore uses distribution Mesa + the MaliBridge format ICD; on
# archniri23 that pair passed gbm_create_device, EGL init, GLES FBO rendering
# and dmabuf EGLImage import (Mesa 26.2.6, zink -> Mali-G2-Ultra-NX).
#
# This file is sourced, not executed. When the stack is absent nothing is
# exported and /etc/environment stays authoritative.

xring_kde_stack="${XRING_O3_MALI_STACK_CURRENT:-/opt/mali-stack/current}"
xring_kde_icd="${XRING_O3_MALI_ICD_FORMAT:-${xring_kde_stack}/share/vulkan/icd.d/droidbridge-format.json}"
xring_kde_socket="${XRING_O3_BRIDGE_SOCKET:-/opt/mb-sock/mali.sock}"
xring_kde_drm="${XRING_O3_DRM_DEVICE:-/dev/dri/card0}"
xring_kde_egl_json="${KDE_EGL_VENDOR_JSON:-/usr/share/glvnd/egl_vendor.d/50_mesa.json}"

if [ -f "${xring_kde_stack}/lib/libgbm.so.1" ] && [ -f "$xring_kde_icd" ]; then
    # Only the shim/drmfake directory: Mesa itself must stay the distribution
    # build so libgbm and libEGL_mesa come from the same source tree.
    export LD_LIBRARY_PATH="${xring_kde_stack}/lib"
    [ -f "$xring_kde_egl_json" ] && export __EGL_VENDOR_LIBRARY_FILENAMES="$xring_kde_egl_json"
    export VK_DRIVER_FILES="$xring_kde_icd"
    export VKBRIDGE_SOCKET="$xring_kde_socket"
    export VKBRIDGE_LOG_LEVEL="${VKBRIDGE_LOG_LEVEL:-1}"
    export MESA_LOADER_DRIVER_OVERRIDE=zink
    # 不要给客户端会话设置 GALLIUM_DRIVER=zink：容器没有 renderD，Mesa 的
    # Wayland EGL 会落到 swrast 平台；zink 在 swrast 上需要
    # VK_EXT_external_memory_host 才能写回 wl_shm，而 MaliBridge 的 hostptr
    # 自检失败，客户端 buffer 会保持全 0（kitty/es2gears 全透明）。
    # KWin 自己需要 zink，由 configure-desktop 写入的
    # plasma-kwin_wayland.service.d/10-gpu.conf 单独提供。
    export KWIN_RENDER_NODES="${KWIN_RENDER_NODES:-$xring_kde_drm}"
    export ANLAND_DRM_DEVICE="${ANLAND_DRM_DEVICE:-$xring_kde_drm}"
    export XWAYLAND_GBM_DEVICE="${XWAYLAND_GBM_DEVICE:-$xring_kde_drm}"
    # Avoid the distribution loader picking llvmpipe when zink is unavailable.
    unset LIBGL_ALWAYS_SOFTWARE
fi

export ANLAND_SKIP_IMPLICIT_SYNC_WAIT=1
# Upstream notes a busy loop in the Anland audio engine on this platform; KDE
# audio is not part of the first Fedora validation.
export ANLAND_DISABLE_AUDIO="${ANLAND_DISABLE_AUDIO:-1}"
export QT_QPA_PLATFORM=wayland
export GDK_BACKEND=wayland
export XDG_SESSION_TYPE=wayland
export XDG_SESSION_CLASS=user
# Qt Quick / GTK4 客户端使用 Vulkan → MaliBridge（dmabuf）；KWin 与
# plasmashell 的 systemd drop-in 会分别覆盖为 opengl/software。
export QSG_RHI_BACKEND=vulkan
export GSK_RENDERER=vulkan

unset xring_kde_stack xring_kde_icd xring_kde_socket xring_kde_drm xring_kde_egl_json
