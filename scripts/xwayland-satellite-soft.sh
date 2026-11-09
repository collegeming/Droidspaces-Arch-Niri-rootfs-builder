#!/bin/sh
# 由镜像提供：niri 通过 xwayland-satellite 拉起 Xwayland 时使用软件渲染。
#
# 背景：容器里只有 /dev/dri/card0（无 renderD128）。不设 XWAYLAND_GBM_DEVICE 时
# Xwayland 会报 "No usable linux-dmabuf main device" 并回落到 swrast，工作正常；
# 一旦按会话环境走 card0 + zink/MaliBridge，glamor 初始化会崩溃
# （Xwayland SIGSEGV，日志里 "Caught signal 11"），随后 niri 反复重启 satellite，
# 产生多个抢同一个 :N 的 Xwayland，X 客户端连接后永远等不到握手。
#
# X11 兼容层不参与零拷贝验收，用 llvmpipe 即可稳定渲染；Wayland 应用仍走 GPU。
# niri 配置通过 `xwayland-satellite { path "/usr/local/bin/xwayland-satellite-soft" }`
# 指向本脚本，参数（-listenfd 等）原样透传。
unset XWAYLAND_GBM_DEVICE
export MESA_LOADER_DRIVER_OVERRIDE=llvmpipe
export GALLIUM_DRIVER=llvmpipe
export LIBGL_ALWAYS_SOFTWARE=1
exec /usr/sbin/xwayland-satellite "$@"
