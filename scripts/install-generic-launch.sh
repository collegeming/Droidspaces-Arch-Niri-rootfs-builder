#!/usr/bin/env bash
# Install the generic zc-launch layer into the image.
#
# Noctalia passes every launch through launch_apps_custom_command; zc-launch
# classifies Chromium/Electron, WebKit and Gecko apps and wraps them with the
# existing zc-run.  zc-desktop-normalize is a safety net for launches outside
# Noctalia.  Both are no-ops for native/unknown apps and for entries that
# already use zc-run or a per-app wrapper.
set -euo pipefail

install -m 0755 /tmp/zc-launch /usr/local/bin/zc-launch
install -m 0755 /tmp/zc-desktop-normalize.py /usr/local/bin/zc-desktop-normalize
install -Dm0644 /tmp/98-zc-desktop-normalize.hook /etc/pacman.d/hooks/98-zc-desktop-normalize.hook

# Magpie 每次启动会把自己真实可执行文件的路径写回用户级 desktop 条目，
# 因此那条 Exec 行无法靠一次性改写保住。装一个守护脚本，由桌面会话在启动
# 时把用户条目恢复成指向 zc-run 的规范文件；未安装 Magpie 的镜像里它不做
# 任何事。
if [ -f /tmp/fix-magpie-user-desktop.sh ]; then
    install -m 0755 /tmp/fix-magpie-user-desktop.sh /usr/local/bin/fix-magpie-user-desktop
fi

if ! command -v python3 >/dev/null 2>&1; then
    pacman -Sy --noconfirm --needed python
fi

# Ensure the Noctalia launch boundary even when APPLY_PREFERENCES is false.
# The preferences asset already carries the same key; this is idempotent.
user=${USERNAME:-colle}
noctalia_cfg=/home/$user/.config/noctalia/config.toml
if [ -f "$noctalia_cfg" ]; then
    if ! grep -q '^launch_apps_custom_command' "$noctalia_cfg"; then
        grep -q '^\[shell\]' "$noctalia_cfg" || printf '\n[shell]\n' >>"$noctalia_cfg"
        sed -i '/^\[shell\]/a launch_apps_custom_command = "/usr/local/bin/zc-launch $CMD"' "$noctalia_cfg"
    fi
    chown "$user" "$noctalia_cfg" 2>/dev/null || true
fi

# The Mali stack and all desktop packages are installed by this point.
/usr/local/bin/zc-desktop-normalize --apply --no-backup || true

rm -f /tmp/zc-launch /tmp/zc-desktop-normalize.py \
    /tmp/98-zc-desktop-normalize.hook /tmp/install-generic-launch.sh \
    /tmp/fix-magpie-user-desktop.sh
rm -rf /var/cache/pacman/pkg/* /var/lib/pacman/sync/*
echo "generic launch layer installed"
