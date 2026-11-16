# 构建 xring-o3 目标镜像

目标镜像固定为 Arch + niri + Anland Wayland + Mali 栈，构建入口是 `build-rootfs-releases.yml`（默认分支 `xring-o3-mali`）。

## 规范参数

| 输入 | 值 | 说明 |
|---|---|---|
| `build_target` | `Arch` | 只支持 Arch |
| `desktop` | `Niri` | 设备档案只允许 niri |
| `display_backend` | `anland-wayland` | 固定值 |
| `custom_username` | `colle` | uid 1000 的桌面用户；与设备会话一致 |
| `device_profile` | `xring-o3` | 安装设备档案与 Mali 栈 |
| `apply_preferences` | `true` | 写入 niri/Noctalia 偏好 |
| `wayland_package_repository` | `collegeming/xring-o3-droidspaces-package` | Anland niri 包来源 |
| `output_scale` | `2` | 只对 `anland-0` 写入输出块 |
| `output_mode` | `native` | 不写 mode，使用 Anland 首选模式 |
| `mali_stack_bundle_url` | release 资产 URL | 必须与 sha256 成对提供 |
| `mali_stack_bundle_sha256` | 对应 sha256 | 缺失会硬失败 |
| `mali_stack_version` | `2026.11.12-v1` | 版本标识 |

`custom_username`、`device_profile`、`apply_preferences` 在 workflow 里有默认值，手工触发时可以省略；其余按上表显式传入。

## 手工触发

```bash
gh workflow run build-rootfs-releases.yml \
  -f build_target=Arch -f desktop=Niri \
  -f output_scale=2 -f output_mode=native \
  -f mali_stack_bundle_url='https://github.com/collegeming/xring-o3-droidspaces-package/releases/download/xring-o3-mali-stack-2026.11.12/xring-o3-mali-stack-2026.11.12-v1.tar.zst' \
  -f mali_stack_bundle_sha256='b628b688ccd287a4d7c953c4ae93743b9a79d4e0e6f1cdaac15a2f7e047d3e06'
```

## 产物验收

1. `xz -t` 校验归档完整性。
2. 解出 `usr/local/share/droidspaces/niri-default-config.kdl`，断言含 `output "anland-0"` 与 `scale 2`。
3. 解出 `etc/systemd/system/desktop-session.service`，断言含 root `ExecStartPre` 创建 `/dev/dri/card0`。
4. 解出 `home/colle/.config/niri/config.kdl`，断言 Noctalia 启动项为 `noctalia-dt`（不带子命令）。
5. 解出 `usr/local/bin/zc-launch`、`usr/local/bin/zc-desktop-normalize`、`etc/pacman.d/hooks/98-zc-desktop-normalize.hook`，并断言 `home/colle/.config/noctalia/config.toml` 含 `launch_apps_custom_command = "/usr/local/bin/zc-launch $CMD"`。
6. 目标容器启动后：`wayland-info | grep -w zwp_linux_dmabuf_v1` 版本 ≥ 4；Zen 无 `no dma-buf presentation`；Chromium `create_immed` 且 `wl_shm.create_pool=0`。
