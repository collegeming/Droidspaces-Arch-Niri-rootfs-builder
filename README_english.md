English | [中文](README.md)

# Droidspaces RootFS Automated Build

This project builds Linux RootFS archives for Droidspaces through GitHub Actions. The build uses extensible desktop profiles and independently selected display backends. KDE, KDE Mobile, and GNOME profiles are provided.

The goal is to reduce the amount of manual setup required to run a desktop Linux container on Android. Fork the repository, choose the build options in GitHub Actions, wait for the Release artifact, then import the generated `.tar.xz` RootFS into Droidspaces.

## Table of Contents

- [Supported Targets](#supported-targets)
- [Feature Overview](#feature-overview)
- [Build Options](#build-options)
- [Build with GitHub Actions](#build-with-github-actions)
- [Import into Droidspaces](#import-into-droidspaces)
- [Start Desktop](#start-desktop)
- [Wayland and Anland Setup](#wayland-and-anland-setup)
- [Droidspaces USB Manager](#droidspaces-usb-manager)
- [Account, Password, and Username Changes](#account-password-and-username-changes)
- [Local Build](#local-build)
- [Install Hardware Firmware](#install-hardware-firmware)
- [Repository Layout](#repository-layout)
- [Known Limitations](#known-limitations)
- [Acknowledgements](#acknowledgements)

## Supported Targets

| Build target | Base image | Desktop profiles | Anland Wayland | Notes |
| --- | --- | --- | --- | --- |
| `Debian-13` | `debian:trixie` | `none`, `KDE`, `KDE mobile`, `GNOME` | Supported | GNOME is Anland Wayland-only. |
| `Ubuntu-24` | `ubuntu:24.04` | `none`, `KDE` | Not supported | Supports `nosnap`. |
| `Ubuntu-25` | `ubuntu:25.10` | `none`, `KDE` | Not supported | Supports `nosnap`. |
| `Ubuntu-26` | `ubuntu:26.04` | `none`, `KDE`, `KDE mobile`, `GNOME` | Supported | Supports `nosnap`; GNOME is Anland Wayland-only. |
| `Fedora-43` | `fedora:43` | `none`, `KDE`, `KDE mobile` | Supported | Some devices require hardware access to avoid flicker or crashes. |
| `Fedora-44` | `fedora:44` | `none`, `KDE`, `KDE mobile` | Supported | Some devices require hardware access. |
| `Arch` | `ogarcia/archlinux` | `none`, `KDE`, `KDE mobile` | Supported | Uses ARM64 Arch patched KWin/Xwayland; this project's QEMU/binfmt flow is not recommended for Arch at the moment. |

`all` filters Dockerfile templates through the selected desktop/backend capabilities, so GNOME builds only `Debian-13` and `Ubuntu-26`. For KDE profiles, `all-wayland` builds all five Wayland targets; for GNOME, it builds those two targets. KDE Mobile and GNOME both force Anland Wayland.

## Feature Overview

- Multi-distribution RootFS builds for Debian, Ubuntu, Fedora, and Arch.
- Desktop choices for command-line only, KDE, KDE mobile, and GNOME RootFS images.
- A unified maintenance TUI: run `droidspaces-tui`, `dstui`, or `ds-tui` in the container to install Mesa, Hangover Wine, Wine fonts, and Anland KDE/GNOME components.
- Desktop auto-start and failure recovery using shared systemd service templates for X11, Plasma Wayland, Plasma Mobile, and GNOME Wayland, with rate-limited automatic restarts after failures.
- Termux:X11 desktop startup support. X11 mode defaults to `DISPLAY=:5`.
- PulseAudio forwarding through Unix socket, TCP, or disabled mode.
- Optional Chinese locale with `zh_CN.UTF-8` and `Asia/Shanghai` timezone.
- Optional Fcitx5 input method. Chinese input addons are installed when Chinese localization is enabled.
- Snapdragon GPU support using configuration from `mesa-for-android-container`.
- All seven distributions use `scripts/install-mesa.sh` to install the matching ARM64 Mesa driver and latest `droidspaces-media-decode` VA-API driver, then lock only the related Mesa packages. The Anland KDE and GNOME installers separately hold KWin/Xwayland and Mutter/Xwayland. Source selection, integrity verification, and hold mechanisms are documented in the [scripts directory guide](scripts/README_english.md#mesa-installer).
- Native ARM64 Google Chrome: every desktop profile replaces Chromium with Chrome Stable. Debian/Ubuntu and Fedora use Google's official repositories; Arch uses the ARM64 AUR packaging recipe.
- Optional Snapdragon 8 Gen 2 Wayland display-corruption fix through a Turnip UBWC environment setting.
- Container integration improvements for common Android/Droidspaces hardware, network, and group recognition.
- Optional TMOE integration. Run `tmoe` inside the container to start it.
- Optional development toolchain packages, including compilers, CMake, and Python development tooling.
- Optional compression utilities such as `zip`, `unzip`, `7z`, `xz`, `tar`, and `gzip`.
- Optional Docker packages inside the RootFS.
- Optional old-kernel systemd compatibility: on apt, dnf, or pacman targets whose systemd major version is above 257, install a complete package-manager-owned systemd 257 family; only `none` and verified standard `KDE` are supported, while Debian 13 and other 257-or-older systems skip installation automatically.
- ARM64 Wayland/Anland support through the separate [`droidspaces-package`](https://github.com/Goldzxcbug/droidspaces-package) repository: patched KWin/Xwayland for KDE, plus patched Mutter/Xwayland for GNOME on Debian 13 and Ubuntu 26.04.
- USB device management on every distribution through Droidspaces USB Manager, including USB storage, ADB device nodes, mounting, unmounting, and a system tray interface.
- Automatic Release publishing with the RootFS `.tar.xz` files.

## Build Options

The main GitHub Actions inputs are:

| Option | Values | Default | Description |
| --- | --- | --- | --- |
| Distribution to build (`build_target`) | Distribution target, `all`, `all-wayland` | `Debian-13` | Selects which RootFS target to build. |
| Custom username (`custom_username`) | 1–32 letters, digits, `_`, or `-`; starts with a letter or `_` | `Gold` | Default user inside the RootFS. |
| Desktop (`desktop`) | `none`, `KDE`, `KDE mobile`, `GNOME` | `KDE` | Selects the command-line environment or a currently available desktop profile. |
| Desktop auto-start (`desktop_autostart`) | `true`, `false` | `true` | Creates the common desktop session service. It must be off for `none`. |
| Display backend (`display_backend`) | `x11`, `anland-wayland` | `x11` | KDE Mobile and GNOME force `anland-wayland`; GNOME has no X11 build. |
| PulseAudio forwarding (`PulseAudio`) | `socket`, `tcp`, `none` | `socket` | Audio forwarding mode for X11 builds. It is forced to `none` when Anland is enabled. |
| Chinese language and timezone (`enable_zh_tz`) | `true`, `false` | `false` in the English workflow | Enables Chinese locale and the Shanghai timezone. |
| Qualcomm Snapdragon GPU support (`enable_mesa`) | `true`, `false` | `true` | Enables Qualcomm Snapdragon GPU and Mesa-related support. |
| Fix Snapdragon 8 Gen 2 Wayland display corruption (`enable_8gen2_wayland`) | `true`, `false` | `false` | Writes `FD_DEV_FEATURES=enable_tp_ubwc_flag_hint=1` to `/etc/environment` for Debian 13, Ubuntu 26, Fedora 43/44, and Arch. |
| Integrate TMOE (`enable_tmoe`) | `true`, `false` | `true` | Integrates TMOE. |
| Remove Ubuntu Snap (`nosnap`) | `true`, `false` | `false` | Ubuntu-only option that removes Snap, snapd, and APT policy paths that may reinstall snapd. |
| systemd 257 old-kernel compatibility (`enable_systemd257`) | `true`, `false` | `false` | Supports only `none` and standard `KDE`. KDE keeps the selected backend and auto-start setting; other desktops fall back to `none`, or are rejected with `all-wayland`. Installs and locks the complete native family above systemd 257, and skips installation on 257 or older. |
| Fcitx5 input method support (`enable_srf`) | `true`, `false` | `false` | Installs Fcitx5 input method support. |
| Cross-architecture support (`enable_binfmt`) | `true`, `false` | `false` | Adds binfmt cross-architecture components inside the RootFS. Not recommended for Arch in this project. |
| NAT and hardware recognition (`enable_yj`) | `true`, `false` | `true` | Enables container hardware and network recognition improvements. |
| Development tools integration (`enable_kfgj`) | `true`, `false` | `false` | Installs development tools. |
| Compression tools integration (`enable_zip`) | `true`, `false` | `true` | Installs common compression tools. |
| Docker integration (`enable_docker`) | `true`, `false` | `false` | Installs Docker-related packages inside the RootFS. |
| Wayland package repository (`wayland_package_repository`) | Public `owner/repository` | `Goldzxcbug/droidspaces-package` | Selects the source of the `anland-kde-packages` or `anland-gnome-packages` Release. RootFS forks are never compared with the official package repository. |

Desktop mode details:

| Mode | Description | Recommended use |
| --- | --- | --- |
| `none` | Does not install a desktop. Keeps a command-line environment only. | Lightweight RootFS, SSH use, development environments, or custom desktop setups. |
| `KDE` | KDE desktop with system tools, monitoring, file management, and multimedia components. | General desktop use. |
| `KDE mobile` | KDE Plasma Mobile components. | Phone-screen and touch-first usage; forces Wayland in this project. |
| `GNOME` | GNOME Shell, Settings, Files, and common desktop components. | Anland Wayland on Debian 13 or Ubuntu 26; X11 is not supported. |

Audio mode details:

| Mode | Description |
| --- | --- |
| `socket` | Uses a Unix socket for PulseAudio forwarding. This is usually lower latency and is recommended for X11 mode. |
| `tcp` | Uses `127.0.0.1:4713` for PulseAudio forwarding. It is straightforward to debug, but exposes a wider interface. |
| `none` | Does not configure PulseAudio. Anland mode automatically uses this value because the Anland app provides its own audio path. |

### systemd 257 old-kernel compatibility

When `enable_systemd257` is enabled, the build runs `scripts/systemd257.sh`. The script first detects the installed systemd major version:

- the allowlist contains only `none` and standard `KDE`: KDE keeps its X11/Anland Wayland and auto-start settings; GNOME, KDE Mobile, and future unverified desktops fall back to `none`, or are rejected under `all-wayland`;
- systemd 257 or older (for example Debian 13 and Ubuntu 24.04) is skipped;
- apt, dnf, and pacman systems above 257 install their complete systemd 257 package family from the frozen compatibility Release `systemd257-packages` in `droidspaces-package`; later package sets are published under immutable tags before the RootFS updates its tag and pinned verification metadata together;
- installation is handled by the native package manager; APT is forbidden from removing existing packages, and systemd-related packages are locked so a later upgrade does not overwrite the compatibility version.

This option targets old Android kernels and is experimental. It adds substantial build time; test dbus, udev, and networking behavior on the target kernel before distributing the image.

## Build with GitHub Actions

1. Fork this repository to your own GitHub account.
2. Open the `Actions` page in your fork.
3. Select the Chinese workflow `编译并发布 Droidspaces RootFS` or the English workflow `Build and Release Droidspaces RootFS`.
4. Click `Run workflow`.
5. Choose the distribution, desktop profile, display backend, username, and feature toggles.
6. For Wayland/Anland builds, choose `display_backend=anland-wayland`; it is supported on Debian 13, Ubuntu 26, Fedora 43/44, and Arch.
7. The default source is `Goldzxcbug/droidspaces-package`. To use your package fork, set `wayland_package_repository` to its public `owner/repository`; RootFS does not compare which repository is newer.
8. To rebuild patched KWin/Xwayland or Mutter/Xwayland packages, run the corresponding Anland package workflow in the selected package repository.
9. Wait for the RootFS workflow, then open its `Releases` page and download the generated `.tar.xz`.

The Release usually contains:

- One or more RootFS archives
- RootFS filenames include the desktop slug and display backend, for example `Ubuntu-26-kde-Wayland-Droidspaces-rootfs-aarch64-v20260702-120000.tar.xz`.
- A Release body that records the build target, desktop profile, display backend, username, and feature toggles.

## Import into Droidspaces

1. Create or import a container in Droidspaces.
2. Select the `.tar.xz` RootFS downloaded from the Release.
3. If the RootFS includes a desktop, enable GPU access in Droidspaces.
4. For Ubuntu and Debian, enabling `noseccomp` in privileged mode is strongly recommended. The kernel should also have `USER_NS` enabled. Without these, some desktop operations may freeze or lag noticeably.
5. For Fedora, some devices require hardware access. Without it, the desktop may flicker or crash.
6. For Arch, kernel 5.10 or newer is recommended.
7. For X11 mode, prepare Termux:X11.
8. For Wayland/Anland mode, complete the host-side Anland setup described below.

## Start Desktop

When `desktop_autostart` is enabled, the build installs `desktop-session.service`. It reads `/etc/droidspaces-desktop.conf` to choose the session:

| Desktop mode | Service file | Start command |
| --- | --- | --- |
| KDE + X11 | `desktop-session.service` | `DISPLAY=:5 startplasma-x11` |
| KDE + Anland Wayland | `desktop-session.service` | `startplasma-wayland` |
| KDE Mobile + Anland Wayland | `desktop-session.service` | `startplasmamobile` |
| GNOME + Anland Wayland | `desktop-session.service` | `gnome-session --session=gnome` (the build writes the GNOME session variables to `/etc/environment`) |

This service runs as UID 1000 and loads `/etc/environment`. If the desktop process fails, systemd restarts it after 2 seconds. If it fails more than 5 times within 60 seconds, systemd temporarily stops retrying to prevent a crash loop. A normal exit does not trigger a restart.

### X11 Mode

KDE X11 mode applies to builds with `display_backend=x11`. Its desktop profile writes:

```text
XCURSOR_SIZE=48
DISPLAY=:5
```

It is recommended to keep `desktop_autostart=true`, which is the default. The RootFS then creates a common desktop auto-start service. Disable it only to manage the desktop process yourself or when building a `none` command-line environment.

When auto-start is disabled, enter the container and start KDE manually:

```bash
startplasma-x11
```

The actual auto-start behavior still depends on Droidspaces systemd support, permissions, and the configured display backend. If the desktop does not start automatically, enter the container and run `startplasma-x11` for debugging.

### Wayland/Anland Mode

Wayland/Anland mode applies to Debian 13, Ubuntu 26, Fedora 43/44, and Arch builds with `display_backend=anland-wayland`. The KDE and KDE Mobile profiles write:

```text
XCURSOR_SIZE=48
WAYLAND_DISPLAY=wayland-0
QT_QPA_PLATFORM=wayland
ANLAND=1
ANLAND_SOCKET=/run/display.sock
ANLAND_DRM_DEVICE=/dev/dri/renderD128
```

After completing the host-side Anland setup, run this inside the container:

```bash
startplasma-wayland
```

For a `KDE mobile` build, the corresponding manual start command is:

```bash
startplasmamobile
```

The GNOME profile writes:

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

The corresponding manual start command is:

```bash
gnome-session --session=gnome
```

## Wayland and Anland Setup

Wayland support depends on [anland](https://github.com/superturtlee/anland) and prebuilt packages published by [`droidspaces-package`](https://github.com/Goldzxcbug/droidspaces-package). KDE uses patched KWin/Xwayland, while GNOME uses patched Mutter/Xwayland and is limited to Debian 13 and Ubuntu 26. Package builds, updates, and fixed rolling Releases are maintained in the separate package repository.

### One-Click Installation of Anland KDE Release Packages

`scripts/install-anland-kde.sh` detects the ARM64 distribution, installs matching patched KWin/Xwayland packages from the fixed rolling Release in `Goldzxcbug/droidspaces-package` by default, and locks the related packages. Supported systems, download mirrors, integrity checks, options, and standalone installation details are documented in the [scripts directory guide](scripts/README_english.md#anland-kde-installer).

Run it from the repository root:

```bash
sudo ./scripts/install-anland-kde.sh
```

The GNOME installer supports Debian 13 and Ubuntu 26 ARM64 and reads the fixed `anland-gnome-packages` Release:

```bash
sudo ./scripts/install-anland-gnome.sh
```

Recommended build options:

| Option | Recommended value |
| --- | --- |
| `build_target` | `Ubuntu-26` |
| `desktop` | `KDE`, `KDE mobile`, or `GNOME` |
| `desktop_autostart` | `true` |
| `display_backend` | `anland-wayland` |
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

If `KDE mobile` or `GNOME` is selected, the workflow forces Wayland on. GNOME also selects the patched Mutter/Xwayland package family.

## Droidspaces USB Manager

All seven distribution templates install [Droidspaces-USB-Manager](https://github.com/Yizhou147/Droidspaces-USB-Manager) through `scripts/install-usb-manager.sh`, including distribution dependencies, command-line entry points, an application-menu entry, and a desktop shortcut. Installer options and update instructions are in the [scripts directory guide](scripts/README_english.md#usb-manager-installer).

Hardware access must be enabled when importing the RootFS into Droidspaces. Without it, `/sys/bus/usb` and `/sys/bus/scsi` devices are not visible inside the container. The installer creates both an application-menu entry and a `~/Desktop/usb-manager.desktop` desktop shortcut. After entering KDE, you can also run:

```bash
usb-manager
```

Two command-line entry points are also installed:

```bash
usb-passthrough
usb-storage-passthrough
```

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

QEMU arm64 build example:

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

After a successful build, the output file will look similar to:

```text
Ubuntu-26-kde-Wayland-Droidspaces-rootfs-aarch64-local.tar.xz
```

## Install Hardware Firmware

Debian 13 and Ubuntu 24/25/26 RootFS images include `/usr/local/bin/download-firmware` for installing and decompressing hardware firmware. Dependencies, repeat-run behavior, and processing details are in the [scripts directory guide](scripts/README_english.md#firmware-tool).

The tool is copied into the RootFS but is not run automatically during the build or container startup. Run it manually inside the container when needed:

```bash
sudo download-firmware
```

## Repository Layout

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
│   ├── desktops/
│   │   ├── gnome.sh
│   │   ├── kde.sh
│   │   └── kde-mobile.sh
│   ├── lib/
│   │   ├── anland-build.sh
│   │   └── desktop-config.sh
│   ├── start/
│   │   └── desktop-session.service
│   ├── bashrc.sh
│   ├── download-firmware
│   ├── install-usb-manager.sh
│   ├── install-anland-desktop.sh
│   ├── install-anland-gnome.sh
│   ├── install-anland-kde.sh
│   ├── install-mesa.sh
│   ├── nosnap.sh
│   └── systemd257.sh
├── scripts/binfmt/
│   ├── qemu-binfmt-register.service
│   └── qemu-binfmt-register.sh
└── .github/workflows/
    ├── build-rootfs-core.yml
    ├── build-rootfs-releases-en.yml
    └── build-rootfs-releases.yml
```

The KDE and GNOME Wayland package workflows and fixed rolling Releases live in [`droidspaces-package`](https://github.com/Goldzxcbug/droidspaces-package). RootFS reads `anland-kde-packages` or `anland-gnome-packages` according to the selected desktop and does not switch sources merely because the RootFS repository is a fork. To maintain custom packages, publish a complete same-name Release in a package-repository fork and set `wayland_package_repository` to it.

## Known Limitations

- Wayland/Anland support covers Debian 13, Ubuntu 26, Fedora 43/44, and Arch.
- Ubuntu 24 and Ubuntu 25 currently use the X11 path.
- `KDE mobile` mode is supported on Debian 13, Ubuntu 26, Fedora 43/44, and Arch.
- `GNOME` supports only Debian 13 and Ubuntu 26 with Anland Wayland; X11 is not supported.
- When `anland-wayland` is selected, the workflow disables PulseAudio forwarding because the Anland app provides its own audio path.
- Fedora may require hardware access on some devices to avoid flicker or crashes.
- Ubuntu and Debian may lag or freeze if `noseccomp` is disabled or the kernel lacks `USER_NS`.
- The default password is `1234`; change it after importing the RootFS.
- Compatibility between the bundled prebuilt Wayland packages and upstream anland depends on the upstream state at build time.

## Acknowledgements

- [Droidspaces-OSS](https://github.com/ravindu644/Droidspaces-OSS/): the runtime foundation used by this project.
- [mesa-for-android-container](https://github.com/lfdevs/mesa-for-android-container): Snapdragon GPU driver support.
- [droidspaces-media-decode](https://github.com/Re-s/droidspaces-media-decode): Android MediaCodec-backed VA-API hardware decoding for containers.
- [TMOE](https://github.com/2moe/tmoe): convenient management tooling inside the container.
- [anland](https://github.com/superturtlee/anland): Wayland display backend and patched KDE work.
- [Droidspaces-USB-Manager](https://github.com/Yizhou147/Droidspaces-USB-Manager): USB storage and ADB device management for Droidspaces.
