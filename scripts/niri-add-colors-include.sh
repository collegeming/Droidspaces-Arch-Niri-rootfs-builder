#!/bin/bash
# Append (or repair) the Noctalia colors.kdl include at the end of niri's config.kdl.
# niri requires a quoted include path; the include must come last so the
# wallpaper-driven Material You values override the hard-coded ones above.
set -euo pipefail

CFG="${1:-/home/colle/.config/niri/config.kdl}"
LINE='include optional=true "colors.kdl"'

grep -vE '^include optional=true "?colors\.kdl"?[[:space:]]*$' "$CFG" > "$CFG.tmp"
printf '\n// Noctalia 壁纸驱动配色（Material You）。放在文件末尾，让动态色覆盖上面写死的值。\n%s\n' "$LINE" >> "$CFG.tmp"
mv "$CFG.tmp" "$CFG"
chmod 600 "$CFG"

tail -4 "$CFG"
