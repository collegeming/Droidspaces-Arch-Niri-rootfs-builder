English | [中文](README.md)

# Droidspaces RootFS Automated Build

This project builds Linux RootFS archives for Droidspaces through GitHub Actions. The build system is based on Dockerfile templates and exposes common options for distribution selection, KDE desktop size, Chinese localization, input method support, Snapdragon GPU acceleration, audio forwarding, TMOE, Docker, development tools, and Wayland/Anland support.

The goal is to reduce the amount of manual setup required to run a desktop Linux container on Android. Fork the repository, choose the build options in GitHub Actions, wait for the Release artifact, then import the generated `.tar.xz` RootFS into Droidspaces.

## Table of Contents

- [Supported Targets](#supported-targets)
- [Feature Overview](#feature-overview)
- [Build Options](#build-options)
- [Build with GitHub Actions](#build-with-github-actions)
- [Import into Droidspaces](#import-into-droidspaces)
- [Start KDE Desktop](#start-kde-desktop)
- [Wayland and Anland Setup](#wayland-and-anland-setup)
- [Droidspaces USB Manager](#droidspaces-usb-manager)
- [Account, Password, and Username Changes](#account-password-and-username-changes)
- [Local Build](#local-build)
- [Install Hardware Firmware](#install-hardware-firmware)
- [Repository Layout](#repository-layout)
- [Known Limitations](#known-limitations)
- [Acknowledgements](#acknowledgements)

## Supported Targets

| Build target | Base image | KDE modes | Wayland/Anland | Notes |
| --- | --- | --- | --- | --- |
| `Debian-13-KDE` | `debian:trixie` | `min`, `conc`, `mobile`, `none` | Supported | Uses the Debian 13 Trixie repositories. |
| `Ubuntu-24-KDE` | `ubuntu:24.04` | `min`, `conc`, `none` | Not supported | Supports `nosnap`. |
| `Ubuntu-25-KDE` | `ubuntu:25.10` | `min`, `conc`, `none` | Not supported | Supports `nosnap`. |
| `Ubuntu-26-KDE` | `ubuntu:26.04` | `min`, `conc`, `mobile`, `none` | Supported | Supports `nosnap`; recommended for Anland KDE. |
| `Fedora-43-KDE` | `fedora:43` | `min`, `conc`, `mobile`, `none` | Supported | Some devices require hardware access to avoid flicker or crashes. |
| `Fedora-44-KDE` | `fedora:44` | `min`, `conc`, `mobile`, `none` | Supported | Some devices require hardware access. |
| `Arch-KDE` | `ogarcia/archlinux` | `min`, `conc`, `mobile`, `none` | Supported | Uses ARM64 Arch patched KWin/Xwayland; this project's QEMU/binfmt flow is not recommended for Arch at the moment. |
| `Arch-Niri` | `ogarcia/archlinux` | No KDE (`build_KDE` ignored) | Forced on | KDE-free minimal Arch + niri (ANiri anland backend) + Noctalia Shell; see the Arch-Niri notes below. |
| `Artix-KDE` | ARMtix OpenRC rootfs | `min`, `conc`, `none` | Not supported | Artix mainline has no aarch64; uses the [ARMtix](https://armtixlinux.org/) community port. OpenRC init (no systemd); unsigned repositories (`SigLevel = Never`); X11 path only. |
| `NixOS-KDE` | `nixos/nix` + declarative build | `min`, `none` | Not supported | Pinned to the NixOS 25.05 channel (systemd 257, old-kernel friendly); `conc` exceeds the GitHub ARM runner disk budget; GPU falls back to software rendering (see the NixOS notes below). |

`all` builds every Dockerfile template. For `min`, `conc`, and `mobile`, `all-wayland` builds `Debian-13-KDE`, `Ubuntu-26-KDE`, `Fedora-43-KDE`, `Fedora-44-KDE`, and `Arch-KDE`; `mobile` forces Wayland on.

### Artix-KDE notes

- Bootstrapped from the official [ARMtix](https://wiki.artixlinux.org/Main/Aarch64) (Artix Linux aarch64 community port) OpenRC rootfs; packages come from the `system`, `world`, and `galaxy` repositories at `repo.armtixlinux.org` (unsigned, so pacman runs with `SigLevel = Never`).
- Uses OpenRC + elogind + standalone udev; there is no systemd, so systemd version compatibility is a non-issue and `enable_systemd257` auto-skips.
- Desktop auto-start uses the OpenRC service `plasma-x11` (`/etc/init.d/plasma-x11`, supervised by supervise-daemon), equivalent to the systemd `plasma-x11.service`.
- The OpenRC services for `NetworkManager` and `udev` carry the same runtime gating as the systemd versions (NAT network mode only / hardware access only).
- Snapdragon GPU support reuses the `archlinux_arm64` custom Mesa build from `mesa-for-android-container` (binary-compatible with ARMtix).
- Wayland/Anland patched KWin and plasma-mobile are not supported on Artix yet.

### NixOS-KDE notes

- Built declaratively inside the `nixos/nix` container, pinned to the `nixos-25.05` channel: it ships **systemd 257**, the last major line that works on old Android kernels such as 4.19, so `scripts/systemd257.sh` is neither needed nor applicable.
- The channel is EOL/frozen: builds are reproducible but receive no further security updates; to update, switch channels inside the container with `nix-channel --add` (newer channels may ship systemd versions incompatible with old kernels).
- The rootfs is produced with nixpkgs `make-system-tarball`, includes the full `/nix/store` closure, and provides `/sbin/init` pointing to the NixOS activation script; the first boot registers the Nix database and creates the user (default password `1234`).
- **GPU limitation**: NixOS uses stock nixpkgs Mesa, which has no Qualcomm KGSL backend, and the `mesa-for-android-container` packages are incompatible with the NixOS store. GPU rendering therefore falls back to llvmpipe software rendering; `enable_mesa` only installs the graphics stack and tools. For GPU acceleration prefer the Arch/Debian/Ubuntu/Fedora templates.
- Only `min` and `none` desktop profiles are supported: the `conc` Plasma closure plus builder intermediates exceed the GitHub ARM runner disk budget.
- TMOE targets apt/dnf/pacman systems and is not integrated on NixOS; Droidspaces USB Manager is not integrated yet either (all other distributions ship it).
- Wayland/Anland patched KWin and plasma-mobile are not supported on NixOS yet.

### Arch-Niri notes (KDE-free minimal + niri + Noctalia Shell)

- Positioning: a **minimal Arch without any KDE components**, with a scrollable-tiling Wayland compositor [niri](https://github.com/niri-wm/niri) (adapted for Android through the [ANiri](https://github.com/Celvra/ANiri) anland backend), the [Noctalia Shell](https://github.com/noctalia-dev/noctalia) desktop shell, and fuzzel as the launcher.
- The terminal prefers **ghostty**: the Arch Linux ARM aarch64 repositories do not carry ghostty yet (the x86_64 mainline does), so the build attempts to install it and falls back to kitty when unavailable; the niri terminal shortcut (Mod+T) detects at runtime via `spawn-sh`, so either terminal works and the image switches to ghostty automatically once the repositories carry it.
- Build logic: based on the upstream `Droidspaces-rootfs-builder` Arch-Minimal (minimal package set, iptables-legacy compatibility, `ds-aliases` shell aliases), combined with this project's Chinese localization, user creation, `enable_systemd257` old-kernel compatibility (recommended for 4.19 devices), fcitx5, the custom Qualcomm Mesa build (`enable_mesa`, which ANiri's kgsl rendering requires), binfmt, NAT/hardware-access gating, USB Manager, and the optional components.
- Repositories and tooling: pacman uses the **TUNA mirror first** (official ALARM servers kept as fallback) and adds the **archlinuxcn aarch64 repository** (TUNA first, official fallback; signature verification is restored after the keyring bootstrap); **paru** (AUR helper, run as a regular user inside the container) is bundled, the editor is neovim, and the file manager is Nemo (niri shortcut `Mod+E`).
- The niri binary is downloaded from a pinned ANiri release (currently `v0.2.0`, SHA256-verified and stripped at build time); it requires kernel ≥3.7, so 4.19 is fully compatible. ANiri does not use this project's patched KWin packages.
- The display path is **Anland/Wayland only** (no X11/Termux:X11 path): selecting this target forces Wayland support on and disables PulseAudio forwarding (the Anland app provides audio).
- The `build_KDE` option is ignored (the template contains no KDE); with `build_KDE_plus=true` (default), `niri.service` auto-starts: it runs `/usr/bin/niri` as the regular user, creates `/run/user/1000` automatically, and restarts 3 seconds after an abnormal exit.
- The input method (`enable_srf`) uses **fcitx5-rime + rime-ice-git (Rime-Ice pinyin)**: fcitx5-rime comes from ALARM extra and rime-ice-git is a prebuilt archlinuxcn aarch64 package, working out of the box without manual rime configuration.
- The niri config is installed to `~/.config/niri/config.kdl` (from the upstream `default-config.kdl`, with the waybar autostart replaced by noctalia and the terminal shortcut preferring ghostty (runtime detection, kitty fallback), plus a new `Mod+E` binding for Nemo; an fcitx5 autostart entry is appended when `enable_srf` is on). New users get the same config from `/etc/skel`.
- Host-side preparation is identical to the Wayland/Anland configuration section: flash virtual-drm-daemon, install the Anland app, bind-mount `display_daemon.sock -> /run/display.sock`, enable GPU access and permissive SELinux, and turn on Anland's accessibility toggle (otherwise Android intercepts the Super key).
- Known limitations: upstream ANiri lists a few known issues (glmark2/vkmark scores slightly below KWin, Android floating windows may cause glitches, microphone/camera forwarding is unreadable by apps); Xwayland is not integrated (the patched Xwayland belongs to the KWin prebuilt package set).

## Feature Overview

- Multi-distribution RootFS builds for Debian, Ubuntu, Fedora, Arch, Artix, and NixOS.
- Scalable KDE desktop profiles, from command-line only to minimal, compact, and mobile KDE.
- KDE-free niri desktop: the `Arch-Niri` target provides minimal Arch + niri (ANiri anland backend) + Noctalia Shell.
- Desktop auto-start and failure recovery using shared systemd service templates for X11, Plasma Wayland, and Plasma Mobile, with rate-limited automatic restarts after failures.
- Termux:X11 desktop startup support. X11 mode defaults to `DISPLAY=:5`.
- PulseAudio forwarding through Unix socket, TCP, or disabled mode.
- Optional Chinese locale with `zh_CN.UTF-8` and `Asia/Shanghai` timezone.
- Optional Fcitx5 input method. Chinese input addons are installed when Chinese localization is enabled.
- Snapdragon GPU support using configuration from `mesa-for-android-container`.
- Optional Snapdragon 8 Gen 2 Wayland display-corruption fix through a Turnip UBWC environment setting.
- Container integration improvements for common Android/Droidspaces hardware, network, and group recognition.
- Optional TMOE integration. Run `tmoe` inside the container to start it.
- Optional development toolchain packages, including compilers, CMake, and Python development tooling.
- Optional compression utilities such as `zip`, `unzip`, `7z`, `xz`, `tar`, and `gzip`.
- Optional Docker packages inside the RootFS.
- Optional old-kernel systemd compatibility: on apt, dnf, or pacman targets whose systemd major version is above 257, build and install `v257-stable`; Debian 13 and other 257-or-older systems are skipped automatically.
- Stable ARM64 Wayland/Anland support for Debian 13, Ubuntu 26.04, Fedora 43/44, and Arch Linux through patched KWin and Xwayland packages.
- USB device management on every distribution through Droidspaces USB Manager, including USB storage, ADB device nodes, mounting, unmounting, and a system tray interface.
- Automatic Release publishing with the RootFS `.tar.xz` files and matching audio startup scripts.

## Build Options

The main GitHub Actions inputs are:

| Option | Values | Default | Description |
| --- | --- | --- | --- |
| Distribution to build (`build_target`) | Distribution target, `all`, `all-wayland` | `Debian-13-KDE` | Selects which RootFS target to build. |
| Custom username (`custom_username`) | String | `Gold` | Default user inside the RootFS. The audio startup script in the Release is patched with this username. |
| KDE desktop choice (`build_KDE`) | `conc`, `min`, `mobile`, `none` | `min` | KDE desktop size. `none` builds a command-line only RootFS. |
| KDE desktop auto-start (`build_KDE_plus`) | `true`, `false` | `true` | Creates a systemd service to auto-start KDE. Requires a KDE mode other than `none`; turn it off when building `none`. |
| Wayland support (`enable_anland_kde`) | `true`, `false` | `false` | Enables Wayland/Anland support on Debian 13, Ubuntu 26, Fedora 43/44, and Arch. |
| PulseAudio forwarding (`PulseAudio`) | `socket`, `tcp`, `none` | `socket` | Audio forwarding mode for X11 builds. It is forced to `none` when Anland is enabled. |
| Chinese language and timezone (`enable_zh_tz`) | `true`, `false` | `false` in the English workflow | Enables Chinese locale and the Shanghai timezone. |
| Qualcomm Snapdragon GPU support (`enable_mesa`) | `true`, `false` | `true` | Enables Qualcomm Snapdragon GPU and Mesa-related support. |
| Fix Snapdragon 8 Gen 2 Wayland display corruption (`enable_8gen2_wayland`) | `true`, `false` | `false` | Writes `FD_DEV_FEATURES=enable_tp_ubwc_flag_hint=1` to `/etc/environment` for Debian 13, Ubuntu 26, Fedora 43/44, and Arch. |
| Integrate TMOE (`enable_tmoe`) | `true`, `false` | `true` | Integrates TMOE. |
| Remove Ubuntu Snap (`nosnap`) | `true`, `false` | `false` | Ubuntu-only option that removes Snap, snapd, and APT policy paths that may reinstall snapd. |
| systemd 257 old-kernel compatibility (`enable_systemd257`) | `true`, `false` | `true` | When enabled, builds a `v257-stable` compatibility runtime if the current systemd major version is above 257; versions 257 and older are skipped, as are Artix (no systemd) and NixOS 25.05 (pinned to 257). systemd-related packages are locked after the build to prevent replacement by upgrades. |
| Fcitx5 input method support (`enable_srf`) | `true`, `false` | `true` | Installs Fcitx5 input method support. |
| Cross-architecture support (`enable_binfmt`) | `true`, `false` | `false` | Adds binfmt cross-architecture components inside the RootFS. Not recommended for Arch in this project. |
| NAT and hardware recognition (`enable_yj`) | `true`, `false` | `true` | Enables container hardware and network recognition improvements. |
| Development tools integration (`enable_kfgj`) | `true`, `false` | `false` | Installs development tools. |
| Compression tools integration (`enable_zip`) | `true`, `false` | `true` | Installs common compression tools. |
| Docker integration (`enable_docker`) | `true`, `false` | `false` | Installs Docker-related packages inside the RootFS. |
| Build Wayland prebuilt packages (`build_wayland_packages`) | `true`, `false` | `false` | Triggers the KWin/Xwayland prebuilt package workflow before building the RootFS. |

KDE mode details:

| Mode | Description | Recommended use |
| --- | --- | --- |
| `none` | Does not install KDE. Keeps a command-line environment only. | Lightweight RootFS, SSH use, development environments, or custom desktop setups. |
| `min` | Minimal KDE desktop with Plasma basics and startup dependencies. | Smaller KDE builds that still provide a usable desktop. |
| `conc` | Compact but more complete KDE desktop with more system tools, monitoring, file management, and multimedia components. | General desktop use. |
| `mobile` | KDE Plasma Mobile components. | Phone-screen and touch-first usage; forces Wayland in this project. |

Audio mode details:

| Mode | Description |
| --- | --- |
| `socket` | Uses a Unix socket for PulseAudio forwarding. This is usually lower latency and is recommended for X11 mode. |
| `tcp` | Uses `127.0.0.1:4713` for PulseAudio forwarding. It is straightforward to debug, but exposes a wider interface. |
| `none` | Does not configure PulseAudio. Anland mode automatically uses this value because the Anland app provides its own audio path. |

### systemd 257 old-kernel compatibility

When `enable_systemd257` is enabled, the build runs `scripts/systemd257.sh`. The script first detects the installed systemd major version:

- systemd 257 or older (for example Debian 13 and Ubuntu 24.04) is skipped;
- apt, dnf, and pacman systems above 257 build systemd 257 from the official `v257-stable` branch;
- build dependencies are removed after the build, and systemd-related packages are locked so a later upgrade does not overwrite the compatibility runtime.

This option targets old Android kernels and is experimental. It adds substantial build time; test the desktop, dbus, udev, and networking behavior on the target kernel before distributing the image.

### Recommended settings for 4.19-kernel devices (for example Redmi K40 / Snapdragon 870)

This `4.19Core` repository targets 4.19-kernel devices (reference device: Redmi K40 `alioth`, Snapdragon 870 / SM8250, Adreno 650). Recommended workflow inputs for such devices:

| Option | Recommended | Notes |
| --- | --- | --- |
| `enable_systemd257` | `true` | 4.19 kernels cannot run systemd 258+; this is the Chinese workflow default. NixOS 25.05 already ships systemd 257 and Artix has no systemd; both skip automatically. |
| `enable_zh_tz` | `true` | Chinese locale and Shanghai timezone (Chinese workflow default). |
| `enable_srf` | `true` | Fcitx5 input method; Chinese input addons are included when the Chinese locale is enabled (Chinese workflow default). |
| `enable_mesa` | `true` | Snapdragon (Adreno) GPU support; on NixOS this is a software-rendering fallback. |
| `enable_yj` | `true` | Container hardware and network recognition (default). |
| `enable_zip` | `true` | Compression tools integration (default). |
| `enable_binfmt` | `false` | See the kernel notes below. |
| `PulseAudio` | `socket` | Recommended Unix-socket forwarding in X11 mode. |

Kernel notes for such devices (verified on the Redmi K40):

- `CONFIG_USER_NS` is not set: enable `noseccomp` in the Droidspaces privileged options when importing, otherwise operations that rely on user namespaces may stutter.
- `CONFIG_BINFMT_MISC` is not set: in-container QEMU binfmt registration skips gracefully (the log prints `binfmt_misc not supported by kernel`), so `enable_binfmt` has no effect on the device; cross-architecture binary emulation requires a kernel with that option enabled.
- The GPU render node `/dev/dri/renderD128` is available; enable GPU access when importing (the `droidspaces-gpu` group is built in).

## Build with GitHub Actions

1. Fork this repository to your own GitHub account.
2. Open the `Actions` page in your fork.
3. Select the Chinese workflow `编译并发布 Droidspaces RootFS` or the English workflow `Build and Release Droidspaces RootFS`.
4. Click `Run workflow`.
5. Choose the distribution, KDE mode, username, and feature toggles.
6. For Wayland/Anland builds, choose `Ubuntu-26-KDE`, `Debian-13-KDE`, `Fedora-43-KDE`, `Fedora-44-KDE`, or `Arch-KDE`, then enable `enable_anland_kde`.
7. If you want to rebuild the patched KWin/Xwayland packages before building the RootFS, enable `build_wayland_packages`.
8. Wait for the workflow to finish. Build time depends on the number of targets, KDE mode, and GitHub runner availability.
9. Open the `Releases` page and download the generated `.tar.xz` RootFS.

The Release usually contains:

- One or more RootFS archives
- RootFS filenames are marked by display mode as `X11`, `Wayland`, or `Mobile`, for example `Ubuntu-26-KDE-Mobile-Droidspaces-rootfs-aarch64-v20260702-120000.tar.xz`.
- `on_aaudio_socket.sh` or `on_aaudio_tcp.sh` when `PulseAudio` is set to `socket` or `tcp` and `build_KDE_plus=false`.
- A Release body that records the build target, KDE mode, Wayland setting, username, and feature toggles.

## Import into Droidspaces

1. Create or import a container in Droidspaces.
2. Select the `.tar.xz` RootFS downloaded from the Release.
3. If the RootFS includes KDE, enable GPU access in Droidspaces.
4. For Ubuntu and Debian, enabling `noseccomp` in privileged mode is strongly recommended. The kernel should also have `USER_NS` enabled. Without these, some desktop operations may freeze or lag noticeably.
5. For Fedora, some devices require hardware access. Without it, the desktop may flicker or crash.
6. For Arch, kernel 5.10 or newer is recommended.
7. For X11 mode, prepare Termux:X11.
8. For Wayland/Anland mode, complete the host-side Anland setup described below.

## Start KDE Desktop

When `build_KDE_plus` is enabled, the build installs the systemd service matching the selected desktop mode:

| Desktop mode | Service file | Start command |
| --- | --- | --- |
| X11 | `plasma-x11.service` | `DISPLAY=:5 startplasma-x11` |
| Wayland | `plasma-wayland.service` | `startplasma-wayland` |
| Mobile | `plasma-mobile.service` | `startplasmamobile` |

These services run as UID 1000 and load `/etc/environment`. If the desktop process fails, systemd restarts it after 2 seconds. If it fails more than 5 times within 60 seconds, systemd temporarily stops retrying to prevent a crash loop. A normal exit does not trigger a restart.

### X11 Mode

X11 mode applies to builds where `enable_anland_kde` is disabled. The default display environment is:

```text
DISPLAY=:5
```

It is recommended to keep `build_KDE_plus=true`, which is now the default. With it enabled, the RootFS creates a KDE auto-start systemd service so the desktop can start after the container boots. Disable it only when you want to use the Termux-side `on_aaudio_*` script to start the desktop manually, or when building a `none` command-line environment.

If the Release includes an audio startup script, run it from Termux to start PulseAudio, Termux:X11, and KDE:

```bash
chmod +x on_aaudio_socket.sh
./on_aaudio_socket.sh
```

Or:

```bash
chmod +x on_aaudio_tcp.sh
./on_aaudio_tcp.sh
```

Before using the script, check the variables at the top:

```bash
CONTAINER_NAME="your Droidspaces container name"
USERNAME="your RootFS username"
DISPLAY_NUMBER=":5"
DPI=315
```

`USERNAME` is patched automatically during Release generation according to `custom_username`, but `CONTAINER_NAME` must still match the container name in Droidspaces.

If you do not use the helper script, enter the container and start KDE manually:

```bash
startplasma-x11
```

The actual auto-start behavior still depends on Droidspaces systemd support, permissions, and the configured display backend. If the desktop does not start automatically, enter the container and run `startplasma-x11` for debugging.

### Wayland/Anland Mode

Wayland/Anland mode applies to Debian 13, Ubuntu 26, Fedora 43/44, and Arch builds where `enable_anland_kde` is enabled. The default environment includes:

```text
WAYLAND_DISPLAY=wayland-0
DISPLAY=:0
QT_QPA_PLATFORM=wayland
ANLAND=1
ANLAND_SOCKET=/run/display.sock
ANLAND_DRM_DEVICE=/dev/dri/renderD128
```

After completing the host-side Anland setup, run this inside the container:

```bash
startplasma-wayland
```

For a `mobile` build, the corresponding manual start command is:

```bash
startplasmamobile
```

## Wayland and Anland Setup

Wayland support depends on [anland](https://github.com/superturtlee/anland) and patched KWin/Xwayland prebuilt packages published through GitHub Releases. `Ubuntu-26-KDE` is recommended, while `Debian-13-KDE`, `Fedora-43-KDE`, `Fedora-44-KDE`, and `Arch-KDE` are also available. Arch rebuilds its packages in an ARM64 Arch container through `producers/kde/Arch_v5/build.sh` from the selected anland repository.

### One-Click Installation of Anland KDE Release Packages

`scripts/install-anland-kde.sh` automatically detects the current Linux distribution, uses `anland-kde-manifest` from the fixed rolling Release `anland-kde-packages` to select the exact archive, downloads the patched KWin/Xwayland packages by their KWin version, and prevents system updates from overwriting them. Binary packages are no longer added to Git history; this Release contains five independent archives for Arch, Debian 13, Ubuntu 26, Fedora 43, and Fedora 44. Archive names include the KWin version, for example `anland-kde-ubuntu2604-kwin-6.7.3-arm64.tar.gz`.
The script reads the system language in `LC_ALL`, `LC_MESSAGES`, and `LANG` priority order. Chinese locales produce Chinese messages; all other locales produce English messages.

The installer supports Debian 13, Ubuntu 26.04, Fedora 43/44, and Arch Linux on ARM64/aarch64 only. It downloads, preflights, and extracts packages as the invoking user, then elevates only for installation. Debian and Ubuntu use installer-managed `apt-mark hold` state, Fedora uses a managed `excludepkgs` block in `/etc/dnf/dnf.conf`, and Arch uses pacman `IgnorePkg` entries for equivalent package locking.

Run it from the repository root:

```bash
sudo ./scripts/install-anland-kde.sh
```

On startup, the installer probes GitHub, `gh-proxy.com`, and `ghproxy.net` in that fixed order. A probe taking two seconds or longer is shown as a timeout; enter `1`, `2`, or `3` to choose a source. When a third-party mirror is selected, both the downloaded manifest and archive are verified against SHA-256 digests published by the GitHub Release API; this requires `jq`, `sha256sum`, and access to `api.github.com`. For non-interactive use, pass `-1` or `--1` to select GitHub directly and skip probing. GitHub Actions builds use `--1`.

Or download the installer directly:

```bash
curl -fLO https://raw.githubusercontent.com/Goldzxcbug/Droidspaces-rootfs-KDE-builder/main/scripts/install-anland-kde.sh
chmod +x install-anland-kde.sh
sudo ./install-anland-kde.sh
```

Recommended build options:

| Option | Recommended value |
| --- | --- |
| `build_target` | `Ubuntu-26-KDE` |
| `build_KDE` | `min`, `conc`, or `mobile` |
| `build_KDE_plus` | `true` |
| `enable_anland_kde` | `true` |
| `PulseAudio` | No manual setting required; it becomes `none` when Anland is enabled |

Host-side setup:

1. Download `virtual-drm-daemon.zip` from [anland Releases](https://github.com/superturtlee/anland/releases), flash it, and reboot the device.
2. Download and install `app-debug.apk` from the same Release.
3. Enable hardware access when importing the Droidspaces container.
4. Enable SELinux permissive mode, or use the precise SELinux policy fix documented below.
5. Enable `nocaps` and `noseccomp` in privileged mode.
6. Add this bind mount in advanced options:

```text
/data/local/tmp/display_daemon.sock -> /run/display.sock
```

7. Start the container and log in as the normal user.
8. Run:

```bash
startplasma-wayland
```

If `mobile` is selected, the workflow forces Wayland on because Plasma Mobile is configured through the Wayland path in this project.

## Droidspaces USB Manager

Eight of the distribution templates (all except NixOS) install [Droidspaces-USB-Manager](https://github.com/Yizhou147/Droidspaces-USB-Manager) through `scripts/install-usb-manager.sh`; NixOS's declarative layout does not integrate it yet (see the NixOS notes above). The installer detects Debian/Ubuntu, Fedora, or Arch-family systems including Artix, installs the matching PyQt5, ADB, udev, NTFS, and exFAT dependencies through APT, DNF, or Pacman, and fixes command paths that are Debian-specific in the upstream source.

Hardware access must be enabled when importing the RootFS into Droidspaces. Without it, `/sys/bus/usb` and `/sys/bus/scsi` devices are not visible inside the container. The installer creates both an application-menu entry and a `~/Desktop/usb-manager.desktop` desktop shortcut. After entering KDE, you can also run:

```bash
usb-manager
```

Two command-line entry points are also installed:

```bash
usb-passthrough
usb-storage-passthrough
```

To install or update the application separately on an existing system, run this from the repository root:

```bash
sudo ./scripts/install-usb-manager.sh --user "$USER"
```

Like `scripts/install-anland-kde.sh`, this installer supports automatic privilege escalation and Chinese/English output. If `--user` is omitted, it tries `SUDO_USER`, the logged-in user, and then the first regular user.

## Local Build

This project is designed primarily for GitHub Actions, but local Docker Buildx builds are supported. Requirements:

- Docker
- Docker Buildx
- `xz`
- A working QEMU/binfmt setup if cross-architecture builds are required

Native build example:

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

QEMU arm64 build example:

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

After a successful build, the output file will look similar to:

```text
Ubuntu-26-KDE-Wayland-Droidspaces-rootfs-aarch64-local.tar.xz
```

## Install Hardware Firmware

Debian 13 and Ubuntu 24/25/26 RootFS images include `/usr/local/bin/download-firmware`. It installs `linux-firmware`, decompresses `.zst` firmware under `/lib/firmware` into regular firmware files, and repairs symbolic links that previously pointed to compressed files. This is useful when a kernel, driver, or container environment cannot load compressed firmware directly.

The tool is copied into the RootFS but is not run automatically during the build or container startup. Run it manually inside the container when needed:

```bash
sudo download-firmware
```

The script installs `zstd` and `linux-firmware`, so working package repositories and network access are required. On success it creates `/var/lib/.fw-setup-completed`. The current script does not use this marker to skip later runs; running it again still refreshes package metadata and scans the firmware directory.

## Repository Layout

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

KDE packages are published only as GitHub Release assets. When running `build-kde-wayland.yml` manually, `build_target=all` pins one Anland source commit and rebuilds all five platforms. If one platform fails, the workflow reuses that platform's archive from the fixed rolling Release, updates only the successful platforms, and rewrites the same `anland-kde-packages` Release with its archives and `anland-kde-manifest`. Selecting one platform rebuilds and replaces only that package; the other four archives remain unchanged. If the fixed Release cannot provide a complete five-platform set, or no new package succeeds, the workflow fails without updating the Release. It never commits packages or rewrites `main`; the fixed rolling Release is preserved.

## Known Limitations

- Wayland/Anland support covers Debian 13, Ubuntu 26, Fedora 43/44, and Arch; Artix and NixOS are not supported yet (X11 path only). `Arch-Niri` uses its own ANiri approach (not patched KWin).
- Ubuntu 24 and Ubuntu 25 currently use the X11 path.
- `mobile` mode is supported on Debian 13, Ubuntu 26, Fedora 43/44, and Arch; not yet on Artix, NixOS, or Arch-Niri.
- The `build_KDE` option is ignored for `Arch-Niri`; its ANiri upstream has known issues such as slightly lower rendering performance and floating-window glitches (see the Arch-Niri notes above).
- NixOS-KDE supports only the `min` and `none` desktop profiles, falls back to software GPU rendering, and does not bundle the USB Manager (see the NixOS notes above).
- Artix-KDE depends on the ARMtix community repositories (unsigned); availability and update cadence depend on that community.
- When Anland is enabled, the workflow disables PulseAudio forwarding because the Anland app provides its own audio path.
- Fedora may require hardware access on some devices to avoid flicker or crashes.
- Ubuntu and Debian may lag or freeze if `noseccomp` is disabled or the kernel lacks `USER_NS`.
- The default password is `1234`; change it after importing the RootFS.
- Compatibility between the bundled prebuilt Wayland packages and upstream anland depends on the upstream state at build time.

## Acknowledgements

- [Droidspaces-OSS](https://github.com/ravindu644/Droidspaces-OSS/): the runtime foundation used by this project.
- [mesa-for-android-container](https://github.com/lfdevs/mesa-for-android-container): Snapdragon GPU driver support.
- [TMOE](https://github.com/2moe/tmoe): convenient management tooling inside the container.
- [anland](https://github.com/superturtlee/anland): Wayland display backend and patched KDE work.
- [Droidspaces-USB-Manager](https://github.com/Yizhou147/Droidspaces-USB-Manager): USB storage and ADB device management for Droidspaces.
- [ARMtix](https://armtixlinux.org/): the Artix Linux aarch64 community port used by `Artix-KDE`.
- [ANiri](https://github.com/Celvra/ANiri), [niri](https://github.com/niri-wm/niri), and [Noctalia](https://github.com/noctalia-dev/noctalia): the scrollable-tiling desktop stack behind `Arch-Niri`.
