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
- [DRI3 和 SELinux 问题处理](#dri3-和-selinux-问题处理)
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
| `Arch-KDE` | `ogarcia/archlinux` | `min`、`conc`、`none` | 不支持 | 内核建议 5.10 或更新；当前不建议使用本项目的 QEMU/binfmt 跨架构方案。 |

`all` 会构建全部 Dockerfile 模板。`all-wayland` 只构建支持 Wayland/Anland 的目标，也就是 `Debian-13-KDE`、`Ubuntu-26-KDE`、`Fedora-43-KDE` 和 `Fedora-44-KDE`，并强制启用 Wayland 支持。

## 功能概览

- 多发行版 RootFS 构建：支持 Debian、Ubuntu、Fedora 和 Arch。
- KDE 桌面可裁剪：支持命令行 RootFS、最小 KDE、精简 KDE 和移动版 KDE。
- 桌面自动启动与故障恢复：X11、Plasma Wayland 和 Plasma Mobile 使用统一的 systemd 服务模板，异常退出后会限频自动重启。
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
- Wayland/Anland：对 Debian 13、Ubuntu 26.04、Fedora 43 和 Fedora 44 提供稳定的 patched KWin 与 Xwayland 包。
- Release 自动发布：构建完成后会把 RootFS `.tar.xz` 和对应的音频启动脚本上传到 GitHub Release。

## 构建选项说明

GitHub Actions 的主要输入项如下：

| 选项 | 可选值 | 默认值 | 说明 |
| --- | --- | --- | --- |
| 选择要构建的发行版 (`build_target`) | 发行版目标、`all`、`all-wayland` | `Debian-13-KDE` | 选择要构建的 RootFS。 |
| 自定义用户名 (`custom_username`) | 字符串 | `Gold` | RootFS 默认用户。Release 中的音频启动脚本会同步替换该用户名。 |
| KDE 桌面选择 (`build_KDE`) | `conc`、`min`、`mobile`、`none` | `min` | KDE 桌面规模。`none` 表示只构建命令行环境。 |
| KDE 桌面开机自启动 (`build_KDE_plus`) | `true`、`false` | `true` | 是否创建 KDE 自启动 systemd 服务。需要已安装 KDE；选择 `none` 桌面时应关闭。 |
| Wayland 支持 (`enable_anland_kde`) | `true`、`false` | `false` | 是否启用 Wayland/Anland 支持。支持 Debian 13、Ubuntu 26、Fedora 43 和 Fedora 44。 |
| PulseAudio 音频转发 (`PulseAudio`) | `socket`、`tcp`、`none` | `socket` | X11 模式下的音频转发方式。启用 Anland 时会被强制改为 `none`。 |
| 使用中文语言和时区 (`enable_zh_tz`) | `true`、`false` | 中文工作流默认为 `true` | 启用中文 locale 并设置上海时区。 |
| 高通骁龙 GPU 支持 (`enable_mesa`) | `true`、`false` | `true` | 启用高通 GPU/Mesa 相关支持。 |
| 修复 8Gen2 Wayland 花屏 (`enable_8gen2_wayland`) | `true`、`false` | `false` | 为 Debian 13、Ubuntu 26、Fedora 43/44 写入 `FD_DEV_FEATURES=enable_tp_ubwc_flag_hint=1` 到 `/etc/environment`。 |
| 集成 TMOE (`enable_tmoe`) | `true`、`false` | `true` | 集成 TMOE。 |
| 移除 Ubuntu Snap (`nosnap`) | `true`、`false` | `false` | 只对 Ubuntu 有意义，用于移除 Snap、snapd 和可能重新安装 snapd 的 APT 策略。 |
| 输入法 Fcitx5 支持 (`enable_srf`) | `true`、`false` | `false` | 安装 Fcitx5 输入法。 |
| 跨架构支持 (`enable_binfmt`) | `true`、`false` | `false` | 在 RootFS 内加入 binfmt 跨架构支持组件。Arch 当前不建议使用。 |
| NAT 和硬件识别支持 (`enable_yj`) | `true`、`false` | `true` | 启用容器硬件和网络识别增强。 |
| 开发工具集成 (`enable_kfgj`) | `true`、`false` | `false` | 安装开发工具链。 |
| 压缩工具集成 (`enable_zip`) | `true`、`false` | `true` | 安装常用压缩工具。 |
| Docker 集成 (`enable_docker`) | `true`、`false` | `false` | 在 RootFS 内安装 Docker 相关包。 |
| 构建 Wayland 预编译包 (`build_wayland_packages`) | `true`、`false` | `false` | 构建 RootFS 前触发 KWin/Xwayland 预编译包更新流程。 |

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

## 使用 GitHub Actions 构建

1. Fork 本仓库到自己的 GitHub 账号。
2. 打开 Fork 后仓库的 `Actions` 页面。
3. 选择中文工作流 `编译并发布 Droidspaces RootFS`，或英文工作流 `Build and Release Droidspaces RootFS`。
4. 点击 `Run workflow`。
5. 选择发行版、KDE 模式、用户名和功能开关。
6. 如果要使用 Wayland/Anland，建议选择 `Ubuntu-26-KDE`、`Debian-13-KDE`、`Fedora-43-KDE` 或 `Fedora-44-KDE`，并开启 `enable_anland_kde`。
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

Wayland/Anland 模式适用于启用 `enable_anland_kde` 的 Debian 13、Ubuntu 26、Fedora 43 和 Fedora 44 构建。默认环境变量包括：

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

Wayland 支持依赖 [anland](https://github.com/superturtlee/anland) 以及本仓库内的 patched KWin/Xwayland 预编译包。建议使用 `Ubuntu-26-KDE`，也可以使用 `Debian-13-KDE`、`Fedora-43-KDE` 或 `Fedora-44-KDE`。Fedora 44 已稳定支持 Wayland/Anland；它使用 Fedora 43 的 Anland 构建脚本，但在 Fedora 44 容器内重新构建 RPM。

### 一键安装 anland-build 包

`anland-build/install.sh` 会自动识别当前发行版，安装对应的 patched KWin/Xwayland 包，并防止系统更新将它们覆盖。如果系统仓库中的版本更新，脚本会允许将相关包降级到本仓库的 patched 版本；已经 hold 的相关包也会在更新后重新设置 hold。
脚本会按 `LC_ALL`、`LC_MESSAGES`、`LANG` 的优先级读取系统语言：中文 locale 输出中文，其他 locale 输出英文。

支持 Debian 13、Ubuntu 26.04、Fedora 43 和 Fedora 44，仅支持 ARM64/aarch64。Debian/Ubuntu 使用 `apt-mark hold`，Fedora 通过 `/etc/dnf/dnf.conf` 的 `exclude` 实现等效锁定。

在仓库根目录运行：

```bash
sudo ./anland-build/install.sh
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

## DRI3 和 SELinux 问题处理

如果启动图形环境时出现 `DRI3` 相关错误，通常是 SELinux 拦截导致 Droidspaces 与图形后端之间的文件描述符传递失败。可以选择以下任意一种方案。

### 方案一：精确修补 SELinux 策略

以 KernelSU 为例，在 Android 宿主机 Root 终端执行：

```bash
/data/adb/ksud sepolicy patch "allow untrusted_app_27 droidspacesd fd use"
```

这是推荐方案，影响范围较小。

### 方案二：放行整个 `untrusted_app_27` 域

先查看哪些应用属于 targetSdk 26 到 28：

```bash
/system/bin/dumpsys package packages | /system/bin/awk '/^ *Package \[/ {pkg=$2} /targetSdk=(26|27|28)$/ {print "App: " pkg " -> " $1}'
```

确认风险可接受后执行：

```bash
/data/adb/ksud sepolicy patch "permissive untrusted_app_27"
```

这个方案影响范围更大，只建议用于临时排障或明确知道风险的设备。

### 方案三：使用宽容内核

将设备 SELinux 状态切换为 Permissive。这个方案最简单，但安全边界最弱。

### 方案四：修改 Droidspaces 模块策略文件

编辑宿主机中的：

```text
/data/adb/modules/droidspaces/etc/droidspaces.te
```

找到：

```text
# Termux related
# Only uncomment the line below if you encounter any problems about DRI3
# allow untrusted_app_27 droidspacesd fd use
```

取消最后一行注释，改为：

```text
allow untrusted_app_27 droidspacesd fd use
```

保存后重启设备。


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
├── Debian-13-KDE.Dockerfile
├── Fedora-43-KDE.Dockerfile
├── Fedora-44-KDE.Dockerfile
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
│   ├── nosnap.sh
│   ├── on_aaudio_socket.sh
│   └── on_aaudio_tcp.sh
├── scripts/binfmt/
│   ├── qemu-binfmt-register.service
│   └── qemu-binfmt-register.sh
├── anland-build/
│   ├── install.sh
│   ├── Debian13/
│   ├── Fedora43/
│   ├── Fedora44/
│   └── ubuntu2604/
└── .github/workflows/
    ├── build-kde-wayland.yml
    ├── build-rootfs-releases-en.yml
    ├──  build-rootfs-releases.yml
    └── clear.yml
```

`anland-build/` 存放 patched KWin 和 Xwayland 预编译包以及一键安装脚本。`build-kde-wayland.yml` 可以重新构建这些包并提交回仓库。当前中文 RootFS workflow 文件名包含一个前导空格，路径为 `.github/workflows/ build-rootfs-releases.yml`。

## 已知限制

- Wayland/Anland 当前只覆盖 Debian 13、Ubuntu 26 和 Fedora 43/44。
- Ubuntu 24、Ubuntu 25 和 Arch 当前按 X11 路径使用。
- `mobile` 模式只允许 Debian 13、Ubuntu 26 和 Fedora 43/44。
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
