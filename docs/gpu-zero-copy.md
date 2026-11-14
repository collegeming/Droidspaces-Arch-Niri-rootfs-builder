# GPU / 零拷贝实现基线（XRING-O3，2026-11-15）

本文是镜像构建与会话环境的**既定方案**。修改 Mali 栈、`session-gpu-env.sh`、`zc-run`、应用 wrapper、niri/KWin 配置或 systemd 会话单元前，先读本文并按第 7 节复验；不要凭“无 renderD 所以不可能”重新否定已经实现的路径。

## 1. 分层定义

| 层 | 含义 | 通过证据 |
| --- | --- | --- |
| L-A 应用渲染 | 应用自身用 GPU | `GL_RENDERER`/`glxinfo` 为 `zink Vulkan ... Mali`，不是 llvmpipe |
| L-B 应用→合成器 | 窗口缓冲以 dma-buf 交付，不走 wl_shm | `zwp_linux_buffer_params_v1.create_immed` > 0；`wl_shm.create_pool` 仅光标小池（2304/9216 B） |
| L-C 合成器→显示 | 合成器把 dmabuf 交给 Anland/Android 显示 | MaliBridge `dma-buf image`、Anland producer/consumer 日志；当前尚未做 scanout/fence trace |

“零拷贝”在本文默认指 **L-B 成立**。L-A 通过不能推出 L-B；L-B 通过不能推出 L-C。

## 2. 通用架构：为什么会话应用默认走 GPU

### 2.1 合成器

- Arch/niri：`/usr/bin/niri-anland` 使用 Anland 后端 + surfaceless EGL + zink，MaliBridge format ICD；`/proc/<niri>/maps` 必须含 `libgallium-26.3.0-devel.so` 与 `libvulkan_droidbridge.so`。
- Fedora/KWin：Anland patched KWin 使用发行版 Mesa zink + `droidbridge-format.json`。
- 容器无 `/dev/dri/renderD*`，只有 `card0`（xring_drm primary）。niri 的 dmabuf feedback 因此降级为 **v3**；v3 仍允许 `create_immed`，不阻断零拷贝。**不要创建 `renderD128`**：会让 niri 进入重启循环。

### 2.2 Arch 会话环境（所有 niri spawn 的应用继承）

`/usr/local/lib/droidspaces/device/xring-o3/session-gpu-env.sh` 从 `/opt/mali-stack/current/conf/zc-env.conf` 读取并导出：

```sh
LD_LIBRARY_PATH=/opt/mali-stack/current/mesa/kopper/candidate/usr/lib
__EGL_VENDOR_LIBRARY_FILENAMES=/opt/mali-stack/current/mesa/kopper/default-egl-vendor.json
VK_DRIVER_FILES=/opt/mali-stack/current/share/vulkan/icd.d/droidbridge-format.json
VKBRIDGE_SOCKET=/opt/mb-sock/mali.sock
MESA_LOADER_DRIVER_OVERRIDE=zink
GALLIUM_DRIVER=zink
LIBGL_KOPPER_DISABLE=false
XWAYLAND_GBM_DEVICE=/dev/dri/card0
```

同时 unset `VKBRIDGE_WSI_SHM`、`LIBGL_ALWAYS_SOFTWARE`、`VK_ICD_FILENAMES`、`LD_PRELOAD`、`MESA_KOPPER_LIFECYCLE_TRACE`。niri 自身与它 spawn 的 Qt/GTK/kitty/Noctalia/Chrome 都从这套环境启动。

**关键约束**：kopper Mesa（26.3）只给 niri/Noctalia 用；Chromium、Electron、Xwayland 必须切到**发行版 Mesa 26.2.6**，否则 Chrome GPU 进程会同时加载两份 libgallium，出现 `ZINK: failed to choose pdev` / `exit_code=11`。

### 2.3 `zc-run`：按应用类型收敛

`/usr/local/bin/zc-run` 是薄包装；真正实现是 `/opt/mali-stack/current/bin/zc-run.real`。它按 `--class` 或 `zc-classify` 分类后注入：

| class | 注入 |
| --- | --- |
| `chromium` | `ZC_MESA_DIR=/usr`、`ZC_EGL_VENDOR_JSON=/usr/share/glvnd/egl_vendor.d/50_mesa.json`、`VKBRIDGE_DRM_RENDER=226:0`、`LD_LIBRARY_PATH=/usr/lib`、gbm shim、`--ozone-platform=wayland --render-node-override=/dev/dri/card0`、unset `DISPLAY` |
| `webkit` | `LD_PRELOAD=/opt/mali-stack/current/lib/libdrmfake.so`、`WEBKIT_WEB_RENDER_DEVICE_FILE=/dev/dri/card0`、`WEBKIT_DMABUF_RENDERER_DISABLE_GBM=1`、`WEBKIT_DISABLE_DMABUF_RENDERER=0`、禁用 WebKit 沙箱、unset `DISPLAY` |
| `gecko` | `MOZ_ENABLE_WAYLAND=1`、`GDK_BACKEND=wayland`、`MOZ_DRM_DEVICE=/dev/dri/card0` |
| 其它 | 继承会话 env；需要特殊 flag 的应用应显式加 class 或 wrapper |

**不要覆盖 `/usr/local/bin/zc-run` 这个符号链接**；构建时 `Arch.Dockerfile` 会把它改名为 `.real` 并生成包装器，直接 `cat >` 会顺着链接覆盖实现。

### 2.4 应用 wrapper

| wrapper | 作用 |
| --- | --- |
| `/usr/local/bin/google-chrome` | 薄别名：`zc-run --class chromium /opt/google/chrome/google-chrome` + VAAPI flags；`unset DISPLAY` |
| `/usr/local/bin/dbx` | `zc-run --class webkit /usr/bin/dbx`；Tauri/WebView 用 |
| `/usr/local/bin/zen` | `zc-run --class gecko /opt/zen/zen` |
| `/usr/local/bin/noctalia-dt` | Noctalia 专用：kopper dt-retire + MaliBridge wl-gone hook + `VKBRIDGE_WSI_SHM` unset |
| `/usr/local/bin/xwayland-satellite-soft` | Xwayland GPU 优先：card0 + 发行版 Mesa + zink + format ICD；探测失败回退 llvmpipe |

## 3. 应用类型矩阵（当前结论）

| 类型 | 启动方式 | 关键环境/参数 | 预期证据 | 状态 |
| --- | --- | --- | --- | --- |
| Qt6 / Qt5 | niri spawn 或 session 直接启动 | 继承会话 env | `create_immed=3/9`，`create_pool=0` | 已实测 L-B |
| GTK4 | niri spawn | 继承会话 env | `create_immed=8`，`create_pool=0` | 已实测 L-B |
| GTK3（Nemo） | 原样 | 无 dmabuf 路径 | 仅 shm（预期） | 负对照 |
| kitty | niri spawn | 继承会话 env | `create_immed=3`，`pool=0` | 已实测 L-B |
| Chromium | `/usr/local/bin/google-chrome` | system Mesa + zc-run chromium + gbm shim + render-node-override | `gpu_compositing=enabled`；`create_immed=9`；`wl_shm=0`；历史 60 FPS/60 min | 已实测；`chrome://gpu` 显示 Compositing: Hardware accelerated |
| Electron 42/43 | `zc-run --class chromium <electron> <app>` | 同 Chromium；`--ozone-platform=wayland` | GPU 进程存活；`create_immed` 为窗口尺寸（1888×1488 等）；shm 仅光标池 | 已实测（electron42） |
| WebKitGTK / Tauri / DBX | `zc-run --class webkit <app>` | libdrmfake + `WEBKIT_WEB_RENDER_DEVICE_FILE` + `DISABLE_GBM=1` + `WEBKIT_DISABLE_DMABUF_RENDERER=0` | `create_immed=8`，`pool=0`；bridge dma-buf image | 已实测（MiniBrowser/DBX）；镜像需预装 webkitgtk-6.0 |
| Zen / Gecko | `zc-run --class gecko /opt/zen/zen` | `MOZ_ENABLE_WAYLAND=1`、`GDK_BACKEND=wayland`、`MOZ_DRM_DEVICE=/dev/dri/card0`；profile user.js：`gfx.webrender.all=true`、`gfx.webrender.software=false`、`widget.dmabuf.force-enabled=true` | `no dma-buf presentation`=0；bridge dma-buf image | 历史已实测；当前镜像未装 Zen |
| Noctalia | `/usr/local/bin/noctalia-dt` | kopper Mesa + dt-retire + wl-gone hook | bridge dmaheap/dma-buf image，无 invalid object | 已实测 |
| Xwayland / X11 | `xwayland-satellite-soft` | card0 + 发行版 Mesa + zink + format ICD；无 renderD、无 mknod | `glxinfo` zink Mali / `Accelerated: yes`；glxgears 窗口可见 | 已实测（:93）；主会话 wrapper 已部署 |
| niri 合成器 | `/usr/bin/niri-anland` | 会话 env（kopper Mesa + zink + format ICD） | maps 含 libgallium + libvulkan_droidbridge；bridge dma-buf 3408×2272 | 已实测 GPU 合成 |

### 3.1 2026-11-15 低负载复测记录

同一 Arch-Niri 会话内，按“启动→8 s 采样→杀进程组”串行执行；WebKit 只加载静态 HTML，不跑动画。

| 用例 | create_immed | wl_shm.create_pool | 说明 |
| --- | --- | --- | --- |
| Qt6 `qml6` | 3 | 0 | 必须先导出会话 GPU env；niri spawn 的应用自动继承 |
| kitty | 3 | 0 | 同上 |
| Electron 42（`zc-run --class chromium`） | 5（窗口尺寸 1888×1488 等） | 2（仅 2304/9216 光标池） | GPU 进程存活，无 exit 11 |
| WebKitGTK MiniBrowser（libdrmfake 配方，静态页） | 8 | 0 | 不跑动画，避免触发 bridge 2GB per-client 预算 |
| Chromium 157 `chrome://gpu` | 历史 9 | 历史 0 | `Compositing: Hardware accelerated`；CDP `gpu_compositing=enabled` |
| Xwayland `:93` glxinfo/glxgears | — | — | zink Vulkan Mali，Accelerated yes；窗口在 niri 内可见 |

注意：直接在容器 shell（非 niri spawn）启动 Qt/kitty 时必须显式导出第 2.2 节的会话 env；否则只会得到 `immed=0/pool=3` 的 wl_shm 结果。这不是实现退化。


## 4. 历史根因与已解决陷阱

1. **Chrome 双 libgallium**：`zc-run` 默认把 kopper Mesa 26.3 注入 Chrome，同时系统 GBM 后端加载 26.2.6，导致 pdev 失败/GPU 进程 exit 11。解决：Chrome `ZC_MESA_DIR=/usr` + `ZC_EGL_VENDOR_JSON=.../50_mesa.json` + `LD_LIBRARY_PATH=/usr/lib`。
2. **Chrome 挂在 Xwayland**：niri 注入 `DISPLAY` 指向挂死的 Xwayland，Chrome 收到 configure 后不 ack/attach。解决：Chromium wrapper `unset DISPLAY`。
3. **WebKit 无 dma-buf**：WebKit 只接受 render node 或 `WEBKIT_WEB_RENDER_DEVICE_FILE`；用 `libdrmfake` 把 card0 标记为 render，并关闭 GBM 路径（`DISABLE_GBM=1`）。
4. **Noctalia invalid object**：Mesa Kopper displaytarget 延迟销毁 + 指针复用；必须叠加 dt-retire Mesa 与 ICD wl-gone hook。
5. **niri v3 不是故障**：无 EGL render node 时 dmabuf feedback 降级 v3，仍支持 `create_immed`；不要为了 v5 创建假 renderD128。
6. **Xwayland 不是无解**：Anland 版 Xwayland 在 dmabuf v3 下读取 `XWAYLAND_GBM_DEVICE`；wrapper 显式给 card0 + 发行版 Mesa 即可 GPU。不要用 kopper 环境，也不要建 renderD128。

## 5. 不得破坏的规则

1. 不创建 `/dev/dri/renderD128`；`desktop-session.service` 的 `ExecStartPre` 只建 `card0`。
2. `/etc/environment` 不写 `WAYLAND_DISPLAY`；KWin/niri 自己发布客户端 socket。
3. 不给会话全局设置 `LIBGL_ALWAYS_SOFTWARE=1` / `GALLIUM_DRIVER=llvmpipe`；软件渲染只允许在 Xwayland wrapper 的显式回退分支。
4. Chromium/Electron/Xwayland 不使用 kopper Mesa；niri/Noctalia 不使用系统 Mesa 替换 kopper。
5. 不覆盖 `zc-run` 符号链接；不删除 `libdrmfake.so`、`libgbm.so.1` 垫片、`droidbridge-format.json`。
6. 不在 live 会话跑整屏 WebKit 动画/压力测试：bridge per-client 预算 2048 MB，可触发 `vkBindBufferMemory` 空指针崩溃并带崩 niri。
7. bridge 未监听 `mali.sock`/`control.sock` 时不要重启 desktop-session；先启动 bridge，否则会话无 GPU、Noctalia 会 `eglInitialize failed`。
8. Xwayland wrapper 必须保留“GPU 探测 + llvmpipe 回退”；不要无条件强制 zink。

## 6. 文件与构建挂载点

| 文件 | 作用 |
| --- | --- |
| `Arch.Dockerfile` | 安装 Mali 栈、zc-run 包装器、Xwayland wrapper、desktop-session、systemd 单元 |
| `scripts/xwayland-satellite-soft.sh` | Xwayland GPU 优先 wrapper（镜像安装到 `/usr/local/bin/`） |
| `scripts/desktop-session.service` / 设备档案 | 创建 card0、等待 bridge、启动 niri |
| `scripts/configure-chrome.sh` | Chrome/DBX/Zen 薄别名 |
| `scripts/desktops/niri.sh` | niri/Noctalia 会话参数 |
| `/usr/local/lib/droidspaces/device/xring-o3/session-gpu-env.sh` | 会话 GPU 环境（Mali 栈 bundle 提供） |
| `/opt/mali-stack/current/conf/zc-env.conf` | zc-run/session 的路径来源 |
| `/opt/mb-sock/server.log`、`budget.conf` | bridge 预算与 dma-buf 证据 |

## 7. 验收命令（按顺序，低负载）

```sh
# 1. 合成器 GPU
pid=$(pgrep -x niri-anland)
grep -E 'libgallium|libvulkan_droidbridge' /proc/$pid/maps | sort -u

# 2. dmabuf global（v3 即可）
runuser -u colle -- env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1 \
  wayland-info | grep -w zwp_linux_dmabuf_v1

# 3. Qt/kitty 零拷贝
runuser -u colle -- env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1 \
  WAYLAND_DEBUG=1 timeout 10 qml6 /tmp/min.qml 2>&1 | \
  grep -cE 'create_immed|wl_shm.*create_pool'

# 4. Chrome 硬件合成（CDP SystemInfo）
#    gpu_compositing 必须为 enabled；renderer 含 zink + Mali

# 5. Chrome/Electron 零拷贝
#    WAYLAND_DEBUG 中 create_immed 为窗口尺寸，create_pool 只有 2304/9216

# 6. Xwayland GPU
DISPLAY=:93 glxinfo -B | grep -E 'renderer|Accelerated'
# 期望 zink Vulkan ... Mali、Accelerated: yes

# 7. bridge 状态
tail -5 /opt/mb-sock/server.log | grep 'mem:'
```

## 8. 当前未完成项

1. niri 自动 spawn `xwayland-satellite-soft` 的 GPU 路径需在下次会话复验；当前 :93 隔离验证已通过。
2. Arch 镜像未预装 `webkitgtk-6.0`；`zc-run` 对未知 Tauri 应用需强制 `class=webkit`。
3. Fedora WebKit 仍被 `WEBKIT_DISABLE_DMABUF_RENDERER=1` 强制 SHM；应改为 `0` + `WEBKIT_WEB_RENDER_DEVICE_FILE=/dev/dri/card0` + `DISABLE_GBM=1`。
4. `vkbridge-server` 预算拒绝路径空指针、supervisor 不自动重启、per-client 2 GB 偏小；在修好前不要跑 WebKit 动画压力测试。
5. L-C（合成器→Android scanout）未做 fence/trace 取证；不要把 L-B 说成全链路零拷贝。
