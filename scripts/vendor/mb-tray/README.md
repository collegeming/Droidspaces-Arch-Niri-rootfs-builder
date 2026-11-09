# mb-tray（本地化版本）

- 上游：`collegeming/xring-o3-droidspaces-package`，`src/mb-tray/mb-tray.c`，
  固定 commit `c71d58e598a3a38d399f583da1a3cc1aebbbc691`。
- 许可证：GPL-3.0-or-later（文件头 SPDX 保留）。
- 改动：仅新增 `mb_use_zh()` / `mb_tr()`，把 `label_for()` 与
  `tooltip_subtitle()` 里的用户可见文案按 `LC_ALL`/`LC_MESSAGES`/`LANG`
  是否含 `zh` 在中文与英文之间切换；逻辑、D-Bus 接口、图标名不变。
- 由 `scripts/configure-mb-tray.sh` 在镜像构建时编译并安装到
  `/usr/local/bin/mb-tray`。
