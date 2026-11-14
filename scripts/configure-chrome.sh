#!/usr/bin/env bash
set -euo pipefail

desktop="${1:-}"
display_backend="${2:-}"
rootfs="${ROOTFS_DIR:-}"
chrome_binary="${rootfs}/opt/google/chrome/google-chrome"
wrapper_dir="${rootfs}/usr/local/bin"
wrapper="${wrapper_dir}/google-chrome"

[[ -n "$desktop" ]] || {
    echo "必须指定桌面配置" >&2
    exit 1
}

case "$display_backend" in
    x11|anland-wayland) ;;
    *)
        echo "无效的 Chrome 显示后端：$display_backend" >&2
        exit 1
        ;;
esac

[[ "$desktop" == none ]] && exit 0

install_debian_chrome() {
    install -d -m 0755 /etc/apt/keyrings /etc/apt/sources.list.d
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
        -o /etc/apt/keyrings/google-chrome.asc
    grep -q 'BEGIN PGP PUBLIC KEY BLOCK' /etc/apt/keyrings/google-chrome.asc
    printf 'deb [arch=arm64 signed-by=/etc/apt/keyrings/google-chrome.asc] https://dl.google.com/linux/chrome/deb/ stable main\n' \
        > /etc/apt/sources.list.d/google-chrome.list
    apt-get update
    apt-get install -y --no-install-recommends google-chrome-stable
}

install_fedora_chrome() {
    install -d -m 0755 /etc/pki/rpm-gpg /etc/yum.repos.d
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub \
        -o /etc/pki/rpm-gpg/RPM-GPG-KEY-google-chrome
    grep -q 'BEGIN PGP PUBLIC KEY BLOCK' /etc/pki/rpm-gpg/RPM-GPG-KEY-google-chrome
    printf '%s\n' \
        '[google-chrome]' \
        'name=Google Chrome' \
        'baseurl=https://dl.google.com/linux/chrome/rpm/stable/$basearch' \
        'enabled=1' \
        'gpgcheck=1' \
        'repo_gpgcheck=0' \
        'gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-google-chrome' \
        > /etc/yum.repos.d/google-chrome.repo
    dnf install -y --setopt=install_weak_deps=False google-chrome-stable
}

install_arch_chrome() {
    : > /tmp/chrome-build-packages
    for package in $(pacman -Sgq base-devel); do
        if ! pacman -Qq "$package" >/dev/null 2>&1; then
            printf '%s\n' "$package" >> /tmp/chrome-build-packages
        fi
    done
    pacman -S --noconfirm --needed base-devel git
    useradd --system --create-home --home-dir /tmp/chrome-build --shell /bin/bash chrome-build
    runuser -u chrome-build -- git clone --depth=1 \
        https://aur.archlinux.org/google-chrome.git /tmp/chrome-build/google-chrome
    grep -Eq '^[[:space:]]*arch = aarch64$' /tmp/chrome-build/google-chrome/.SRCINFO
    grep -Eq '^[[:space:]]*source_aarch64 = https://dl\.google\.com/linux/chrome/deb/.+_arm64\.deb$' \
        /tmp/chrome-build/google-chrome/.SRCINFO
    grep -Eq '^[[:space:]]*sha512sums_aarch64 = [0-9a-fA-F]{128}$' \
        /tmp/chrome-build/google-chrome/.SRCINFO
    CHROME_DEPENDENCIES="$(sed -n 's/^[[:space:]]*depends = //p' \
        /tmp/chrome-build/google-chrome/.SRCINFO | sed 's/[<>=].*$//' | sort -u)"
    [ -n "$CHROME_DEPENDENCIES" ]
    if printf '%s\n' "$CHROME_DEPENDENCIES" | grep -Eqv '^[A-Za-z0-9@._+][A-Za-z0-9@._+:-]*$'; then
        echo "AUR 配方包含无效的 Chrome 依赖" >&2
        exit 1
    fi
    pacman -S --noconfirm --needed --asdeps $CHROME_DEPENDENCIES
    runuser -u chrome-build -- bash -c \
        'cd "$1" && makepkg --cleanbuild --clean --noconfirm' _ \
        /tmp/chrome-build/google-chrome
    CHROME_PACKAGE="$(find /tmp/chrome-build/google-chrome -maxdepth 1 \
        -type f -name 'google-chrome-*.pkg.tar.*' ! -name '*.sig' -print -quit)"
    [ -n "$CHROME_PACKAGE" ]
    [ "$(find /tmp/chrome-build/google-chrome -maxdepth 1 \
        -type f -name 'google-chrome-*.pkg.tar.*' ! -name '*.sig' -print | wc -l)" -eq 1 ]
    sed -e '/^[[:space:]]*LocalFileSigLevel[[:space:]]*=/d' \
        -e '/^\[options\][[:space:]]*$/a LocalFileSigLevel = Optional' \
        /etc/pacman.conf > /tmp/pacman-chrome.conf
    [ "$(pacman --config /tmp/pacman-chrome.conf -Qqp "$CHROME_PACKAGE")" = "google-chrome" ]
    LC_ALL=C pacman --config /tmp/pacman-chrome.conf -Qip "$CHROME_PACKAGE" | \
        grep -Eq '^Architecture[[:space:]]*: aarch64$'
    pacman --config /tmp/pacman-chrome.conf -U --noconfirm "$CHROME_PACKAGE"
    userdel -r chrome-build
    if [ -s /tmp/chrome-build-packages ]; then
        pacman -Rns --noconfirm $(cat /tmp/chrome-build-packages)
    fi
    rm -f /tmp/chrome-build-packages /tmp/pacman-chrome.conf
}

install_chrome() {
    # ROOTFS_DIR 用于隔离测试；实际 RootFS 构建时为空。
    [[ -n "$rootfs" ]] && return 0

    # shellcheck disable=SC1091
    source /etc/os-release
    case "${ID:-}" in
        debian|ubuntu) install_debian_chrome ;;
        fedora) install_fedora_chrome ;;
        arch|archarm|archlinux) install_arch_chrome ;;
        *)
            echo "不支持的 Chrome 发行版：${ID:-unknown}" >&2
            exit 1
            ;;
    esac
}

install_chrome
[[ -x "$chrome_binary" ]] || {
    echo "Chrome 安装完成后未找到：$chrome_binary" >&2
    exit 1
}

[[ "$display_backend" == anland-wayland ]] || exit 0

install -d -m 0755 "$wrapper_dir"
# 与设备上验证过的包装器一致：GPU/零拷贝环境与 Chromium 参数由 zc-run 统一
# 注入，这里只补需要强制开启的 VA-API 特性，避免两处各写一份 GPU 变量。
#
# 2026-11-09 实测结论（create_immed=3、wl_shm 仅光标池、GPU crash=0）：
# - EGL 必须用发行版 Mesa：候选 kopper 26.3 的 GBM 初始化在无 DRM 属性时
#   在 dri2_setup_screen 解引用空指针，GPU 进程 exit 11。
# - GBM 必须用项目 shim：它把所有分配强制成 LINEAR；用系统 libgbm 时 Chrome
#   会拿 tiled/AFB 缓冲，桥接侧 dma-buf 导入被拒（INVALID_EXTERNAL_HANDLE）。
# - VKBRIDGE_DRM_RENDER 让 zink 在 GBM 路径按 226:0 匹配到唯一 pdev。
# - LD_LIBRARY_PATH 必须在这里收敛到 /usr/lib：zc-run 只 prepend 不清继承值，
#   而 niri 会话全局注入了 kopper 的 mesa 路径；从桌面启动时 libEGL 会命中
#   kopper 26.3 并复现 exit 11（手工干净 env 测不出来）。
cat > "$wrapper" <<'EOF'
#!/bin/sh
# Thin alias: GPU/zero-copy env and Chromium flags are owned by zc-run.
ZC_MESA_DIR=/usr
ZC_EGL_VENDOR_JSON=/usr/share/glvnd/egl_vendor.d/50_mesa.json
VKBRIDGE_DRM_RENDER=226:0
LD_LIBRARY_PATH=/usr/lib
export ZC_MESA_DIR ZC_EGL_VENDOR_JSON VKBRIDGE_DRM_RENDER LD_LIBRARY_PATH
# Audio: Chrome must not start before the Anland/PipeWire default sink exists.
# A session restart recreates the sink after niri starts; Chrome's audio service
# otherwise caches "no output device" until the browser is restarted. Wait up to
# 10 s and pin the Pulse socket to the session runtime directory.
: "${XDG_RUNTIME_DIR:=/run/user/$(id -u)}"
export PULSE_SERVER="${PULSE_SERVER:-unix:${XDG_RUNTIME_DIR}/pulse/native}"
_i=0
while [ "$_i" -lt 20 ]; do
    if command -v pactl >/dev/null 2>&1 \
        && pactl info >/dev/null 2>&1 \
        && pactl list short sinks 2>/dev/null | grep -q .; then
        break
    fi
    _i=$((_i + 1))
    sleep 0.5
done
# 2026-11-09 实测：niri 会给 spawn 的应用注入 DISPLAY，但容器里的 Xwayland 可能
# 挂死（socket 能 connect、X 握手永不响应）。Chrome 会在 xdg_surface.configure
# 之后不 ack、不 attach：没有窗口、没有 dmabuf，只剩光标 shm 池。Chrome 走
# Wayland 不需要 DISPLAY，清掉后稳定恢复 create_immed=3。
unset DISPLAY
exec /usr/local/bin/zc-run --class chromium /opt/google/chrome/google-chrome \
    --enable-features=VaapiVideoDecodeLinux,VaapiVideoDecoder,VaapiVideoDecodeLinuxGL \
    "$@"
EOF
chmod 0755 "$wrapper"
ln -sfn -- google-chrome "${wrapper_dir}/google-chrome-stable"

# DBX/WebKit 只在镜像里已经装了 DBX 时创建别名；没有 DBX 的构建继续成功。
if [[ -x "${rootfs}/usr/bin/dbx" ]]; then
    dbx_wrapper="${wrapper_dir}/dbx-dmabuf"
    cat > "$dbx_wrapper" <<'EOF'
#!/bin/sh
# Thin alias: zc-run webkit owns WEBKIT_*/libdrmfake/bridge env.
exec /usr/local/bin/zc-run --class webkit /usr/bin/dbx "$@"
EOF
    chmod 0755 "$dbx_wrapper"
else
    echo "--> [跳过] 未安装 DBX，不创建 dbx-dmabuf 别名"
fi

for desktop_file in \
    "${rootfs}/usr/share/applications/google-chrome.desktop" \
    "${rootfs}/usr/share/applications/com.google.Chrome.desktop"; do
    [[ -f "$desktop_file" ]] || continue

    temporary_file="$(mktemp "${desktop_file}.tmp.XXXXXXXX")"
    # 官方包与 AUR 包的 Exec 写法不同：/usr/bin/google-chrome(-stable) 与
    # /opt/google/chrome/google-chrome 都要改写，否则点图标会绕过 wrapper 直跑
    # kopper，复现 GPU exit 11。
    awk -v launcher="/usr/local/bin/google-chrome" '
        /^Exec=(\/usr\/bin\/google-chrome(-stable)?|\/opt\/google\/chrome\/google-chrome)([[:space:]]|$)/ {
            sub(/^Exec=(\/usr\/bin\/google-chrome(-stable)?|\/opt\/google\/chrome\/google-chrome)/, "Exec=" launcher)
        }
        /^TryExec=(\/usr\/bin\/google-chrome(-stable)?|\/opt\/google\/chrome\/google-chrome)([[:space:]]|$)/ {
            sub(/^TryExec=(\/usr\/bin\/google-chrome(-stable)?|\/opt\/google\/chrome\/google-chrome)/, "TryExec=" launcher)
        }
        { print }
    ' "$desktop_file" > "$temporary_file"
    chmod 0644 "$temporary_file"
    mv -f -- "$temporary_file" "$desktop_file"
done
