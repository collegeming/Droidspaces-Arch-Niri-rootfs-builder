# AGENTS.md — Droidspaces RootFS Builder

## Project Purpose

This repo builds customized Linux RootFS images (tar.xz archives) for [Droidspaces](https://github.com/ravindu644/Droidspaces-OSS/) — a container runtime on Android. Builds target ARM64 containers with KDE desktop, running on Android kernels via Termux:X11.

## Architecture

- **Dockerfiles** (root): Each `*-KDE.Dockerfile` is a self-contained multi-stage build. The `customizer` stage installs everything, then `FROM scratch AS export` extracts the rootfs via `COPY --from=customizer /`.
- **Build scripts**: `build_rootfs-native.sh` (native ARM64 runner) and `build_rootfs-qemu-aarch64.sh` (cross-arch via QEMU). Both accept the same flags.
- **CI**: GitHub Actions workflow `build-rootfs-releases.yml` (Chinese) / `build-rootfs-releases-en.yml` (English). Triggered via `workflow_dispatch` with a visual menu. Builds on `ubuntu-24.04-arm` runner.
- **Helper scripts** in `scripts/`: audio startup (`on_aaudio_*.bashrc.sh`), firmware download, binfmt registration, shell aliases.

## Build Commands

**Local build (native ARM64):**
```bash
./build_rootfs-native.sh \
  -i Ubuntu-25-KDE.Dockerfile \
  -v v1 \
  -K min \        # KDE size: conc|min|none
  -L false \      # KDE auto-start
  -P socket \     # PulseAudio: socket|tcp|none
  -g true \       # Chinese locale
  -a false \      # binfmt cross-arch
  -b true \       # NAT/hw recognition
  -c true \       # Mesa GPU driver
  -d false \      # dev tools
  -e true \       # compression tools
  -f false \      # Docker-in-container
  -h false \      # fcitx5 input method
  -j true \       # TMOE
  -A false \      # anland_kde support (Ubuntu 26 only)
  -u Gold         # username
```

**Local build (QEMU cross-arch, x86 host → arm64):**
```bash
./build_rootfs-qemu-aarch64.sh [same flags]
```

**Output**: `<Distro>-Droidspaces-rootfs-<arch>-<date>-<version>.tar.xz`

## Dockerfile Structure (all distros follow this pattern)

1. Base image pull + repo enable
2. Copy `scripts/download-firmware` and `scripts/bashrc.sh`
3. Install core packages (bash, jq, curl, systemd, etc.)
4. Conditional KDE install (`BUILD_KDE` = conc/min/none)
5. Optional anland_kde support (Ubuntu 26 only, requires KDE)
6. Optional packages (fcitx5, dev tools, compression, docker, TMOE)
7. iptables-legacy forced (Android kernel requirement)
8. Locale + SSH + user creation (default user: `Gold`, password: `1234`)
9. Environment variables (`DISPLAY=:5`, `XCURSOR_SIZE=48`, PulseAudio)
10. Fcitx5 autostart + Mesa env vars
11. Mesa driver download from `lfdevs/mesa-for-android-container`
12. Android compat patches (aid_inet groups, systemd fixes, udev overrides)
13. Optional binfmt/QEMU setup
14. `FROM scratch AS export` → `COPY --from=customizer /`

## Key Gotchas

- **iptables-legacy is mandatory**: All Dockerfiles force `iptables-legacy` — Android kernel doesn't support nftables.
- **GUEST_SYSTEMD_PATH differs by distro**: Debian/Ubuntu use `/lib/systemd/system`, Fedora/Arch use `/usr/lib/systemd/system`.
- **Mesa download URL varies per distro**: Each Dockerfile uses a different regex to match the correct Mesa package from GitHub releases. Match the distro codename in the `jq` filter.
- **Arch uses `ogarcia/archlinux` base image**, not `archlinux:latest`.
- **Ubuntu 24 uses `neofetch`**, Ubuntu 25/26 and others use `fastfetch`.
- **Ubuntu 25/26 create user with `-G shadow`** group for screen lock support; Debian/Fedora don't.
- **Arch creates a `startplasma-x11` wrapper** at `/usr/local/bin/startplasma-x11` that wraps with `dbus-run-session`.
- **Binfmt on Ubuntu 26** uses `qemu-user-binfmt` (not `qemu-user-static`).
- **Workflow file has a leading space** in the filename: `.github/workflows/ build-rootfs-releases.yml` (note the space before `build`).
- **`enable_yj` controls systemd service visibility**: When false, udev/resolved/networkd/NetworkManager are masked with `/dev/null` symlinks.
- **`build_KDE_plus`** creates a systemd service (`plasma-x11.service`) that auto-starts KDE on boot. Invalid when `BUILD_KDE=none`.
- **`enable_anland_kde`** applies anland patches to KWin and Xwayland for Android GPU/display integration. Only supported on Ubuntu 26 and requires `BUILD_KDE=min` or `BUILD_KDE=conc`.

## File Naming Convention

- `*-KDE.Dockerfile` — distro Dockerfiles (must follow this pattern for the workflow matrix to pick them up)
- `scripts/on_aaudio_*.sh` — audio startup scripts bundled into releases
- `build_rootfs-native.sh` — native build
- `build_rootfs-qemu-aarch64.sh` — cross-arch build

## Workflow Inputs → Build Flags Mapping

| Workflow Input | Build Flag | Dockerfile ARG |
|---|---|---|
| `build_KDE` | `-K` | `BUILD_KDE` |
| `build_KDE_plus` | `-L` | `BUILD_KDE_plus` |
| `PulseAudio` | `-P` | `PulseAudio` |
| `enable_zh_tz` | `-g` | `ENABLE_zh_tz_ARG` |
| `enable_binfmt` | `-a` | `ENABLE_binfmt_ARG` |
| `enable_yj` | `-b` | `ENABLE_yj_ARG` |
| `enable_mesa` | `-c` | `ENABLE_mesa_ARG` |
| `enable_kfgj` | `-d` | `ENABLE_kfgj_ARG` |
| `enable_zip` | `-e` | `ENABLE_zip_ARG` |
| `enable_docker` | `-f` | `ENABLE_docker_ARG` |
| `enable_srf` | `-h` | `ENABLE_srf_ARG` |
| `enable_tmoe` | `-j` | `ENABLE_tmoe_ARG` |
| `enable_anland_kde` | `-A` | `ENABLE_anland_kde_ARG` |
| `custom_username` | `-u` | `USERNAME` |

## Commit Style

Chinese commit messages, no conventional commits enforced. Examples: `修复Ubuntu mesa 驱动问题`, `优化构建脚本逻辑`.
