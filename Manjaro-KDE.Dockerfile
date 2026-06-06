ARG TARGETPLATFORM
FROM manjaro:latest AS customizer

#######################################################
ARG BUILD_KDE
ARG BUILD_KDE_plus
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
ARG USERNAME
######################################################

ENV LANG=C.UTF-8

# 更新系统并安装基础工具（使用 pacman）
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm --needed \
    bash jq dialog coreutils file findutils grep sed gawk curl wget ca-certificates locales sudo dbus systemd systemd-sysv udev awk git nano openssh net-tools iputils iproute2 iptables procps tzdata kmod || true && \
    pacman -Scc --noconfirm

# 复制并准备自定义脚本
COPY scripts/download-firmware /usr/local/bin/
COPY scripts/bashrc.sh /etc/profile.d/ds-aliases.sh
RUN chmod +x /usr/local/bin/download-firmware /etc/profile.d/ds-aliases.sh || true

# KDE 安装（按 BUILD_KDE 选择不同集合）
RUN if [ "$BUILD_KDE" = "min" ]; then \
        pacman -S --noconfirm --needed dbus-x11 xorg-xhost xorg-xinit noto-fonts-cjk noto-fonts-emoji plasma-desktop pipewire pipewire-pulse wireplumber powerdevil kscreen plasma-pa ark kwin konsole dolphin kate upower mesa-utils alsa-utils pulseaudio-alsa || true; \
    fi && \
    if [ "$BUILD_KDE" = "conc" ]; then \
        pacman -S --noconfirm --needed dbus-x11 xorg-server xorg-xinit noto-fonts-cjk noto-fonts-emoji plasma kde-applications pipewire pipewire-pulse wireplumber powerdevil kscreen plasma-pa ark kwin konsole dolphin kate kinfocenter mesa-utils ffmpegthumbs kio-extras xdg-user-dirs wayland-protocols xorg-xwayland || true; \
    fi

# 可选组件
RUN if [ "$ENABLE_kfgj_ARG" = "true" ]; then \
        pacman -S --noconfirm --needed base-devel gcc make cmake clang python python-pip python-virtualenv || true; \
    fi && \
    if [ "$ENABLE_zip_ARG" = "true" ]; then \
        pacman -S --noconfirm --needed unzip p7zip tar gzip xz || true; \
    fi && \
    if [ "$ENABLE_docker_ARG" = "true" ]; then \
        pacman -S --noconfirm --needed docker docker-compose || true; \
    fi

# 时区与本地化
RUN if [ "$ENABLE_zh_tz_ARG" = "true" ]; then \
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && echo "Asia/Shanghai" > /etc/timezone && \
        sed -i 's/^#\(zh_CN.UTF-8 UTF-8\)/\1/' /etc/locale.gen && locale-gen && \
        export LANG=zh_CN.UTF-8; \
    else \
        sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' /etc/locale.gen && locale-gen && export LANG=en_US.UTF-8; \
    fi

# 创建用户并设置密码
RUN useradd -m -s /bin/bash ${USERNAME} || true && echo "${USERNAME}:1234" | chpasswd || true

# 环境变量
RUN cat <<'EOF' > /etc/environment
XCURSOR_SIZE=48
DISPLAY=:5
EOF

RUN if [ "$PulseAudio" = "socket" ]; then \
        echo "PULSE_SERVER=unix:/tmp/.pulse-socket" >> /etc/environment; \
    elif [ "$PulseAudio" = "tcp" ]; then \
        echo "PULSE_SERVER=tcp:127.0.0.1:4713" >> /etc/environment; \
    fi

# 输入法与自动启动（参考 Debian 实现）
RUN if [ "$ENABLE_srf_ARG" = "true" ]; then \
        pacman -S --noconfirm --needed fcitx5 fcitx5-chinese-addons || true; \
    fi

RUN echo 'export XDG_RUNTIME_DIR=/run/user/$(id -u)' >> /home/${USERNAME}/.bashrc || true

# 简单的 systemd 服务占位（如需要可在宿主或 Docker 运行时 enable）
RUN if [ "$BUILD_KDE_plus" = "true" ]; then \
        cat > /etc/systemd/system/plasma-x11.service <<EOF
[Unit]
Description=Start Plasma X11
After=network.target display-manager.service

[Service]
Type=simple
User=${USERNAME}
EnvironmentFile=-/etc/environment
ExecStart=/bin/bash -lc 'DISPLAY=:5 startplasma-x11'
Restart=no
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
        mkdir -p /etc/systemd/system/multi-user.target.wants && \
        ln -sf /etc/systemd/system/plasma-x11.service /etc/systemd/system/multi-user.target.wants/plasma-x11.service; \
    fi || true

# 清理 pacman 缓存
RUN pacman -Scc --noconfirm || true

COPY scripts/binfmt/qemu-binfmt-register.sh /usr/local/bin/ || true
COPY scripts/binfmt/qemu-binfmt-register.service /etc/systemd/system/ || true

RUN if [ "$ENABLE_binfmt_ARG" = "true" ]; then \
        chmod +x /usr/local/bin/qemu-binfmt-register.sh || true && \
        chmod 644 /etc/systemd/system/qemu-binfmt-register.service || true; \
    else \
        rm -f /usr/local/bin/qemu-binfmt-register.sh /etc/systemd/system/qemu-binfmt-register.service || true; \
    fi

FROM scratch AS export
COPY --from=customizer / /
