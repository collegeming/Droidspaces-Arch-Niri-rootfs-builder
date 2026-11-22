#!/bin/bash
# Magpie rewrites its own user-level desktop entry with its real executable
# path on every start (it writes the argv[0] it was launched with).  Any
# "patch the Exec line" fix is undone the next time the app runs, so the
# user-level files cannot be trusted to carry zc-run.
#
# Layout used here:
#   /usr/local/share/droidspaces/magpie/*.desktop   canonical, root-owned
#   ~/.local/share/applications/magpie*.desktop     symlinks to the above
#
# A symlink cannot be opened for writing by the desktop user (verified:
# append and truncate both fail with EACCES), which blocks magpie's rewrite.
# Magpie could still unlink and recreate a plain file; `--ensure` restores the
# symlinks and is cheap enough to run at session start.
#
# Usage:
#   fix-magpie-user-desktop            install canonical entries + symlinks (root)
#   fix-magpie-user-desktop --ensure   only restore symlinks (any user)
set -uo pipefail

CANON_DIR=/usr/local/share/droidspaces/magpie

user_dir() {
    printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/../.local/share/applications" | sed 's|/.config/../|/|'
}

ensure_symlinks() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    local f
    for f in magpie.desktop magpie-ccswitch.desktop; do
        [ -f "$CANON_DIR/$f" ] || continue
        if [ -L "$dir/$f" ]; then
            continue
        fi
        if [ -e "$dir/$f" ]; then
            # The app replaced the symlink with a plain file. Move it aside so
            # the original content is not lost, then relink.
            mv -f "$dir/$f" "$dir/$f.magpie-rewrite.bak" 2>/dev/null || continue
        fi
        ln -s "$CANON_DIR/$f" "$dir/$f" 2>/dev/null || true
    done
}

mode="${1:-install}"

if [ "$mode" = "--ensure" ]; then
    ensure_symlinks "$HOME/.local/share/applications"
    exit 0
fi

if [ "$(id -u)" != 0 ]; then
    echo "install mode needs root" >&2
    exit 1
fi

install -d -m 0755 "$CANON_DIR"

cat >"$CANON_DIR/magpie.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=magpie
Comment=Every agent's model. One place.
Exec=/usr/local/bin/zc-run --class webkit /usr/bin/magpie.real app %u
Icon=magpie
StartupWMClass=magpie
Categories=Development;Utility;
MimeType=x-scheme-handler/magpie;
Terminal=false
EOF

cat >"$CANON_DIR/magpie-ccswitch.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=magpie (ccswitch:// links)
Exec=/usr/local/bin/zc-launch /usr/bin/magpie.real %u
NoDisplay=true
MimeType=x-scheme-handler/ccswitch;
Terminal=false
EOF

chmod 0644 "$CANON_DIR"/*.desktop
chown root:root "$CANON_DIR"/*.desktop

TARGET_USER="${MAGPIE_USER:-colle}"
TARGET_HOME=$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f6)
[ -n "${TARGET_HOME:-}" ] || TARGET_HOME=/home/$TARGET_USER
TARGET_DIR="$TARGET_HOME/.local/share/applications"
install -d -m 0755 -o "$TARGET_USER" -g "$TARGET_USER" "$TARGET_DIR" 2>/dev/null \
    || install -d -m 0755 "$TARGET_DIR"
ensure_symlinks "$TARGET_DIR"

echo "canonical entries:"
grep -H '^Exec' "$CANON_DIR"/*.desktop
echo
echo "user entries:"
ls -la "$TARGET_DIR"/magpie*.desktop 2>/dev/null || true
echo
echo "system entry:"
grep -H '^Exec' /usr/share/applications/magpie.desktop 2>/dev/null || true
