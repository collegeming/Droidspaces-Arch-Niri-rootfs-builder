中文 | [English](README_english.md)

***

# 🚀 Droidspaces RootFS 自动构建

本项目旨在通过 GitHub Actions 实现全自动化的云端构建，为 Droidspaces 提供开箱即用、高度定制的 RootFS。

在触发 Workflow 时，您可以通过可视化菜单自由配置目标系统版本、桌面环境规模以及各项增强功能开关，轻松打造专属的移动端 Linux 容器环境。

## ✨ 核心特性

- **多发行版支持**：支持快速构建 `Debian-13`、`Ubuntu-24`、`Ubuntu-25`、`Ubuntu-26`、`Fedora 43` 以及 `Arch Linux` 的 RootFS。
- **按需定制的 KDE 桌面**：提供多种 KDE 桌面规模选择，配合 `on` 脚本即可快速启动图形界面：
  - `conc`：精简版
  - `min`：最小化构造版
  - `none`：仅命令行（不安装桌面环境）
- **灵活的音频转发 (PulseAudio)**：
  - 支持 `tcp`（网卡转发）与 `socket`（套接字）模式。
  - *强烈推荐使用* *`socket`* *模式*：依赖本地文件传输，效率更高、延迟更低。
- **原生中文化**：一键开启中文语言环境并自动校准时区，彻底解决容器内中文显示与配置繁琐的问题。
- **骁龙 GPU 硬件加速**：内置针对高通骁龙 GPU 的 Mesa 驱动增强，为桌面环境提供丝滑的硬件加速体验。（驱动上游：[lfdevs/mesa-for-android-container](https://github.com/lfdevs/mesa-for-android-container)）
- **模块化组件一键集成**：支持通过参数灵活开启以下功能：
  - **输入法**：原生集成 Fcitx5 支持。
  - **TMOE 部署**：集成 TMOE 环境。在终端输入 `tmoe` 即可自动安装依赖并运行。（项目上游：[TMOE](https://github.com/2moe/tmoe)）
  - **跨架构支持**：启用 `binfmt` 实现跨架构程序运行（注：Arch Linux 暂不支持此 QEMU 方案）。
  - **容器增强**：深度优化容器对底层硬件与网络环境的识别。
  - **生产力工具**：可选集成开发工具链、压缩工具包及 Docker 容器引擎。
- **Wayland 支持**（目前仅 Ubuntu 26）：使用 anland-kwin 为 Wayland 提供特殊支持，通过 patched KWin 和 Xwayland 实现与 anland 显示后端的直接通信。需要同时启用 KDE 桌面，详细配置参考下文"Wayland 配置方法"。项目上游：[anland](https://github.com/superturtlee/anland)
- **账户密码**：所有构建的 `Rootfs` 账户默认为: `Gold`，可自行修改；密码均为: `1234`

## 🔥 快速上手

1. **Fork** 本项目到您的 GitHub 仓库。
2. 进入 **Actions** 页面，在左侧选择工作流 **"编译并发布 Droidspaces RootFS"**。
3. 点击 **Run workflow**，在弹出的可视化菜单中选择您需要的配置选项，然后运行。
4. 等待约 10 分钟构建完成，前往 **Releases** 页面下载生成的 RootFS 压缩包，导入至 Droidspaces 即可使用。

## ⚠️ 避坑指南与注意事项

### 🖥️ 系统与桌面环境配置

- **通用要求**：所有使用本项目 RootFS 并开启 KDE 桌面环境的用户，**必须**在 Droidspaces 中开启「GPU 访问」权限，并配置好 Termux:X11。
- **Ubuntu / Debian 系**：在开启 KDE 桌面环境前，强烈建议在 Droidspaces 的特权模式配置中开启 **`noseccomp`**。否则可能会导致容器内部分操作出现长达 10 秒的卡顿。
- **Fedora 系**：有些设备**必须**在 Droidspaces 中开启「硬件访问」权限！否则会导致桌面闪屏并最终崩溃（目前需手动卸载冲突包，暂无完美替代方案，需要自行测试）。
- **Arch**: 内核版本必须在5.10以上。

### 📱 Wayland配置方法

- 在构建时选择 **Ubuntu26**，然后同时勾选 **KDE 桌面开机自启动** 和 **Wayland 支持**。
- 在[Releases · superturtlee/anland](https://github.com/superturtlee/anland/releases)中下载[virtual-drm-daemon.zip](https://github.com/superturtlee/anland/releases/download/2.0/virtual-drm-daemon.zip)刷入并重启，下载[app-debug.apk](https://github.com/superturtlee/anland/releases/download/2.0/app-debug.apk)并安装。
- 导入容器时，配置开启**硬件访问**、**SELinux宽容模式**，**特权模式**开启**nocaps**、**noseccomp**；
- 在高级选项中添加绑定挂载点，将 `/data/local/tmp/display_daemon.sock` 挂载到 `/run/display.sock`。
- 完成配置后在终端选择你的用户，执行 `startanland-kde.sh` 即可在 VirtualDRM（刚安装的apk）中使用KDE。

### 🛠️ DRI3 报错解决方案

如果您在启动图形环境时遇到 `DRI3` 相关的报错，说明存在 SELinux 权限拦截。请根据您的实际情况，选择以下**任意一种**方法进行修复：

**方法一：定向修补 SELinux 策略（推荐，以 KernelSU 为例）**
在宿主机（Android）的 Root 终端中执行：

```bash
/data/adb/ksud sepolicy patch "allow untrusted_app_27 droidspacesd fd use"

```

**方法二：放行整个 untrusted\_app\_27 域（较为激进）**
在宿主机 Root 终端执行以下命令直接放行。*注意：此方法会降低安全性，建议先运行第二行命令排查哪些 App 属于该域，确认无风险后再执行策略修补。*

```bash
# 排查属于 targetSdk 26-28 的 App：
/system/bin/dumpsys package packages | /system/bin/awk '/^ *Package \[/ {pkg=$2} /targetSdk=(26|27|28)$/ {print "App: " pkg " -> " $1}'

# 确认无误后执行放行：
/data/adb/ksud sepolicy patch "permissive untrusted_app_27"

```

**方法三：宽容内核 (Permissive Kernel)**

直接将设备的 SELinux 状态切换为 Permissive（宽容模式）。

**方法四：修改 Droidspaces 模块配置文件**
修改设备中 `/data/adb/modules/droidspaces/etc/droidspaces.te` 文件：

```text
# 找到以下部分：
# Termux related
# Only uncommet line below if you are encounter any problems about dri3
# allow untrusted_app_27 droidspacesd fd use

# 取消最后一行的注释，修改为：
allow untrusted_app_27 droidspacesd fd use

修改保存后，重启设备 即可生效。
```

## 致谢

- **[Droidspaces-OOS](https://github.com/ravindu644/Droidspaces-OSS/)** - 本项目实现的前提。
- **[mesa-for-android-container](https://github.com/lfdevs/mesa-for-android-container)** - 构建Rootfs的高通骁龙GPU驱动支持
- **[TMOE](https://github.com/2moe/tmoe)** - 容器里特别方便的管理工具
- **[anland](https://github.com/superturtlee/anland)** - 用于显示 Wayland 协议的APP
