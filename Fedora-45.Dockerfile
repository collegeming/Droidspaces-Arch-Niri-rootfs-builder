FROM fedora:45 AS customizer

#######################################################
ARG DESKTOP
ARG DESKTOP_AUTOSTART
ARG PulseAudio
ARG ENABLE_zh_tz_ARG
ARG ENABLE_binfmt_ARG
ARG ENABLE_yj_ARG
ARG ENABLE_mesa_ARG
ARG MALI_STACK_VERSION=2026.11.12-v1
ARG MALI_STACK_BUNDLE_URL=
ARG MALI_STACK_BUNDLE_SHA256=
ARG MALI_STACK_BUNDLE_DIR=
ARG DISPLAY_BACKEND
ARG ENABLE_kfgj_ARG
ARG ENABLE_zip_ARG
ARG ENABLE_docker_ARG
ARG ENABLE_srf_ARG
ARG ENABLE_systemd257_ARG
ARG USERNAME
ARG ANLAND_RELEASE_REPOSITORY=Goldzxcbug/droidspaces-package
# Fedora 45 的 patched KWin 由本仓库 build-anland-kde-packages.yml 发布；
# 同 tag 的资产会被新构建覆盖，内容和 sha256 以发布页为准。
ARG ANLAND_KDE_RELEASE_REPOSITORY=collegeming/Droidspaces-Arch-Niri-rootfs-builder
ARG ANLAND_KDE_RELEASE_TAG=anland-kde-packages
ARG ANLAND_PACKAGE_REVISION=unknown
# XRING-O3 设备脚本从复刻包按固定 commit 拉取，builder 不再保存副本。
ARG XRING_O3_KIT_REPO=https://github.com/collegeming/xring-o3-droidspaces-package.git
ARG XRING_O3_KIT_REF=24fc5f6cf621fef277731de6a600d1f3260d6922
ARG APPLY_PREFERENCES=true
ARG PREFERENCES_PROFILE=fedora-kde-mali
ARG PREFERENCES_STRICT=false
# KDE 不使用 niri 的 anland-0 输出块；保留参数是为了与构建脚本/归档命名一致。
ARG OUTPUT_SCALE=2
ARG OUTPUT_MODE=native
######################################################

# 本分支的 Fedora 只交付 XRING-O3 + KDE + Anland Wayland + Mali 栈。
# 其他组合在安装任何软件包之前直接失败，避免产出看似可用、实际没有 GPU 的镜像。
RUN if [ "$DESKTOP" != "kde" ] || [ "$DISPLAY_BACKEND" != "anland-wayland" ]; then \
        echo "错误：Fedora-45 只支持 KDE + anland-wayland。" >&2; \
        echo "当前 DESKTOP=${DESKTOP:-<未设置>}，DISPLAY_BACKEND=${DISPLAY_BACKEND:-<未设置>}。" >&2; \
        exit 1; \
    fi && \
    if [ "$ENABLE_mesa_ARG" != "true" ]; then \
        echo "错误：Fedora-45 只交付带 XRING-O3 Mali stack 的镜像，ENABLE_mesa_ARG 必须为 true。" >&2; \
        exit 1; \
    fi && \
    if [ -z "$MALI_STACK_BUNDLE_URL" ] || [ -z "$MALI_STACK_BUNDLE_SHA256" ]; then \
        echo "错误：缺少 MALI_STACK_BUNDLE_URL / MALI_STACK_BUNDLE_SHA256。" >&2; \
        exit 1; \
    fi

ARG TARGETPLATFORM
RUN if [ -n "$TARGETPLATFORM" ] && [ "$TARGETPLATFORM" != "linux/arm64" ]; then \
        echo "错误：本镜像只支持 linux/arm64，当前 TARGETPLATFORM=$TARGETPLATFORM。" >&2; \
        exit 1; \
    fi

COPY scripts/install-usb-manager.sh /usr/local/sbin/install-droidspaces-usb-manager
COPY scripts/systemd257.sh /usr/local/sbin/systemd257
COPY scripts/tui/install-anland-kde.sh /usr/local/sbin/install-anland-kde
COPY scripts/install-anland-desktop.sh /usr/local/sbin/install-anland-desktop
COPY scripts/install-desktop.sh /usr/local/sbin/install-desktop
COPY scripts/configure-desktop.sh /usr/local/sbin/configure-desktop
COPY scripts/start-desktop-session.sh /usr/local/bin/start-desktop-session
COPY scripts/kde-session-env.sh /usr/local/lib/droidspaces/kde-session-env.sh
COPY scripts/desktops/ /usr/local/lib/droidspaces/desktops/
COPY scripts/start/ /tmp/droidspaces-start/
COPY scripts/etc/wireplumber/wireplumber.conf.d/Anland-Audio.conf /tmp/Anland-Audio.conf
RUN if [ "$DISPLAY_BACKEND" = "anland-wayland" ]; then \
        install -D -m 0644 /tmp/Anland-Audio.conf /etc/wireplumber/wireplumber.conf.d/Anland-Audio.conf; \
    fi && \
    rm -f /tmp/Anland-Audio.conf

# Fedora 容器默认只解包 en_US 翻译；桌面需要 zh_CN 翻译。
RUN echo '%_install_langs all' > /etc/rpm/macros.image-language-conf && \
    echo "max_parallel_downloads=10" >> /etc/dnf/dnf.conf && \
    echo "fastestmirror=True" >> /etc/dnf/dnf.conf && \
    echo "defaultyes=True" >> /etc/dnf/dnf.conf

RUN chmod +x /usr/local/sbin/install-anland-kde /usr/local/sbin/install-anland-desktop \
        /usr/local/sbin/install-desktop /usr/local/sbin/configure-desktop \
        /usr/local/bin/start-desktop-session /usr/local/lib/droidspaces/desktops/*.sh && \
    chmod 0644 /usr/local/lib/droidspaces/kde-session-env.sh

# 基础工具 + Mali 栈解包/校验依赖（zstd、diffutils、coreutils）。
RUN dnf install -y --setopt=install_weak_deps=False \
        bash jq dialog coreutils file findutils grep sed gawk curl wget ca-certificates \
        bash-completion systemd-udev dbus-daemon systemd systemd-pam systemd-resolved fastfetch \
        git nano sudo openssh-server net-tools iptables iptables-legacy iputils iproute \
        bind-utils dhcp-client procps-ng kmod tzdata tar zstd xz diffutils \
        glibc-locale-source glibc-langpack-en glibc-langpack-zh && \
    dnf upgrade -y && \
    dnf clean all && rm -rf /var/cache/dnf

# KDE Plasma 6.8 + 会话依赖；安装清单集中在 scripts/desktops/kde.sh。
RUN /usr/local/sbin/install-desktop "$DESKTOP"

# 输入法 fcitx5 (可选)
RUN if [ "$ENABLE_srf_ARG" = "true" ]; then \
        dnf install -y --setopt=install_weak_deps=False fcitx5 fcitx5-qt fcitx5-gtk; \
    fi && \
    if [ "$ENABLE_srf_ARG" = "true" ] && [ "$ENABLE_zh_tz_ARG" = "true" ]; then \
        dnf install -y --setopt=install_weak_deps=False fcitx5-chinese-addons; \
    fi

# 开发工具 / 压缩 / Docker（可选）
RUN if [ "$ENABLE_kfgj_ARG" = "true" ]; then \
        dnf install -y --setopt=install_weak_deps=False \
            gcc gcc-c++ make cmake autoconf automake libtool pkgconf clang llvm \
            python3 python3-pip python3-devel; \
    fi && \
    if [ "$ENABLE_zip_ARG" = "true" ]; then \
        dnf install -y --setopt=install_weak_deps=False zip unzip p7zip p7zip-plugins bzip2 xz tar gzip; \
    fi && \
    if [ "$ENABLE_docker_ARG" = "true" ]; then \
        dnf install -y --setopt=install_weak_deps=False moby-engine docker-compose docker-cli; \
    fi

# Anland patched KWin（Fedora 45 原生构建，见 build-anland-kde-packages.yml）。
# install-anland-kde.sh 会替换仓库里的 kwin，并在 dnf.conf 写入 kwin* 排除，
# 避免后续升级把 Anland backend 覆盖掉。
RUN if [ "$DISPLAY_BACKEND" = "anland-wayland" ]; then \
        echo "--> 安装 Anland KDE 包（${ANLAND_KDE_RELEASE_REPOSITORY}@${ANLAND_KDE_RELEASE_TAG}）..." && \
        ANLAND_KDE_RELEASE_REPOSITORY="$ANLAND_KDE_RELEASE_REPOSITORY" \
        ANLAND_KDE_RELEASE_TAG="$ANLAND_KDE_RELEASE_TAG" \
        /usr/local/sbin/install-anland-desktop "$DESKTOP" --1; \
    fi

# 强制 iptables-legacy（Android 内核兼容）
RUN ln -sf /usr/sbin/iptables-legacy /usr/sbin/iptables && \
    ln -sf /usr/sbin/ip6tables-legacy /usr/sbin/ip6tables && \
    ln -sf /usr/sbin/iptables-legacy-save /usr/sbin/iptables-save && \
    ln -sf /usr/sbin/iptables-legacy-restore /usr/sbin/iptables-restore && \
    ln -sf /usr/sbin/ip6tables-legacy-save /usr/sbin/ip6tables-save && \
    ln -sf /usr/sbin/ip6tables-legacy-restore /usr/sbin/ip6tables-restore

# Locale / 时区 / SSH / 用户
RUN if [ "$ENABLE_zh_tz_ARG" = "true" ]; then \
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
        echo "Asia/Shanghai" > /etc/timezone && \
        echo "LANG=zh_CN.UTF-8" > /etc/locale.conf; \
    else \
        echo "LANG=en_US.UTF-8" > /etc/locale.conf; \
    fi && \
    mkdir -p /var/run/sshd && \
    ssh-keygen -A && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    useradd -m -s /bin/bash ${USERNAME} && echo "${USERNAME}:1234" | chpasswd && \
    systemctl enable sshd

# desktop-session.service 硬编码 User=1000。
RUN [ "$(id -u "${USERNAME}")" = "1000" ] || { \
        echo "ERROR: ${USERNAME} 的 uid 不是 1000，desktop-session.service 将无法启动" >&2; \
        exit 1; \
    }

# 为 droidspaces 的 su/su -l 入口建立完整的 systemd 用户会话。
RUN for pam_file in /etc/pam.d/su /etc/pam.d/su-l; do \
        if ! grep -qE '^[[:space:]-]*session[[:space:]].*pam_systemd\.so' "$pam_file"; then \
            sed -i '/^[[:space:]]*session[[:space:]].*pam_unix\.so/a\session        optional        pam_systemd.so' "$pam_file"; \
        fi; \
    done && \
    grep -qE '^[[:space:]]*session[[:space:]].*pam_env\.so' /etc/pam.d/su-l || \
        echo 'session        required        pam_env.so' >> /etc/pam.d/su-l

# xring-o3 设备档案：标记、bridge gate、会话 GPU 环境、Vulkan 默认 ICD、
# desktop 包装器与 environment.d。设备脚本固定 commit 拉取。
RUN git init -q /tmp/xring-o3-kit && \
    git -C /tmp/xring-o3-kit remote add origin "$XRING_O3_KIT_REPO" && \
    git -C /tmp/xring-o3-kit fetch -q --depth=1 origin "$XRING_O3_KIT_REF" && \
    git -C /tmp/xring-o3-kit checkout -q --detach FETCH_HEAD && \
    install -d -m 0755 /usr/local/lib/droidspaces/device && \
    cp -a /tmp/xring-o3-kit/rootfs/device/xring-o3 /usr/local/lib/droidspaces/device/ && \
    rm -rf /tmp/xring-o3-kit && \
    chmod +x /usr/local/lib/droidspaces/device/xring-o3/*.sh && \
    /usr/local/lib/droidspaces/device/xring-o3/profile.sh --install

# Mali 栈（必装）：bundle 校验失败时 docker build 直接失败。
RUN /usr/local/lib/droidspaces/device/xring-o3/install-mali-stack.sh


# libgbm 垫片把真实库路径写死为 /opt/mesa-kopper-retire-42194036783/...；
# Fedora 的 libgbm 在 /usr/lib64。补上路径，让垫片在 KWin 会话里可用。
RUN mkdir -p /opt/gbm-spike /opt/zc \
        /opt/mesa-kopper-retire-42194036783/candidate/usr/lib && \
    if [ ! -e /opt/mesa-kopper-retire-42194036783/candidate/usr/lib/libgbm.so.1.0.0 ]; then \
        ln -sf /usr/lib64/libgbm.so.1.0.0 \
            /opt/mesa-kopper-retire-42194036783/candidate/usr/lib/libgbm.so.1.0.0; \
    fi && \
    { [ -e /opt/zc/current ] || ln -sfn /opt/mali-stack/current /opt/zc/current; } && \
    touch /opt/gbm-spike/shim.log && chmod 666 /opt/gbm-spike/shim.log

# 设备节点与 Anland socket 的容器侧准备。
RUN /usr/local/lib/droidspaces/device/xring-o3/card0.sh --install && \
    /usr/local/lib/droidspaces/device/xring-o3/anland.sh --install

# 初始化环境变量；KDE 会话变量由 configure-desktop 调用的 kde.sh 写入。
RUN : > /etc/environment

# 输入法自启动 + 会话配置 + desktop-session unit。
RUN <<'EOF_RUN'
if [ "$ENABLE_srf_ARG" = "true" ]; then
    mkdir -p /home/${USERNAME}/.config/autostart
    cat > /home/${USERNAME}/.config/autostart/fcitx5.desktop <<'EOF'
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
    printf '%s\n' 'XMODIFIERS=@im=fcitx' 'INPUT_METHOD=fcitx' >> /etc/environment
fi
echo 'export XDG_RUNTIME_DIR=/run/user/$(id -u)' >> /home/${USERNAME}/.bashrc
OUTPUT_SCALE="${OUTPUT_SCALE:-2}" OUTPUT_MODE="${OUTPUT_MODE:-native}" \
    /usr/local/sbin/configure-desktop "$DESKTOP" "$DISPLAY_BACKEND" "$DESKTOP_AUTOSTART" "$USERNAME"
rm -rf /tmp/droidspaces-start
EOF_RUN

# Fedora + Android 运行环境修正（网络、日志、logind、udev、只读路径）。
RUN <<'EOF_RUN'
grep -q '^aid_inet:' /etc/group     || echo 'aid_inet:x:3003:'    >> /etc/group
grep -q '^aid_net_raw:' /etc/group || echo 'aid_net_raw:x:3004:' >> /etc/group
grep -q '^aid_net_admin:' /etc/group || echo 'aid_net_admin:x:3005:' >> /etc/group
getent group droidspaces-gpu >/dev/null || groupadd -g 786 -r droidspaces-gpu
usermod -a -G aid_inet,aid_net_raw,input,video,tty,wheel,droidspaces-gpu root || true
usermod -a -G aid_inet,aid_net_raw,input,video,tty,wheel,droidspaces-gpu ${USERNAME} || true

ln -sf /dev/null /etc/systemd/system/systemd-networkd-wait-online.service
ln -sf /dev/null /etc/systemd/system/systemd-journald-audit.socket
cat >> /etc/systemd/journald.conf <<'EOT'
[Journal]
ReadKMsg=no
Audit=no
Storage=volatile
EOT
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/ds-logging.conf <<'EOT'
[Journal]
SystemMaxUse=200M
RuntimeMaxUse=200M
MaxRetentionSec=7day
MaxLevelStore=info
EOT

mkdir -p /etc/systemd/system/multi-user.target.wants
GUEST_SYSTEMD_PATH=/usr/lib/systemd/system
if [ -f "$GUEST_SYSTEMD_PATH/dbus.service" ]; then
    ln -sf "$GUEST_SYSTEMD_PATH/dbus.service" /etc/systemd/system/multi-user.target.wants/dbus.service
fi
if [ "$ENABLE_yj_ARG" = "true" ]; then
    for service in systemd-udevd.service systemd-resolved.service systemd-networkd.service NetworkManager.service; do
        [ -f "$GUEST_SYSTEMD_PATH/$service" ] && ln -sf "$GUEST_SYSTEMD_PATH/$service" "/etc/systemd/system/multi-user.target.wants/$service"
    done
else
    for service in systemd-udevd.service systemd-resolved.service systemd-networkd.service NetworkManager.service; do
        ln -sf /dev/null "/etc/systemd/system/$service"
    done
fi

mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/99-power-key.conf <<'EOT'
[Login]
HandlePowerKey=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
HandlePowerKeyLongPress=ignore
HandlePowerKeyLongPressHibernate=ignore
EOT

mkdir -p /etc/systemd/system/systemd-udev-trigger.service.d
cat > /etc/systemd/system/systemd-udev-trigger.service.d/override.conf <<'EOT'
[Service]
ExecStart=
ExecStart=-/usr/bin/udevadm trigger --subsystem-match=usb --subsystem-match=block --subsystem-match=input --subsystem-match=tty --subsystem-match=net
EOT
for unit in systemd-udevd.service systemd-udev-trigger.service systemd-udev-settle.service systemd-udevd-kernel.socket systemd-udevd-control.socket; do
    mkdir -p "/etc/systemd/system/${unit}.d"
    printf '[Unit]\nConditionPathIsReadWrite=\n' > "/etc/systemd/system/${unit}.d/99-readonly-fix.conf"
done

mkdir -p /etc/systemd/network
cat > /etc/systemd/network/10-eth-dhcp.network <<'EOT'
[Match]
Name=eth*

[Network]
DHCP=yes
IPv6AcceptRA=yes

[DHCPv4]
UseDNS=yes
UseDomains=yes
RouteMetric=100
EOT

if [ -f /etc/logrotate.conf ]; then
    sed -i 's/^#maxsize.*/maxsize 50M/' /etc/logrotate.conf
    grep -q 'maxsize 50M' /etc/logrotate.conf || echo 'maxsize 50M' >> /etc/logrotate.conf
fi
echo "Post-extraction fixes applied on $(date)" > /etc/droidspaces
EOF_RUN

# systemd 257 兼容与 Fedora 无关：显式跳过，避免产出半套运行时。
RUN if [ "$ENABLE_systemd257_ARG" = "true" ]; then \
        echo "--> [跳过] Fedora 镜像不提供 systemd 257 旧内核兼容层"; \
    fi

# 桌面偏好（pacman mirrorlist / Rime 构建产物）是 Arch 专属；Fedora 只保留
# 输入法基础配置，不执行 apply-preferences.sh。
RUN if [ "$APPLY_PREFERENCES" = "true" ]; then \
        echo "--> [跳过] Fedora KDE 镜像不执行 Arch 桌面偏好脚本（$PREFERENCES_PROFILE）"; \
    fi

# 清理一次性构建脚本与缓存。
RUN rm -f /usr/local/sbin/configure-desktop /usr/local/sbin/install-desktop \
        /usr/local/sbin/install-anland-desktop /usr/local/sbin/install-droidspaces-usb-manager \
        /usr/local/sbin/systemd257 /usr/local/sbin/install-anland-kde && \
    rm -rf /usr/local/lib/droidspaces/desktops /usr/local/sbin/configure-chrome && \
    rm -rf /var/cache/dnf /var/lib/dnf/history.sqlite* /tmp/* 2>/dev/null || true

# 阶段 2：导出完整 rootfs
FROM scratch AS export
COPY --from=customizer / /
