FROM ogarcia/archlinux AS customizer

#######################################################
ARG DESKTOP
ARG DESKTOP_AUTOSTART
ARG PulseAudio
ARG ENABLE_zh_tz_ARG
ARG ENABLE_binfmt_ARG
ARG ENABLE_yj_ARG
ARG ENABLE_mesa_ARG
ARG MALI_STACK_VERSION=
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
ARG ANLAND_PACKAGE_REVISION=unknown
# XRING-O3 设备脚本从复刻包按固定 commit 拉取，builder 不再保存副本。
ARG XRING_O3_KIT_REPO=https://github.com/collegeming/xring-o3-droidspaces-package.git
ARG XRING_O3_KIT_REF=6704d266ae9043f909a4a7aec616d0cf1f18651c
# 最终阶段：桌面偏好设置开关（与 scripts/preferences/apply-preferences.sh 对应）
# 默认开启：文档 01/02 要求开箱可用，关闭会产出“有 niri 但没有终端/输入法”的镜像。
ARG APPLY_PREFERENCES=true
ARG PREFERENCES_PROFILE=arch-niri-noctalia
ARG PREFERENCES_STRICT=false
# niri 默认配置中的 anland-0 输出块：缩放与模式由构建参数决定（mode=native 表示不写 mode）。
ARG OUTPUT_SCALE=2
ARG OUTPUT_MODE=native
######################################################

# 本分支只交付 Arch + niri + XRING-O3 Mali。其它组合在拉取依赖前直接失败，
# 避免产出缺少 GPU 栈、看起来可用但不能渲染的镜像。
RUN if [ "$DESKTOP" != "niri" ] || [ "$DISPLAY_BACKEND" != "anland-wayland" ]; then \
        echo "错误：xring-o3-mali-clean 只支持 Arch + niri + anland-wayland。" >&2; \
        echo "当前 DESKTOP=${DESKTOP:-<未设置>}，DISPLAY_BACKEND=${DISPLAY_BACKEND:-<未设置>}。" >&2; \
        exit 1; \
    fi && \
    if [ "$ENABLE_mesa_ARG" != "true" ]; then \
        echo "错误：本分支只交付带 XRING-O3 Mali stack 的镜像，ENABLE_mesa_ARG 必须为 true。" >&2; \
        exit 1; \
    fi

# 设备是 arm64（Mali/G2-Ultra）。buildx 下 TARGETPLATFORM 一定有值；普通
# docker build 没有该变量时不拦，避免误伤本地单架构构建。
ARG TARGETPLATFORM
RUN if [ -n "$TARGETPLATFORM" ] && [ "$TARGETPLATFORM" != "linux/arm64" ]; then \
        echo "错误：本镜像只支持 linux/arm64，当前 TARGETPLATFORM=$TARGETPLATFORM。" >&2; \
        exit 1; \
    fi

COPY scripts/install-usb-manager.sh /usr/local/sbin/install-droidspaces-usb-manager
COPY scripts/systemd257.sh /usr/local/sbin/systemd257
COPY scripts/tui/install-anland-kde.sh /usr/local/sbin/install-anland-kde
COPY scripts/tui/install-anland-gnome.sh /usr/local/sbin/install-anland-gnome
COPY scripts/tui/install-anland-next.sh /usr/local/sbin/install-anland-next
COPY scripts/tui/install-anland-niri.sh /usr/local/sbin/install-anland-niri
COPY scripts/tui/install-anland-hyprland.sh /usr/local/sbin/install-anland-hyprland
COPY scripts/tui/install-anland-mango.sh /usr/local/sbin/install-anland-mango
COPY scripts/tui/install-anland-denial.sh /usr/local/sbin/install-anland-denial
COPY scripts/install-anland-desktop.sh /usr/local/sbin/install-anland-desktop
COPY scripts/tui/install-mesa.sh /usr/local/sbin/install-mesa
COPY scripts/tui/install-hangover-wine.sh /usr/local/sbin/install-hangover-wine
COPY scripts/tui/install-winefonts.sh /usr/local/sbin/install-winefonts
COPY scripts/tui/droidspaces-tui.sh /usr/local/bin/droidspaces-tui
COPY scripts/tui/droidspaces-gpu.sh /usr/local/bin/droidspaces-gpu
COPY scripts/install-desktop.sh /usr/local/sbin/install-desktop
COPY scripts/configure-desktop.sh /usr/local/sbin/configure-desktop
COPY scripts/configure-chrome.sh /usr/local/sbin/configure-chrome
COPY scripts/configure-mark-shot.sh /usr/local/sbin/configure-mark-shot
COPY scripts/fix-chrome-sandbox.sh /usr/local/bin/fix-chrome-sandbox
COPY scripts/etc/pacman.d/hooks/90-chrome-sandbox.hook /etc/pacman.d/hooks/90-chrome-sandbox.hook
COPY scripts/fix-btop-filecaps.sh /usr/local/bin/fix-btop-filecaps
COPY scripts/etc/pacman.d/hooks/99-btop-filecaps.hook /etc/pacman.d/hooks/99-btop-filecaps.hook
COPY scripts/fix-unsupported-filecaps.sh /usr/local/bin/fix-unsupported-filecaps
COPY scripts/etc/pacman.d/hooks/98-unsupported-filecaps.hook /etc/pacman.d/hooks/98-unsupported-filecaps.hook
COPY scripts/bashrc.sh /etc/profile.d/ds-aliases.sh
COPY scripts/start-desktop-session.sh /usr/local/bin/start-desktop-session
COPY scripts/xwayland-satellite-soft.sh /usr/local/bin/xwayland-satellite-soft
COPY scripts/noctalia-location-sync.sh /usr/local/bin/noctalia-location-sync
COPY scripts/desktops/ /usr/local/lib/droidspaces/desktops/
COPY scripts/etc/niri-default-config.kdl /usr/local/share/droidspaces/niri-default-config.kdl
COPY scripts/etc/wireplumber/wireplumber.conf.d/Anland-Audio.conf /tmp/Anland-Audio.conf
RUN if [ "$DISPLAY_BACKEND" = "anland-wayland" ]; then \
        install -D -m 0644 /tmp/Anland-Audio.conf /etc/wireplumber/wireplumber.conf.d/Anland-Audio.conf; \
    fi && \
    rm -f /tmp/Anland-Audio.conf

RUN chmod +x /usr/local/sbin/install-anland-* /usr/local/sbin/install-mesa /usr/local/sbin/install-hangover-wine /usr/local/sbin/install-winefonts /usr/local/sbin/install-desktop /usr/local/sbin/configure-desktop /usr/local/sbin/configure-chrome /usr/local/sbin/configure-mark-shot /usr/local/bin/fix-chrome-sandbox /usr/local/bin/fix-btop-filecaps /usr/local/bin/fix-unsupported-filecaps /usr/local/bin/droidspaces-tui /usr/local/bin/droidspaces-gpu /usr/local/bin/start-desktop-session /usr/local/bin/xwayland-satellite-soft /usr/local/bin/noctalia-location-sync /usr/local/lib/droidspaces/desktops/*.sh && \
    chmod 0644 /etc/profile.d/ds-aliases.sh && \
    ln -s droidspaces-tui /usr/local/bin/dstui && \
    ln -s droidspaces-tui /usr/local/bin/ds-tui && \
    sed -i '/^#ParallelDownloads/s/^#//' /etc/pacman.conf && \
    sed -i '/NoExtract.*locale/d' /etc/pacman.conf && \
    sed -i '/NoExtract.*i18n/d' /etc/pacman.conf && \
    pacman -Sy --noconfirm archlinux-keyring glibc && \
    pacman -Su --noconfirm && \
    pacman -S --noconfirm --needed \
    # 核心工具组件
    bash jq dialog coreutils file findutils grep sed gawk curl wget ca-certificates bash-completion dbus systemd pam fastfetch logrotate \
    # 用户请求的基础开发/编辑工具
    git nano sudo \
    # 网络与 SSH 工具
    openssh net-tools iptables iputils iproute2 bind \
    # 用于系统监控的 procps 进程工具
    procps-ng \
    # 核心内核模块支持
    kmod tzdata tar && \
    # XRING-O3: DRM/GPU 诊断基础包（Mesa/Mali stack 由 device profile 安装）
    pacman -S --noconfirm --needed libdrm vulkan-tools mesa-utils zstd diffutils && \
    # XRING-O3 设备脚本：固定 commit 拉取，避免 builder 与复刻包各存一份。
    git init -q /tmp/xring-o3-kit && \
    git -C /tmp/xring-o3-kit remote add origin "$XRING_O3_KIT_REPO" && \
    git -C /tmp/xring-o3-kit fetch -q --depth=1 origin "$XRING_O3_KIT_REF" && \
    git -C /tmp/xring-o3-kit checkout -q --detach FETCH_HEAD && \
    install -d -m 0755 /usr/local/lib/droidspaces/device && \
    cp -a /tmp/xring-o3-kit/rootfs/device/xring-o3 /usr/local/lib/droidspaces/device/ && \
    install -d -m 0755 /usr/local/share/droidspaces/noctalia-plugins && \
    cp -a /tmp/xring-o3-kit/src/noctalia-mali-gpu /usr/local/share/droidspaces/noctalia-plugins/ && \
    rm -rf /tmp/xring-o3-kit && \
    chmod +x /usr/local/lib/droidspaces/device/xring-o3/*.sh && \
    /usr/local/lib/droidspaces/device/xring-o3/profile.sh --install && \
    /usr/local/sbin/install-desktop "$DESKTOP" && \
    #输入法 fcitx5 (可选)
    if [ "$ENABLE_srf_ARG" = "true" ]; then \
        pacman -S --noconfirm --needed fcitx5-im; \
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
    fi

# 启用 Anland 时从固定滚动 GitHub Release 安装对应桌面的 ARM64 包。
RUN if [ "$DISPLAY_BACKEND" = "anland-wayland" ]; then \
        echo "--> [enabled] Installing Anland $DESKTOP packages (${ANLAND_PACKAGE_REVISION})..." && \
        ANLAND_RELEASE_REPOSITORY="$ANLAND_RELEASE_REPOSITORY" \
        ANLAND_NIRI_RELEASE_REPOSITORY="$ANLAND_RELEASE_REPOSITORY" \
        /usr/local/sbin/install-anland-desktop "$DESKTOP" --1 && \
        echo "--> [enabled] Anland $DESKTOP support installed"; \
    fi

# 本镜像的合成器二进制名是 niri-anland；大量工具（mark-shot 的窗口识别、
# 用户脚本里的 `niri msg`）按 `niri` 探测。别名必须在这里创建：
# install-desktop 阶段 niri-anland 尚未安装，那时创建会静默跳过。
RUN if [ -x /usr/bin/niri-anland ] && [ ! -e /usr/local/bin/niri ]; then \
        ln -s /usr/bin/niri-anland /usr/local/bin/niri; \
    fi

# 配置 Locale 与 SSH
# 只写 LANG，不写 LC_ALL：LC_ALL 会压掉单项分类（如 LC_TIME），与文档 02 的约定冲突。
RUN echo "en_US.UTF-8 UTF-8" > /etc/locale.gen && \
    if [ "$ENABLE_zh_tz_ARG" = "true" ]; then \
        ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime && \
        echo "zh_CN.UTF-8 UTF-8" >> /etc/locale.gen && \
        locale-gen && \
        echo "LANG=zh_CN.UTF-8" > /etc/locale.conf; \
    else \
        locale-gen && \
        echo "LANG=en_US.UTF-8" > /etc/locale.conf; \
    fi && \
    # 配置 SSH 服务（禁用 root 密码登录，但允许常规密码认证）
    mkdir -p /var/run/sshd && \
    ssh-keygen -A && \
    sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config && \
    sed -i 's/#PasswordAuthentication yes/PasswordAuthentication yes/' /etc/ssh/sshd_config && \
    # 如果容器内存在默认的 alarm 或 arch 用户，则清理
    (userdel -r alarm 2>/dev/null || true) && \
    useradd -m -s /bin/bash ${USERNAME} && echo "${USERNAME}:1234" | chpasswd && \
    systemctl enable sshd

# desktop-session.service 硬编码 User=1000：用户名可配，但 uid 必须是 1000。
RUN [ "$(id -u "${USERNAME}")" = "1000" ] || { \
        echo "ERROR: ${USERNAME} 的 uid 不是 1000，desktop-session.service 将无法启动" >&2; \
        exit 1; \
    }

# 为所有 Arch RootFS 安装 Droidspaces USB Manager
RUN /usr/local/sbin/install-droidspaces-usb-manager --user "${USERNAME}"

# 为 droidspaces 的 su/su -l 入口建立完整的 systemd 用户会话。
RUN for pam_file in /etc/pam.d/su /etc/pam.d/su-l; do \
        if ! grep -qE '^[[:space:]-]*session[[:space:]].*pam_systemd\.so' "$pam_file"; then \
            sed -i '/^[[:space:]]*session[[:space:]].*pam_unix\.so/a\session        optional        pam_systemd.so' "$pam_file"; \
        fi; \
    done && \
    grep -qE '^[[:space:]]*session[[:space:]].*pam_env\.so' /etc/pam.d/su-l || \
        echo 'session        required        pam_env.so' >> /etc/pam.d/su-l

# 初始化环境变量文件；桌面专属变量由对应 profile 管理。
RUN : > /etc/environment
# 音频选择
RUN if [ "$PulseAudio" = "socket" ]; then \
        echo "PULSE_SERVER=unix:/tmp/.pulse-socket" >> /etc/environment; \
    elif [ "$PulseAudio" = "tcp" ]; then \
        echo "PULSE_SERVER=tcp:127.0.0.1:4713" >> /etc/environment; \
    fi

# XRING-O3: GPU 环境全部由设备档案 xring-o3/profile.sh 在 configure-desktop 阶段
# 写入，这里不保存任何厂商专属变量。

# 输入法与桌面会话配置
COPY scripts/start/ /tmp/droidspaces-start/
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
XMODIFIERS=@im=fcitx
INPUT_METHOD=fcitx
EOF
fi
    echo 'export XDG_RUNTIME_DIR=/run/user/$(id -u)' >> /home/${USERNAME}/.bashrc
    OUTPUT_SCALE="${OUTPUT_SCALE}" OUTPUT_MODE="${OUTPUT_MODE}" \
        /usr/local/sbin/configure-desktop "$DESKTOP" "$DISPLAY_BACKEND" "$DESKTOP_AUTOSTART" "$USERNAME"
    rm -rf /tmp/droidspaces-start
EOF_RUN

# 安装 XRING-O3 Mali stack。bundle 尚未发布时必须硬失败；不要用占位目录。
RUN if [ "$ENABLE_mesa_ARG" = "true" ]; then \
        /usr/local/lib/droidspaces/device/xring-o3/install-mali-stack.sh; \
    else \
        echo "--> [跳过] 未开启 XRING-O3 Mali stack 安装"; \
    fi

# 零拷贝兼容层（bundle 侧修好后可删）：
# 1) libgbm 垫片的 init_real 把真实库路径写死为 /opt/mesa-kopper-retire-42194036783/...，
#    bundle 只带垫片本身、不带 Mesa 的 libgbm，于是 gbm_create_device 返回 NULL，
#    Chromium 报 "Failed to initialize gbm device" 并退回 wl_shm。这里用系统 Mesa 的
#    libgbm 补上该路径（实测可建 device，且能触发 zink→MaliBridge）。
# 2) zc-run 默认从 /opt/zc/current/conf/zc-env.conf 读配置；镜像里只有
#    /opt/mali-stack/current，配置读不到时会回落到硬编码旧路径导致 EGL 全挂。
RUN mkdir -p /opt/gbm-spike /opt/zc /opt/mesa-kopper-retire-42194036783/candidate/usr/lib && \
    if [ ! -e /opt/mesa-kopper-retire-42194036783/candidate/usr/lib/libgbm.so.1.0.0 ]; then \
        ln -sf /usr/lib/libgbm.so.1.0.0 \
            /opt/mesa-kopper-retire-42194036783/candidate/usr/lib/libgbm.so.1.0.0; \
    fi && \
    { [ -e /opt/zc/current ] || ln -sfn /opt/mali-stack/current /opt/zc/current; } && \
    touch /opt/gbm-spike/shim.log && chmod 666 /opt/gbm-spike/shim.log

# chromium 类（Chrome / Electron / CEF）的会话隔离层。
# zc-run 只 prepend LD_LIBRARY_PATH、不清继承值，而 niri 会话全局带着 kopper 的
# mesa 路径；从桌面启动时 libEGL 会命中 kopper 26.3 并在 dri2_setup_screen 空指针
# 崩溃（GPU exit 11）。这里在入口处把 chromium 类收敛到发行版 Mesa + LINEAR shim
# + DRM_RENDER，其余 class 原样透传给真正的 zc-run。
#
# 注意 zc-run 在镜像里是软链（/usr/local/bin/zc-run -> /opt/mali-stack/current/bin/zc-run）。
# 直接 `cat > /usr/local/bin/zc-run` 会顺着软链覆盖真正的二进制，包装器再 exec
# 自己形成无限递归。这里把真身复制成 .real、再替换软链为包装器；真身保持原位，
# 这样 mali-stack 升级重新生成软链时也不会指向不存在的文件。
RUN <<'EOF_ZCRUN'
set -eu
link=/usr/local/bin/zc-run
if [ -L "$link" ]; then
    target=$(readlink -f "$link")
    [ -e "$target.real" ] || cp -a "$target" "$target.real"
    rm -f "$link"
elif [ -f "$link" ]; then
    [ -e "$link.real" ] || cp -a "$link" "$link.real"
fi
cat > "$link" <<'EOF'
#!/bin/sh
# 由镜像生成（详见 Arch.Dockerfile）：chromium 类的 Mesa/EGL 收敛。
# 真身优先 .real（构建时改名而来）；Mali stack 升级后新版本没有 .real，
# 就退回 current/bin/zc-run，包装器行为自动降级为透传而不报错。
REAL=
for candidate in /usr/local/bin/zc-run.real \
                 /opt/mali-stack/current/bin/zc-run.real \
                 /opt/mali-stack/current/bin/zc-run; do
    if [ -x "$candidate" ]; then REAL=$candidate; break; fi
done
[ -n "$REAL" ] || { echo "zc-run: 找不到底层实现" >&2; exit 127; }
cls=${ZC_RUN_CLASS:-}
prev=
for a in "$@"; do
    [ "$prev" = "--class" ] && cls=$a
    case "$a" in --class=*) cls=${a#--class=} ;; esac
    prev=$a
done
# 没显式 --class 时按 zc-classify 的判定走同一收敛：Electron/CEF 这类应用
# 通常由分类器识别为 chromium，用户不会也不该手动补 --class。
if [ -z "$cls" ]; then
    classifier=${ZC_CLASSIFY:-/opt/mali-stack/current/lib/zc-run/zc-classify}
    [ -x "$classifier" ] && cls=$("$classifier" "$@" 2>/dev/null) || cls=
fi
if [ "$cls" = chromium ]; then
    ZC_MESA_DIR=/usr
    ZC_EGL_VENDOR_JSON=/usr/share/glvnd/egl_vendor.d/50_mesa.json
    VKBRIDGE_DRM_RENDER=226:0
    LD_LIBRARY_PATH=/usr/lib
    export ZC_MESA_DIR ZC_EGL_VENDOR_JSON VKBRIDGE_DRM_RENDER LD_LIBRARY_PATH
    # niri 会给每个 spawn 的应用注入 DISPLAY，但容器里的 Xwayland 可能挂死：
    # socket 能 connect、邮件永不响应，Chrome 卡在 xdg_surface.configure 之后
    # 不 ack、不 attach，最终没有窗口也没有 dmabuf。Chrome/Electron 走 Wayland
    # 时不需要 DISPLAY，清掉可稳定恢复零拷贝（实测 create_immed=3）。
    unset DISPLAY
fi
if [ "$cls" = webkit ]; then
    # WebKitGTK（含 Tauri / WebView 应用）的 web 进程在容器里起不来：
    #   bwrap: setting up uid map: No such file or directory
    # 容器不允许 user namespace，沙箱初始化失败后 web 进程退出，表现为
    # “Tauri 应用白屏/打不开”。禁用沙箱后实测走 dmabuf 零拷贝：
    # create_immed=8、无 wl_shm 池。
    export WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1
    # 与 chromium 同理：niri 注入的 DISPLAY 可能指向挂死的 Xwayland。
    unset DISPLAY
fi
exec "$REAL" "$@"
EOF
chmod 0755 "$link"
EOF_ZCRUN

# mb-tray 已废弃：预算显示和调整由 Noctalia GPU 插件接管，镜像不再安装或
# 自启动托盘。Mali 栈安装器仍会建立 /usr/local/bin/mb-tray 与桌面项，这里删除。
RUN rm -f /usr/local/bin/mb-tray /usr/share/applications/mb-tray.desktop /usr/share/icons/hicolor/*/apps/mb-budget.*

# 设备节点与 Anland socket 的容器侧准备；构建阶段只安装 unit，不创建设备节点。
RUN /usr/local/lib/droidspaces/device/xring-o3/card0.sh --install && \
    /usr/local/lib/droidspaces/device/xring-o3/anland.sh --install

# 安装并配置原生 ARM64 Google Chrome。
RUN /usr/local/sbin/configure-chrome "$DESKTOP" "$DISPLAY_BACKEND"

# 安装 AUR mark-shot-arch-bin（Arch/ALARM 双架构预编译包）：依赖对齐 FFmpeg 9，
# 自带 libmark-shot-layer-shell.so，无需本地编译或 soname 旁路。
RUN /usr/local/sbin/configure-mark-shot "$DESKTOP" "$DISPLAY_BACKEND"

# 修正构建阶段已安装的 Chromium/Electron sandbox helper 权限；用户后续安装
# 由 pacman PostTransaction 钩子（90-chrome-sandbox.hook）自动处理。
RUN /usr/local/bin/fix-chrome-sandbox

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

# 确保 Arch 赋予 sudo 权限给 wheel 组
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

# 限制特定的网络服务
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

# 注入 binfmt 服务脚本
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
        pacman -S --noconfirm --needed qemu-user qemu-user-binfmt && \
        rm -rf /var/cache/pacman/pkg/* /var/lib/pacman/sync/* ; \
    else \
        rm -f /usr/local/bin/qemu-binfmt-register.sh /etc/systemd/system/qemu-binfmt-register.service; \
    fi

# 可选：为 systemd 258+ 发行版构建 systemd 257 旧内核兼容运行时。
RUN if [ "$ENABLE_systemd257_ARG" = "true" ]; then \
        bash /usr/local/sbin/systemd257; \
    else \
        echo "--> [跳过] 未启用 systemd 257 旧内核兼容"; \
    fi

# 彻底清理 pacman 缓存
# 打包前删除仅用于构建的一次性脚本；TUI 和运行时脚本保留。
RUN rm -f \
        /usr/local/sbin/configure-chrome \
        /usr/local/sbin/configure-mark-shot \
        \
        /usr/local/sbin/configure-desktop \
        /usr/local/sbin/install-desktop \
        /usr/local/sbin/install-anland-desktop \
        /usr/local/sbin/install-droidspaces-usb-manager \
        /usr/local/sbin/systemd257 \
        /usr/local/sbin/nosnap && \
    rm -rf /usr/local/lib/droidspaces/desktops && \
    rm -rf /var/cache/pacman/pkg/* /var/lib/pacman/sync/*
# 最终阶段：应用桌面偏好设置（默认关闭；由工作流或构建脚本通过构建参数开启）
COPY scripts/preferences/ /usr/local/lib/droidspaces/preferences/
RUN APPLY_PREFERENCES="${APPLY_PREFERENCES}" \
    PREFERENCES_PROFILE="${PREFERENCES_PROFILE}" \
    PREFERENCES_STRICT="${PREFERENCES_STRICT}" \
    sh /usr/local/lib/droidspaces/preferences/apply-preferences.sh

# 阶段 2：将完整的根文件系统导出到 scratch（空白层），以便外部直接提取或打包成 tarfs
FROM scratch AS export
COPY --from=customizer / /
