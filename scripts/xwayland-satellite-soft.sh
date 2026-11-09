#!/bin/sh
# 由镜像提供：niri 通过 xwayland-satellite 拉起 Xwayland 的启动器。
#
# 默认走软件渲染（llvmpipe），这是当前唯一稳定可用的 X11 方案：
#   - 容器只有 /dev/dri/card0（无真实 renderD128）；不设 XWAYLAND_GBM_DEVICE 时
#     Xwayland 回落 swrast，X11 应用正常。
#   - 若按会话环境走 card0 + zink/MaliBridge，glamor 初始化会 SIGSEGV，niri
#     反复重启 satellite，多个 Xwayland 抢同一个 :N，X 客户端握手永远超时。
#
# 可选 GPU 路径（XWAYLAND_GPU=1 且容器带 /data/local/tmp/vtest:/run/ds-gpu）：
#   走 zink → Venus(virtio ICD) → vtest → 宿主 virglrenderer → Mali。
#   历史上合成器 GL 已验证（Virtio-GPU Venus (Mali-G2-Ultra-NX MC16)），
#   Xwayland 这条路尚未验收，所以必须先用 eglinfo 探测成功才切换；失败自动
#   回退软件渲染，避免 Xwayland 直接 abort。
unset XWAYLAND_GBM_DEVICE

vts=${VTEST_SOCKET_NAME:-/run/ds-gpu/vtest.sock}
if [ "${XWAYLAND_GPU:-0}" = 1 ] && [ -S "$vts" ] && command -v eglinfo >/dev/null 2>&1; then
    if VTEST_SOCKET_NAME=$vts \
        VK_DRIVER_FILES=/usr/share/vulkan/icd.d/virtio_icd.json \
        VN_PERF=no_fence_feedback MESA_LOADER_DRIVER_OVERRIDE=zink \
        GALLIUM_DRIVER=zink EGL_PLATFORM=surfaceless \
        timeout 8 eglinfo -B 2>/dev/null | grep -qE "Venus|virgl"; then
        export VTEST_SOCKET_NAME=$vts
        export VK_DRIVER_FILES=/usr/share/vulkan/icd.d/virtio_icd.json
        export VN_PERF=no_fence_feedback
        export MESA_LOADER_DRIVER_OVERRIDE=zink GALLIUM_DRIVER=zink
        exec /usr/sbin/xwayland-satellite "$@"
    fi
fi

export MESA_LOADER_DRIVER_OVERRIDE=llvmpipe
export GALLIUM_DRIVER=llvmpipe
export LIBGL_ALWAYS_SOFTWARE=1
exec /usr/sbin/xwayland-satellite "$@"
