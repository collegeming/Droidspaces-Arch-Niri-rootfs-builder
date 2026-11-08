#!/usr/bin/env bash
# Install the Zen Browser Linux ARM64 tarball into /opt/zen and register a
# zc-run based launcher. The version and digest are pinned; a mismatch aborts
# the image build.
set -euo pipefail

ZEN_VERSION="1.24.1b"
ZEN_SHA256="ac0fc39fd2342066027e56a42bdebfea910e9fdc539d02dd7d658e39c38e42dc"
ZEN_URL="https://github.com/zen-browser/desktop/releases/download/${ZEN_VERSION}/zen.linux-aarch64.tar.xz"
DEST=/opt/zen
TMP_TAR=$(mktemp /tmp/zen.XXXXXXXX.tar.xz)
TMP_DIR=$(mktemp -d /tmp/zen.XXXXXXXX)

cleanup() {
    rm -rf -- "$TMP_TAR" "$TMP_DIR"
}
trap cleanup EXIT

curl -fL --retry 3 --connect-timeout 20 -o "$TMP_TAR" "$ZEN_URL"
printf '%s  %s\n' "$ZEN_SHA256" "$TMP_TAR" | sha256sum -c -

tar -xJf "$TMP_TAR" -C "$TMP_DIR"
app_ini=$(find "$TMP_DIR" -maxdepth 3 -name application.ini -print -quit)
[[ -n "$app_ini" ]] || { echo "Zen tarball has no application.ini" >&2; exit 1; }
src_dir=$(dirname "$app_ini")

install -d -m 0755 "$DEST"
cp -a "$src_dir/." "$DEST/"

cat > /usr/local/bin/zen-browser <<'EOF'
#!/bin/sh
exec /usr/local/bin/zc-run --class gecko /opt/zen/zen "$@"
EOF
chmod 0755 /usr/local/bin/zen-browser

cat > /usr/share/applications/zen-browser.desktop <<'EOF'
[Desktop Entry]
Type=Application
Name=Zen Browser
Comment=Browse the web with Zen
Exec=/usr/local/bin/zen-browser %u
Icon=zen-browser
Terminal=false
Categories=Network;WebBrowser;
MimeType=text/html;text/xml;application/xhtml+xml;x-scheme-handler/http;x-scheme-handler/https;
StartupNotify=true
EOF

# Icon from the tarball, if present.
icon=$(find "$DEST" -maxdepth 3 -type f \( -name 'zen.png' -o -name 'default256.png' \) -print -quit || true)
if [[ -n "$icon" ]]; then
    install -D -m 0644 "$icon" /usr/share/icons/hicolor/256x256/apps/zen-browser.png
fi

echo "--> Zen Browser ${ZEN_VERSION} installed at ${DEST}"
