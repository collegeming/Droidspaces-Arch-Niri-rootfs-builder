中文 | [English](README_english.md)

# Droidspaces RootFS 自动构建

本项目用于通过 GitHub Actions 自动构建适用于 Droidspaces 的 Linux RootFS。构建流程基于 Dockerfile 模板，可以按需选择发行版、KDE 桌面规模、中文环境、输入法、GPU 加速、音频转发、TMOE、Docker、开发工具和 Wayland/Anland 支持。

项目目标是减少在 Android 设备上手动配置桌面 Linux 容器的工作量。你只需要 Fork 仓库，在 Actions 页面选择构建参数，等待 Release 产物生成，然后把 `.tar.xz` RootFS 导入 Droidspaces。

## 目录

- [支持的系统](#支持的系统)
- [功能概览](#功能概览)
- [构建选项说明](#构建选项说明)
- [使用 GitHub Actions 构建](#使用-github-actions-构建)
- [导入 Droidspaces](#导入-droidspaces)
- [启动 KDE 桌面](#启动-kde-桌面)
- [Wayland 和 Anland 配置](#wayland-和-anland-配置)
- [Droidspaces USB Manager](#droidspaces-usb-manager)
- [账户、密码和用户名修改](#账户密码和用户名修改)
- [本地构建](#本地构建)
- [安装硬件固件](#安装硬件固件)
- [仓库结构](#仓库结构)
- [已知限制](#已知限制)
- [致谢](#致谢)

## 支持的系统

| 构建目标 | 基础镜像 | KDE 模式 | Wayland/Anland | 备注 |
| --- | --- | --- | --- | --- |
| `Debian-13-KDE` | `debian:trixie` | `min`、`conc`、`mobile`、`none` | 支持 | Debian 13 使用 Trixie 软件源。 |
| `Ubuntu-24-KDE` | `ubuntu:24.04` | `min`、`conc`、`none` | 不支持 | 支持 `nosnap`。 |
| `Ubuntu-25-KDE` | `ubuntu:25.10` | `min`、`conc`、`none` | 不支持 | 支持 `nosnap`。 |
| `Ubuntu-26-KDE` | `ubuntu:26.04` | `min`、`conc`、`mobile`、`none` | 支持 | 支持 `nosnap`，推荐用于 Anland KDE。 |
| `Fedora-43-KDE` | `fedora:43` | `min`、`conc`、`mobile`、`none` | 支持 | 某些设备需要启用硬件访问。 |
| `Fedora-44-KDE` | `fedora:44` | `min`、`conc`、`mobile`、`none` | 支持 | 某些设备需要启用硬件访问。 |
| `Arch-KDE` | `ogarcia/archlinux` | `min`、`conc`、`mobile`、`none` | 支持 | 使用 ARM64 Arch patched KWin/Xwayland；当前不建议使用本项目的 QEMU/binFmt 跨架构方案。 |
| `Arch-Niri` | `ogarcia/archlinux` | 无 KDE（`build_KDE` 被忽略） | 强制启用 | 无 KDE 最小化 Arch + niri（ANiri anland 后端）+ Noctalia Shell；详见下文 Arch-Niri 说明。 |
| `Artix-KDE` | ARMtix OpenRC rootfs | `min`、`conc`、`none` | 不支持 | Artix 官方主线无 aarch64，使用 [ARMtix](https://armtixlinux.org/) 社区移植；OpenRC 初始化（无 systemd）；仓库未签名（`SigLevel = Never`）；仅 X11 路径。 |
| `NixOS-KDE` | `nixos/nix` + 声明式构建 | `min`、`none` | 不支持 | 固定 NixOS 25.05 渠道（systemd 257，旧内核友好）；`conc` 体积超出 GitHub ARM 运行器磁盘预算故不支持；GPU 为软件渲染回退（详见下文 NixOS 说明）。 |

`all` 会构建全部 Dockerfile 模板。`all-wayland` 在 `min`、`conc` 和 `mobile` 模式下构建 `Debian-13-KDE`、`Ubuntu-26-KDE`、`Fedora-43-KDE`、`Fedora-44-KDE` 和 `Arch-KDE`；`mobile` 模式会强制启用 Wayland 支持。

### Artix-KDE 说明

- 基于 [ARMtix](https://wiki.artixlinux.org/Main/Aarch64)（Artix Linux aarch64 社区移植）官方 OpenRC rootfs 引导，包仓库为 `repo.armtixlinux.org` 的 `system`、`world`、`galaxy` 三仓库（未签名，pacman 配置为 `SigLevel = Never`）。
- 使用 OpenRC + elogind + 独立 udev，没有 systemd，因此天然没有 systemd 版本兼容问题，`enable_systemd257` 会自动跳过。
- 桌面自启动通过 OpenRC 服务 `plasma-x11`（`/etc/init.d/plasma-x11`，supervise-daemon 守护）实现，等价于 systemd 版本的 `plasma-x11.service`。
- `NetworkManager` 与 `udev` 的 OpenRC 服务内置了与 systemd 版等价的运行条件检查（仅 NAT 网络模式 / 仅开启硬件访问时启动）。
- Mesa 高通 GPU 支持复用 `mesa-for-android-container` 的 `archlinux_arm64` 定制包（与 ARMtix 二进制兼容）。
- Wayland/Anland patched KWin 与 plasma-mobile 暂不支持 Artix。

### NixOS-KDE 说明

- 在 `nixos/nix` 容器内以声明式 `configuration.nix` 构建，固定使用 `nixos-25.05` 渠道：该版本搭载 **systemd 257**，是适配 4.19 等旧 Android 内核的最后主线大版本，因此无需（也不适用）`scripts/systemd257.sh` 降级编译。
- 渠道已 EOL 冻结：结果可复现，但不再接收上游安全更新；如需更新请自行在容器内 `nix-channel --add` 切换渠道（注意新渠道的 systemd 版本可能不再兼容旧内核）。
- rootfs 通过 nixpkgs 的 `make-system-tarball` 生成，包含完整 `/nix/store` 闭包、`/sbin/init` 指向 NixOS 激活脚本；首次启动自动注册 Nix 数据库并创建用户（默认密码 `1234`）。
- **GPU 限制**：NixOS 使用 nixpkgs 自带 Mesa，不含高通 KGSL 后端；`mesa-for-android-container` 的定制包与 NixOS store 不兼容。因此在 NixOS 上 GPU 渲染为 llvmpipe 软件回退，`enable_mesa` 仅安装图形栈与工具。需要 GPU 加速请优先选择 Arch/Debian/Ubuntu/Fedora 模板。
- KDE 桌面规模仅支持 `min` 和 `none`：`conc` 的 Plasma 全家桶闭包叠加构建器中间产物会超出 GitHub ARM 运行器磁盘预算。
- `TMOE` 面向 apt/dnf/pacman 体系，NixOS 不集成；`Droidspaces USB Manager` 暂未集成（其余发行版均已内置）。
- Wayland/Anland patched KWin 与 plasma-mobile 暂不支持 NixOS。

### Arch-Niri 说明（无 KDE 最小化 + niri + Noctalia Shell）

- 定位：**不含任何 KDE 组件的最小化 Arch**，桌面为滚动平铺 Wayland 合成器 [niri](https://github.com/niri-wm/niri)（通过 [ANiri](https://github.com/Celvra/ANiri) 的 anland 后端适配 Android）+ [Noctalia Shell](https://github.com/noctalia-dev/noctalia) 桌面外壳，启动器为 fuzzel。
- 终端由 workflow 启动参数 `terminal` 选择：**`kitty`（默认）** 直接从仓库安装，稳定快速；**`ghostty`** 用 Arch 官方稳定版 1.3.1 PKGBUILD 源码构建（约 25-50 分钟，用官方 zig 0.16.0 + 在线 fetch 绕 `--system` 离线清单缺陷；ghostty 构建失败即硬失败，不再静默回退）；**`konsole`** 用 KDE 自带终端（仅 Arch-KDE 适用）；**`both`** 同时构建 kitty 版 + ghostty 版两个 rootfs（matrix 维度展开，各出一个 job，汇总到同一 release）。两个模板都生效：Arch-Niri 的 niri Mod+T 快捷键用 `spawn-sh` 运行时探测已装终端（ghostty 装了用 ghostty、否则 kitty）；Arch-KDE 选 kitty/ghostty 时通过 `/etc/xdg/kdeglobals` 的 `TerminalApplication` 设为对应终端。桌面选择通过 `build_target` 参数：`Arch-Niri`（niri + Noctalia Shell）或 `Arch-KDE`（Plasma）。
- 构建逻辑：以上游 `Droidspaces-rootfs-builder` 的 Arch-Minimal 为基础（最小包集合、iptables-legacy 兼容、`ds-aliases` 别名），叠加本项目的中文环境、用户创建、`enable_systemd257` 旧内核兼容（4.19 设备建议开启）、fcitx5、高通 GPU 定制 Mesa（`enable_mesa`，ANiri 的 kgsl 渲染依赖它）、binfmt、NAT/硬件识别门控、USB Manager 与各可选组件。
- 软件源与工具链：pacman 配置 **TUNA 清华镜像置顶**（官方 ALARM 源保留回退），附加 **archlinuxcn aarch64 仓库**（TUNA 优先、官方回退，keyring 引导安装后恢复签名校验），内置 **paru**（AUR 助手，容器内以普通用户运行）；编辑器为 neovim，文件管理器为 Nemo（niri 快捷键 `Mod+E`）。
- niri 二进制固定从 ANiri Releases 下载（当前 `v0.2.0`，SHA256 校验 + strip），内核要求 ≥3.7，4.19 完全兼容；ANiri 不依赖本项目的 patched KWin 预编译包。
- 显示路径固定为 **Anland/Wayland**（无 X11/Termux:X11 路径）：工作流选中该目标时会强制启用 Wayland 支持、关闭 PulseAudio 转发（Anland App 自带音频）。
- `build_KDE` 选项被忽略（模板不含 KDE）；`build_KDE_plus=true`（默认）时启用 `niri.service` 自启动：以普通用户运行 `/usr/bin/niri`，自动创建 `/run/user/1000`，异常退出 3 秒后自动重启。服务以 `dbus-run-session` 包裹启动：fcitx5 的 GTK/Qt 输入法模块、Noctalia Shell 的 IPC 等都依赖会话级 D-Bus 总线，而 systemd 系统服务默认没有。
- 输入法（`enable_srf`）使用 **fcitx5-rime + rime-ice-git（雾凇拼音）**：fcitx5-rime 来自 ALARM extra，rime-ice-git 为 archlinuxcn aarch64 预编译包，开箱即用、无需手工配置 rime。
- niri 配置安装到 `~/.config/niri/config.kdl`（默认来自 niri 上游 `default-config.kdl`，已把 waybar 自启动替换为 noctalia、终端快捷键改为 ghostty 优先（运行时探测，缺失回退 kitty）、新增 `Mod+E` 打开 Nemo；开启 `enable_srf` 时追加 fcitx5 自启动）。新用户会从 `/etc/skel` 获得同样配置。
- 桌面应用预配置（全部写入 `/etc/skel` 并同步到默认用户家目录）：
  - **fcitx5**：niri 原生支持输入法协议（text-input-v3，v26.04 起修复了 GTK4 弹窗与 Fcitx 的兼容问题）；预置 `profile` 默认挂 rime 引擎，跳过首次运行向导；环境变量沿用 fcitx5 官方键名（GTK/Qt 模块同时注册 `fcitx` 与 `fcitx5`）；niri 启动时自动拉起 `fcitx5 -d`。
  - **Nemo**：GTK3 应用在 Wayland 原生运行（无需 Xwayland）；`gvfs` 提供回收站/挂载后端；目录默认打开方式设为 Nemo（`/etc/xdg/mimeapps.list`）；预置「在终端中打开」动作（走 `droidspaces-terminal` 包装脚本，ghostty 优先、回退 kitty，与 `Mod+T` 行为一致）。
  - **neovim**：预置最小 `init.lua`（UTF-8、行号、真彩色、鼠标、系统剪贴板同步）；随附 `wl-clipboard` 提供剪贴板支撑。删除 `~/.config/nvim/init.lua` 即可恢复原生默认。
  - **GTK3/GTK4 暗色主题**：与 Noctalia 深色风格一致（ghostty 与 Nemo 均读取）。
  - **终端美化**（`scripts/terminal/setup-beautify.sh` 一键部署，写入 `/etc/skel` 并同步到用户家目录）：
    - **fish shell**：设为默认 shell（`chsh -s /usr/bin/fish`），kitty/ghostty 的 `shell`/`command` 均指向 fish 交互登录模式。
    - **reef + reef-tools**（AUR）：bash 兼容层 + 现代 CLI 工具替代（grep→rg, find→fd, cat→bat, ls→eza, cd→zoxide）；`conf.d/reef.fish` 在交互会话自动 `reef on`。
    - **Fisher + Tide**：`fisher.fish` 手动下载到 functions 目录，`fisher install ilancosman/tide@v6` 预装；`tide-apply.fish` 直写 universal 变量（**Classic 风格 Powerline**，双行 frame，`❯` 提示符，左 os→pwd→git→newline→character，右 status/cmd_duration/context/jobs/direnv/语言运行时/云平台/time，Powerline 分隔符 `\ue0b0`，vi_mode 图标，shlvl/private_mode 模块）。
    - **Maple Mono NF CN 字体**：从 GitHub release 下载（v7.9，Nerd Font + 中文），安装到 `/usr/share/fonts/MapleMono/`，`fc-cache` 刷新。
    - **kitty 配置**：Catppuccin Frappe 主题（`include themes/frappe.conf`）、Maple Mono NF CN 字体 14pt、Neovide 风格光标拖尾（`cursor_trail 3`）、背景半透明 0.85、无边框。
    - **ghostty 配置**（仅 `terminal=ghostty` 时）：`theme = catppuccin-frappe`（内置）、Maple Mono NF CN 14pt、`background-blur = true`（Ghostty 1.1+ 原生 ext-background-effect-v1）、`custom-shader = shaders/cursor_warp.glsl`（克隆 `ghostty-cursor-shaders` 仓库）、背景半透明 0.85。
    - **niri 背景模糊**：`config.kdl` 追加 `window-rule` 对 kitty/ghostty 启用 `background-effect { blur true }`（kitty 原生 blur 在 niri 不生效，ghostty 自带 blur 时由协议优先）。
    - **Nemo 中文**：安装 `cinnamon-translations` 包（Nemo UI 翻译来源），配合已生成的 `zh_CN.UTF-8` locale 实现中文界面。
- Noctalia Shell：niri 是其官方集成的合成器之一，通知守护/启动器/控制中心均为内置，无需额外守护进程；其自身无 polkit 认证代理（本项目内 USB Manager 走免密 sudo，不受影响）。
- 宿主侧准备与 Wayland/Anland 配置一节相同：刷入 virtual-drm-daemon、安装 Anland App、绑定挂载 `display_daemon.sock -> /run/display.sock`、开启 GPU 访问与 SELinux 宽容，并在 Anland 中开启无障碍开关（否则 Android 会拦截 Super 键）。
- 已知限制：ANiri 上游声明的已知问题包括 glmark2/vkmark 得分略低于 KWin、Android 悬浮窗可能引起花屏、麦克风/摄像头转发应用侧不可读；本模板未集成 Xwayland（ patched Xwayland 属于 KWin 预编译包体系）；Nemo 的「在终端中打开」动作在空白背景右键时可能不显示（对文件/文件夹右键可用）。
- **远程访问**（workflow 参数 `remote`，仅 Arch-Niri 适用）：
  - **`none`（默认）**：不启用远程访问。
  - **`wayvnc`（推荐）**：Wayland 原生 VNC 服务器，ALARM extra 预编译包（改动最小，~5MB），niri 已实现 wayvnc 所需全部 wlr 协议（screencopy v3 + virtual-pointer + virtual-keyboard + data-control）。PC 端用 TigerVNC/Remmina/NyaTerm 连接 `<手机IP>:5900`，**无密码**（wayvnc 0.10.1 启用密码认证时会同时提供 RSA-AES 安全类型，多数 Windows VNC 客户端不支持导致连接失败，故默认关闭认证，仅限局域网访问）。如需远程安全访问，建议通过 SSH 隧道：`ssh -L 5900:localhost:5900 colle@<手机IP>`，然后 VNC 连 `localhost:5900`。已知限制：虚拟键盘修饰键不触发 niri 自身快捷键（Super+Tab 等，niri#403），普通字符输入正常，窗口管理用 Noctalia Shell 按钮替代。
  - **`lamco`**：基于 IronRDP 的标准 RDP 服务端（PC 端 Windows 自带 `mstsc` 免装客户端），aarch64 需从源码构建（Rust 1.89+，约 30-60 分钟），依赖 PipeWire + dbus-broker。连接 `<手机IP>:3389`，**PAM 认证**：输入容器内系统用户名+密码（如 `colle` / `1234`）。许可证 BSL 1.1（单实例免费）。配置文件 `/etc/lamco/config.toml`（`auth_method = "pam"`）。
  - 两方案不冲突（不同端口/协议），修饰键缺陷是 niri/Smithay 上游共有问题（不可在容器侧修复）。详细调研见 `remote-access-background-and-solutions.md`。

#### VNC 连接操作说明（`remote=wayvnc`）

**前提**：构建时选 `remote=wayvnc`；容器启动后 `wayvnc.service` 会自动监听 `0.0.0.0:5900`。

**PC 端连接步骤**：

1. **获取手机 IP**：在手机上查看 Droidspaces 容器使用的网络模式——
   - **NAT 模式**：手机设置 → WLAN → 查看 IP（如 `192.168.1.100`）
   - **主机网络模式**：与手机同一 IP

2. **下载 VNC 客户端**（任选其一，免费）：
   - **Windows**：[TigerVNC](https://tigervnc.org/)（轻量，推荐）或 [RealVNC Viewer](https://www.realvnc.com/en/connect/download/viewer/)
   - **macOS**：自带的「屏幕共享」或 [TigerVNC](https://tigervnc.org/)
   - **Linux**：`pacman -S tigervnc` 或 `apt install tigervnc-viewer` / Remmina

3. **连接**：打开 VNC 客户端，输入地址：
   ```
   <手机IP>:5900
   ```
   例如 `192.168.1.100:5900`（TigerVNC 输入 `192.168.1.100::5900`）。

   **密码**：无密码（VNC 认证已关闭）。如需安全访问，建议通过 SSH 隧道：先在 PC 端运行 `ssh -L 5900:localhost:5900 colle@<手机IP>`，然后 VNC 连 `localhost:5900`。

4. **操作**：
   - 连接后即可看到 niri 桌面（与手机屏幕同一画面）
   - **鼠标**：完全可用（移动、点击、拖拽、滚轮）
   - **键盘字符输入**：完全可用（终端打字、中文输入）
   - **fcitx5 中文输入**：正常
   - **窗口管理快捷键**：Super+Tab / Super+Q 等 niri 快捷键**不触发**（niri#403 上游限制），请用 Noctalia Shell 的 UI 按钮替代（切换窗口、关闭窗口、移动窗口等）

5. **断开**：关闭 VNC 客户端窗口即可。wayvnc 服务仍在运行，随时可重连。

## 功能概览

- 多发行版 RootFS 构建：支持 Debian、Ubuntu、Fedora、Arch、Artix 和 NixOS。
- KDE 桌面可裁剪：支持命令行 RootFS、最小 KDE、精简 KDE 和移动版 KDE。
- 无 KDE 的 niri 桌面：`Arch-Niri` 目标提供最小化 Arch + niri（ANiri anland 后端）+ Noctalia Shell，**不含任何 KDE 组件**。
- 终端选择参数化（`terminal`）：Arch-Niri/Arch-KDE 可选 kitty（仓库直装）、ghostty（官方稳定版 1.3.1 源码构建）、konsole（KDE 自带）、both（同时出 kitty+ghostty 两版 rootfs 到一个 release）。
- 终端美化预配置：fish shell（默认 shell）+ reef/reef-tools（bash 兼容层）+ Fisher + Tide v6（Classic Powerline 双行样式）+ Maple Mono NF CN 字体 + Catppuccin Frappe 主题 + 光标拖尾 + 背景半透明 + niri 背景模糊 window-rule。
- Nemo 中文：安装 cinnamon-translations 包，配合 zh_CN.UTF-8 locale 实现 Nemo 中文界面。
- 远程访问参数化（`remote`）：Arch-Niri 可选 wayvnc（VNC 5900，推荐）或 lamco（RDP 3389，mstsc 免装客户端），从 PC 远程访问手机容器桌面。
- 桌面自动启动与故障恢复：X11、Plasma Wayland 和 Plasma Mobile 使用统一的 systemd 服务模板，异常退出后会限频自动重启。niri 自启动由 `niri.service`（`dbus-run-session` 包裹）实现。
- Termux:X11 桌面启动：X11 模式下默认使用 `DISPLAY=:5`。
- PulseAudio 音频转发：支持 Unix socket、TCP 和关闭音频转发。
- 中文环境：可选启用 `zh_CN.UTF-8` 和 `Asia/Shanghai` 时区。
- 输入法：可选安装 Fcitx5；启用中文环境时会额外安装中文输入支持。
- Snapdragon GPU 支持：集成来自 `mesa-for-android-container` 的高通 GPU 相关配置。
- 骁龙 8 Gen 2 Wayland 花屏修复：可选将 Turnip UBWC 修复开关写入 RootFS 环境变量。
- 容器增强：补充 Android/Droidspaces 环境下常见的硬件、网络和用户组识别配置。
- TMOE：可选集成 TMOE，容器内执行 `tmoe` 即可启动。
- 开发工具：可选安装编译器、CMake、Python 开发环境等。
- 压缩工具：可选安装 `zip`、`unzip`、`7z`、`xz`、`tar`、`gzip` 等工具。
- Docker：可选在 RootFS 内安装 Docker 相关软件包。
- 旧内核 systemd 兼容：可选在 systemd 主版本高于 257 的 apt、dnf 或 pacman 发行版中构建并安装 `v257-stable`；Debian 13 等已是 257 或更低版本时会自动跳过；Artix 无 systemd、NixOS 25.05 固定 257，两者均自动跳过。
- Wayland/Anland：对 Debian 13、Ubuntu 26.04、Fedora 43/44 和 Arch Linux 提供 ARM64 patched KWin 与 Xwayland 包。
- USB 设备管理：全部发行版内置 Droidspaces USB Manager，支持 USB 存储、ADB 设备节点、挂载、卸载和系统托盘。
- Release 自动发布：构建完成后会把 RootFS `.tar.xz` 和对应的音频启动脚本上传到 GitHub Release。

## 构建选项说明

GitHub Actions 的主要输入项如下：

| 选项 | 可选值 | 默认值 | 说明 |
| --- | --- | --- | --- |
| 选择要构建的发行版 (`build_target`) | 发行版目标、`all`、`all-wayland` | `Debian-13-KDE` | 选择要构建的 RootFS。 |
| 自定义用户名 (`custom_username`) | 字符串 | `Gold` | RootFS 默认用户。Release 中的音频启动脚本会同步替换该用户名。 |
| KDE 桌面选择 (`build_KDE`) | `conc`、`min`、`mobile`、`none` | `min` | KDE 桌面规模。`none` 表示只构建命令行环境。 |
| KDE 桌面开机自启动 (`build_KDE_plus`) | `true`、`false` | `true` | 是否创建 KDE 自启动 systemd 服务。需要已安装 KDE；选择 `none` 桌面时应关闭。 |
| Wayland 支持 (`enable_anland_kde`) | `true`、`false` | `false` | 是否启用 Wayland/Anland 支持。支持 Debian 13、Ubuntu 26、Fedora 43/44 和 Arch。 |
| PulseAudio 音频转发 (`PulseAudio`) | `socket`、`tcp`、`none` | `socket` | X11 模式下的音频转发方式。启用 Anland 时会被强制改为 `none`。 |
| 使用中文语言和时区 (`enable_zh_tz`) | `true`、`false` | 中文工作流默认为 `true` | 启用中文 locale 并设置上海时区。 |
| 高通骁龙 GPU 支持 (`enable_mesa`) | `true`、`false` | `true` | 启用高通 GPU/Mesa 相关支持。 |
| 修复 8Gen2 Wayland 花屏 (`enable_8gen2_wayland`) | `true`、`false` | `false` | 为 Debian 13、Ubuntu 26、Fedora 43/44 和 Arch 写入 `FD_DEV_FEATURES=enable_tp_ubwc_flag_hint=1` 到 `/etc/environment`。 |
| 集成 TMOE (`enable_tmoe`) | `true`、`false` | `true` | 集成 TMOE。 |
| 移除 Ubuntu Snap (`nosnap`) | `true`、`false` | `false` | 只对 Ubuntu 有意义，用于移除 Snap、snapd 和可能重新安装 snapd 的 APT 策略。 |
| systemd 257 旧内核兼容 (`enable_systemd257`) | `true`、`false` | `true` | 启用后，在当前 systemd 主版本高于 257 时从 `v257-stable` 构建兼容运行时；systemd 257 及更低版本自动跳过；Artix（无 systemd）与 NixOS 25.05（固定 257）自动跳过。构建完成后会锁定 systemd 相关包，避免再次升级覆盖。 |
| 输入法 Fcitx5 支持 (`enable_srf`) | `true`、`false` | `true` | 安装 Fcitx5 输入法。 |
| 跨架构支持 (`enable_binfmt`) | `true`、`false` | `false` | 在 RootFS 内加入 binfmt 跨架构支持组件。Arch 当前不建议使用。 |
| NAT 和硬件识别支持 (`enable_yj`) | `true`、`false` | `true` | 启用容器硬件和网络识别增强。 |
| 开发工具集成 (`enable_kfgj`) | `true`、`false` | `false` | 安装开发工具链。 |
| 压缩工具集成 (`enable_zip`) | `true`、`false` | `true` | 安装常用压缩工具。 |
| Docker 集成 (`enable_docker`) | `true`、`false` | `false` | 在 RootFS 内安装 Docker 相关包。 |
| 构建 Wayland 预编译包 (`build_wayland_packages`) | `true`、`false` | `false` | 构建 RootFS 前触发 KWin/Xwayland 预编译包更新流程。 |
| 终端选择 (`terminal`) | `kitty`、`ghostty`、`konsole`、`both` | `kitty` | Arch-Niri/Arch-KDE 的终端。`both` 同时构建 kitty+ghostty 两个 rootfs 到一个 release。 |
| 远程访问 (`remote`) | `none`、`wayvnc`、`lamco` | `none` | Arch-Niri 远程访问方案。`wayvnc`=VNC 5900（推荐，改动最小）；`lamco`=RDP 3389（mstsc 免装客户端，需源码构建）。 |

KDE 模式说明：

| 模式 | 说明 | 适合场景 |
| --- | --- | --- |
| `none` | 不安装 KDE 桌面，只保留命令行环境。 | 需要轻量 RootFS、SSH、开发环境或自定义桌面的用户。 |
| `min` | 最小 KDE 桌面，包含 Plasma 基础组件和常用启动依赖。 | 想要较小体积且可用 KDE 桌面的用户。 |
| `conc` | 精简但更完整的 KDE 桌面，包含更多系统工具、监控、文件管理和多媒体组件。 | 日常桌面使用。 |
| `mobile` | KDE Plasma Mobile 相关组件。 | 手机屏幕和触控优先场景；会强制启用 Wayland。 |

音频模式说明：

| 模式 | 说明 |
| --- | --- |
| `socket` | 使用 Unix socket 转发 PulseAudio。通常延迟更低，推荐在 X11 模式下使用。 |
| `tcp` | 使用 `127.0.0.1:4713` 转发 PulseAudio。兼容性较直观，但暴露面更大。 |
| `none` | 不配置 PulseAudio。Anland 模式下会自动使用此模式，因为 Anland App 自带音频路径。 |

### systemd 257 旧内核兼容

开启 `enable_systemd257` 后，RootFS 会运行 `scripts/systemd257.sh`。脚本会先检测发行版现有的 systemd 主版本：

- 257 或更低版本（例如 Debian 13、Ubuntu 24.04）直接跳过；
- 高于 257 的 apt、dnf 和 pacman 系统从官方 `v257-stable` 构建 systemd 257；
- 构建依赖会在完成后清理，并锁定 systemd 相关软件包，防止后续升级覆盖兼容版本。

该选项主要面向旧 Android 内核，属于实验性兼容方案，会显著增加构建时间；建议先在目标内核上验证桌面、dbus、udev 和网络功能。

### 4.19 内核设备推荐配置（如 Redmi K40 / 骁龙 870）

本仓库 `4.19Core` 定位面向 4.19 内核设备（参考设备：Redmi K40 `alioth`，骁龙 870 / SM8250，Adreno 650）。针对这类设备的推荐工作流选项：

| 选项 | 推荐值 | 说明 |
| --- | --- | --- |
| `enable_systemd257` | `true` | 4.19 内核无法运行 systemd 258+；本项为中文工作流默认值。NixOS 25.05 已内置 systemd 257，Artix 无 systemd，均自动跳过。 |
| `enable_zh_tz` | `true` | 中文 locale + 上海时区（中文工作流默认值）。 |
| `enable_srf` | `true` | Fcitx5 输入法，启用中文环境时自动附带中文输入引擎（中文工作流默认值）。 |
| `enable_mesa` | `true` | 高通 GPU（Adreno）支持；NixOS 上为软件渲染回退。 |
| `enable_yj` | `true` | 容器硬件与网络识别（默认值）。 |
| `enable_zip` | `true` | 压缩工具集成（默认值）。 |
| `enable_binfmt` | `false` | 见下方内核注意事项。 |
| `PulseAudio` | `socket` | X11 模式推荐 Unix socket 转发。 |

这类设备的内核注意事项（以 Redmi K40 实测为准）：

- `CONFIG_USER_NS` 未开启：导入 Droidspaces 时请在特权模式开启 `noseccomp`，避免依赖用户命名空间的操作卡顿。
- `CONFIG_BINFMT_MISC` 未开启：容器内的 QEMU binfmt 跨架构注册会优雅跳过（日志提示 `binfmt_misc not supported by kernel`），`enable_binfmt` 打开也不会在设备上生效；跨架构二进制转译需要更换启用该选项的内核。
- GPU 渲染节点 `/dev/dri/renderD128` 正常可用；导入时需开启 GPU 访问（droidspaces-gpu 组已内置）。

## 使用 GitHub Actions 构建

1. Fork 本仓库到自己的 GitHub 账号。
2. 打开 Fork 后仓库的 `Actions` 页面。
3. 选择中文工作流 `编译并发布 Droidspaces RootFS`，或英文工作流 `Build and Release Droidspaces RootFS`。
4. 点击 `Run workflow`。
5. 选择发行版、KDE 模式、用户名和功能开关。
6. 如果要使用 Wayland/Anland，建议选择 `Ubuntu-26-KDE`，也可选择 `Debian-13-KDE`、`Fedora-43-KDE`、`Fedora-44-KDE` 或 `Arch-KDE`，并开启 `enable_anland_kde`。
7. 如果希望先重新构建 patched KWin/Xwayland 包，再构建 RootFS，开启 `build_wayland_packages`。
8. 等待 Actions 完成。构建时间取决于目标数量、KDE 模式和 GitHub runner 状态。
9. 打开 `Releases` 页面，下载生成的 `.tar.xz` RootFS。

Release 通常包含：

- 一个或多个 RootFS 压缩包
- RootFS 文件名会按显示模式标记为 `X11`、`Wayland` 或 `Mobile`，例如 `Ubuntu-26-KDE-Mobile-Droidspaces-rootfs-aarch64-v20260702-120000.tar.xz`。
- 当 `PulseAudio` 为 `socket` 或 `tcp`，且 `build_KDE_plus=false` 时，会附带 `on_aaudio_socket.sh` 或 `on_aaudio_tcp.sh`。
- Release 正文会记录构建目标、KDE 模式、Wayland 开关、用户名和各功能开关。

## 导入 Droidspaces

1. 在 Droidspaces 中创建或导入容器。
2. RootFS 文件选择 Release 下载的 `.tar.xz`。
3. 如果 RootFS 包含 KDE 桌面，必须在 Droidspaces 中开启 GPU 访问。
4. Ubuntu 和 Debian 系建议在特权模式中开启 `noseccomp`，并确保内核启用 `USER_NS`。否则某些桌面操作可能出现明显卡顿。
5. Fedora 某些设备需要开启硬件访问，否则可能出现桌面闪屏或崩溃。
6. Arch 建议宿主内核版本为 5.10 或更新。
7. 如果使用 X11 模式，准备好 Termux:X11。
8. 如果使用 Wayland/Anland 模式，按本文的 Wayland 和 Anland 配置完成宿主侧准备。

## 启动 KDE 桌面

启用 `build_KDE_plus` 后，构建流程会根据桌面模式安装对应的 systemd 服务：

| 桌面模式 | 服务文件 | 启动命令 |
| --- | --- | --- |
| X11 | `plasma-x11.service` | `DISPLAY=:5 startplasma-x11` |
| Wayland | `plasma-wayland.service` | `startplasma-wayland` |
| Mobile | `plasma-mobile.service` | `startplasmamobile` |

这些服务以 UID 1000 用户运行并读取 `/etc/environment`。桌面进程异常退出时会在 2 秒后自动重启；如果 60 秒内启动失败超过 5 次，systemd 会暂时停止重试，防止形成崩溃循环。正常退出不会触发自动重启。

### X11 模式

X11 模式适用于未启用 `enable_anland_kde` 的构建。默认环境变量为：

```text
DISPLAY=:5
```

建议保持 `build_KDE_plus=true`，这也是当前默认选项。启用后 RootFS 会创建 KDE 自启动 systemd 服务，容器启动后会自动拉起桌面环境；只有需要使用 Termux 侧 `on_aaudio_*` 脚本手动启动桌面，或构建 `none` 命令行环境时，才建议关闭该选项。

如果 Release 中包含音频启动脚本，可以在 Termux 中使用它启动 PulseAudio、Termux:X11 和 KDE：

```bash
chmod +x on_aaudio_socket.sh
./on_aaudio_socket.sh
```

或：

```bash
chmod +x on_aaudio_tcp.sh
./on_aaudio_tcp.sh
```

使用脚本前需要检查脚本顶部变量：

```bash
CONTAINER_NAME="你的 Droidspaces 容器名"
USERNAME="你的 RootFS 用户名"
DISPLAY_NUMBER=":5"
DPI=315
```

`USERNAME` 会在 Release 生成时按 `custom_username` 自动替换，但 `CONTAINER_NAME` 仍需要与 Droidspaces 中的容器名称一致。

如果不用脚本，也可以进入容器后手动启动：

```bash
startplasma-x11
```

自启动的实际效果仍取决于 Droidspaces 的 systemd、权限和显示后端配置。如果自启动没有拉起桌面，可以进入容器后执行 `startplasma-x11` 排查。

### Wayland/Anland 模式

Wayland/Anland 模式适用于启用 `enable_anland_kde` 的 Debian 13、Ubuntu 26、Fedora 43/44 和 Arch 构建。默认环境变量包括：

```text
WAYLAND_DISPLAY=wayland-0
DISPLAY=:0
QT_QPA_PLATFORM=wayland
ANLAND=1
ANLAND_SOCKET=/run/display.sock
ANLAND_DRM_DEVICE=/dev/dri/renderD128
```

完成宿主侧 Anland 配置后，在容器内执行：

```bash
startplasma-wayland
```

如果构建的是 `mobile` 模式，对应的手动启动命令为：

```bash
startplasmamobile
```

## Wayland 和 Anland 配置

Wayland 支持依赖 [anland](https://github.com/superturtlee/anland) 和 GitHub Releases 中的 patched KWin/Xwayland 预编译包。建议使用 `Ubuntu-26-KDE`，也可以使用 `Debian-13-KDE`、`Fedora-43-KDE`、`Fedora-44-KDE` 或 `Arch-KDE`。Arch 使用 `anland` 仓库中的 `producers/kde/Arch_v5/build.sh` 在 ARM64 Arch 容器内重建包。

### 一键安装 Anland KDE Release 包

`scripts/install-anland-kde.sh` 会自动识别当前发行版，从固定滚动 Release `anland-kde-packages` 的 `anland-kde-manifest` 精确选择对应的压缩包，按 KWin 版本下载 patched KWin/Xwayland 包，然后防止系统更新将它们覆盖。二进制包不会再加入 Git 历史；这个 Release 包含 Arch、Debian 13、Ubuntu 26、Fedora 43 和 Fedora 44 的五个独立压缩包，文件名形如 `anland-kde-ubuntu2604-kwin-6.7.3-arm64.tar.gz`。
脚本会按 `LC_ALL`、`LC_MESSAGES`、`LANG` 的优先级读取系统语言：中文 locale 输出中文，其他 locale 输出英文。

支持 Debian 13、Ubuntu 26.04、Fedora 43/44 和 Arch Linux，仅支持 ARM64/aarch64。安装器在普通用户权限下下载、预检和解包，再仅以 root 权限执行安装。Debian/Ubuntu 使用受脚本记录管理的 `apt-mark hold`，Fedora 通过 `/etc/dnf/dnf.conf` 的托管 `excludepkgs` 块，Arch 通过 pacman 的 `IgnorePkg` 实现等效锁定。

从仓库根目录运行：

```bash
sudo ./scripts/install-anland-kde.sh
```

启动后会按固定顺序测试 GitHub、`gh-proxy.com`、`ghproxy.net` 三个下载源；单个测试达到 2 秒会显示为超时，然后输入 `1`、`2` 或 `3` 选择下载源。选择第三方镜像时，下载的清单和归档都会以 GitHub Release API 公布的 SHA-256 digest 校验，因此需要系统具有 `jq`、`sha256sum`，且能访问 `api.github.com`。非交互场景可传入 `-1` 或 `--1` 直接使用 GitHub 并跳过测速；GitHub Actions 构建使用 `--1`。

也可以直接获取安装器：

```bash
curl -fLO https://raw.githubusercontent.com/Goldzxcbug/Droidspaces-rootfs-KDE-builder/main/scripts/install-anland-kde.sh
chmod +x install-anland-kde.sh
sudo ./install-anland-kde.sh
```

推荐构建选项：

| 选项 | 推荐值 |
| --- | --- |
| `build_target` | `Ubuntu-26-KDE` |
| `build_KDE` | `min`、`conc` 或 `mobile` |
| `build_KDE_plus` | `true` |
| `enable_anland_kde` | `true` |
| `PulseAudio` | 无需手动设置，启用 Anland 后会变为 `none` |

宿主侧配置步骤：

1. 从 [anland Releases](https://github.com/superturtlee/anland/releases) 下载 `virtual-drm-daemon.zip`，刷入后重启设备。
2. 从同一 Release 下载并安装 `app-debug.apk`。
3. 导入 Droidspaces 容器时开启硬件访问。
4. 开启 SELinux 宽容模式，或使用后文的精确 SELinux 策略修补。
5. 在特权模式中开启 `nocaps` 和 `noseccomp`。
6. 在高级选项中添加绑定挂载：

```text
/data/local/tmp/display_daemon.sock -> /run/display.sock
```

7. 启动容器，选择普通用户登录。
8. 在容器内执行：

```bash
startplasma-wayland
```

如果选择 `mobile`，工作流会强制启用 Wayland，因为 Plasma Mobile 在本项目中按 Wayland 路径配置。

## Droidspaces USB Manager

除 NixOS 外的 9 个发行版模板都会通过 `scripts/install-usb-manager.sh` 安装 [Droidspaces-USB-Manager](https://github.com/Yizhou147/Droidspaces-USB-Manager)（NixOS 的声明式体系暂未集成，见上文说明）。安装器会自动识别 Debian/Ubuntu、Fedora 或 Arch 系（含 Artix）系统，使用 APT、DNF 或 Pacman 安装对应的 PyQt5、ADB、udev、NTFS 和 exFAT 依赖，并修正上游代码中仅适用于 Debian 的命令路径。

导入 RootFS 时必须开启 Droidspaces 的硬件访问，否则容器内看不到 `/sys/bus/usb` 和 `/sys/bus/scsi` 设备。安装器会同时创建应用菜单入口和 `~/Desktop/usb-manager.desktop` 桌面快捷方式。进入 KDE 后，也可以运行：

```bash
usb-manager
```

另外提供两个命令行入口：

```bash
usb-passthrough
usb-storage-passthrough
```

如果需要在已有系统中单独安装或更新，可在仓库根目录执行：

```bash
sudo ./scripts/install-usb-manager.sh --user "$USER"
```

与 `scripts/install-anland-kde.sh` 一样，该脚本支持自动提权、中文/英文日志。省略 `--user` 时会依次尝试 `SUDO_USER`、当前登录用户和第一个普通用户。

## 本地构建

本项目主要面向 GitHub Actions，但也可以在本地使用 Docker Buildx 构建。你需要准备：

- Docker
- Docker Buildx
- `xz`
- 如果要跨架构构建，需要可用的 QEMU/binfmt 环境

原生架构构建示例：

```bash
chmod +x build_rootfs-native.sh
./build_rootfs-native.sh \
  -i Debian-13-KDE.Dockerfile \
  -v local \
  -K min \
  -L true \
  -P socket \
  -g true \
  -a false \
  -b true \
  -c true \
  -d false \
  -e true \
  -f false \
  -h false \
  -j true \
  -n false \
  -S false \
  -t false \
  -u Gold \
  -A false
```

使用 QEMU 构建 arm64 RootFS 示例：

```bash
chmod +x build_rootfs-qemu-aarch64.sh
./build_rootfs-qemu-aarch64.sh \
  -i Ubuntu-26-KDE.Dockerfile \
  -v local \
  -K conc \
  -L true \
  -P none \
  -g true \
  -a false \
  -b true \
  -c true \
  -d false \
  -e true \
  -f false \
  -h true \
  -j true \
  -n true \
  -S false \
  -t false \
  -u Gold \
  -A true
```

构建完成后会生成类似下面的文件：

```text
Ubuntu-26-KDE-Wayland-Droidspaces-rootfs-aarch64-local.tar.xz
```

## 安装硬件固件

Debian 13 和 Ubuntu 24/25/26 RootFS 内置了 `/usr/local/bin/download-firmware`，用于安装 `linux-firmware`，并将 `/lib/firmware` 中的 `.zst` 压缩固件解压为普通固件文件。脚本还会修复原本指向 `.zst` 文件的软链接，适用于内核、驱动或容器环境无法直接读取压缩固件的情况。

该工具只会被复制到 RootFS，不会在构建或容器启动时自动执行。需要使用时，在容器内手动运行：

```bash
sudo download-firmware
```

脚本会安装 `zstd` 和 `linux-firmware`，因此执行时需要可用的软件源和网络连接。成功后会创建 `/var/lib/.fw-setup-completed` 标记文件。当前脚本不会根据该标记跳过后续执行；重复运行仍会更新软件包列表并重新扫描固件目录。

## 仓库结构

```text
.
├── Arch-KDE.Dockerfile
├── Arch-Niri.Dockerfile
├── Artix-KDE.Dockerfile
├── Debian-13-KDE.Dockerfile
├── Fedora-43-KDE.Dockerfile
├── Fedora-44-KDE.Dockerfile
├── NixOS-KDE.Dockerfile
├── Ubuntu-24-KDE.Dockerfile
├── Ubuntu-25-KDE.Dockerfile
├── Ubuntu-26-KDE.Dockerfile
├── build_rootfs-native.sh
├── build_rootfs-qemu-aarch64.sh
├── scripts/
│   ├── start/
│   │   ├── plasma-mobile.service
│   │   ├── plasma-wayland.service
│   │   └── plasma-x11.service
│   ├── bashrc.sh
│   ├── download-firmware
│   ├── install-usb-manager.sh
│   ├── install-anland-kde.sh
│   ├── niri/
│   │   └── default-config.kdl
│   ├── nosnap.sh
│   ├── systemd257.sh
│   ├── on_aaudio_socket.sh
│   └── on_aaudio_tcp.sh
├── scripts/binfmt/
│   ├── qemu-binfmt-register.service
│   └── qemu-binfmt-register.sh
└── .github/workflows/
    ├── build-kde-wayland.yml
    ├── build-rootfs-releases-en.yml
    └── build-rootfs-releases.yml
```

KDE 包只作为 GitHub Release 资产发布。手动运行 `build-kde-wayland.yml` 时，`build_target=all` 会固定一个 Anland 源提交并重新生成五个平台；若其中某个平台构建失败，工作流会从固定滚动 Release 沿用该平台的现有包，只更新成功的平台，并重写同一个 `anland-kde-packages` Release 的全部资产和 `anland-kde-manifest`。选择单个平台时只重新构建并替换该平台，其他四个压缩包保持不变。若固定 Release 不能提供完整的五平台资产，或本次没有任何新包成功生成，工作流会失败且不会更新 Release。它不会提交包或改写 `main`；固定滚动 Release 会被保留。
首次创建固定滚动 Release 必须选择 `all` 并让五个平台全部成功；创建后，部分构建只会从该固定 Release 复用未替换的平台资产。

## 已知限制

- Wayland/Anland 当前覆盖 Debian 13、Ubuntu 26、Fedora 43/44 和 Arch；Artix 与 NixOS 暂不支持（仅 X11 路径）。`Arch-Niri` 使用独立的 ANiri 方案（非 patched KWin）。
- Ubuntu 24 和 Ubuntu 25 当前按 X11 路径使用。
- `mobile` 模式支持 Debian 13、Ubuntu 26、Fedora 43/44 和 Arch；Artix、NixOS 与 Arch-Niri 暂不支持。
- `Arch-Niri` 的 `build_KDE` 选项被忽略；其 ANiri 上游存在渲染性能略低、悬浮窗花屏等已知问题（详见上文 Arch-Niri 说明）。
- NixOS-KDE 仅支持 `min` 和 `none` 桌面规模，且 GPU 为软件渲染回退、未集成 USB Manager（详见上文 NixOS-KDE 说明）。
- Artix-KDE 依赖 ARMtix 社区仓库（未签名），可用性与更新节奏取决于上游社区。
- 启用 Anland 后，工作流会关闭 PulseAudio 转发，因为 Anland App 自带音频路径。
- Fedora 在部分设备上需要硬件访问，否则可能闪屏或崩溃。
- Ubuntu 和 Debian 在未启用 `noseccomp` 或内核缺少 `USER_NS` 时，可能出现卡顿。
- 默认密码为 `1234`，导入后应立即修改。
- 本项目内置的预编译 Wayland 包与上游 anland 的兼容性取决于构建时的上游状态。

## 致谢

- [Droidspaces-OSS](https://github.com/ravindu644/Droidspaces-OSS/)：本项目运行环境的基础。
- [mesa-for-android-container](https://github.com/lfdevs/mesa-for-android-container)：高通 Snapdragon GPU 驱动支持。
- [TMOE](https://github.com/2moe/tmoe)：容器内管理工具。
- [anland](https://github.com/superturtlee/anland)：Wayland 显示后端和 patched KDE 相关工作。
- [Droidspaces-USB-Manager](https://github.com/Yizhou147/Droidspaces-USB-Manager)：适用于Droidspaces 的 USB 存储和 ADB 设备管理工具。
- [ARMtix](https://armtixlinux.org/)：`Artix-KDE` 所使用的 Artix Linux aarch64 社区移植。
- [NixOS](https://nixos.org/) 与 [nixpkgs](https://github.com/NixOS/nixpkgs)：`NixOS-KDE` 声明式构建的基础。
- [ANiri](https://github.com/Celvra/ANiri) 与 [niri](https://github.com/niri-wm/niri)、[Noctalia](https://github.com/noctalia-dev/noctalia)：`Arch-Niri` 的滚动平铺桌面方案。
