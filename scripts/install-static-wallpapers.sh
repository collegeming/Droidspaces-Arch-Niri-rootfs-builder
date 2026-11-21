#!/bin/bash
# Install static wallpapers from ech678/wallpaper-collection into the user's
# XDG Pictures/Wallpapers directory. Video wallpapers are intentionally skipped.
set -uo pipefail

TARGET="${TARGET:-/home/colle/图片/Wallpapers}"
TMP=/tmp/wp-clone.$$
REPOS=(
    "https://github.com/ech678/wallpaper-collection.git"
    "https://gh-proxy.org/https://github.com/ech678/wallpaper-collection.git"
)

mkdir -p "$TARGET" || exit 1

if [ -n "${SKIP_CLONE:-}" ] && [ -d /tmp/wp-src ]; then
    SRC=/tmp/wp-src
else
    ok=0
    for repo in "${REPOS[@]}"; do
        rm -rf "$TMP"
        echo "clone: $repo"
        if git clone --depth 1 "$repo" "$TMP" 2>&1 | tail -3; then
            ok=1
            break
        fi
    done
    [ "$ok" = 1 ] || { echo "clone failed"; exit 1; }
    SRC=$TMP
fi

echo "=== static files found ==="
find "$SRC" -maxdepth 1 -type f \( -iname '*.webp' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) | wc -l

copied=0
skipped=0
while IFS= read -r -d '' f; do
    base=$(basename "$f")
    if [ -e "$TARGET/$base" ]; then
        skipped=$((skipped + 1))
        continue
    fi
    cp -p "$f" "$TARGET/$base" || { echo "copy failed: $base"; continue; }
    copied=$((copied + 1))
done < <(find "$SRC" -maxdepth 1 -type f \( -iname '*.webp' -o -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' \) -print0)

echo "copied=$copied skipped=$skipped"
echo "=== target inventory ==="
find "$TARGET" -maxdepth 1 -type f -printf '%f\n' | sort
echo "=== target size ==="
du -sh "$TARGET"

if [ -z "${SKIP_CLONE:-}" ]; then
    rm -rf "$TMP"
fi
