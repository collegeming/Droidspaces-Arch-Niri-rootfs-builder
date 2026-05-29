ARG TARGETPLATFORM
FROM fedora:43 AS customizer

#######################################################
ARG BUILD_KDE
ARG PulseAudio
ARG ENABLE_zh_tz_ARG
ARG ENABLE_binfmt_ARG
ARG ENABLE_yj_ARG
ARG ENABLE_mesa_ARG
ARG ENABLE_kfgj_ARG
ARG ENABLE_zip_ARG
ARG ENABLE_docker_ARG
ARG ENABLE_srf_ARG
ARG ENABLE_tmoe_ARG
######################################################

ENV DEBIAN_FRONTEND=noninteractive

RUN dnf -y install --setopt=install_weak_deps=False \
    # 核心工具组件
    bash jq dialog coreutils file findutils grep sed gawk curl wget ca-certificates \
    glibc-langpack-en bash-completion udev dbus systemd systemd-resolved fastfetch \
    # 用户请求的基础开发/编辑工具
    git nano sudo \
    # 网络与 SSH 工具
    openssh-server net-tools iptables-legacy iputils iproute bind-utils \
    # 用于系统监控的 procps 进程工具
    procps-ng \
    # 核心内核模块支持
    kmod tzdata && \
    ############################################## KDE支持 ################################################
    # 最小化KDE
    if [ "$BUILD_KDE" = "min" ]; then \
        dnf -y install --setopt=install_weak_deps=False \
        dbus-x11 xorg-x11-server-Xorg xorg-x11-xauth xrandr xset xprop \
        plasma-desktop plasma-workspace plasma-workspace-x11 kwin-x11 \
        fonts-noto-cjk fonts-noto-color-emoji \
        pipewire pipewire-pulseaudio wireplumber powerdevil kscreen plasma-pa \
        ark konsole dolphin kate kinfocenter \
        mesa-demos pulseaudio-utils vulkan-tools desktop-backgrounds-kde; \
    fi && \
    # 精简KDE
    if [ "$BUILD_KDE" = "conc" ]; then \
        dnf -y install --setopt=install_weak_deps=False \
        dbus-x11 xorg-x11-server-Xorg xorg-x11-xauth xrandr xset xprop \
        plasma-desktop plasma-workspace plasma-workspace-x11 kwin-x11 \
        fonts-noto-cjk fonts-noto-color-emoji \
        pipewire pipewire-pulseaudio wireplumber powerdevil kscreen plasma-pa \
        ark konsole dolphin kate kinfocenter \
        mesa-demos pulseaudio-utils vulkan-tools desktop-backgrounds-kde \
        aha clinfo dmidecode libdisplay-info-tools pciutils wayland-utils \
        kfind plasma-systemmonitor filelight glmark2 vkmark \
        plasma-systemsettings kscreenlocker kio-extras xdg-user-dirs \
        dolphin-plugins ffmpegthumbnailer kimageformats plasma-browser-integration \
        libcanberra gstreamer1-plugins-base gstreamer1-plugins-good \
        sound-theme-freedesktop chromium chromium-l10n; \
    fi && \
    ######################################################################################################
    #输入法 fcitx5 (可选)
    if [ "$ENABLE_srf_ARG" = "true" ]; then \
        dnf -y install --setopt=install_weak_deps=False fcitx5; \
    fi && \
    if [ "$ENABLE_srf_ARG" = "true" ] && [ "$ENABLE_zh_tz_ARG" = "true" ]; then \
        dnf -y install --setopt=install_weak_deps=False fcitx5-chinese-addons; \
    fi && \
    ## 开发工具集成 (可选)
    if [ "$ENABLE_kfgj_ARG" = "true" ]; then \
        dnf -y install --setopt=install_weak_deps=False \
        gcc gcc-c++ make cmake autoconf automake libtool pkgconf-pkg-config \
        clang llvm python3 python3-pip python3-devel python3-virtualenv \
        python-unversioned-command; \
    fi && \
    ## 压缩工具扩展 (可选)
    if [ "$ENABLE_zip_ARG" = "true" ]; then \
        dnf -y install --setopt=install_weak_deps=False \
        zip unzip p7zip p7zip-plugins bzip2 xz tar gzip; \
    fi && \
    ## docker (可选)
    if [ "$ENABLE_docker_ARG" = "true" ]; then \
        dnf -y install --setopt=install_weak_deps=False \
        moby-engine docker-cli docker-compose; \
    fi && \
    ## 集成tmoe (可选)
    if [ "$ENABLE_tmoe_ARG" = "true" ]; then \
        git clone --depth=1 https://github.com/2moe/tmoe-linux.git /usr/local/etc/tmoe-linux/git && \
        ln -sf /usr/local/etc/tmoe-linux/git/debian.sh /usr/local/bin/tmoe && \
        chmod -R 755 /usr/local/etc/tmoe-linux; \
    fi && \
    dnf -y clean all && \
    rm -rf /var/cache/dnf

# 强制配置使用 iptables-legacy（这是兼容 Android 内核的硬性要求）
RUN alternatives --set iptables /usr/sbin/iptables-legacy || true && \
    alternatives --set ip6tables /usr/sbin/ip6tables-legacy || true

RUN if [ "$ENABLE_zh_tz_ARG" = "true" ]; then \
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
        echo "Asia/Shanghai" > /etc/timezone && \
        dnf -y install --setopt=install_weak_deps=False glibc-langpack-zh && \
        cat > /etc/locale.conf <<'EOF'; \
LANG=zh_CN.UTF-8
LC_ALL=zh_CN.UTF-8
EOF \
    ; else \
        cat > /etc/locale.conf <<'EOF'; \
LANG=en_US.UTF-8
LC_ALL=en_US.UTF-8
EOF \
    ; fi && \
    # 配置 SSH 服务（禁用 root 密码登录，但允许常规密码认证）
    mkdir -p /var/run/sshd && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    # 如果容器内存在默认的 fedora 用户，则将其连同家目录一起删除
    userdel -r fedora 2>/dev/null || true && \
    useradd -m -s /bin/bash Gold && echo "Gold:1234" | chpasswd

# 添加环境变量
RUN cat <<'EOF' > /etc/environment
MESA_LOADER_DRIVER_OVERRIDE=kgsl
TU_DEBUG=noconform
XCURSOR_SIZE=48
XMODIFIERS=@im=fcitx5
GTK_IM_MODULE=fcitx5
QT_IM_MODULE=fcitx5
SDL_IM_MODULE=fcitx5
GLFW_IM_MODULE=fcitx
DISPLAY=:1
EOF

# 音频选择
RUN if [ "$PulseAudio" = "socket" ]; then \
        echo "PULSE_SERVER=unix:/tmp/.pulse-socket" >> /etc/environment; \
    elif [ "$PulseAudio" = "tcp" ]; then \
        echo "PULSE_SERVER=tcp:127.0.0.1:4713" >> /etc/environment; \
    fi

# 输入法开机自启动
RUN <<'EOF_RUN'
    if [ "$ENABLE_srf_ARG" = "true" ]; then
    mkdir -p /home/Gold/.config/autostart
    cat <<'EOF' > /home/Gold/.config/autostart/fcitx5.desktop
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
fi
    echo 'export XDG_RUNTIME_DIR=/run/user/$(id -u)' >> /home/Gold/.bashrc
    if [ "$BUILD_KDE" = "min" ] || [ "$BUILD_KDE" = "conc" ] ; then
    mkdir -p /home/Gold/.config
    cat <<'EOF' > /home/Gold/.config/kwinrc
[Compositing]
Enabled=false
EOF
    fi
    chown -R Gold:Gold /home/Gold
EOF_RUN

RUN if [ "$ENABLE_mesa_ARG" = "true" ]; then \
        echo "--> [开启] 正在下载并安装最新版 Mesa 驱动..." && \
        URL=$(curl -s https://api.github.com/repos/lfdevs/mesa-for-android-container/releases/latest | \
        jq -r '.assets[] | select(.name | test("mesa-for-android-container_.*_fedora_43_arm64\\.tar\\.gz")) | .browser_download_url' | head -1) && \
        if [ -z "$URL" ] || [ "$URL" = "null" ]; then echo "获取下载链接失败，可能是触发了 GitHub API 速率限制"; exit 1; fi && \
        wget -q --tries=5 --waitretry=3 -O /tmp/mesa.tar.gz "$URL" && \
        tar -zxf /tmp/mesa.tar.gz -C / && \
        rm /tmp/mesa.tar.gz && \
        ldconfig; \
    else \
        echo "--> [跳过] 未开启 Mesa 驱动安装"; \
    fi

# 修复容器内的 DHCP 网络服务配置
RUN mkdir -p /etc/systemd/network && \
    cat <<'EOF' > /etc/systemd/network/10-eth-dhcp.network
[Match]
Name=eth*

[Network]
DHCP=yes
IPv6AcceptRA=yes

[DHCPv4]
UseDNS=yes
UseDomains=yes
RouteMetric=100
EOF

# 应用 Android 运行环境兼容性修复（重点针对 Systemd 和 Udev）
RUN <<'EOF_RUN'

# --- 1. 常规兼容性修复 ---
# 建立 Android 网络权限组（在 Android 内核上运行 Linux 容器时，必须有这些 GID 才能正常访问网络 socket）
grep -q '^aid_inet:' /etc/group     || echo 'aid_inet:x:3003:'    >> /etc/group
grep -q '^aid_net_raw:' /etc/group || echo 'aid_net_raw:x:3004:' >> /etc/group
grep -q '^aid_net_admin:' /etc/group || echo 'aid_net_admin:x:3005:' >> /etc/group

# 检查并创建 droidspaces-gpu 组
getent group droidspaces-gpu >/dev/null || groupadd -g 786 -r droidspaces-gpu
# 为 root 用户赋予访问 Android 硬件及网络的权限组
usermod -a -G aid_inet,aid_net_raw,input,video,tty,droidspaces-gpu root || true
usermod -a -G aid_inet,aid_net_raw,input,video,tty,sudo,droidspaces-gpu Gold || true

# 确保未来通过 adduser 创建的所有新用户，都会被默认加入这些 Android 硬件与网络组
if [ -f /etc/adduser.conf ]; then
    sed -i '/^EXTRA_GROUPS=/d; /^ADD_EXTRA_GROUPS=/d' /etc/adduser.conf
    echo 'ADD_EXTRA_GROUPS=1' >> /etc/adduser.conf
    echo 'EXTRA_GROUPS="aid_inet aid_net_raw input video tty"' >> /etc/adduser.conf
fi

# --- 2. 针对 Systemd 的特定修复 ---
# 屏蔽在 Android 内核下容易引发报错或死锁的阻塞服务
ln -sf /dev/null /etc/systemd/system/systemd-networkd-wait-online.service
ln -sf /dev/null /etc/systemd/system/systemd-journald-audit.socket

# 优化 Journald 日志配置（跳过内核审计、KMsg 等 Android 内核不兼容或权限受限的日志源）
cat >> /etc/systemd/journald.conf << 'EOT'
[Journal]
ReadKMsg=no
Audit=no
Storage=volatile
EOT

mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/ds-logging.conf << 'EOT'
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=200M
MaxRetentionSec=7day
MaxLevelStore=info
EOT

mkdir -p /etc/systemd/system/multi-user.target.wants
GUEST_SYSTEMD_PATH="/usr/lib/systemd/system"

if [ -f "$GUEST_SYSTEMD_PATH/dbus.service" ]; then
    ln -sf "$GUEST_SYSTEMD_PATH/dbus.service" "/etc/systemd/system/multi-user.target.wants/dbus.service"
fi

if [ "$ENABLE_yj_ARG" = "true" ]; then
    for service in systemd-udevd.service systemd-resolved.service systemd-networkd.service NetworkManager.service; do
        if [ -f "$GUEST_SYSTEMD_PATH/$service" ]; then
            ln -sf "$GUEST_SYSTEMD_PATH/$service" "/etc/systemd/system/multi-user.target.wants/$service"
        fi
    done
else
    for service in systemd-udevd.service systemd-resolved.service systemd-networkd.service NetworkManager.service; do
        ln -sf /dev/null "/etc/systemd/system/$service"
    done
fi

# 在 systemd-logind 中禁用电源键行为处理（防止容器误拦截或处理宿主机的实体电源按键事件）
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/99-power-key.conf << 'EOF'
[Login]
HandlePowerKey=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandlePowerKeyLongPress=ignore
HandlePowerKeyLongPressHibernate=ignore
EOF

# 应用 udev 覆盖配置
# 1. 触发器覆盖：限制 udevadm trigger 的扫描范围（防止冷插拔时全面扫描 Android 宿主机硬件导致卡死或冲突）
mkdir -p /etc/systemd/system/systemd-udev-trigger.service.d
cat > /etc/systemd/system/systemd-udev-trigger.service.d/override.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/usr/bin/udevadm trigger --subsystem-match=usb --subsystem-match=block --subsystem-match=input --subsystem-match=tty --subsystem-match=net
EOF

# 2. 针对只读文件系统路径（ConditionPathIsReadWrite）的覆盖，防止 udev 相关服务因为路径只读而报错中断
for unit in systemd-udevd.service systemd-udev-trigger.service systemd-udev-settle.service systemd-udevd-kernel.socket systemd-udevd-control.socket; do
    mkdir -p "/etc/systemd/system/${unit}.d"
    printf "[Unit]\nConditionPathIsReadWrite=\n" > "/etc/systemd/system/${unit}.d/99-readonly-fix.conf"
done

# 限制特定的网络服务：只有当容器配置为 NAT 模式时才允许启动
# 这可以有效防止容器在“主机网络模式（Host Mode）”下运行时破坏手机原本的蜂窝移动数据网络
for unit in NetworkManager.service dhcpcd.service systemd-resolved.service systemd-networkd.service; do
    if [ -f "$GUEST_SYSTEMD_PATH/$unit" ] || [ -f "/etc/systemd/system/multi-user.target.wants/$unit" ]; then
        mkdir -p "/etc/systemd/system/${unit}.d"
        cat > "/etc/systemd/system/${unit}.d/99-netmode-limit.conf" << 'EOF'
[Service]
ExecCondition=
ExecCondition=/bin/sh -c "grep -q 'net_mode=nat' /run/droidspaces/container.config"
EOF
    fi
done
# 仅在启用硬件访问时限制 udev 服务启动
for unit in systemd-udevd.service systemd-udev-trigger.service systemd-udev-settle.service; do
    if [ -f "$GUEST_SYSTEMD_PATH/$unit" ] || [ -f "/etc/systemd/system/multi-user.target.wants/$unit" ]; then
        mkdir -p "/etc/systemd/system/${unit}.d"
        cat > "/etc/systemd/system/${unit}.d/99-hwaccess-limit.conf" << 'EOF'
[Service]
ExecCondition=
ExecCondition=/bin/sh -c "grep -q 'enable_hw_access=1' /run/droidspaces/container.config"
EOF
    fi
done

# 针对 Android 环境微调日志轮转（logrotate）的最大容量限制
if [ -f /etc/logrotate.conf ]; then
    sed -i 's/^#maxsize.*/maxsize 50M/' /etc/logrotate.conf
    if ! grep -q "maxsize 50M" /etc/logrotate.conf; then
        echo "maxsize 50M" >> /etc/logrotate.conf
    fi
fi

# 写入修复完成的标记和时间戳
echo "Post-extraction fixes applied on $(date)" > /etc/droidspaces
EOF_RUN

COPY scripts/binfmt/qemu-binfmt-register.sh /usr/local/bin/
COPY scripts/binfmt/qemu-binfmt-register.service /etc/systemd/system/
RUN if [ "$ENABLE_binfmt_ARG" = "false" ]; then \
        rm -rf /usr/local/bin/qemu-binfmt-register.sh && \
        rm -rf /etc/systemd/system/qemu-binfmt-register.service ; \
    fi

RUN if [ "$ENABLE_binfmt_ARG" = "true" ]; then \
        chmod +x /usr/local/bin/qemu-binfmt-register.sh && \
        chmod 644 /etc/systemd/system/qemu-binfmt-register.service && \
        mkdir -p /etc/systemd/system/multi-user.target.wants && \
        ln -sf /etc/systemd/system/qemu-binfmt-register.service /etc/systemd/system/multi-user.target.wants/qemu-binfmt-register.service && \
        (dnf -y remove 'qemu-*' binfmt-support || true) && \
        dnf -y install --setopt=install_weak_deps=False qemu-user-static qemu-user-binfmt && \
        dnf -y clean all && \
        rm -rf /var/cache/dnf && \
        # 显式添加 amd64 异构架构支持
        true; \
    else \
        rm -f /usr/local/bin/qemu-binfmt-register.sh /etc/systemd/system/qemu-binfmt-register.service; \
    fi

# 最终清理包管理器缓存，尽可能缩减镜像层体积
RUN dnf -y clean all && \
    rm -rf /var/cache/dnf

# 阶段 2：将完整的根文件系统导出到 scratch（空白层），以便外部直接提取或打包成 tarfs
FROM scratch AS export

# 从 customizer 编译阶段将所有定制好的根文件系统内容整体拷贝出来
COPY --from=customizer / /
