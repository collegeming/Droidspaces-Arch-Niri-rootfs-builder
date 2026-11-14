#!/bin/sh
# 由镜像提供：niri 通过 xwayland-satellite 拉起 Xwayland 的启动器。
#
# 优先 GPU：niri 的 anland 后端在当前无 renderD 的容器里只通告 dmabuf v3
# （无 main_device）。Anland 版 Xwayland 在 v3 分支使用
# $XWAYLAND_GBM_DEVICE，因此这里显式给出 /dev/dri/card0，不创建任何节点。
#
# 2026-11-15 实测：niri dmabuf v3 + XWAYLAND_GBM_DEVICE=/dev/dri/card0 +
# LD_LIBRARY_PATH=/usr/lib（发行版 Mesa，不能带 kopper）+ distro EGL
# vendor json + droidbridge ICD + GALLIUM_DRIVER=zink 时，glxinfo 得到
# zink Vulkan Mali、Accelerated yes，glxgears 窗口在 niri 内正常显示。
#
# 探测失败（无 dmabuf global、eglinfo 选不到 Mali、bridge 未启动）时回退
# llvmpipe，保证 X11 始终可用。XWAYLAND_GPU=0 可强制软件渲染。
stack=${XRING_O3_MALI_STACK_CURRENT:-/opt/mali-stack/current}
icd=${ZC_ICD:-$stack/share/vulkan/icd.d/droidbridge-format.json}
sock=${VKBRIDGE_SOCKET:-/opt/mb-sock/mali.sock}
drm=${XWAYLAND_GBM_DEVICE:-/dev/dri/card0}
egl_json=/usr/share/glvnd/egl_vendor.d/50_mesa.json
gpu_ok=0
if [ "${XWAYLAND_GPU:-1}" = 1 ] && command -v wayland-info >/dev/null 2>&1 \
    && wayland-info 2>/dev/null | grep -q "zwp_linux_dmabuf_v1"; then
    if [ -x /usr/bin/eglinfo ] && [ -f "$icd" ] && [ -e "$drm" ] && [ -S "$sock" ]; then
        if EGL_PLATFORM=surfaceless \
            LD_LIBRARY_PATH=/usr/lib \
            __EGL_VENDOR_LIBRARY_FILENAMES=$egl_json \
            VK_DRIVER_FILES="$icd" VKBRIDGE_SOCKET="$sock" \
            MESA_LOADER_DRIVER_OVERRIDE=zink GALLIUM_DRIVER=zink \
            LIBGL_KOPPER_DISABLE=false \
            timeout 8 eglinfo -B 2>/dev/null | grep -qE 'zink.*Mali|Mali.*zink'; then
            gpu_ok=1
        fi
    fi
fi
if [ "$gpu_ok" = 1 ]; then
    unset __EGL_VENDOR_LIBRARY_FILENAMES LD_LIBRARY_PATH LIBGL_ALWAYS_SOFTWARE
    export LD_LIBRARY_PATH=/usr/lib
    export __EGL_VENDOR_LIBRARY_FILENAMES=$egl_json
    export VK_DRIVER_FILES="$icd" VKBRIDGE_SOCKET="$sock" VKBRIDGE_LOG_LEVEL=1
    export XWAYLAND_GBM_DEVICE="$drm"
    export MESA_LOADER_DRIVER_OVERRIDE=zink GALLIUM_DRIVER=zink
    export LIBGL_KOPPER_DISABLE=false
    exec /usr/sbin/xwayland-satellite "$@"
fi
unset XWAYLAND_GBM_DEVICE
export MESA_LOADER_DRIVER_OVERRIDE=llvmpipe GALLIUM_DRIVER=llvmpipe LIBGL_ALWAYS_SOFTWARE=1
exec /usr/sbin/xwayland-satellite "$@"
