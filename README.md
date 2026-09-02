中文 | [English](README_english.md)

# Droidspaces RootFS 自动构建

本项目用于通过 GitHub Actions 自动构建适用于 Droidspaces 的 Linux RootFS。构建流程采用可扩展的桌面 profile，可以按需选择发行版、桌面、显示后端、中文环境、输入法、GPU 加速、音频转发、TMOE、Docker 和开发工具。目前提供 KDE、KDE Mobile 与 GNOME profile。

项目目标是减少在 Android 设备上手动配置桌面 Linux 容器的工作量。你只需要 Fork 仓库，在 Actions 页面选择构建参数，等待 Release 产物生成，然后把 `.tar.xz` RootFS 导入 Droidspaces。

## 目录

- [支持的系统](#支持的系统)
- [功能概览](#功能概览)
- [构建选项说明](#构建选项说明)
- [使用 GitHub Actions 构建](#使用-github-actions-构建)
- [导入 Droidspaces](#导入-droidspaces)
- [启动桌面](#启动桌面)
- [Wayland 和 Anland 配置](#wayland-和-anland-配置)
- [Droidspaces USB Manager](#droidspaces-usb-manager)
- [账户、密码和用户名修改](#账户密码和用户名修改)
- [本地构建](#本地构建)
- [安装硬件固件](#安装硬件固件)
- [仓库结构](#仓库结构)
- [已知限制](#已知限制)
- [致谢](#致谢)

## 支持的系统

| 构建目标 | 基础镜像 | 桌面 profile | Anland Wayland | 备注 |
| --- | --- | --- | --- | --- |
| `Debian-13` | `debian:trixie` | `none`、`KDE`、`KDE mobile`、`GNOME` | 支持 | GNOME 仅支持 Anland Wayland。 |
| `Ubuntu-24` | `ubuntu:24.04` | `none`、`KDE` | 不支持 | 支持 `nosnap`。 |
| `Ubuntu-25` | `ubuntu:25.10` | `none`、`KDE` | 不支持 | 支持 `nosnap`。 |
| `Ubuntu-26` | `ubuntu:26.04` | `none`、`KDE`、`KDE mobile`、`GNOME` | 支持 | 支持 `nosnap`，GNOME 仅支持 Anland Wayland。 |
| `Fedora-43` | `fedora:43` | `none`、`KDE`、`KDE mobile` | 支持 | 某些设备需要启用硬件访问。 |
| `Fedora-44` | `fedora:44` | `none`、`KDE`、`KDE mobile` | 支持 | 某些设备需要启用硬件访问。 |
| `Arch` | `ogarcia/archlinux` | `none`、`KDE`、`KDE mobile` | 支持 | 使用 ARM64 Arch patched KWin/Xwayland；当前不建议使用本项目的 QEMU/binfmt 跨架构方案。 |

`all` 会按桌面/后端能力过滤 Dockerfile：GNOME 只构建 `Debian-13` 和 `Ubuntu-26`。`all-wayland` 在 `KDE` 和 `KDE mobile` 模式下构建五个 Wayland 目标，在 `GNOME` 模式下只构建上述两个目标；`KDE mobile` 和 `GNOME` 都会强制启用 Anland Wayland。

## 功能概览

- 多发行版 RootFS 构建：支持 Debian、Ubuntu、Fedora 和 Arch。
- 桌面选择：支持命令行 RootFS、KDE、KDE mobile 和 GNOME。
- 统一维护 TUI：容器内运行 `droidspaces-tui`、`dstui` 或 `ds-tui`，可安装 Mesa、Hangover Wine、Wine 字体及 Anland KDE/GNOME 组件。
- 桌面自动启动与故障恢复：X11、Plasma Wayland、Plasma Mobile 和 GNOME Wayland 使用统一的 systemd 服务模板，异常退出后会限频自动重启。
- Termux:X11 桌面启动：X11 模式下默认使用 `DISPLAY=:5`。
- PulseAudio 音频转发：支持 Unix socket、TCP 和关闭音频转发。
- 中文环境：可选启用 `zh_CN.UTF-8` 和 `Asia/Shanghai` 时区。
- 输入法：可选安装 Fcitx5；启用中文环境时会额外安装中文输入支持。
- Snapdragon GPU 支持：集成来自 `mesa-for-android-container` 的高通 GPU 相关配置。
- 全部七个发行版通过 `scripts/tui/install-mesa.sh` 安装对应的 ARM64 Mesa 驱动及最新版 `droidspaces-media-decode` VA-API 驱动，并仅锁定相关 Mesa 包。KWin/Xwayland 与 Mutter/Xwayland 分别由 Anland KDE、GNOME 安装器锁定。镜像源选择、完整性校验和各发行版锁定机制见 [scripts 目录说明](scripts/README.md#mesa-安装器)。
- 原生 ARM64 Google Chrome：全部桌面模式以 Chrome Stable 取代 Chromium；Debian/Ubuntu 和 Fedora 使用 Google 官方软件源，Arch 使用 AUR 的 ARM64 打包配方。

- 骁龙 8 Gen 2 Wayland 花屏修复：可选将 Turnip UBWC 修复开关写入 RootFS 环境变量。
- 容器增强：补充 Android/Droidspaces 环境下常见的硬件、网络和用户组识别配置。
- TMOE：可选集成 TMOE，容器内执行 `tmoe` 即可启动。
- 开发工具：可选安装编译器、CMake、Python 开发环境等。
- 压缩工具：可选安装 `zip`、`unzip`、`7z`、`xz`、`tar`、`gzip` 等工具。
- Docker：可选在 RootFS 内安装 Docker 相关软件包。
- 旧内核 systemd 兼容：可选在 systemd 主版本高于 257 的 apt、dnf 或 pacman 发行版中安装由包管理器管控的完整 systemd 257 包族；只支持 `none` 和经过验证的普通 `KDE`，Debian 13 等已是 257 或更低版本时会自动跳过安装。
- Wayland/Anland：通过独立的 [`droidspaces-package`](https://github.com/Goldzxcbug/droidspaces-package) 仓库提供 ARM64 patched KWin/Xwayland；GNOME 在 Debian 13、Ubuntu 26.04 上使用独立的 patched Mutter/Xwayland 包族。
- USB 设备管理：全部发行版内置 Droidspaces USB Manager，支持 USB 存储、ADB 设备节点、挂载、卸载和系统托盘。
- Release 自动发布：构建完成后会把 RootFS `.tar.xz` 上传到 GitHub Release。

## 构建选项说明

GitHub Actions 的主要输入项如下：

| 选项 | 可选值 | 默认值 | 说明 |
| --- | --- | --- | --- |
| 选择要构建的发行版 (`build_target`) | 发行版目标、`all`、`all-wayland` | `Debian-13` | 选择要构建的 RootFS。 |
| 自定义用户名 (`custom_username`) | 1–32 位字母、数字、`_`、`-`，以字母或 `_` 开头 | `Gold` | RootFS 默认用户。 |
| 桌面选择 (`desktop`) | `none`、`KDE`、`KDE mobile`、`GNOME` | `KDE` | 选择命令行环境或当前提供的桌面 profile。 |
| 桌面开机自启动 (`desktop_autostart`) | `true`、`false` | `true` | 是否创建统一的桌面自启动 systemd 服务。选择 `none` 时必须关闭。 |
| 显示后端 (`display_backend`) | `x11`、`anland-wayland` | `anland-wayland` | KDE Mobile 和 GNOME 会强制使用 `anland-wayland`；GNOME 不提供 X11 构建。 |
| PulseAudio 音频转发 (`PulseAudio`) | `socket`、`tcp`、`none` | `socket` | X11 模式下的音频转发方式。启用 Anland 时会被强制改为 `none`。 |
| 使用中文语言和时区 (`enable_zh_tz`) | `true`、`false` | 中文工作流默认为 `true` | 启用中文 locale 并设置上海时区。 |
| 高通骁龙 GPU 支持 (`enable_mesa`) | `true`、`false` | `true` | 启用高通 GPU/Mesa 相关支持。 |
| 修复 8Gen2 Wayland 花屏 (`enable_8gen2_wayland`) | `true`、`false` | `false` | 为 Debian 13、Ubuntu 26、Fedora 43/44 和 Arch 写入 `FD_DEV_FEATURES=enable_tp_ubwc_flag_hint=1` 到 `/etc/environment`。 |
| 集成 TMOE (`enable_tmoe`) | `true`、`false` | `true` | 集成 TMOE。 |
| 移除 Ubuntu Snap (`nosnap`) | `true`、`false` | `false` | 只对 Ubuntu 有意义，用于移除 Snap、snapd 和可能重新安装 snapd 的 APT 策略。 |
| systemd 257 旧内核兼容 (`enable_systemd257`) | `true`、`false` | `false` | 只支持 `none` 和普通 `KDE`。普通 KDE 保留所选后端与自启动设置；其他桌面强制回退到 `none`，`all-wayland` 下则直接拒绝。当前 systemd 高于 257 时安装完整原生包族并锁定，257 及更低版本跳过安装。 |
| 输入法 Fcitx5 支持 (`enable_srf`) | `true`、`false` | `false` | 安装 Fcitx5 输入法。 |
| 跨架构支持 (`enable_binfmt`) | `true`、`false` | `false` | 在 RootFS 内加入 binfmt 跨架构支持组件。Arch 当前不建议使用。 |
| NAT 和硬件识别支持 (`enable_yj`) | `true`、`false` | `true` | 启用容器硬件和网络识别增强。 |
| 开发工具集成 (`enable_kfgj`) | `true`、`false` | `false` | 安装开发工具链。 |
| 压缩工具集成 (`enable_zip`) | `true`、`false` | `true` | 安装常用压缩工具。 |
| Docker 集成 (`enable_docker`) | `true`、`false` | `false` | 在 RootFS 内安装 Docker 相关包。 |
| Wayland 软件包仓库 (`wayland_package_repository`) | 公开的 `owner/repository` | `Goldzxcbug/droidspaces-package` | 指定 `anland-kde-packages` 或 `anland-gnome-packages` Release 的来源；不会比较 RootFS Fork 与官方仓库的包时间。 |

桌面模式说明：

| 模式 | 说明 | 适合场景 |
| --- | --- | --- |
| `none` | 不安装桌面，只保留命令行环境。 | 需要轻量 RootFS、SSH、开发环境或自定义桌面的用户。 |
| `KDE` | KDE 桌面，包含系统工具、监控、文件管理和多媒体组件。 | 日常桌面使用。 |
| `KDE mobile` | KDE Plasma Mobile 相关组件。 | 手机屏幕和触控优先场景；会强制启用 Wayland。 |
| `GNOME` | GNOME Shell、控制中心、文件管理和常用桌面组件。 | Debian 13 或 Ubuntu 26 的 Anland Wayland 桌面；不支持 X11。 |

音频模式说明：

| 模式 | 说明 |
| --- | --- |
| `socket` | 使用 Unix socket 转发 PulseAudio。通常延迟更低，推荐在 X11 模式下使用。 |
| `tcp` | 使用 `127.0.0.1:4713` 转发 PulseAudio。兼容性较直观，但暴露面更大。 |
| `none` | 不配置 PulseAudio。Anland 模式下会自动使用此模式，因为 Anland App 自带音频路径。 |

### systemd 257 旧内核兼容

开启 `enable_systemd257` 后，RootFS 会运行 `scripts/systemd257.sh`。脚本会先检测发行版现有的 systemd 主版本：

- 支持白名单只有 `none` 和普通 `KDE`：普通 KDE 保留 X11/Anland Wayland 与桌面自启动设置；GNOME、KDE Mobile 及未来新增但未经验证的桌面会回退到 `none`，在 `all-wayland` 下则直接拒绝；
- 257 或更低版本（例如 Debian 13、Ubuntu 24.04）直接跳过；
- 高于 257 的 apt、dnf 和 pacman 系统从 `droidspaces-package` 的冻结兼容 Release `systemd257-packages` 安装对应发行版的完整 systemd 257 包族；后续包族先发布到不可变标签，再由 RootFS 一次性更新标签与校验元数据；
- 安装由发行版包管理器完成；APT 事务禁止删除任何现有包，安装完成后锁定 systemd 相关软件包，防止后续升级覆盖兼容版本。

该选项主要面向旧 Android 内核，属于实验性兼容方案，会显著增加构建时间；建议先在目标内核上验证 dbus、udev 和网络功能。

## 使用 GitHub Actions 构建

1. Fork 本仓库到自己的 GitHub 账号。
2. 打开 Fork 后仓库的 `Actions` 页面。
3. 选择中文工作流 `编译并发布 Droidspaces RootFS`，或英文工作流 `Build and Release Droidspaces RootFS`。
4. 点击 `Run workflow`。
5. 选择发行版、桌面 profile、显示后端、用户名和功能开关。
6. 如果要使用 Wayland/Anland，选择 `display_backend=anland-wayland`；支持 Debian 13、Ubuntu 26、Fedora 43/44 和 Arch。
7. 默认直接使用 `Goldzxcbug/droidspaces-package`。若要使用你 Fork 的包仓库，在 `wayland_package_repository` 填写公开的 `owner/repository`；RootFS 不会比较两个仓库谁更新。
8. 如需重新构建 patched KWin/Xwayland 或 Mutter/Xwayland 包，先在对应包仓库运行相应的 Anland 软件包工作流。
9. 等待 RootFS Actions 完成，然后打开 `Releases` 页面下载生成的 `.tar.xz`。

Release 通常包含：

- 一个或多个 RootFS 压缩包
- RootFS 文件名会同时记录桌面 slug 和显示后端，例如 `Ubuntu-26-kde-Wayland-Droidspaces-rootfs-aarch64-v20260702-120000.tar.xz`。
- Release 正文会记录构建目标、桌面 profile、显示后端、用户名和各功能开关。

## 导入 Droidspaces

1. 在 Droidspaces 中创建或导入容器。
2. RootFS 文件选择 Release 下载的 `.tar.xz`。
3. 如果 RootFS 包含桌面，必须在 Droidspaces 中开启 GPU 访问。
4. Ubuntu 和 Debian 系建议在特权模式中开启 `noseccomp`，并确保内核启用 `USER_NS`。否则某些桌面操作可能出现明显卡顿。
5. Fedora 某些设备需要开启硬件访问，否则可能出现桌面闪屏或崩溃。
6. Arch 建议宿主内核版本为 5.10 或更新。
7. 如果使用 X11 模式，准备好 Termux:X11。
8. 如果使用 Wayland/Anland 模式，按本文的 Wayland 和 Anland 配置完成宿主侧准备。

## 启动桌面

启用 `desktop_autostart` 后，构建流程安装统一的 `desktop-session.service`；服务读取 `/etc/droidspaces-desktop.conf` 决定实际会话：

| 桌面模式 | 服务文件 | 启动命令 |
| --- | --- | --- |
| KDE + X11 | `desktop-session.service` | `DISPLAY=:5 startplasma-x11` |
| KDE + Anland Wayland | `desktop-session.service` | `startplasma-wayland` |
| KDE Mobile + Anland Wayland | `desktop-session.service` | `startplasmamobile` |
| GNOME + Anland Wayland | `desktop-session.service` | `gnome-session --session=gnome`（构建时将 GNOME 会话变量写入 `/etc/environment`） |

该服务以 UID 1000 用户运行并读取 `/etc/environment`。桌面进程异常退出时会在 2 秒后自动重启；如果 60 秒内启动失败超过 5 次，systemd 会暂时停止重试，防止形成崩溃循环。正常退出不会触发自动重启。

### X11 模式

KDE 的 X11 模式适用于 `display_backend=x11` 的构建。桌面 profile 写入：

```text
XCURSOR_SIZE=48
DISPLAY=:5
```

建议保持 `desktop_autostart=true`，这也是当前默认选项。启用后 RootFS 会创建通用桌面自启动服务；只有需要自行管理桌面进程，或构建 `none` 命令行环境时，才应关闭该选项。

关闭自启动后，可以进入容器手动启动：

```bash
startplasma-x11
```

自启动的实际效果仍取决于 Droidspaces 的 systemd、权限和显示后端配置。如果自启动没有拉起桌面，可以进入容器后执行 `startplasma-x11` 排查。

### Wayland/Anland 模式

Wayland/Anland 模式适用于选择 `display_backend=anland-wayland` 的 Debian 13、Ubuntu 26、Fedora 43/44 和 Arch 构建。KDE 和 KDE Mobile profile 写入：

```text
XCURSOR_SIZE=48
WAYLAND_DISPLAY=wayland-0
QT_QPA_PLATFORM=wayland
ANLAND=1
ANLAND_SOCKET=/run/display.sock
ANLAND_DRM_DEVICE=/dev/dri/renderD128
```

完成宿主侧 Anland 配置后，在容器内执行：

```bash
startplasma-wayland
```

如果构建的是 `KDE mobile` 模式，对应的手动启动命令为：

```bash
startplasmamobile
```

GNOME profile 写入以下变量：

```text
XCURSOR_SIZE=48
XDG_SESSION_TYPE=wayland
XDG_CURRENT_DESKTOP=GNOME
XDG_SESSION_DESKTOP=gnome
GNOME_SHELL_SESSION_MODE=gnome
WAYLAND_DISPLAY=wayland-anland
GNOME_WAYLAND_DISPLAY=wayland-anland
QT_QPA_PLATFORM=wayland
ANLAND=1
ANLAND_SOCKET=/run/display.sock
ANLAND_DRM_DEVICE=/dev/dri/renderD128
```

对应的手动启动命令为：

```bash
gnome-session --session=gnome
```

## Wayland 和 Anland 配置

Wayland 支持依赖 [anland](https://github.com/superturtlee/anland) 和 [`droidspaces-package`](https://github.com/Goldzxcbug/droidspaces-package) Release 中的预编译包。KDE 使用 patched KWin/Xwayland，GNOME 使用 patched Mutter/Xwayland。GNOME 仅覆盖 Debian 13 与 Ubuntu 26；包的构建、更新和固定滚动 Release 均由独立包仓库维护。

### 一键安装 Anland KDE Release 包

`scripts/tui/install-anland-kde.sh` 会自动识别 ARM64 发行版，默认从 `Goldzxcbug/droidspaces-package` 的固定滚动 Release 安装匹配的 patched KWin/Xwayland 包，并锁定相关软件包。支持的系统、下载镜像、完整性校验、参数和独立安装方法已移至 [scripts 目录说明](scripts/README.md#anland-kde-安装器)。

从仓库根目录运行：

```bash
sudo ./scripts/tui/install-anland-kde.sh
```

GNOME 对应的安装器只支持 Debian 13 与 Ubuntu 26 ARM64，并读取固定的 `anland-gnome-packages` Release：

```bash
sudo ./scripts/tui/install-anland-gnome.sh
```

推荐构建选项：

| 选项 | 推荐值 |
| --- | --- |
| `build_target` | `Ubuntu-26` |
| `desktop` | `KDE`、`KDE mobile` 或 `GNOME` |
| `desktop_autostart` | `true` |
| `display_backend` | `anland-wayland` |
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

如果选择 `KDE mobile` 或 `GNOME`，工作流会强制启用 Wayland；GNOME 还会自动改用 patched Mutter/Xwayland 包族。

## Droidspaces USB Manager

全部 7 个发行版模板都会通过 `scripts/install-usb-manager.sh` 安装 [Droidspaces-USB-Manager](https://github.com/Yizhou147/Droidspaces-USB-Manager)，包括发行版依赖、命令行入口、应用菜单和桌面快捷方式。安装参数和更新方法见 [scripts 目录说明](scripts/README.md#usb-manager-安装器)。

导入 RootFS 时必须开启 Droidspaces 的硬件访问，否则容器内看不到 `/sys/bus/usb` 和 `/sys/bus/scsi` 设备。安装器会同时创建应用菜单入口和 `~/Desktop/usb-manager.desktop` 桌面快捷方式。进入 KDE 后，也可以运行：

```bash
usb-manager
```

另外提供两个命令行入口：

```bash
usb-passthrough
usb-storage-passthrough
```

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
  -i Debian-13.Dockerfile \
  -v local \
  -K KDE \
  -L true \
  -B x11 \
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
  -u Gold
```

使用 QEMU 构建 arm64 RootFS 示例：

```bash
chmod +x build_rootfs-qemu-aarch64.sh
./build_rootfs-qemu-aarch64.sh \
  -i Ubuntu-26.Dockerfile \
  -v local \
  -K KDE \
  -L true \
  -B anland-wayland \
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
  -u Gold
```

构建完成后会生成类似下面的文件：

```text
Ubuntu-26-kde-Wayland-Droidspaces-rootfs-aarch64-local.tar.xz
```

## 安装硬件固件

Debian 13 和 Ubuntu 24/25/26 RootFS 内置 `/usr/local/bin/download-firmware`，用于安装并解压硬件固件。依赖、重复运行行为和处理流程见 [scripts 目录说明](scripts/README.md#固件工具)。

该工具只会被复制到 RootFS，不会在构建或容器启动时自动执行。需要使用时，在容器内手动运行：

```bash
sudo download-firmware
```

## 仓库结构

```text
.
├── Arch.Dockerfile
├── Debian-13.Dockerfile
├── Fedora-43.Dockerfile
├── Fedora-44.Dockerfile
├── Ubuntu-24.Dockerfile
├── Ubuntu-25.Dockerfile
├── Ubuntu-26.Dockerfile
├── build_rootfs-native.sh
├── build_rootfs-qemu-aarch64.sh
├── scripts/
│   ├── README.md
│   ├── README_english.md
│   ├── configure-desktop.sh
│   ├── install-desktop.sh
│   ├── start-desktop-session.sh
│   ├── binfmt/
│   │   ├── qemu-binfmt-register.service
│   │   └── qemu-binfmt-register.sh
│   ├── desktops/
│   │   ├── gnome.sh
│   │   ├── kde.sh
│   │   └── kde-mobile.sh
│   ├── lib/
│   │   ├── anland-build.sh
│   │   └── desktop-config.sh
│   ├── start/
│   │   └── desktop-session.service
│   ├── tui/
│   │   ├── droidspaces-tui.sh
│   │   ├── install-anland-gnome.sh
│   │   ├── install-anland-kde.sh
│   │   ├── install-hangover-wine.sh
│   │   ├── install-mesa.sh
│   │   └── install-winefonts.sh
│   ├── bashrc.sh
│   ├── download-firmware
│   ├── install-usb-manager.sh
│   ├── install-anland-desktop.sh
│   ├── nosnap.sh
│   └── systemd257.sh
└── .github/workflows/
    ├── build-rootfs-core.yml
    ├── build-rootfs-releases-en.yml
    └── build-rootfs-releases.yml
```

KDE 与 GNOME Wayland 包的构建工作流和固定滚动 Release 已移到 [`droidspaces-package`](https://github.com/Goldzxcbug/droidspaces-package)。RootFS 根据桌面读取 `anland-kde-packages` 或 `anland-gnome-packages`，不会因 RootFS 仓库被 Fork 而自动改用 Fork。需要自维护软件包时，应在包仓库 Fork 中生成完整的同名 Release，再修改 `wayland_package_repository`。

## 已知限制

- Wayland/Anland 当前覆盖 Debian 13、Ubuntu 26、Fedora 43/44 和 Arch。
- Ubuntu 24 和 Ubuntu 25 当前按 X11 路径使用。
- `KDE mobile` 模式支持 Debian 13、Ubuntu 26、Fedora 43/44 和 Arch。
- `GNOME` 仅支持 Debian 13、Ubuntu 26 和 Anland Wayland，不支持 X11。
- 选择 `anland-wayland` 后，工作流会关闭 PulseAudio 转发，因为 Anland App 自带音频路径。
- Fedora 在部分设备上需要硬件访问，否则可能闪屏或崩溃。
- Ubuntu 和 Debian 在未启用 `noseccomp` 或内核缺少 `USER_NS` 时，可能出现卡顿。
- 默认密码为 `1234`，导入后应立即修改。
- 本项目内置的预编译 Wayland 包与上游 anland 的兼容性取决于构建时的上游状态。

## 致谢

- [Droidspaces-OSS](https://github.com/ravindu644/Droidspaces-OSS/)：本项目运行环境的基础。
- [mesa-for-android-container](https://github.com/lfdevs/mesa-for-android-container)：高通 Snapdragon GPU 驱动支持。
- [droidspaces-media-decode](https://github.com/Re-s/droidspaces-media-decode)：基于 Android MediaCodec 的容器 VA-API 硬件解码驱动。
- [TMOE](https://github.com/2moe/tmoe)：容器内管理工具。
- [anland](https://github.com/superturtlee/anland)：Wayland 显示后端和 patched KDE 相关工作。
- [Droidspaces-USB-Manager](https://github.com/Yizhou147/Droidspaces-USB-Manager)：适用于Droidspaces 的 USB 存储和 ADB 设备管理工具。
