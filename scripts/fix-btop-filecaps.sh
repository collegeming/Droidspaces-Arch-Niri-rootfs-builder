#!/bin/sh
# btop 的 Arch 包带文件能力 cap_dac_read_search,cap_perfmon=ep。Droidspaces
# 容器的 capability bounding set 不含 cap_dac_read_search，execve 会直接返回
# EPERM（表现为 fish/kitty 报 “No permission … or you lack capabilities”，
# root 也一样）。btop 去掉这两个能力后仍可正常显示 CPU/内存/磁盘/网络，
# 因此在 pacman 安装/升级后自动剥离。
[ -x /usr/bin/btop ] || exit 0
command -v setcap >/dev/null 2>&1 || exit 0
setcap -r /usr/bin/btop 2>/dev/null || true
exit 0
