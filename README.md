# Droidspaces RootFS 自动构建（XRING-O3 定制）

通过 GitHub Actions 为 Android 上的 Droidspaces 构建 Linux ARM64 RootFS。本仓库 fork 自 [Goldzxcbug/Droidspaces-rootfs-Desktop-builder](https://github.com/Goldzxcbug/Droidspaces-rootfs-Desktop-builder)，默认分支 **`xring-o3-mali`**，在保留通用多发行版构建的同时，为 **小米平板 9 Pro Max（M367FC / XRing O3 / Android 17 / Mali-G2-Ultra-NX）** 增加 Arch + niri + Noctalia + MaliBridge 的设备档案。

配套宿主侧仓库：[collegeming/xring-o3-droidspaces-package](https://github.com/collegeming/xring-o3-droidspaces-package)（宿主脚本、KSU 模块、Mali 栈 bundle、niri-anland 包）。

## 1. 构建什么

一次构建产出一个可直接导入 Droidspaces 的 rootfs 归档（`Arch-niri-Wayland-Droidspaces-rootfs-aarch64-<时间>.tar.xz`，约 1.36 GB），内含：

| 层 | 内容 |
| --- | --- |
| 基础系统 | Arch Linux ARM64，用户 `colle`（uid 1000），中文 locale + 上海时区 |
| 桌面 | niri-anland（26.4 + Touch seat / Smithay AFBC 补丁，来自 xring 仓库的包）、Noctalia（GTK4 shell）、desktop-session（systemd 系统单元） |
| GPU | Mali 栈 bundle：Mesa 26.2.6（Zink）、MaliBridge ICD、wl-gone shim、libgbm 垫片、libdrmfake、zc-run、mbctl、mb-tray、budget.conf |
| 输入法 | fcitx5 + Rime（rime-ice），默认中文、左 Shift 在 Rime 内切中英文 |
| 应用与工具 | kitty、nemo、neovim、fish + tide/reef、mark-shot-bin、firefox/chrome 支持等 |

## 2. 快速开始

1. Fork 本仓库，确认默认分支为 `xring-o3-mali`。
2. 打开 **Actions → 编译并发布 Droidspaces RootFS → Run workflow**，按设备档案填写参数（见下表）。
3. 构建完成后从 run artifacts 或 Releases 下载 `Arch-niri-Wayland-Droidspaces-rootfs-aarch64-*.tar.xz`。
4. 设备上导入：解压到 `/data/local/Droidspaces/Containers/<ctr>/rootfs`，创建/启动容器，按 xring 仓库的 host 脚本启动 bridge 与 Anland 别名，Anland app 连接 `archniri-latest-display.sock`。

## 3. 设备构建参数（xring-o3）

| 输入 | 值 | 说明 |
| --- | --- | --- |
| `build_target` | `Arch` | 设备档案只支持 Arch |
| `desktop` | `Niri` | 固定 |
| `display_backend` | `anland-wayland` | 固定 |
| `custom_username` | `colle` | uid 1000 桌面用户 |
| `device_profile` | `xring-o3` | 安装设备档案与 Mali 栈 |
| `apply_preferences` | `true` | 构建末尾写入桌面偏好 |
| `wayland_package_repository` | `collegeming/xring-o3-droidspaces-package` | niri/niri-anland 包来源 |
| `output_scale` | `2` | 只对 `anland-0` 写输出块 |
| `output_mode` | `native` | 不写 mode，用 Anland 首选模式 |
| `mali_stack_bundle_url` | xring releases 资产 URL | 必须与 sha256 成对提供，缺失硬失败 |
| `mali_stack_bundle_sha256` | 对应 sha256 | 当前 `159ddd87…` |
| `mali_stack_version` | `2026.11.08` | 版本标识 |

命令行等价写法见 [`docs/build-image-xring-o3.md`](docs/build-image-xring-o3.md)。

## 4. 构建末尾写入的偏好（关键项）

`scripts/preferences/apply-preferences.sh` 在 rootfs 完成后执行，与设备实际使用行为对齐：

| 项 | 内容 |
| --- | --- |
| 输入法环境 | `/etc/environment` 写入 `XMODIFIERS=@im=fcitx5`、`GTK/QT/SDL_IM_MODULE=fcitx5`、`GLFW_IM_MODULE=fcitx`（Wayland 应用据此把输入交给 fcitx） |
| fcitx5 启动 | `fcitx5-session.service` → `fcitx5-dbus` wrapper：等待 Wayland socket、必要时接管过早启动的实例；**启动 fcitx5 前剥离 IM_MODULE**，避免“Wayland 诊断”通知；无 `WAYLAND_DISPLAY` 时退出让 systemd/niri 重试 |
| 输入法配置 | fcitx5 profile 只保留 rime（无 keyboard-us）、`ActiveByDefault=True`；Rime `Shift_L: inline_ascii` / `Shift_R: commit_text` |
| Noctalia | 自启动条目（`noctalia-dt`）、`NOCTALIA_LD_PRELOAD` 指向 wl-surface-gone shim（否则 surface 销毁时崩溃） |
| 桌面外观 | GTK 暗色、tide Rainbow 双 frame、mb-tray 中文、mark-shot-bin 预编译包 |
| 会话 | `desktop-session` 清理遗留 Xwayland/`DISPLAY`、`TMPDIR=/tmp`、4G 内存预算由宿主 host.env 控制 |

## 5. 与 xring 仓库如何联动

| 资产 | 产出方 | 消费方 |
| --- | --- | --- |
| Mali 栈 bundle（Mesa/ICD/shim/zc-run/...） | **xring** releases（`xring-o3-mali-stack-2026.11.08-v2.tar.zst`，sha256 `159ddd87…`） | 本仓库构建时按 URL+sha256 下载并装入 rootfs |
| niri / niri-anland Arch ARM64 包 | **xring** `build-niri-package` workflow | 本仓库通过 `wayland_package_repository` 安装 |
| host bundle / KSU 模块 / 宿主脚本 | **xring** 仓库 | 设备宿主安装，启动 bridge 与 Anland 别名 |
| rootfs 镜像 | **本仓库** | 部署到 Droidspaces 容器 |

构建链：`xring 打补丁/出包 → 本仓库构建 rootfs → 设备导入 → xring 的 host 脚本启动 bridge/别名 → Anland 上屏`。

## 6. 实现效果（与 xring 仓库同一套实测）

| 场景 | 结果 |
| --- | --- |
| 主 niri 合成 | Zink → MaliBridge → Mali GPU 合成 |
| 主 Noctalia | DMA-BUF 窗口客户端；`vkbridge-wl-shm` memfd 映射为 0 |
| 容器 Chrome | `create_immed=9`、`wl_shm.create_pool=0`；3 个 WebGL2 页面 60.39/60.06/60.35 FPS，p50 16.6–16.7 ms |
| 复杂 GL 离屏 | MaliBridge 67/19/18.5 FPS；llvmpipe 10.9/2.7/2.3；vtest 60.9/17.2/16.8 |
| Xwayland | 仅 llvmpipe（容器无 renderD） |
| A 级零拷贝 | 0（窗口缓冲走 DMA-BUF，合成器侧导入/scanout 未验证） |
| 输入法 | 默认中文（rime）、左 Shift 切中英文、无 Wayland 诊断通知 |

## 7. 产物验收

1. `xz -t` 校验归档完整性。
2. `usr/local/share/droidspaces/niri-default-config.kdl` 含 `output "anland-0"` 与 `scale 2`。
3. `etc/systemd/system/desktop-session.service` 含创建 `/dev/dri/card0` 的 `ExecStartPre`。
4. `home/colle/.config/niri/config.kdl` 中 Noctalia 启动项为 `noctalia-dt`（不带子命令）。
5. 容器启动后：`wayland-info | grep -w zwp_linux_dmabuf_v1` 版本 ≥ 4；Chromium `create_immed>0` 且 `wl_shm.create_pool=0`。

## 8. 已知边界

1. **A 级零拷贝为 0**：`create_immed` 只覆盖窗口缓冲路径。
2. **Xwayland 仅软件渲染**：容器无 renderD，X11 应用走 llvmpipe。
3. **临时 root**：设备重启后需重新 root、加载 LKM、启动容器与 bridge。
4. **功耗不可排名**：设备充电中，传感器数据不能作整机功耗。
5. **120Hz 未达**：Chrome 60 FPS 为当前上限，原因未定位。

## 9. 版本（2026-11-10）

| 项 | 值 |
| --- | --- |
| 当前镜像 | rootfs16，commit `3a27756`，sha256 `eecf1172…` |
| Mali 栈 | `2026.11.08-v2`（sha256 `159ddd87…`） |
| niri-anland | 26.4 + Touch seat / Smithay AFBC 补丁 |
| Anland consumer | `5.19-gold-identity-15d9`（collegeming/anland-mali @ `c0aede9`） |
| LKM | lkm4ctr 4.0.5 |

## 10. 关联与参考项目

| 项目 | 关系 |
| --- | --- |
| [Goldzxcbug/Droidspaces-rootfs-Desktop-builder](https://github.com/Goldzxcbug/Droidspaces-rootfs-Desktop-builder) | 本仓库上游模板（通用多发行版构建） |
| [collegeming/xring-o3-droidspaces-package](https://github.com/collegeming/xring-o3-droidspaces-package) | 配套宿主侧资产与 Mali 栈 |
| [ravindu644/Droidspaces-OSS](https://github.com/ravindu644/Droidspaces-OSS) | Droidspaces 运行时（7.1.0） |
| [ASEbrahim/MaliBridge](https://github.com/ASEbrahim/MaliBridge) | MaliBridge 上游（DroidDeck PR #517） |
| [SuperTurtleDev/anland](https://github.com/SuperTurtleDev/anland) / [Goldzxcbug/anland](https://github.com/Goldzxcbug/anland) | Anland 上游 / Droidspaces 集成分支 |
| [collegeming/anland-mali](https://github.com/collegeming/anland-mali) | 本设备 Anland fork |
| [Shikochin/Droidspaces-LKM](https://github.com/Shikochin/Droidspaces-LKM) / [cyanmint/lkm4ctr](https://github.com/cyanmint/lkm4ctr) | 免刷内核 LKM |
| [iDvel/rime-ice](https://github.com/iDvel/rime-ice) | Rime 雾凇拼音 |
| [YaLTeR/niri](https://github.com/YaLTeR/niri) / [Noctalia](https://github.com/noctalia-dev/noctalia) | 合成器与桌面 shell |

## 11. 上游通用文档

通用（非本设备）构建说明仍保留在上游文档中：

- [文档目录与桌面截图](docs/zh/README.md)
- [从 Actions 构建并导入 Droidspaces](docs/zh/快速开始.md)
- [发行版兼容性与构建选项](docs/zh/构建选项.md)
- [桌面启动与 Anland Wayland 配置](docs/zh/桌面与Anland.md)
- [TUI、USB、固件与本地构建](docs/zh/进阶使用.md)

本设备专用：`docs/build-image-xring-o3.md`。同设备的完整整理文档保存在本地 `DroidSpaces/.docs/`（50 份，按现状/调研/分析/方案/验证/手册/工程化/归档分类）。
