#!/bin/bash

export DEBIAN_FRONTEND=noninteractive

if [ "$EUID" -ne 0 ]; then
  echo "请用 root 运行：sudo bash nosnap.sh"
  exit 1
fi

echo "[nosnap] stopping snapd services"
if command -v systemctl >/dev/null 2>&1; then
  for unit in snapd.service snapd.socket snapd.seeded.service snapd.apparmor.service; do
    systemctl stop "$unit" >/dev/null 2>&1 || true
    systemctl disable "$unit" >/dev/null 2>&1 || true
  done
fi

echo "[nosnap] unmounting snap mounts"
if command -v mount >/dev/null 2>&1 && command -v umount >/dev/null 2>&1; then
  for mountpoint in $(mount | awk '$3 ~ "^/snap" || $3 ~ "^/var/snap" || $3 ~ "^/var/lib/snapd" { print $3 }' | sort -r); do
    umount -lf "$mountpoint" >/dev/null 2>&1 || true
  done
fi

echo "[nosnap] purging snapd packages"
if command -v apt-get >/dev/null 2>&1 && command -v dpkg >/dev/null 2>&1; then
  for package in snapd gnome-software-plugin-snap snapd-desktop-integration plasma-discover-backend-snap; do
    if dpkg -s "$package" >/dev/null 2>&1; then
      apt-get purge -y "$package" >/dev/null 2>&1 || true
    fi
  done
  apt-get autoremove -y --purge >/dev/null 2>&1 || true
  apt-get clean >/dev/null 2>&1 || true
fi

echo "[nosnap] removing snap leftovers"
rm -rf \
  /snap \
  /var/snap \
  /var/lib/snapd \
  /var/cache/snapd \
  /usr/lib/snapd \
  /etc/systemd/system/snapd* \
  /etc/apt/apt.conf.d/*snap* \
  "$HOME/snap" \
  /home/*/snap

echo "[nosnap] blocking snapd reinstall through apt"
mkdir -p /etc/apt/preferences.d
cat > /etc/apt/preferences.d/nosnap.pref <<'EOF'
Package: snapd snapd-desktop-integration gnome-software-plugin-snap plasma-discover-backend-snap
Pin: release a=*
Pin-Priority: -10

Package: *
Pin: version *snap*
Pin-Priority: -10
EOF

if [ ! -f /etc/apt/preferences.d/nosnap.pref ]; then
  echo "[nosnap] failed to write apt pin"
  exit 1
fi

echo "[nosnap] adding ppa:xtradeb/apps"
xtradeb_codename=""
if [ -r /etc/os-release ]; then
  . /etc/os-release
  xtradeb_codename="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
fi

if [ -n "$xtradeb_codename" ]; then
  xtradeb_key=""
  xtradeb_release_ok="false"
  xtradeb_api="https://api.launchpad.net/1.0/~xtradeb/+archive/ubuntu/apps"
  xtradeb_release="https://ppa.launchpadcontent.net/xtradeb/apps/ubuntu/dists/${xtradeb_codename}/Release"

  if command -v curl >/dev/null 2>&1; then
    xtradeb_key="$(curl -fsSL "$xtradeb_api" 2>/dev/null | awk -F'"' '/signing_key_fingerprint/ { print $4; exit }')"
    curl -fsSL "$xtradeb_release" >/dev/null 2>&1 && xtradeb_release_ok="true"
  elif command -v wget >/dev/null 2>&1; then
    xtradeb_key="$(wget -qO- "$xtradeb_api" 2>/dev/null | awk -F'"' '/signing_key_fingerprint/ { print $4; exit }')"
    wget -qO- "$xtradeb_release" >/dev/null 2>&1 && xtradeb_release_ok="true"
  fi

  if [ "$xtradeb_release_ok" = "true" ] && [ -n "$xtradeb_key" ]; then
    mkdir -p /etc/apt/keyrings /etc/apt/sources.list.d
    if command -v curl >/dev/null 2>&1; then
      curl -fsSL "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${xtradeb_key}" > /etc/apt/keyrings/xtradeb-apps.asc 2>/dev/null || rm -f /etc/apt/keyrings/xtradeb-apps.asc
    elif command -v wget >/dev/null 2>&1; then
      wget -qO /etc/apt/keyrings/xtradeb-apps.asc "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${xtradeb_key}" 2>/dev/null || rm -f /etc/apt/keyrings/xtradeb-apps.asc
    fi

    if [ -s /etc/apt/keyrings/xtradeb-apps.asc ]; then
      chmod 0644 /etc/apt/keyrings/xtradeb-apps.asc
      echo "deb [signed-by=/etc/apt/keyrings/xtradeb-apps.asc] https://ppa.launchpadcontent.net/xtradeb/apps/ubuntu ${xtradeb_codename} main" > /etc/apt/sources.list.d/xtradeb-apps.list
    else
      echo "[nosnap] failed to fetch xtradeb signing key, skipped ppa:xtradeb/apps"
    fi
  else
    echo "[nosnap] ppa:xtradeb/apps does not support ${xtradeb_codename} or network is unavailable, skipped"
  fi
else
  echo "[nosnap] unable to detect Ubuntu codename, skipped ppa:xtradeb/apps"
fi

echo "[nosnap] done"
