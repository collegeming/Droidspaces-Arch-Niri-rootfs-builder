中文 | [English](README_english.md)

# Droidspaces Arch-Niri RootFS Builder

面向 ARM64 Android/Droidspaces（尤其 4.19 内核设备）的 **Arch Linux + niri/ANiri + Anland + Noctalia** RootFS 构建器。唯一 active 目标是 `Droidspaces-Arch-Niri.Dockerfile`；可生成 kitty、ghostty 或两种终端变体，并选择 `remote=none|wayvnc|lamco`。

Droidspaces 是共享 Android 内核、使用 namespace + `pivot_root` 的特权容器，**不是 PRoot**。本仓库只组合并固定 Linux RootFS；Android APK、root helper、Surface/MediaCodec 组件始终属于设备侧前置依赖，不会装进 RootFS。

- Canonical repository: <https://github.com/collegeming/Droidspaces-Arch-Niri-rootfs-builder>
- Workflow: [Build and release Droidspaces Arch-Niri RootFS](https://github.com/collegeming/Droidspaces-Arch-Niri-rootfs-builder/actions/workflows/build-arch-niri-rootfs.yml)
- English documentation: [README_english.md](README_english.md)
- 已归档的多发行版 KDE 文件：[legacy/README.md](legacy/README.md)

## 组件关系与职责

| 项目 | 职责 | 当前 Builder 状态 |
| --- | --- | --- |
| [niri](https://github.com/niri-wm/niri) / [Celvra/ANiri](https://github.com/Celvra/ANiri) | Linux Wayland 合成器及 Anland 显示后端 | 暂时消费已验证的上游 ANiri `v0.2.0` ARM64 资产。 |
| [collegeming/ANiri-anland-tuned](https://github.com/collegeming/ANiri-anland-tuned) | 针对 Anland 的 Linux compositor、输入、剪贴板和 polling 调优 | 调优提交已存在，但尚无可消费的 immutable ARM64 Release；Builder **没有虚构或提前切换 pin**。 |
| [superturtlee/anland](https://github.com/superturtlee/anland) / [collegeming/anland-bridge](https://github.com/collegeming/anland-bridge) | Android Surface、`local|remote|both` 显示状态、MediaCodec、FD/root helper | 设备侧 prerequisite；APK、daemon、Magisk 资产不进入 RootFS。candidate 已编译通过，但公开 immutable Release/checksum 尚未发布。 |
| [collegeming/lamco-anland-bridge](https://github.com/collegeming/lamco-anland-bridge) | Linux RDP/TLS/EGFX、输入、CLIPRDR 和私有 UDS listener | `remote=lamco` 固定消费已发布并校验的 ARM64 二进制，不在 RootFS 内构建 Rust。 |
| 本 Builder | 组合并 pin Linux RootFS，生成变体、校验和与 metadata，并记录 Android prerequisite | 唯一 active Dockerfile/workflow；旧 KDE 内容仅在 `legacy/` 保存。 |

## 架构与数据路径

### 两条不同的 Unix socket

两条 socket 不可互换：

| 路径 | 用途 | Android 侧来源 |
| --- | --- | --- |
| `/run/display.sock` | ANiri 本地显示链，将桌面送到 Android Surface consumer | Droidspaces/Anland 挂载的 display socket。 |
| `/run/anland-rdp/bridge.sock` | Lamco 专用的 HMAC mutual-auth 私有桥接通道 | 必须把目录 `/data/local/tmp/anland-rdp` bind mount 到 `/run/anland-rdp`。 |

Lamco 必须绑定**目录**，不能绑定单个 `bridge.sock` inode。服务重启会安全地 unlink/rebind socket；目录绑定才能继续看到新 inode。不要将该 socket 映射到网络，也不要使用 `chmod 777`。

```text
/data/local/tmp/anland-rdp -> /run/anland-rdp
```

### Android 显示状态：local / remote / both

这是 Android `anland-bridge` 的显示状态，不是 Builder 的 `remote` 输入：

- `local`：只保持本机 Android Surface viewer。
- `remote`：只保持远程硬件编码/RDP 图形链。
- `both`：同时保持本机 Surface 和远程 viewer。
- viewer 缺失或长期最小化，且没有本地 Surface 时，Android 必须停止 MediaCodec encoder 和图形消费链，避免空闲编码与持续耗电。

Builder 的 `remote=none|wayvnc|lamco` 只决定 RootFS 是否安装远程服务。

### 编码、输入、剪贴板与音频边界

- H.264 只允许 **Android MediaCodec 硬件 Surface encoder**。没有 OpenH264、x264、FFmpeg/libavcodec 软件 fallback；硬件链不可用时失败或无视频。
- Lamco 不通过 Portal、PipeWire、screencopy 或 Android MediaProjection 捕获整块屏幕；它只消费专用 Anland bridge 的 ANiri 桌面。
- Win/Super 作为原始 RDP input 转发；niri 保持原生 `Mod+T`、`Mod+E` 等语义，禁止 Win→Alt 映射。
- RDP 剪贴板仅支持 `CF_UNICODETEXT` 文本，包括 CJK、emoji、换行和清空；不支持图片、文件、HTML 或 RTF。
- 当前无 RDPSND，PC 端没有 RDP 音频；本地 Android audio 是独立链路。

## 精确版本与兼容矩阵

| 组件 | Repository / tag | Source commit | Asset / SHA-256 | 状态 |
| --- | --- | --- | --- | --- |
| ANiri baseline | `Celvra/ANiri` / `v0.2.0` | `cfd31db9c79c681a11ebc1afdb80fa7b31c4f7e0` | `niri-arm64-linux-bin` / `9d7e8d3533e73f95a9141c81346c5f33777b9be38b87bf703cb322b340eee6eb` | 当前 RootFS 实际消费。 |
| ANiri tuned | `collegeming/ANiri-anland-tuned` / branch `anland-poll-optimize` | `74ce2a92eb2151d729818a784ced605ec950b56c` | 尚无 Release asset/checksum | 不消费；等待真实 immutable Release 后再改 pin。 |
| Android anland bridge | `collegeming/anland-bridge` / branch `bridge-service-toggle` | `95b2d73ff799639ce8576ff908f13f5a31e024a1` | candidate 已成功；公开 Release/checksum 尚不可用 | 设备侧 prerequisite，不进入 RootFS。 |
| Lamco | `collegeming/lamco-anland-bridge` / `anland-v0.2.0` | `03902875622f04c8c64ab52fd4dc72981bb93e64` | `lamco-anland-bridge-0.2.0-aarch64-unknown-linux-gnu.tar.xz` / `593a2639f7c06bc3f453ae094114f85e03f442f5d9482d132b5662cd9a146eea` | `remote=lamco` 实际消费。 |
| Lamco IronRDP pin | `collegeming/IronRDP` / branch `anland-preauth-timeout` | `33fc287b83af35ba3650519fe059db99d1cdf131` | 记录在 Lamco metadata | 由 Lamco Release 固定。 |

RootFS 内会写入 `/usr/share/doc/droidspaces-arch-niri/ANIRI-PIN.txt` 与 `BUILD-COMPATIBILITY.txt`。workflow 还会生成外部 `BUILD-METADATA.txt` 和 `SHA256SUMS`，其中 Builder commit 取运行时精确 `github.sha`，不会使用可变 `latest`。

## Active RootFS 功能

- ARM64 Arch Linux；niri/ANiri over Anland；Noctalia + fuzzel。
- kitty、ghostty 或 `both` 两个独立 RootFS 变体。
- fcitx5 + Rime-Ice、中文 locale、Nemo、neovim、fish/reef/Fisher/Tide 和 Maple Mono NF CN。
- Qualcomm KGSL Mesa、Snapdragon 8 Gen 2 UBWC hint。
- systemd 257 旧内核兼容、Droidspaces USB manager、可选 firmware/binfmt/container integration。
- 可选开发工具、压缩工具、Docker 和 TMOE。
- `remote=none|wayvnc|lamco`。

RootFS 默认 Linux 用户为 `droid`，构建参数可修改。镜像目前为 Linux 账户设置初始密码 `1234`；导入后必须立即通过 `passwd` 修改。Lamco 不复用该密码，必须单独配置强 RDP 凭据。

## GitHub Actions 构建

唯一 active workflow 为 `.github/workflows/build-arch-niri-rootfs.yml`，名称为 **Build and release Droidspaces Arch-Niri RootFS**。

主要输入：

| 输入 | 值 | 默认值 |
| --- | --- | --- |
| `version` | 安全的版本/文件名标签；`candidate` 自动附加 run id/attempt | `candidate` |
| `publish_release` | 是否发布 immutable tag/Release | `false` |
| `build_mode` | `native-arm64` 或 `qemu-x86_64` | `native-arm64` |
| `username` | RootFS 用户名 | `droid` |
| `terminal` | `kitty|ghostty|both` | `kitty` |
| `remote` | `none|wayvnc|lamco` | `none` |
| `niri_autostart` | niri 自动启动 | `true` |
| `enable_zh_locale` | 中文 locale/上海时区 | `true` |
| `enable_fcitx_rime` | fcitx5 + Rime-Ice | `true` |
| `enable_qualcomm_mesa` | Qualcomm KGSL Mesa | `true` |
| `enable_systemd257` | systemd 257 兼容运行时 | `true` |
| `enable_usb_manager` | Droidspaces USB manager | `true` |
| `enable_firmware` | Linux firmware 包 | `false` |
| `enable_binfmt` | RootFS 内 binfmt helper | `false` |
| `enable_container_integration` | Droidspaces 硬件/网络集成 | `true` |
| `enable_8gen2_wayland` | 8 Gen 2 UBWC hint | `false` |
| `enable_dev_tools` | 开发工具链 | `false` |
| `enable_compression_tools` | 附加压缩工具 | `true` |
| `enable_docker` | RootFS 内 Docker 包 | `false` |
| `enable_tmoe` | TMOE | `false` |

### Candidate 与发布安全

1. 正常验证保持 `publish_release=false`；产物作为 Actions artifact，不创建 tag/Release。
2. `native-arm64` 固定使用 ARM64 runner，并由脚本拒绝非 ARM64 host。
3. `qemu-x86_64` 在 x86_64 runner 显式注册 arm64 QEMU，仅构建 `linux/arm64`；ARM64 host 不能误用该脚本。
4. `terminal=both` 展开为 kitty 与 ghostty 两个变体；文件名始终包含真实 `remote` 和 `terminal`：

   ```text
   Droidspaces-Arch-Niri-Anland-aarch64-<version>-<remote>-<terminal>.tar.xz
   ```

5. 每个 archive 先通过 `xz -t`、tar listing 和独立 SHA-256 校验，再汇总 exact asset set。
6. `publish_release=true` 只允许从 `main` 和显式非 `candidate` 版本运行。workflow 在构建前、发布前分别验证 tag/Release 不存在；拒绝覆盖已有 tag、Release 或 asset。
7. 第三方 actions 固定 40 位 commit SHA；默认权限为 `contents: read`，仅 release job 提升为 `contents: write`。

本项目不会自动触发 workflow。只有人工在 GitHub Actions 页面运行时才会开始构建；不要把旧 run/Release 当成当前 commit 的验证结果。

## 本地构建

要求 Docker + Buildx + `xz`。所有命令从仓库根目录执行。

ARM64 host 原生构建：

```bash
./build_rootfs-native.sh \
  -i Droidspaces-Arch-Niri.Dockerfile \
  -v local \
  -u droid \
  -T both \
  -R lamco \
  -N true -g true -h true -c true -S true \
  -U true -F false -a false -b true -t false \
  -d false -e true -f false -j false
```

x86_64 host 必须使用显式 QEMU 脚本：

```bash
./build_rootfs-qemu-aarch64.sh \
  -i Droidspaces-Arch-Niri.Dockerfile \
  -v local \
  -u droid \
  -T kitty \
  -R none \
  -N true -g true -h true -c true -S true \
  -U true -F false -a false -b true -t false \
  -d false -e true -f false -j false
```

脚本会拒绝错误 host 架构、非 canonical Dockerfile、不安全版本/用户名、无效 boolean、terminal 或 remote。

## 导入与本地显示

1. 把 `.tar.xz` 导入 Droidspaces 特权容器；不要按 PRoot 教程配置。
2. 为 Qualcomm Mesa/niri 启用 GPU 与必要硬件访问。
3. 4.19 内核建议保持 `enable_systemd257=true`。`enable_binfmt` 只有目标内核启用 `CONFIG_BINFMT_MISC` 才有意义。
4. 配置 Anland Android 端，并提供本地显示 socket 到 `/run/display.sock`。具体 Android 资产应来自 `anland-bridge` 的设备侧 Release；不要从 RootFS 寻找 APK/daemon。
5. `niri.service` 默认自动启动；检查命令：

   ```bash
   systemctl status niri.service
   journalctl -u niri.service
   ```

6. 首次导入后修改 Linux 账户密码：`passwd`。

## 远程访问

### `remote=none`

不安装远程服务，只使用 Android 本地 Surface 显示链。

### `remote=wayvnc`

wayvnc 监听 guest `0.0.0.0:5900`，当前默认没有 VNC 密码：仅可在受信任网络使用，并通过防火墙、SSH tunnel 或 Droidspaces 隔离/端口发布策略限制入口。

- **host/shared network**：连接 `<手机 WLAN IP>:5900`。
- **isolated/NAT network**：必须把 guest TCP 5900 发布到 host 端口，然后使用 Droidspaces 实际显示的 `<host address>:<host port>`；未发布时手机 WLAN IP 不能直接访问 guest 5900。

wayvnc 使用独立的 Wayland screencopy/virtual-input 路径，不等同于 Lamco 的私有硬件编码桥。

### `remote=lamco`

Lamco Release 已固定并在安装时验证 archive entry、AArch64 ELF、interpreter、动态依赖、metadata、SBOM 和 license。RootFS 不预置 config、bridge token、TLS private key 或 RDP 凭据，也不会自动启用未经配置的服务。

1. Android host 创建 `/data/local/tmp/anland-rdp`，并做目录 bind：

   ```text
   /data/local/tmp/anland-rdp -> /run/anland-rdp
   ```

2. 容器启动后核对 PID 1 mount：

   ```bash
   findmnt --task 1 --mountpoint /run/anland-rdp --output TARGET,FSROOT
   ```

3. 在 Android App 选择 `remote` 或 `both`，获取 32 位小写十六进制 bridge token。
4. 在容器内交互配置：

   ```bash
   sudo setup-lamco-anland-bridge
   ```

   helper 关闭 xtrace、隐藏读取 token/密码、拒绝全零 token 和弱密码，要求 RDP 密码至少 12 个字符且不同于用户名。它原子写入 mode `0600` 的 config，使用专用 `lamco-anland-bridge` no-login 用户，并准备 mode `0700` 的 TLS/socket 目录。

5. 检查服务：

   ```bash
   systemctl status lamco-anland-bridge.service
   journalctl -u lamco-anland-bridge.service
   ```

6. 网络入口：
   - **host/shared**：`mstsc` 连接 `<手机 WLAN IP>:3389`。
   - **isolated/NAT**：发布 guest TCP 3389 后，连接 Droidspaces 实际显示的 `<host address>:<host port>`。只有明确把 host address/port 配成手机 WLAN IP:3389 时，入口才是该地址。
   - 两种模式都应只允许目标 PC/受信任子网；绝不转发私有 UDS，也不暴露调试 TCP 33910。

首次自签名 TLS 会让 `mstsc` 显示证书提示，应核对设备身份；生产环境可替换为受信任证书和匹配私钥。

## 验证状态与未验证边界

静态/构建系统可验证：

- active Bash `bash -n`、ShellCheck；workflow YAML parse、actionlint；Dockerfile parse。
- active/legacy scope、唯一 workflow、旧 active 参数、action SHA、permissions、mode、symlink、secret signature 和 hard-coded URL 扫描。
- workflow 产物的 xz/tar、文件名、变体数、SHA256、metadata 与 exact Release asset set。
- Lamco Release installer 的 AArch64 ELF、依赖、metadata、SBOM/license 与软件 H.264 依赖拒绝。

除非有对应设备测试记录，否则以下均视为**未验证**：目标手机导入/启动、实际 GPU、Android Surface 生命周期、MediaCodec、`mstsc` 互操作、剪贴板端到端、host/NAT UI、功耗、温度、长时间稳定性。Actions 成功不能替代真机验证。

## Legacy KDE 内容

旧 Debian/Ubuntu/Fedora/Arch-KDE/Artix/NixOS Dockerfiles、KDE 脚本和旧 workflow 保留在 `legacy/`，用于历史参考和恢复，不是 active target：

- `.github/workflows` 中不会发现它们，GitHub Actions 不会注册或自动运行。
- active scripts 不再接受 `build_KDE`、`build_KDE_plus`、`enable_anland_kde`、`build_wayland_packages`、`all-wayland` 等旧参数。
- 旧文件可能保留外部上游 `Goldzxcbug/Droidspaces-rootfs-KDE-builder` pin；这不是本仓库 self URL，也不代表 active 支持。

详见 [legacy/README.md](legacy/README.md)。

## 致谢

- [Droidspaces-OSS](https://github.com/ravindu644/Droidspaces-OSS/)
- [niri](https://github.com/niri-wm/niri)、[ANiri](https://github.com/Celvra/ANiri)、[Noctalia](https://github.com/noctalia-dev/noctalia)
- [superturtlee/anland](https://github.com/superturtlee/anland)
- [lamco-admin/lamco-rdp-server](https://github.com/lamco-admin/lamco-rdp-server) 与 [IronRDP](https://github.com/Devolutions/IronRDP)
- [mesa-for-android-container](https://github.com/lfdevs/mesa-for-android-container)
- [Droidspaces-USB-Manager](https://github.com/Yizhou147/Droidspaces-USB-Manager)
