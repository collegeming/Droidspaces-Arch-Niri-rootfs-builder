#!/usr/bin/env bash
# Install the Nyxuri-derived Material You template pool into the built rootfs.
#
# The templates live in the image so a fresh container can render a
# wallpaper-driven palette without extra downloads. Nothing here writes to
# ~/.config: user files are untouched; the Noctalia registration snippet is
# left in /usr/local/share/droidspaces/themes/ for the user (or a later
# preference step) to copy into ~/.config/noctalia/.
set -euo pipefail

USERNAME="${USERNAME:-colle}"

TPL_DIR=/usr/local/share/droidspaces/themes/templates
CONF_DIR=/usr/local/share/droidspaces/themes

install -d -m 0755 "$TPL_DIR" "$CONF_DIR"

for f in gtk-3.0.css gtk-4.0.css niri-glow-material-you.kdl palette.toml; do
    install -m 0644 "/tmp/nyxuri-templates/$f" "$TPL_DIR/$f"
done

install -m 0644 /tmp/noctalia-theme-dynamic.toml "$CONF_DIR/noctalia-theme-dynamic.toml"

# 帮助脚本：安装壁纸、接上 niri 的 colors.kdl include、验证联动。
install -m 0755 /tmp/install-static-wallpapers.sh "$CONF_DIR/install-static-wallpapers.sh"
install -m 0755 /tmp/niri-add-colors-include.sh "$CONF_DIR/niri-add-colors-include.sh"

# 模板里的输出路径与用户名相关，安装时按构建用户改写。
if [ "$USERNAME" != "colle" ]; then
    sed -i "s|/home/colle|/home/$USERNAME|g" \
        "$CONF_DIR/noctalia-theme-dynamic.toml" "$CONF_DIR/install-static-wallpapers.sh"
fi

cat >"$CONF_DIR/README.txt" <<'EOF'
Material You 动态取色（Nyxuri 模板移植）

1. 模板池：templates/ 下的 4 个文件，Noctalia 渲染时读取。
2. 注册：把 noctalia-theme-dynamic.toml 复制或合并到 ~/.config/noctalia/，
   把其中的 /home/colle 换成实际用户名（镜像已按构建用户预改写）。
3. niri：在 ~/.config/niri/config.kdl 末尾加
   include optional=true "colors.kdl"
4. 壁纸：bash install-static-wallpapers.sh 把 ech678/wallpaper-collection
   的静态壁纸装到 ~/图片/Wallpapers（不含 video/）。
5. 切换：noctalia msg wallpaper-set <图片路径>
EOF

echo "installed Material You templates into $TPL_DIR"
