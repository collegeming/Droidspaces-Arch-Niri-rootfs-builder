# Legacy multi-distribution KDE archive / 旧版多发行版 KDE 归档

[中文](#中文) | [English](#english)

## 中文

此目录保存本仓库转为 **Droidspaces Arch-Niri RootFS Builder** 之前的多发行版 KDE 实现，仅用于历史参考、审计或人工恢复，不是 active build API。

- `dockerfiles/`：旧 Debian、Ubuntu、Fedora、Arch-KDE、Artix 和 NixOS Dockerfiles。
- `scripts/`：旧 patched KWin/KDE、PulseAudio 和 Plasma service helper。
- `workflows/`：旧中英文 RootFS、patched KDE Wayland package 和清理 workflow。

重要边界：

1. GitHub 只注册 `.github/workflows/` 下的 workflow；本目录 workflow 不会自动注册、dispatch 或发布。
2. 唯一 active Dockerfile 是仓库根目录的 `Droidspaces-Arch-Niri.Dockerfile`；唯一 active workflow 是 `.github/workflows/build-arch-niri-rootfs.yml`。
3. active builder 不再接受 `build_KDE`、`build_KDE_plus`、`enable_anland_kde`、`build_wayland_packages`、`all-wayland` 等旧参数，也不会动态扫描 `*.Dockerfile`。
4. 归档文件按原有结构保留，可能引用外部历史上游 `Goldzxcbug/Droidspaces-rootfs-KDE-builder` 或旧 rolling Release。这些是外部 dependency pin，不是本仓库 self URL；不承诺仍可构建、兼容或安全。
5. 不要把本目录文件移回 `.github/workflows` 或根目录后直接运行。恢复前必须重新审计 action pin、permissions、发行版 EOL、包签名、Release overwrite 行为、URL 与脚本路径。
6. 旧 Release/tag 保留在 GitHub，不删除、不覆盖。新的 canonical repository URL 是：
   <https://github.com/collegeming/Droidspaces-Arch-Niri-rootfs-builder>

Active 文档：[中文 README](../README.md) / [English README](../README_english.md)

## English

This directory preserves the multi-distribution KDE implementation that predated the **Droidspaces Arch-Niri RootFS Builder**. It exists only for historical reference, auditing, or deliberate manual recovery and is not part of the active build API.

- `dockerfiles/`: old Debian, Ubuntu, Fedora, Arch-KDE, Artix, and NixOS Dockerfiles.
- `scripts/`: old patched-KWin/KDE, PulseAudio, and Plasma service helpers.
- `workflows/`: old Chinese/English RootFS, patched KDE Wayland package, and cleanup workflows.

Important boundaries:

1. GitHub registers workflows only under `.github/workflows/`. Workflows in this directory cannot be registered, dispatched, or publish automatically.
2. The sole active Dockerfile is `Droidspaces-Arch-Niri.Dockerfile` at the repository root. The sole active workflow is `.github/workflows/build-arch-niri-rootfs.yml`.
3. The active builder no longer accepts `build_KDE`, `build_KDE_plus`, `enable_anland_kde`, `build_wayland_packages`, `all-wayland`, or related inputs and never dynamically scans `*.Dockerfile`.
4. Archived files retain their historical structure and may reference the external upstream `Goldzxcbug/Droidspaces-rootfs-KDE-builder` or an old rolling Release. Those references are external dependency pins, not this repository's self URL. Buildability, compatibility, and security are not guaranteed.
5. Do not move these files back into `.github/workflows` or the repository root and run them unchanged. Re-audit action pins, permissions, distribution EOL status, package signatures, Release-overwrite behavior, URLs, and script paths first.
6. Historical Releases/tags remain on GitHub and must not be deleted or overwritten. The new canonical repository URL is:
   <https://github.com/collegeming/Droidspaces-Arch-Niri-rootfs-builder>

Active documentation: [Chinese README](../README.md) / [English README](../README_english.md)
