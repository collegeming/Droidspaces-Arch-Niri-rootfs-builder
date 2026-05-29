# Droidspaces RootFS 自动构建 🚀
本项目目标，自动化构建支持 Droidspaces 的 Rootfs，并集成了大量选项，以确保用户开箱即用的体验

支持通过 GitHub Actions 进行全自动云端构建。在触发 Workflow 时，可以通过可视化菜单自由配置目标系统版本、桌面规模以及各项增强功能开关。

## ✨ 核心特性
- **多发行版支持**：支持快速构建 `Debian-13`, `Ubuntu-24`, `Ubuntu-25` 以及 `Arch Linux` 的 RootFS。
- **高度定制的 KDE 桌面**：可按需选择 KDE 桌面的体量,可以配合 `on` 脚本快速启动图形化界面
    - `conc` 精简版
    - `min` 最小化构造版
    - `none` 不使用桌面环境
- **PulseAudio 音频转发**：可以选择 TCP 模式（网卡转发）,SOCKET(套接字)，SOCKET依赖于本地文件，效率更高更推荐
- **原生中文环境**：一键开启中文语言环境并调整正确时区，解决容器内中文显示与配置繁琐的问题。
- **高通骁龙 GPU 支持**：内置对骁龙 GPU 的 Mesa 驱动增强，为桌面环境提供更流畅的硬件加速体验，驱动来源于: [lfdevs的项目](https://github.com/lfdevs/mesa-for-android-container)
- **高度模块化的组件集成**：支持通过参数灵活开启以下功能：
  - **输入法**：集成 Fcitx5 支持。
  - **TMOE 支持**：集成 TMOE 以方便部署和管理,项目来源于:[TMOE](https://github.com/2moe/tmoe)
  - **跨架构支持**：启用 binfmt 实现跨架构程序运行,Arch无法使用其Qemu。
  - **容器增强**：容器部分硬件与网络识别优化。
  - **生产力工具**：可选集成开发工具包、压缩工具包及 Docker 容器引擎。
## 🔥 使用教程
1. Fork 本项目
2. 打开 Actions ,选择 "编译并发布 Droidspaces RootFS"
3. 选择你想要的选项，运行工作流程脚本
4. 等待 10 min 左右，去 Releases 下载导入到 Droidspaces 使用

## ⚠️ 注意事项
- 所有要使用本项目的 Rootfs，并打开KDE桌面环境的，必须将 GPU 访问打开，配置 Termux:X11 打开
- Ubuntu 和 Debian 系的 Rootfs，开启 KDE 桌面环境之前，强烈建议把 特权模式 的 noseccomp 打开，不然会导致容器一些操作卡 10s
- Fedora 系必须把 硬件访问 打开，否则会造成桌面闪屏后崩溃！！！！！（需要卸载包，目前没找到）
- 遇到 DRI3 报错，请执行以下任意选项
```bash
----------------------------方法一----------------------------------------
/data/adb/ksud sepolicy patch "allow untrusted_app_27 droidspacesd fd use"
#以kernelsu为例
----------------------------方法二----------------------------------------
/data/adb/ksud sepolicy patch "permissive untrusted_app_27"
#这条命令可以解决所有问题,但是够危险,建议配合下面,查找untrusted_app_27域的app,再确认是否执行上面命令
/system/bin/dumpsys package packages | /system/bin/awk '/^ *Package \[/ {pkg=$2} /targetSdk=(26|27|28)$/ {print "App: " pkg " -> " $1}'
----------------------------方法三----------------------------------------
宽容内核
----------------------------方法四----------------------------------------
/data/adb/modules/droidspaces/etc/droidspaces.te  在这个文件路径

# Termux related
# Only uncommet line below if you are encounter any problems about dri3
# allow untrusted_app_27 droidspacesd fd use
改为
# Termux related
# Only uncommet line below if you are encounter any problems about dri3
allow untrusted_app_27 droidspacesd fd use

后重启设备
```
