ARG TARGETPLATFORM
FROM debian:trixie AS customizer

ENV DEBIAN_FRONTEND=noninteractive

# 更新基础系统并启用 non-free（非自由）和 contrib 软件源
RUN (sed -i 's/main/main contrib non-free/g' /etc/apt/sources.list 2>/dev/null || sed -i 's/Components: main/Components: main contrib non-free/g' /etc/apt/sources.list.d/debian.sources) && \
    apt-get update && \
    apt-get upgrade -y

# 优先复制自定义脚本
COPY scripts/download-firmware /usr/local/bin/

# 将自定义的 bashrc 脚本复制到根文件系统的 profile 目录
COPY scripts/bashrc.sh /etc/profile.d/ds-aliases.sh

# 赋予相关脚本可执行权限
RUN chmod +x /usr/local/bin/download-firmware /etc/profile.d/ds-aliases.sh

# 安装精简版基础软件包
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    # 核心工具组件
    bash \
    jq \
    dialog \
    coreutils \
    file \
    findutils \
    grep \
    sed \
    gawk \
    curl \
    wget \
    ca-certificates \
    locales \
    bash-completion \
    udev \
    dbus \
    systemd-sysv \
    systemd-resolved \
    # 用户请求的基础开发/编辑工具
    git \
    nano \
    sudo \
    # 网络与 SSH 工具
    openssh-server \
    net-tools \
    iptables \
    iputils-ping \
    iproute2 \
    dnsutils \
    # 用于系统监控的 procps 进程工具
    procps \
    # 核心内核模块支持
    kmod \
    # 最小化KDE支持
    dbus-x11 \
    x11-xserver-utils \
    fonts-noto-cjk \
    fonts-noto-color-emoji\
    kde-plasma-desktop \
    konsole \
    dolphin \
    kate \
    && apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# 强制配置使用 iptables-legacy（这是兼容 Android 内核的硬性要求）
RUN update-alternatives --set iptables /usr/sbin/iptables-legacy && \
    update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy

# 配置语言环境、环境变量、SSH 安全设置以及默认用户清理
RUN sed -i '/en_US.UTF-8/s/^# //' /etc/locale.gen && \
    sed -i '/zh_CN.UTF-8/s/^# //' /etc/locale.gen && \
    locale-gen && \
    update-locale LANG=zh_CN.UTF-8 LC_ALL=zh_CN.UTF-8 && \
    # 配置 SSH 服务（禁用 root 密码登录，但允许常规密码认证）
    mkdir -p /var/run/sshd && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    # 如果容器内存在默认的 debian 用户，则将其连同家目录一起删除
    deluser --remove-home debian || true && \
    useradd -m -s /bin/bash Gold && echo "Gold:1234" | chpasswd

# 添加环境变量
RUN cat <<'EOF' > /etc/environment
MESA_LOADER_DRIVER_OVERRIDE=freedreno
XCURSOR_SIZE=48
XMODIFIERS=@im=fcitx5
GTK_IM_MODULE=fcitx5
QT_IM_MODULE=fcitx5
SDL_IM_MODULE=fcitx5
GLFW_IM_MODULE=fcitx
PULSE_SERVER=tcp:127.0.0.1:4713
DISPLAY=:1
EOF

RUN echo 'export XDG_RUNTIME_DIR=/run/user/$(id -u)' >> /home/Gold/.bashrc
RUN mkdir -p /home/Gold/.config && \
    cat <<'EOF' > /home/Gold/.config/kwinrc
[Compositing]
Enabled=false
EOF
RUN chown -R Gold:Gold /home/Gold

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

# 安装最新版mesa驱动
RUN curl -s https://api.github.com/repos/lfdevs/mesa-for-android-container/releases/latest | \
    jq -r '.assets[] | select(.name | test("mesa-for-android-container_.*_debian_trixie_arm64\\.tar\\.gz")) | .browser_download_url' | \
    head -1 | xargs wget -O /tmp/mesa.tar.gz && \
    tar -zxf /tmp/mesa.tar.gz -C / && \
    rm /tmp/mesa.tar.gz && \
    ldconfig

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
RUN <<EOF_RUN

# --- 1. 常规兼容性修复 ---
# 建立 Android 网络权限组（在 Android 内核上运行 Linux 容器时，必须有这些 GID 才能正常访问网络 socket）
grep -q '^aid_inet:' /etc/group     || echo 'aid_inet:x:3003:'    >> /etc/group
grep -q '^aid_net_raw:' /etc/group || echo 'aid_net_raw:x:3004:' >> /etc/group
grep -q '^aid_net_admin:' /etc/group || echo 'aid_net_admin:x:3005:' >> /etc/group

# 检查并创建 droidspaces-gpu 组
getent group droidspaces-gpu >/dev/null || groupadd -r droidspaces-gpu
# 为 root 用户赋予访问 Android 硬件及网络的权限组
usermod -a -G aid_inet,aid_net_raw,input,video,tty,droidspaces-gpu root || true
usermod -a -G aid_inet,aid_net_raw,input,video,tty,sudo,droidspaces-gpu Gold || true

# 将 _apt 的主用户组改为 aid_inet，确保 apt 包管理器在 Android 环境下可以正常联网
grep -q '^_apt:' /etc/passwd && usermod -g aid_inet _apt || true

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

# 启用容器所需的核心系统服务(可选)
mkdir -p /etc/systemd/system/multi-user.target.wants
GUEST_SYSTEMD_PATH="/lib/systemd/system"
# for service in dbus.service systemd-udevd.service systemd-resolved.service systemd-networkd.service NetworkManager.service; do
#     if [ -f "$GUEST_SYSTEMD_PATH/$service" ]; then
#         ln -sf "$GUEST_SYSTEMD_PATH/$service" "/etc/systemd/system/multi-user.target.wants/$service"
#     fi
# done

# 禁用容器硬件刷新，防止容器接管安卓硬件
for service in systemd-udevd.service systemd-resolved.service systemd-networkd.service NetworkManager.service; do
    # 强行将服务指向空设备，等同于 systemctl mask
    ln -sf /dev/null "/etc/systemd/system/$service"
done

for service in dbus.service ; do
    if [ -f "$GUEST_SYSTEMD_PATH/$service" ]; then
        ln -sf "$GUEST_SYSTEMD_PATH/$service" "/etc/systemd/system/multi-user.target.wants/$service"
    fi
done

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

# 复制自定义的异构架构运行环境（binfmt）相关脚本与服务单元 (启动qemu，使得容器可以直接运行x86软件)
# COPY scripts/binfmt/qemu-binfmt-register.sh /usr/local/bin/
# COPY scripts/binfmt/qemu-binfmt-register.service /etc/systemd/system/
# RUN chmod +x /usr/local/bin/qemu-binfmt-register.sh && \
#    chmod 644 /etc/systemd/system/qemu-binfmt-register.service && \
#    ln -sf /etc/systemd/system/qemu-binfmt-register.service /etc/systemd/system/multi-user.target.wants/qemu-binfmt-register.service
# 
# 严格按照指定顺序彻底卸载并重新安装 qemu 和 binfmt，防止出现异构架构注册冲突 
# RUN apt-get purge -y qemu-* binfmt-support || true && \
#    apt-get autoremove -y && \
#    apt-get autoclean && \
#    # 彻底清除所有旧的、可能导致冲突的 binfmt 配置文件
#    rm -rf /var/lib/binfmts/* && \
#    rm -rf /etc/binfmt.d/* && \
#    rm -rf /usr/lib/binfmt.d/qemu-* && \
#    # 重新更新软件源
#    apt-get update && \
#    # 必须严格按照此顺序安装这两个核心包
#    apt-get install -y qemu-user-static && \
#    apt-get install -y binfmt-support && \
#    # 显式添加 amd64 异构架构支持，并安装对应的基础 libc 库（常用于在 ARM64 宿主机上容器化运行 x86_64 应用）
#    dpkg --add-architecture amd64 && \
#    apt-get update && \
#    apt-get install -y libc6:amd64

# 最终清理 APT 包管理器缓存，尽可能缩减镜像层体积
RUN apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# 阶段 2：将完整的根文件系统导出到 scratch（空白层），以便外部直接提取或打包成 tarfs
FROM scratch AS export

# 从 customizer 编译阶段将所有定制好的根文件系统内容整体拷贝出来
COPY --from=customizer / /
