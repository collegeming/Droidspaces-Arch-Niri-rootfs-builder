# Dockerfile (Artix Linux OpenRC - aarch64, ARMtix port)
# 说明：
#   - Artix 官方主线仅提供 x86_64，aarch64 由 ARMtix 社区移植提供
#     (https://wiki.artixlinux.org/Main/Aarch64，镜像 https://armtixlinux.org)。
#   - 构建流程：先在 bootstrap 阶段下载并解压 ARMtix OpenRC rootfs，
#     再以它为基础安装 KDE 与 Droidspaces 相关组件。
#   - Artix 使用 OpenRC 而非 systemd：
#       * 不适用 scripts/systemd257.sh（无 systemd，天然无版本兼容问题）；
#       * Wayland/Anland patched KWin 暂不支持 Artix（仅 X11 / Termux:X11 路径）；
#       * plasma-mobile 暂不支持 Artix。
#   - 仓库签名：ARMtix 仓库当前未签名，pacman.conf 使用 SigLevel = Never。

ARG TARGETPLATFORM

#######################################################
# 阶段 0：下载并解压 ARMtix OpenRC rootfs（aarch64）
#######################################################
FROM ubuntu:24.04 AS bootstrap
RUN apt-get update && \
    apt-get install -y --no-install-recommends ca-certificates curl xz-utils && \
    rm -rf /var/lib/apt/lists/*
RUN mkdir -p /rootfs && \
    curl -fL --retry 5 --retry-delay 3 \
      "https://armtixlinux.org/images/armtix-openrc-20260124.tar.xz" -o /tmp/armtix.tar.xz && \
    echo "0dabdf9b2b1cfe16a1e5e0209884c650b8e12e2125488be557f152c3586924d9  /tmp/armtix.tar.xz" | sha256sum -c - && \
    tar -xJf /tmp/armtix.tar.xz -C /rootfs && \
    rm -f /tmp/armtix.tar.xz

# 将 ARMtix rootfs 固化为独立基础镜像层
FROM scratch AS armtix-base
COPY --from=bootstrap /rootfs/ /

#######################################################
# 阶段 1：自定义 rootfs
#######################################################
FROM armtix-base AS customizer

ARG BUILD_KDE
ARG BUILD_KDE_plus
ARG PulseAudio
ARG ENABLE_zh_tz_ARG
ARG ENABLE_binfmt_ARG
ARG ENABLE_yj_ARG
ARG ENABLE_mesa_ARG
ARG ENABLE_anland_kde_ARG
ARG ENABLE_8gen2_wayland_ARG
ARG ENABLE_kfgj_ARG
ARG ENABLE_zip_ARG
ARG ENABLE_docker_ARG
ARG ENABLE_srf_ARG
ARG ENABLE_tmoe_ARG
ARG ENABLE_systemd257_ARG
ARG ENABLE_nosnap_ARG
ARG USERNAME
ARG ANLAND_KDE_RELEASE_REPOSITORY=Goldzxcbug/Droidspaces-rootfs-KDE-builder
ARG ANLAND_KDE_RELEASE_TAG
ARG ANLAND_KDE_PACKAGE_REVISION=unknown
######################################################

COPY scripts/install-usb-manager.sh /usr/local/sbin/install-droidspaces-usb-manager
COPY scripts/binfmt/qemu-binfmt-register.sh /usr/local/bin/qemu-binfmt-register.sh

# Artix 限制检查：不支持 Wayland/Anland 与 mobile 模式
RUN if [ "$ENABLE_anland_kde_ARG" = "true" ]; then \
        echo "错误: Artix-KDE 当前不支持 Wayland/Anland（请选择 Debian-13/Ubuntu-26/Fedora-43/Fedora-44/Arch）" >&2; \
        exit 1; \
    fi && \
    if [ "$BUILD_KDE" = "mobile" ]; then \
        echo "错误: Artix-KDE 当前不支持 mobile 模式" >&2; \
        exit 1; \
    fi && \
    if [ "$ENABLE_systemd257_ARG" = "true" ]; then \
        echo "--> [跳过] Artix 使用 OpenRC，无 systemd，不适用 systemd 257 兼容构建"; \
    fi

# 配置 pacman：ARMtix 仓库（未签名，SigLevel = Never）
RUN cat <<'EOF' > /etc/pacman.conf
[options]
Architecture = aarch64
SigLevel = Never
NoProgressBar = True
ParallelDownloads = 5
# 保留 locale 数据以支持中文环境

[system]
Server = https://repo.armtixlinux.org/$repo/os/$arch
Server = https://armtix.artixlinux.org/repos/$repo/os/$arch

[world]
Server = https://repo.armtixlinux.org/$repo/os/$arch
Server = https://armtix.artixlinux.org/repos/$repo/os/$arch

[galaxy]
Server = https://repo.armtixlinux.org/$repo/os/$arch
Server = https://armtix.artixlinux.org/repos/$repo/os/$arch
EOF
RUN mkdir -p /var/lib/pacman/sync /etc/pacman.d && \
    pacman -Sy --noconfirm glibc pacman && \
    pacman -Su --noconfirm

# 移除 rootfs 镜像自带的内核/固件（容器内无用，节约 1GB+ 体积）
RUN pacman -Rdd --noconfirm \
        linux-aarch64 linux-aarch64-headers \
        linux-aarch64-lts linux-aarch64-lts-headers \
        linux-firmware \
        $(pacman -Qq 2>/dev/null | grep -E '^linux-firmware-' || true) \
        2>/dev/null || true; \
    rm -rf /boot/* /lib/modules/* /lib/firmware/* /usr/lib/modules/* /usr/lib/firmware/*; \
    pacman -S --noconfirm --needed \
    # 核心工具组件（OpenRC 体系：openrc/elogind/udev，不安装 systemd）
    bash jq dialog coreutils file findutils grep sed gawk curl wget ca-certificates bash-completion dbus elogind pam fastfetch logrotate \
    openrc udev dbus-openrc elogind-openrc \
    # 用户请求的基础开发/编辑工具
    git nano sudo \
    # 网络与 SSH 工具
    openssh openssh-openrc net-tools iptables iputils iproute2 bind \
    # 用于系统监控的 procps 进程工具
    procps-ng \
    # 核心内核模块支持
    kmod tzdata tar && \
    # 容器网络与硬件识别（可选）：NetworkManager 及其 OpenRC 服务
    if [ "$ENABLE_yj_ARG" = "true" ]; then \
        pacman -S --noconfirm --needed networkmanager networkmanager-openrc; \
    fi && \
    ############################################## KDE支持 ################################################
    # 最小化KDE
    if [ "$BUILD_KDE" = "min" ]; then \
        pacman -S --noconfirm --needed \
        xorg-xrandr noto-fonts-cjk noto-fonts-emoji plasma-desktop plasma-workspace pipewire pipewire-pulse wireplumber powerdevil kscreen plasma-pa ark kwin kwin-x11 upower konsole \
        dolphin kate kinfocenter mesa-utils libpulse vulkan-tools; \
    fi && \
    # 精简KDE
    if [ "$BUILD_KDE" = "conc" ]; then \
        pacman -S --noconfirm --needed \
        xorg-xrandr noto-fonts-cjk noto-fonts-emoji plasma-desktop plasma-workspace pipewire pipewire-pulse wireplumber powerdevil kscreen plasma-pa ark kwin kwin-x11 upower konsole \
        dolphin kate kinfocenter mesa-utils libpulse vulkan-tools aha clinfo dmidecode wayland-utils xorg-server \
        kfind plasma-systemmonitor filelight systemsettings kscreenlocker kio-extras xdg-user-dirs dolphin-plugins ffmpegthumbs kdegraphics-thumbnailers \
        kimageformats plasma-browser-integration libcanberra gstreamer gst-plugins-base gst-plugins-good sound-theme-freedesktop firefox; \
    fi && \
    # Artix 强制安装，但是这玩意不开硬件访问会导致桌面闪退
    if [ "$BUILD_KDE" = "conc" ] || [ "$BUILD_KDE" = "min" ] ; then \
        mv /usr/lib/xdg-desktop-portal /usr/lib/xdg-desktop-portal.bak 2>/dev/null || true; \
        mv /usr/lib/xdg-desktop-portal-kde /usr/lib/xdg-desktop-portal-kde.bak 2>/dev/null || true; \
    fi && \
    ######################################################################################################
    #输入法 fcitx5 (可选)
    if [ "$ENABLE_srf_ARG" = "true" ]; then \
        pacman -S --noconfirm --needed fcitx5 fcitx5-configtool fcitx5-gtk fcitx5-qt; \
    fi && \
    if [ "$ENABLE_srf_ARG" = "true" ] && [ "$ENABLE_zh_tz_ARG" = "true" ]; then \
        pacman -S --noconfirm --needed fcitx5-chinese-addons; \
    fi && \
    ## 开发工具集成 (可选)
    if [ "$ENABLE_kfgj_ARG" = "true" ]; then \
        pacman -S --noconfirm --needed \
        base-devel cmake clang llvm python python-pip; \
    fi && \
    ## 压缩工具扩展 (可选)
    if [ "$ENABLE_zip_ARG" = "true" ]; then \
        pacman -S --noconfirm --needed \
        zip unzip p7zip bzip2 xz tar gzip; \
    fi && \
    ## docker (可选)
    if [ "$ENABLE_docker_ARG" = "true" ]; then \
        pacman -S --noconfirm --needed \
        docker docker-compose; \
    fi && \
    ## 集成tmoe (可选)
    if [ "$ENABLE_tmoe_ARG" = "true" ]; then \
        git clone --depth=1 https://github.com/2moe/tmoe-linux.git /usr/local/etc/tmoe-linux/git && \
        ln -sf /usr/local/etc/tmoe-linux/git/debian.sh /usr/local/bin/tmoe && \
        chmod -R 755 /usr/local/etc/tmoe-linux; \
    fi

# 配置 Locale 与 SSH
RUN echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && \
    if [ "$ENABLE_zh_tz_ARG" = "true" ]; then \
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
        echo "zh_CN.UTF-8 UTF-8" >> /etc/locale.gen && \
        locale-gen && \
        echo "LANG=zh_CN.UTF-8" > /etc/locale.conf && \
        echo "LC_ALL=zh_CN.UTF-8" >> /etc/locale.conf; \
    else \
        locale-gen && \
        echo "LANG=en_US.UTF-8" > /etc/locale.conf && \
        echo "LC_ALL=en_US.UTF-8" >> /etc/locale.conf; \
    fi && \
    # 配置 SSH 服务（禁用 root 密码登录，但允许常规密码认证）
    mkdir -p /var/run/sshd && \
    ssh-keygen -A && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    # 清理 ARMtix 镜像默认用户，创建目标用户（默认密码 1234）
    userdel -r armtix 2>/dev/null || true && \
    echo "root:1234" | chpasswd && \
    useradd -m -s /bin/bash ${USERNAME} && echo "${USERNAME}:1234" | chpasswd

# 为所有 Artix RootFS 安装 Droidspaces USB Manager
RUN /usr/local/sbin/install-droidspaces-usb-manager --user "${USERNAME}"

# 添加环境变量
RUN cat <<'EOF' > /etc/environment
XCURSOR_SIZE=48
EOF
RUN echo 'DISPLAY=:5' >> /etc/environment
# 音频选择
RUN if [ "$PulseAudio" = "socket" ]; then \
        echo "PULSE_SERVER=unix:/tmp/.pulse-socket" >> /etc/environment; \
    elif [ "$PulseAudio" = "tcp" ]; then \
        echo "PULSE_SERVER=tcp:127.0.0.1:4713" >> /etc/environment; \
    fi

RUN if [ "$ENABLE_8gen2_wayland_ARG" = "true" ]; then \
        echo 'FD_DEV_FEATURES=enable_tp_ubwc_flag_hint=1' >> /etc/environment; \
    fi

# 输入法与 Mesa 相关环境变量
RUN <<'EOF_RUN'
    if [ "$ENABLE_srf_ARG" = "true" ]; then
    mkdir -p /home/${USERNAME}/.config/autostart
    cat <<'EOF' > /home/${USERNAME}/.config/autostart/fcitx5.desktop
[Desktop Entry]
Name=Fcitx5
GenericName=Input Method
Comment=Start Input Method
Exec=fcitx5 -d
Icon=fcitx
Terminal=false
Type=Application
Categories=System;Utility;
StartupNotify=false
NoDisplay=true
EOF
    cat <<'EOF' >> /etc/environment
XMODIFIERS=@im=fcitx5
GTK_IM_MODULE=fcitx5
QT_IM_MODULE=fcitx5
SDL_IM_MODULE=fcitx5
GLFW_IM_MODULE=fcitx
EOF
fi
    if [ "$ENABLE_mesa_ARG" = "true" ]; then
        cat <<'EOF' >> /etc/environment
MESA_LOADER_DRIVER_OVERRIDE=kgsl
TU_DEBUG=noconform
EOF
    fi
    echo 'export XDG_RUNTIME_DIR=/run/user/$(id -u)' >> /home/${USERNAME}/.bashrc
    if { [ "$BUILD_KDE" = "min" ] || [ "$BUILD_KDE" = "conc" ]; } ; then
    mkdir -p /home/${USERNAME}/.config
    cat <<'EOF' > /home/${USERNAME}/.config/kwinrc
[Compositing]
Enabled=false
EOF
    fi
    chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}
EOF_RUN

# KDE 开机自启动（OpenRC 服务，等价于 systemd 的 plasma-x11.service）
RUN <<'EOF_RUN'
    if [ "$BUILD_KDE_plus" = "true" ] && { [ "$BUILD_KDE" = "min" ] || [ "$BUILD_KDE" = "conc" ]; } ; then
    cat <<'EOF' > /usr/local/bin/droidspaces-plasma-x11
#!/bin/bash
# 加载 /etc/environment 后以当前用户启动 Plasma X11 会话
set -a
. /etc/environment 2>/dev/null || true
set +a
export XDG_RUNTIME_DIR="/run/user/$(id -u)"
mkdir -p "$XDG_RUNTIME_DIR" 2>/dev/null || true
chmod 700 "$XDG_RUNTIME_DIR" 2>/dev/null || true
exec /usr/bin/startplasma-x11
EOF
    chmod 755 /usr/local/bin/droidspaces-plasma-x11
    cat <<'EOF' > /etc/init.d/plasma-x11
#!/sbin/openrc-run

description="Droidspaces Plasma X11 desktop session"
supervisor=supervise-daemon
command=/usr/local/bin/droidspaces-plasma-x11
command_user="__DS_USER__"
output_log="/var/log/plasma-x11.log"
error_log="/var/log/plasma-x11.log"

depend() {
    after local sshd dbus elogind
}
EOF
    sed -i "s/__DS_USER__/${USERNAME}/" /etc/init.d/plasma-x11
    chmod 755 /etc/init.d/plasma-x11
    # OpenRC 在 Docker 构建阶段无法运行 rc-update，手动创建 runlevel 符号链接
    mkdir -p /etc/runlevels/default
    ln -sf /etc/init.d/plasma-x11 /etc/runlevels/default/plasma-x11
    fi
EOF_RUN

# 下载并安装 Mesa（高通 GPU，archlinux_arm64 包与 ARMtix 兼容）
RUN if [ "$ENABLE_mesa_ARG" = "true" ]; then \
        echo "--> [开启] 正在下载并安装最新版 Mesa 驱动..." && \
        URL=$(curl -s https://api.github.com/repos/lfdevs/mesa-for-android-container/releases/latest | \
        jq -r '.assets[] | select(.name | test("mesa-for-android-container_.*_archlinux_arm64\\.tar")) | .browser_download_url' | head -1) && \
        if [ -z "$URL" ] || [ "$URL" = "null" ]; then echo "获取下载链接失败，可能是触发了 GitHub API 速率限制"; exit 1; fi && \
        wget -q --tries=5 --waitretry=3 -O /tmp/mesa.tar "$URL" && \
        tar -xf /tmp/mesa.tar -C /tmp && \
        pacman -U --noconfirm /tmp/*.pkg.tar.* && \
        rm -f /tmp/mesa.tar /tmp/*.pkg.tar.* /tmp/*.sig ; \
    else \
        echo "--> [跳过] 未开启 Mesa 驱动安装"; \
    fi

# 应用 Android 运行环境兼容性修复（OpenRC 体系）
RUN <<'EOF_RUN'
# --- 1. 常规兼容性修复 ---
# 建立 Android 网络权限组
grep -q '^aid_inet:' /etc/group     || echo 'aid_inet:x:3003:'    >> /etc/group
grep -q '^aid_net_raw:' /etc/group || echo 'aid_net_raw:x:3004:' >> /etc/group
grep -q '^aid_net_admin:' /etc/group || echo 'aid_net_admin:x:3005:' >> /etc/group

# 检查并创建 droidspaces-gpu 组
getent group droidspaces-gpu >/dev/null || groupadd -g 786 -r droidspaces-gpu
# 为 root 用户赋予访问 Android 硬件及网络的权限组
usermod -a -G aid_inet,aid_net_raw,input,video,tty,droidspaces-gpu root || true
usermod -a -G aid_inet,aid_net_raw,input,video,tty,wheel,droidspaces-gpu ${USERNAME} || true

# 赋予 wheel 组 sudo 权限
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# --- 2. OpenRC 容器环境适配 ---
# 告知 OpenRC 处于 LXC 风格容器，抑制 hwdrivers/machine-id 对 /dev 的依赖告警
if [ -f /etc/rc.conf ]; then
    sed -i 's/^#\?rc_sys=.*/rc_sys="lxc"/' /etc/rc.conf
fi

# --- 3. 容器网络与硬件识别（enable_yj） ---
# dbus 与 elogind 是桌面会话必需组件，始终启用；
# NetworkManager 提供容器网络（NAT 模式）与硬件识别，未启用时移除
# 同时清理镜像默认 runlevel：容器内无 tty1-6 虚拟终端，
# dhcpcd/netmount 与 NetworkManager 冲突
mkdir -p /etc/runlevels/default /etc/runlevels/sysinit /etc/runlevels/boot
rm -f /etc/runlevels/default/agetty.tty* /etc/runlevels/default/dhcpcd /etc/runlevels/default/netmount 2>/dev/null || true
ln -sf /etc/init.d/dbus /etc/runlevels/default/dbus
ln -sf /etc/init.d/sshd /etc/runlevels/default/sshd
if [ "$ENABLE_yj_ARG" = "true" ]; then
    ln -sf /etc/init.d/NetworkManager /etc/runlevels/default/NetworkManager
else
    rm -f /etc/init.d/NetworkManager 2>/dev/null || true
fi

# --- 4. udev OpenRC 服务（覆写为带 Droidspaces 硬件访问门控的版本） ---
# 镜像 sysinit 已包含 udev/udev-trigger；本服务的 start_post 已自带
# 定向 trigger+settle，故移除独立的 udev-trigger 链接避免重复触发
cat <<'EOF' > /etc/init.d/udev
#!/sbin/openrc-run

description="Device event managing daemon for Droidspaces"
command="/usr/bin/udevd"
command_args="--daemon"
pidfile="/run/udev.pid"

depend() {
    need sysfs
}

start_pre() {
    # 仅在 Droidspaces 开启硬件访问时启动 udev
    if ! grep -q 'enable_hw_access=1' /run/droidspaces/container.config 2>/dev/null; then
        einfo "Skipping udev: hardware access disabled"
        return 1
    fi
    checkpath -d -m 0755 /run/udev
}

start_post() {
    # 只触发容器内可见的设备子系统，避免无意义的全量扫描
    udevadm trigger --subsystem-match=usb --subsystem-match=block \
        --subsystem-match=input --subsystem-match=tty --subsystem-match=net || true
    udevadm settle || true
}
EOF
chmod 755 /etc/init.d/udev
rm -f /etc/runlevels/sysinit/udev-trigger 2>/dev/null || true
if [ "$ENABLE_yj_ARG" = "true" ]; then
    ln -sf /etc/init.d/udev /etc/runlevels/sysinit/udev
else
    rm -f /etc/init.d/udev /etc/runlevels/sysinit/udev 2>/dev/null || true
fi

# --- 5. NetworkManager 容器网络模式限制 ---
# 仅在 NAT/Gateway 网络模式下启动，防止误碰 Android 宿主网络接口
if [ -f /etc/init.d/NetworkManager ]; then
cat <<'EOF' > /etc/init.d/NetworkManager
#!/sbin/openrc-run

description="Network Manager for Droidspaces"

command="/usr/bin/NetworkManager"
command_args="--no-daemon"
command_background="true"
pidfile="/run/NetworkManager/NetworkManager.pid"

depend() {
    need dbus
    provide net
}

start_pre() {
    if ! grep -qE 'net_mode=(nat|gateway)' /run/droidspaces/container.config 2>/dev/null; then
        einfo "Skipping NetworkManager: not in NAT network mode"
        return 1
    fi
    checkpath -d -m 0755 /run/NetworkManager
}
EOF
chmod 755 /etc/init.d/NetworkManager
fi

# --- 6. 日志轮转调优 ---
if [ -f /etc/logrotate.conf ]; then
    sed -i 's/^#maxsize.*/maxsize 50M/' /etc/logrotate.conf
    if ! grep -q "maxsize 50M" /etc/logrotate.conf; then
        echo "maxsize 50M" >> /etc/logrotate.conf
    fi
fi

echo "Post-extraction fixes applied on $(date)" > /etc/droidspaces
EOF_RUN

# 注入 binfmt 跨架构支持（OpenRC 服务版本）
RUN <<'EOF_RUN'
cat <<'EOF' > /etc/init.d/qemu-binfmt-register
#!/sbin/openrc-run

description="Register QEMU binfmt handlers for cross-architecture support"
command="/usr/local/bin/qemu-binfmt-register.sh"

depend() {
    after local
}
EOF
chmod 755 /etc/init.d/qemu-binfmt-register
if [ "$ENABLE_binfmt_ARG" = "true" ]; then
    chmod +x /usr/local/bin/qemu-binfmt-register.sh
    chmod 755 /etc/init.d/qemu-binfmt-register
    mkdir -p /etc/runlevels/default
    ln -sf /etc/init.d/qemu-binfmt-register /etc/runlevels/default/qemu-binfmt-register
    pacman -S --noconfirm --needed qemu-user qemu-user-binfmt
else
    rm -f /usr/local/bin/qemu-binfmt-register.sh /etc/init.d/qemu-binfmt-register
fi
EOF_RUN

# 彻底清理 pacman 缓存
RUN rm -rf /var/cache/pacman/pkg/* /var/lib/pacman/sync/*
# 阶段 2：将完整的根文件系统导出到 scratch（空白层），以便外部直接提取或打包成 tarfs
FROM scratch AS export
COPY --from=customizer / /
