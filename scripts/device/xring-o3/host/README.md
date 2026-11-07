# XRING-O3 Android 主机侧 MaliBridge 包

本目录是小米平板 9 Pro Max（XRING-O3 / Mali-G2-Ultra-NX）Android 主机侧的全部文件。它把原先只存在于单台设备 `/data/local/tmp` 下的 bionic 服务端、supervisor、Anland socket 别名与验证脚本整理成可复制、可校验的一组脚本，使同型号设备不必再手工拼装。

配套的 rootfs 侧载荷由 `scripts/device/xring-o3/README.md` 描述，以 `mali-stack-<version>.tar.zst` 发布；主机侧以 `mali-host-<version>.tar.zst` 发布。**复现一台设备需要两个包**：rootfs 包负责容器内的 Mesa/ICD/zc-run/mbctl，主机包负责本目录与 `vkbridge-server`。

## 主机与 rootfs 的边界

| 组件 | 位置 | 不能放进 rootfs 的原因 |
| --- | --- | --- |
| `vkbridge-server` | Android 主机 `$SRV/mbsrv/` | bionic 可执行文件，依赖 `/dev/mali0` 与 vendor Mali 驱动 |
| `bridge-supervisor.sh` | Android 主机 `$SRV/` | server 在父进程退出时退出，需要一个常驻父进程 |
| Anland socket 稳定别名 | Android 主机 `$ANLAND_LINK` | 容器看不到宿主 `/data/local/Droidspaces/Net/` |
| 容器 `/run/display.sock` | Droidspaces 绑定挂载 | 由宿主编排，rootfs 内只能检查不能创建 |
| `/dev/dri/card0` | 容器内 oneshot（`card0.sh`） | XRING-O3 只暴露主节点，容器需 `CAP_MKNOD` 自建 |
| Mesa / ICD / libgbm / zc-run / mbctl | 容器 `/opt/mali-stack/current` | 属于 `mali-stack-*` bundle，不随本目录发布 |

## 文件清单

| 文件 | 作用 | 运行位置 |
| --- | --- | --- |
| `host.env.example` | 全部可覆盖配置的模板 | 主机 |
| `install-host.sh` | 安装/卸载本目录脚本与 server；PC 走 adb，设备上本地安装 | 主机 |
| `start-bridge.sh` | 手动启动 server 与 supervisor，打印 pid 和 socket 路径 | 主机 |
| `stop-bridge.sh` | 停止 server、supervisor，删除 socket 与 pid 文件，保留日志 | 主机 |
| `bridge-supervisor.sh` | 常驻父进程：写 `server.pid`、等 socket、置 `oom_score_adj=0` | 主机 |
| `anland-link.sh` | 解析真实 Anland socket，校验活跃后原子替换稳定别名 | 主机 |
| `verify-host.sh` | 只读 PASS/FAIL 检查 | 主机 |

配置优先级：**环境变量 > `$SRV/host.env` > 内置默认值**。默认值：

| 变量 | 默认值 |
| --- | --- |
| `CTR` | `archniri` |
| `ROOTFS` | `/data/local/Droidspaces/Containers/archniri/rootfs` |
| `SRV` | `/data/local/tmp/xring-o3-host` |
| `ANLAND_LINK` | `/data/local/tmp/archniri-display.sock` |
| `BUDGET_TOTAL_MB` / `BUDGET_PID_MB` / `BUDGET_FLOOR_MB` | `4096` / `2048` / `2048` |
| `MAP_LIMIT` | `60000` |
| `CONTROL_UIDS` | `1000` |

`BUDGET_*` 与 `MAP_LIMIT` 在每次启动时导出为 `VKBRIDGE_MEM_BUDGET_TOTAL_MB`、`VKBRIDGE_MEM_BUDGET_PID_MB`、`VKBRIDGE_MEM_MIN_AVAIL_MB`、`VKBRIDGE_MAP_LIMIT`；`CONTROL_UIDS` 导出为 `VKBRIDGE_CONTROL_UIDS`。环境变量优先于容器内 `budget.conf`。

## 前置条件

| 项目 | 要求 | 说明 |
| --- | --- | --- |
| Root | KernelSU | 实测 root 上下文 `u:r:ksu:s0`；本目录脚本不自动提权，需 `su -c` 调用 |
| Droidspaces | APK 7.1.0 | CLI 在 `/data/local/Droidspaces/bin/droidspaces`，**不在 PATH** |
| 容器 | `archniri` 已创建并运行 | rootfs 目录由 Droidspaces 管理 |
| Anland | Android 侧 APK 已安装 | 实测 `com.anlandnext` 0.1、`com.anland.consumer` 5.19-mali-stride-fix 均已安装 |
| 设备 | Android 17 (SDK 37) | 实测型号 `M367FC` / product `yingtian` / board `xring_o3_asic` |
| Bootloader | 锁定即可 | 本目录不写 boot、不要求解锁、不重启设备 |
| PC 侧工具 | `adb`；`--bundle` 与打包需要 `zstd` 和 GNU tar | `install-host.sh` 与 `make-*.sh` 在 PC 上运行 |

## 安装

### 主机包（PC 通过 adb，推荐）

```sh
# 1. 把主机包解压到设备（install-host.sh 在 PC 上解压，再把文件推入设备）
bash scripts/device/xring-o3/host/install-host.sh \
     --bundle dist/mali-host-2026.11.08.tar.zst

# 2. 已有 vkbridge-server 时也可以只传二进制
bash scripts/device/xring-o3/host/install-host.sh \
     --server /path/to/vkbridge-server

# 3. 多台设备时指定序列号
bash scripts/device/xring-o3/host/install-host.sh --serial 0308A880499C3540 --bundle ...
```

安装结果：`$SRV/*.sh`（0755）、`$SRV/host.env.example`、`$SRV/host.env`（仅首次生成）、`$SRV/mbsrv/vkbridge-server`（0755），以及记录安装文件的 `$SRV/.install-manifest`。manifest 跨多次运行累积，先装 server 再补脚本不会丢失归属。脚本**不启动** server，不写开机启动。

### 主机包（设备上直接运行）

```sh
adb push scripts/device/xring-o3/host/*.sh /data/local/tmp/xring-o3-host/
adb shell su -c 'sh /data/local/tmp/xring-o3-host/install-host.sh \
    --server /data/local/tmp/mbsrv/vkbridge-server'
```

设备上没有 `zstd`，`--bundle` 只能在 PC 上使用；设备侧改用 `--server` 指向已解压的二进制。

### 卸载

```sh
adb shell su -c '/data/local/tmp/xring-o3-host/stop-bridge.sh'
bash scripts/device/xring-o3/host/install-host.sh --uninstall
```

`--uninstall` 只删除 `.install-manifest` 列出的文件；`server.log`、`stdout.log`、socket 与容器数据不受影响。没有 manifest 时脚本拒绝删除。

### rootfs 侧

容器内安装 `mali-stack-<version>.tar.zst`，命令见 `scripts/device/xring-o3/README.md`。该包提供 Mesa、`libvulkan_droidbridge.so`、ICD、libgbm、libdrmfake、`zc-run`、`mbctl`、`mb-tray` 与 `budget.conf` 模板。

## Anland 别名与绑定挂载

```sh
# 每次完整启停容器、Anland 重启或宿主重启后执行一次
adb shell su -c '/data/local/tmp/xring-o3-host/anland-link.sh'

# 只校验，不修改
adb shell su -c '/data/local/tmp/xring-o3-host/anland-link.sh --check'
```

解析顺序：

1. `/data/local/Droidspaces/Pids/<CTR>.asock` 可读且指向活跃 socket 时直接采用；
2. 否则扫描 `/data/local/Droidspaces/Net/anland-*.sock`，取最新的活跃 socket（多个时打印警告）。

活跃判定为：路径是 socket inode，且在 `/proc/net/unix` 中处于 `01`（LISTEN）状态。残留的 socket 文件不算活跃。替换方式为同目录临时符号链接加 `mv`，避免 `ln -sfn` 的中断窗口。

Droidspaces 的绑定挂载源应填 `$ANLAND_LINK`，容器内目标为 `/run/display.sock`。**挂载在创建时解析源路径**，所以顺序必须是：先刷新别名，再创建或重启容器。

## 启动与停止

```sh
adb shell su -c '/data/local/tmp/xring-o3-host/start-bridge.sh'
adb shell su -c '/data/local/tmp/xring-o3-host/stop-bridge.sh'
```

`start-bridge.sh` 的行为：

- 已在运行时不重复启动，只打印 pid 与 socket 路径；
- 创建 `$ROOTFS/opt/mb-sock`（0777），清理旧 socket；
- `setsid` 拉起 `bridge-supervisor.sh`，写 `supervisor.pid`；
- 等待 `mali.sock` 与 `control.sock` 均出现（最多约 12 秒），然后 `chmod 0666`；
- 打印 server pid、supervisor pid、两个 socket 路径与 `budget.conf` 路径；
- 起不来时打印 `server.log` 末尾并返回非零。

开机启动、`init` 脚本、boot 镜像均不修改；需要随开机自动运行时由使用方自行编排。

## 验证

```sh
adb shell su -c '/data/local/tmp/xring-o3-host/verify-host.sh'
```

只读检查，全部通过返回 0，任一失败返回 1。

| 检查 | PASS 条件 | 失败处理 |
| --- | --- | --- |
| `/dev/mali0` | 字符设备存在 | 确认机型与 vendor 驱动已加载 |
| `/dev/dri/card0` | 字符设备 `226:0` | 容器内运行 `card0.sh`，确认 `CAP_MKNOD` |
| 容器 | `droidspaces show` 列出 `$CTR` 且 pid 存活 | 启动容器 |
| server | `server.pid` 存活且命令行含 `vkbridge-server` | 运行 `start-bridge.sh` |
| `mali.sock` | 存在且 LISTEN | 运行 `start-bridge.sh`，失败看 `server.log` |
| `control.sock` | 存在且 LISTEN | 同上 |
| `budget.conf` | 可读，`total_mb`/`pid_mb`/`floor_mb`/`map_limit` 为整数 | 由 rootfs 包安装；与 `host.env` 不一致时以环境变量为准并给出提示 |
| Anland 别名 | 符号链接指向活跃 socket | 运行 `anland-link.sh` 后重启容器 |
| vendor GLES | `/vendor/lib64/egl/libGLES_mali.so` 或 `/vendor/lib64/libGLES_mali.so` | 确认机型 |
| vendor Vulkan | `/vendor/lib64/hw/vulkan.mali.so` 或 `/vendor/lib64/vulkan.mali.so` | 确认机型 |
| Vulkan HAL 模块 | `/vendor/lib64/hw/vulkan*.so` 或 `/vendor/lib64/hwvulkan*` | 确认机型 |

## 同一机型复现步骤

1. 解锁开发者选项与 USB 调试，安装 KernelSU 并取得 root；锁定 bootloader 不影响本流程。
2. 安装 Droidspaces APK 7.1.0，创建容器 `archniri`，rootfs 目录为 `/data/local/Droidspaces/Containers/archniri/rootfs`，启用硬件访问（`CAP_MKNOD`）。
3. 安装 Anland 侧 APK 并启动一次，确认 `/data/local/Droidspaces/Net/anland-*.sock` 出现。
4. 把 `mali-stack-<version>.tar.zst` 放到宿主可读位置，复制到 `$ROOTFS/root/`，在容器内按 `scripts/device/xring-o3/README.md` 运行 `install-mali-stack.sh`。
5. PC 上运行 `install-host.sh --bundle mali-host-<version>.tar.zst`；设备侧执行时改用 `--server`。
6. `anland-link.sh` 创建或刷新 `$ANLAND_LINK`。
7. 在 Droidspaces 里为容器添加绑定挂载 `$ANLAND_LINK` → `/run/display.sock`，然后启动容器。
8. `start-bridge.sh` 启动 server。
9. `verify-host.sh` 全项 PASS 后，在容器内启动 niri/Noctalia。
10. 容器内 `vulkaninfo --summary` 应列出 MaliBridge ICD，`eglinfo -B` 应报告 Zink。

## 打包（维护者）

```sh
# rootfs 包：staging 目录布局见 scripts/device/xring-o3/README.md
bash scripts/device/xring-o3/make-mali-stack-bundle.sh \
     --dir /path/to/staging --version 2026.11.08 --out dist

# 主机包：直接从设备读取 vkbridge-server 与设备属性
bash scripts/device/xring-o3/make-host-bundle.sh \
     --device --version 2026.11.08 --out dist
```

两个脚本的共同约束：

- 产物为 `<name>.tar.zst` 与 `<name>.tar.zst.sha256`（`sha256sum` 原始格式）；
- tar 条目 owner/group 固定为 `0`、mtime 固定为 `--mtime`（默认 `SOURCE_DATE_EPOCH`，否则 `0`）、条目排序固定；
- 不加 `--force` 时拒绝覆盖已存在的产物；
- 不包含上传或发布逻辑。

`make-mali-stack-bundle.sh` 校验：无符号链接、无特殊文件、文件名无空白、`SHA256SUMS` 为 `sha256sum` 原始格式、全部文件被覆盖且哈希一致、五个动态库为 AArch64 ELF 共享对象、ICD 引用 `libvulkan_droidbridge.so`、必需路径与图标齐全。

`make-host-bundle.sh` 校验：server 为 AArch64 Android（`/system/bin/linker64`）可执行文件，拒绝 glibc 版本；打包时权限固定 `0755`；`manifest.env` 记录版本、来源设备与 server 的 sha256。

## 实测差异与注意事项

| 现象 | 说明 | 处理 |
| --- | --- | --- |
| `Pids/<CTR>.asock` 以 root 读取仍 `Permission denied` | 实测 `archniri.asock` 不可读 | `anland-link.sh` 自动回退扫描 `Net/`，不需要该文件 |
| vendor 库不在文档常见路径 | 本机只有 `/vendor/lib64/egl/libGLES_mali.so` 与 `/vendor/lib64/hw/vulkan.mali.so`，没有 `/vendor/lib64/libGLES_mali.so`、`/vendor/lib64/vulkan.mali.so`、`/vendor/lib64/hwvulkan*` | 验证脚本按候选路径解析并打印实际路径 |
| 容器 `/run/display.sock` 不是 rootfs 内的文件 | `mountinfo` 显示它是 `Net/anland-<hash>.sock` 的绑定挂载 | 先刷新别名再建挂载 |
| `droidspaces` 不在 PATH | 只能使用 `/data/local/Droidspaces/bin/droidspaces` | 脚本内置该路径，也可用 `DROIDSPACES_BIN` 覆盖 |
| `budget.conf` 与 `host.env` 数值可能不同 | 环境变量优先于文件 | `verify-host.sh` 打印差异但不判失败 |

## 故障排查

| 症状 | 可能原因 | 处理 |
| --- | --- | --- |
| `start-bridge.sh` 报“缺少 /dev/mali0” | vendor Mali 驱动未就绪 | 确认机型与驱动；重启 Android 后重试 |
| `start-bridge.sh` 报“socket 已被其他进程监听” | 旧目录（如 `/data/local/tmp/mbsrv`）的 server 仍在运行 | 先停止占用者（`kill` 其 pid 或旧脚本的 stop），再启动 |
| `start-bridge.sh` 报“缺少可执行文件 …/mbsrv/vkbridge-server” | 未安装主机包 | `install-host.sh --bundle` 或 `--server` |
| socket 未就绪 | server 启动失败 | 看 `$ROOTFS/opt/mb-sock/server.log` 末尾；先 `stop-bridge.sh` 再重试 |
| 容器内 Vulkan 枚举为空 | 容器未运行、ICD 未安装或 `VK_DRIVER_FILES` 缺失 | 检查 rootfs 包安装状态与 `/etc/environment` |
| Anland 别名 FAIL | 容器刚重启，socket 已换 | `anland-link.sh`，然后重启容器重建挂载 |
| `control.sock` 无法连接 | 容器 uid 不在 `CONTROL_UIDS` | 调整 `CONTROL_UIDS` 后重启 server |
| `verify-host.sh` 报 `budget.conf` 字段缺失 | rootfs 包未装或模板被删 | 重装 rootfs 包；`budget.conf` 只由容器侧创建 |
