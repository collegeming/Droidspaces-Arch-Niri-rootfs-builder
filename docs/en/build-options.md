[Documentation index](README.md) · [Project home](../../README_english.md)

# Build Options

Choose the target, desktop, display backend, and optional features on the GitHub Actions `Run workflow` page. Desktop images are intended for ARM64 Droidspaces containers.

## Distribution and desktop support

| Target | Base image | Desktop profiles | Anland Wayland |
| --- | --- | --- | --- |
| `Debian-13` | Debian 13 (trixie) | `none`, `KDE`, `KDE mobile`, `GNOME`, `Anland Next` | Yes |
| `Ubuntu-24` | Ubuntu 24.04 | `none`, `KDE` | No |
| `Ubuntu-25` | Ubuntu 25.10 | `none`, `KDE` | No |
| `Ubuntu-26` | Ubuntu 26.04 | `none`, `KDE`, `KDE mobile`, `GNOME`, `Anland Next` | Yes |
| `Fedora-43` | Fedora 43 | `none`, `KDE`, `KDE mobile`, `Anland Next` | Yes |
| `Fedora-44` | Fedora 44 | `none`, `KDE`, `KDE mobile`, `Anland Next` | Yes |
| `Arch` | Arch Linux ARM | `none`, `KDE`, `KDE mobile`, `Anland Next` | Yes |

`all` filters targets according to desktop/backend support. `all-wayland` builds five Wayland targets for KDE/KDE Mobile; GNOME builds only Debian 13 and Ubuntu 26. GNOME, KDE Mobile, and Anland Next force `anland-wayland`.

| Desktop | Description |
| --- | --- |
| `none` | Command-line environment for SSH, development, or a custom desktop. |
| `KDE` | KDE Plasma; X11 or Anland Wayland, depending on the target. |
| `KDE mobile` | Touch-first Plasma Mobile; requires Anland Wayland. |
| `GNOME` | Anland Wayland only, on Debian 13 and Ubuntu 26. |
| `Anland Next` | An Anland session with rootless Xwayland and mini-wm, without a full desktop; Wayland only. |

## Workflow inputs

| Input | Values / default | Description |
| --- | --- | --- |
| `build_target` | Distribution, `all`, `all-wayland`; default `Debian-13` | Select build targets. |
| `custom_username` | 1–32 letters, digits, `_`, or `-`, starting with a letter or `_`; default `Gold` | Normal RootFS user. |
| `desktop` | `none`, `KDE`, `KDE mobile`, `GNOME`, `Anland Next`; default `KDE` | Select desktop or command-line mode. |
| `desktop_autostart` | `true` / `false`; default `true` | Installs the desktop startup service; must be disabled for `none`. |
| `display_backend` | `x11` / `anland-wayland` | Defaults to Wayland in the Chinese workflow and X11 in the English workflow; some profiles force Wayland. |
| `PulseAudio` | `socket` / `tcp` / `none`; default `socket` | X11 audio forwarding; Anland sets this to `none`. |
| `enable_zh_tz` | `true` / `false` | Installs Chinese locale and Shanghai timezone; defaults differ by workflow. |
| `enable_mesa` | `true` / `false`; default `true` | Adds Snapdragon GPU/Mesa support. |
| `enable_8gen2_wayland` | `true` / `false`; default `false` | Sets the Turnip UBWC Wayland workaround for relevant devices. |
| `nosnap` | `true` / `false` | Ubuntu only: removes Snap and prevents APT from reinstalling it; defaults differ by workflow. |
| `enable_systemd257` | `true` / `false`; default `false` | Tries the systemd 257 package family for old Android kernels; only `none` and standard `KDE` are supported. |
| `enable_srf` | `true` / `false` | Installs Fcitx5; enabled by default in the Chinese workflow, disabled in English. |
| `enable_binfmt` | `true` / `false`; default `false` | Adds binfmt cross-architecture support; not recommended for Arch. |
| `enable_yj` | `true` / `false`; default `true` | Improves NAT and Android/Droidspaces hardware recognition. |
| `enable_kfgj` | `true` / `false`; default `false` | Installs development tools such as compilers, CMake, and Python. |
| `enable_zip` | `true` / `false`; default `true` | Installs common compression tools. |
| `enable_docker` | `true` / `false`; default `false` | Installs Docker packages in the RootFS. |
| `wayland_package_repository` | Public `owner/repository`; default `Goldzxcbug/droidspaces-package` | Selects the source for Anland KDE/GNOME package Releases. |

For exact defaults, see `.github/workflows/build-rootfs-releases-en.yml` and `build-rootfs-releases.yml`. `enable_systemd257` is experimental and adds build time. Systems already at systemd 257 or older skip installation; details are in the [script guide](../../scripts/README_english.md).
