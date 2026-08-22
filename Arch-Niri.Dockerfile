# Dockerfile (Arch Linux Minimal + niri/ANiri + Noctalia Shell - aarch64)
# 说明：
#   - 定位：不带 KDE 的最小化 Arch RootFS，集成 niri（滚动平铺 Wayland 合成器）
#     与 Noctalia Shell 桌面外壳。
#   - 基础逻辑来自上游 Droidspaces-rootfs-builder 的 Arch-Minimal
#     （最小包集合、iptables-legacy 兼容、ds-aliases 别名），
#     并叠加本项目的优化：中文环境、用户创建、systemd 257 旧内核兼容、
#     fcitx5、高通 GPU（mesa-for-android-container）、binfmt 跨架构、
#     NAT/硬件识别门控、USB Manager、压缩/开发/Docker/TMOE 可选组件。
#   - niri 使用 ANiri（https://github.com/Celvra/ANiri）：niri 的 anland 后端
#     fork，通过 Anland 把桌面渲染到 Android Surface（与本项目 patched KWin
#     同一套宿主侧方案：virtual-drm-daemon + /run/display.sock 绑定挂载）。
#     二进制固定从 ANiri Releases 下载并校验 SHA256，构建时 strip 减小体积。
#   - 显示路径固定为 Anland/Wayland：无需 Termux:X11；BUILD_KDE 选项被忽略
#     （本模板不安装任何 KDE 组件），BUILD_KDE_plus 控制的是 niri 自启动。
#   - pacman 源定制：
#       * TUNA 清华镜像置顶（archlinuxarm $arch/$repo），官方源保留回退；
#       * 附加 archlinuxcn aarch64 仓库（TUNA 优先、官方回退），
#         首次以 SigLevel=Never 引导安装 archlinuxcn-keyring（其安装脚本
#         会执行 pacman-key --populate 完成本地信任），随后恢复签名校验；
#       * archlinuxcn 提供 paru（AUR 助手）与 rime-ice-git（雾凇拼音）等
#         aarch64 预编译包，无需本地编译。

ARG TARGETPLATFORM

FROM ogarcia/archlinux AS customizer

#######################################################
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
ARG TERMINAL_ARG=kitty
ARG USERNAME
ARG ANLAND_KDE_RELEASE_REPOSITORY=Goldzxcbug/Droidspaces-rootfs-KDE-builder
ARG ANLAND_KDE_RELEASE_TAG
ARG ANLAND_KDE_PACKAGE_REVISION=unknown
# ANiri（niri anland 后端）固定版本与校验
ARG ANIRI_VERSION=v0.2.0
ARG ANIRI_FILENAME=niri-arm64-linux-bin
ARG ANIRI_SHA256=9d7e8d3533e73f95a9141c81346c5f33777b9be38b87bf703cb322b340eee6eb
######################################################

COPY scripts/install-usb-manager.sh /usr/local/sbin/install-droidspaces-usb-manager
COPY scripts/systemd257.sh /usr/local/sbin/systemd257
COPY scripts/build-ghostty.sh /usr/local/sbin/build-ghostty
COPY scripts/bashrc.sh /etc/profile.d/ds-aliases.sh
COPY scripts/niri/default-config.kdl /usr/share/niri/default-config.kdl
COPY scripts/terminal/ /tmp/beautify/

# Arch-Niri 限制检查与说明
RUN if [ "$BUILD_KDE" = "mobile" ]; then \
        echo "错误: Arch-Niri 不支持 mobile 模式（该选项属于 KDE Plasma Mobile）" >&2; \
        exit 1; \
    fi && \
    if [ "$BUILD_KDE" = "min" ] || [ "$BUILD_KDE" = "conc" ]; then \
        echo "--> [提示] Arch-Niri 为无 KDE 模板，build_KDE=$BUILD_KDE 将被忽略"; \
    fi && \
    if [ "$ENABLE_anland_kde_ARG" != "true" ]; then \
        echo "--> [提示] Arch-Niri 显示路径固定为 Anland/Wayland，无论开关如何都会写入 anland 环境变量"; \
    fi && \
    if [ "$PulseAudio" != "none" ]; then \
        echo "--> [提示] Anland App 自带音频路径，PulseAudio=$PulseAudio 仅保留客户端变量"; \
    fi

RUN chmod +x /etc/profile.d/ds-aliases.sh && \
    sed -i '/^#ParallelDownloads/s/^#//' /etc/pacman.conf && \
    # 本地构建包（pacman -U / paru AUR 安装）无签名，显式放开本地文件签名要求；
    # 仓库包签名校验不受影响
    sed -i '/^ParallelDownloads/a LocalFileSigLevel = PackageOptional' /etc/pacman.conf && \
    sed -i '/NoExtract.*locale/d' /etc/pacman.conf && \
    sed -i '/NoExtract.*i18n/d' /etc/pacman.conf && \
    # pacman 清华镜像置顶，官方 ALARM 源保留为回退
    sed -i '1i Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/$arch/$repo' /etc/pacman.d/mirrorlist && \
    # archlinuxcn aarch64 仓库（置于末尾，官方仓库优先）。
    # 注意 archlinuxcn 的目录结构为 $arch/（无 $repo 子目录，与 ALARM 不同）
    # 首次以仓库级 SigLevel=Never 引导安装 archlinuxcn-keyring。
    # 基础镜像的 pacman gnupg 目录没有本地私钥，keyring 的 populate
    # (lsign) 会失败（There is no secret key available to sign with），
    # 需先 pacman-key --init 生成本地主密钥
    printf '\n[archlinuxcn]\nSigLevel = Never\nServer = https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/$arch\nServer = https://repo.archlinuxcn.org/$arch\n' >> /etc/pacman.conf && \
    pacman-key --init && \
    pacman -Sy --noconfirm archlinux-keyring glibc archlinuxcn-keyring && \
    # keyring 就位后恢复 archlinuxcn 签名校验
    sed -i '/^\[archlinuxcn\]/,/^Server/{/^SigLevel = Never$/d;}' /etc/pacman.conf && \
    pacman -Su --noconfirm && \
    pacman -S --noconfirm --needed \
    # 核心工具组件（沿用上游 Arch-Minimal 的最小集合）
    bash dialog coreutils file findutils grep sed gawk curl wget ca-certificates bash-completion \
    systemd dbus \
    # 基础工具
    git nano sudo \
    # 网络与 SSH
    openssh net-tools iptables iputils iproute2 bind \
    # 日志与监控
    logrotate procps-ng fastfetch jq \
    # 编辑器与文件管理器（gvfs 提供 Nemo 回收站/挂载后端，wl-clipboard
    # 提供 Wayland 原生剪贴板工具，neovim 与 Noctalia 均可使用）
    neovim nemo gvfs wl-clipboard \
    # 内核模块与时区数据
    kmod tzdata tar util-linux \
    # strip niri 二进制需要 binutils
    binutils \
    ######################################## niri 运行时依赖（按 ANiri 安装指南） ########
    libinput pango glib2 libdisplay-info mesa seatd systemd-libs libdrm libxkbcommon libevdev \
    libwacom lua freetype2 fontconfig libx11 libxcb libffi pcre2 libgudev pixman libxrender libxext \
    xkeyboard-config \
    # 音频栈（Anland App 负责转发，容器内安装客户端库）
    pipewire libpipewire pipewire-pulse wireplumber \
    noctalia fuzzel kitty && \
    # AUR 助手 paru（archlinuxcn aarch64 预编译包，容器内以普通用户运行）、
    # base-devel 全组（makepkg 与源码构建必需，容器内 AUR 构建完全可用；
    # 增加约 250MB 体积）、zig 0.16（官方稳定版 PKGBUILD 无约束，0.16 满足；
    # 构建后随工具链清理）、电源信息、字体
    pacman -S --noconfirm --needed paru base-devel zig upower noto-fonts noto-fonts-emoji && \
    # 终端选择（TERMINAL_ARG）：kitty（默认，已随上面 pacman 装好，直接跳过）
    # 或 ghostty（调用 scripts/build-ghostty.sh：官方稳定版 1.3.1 PKGBUILD +
    # 官方 zig 0.16.0 + 删 --system 改在线 fetch + pandoc 官方二进制，约 25-50
    # 分钟，硬失败——任何错误 exit 1，不再静默回退 kitty）。脚本封装为单点
    # 维护，Arch-Niri 与 Arch-KDE 共用。kitty 选项跳过本块，直接用已装仓库 kitty。
    # ghostty 真实根因详见 scripts/build-ghostty.sh 顶部注释。
    if [ "$TERMINAL_ARG" = "ghostty" ]; then \
        /usr/local/sbin/build-ghostty; \
        userdel -r aurbuild 2>/dev/null || true; \
        rm -f /etc/sudoers.d/aurbuild; \
        pacman -Rdd --noconfirm zig 2>/dev/null || true; \
        rm -f /usr/local/bin/pandoc /usr/local/bin/zig; \
        rm -rf /usr/local/lib/zig; \
        rm -rf /tmp/ghostty-pkg; \
    fi && \
    # 中文附加字体（可选）
    if [ "$ENABLE_zh_tz_ARG" = "true" ]; then pacman -S --noconfirm --needed noto-fonts-cjk; fi && \
    ############################################## 可选组件 ################################################
    # 输入法 fcitx5 + rime 雾凇拼音 (可选)
    if [ "$ENABLE_srf_ARG" = "true" ]; then \
        pacman -S --noconfirm --needed fcitx5-im; \
    fi && \
    if [ "$ENABLE_srf_ARG" = "true" ]; then \
        pacman -S --noconfirm --needed fcitx5-rime; \
        pacman -S --noconfirm --needed rime-ice-git; \
    fi && \
    ## 开发工具集成 (可选)
    if [ "$ENABLE_kfgj_ARG" = "true" ]; then \
        pacman -S --noconfirm --needed base-devel cmake clang llvm python python-pip; \
    fi && \
    ## 压缩工具扩展 (可选)
    if [ "$ENABLE_zip_ARG" = "true" ]; then \
        pacman -S --noconfirm --needed zip unzip p7zip bzip2 xz tar gzip; \
    fi && \
    ## docker (可选)
    if [ "$ENABLE_docker_ARG" = "true" ]; then \
        pacman -S --noconfirm --needed docker docker-compose; \
    fi && \
    ## 集成tmoe (可选)
    if [ "$ENABLE_tmoe_ARG" = "true" ]; then \
        git clone --depth=1 https://github.com/2moe/tmoe-linux.git /usr/local/etc/tmoe-linux/git && \
        ln -sf /usr/local/etc/tmoe-linux/git/debian.sh /usr/local/bin/tmoe && \
        chmod -R 755 /usr/local/etc/tmoe-linux; \
    fi

# 配置 legacy iptables（上游：Android 兼容必需）
RUN ln -sf /usr/bin/iptables-legacy /usr/bin/iptables && \
    ln -sf /usr/bin/ip6tables-legacy /usr/bin/ip6tables && \
    ln -sf /usr/bin/arptables-legacy /usr/bin/arptables && \
    ln -sf /usr/bin/ebtables-legacy /usr/bin/ebtables

# 配置 Locale、时区与 SSH
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
    # 清理容器内默认的 alarm 或 arch 用户后创建目标用户（默认密码 1234）
    userdel -r alarm 2>/dev/null || true && \
    useradd -m -s /bin/bash ${USERNAME} && echo "${USERNAME}:1234" | chpasswd && \
    systemctl enable sshd

# 为 RootFS 安装 Droidspaces USB Manager
RUN /usr/local/sbin/install-droidspaces-usb-manager --user "${USERNAME}"

# 为 droidspaces 的 su/su -l 入口建立完整的 systemd 用户会话。
RUN for pam_file in /etc/pam.d/su /etc/pam.d/su-l; do \
        if ! grep -qE '^[[:space:]-]*session[[:space:]].*pam_systemd\.so' "$pam_file"; then \
            sed -i '/^[[:space:]]*session[[:space:]].*pam_unix\.so/a\session        optional        pam_systemd.so' "$pam_file"; \
        fi; \
    done && \
    grep -qE '^[[:space:]]*session[[:space:]].*pam_env\.so' /etc/pam.d/su-l || \
        echo 'session        required        pam_env.so' >> /etc/pam.d/su-l

# 添加环境变量：Anland/Wayland 为固定显示路径
RUN cat <<'EOF' > /etc/environment
XCURSOR_SIZE=48
WAYLAND_DISPLAY=wayland-0
QT_QPA_PLATFORM=wayland
ANLAND=1
ANLAND_SOCKET=/run/display.sock
ANLAND_DRM_DEVICE=/dev/dri/renderD128
XWAYLAND_GBM_DEVICE=/dev/dri/renderD128
EOF
RUN if [ "$ENABLE_mesa_ARG" = "true" ]; then \
        echo "MESA_LOADER_DRIVER_OVERRIDE=kgsl" >> /etc/environment && \
        echo "GALLIUM_DRIVER=kgsl" >> /etc/environment && \
        echo "FD_FORCE_KGSL=1" >> /etc/environment; \
    fi
# 音频选择（X11 时代的转发方式，Anland 下通常不需要）
RUN if [ "$PulseAudio" = "socket" ]; then \
        echo "PULSE_SERVER=unix:/tmp/.pulse-socket" >> /etc/environment; \
    elif [ "$PulseAudio" = "tcp" ]; then \
        echo "PULSE_SERVER=tcp:127.0.0.1:4713" >> /etc/environment; \
    fi

RUN if [ "$ENABLE_8gen2_wayland_ARG" = "true" ]; then \
        echo 'FD_DEV_FEATURES=enable_tp_ubwc_flag_hint=1' >> /etc/environment; \
    fi

# 输入法环境变量（不使用 heredoc：BuildKit 的重定向 heredoc 会终止指令，
# 其后的 fi 会被当作 Dockerfile 指令导致解析错误）
RUN if [ "$ENABLE_srf_ARG" = "true" ]; then \
        echo "XMODIFIERS=@im=fcitx5" >> /etc/environment && \
        echo "GTK_IM_MODULE=fcitx5" >> /etc/environment && \
        echo "QT_IM_MODULE=fcitx5" >> /etc/environment && \
        echo "SDL_IM_MODULE=fcitx5" >> /etc/environment && \
        echo "GLFW_IM_MODULE=fcitx" >> /etc/environment; \
    fi

RUN echo 'export XDG_RUNTIME_DIR=/run/user/$(id -u)' >> /home/${USERNAME}/.bashrc && \
    chown ${USERNAME}:${USERNAME} /home/${USERNAME}/.bashrc

# 桌面应用预配置：统一写入 /etc/skel（新用户模板）并复制到当前用户家目录
# 1. fcitx5 输入法 profile：默认分组直接挂 rime（雾凇拼音），跳过首次运行向导
# 2. GTK3/GTK4 暗色主题（与 Noctalia 深色风格一致；ghostty/Nemo 均读取）
# 3. neovim 最小默认配置（UTF-8、行号、真彩色、鼠标、系统剪贴板同步）
# 4. mimeapps：目录默认用 Nemo 打开
# 5. Nemo "在终端中打开" 动作 + droidspaces-terminal 包装脚本
#    （ghostty 优先、缺失回退 kitty，与 niri Mod+T 快捷键行为一致）
RUN <<'EOF_RUN'
install -d -m 755 /etc/skel/.config/fcitx5 \
    /etc/skel/.config/gtk-3.0 /etc/skel/.config/gtk-4.0 \
    /etc/skel/.config/nvim /etc/xdg

cat <<'EOF' > /etc/skel/.config/fcitx5/profile
[Groups/0]
Name=Default
Default Layout=us
DefaultIM=rime

[Groups/0/Items/0]
Name=keyboard-us
Layout=

[Groups/0/Items/1]
Name=rime
Layout=

[GroupOrder]
0=Default
EOF

cat <<'EOF' > /etc/skel/.config/gtk-3.0/settings.ini
[Settings]
gtk-application-prefer-dark-theme=true
EOF
cp /etc/skel/.config/gtk-3.0/settings.ini /etc/skel/.config/gtk-4.0/settings.ini

cat <<'EOF' > /etc/skel/.config/nvim/init.lua
-- Droidspaces Arch-Niri 预置默认配置；删除本文件即可恢复 nvim 原生默认
vim.opt.encoding = "utf-8"
vim.opt.number = true
vim.opt.termguicolors = true
vim.opt.mouse = "a"
vim.opt.clipboard = "unnamedplus"
vim.opt.backspace = { "indent", "eol", "start" }
EOF

cat <<'EOF' > /etc/xdg/mimeapps.list
[Default Applications]
inode/directory=nemo.desktop
EOF

cat <<'EOF' > /usr/local/bin/droidspaces-terminal
#!/bin/bash
# Droidspaces 统一终端启动器：ghostty 优先，缺失回退 kitty
dir="${1:-$PWD}"
cd "$dir" 2>/dev/null || true
if command -v ghostty >/dev/null 2>&1; then
    exec ghostty
fi
exec kitty
EOF
chmod 755 /usr/local/bin/droidspaces-terminal

cat <<'EOF' > /usr/share/nemo/actions/droidspaces-terminal.nemo_action
[Nemo Action]
Name=Open in Terminal
Name[zh_CN]=在终端中打开
Comment=Open the current folder in a terminal
Comment[zh_CN]=在终端中打开当前文件夹
Exec=droidspaces-terminal %P
Icon=terminal
Selection=any
Extensions=any;
Dependencies=nemo;
EOF

install -d -o ${USERNAME} -g ${USERNAME} -m 755 /home/${USERNAME}/.config
cp -r /etc/skel/.config/fcitx5 /etc/skel/.config/gtk-3.0 /etc/skel/.config/gtk-4.0 /etc/skel/.config/nvim /home/${USERNAME}/.config/
chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.config
EOF_RUN

# 终端美化：fish + reef + fisher + tide + Maple Mono 字体 +
# kitty/ghostty 配置 + Nemo 中文(cinnamon-translations) + fish 设为默认 shell
RUN chmod +x /tmp/beautify/setup-beautify.sh && \
    /tmp/beautify/setup-beautify.sh ${USERNAME} && \
    rm -rf /tmp/beautify

# 下载 ANiri niri 二进制（固定版本 + SHA256 校验 + strip 减小体积）
RUN echo "--> [niri] 下载 ANiri ${ANIRI_VERSION}..." && \
    curl -fL --retry 5 --retry-delay 3 \
      "https://github.com/Celvra/ANiri/releases/download/${ANIRI_VERSION}/${ANIRI_FILENAME}" \
      -o /tmp/niri-bin && \
    echo "${ANIRI_SHA256}  /tmp/niri-bin" | sha256sum -c - && \
    install -Dm755 /tmp/niri-bin /usr/bin/niri && \
    strip --strip-all /usr/bin/niri && \
    rm -f /tmp/niri-bin && \
    /usr/bin/niri --version

# 安装 niri 默认配置：waybar 自启动替换为 noctalia，终端快捷键指向
# ghostty（缺失时回退 kitty，spawn-sh 运行时探测），并按构建开关追加
# fcitx5 自启动；同时安装到 /etc/skel 与用户家目录
RUN <<'EOF_RUN'
install -Dm644 /usr/share/niri/default-config.kdl /tmp/config.kdl
sed -i 's/spawn-at-startup "waybar"/spawn-at-startup "noctalia"/' /tmp/config.kdl
sed -i 's#spawn "alacritty"#spawn-sh "command -v ghostty >/dev/null 2>\&1 \&\& exec ghostty || exec kitty"#' /tmp/config.kdl
sed -i 's/Open a Terminal: alacritty/Open a Terminal: ghostty (fallback kitty)/' /tmp/config.kdl
sed -i '/Open a Terminal: ghostty/a\    Mod+E hotkey-overlay-title="Open Files: nemo" { spawn "nemo"; }' /tmp/config.kdl
if [ "$ENABLE_srf_ARG" = "true" ]; then
    printf '\n// Droidspaces: fcitx5 input method\nspawn-at-startup "fcitx5" "-d"\n' >> /tmp/config.kdl
fi
# 追加终端窗口背景模糊（kitty niri 原生不生效，ghostty 自带 blur 时由协议优先）
printf '\n// Droidspaces: terminal background blur\nwindow-rule {\n    match app-id="^kitty$"\n    background-effect {\n        blur true\n    }\n}\nwindow-rule {\n    match app-id="^ghostty$"\n    background-effect {\n        blur true\n    }\n}\n' >> /tmp/config.kdl
install -Dm644 -o ${USERNAME} -g ${USERNAME} /tmp/config.kdl /home/${USERNAME}/.config/niri/config.kdl
install -Dm644 /tmp/config.kdl /etc/skel/.config/niri/config.kdl
rm -f /tmp/config.kdl
EOF_RUN

# niri 自启动 systemd 服务（等价上游指南的手写 niri.service）。
# ExecStart 使用 dbus-run-session 包裹：niri 的子进程（fcitx5 的 GTK/Qt
# 输入法模块、Noctalia Shell 的 IPC、剪贴板工具等）都需要会话级
# D-Bus 总线；system 级服务默认没有会话总线。
RUN <<'EOF_RUN'
cat <<'EOF' > /etc/systemd/system/niri.service
[Unit]
Description=Niri Anland compositor
After=network.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
User=__DS_USER__
EnvironmentFile=-/etc/environment
Environment=XDG_RUNTIME_DIR=/run/user/1000
ExecStartPre=+/usr/bin/install -d -o __DS_USER__ -g __DS_USER__ -m 700 /run/user/1000
ExecStart=/usr/bin/dbus-run-session -- /usr/bin/niri
Restart=on-failure
RestartSec=3s

[Install]
WantedBy=multi-user.target
EOF
sed -i "s/__DS_USER__/${USERNAME}/g" /etc/systemd/system/niri.service
if [ "$BUILD_KDE_plus" = "true" ]; then
    mkdir -p /etc/systemd/system/multi-user.target.wants
    ln -sf /etc/systemd/system/niri.service /etc/systemd/system/multi-user.target.wants/niri.service
fi
EOF_RUN

# 注入 binfmt 服务脚本（与 Arch-KDE 相同的 systemd 方案）
COPY scripts/binfmt/qemu-binfmt-register.sh /usr/local/bin/
COPY scripts/binfmt/qemu-binfmt-register.service /etc/systemd/system/

RUN if [ "$ENABLE_binfmt_ARG" = "true" ]; then \
        chmod +x /usr/local/bin/qemu-binfmt-register.sh && \
        chmod 644 /etc/systemd/system/qemu-binfmt-register.service && \
        mkdir -p /etc/systemd/system/multi-user.target.wants && \
        ln -sf /etc/systemd/system/qemu-binfmt-register.service /etc/systemd/system/multi-user.target.wants/qemu-binfmt-register.service && \
        pacman -S --noconfirm --needed qemu-user qemu-user-binfmt && \
        rm -rf /var/cache/pacman/pkg/* /var/lib/pacman/sync/* ; \
    else \
        rm -f /usr/local/bin/qemu-binfmt-register.sh /etc/systemd/system/qemu-binfmt-register.service; \
    fi

# 可选：为 systemd 258+ 发行版构建 systemd 257 旧内核兼容运行时（4.19 内核设备建议开启）
RUN if [ "$ENABLE_systemd257_ARG" = "true" ]; then \
        bash /usr/local/sbin/systemd257; \
    else \
        echo "--> [跳过] 未启用 systemd 257 旧内核兼容"; \
    fi && \
    rm -f /usr/local/sbin/systemd257

# 下载并安装 Mesa（高通 GPU，ANiri 的 kgsl 渲染依赖此定制包）
RUN --mount=type=secret,id=github_token if [ "$ENABLE_mesa_ARG" = "true" ]; then \
        echo "--> [开启] 正在下载并安装最新版 Mesa 驱动..." && \
        GH_TOKEN_VAL="$(cat /run/secrets/github_token 2>/dev/null || true)" && \
        URL=$(if [ -n "$GH_TOKEN_VAL" ]; then \
                 curl -s --retry 5 --retry-delay 3 --retry-all-errors -H "Authorization: Bearer $GH_TOKEN_VAL" https://api.github.com/repos/lfdevs/mesa-for-android-container/releases/latest; \
             else \
                 curl -s --retry 5 --retry-delay 3 --retry-all-errors https://api.github.com/repos/lfdevs/mesa-for-android-container/releases/latest; \
             fi | \
        jq -r '.assets[] | select(.name | test("mesa-for-android-container_.*_archlinux_arm64\\.tar")) | .browser_download_url' | head -1) && \
        if [ -z "$URL" ] || [ "$URL" = "null" ]; then echo "获取下载链接失败，可能是触发了 GitHub API 速率限制"; exit 1; fi && \
        wget -q --tries=5 --waitretry=3 -O /tmp/mesa.tar "$URL" && \
        tar -xf /tmp/mesa.tar -C /tmp && \
        cp /etc/pacman.conf /tmp/pacman-nosig.conf && \
        sed -i 's/.*SigLevel.*/SigLevel = Never/g' /tmp/pacman-nosig.conf && \
        pacman --config /tmp/pacman-nosig.conf -U --noconfirm /tmp/*.pkg.tar.* && \
        rm -f /tmp/mesa.tar /tmp/*.pkg.tar.* /tmp/pacman-nosig.conf /tmp/*.sig ; \
    else \
        echo "--> [跳过] 未开启 Mesa 驱动安装（niri 将回退 llvmpipe 软渲染）"; \
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

# --- 2. 针对 Systemd 的特定修复 ---
ln -sf /dev/null /etc/systemd/system/systemd-networkd-wait-online.service
ln -sf /dev/null /etc/systemd/system/systemd-journald-audit.socket

# 优化 Journald 日志配置
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

# 在 systemd-logind 中禁用电源键行为处理
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
mkdir -p /etc/systemd/system/systemd-udev-trigger.service.d
cat > /etc/systemd/system/systemd-udev-trigger.service.d/override.conf << 'EOF'
[Service]
ExecStart=
ExecStart=-/usr/bin/udevadm trigger --subsystem-match=usb --subsystem-match=block --subsystem-match=input --subsystem-match=tty --subsystem-match=net
EOF

# 针对只读文件系统路径覆盖
for unit in systemd-udevd.service systemd-udev-trigger.service systemd-udev-settle.service systemd-udevd-kernel.socket systemd-udevd-control.socket; do
    mkdir -p "/etc/systemd/system/${unit}.d"
    printf "[Unit]\nConditionPathIsReadWrite=\n" > "/etc/systemd/system/${unit}.d/99-readonly-fix.conf"
done

# 限制特定的网络服务（仅 NAT/Gateway 模式启动）
for unit in NetworkManager.service dhcpcd.service systemd-resolved.service systemd-networkd.service; do
    if [ -f "$GUEST_SYSTEMD_PATH/$unit" ] || [ -f "/etc/systemd/system/multi-user.target.wants/$unit" ]; then
        mkdir -p "/etc/systemd/system/${unit}.d"
        cat > "/etc/systemd/system/${unit}.d/99-netmode-limit.conf" << 'EOF'
[Service]
ExecCondition=
ExecCondition=/bin/sh -c "grep -qE 'net_mode=(nat|gateway)' /run/droidspaces/container.config"
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

# 针对 Android 环境微调日志轮转
if [ -f /etc/logrotate.conf ]; then
    sed -i 's/^#maxsize.*/maxsize 50M/' /etc/logrotate.conf
    if ! grep -q "maxsize 50M" /etc/logrotate.conf; then
        echo "maxsize 50M" >> /etc/logrotate.conf
    fi
fi

echo "Post-extraction fixes applied on $(date)" > /etc/droidspaces
EOF_RUN

# 彻底清理 pacman 缓存（上游使用 pacman -Scc）
RUN pacman -Scc --noconfirm || true; \
    rm -rf /var/cache/pacman/pkg/* /var/lib/pacman/sync/*
# 阶段 2：将完整的根文件系统导出到 scratch（空白层），以便外部直接提取或打包成 tarfs
FROM scratch AS export
COPY --from=customizer / /
