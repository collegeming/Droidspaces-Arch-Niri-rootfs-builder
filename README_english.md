English | [中文](README.md)

# Droidspaces Arch-Niri RootFS Builder

An **Arch Linux + niri/ANiri + Anland + Noctalia** RootFS builder for ARM64 Android/Droidspaces, especially devices running 4.19 kernels. The only active target is `Droidspaces-Arch-Niri.Dockerfile`. It can produce kitty, ghostty, or both terminal variants with `remote=none|wayvnc|lamco`.

Droidspaces is a privileged container using namespaces and `pivot_root` on the shared Android kernel; it is **not PRoot**. This repository assembles and pins the Linux RootFS only. Android APKs, root helpers, Surface/MediaCodec components, and Magisk assets are device-side prerequisites and are never installed into the RootFS.

- Canonical repository: <https://github.com/collegeming/Droidspaces-Arch-Niri-rootfs-builder>
- Workflow: [Build and release Droidspaces Arch-Niri RootFS](https://github.com/collegeming/Droidspaces-Arch-Niri-rootfs-builder/actions/workflows/build-arch-niri-rootfs.yml)
- Chinese documentation: [README.md](README.md)
- Archived multi-distribution KDE files: [legacy/README.md](legacy/README.md)

## Project relationships and responsibilities

| Project | Responsibility | Current Builder status |
| --- | --- | --- |
| [niri](https://github.com/niri-wm/niri) / [Celvra/ANiri](https://github.com/Celvra/ANiri) | Upstream niri and historical source of the Anland backend | The Builder consumes the tuned fork's final immutable Release listed below. |
| [collegeming/ANiri-anland-tuned](https://github.com/collegeming/ANiri-anland-tuned) | Linux compositor, input, `CF_UNICODETEXT` clipboard, and Anland polling improvements | The RootFS pins final Arch ARM64 Release `v26.4.0-anland.5`; its source commit contains the `74ce2a9…` implementation baseline, minimal strict-Clippy fixes, and the final public-Release verification fix. |
| [superturtlee/anland](https://github.com/superturtlee/anland) / [collegeming/anland-bridge](https://github.com/collegeming/anland-bridge) | Android Surface, `local|remote|both` state, MediaCodec, FD/root helper | Final device-side prerequisite `anland-v5.19.3`. APK, daemon, and Magisk assets are installed only on the Android host/root side and never enter the RootFS. |
| [collegeming/lamco-anland-bridge](https://github.com/collegeming/lamco-anland-bridge) | Linux RDP/TLS/EGFX, input, CLIPRDR, and private UDS listener | `remote=lamco` consumes a pinned, verified ARM64 binary Release. Rust is not built inside the RootFS. |
| This Builder | Combines and pins the Linux RootFS, emits variants/checksums/metadata, and records Android prerequisites | One active Dockerfile and workflow; old KDE content is preserved only under `legacy/`. |

## Architecture and data paths

### Two distinct Unix sockets

These sockets are not interchangeable:

| Path | Purpose | Android-side source |
| --- | --- | --- |
| `/run/display.sock` | ANiri local display path to the Android Surface consumer | The display socket mounted by Droidspaces/Anland. |
| `/run/anland-rdp/bridge.sock` | Lamco's private HMAC mutual-auth bridge | Bind the Android directory `/data/local/tmp/anland-rdp` to `/run/anland-rdp`. |

Lamco requires a **directory bind**, not a bind of the individual `bridge.sock` inode. The service safely unlinks and rebinds its socket after restart; only a directory bind exposes the new inode. Never map this socket to the network or use `chmod 777`.

```text
/data/local/tmp/anland-rdp -> /run/anland-rdp
```

### Android display states: local / remote / both

These are states of the Android `anland-bridge`, not values of the Builder's `remote` input:

- `local`: retain only the local Android Surface viewer.
- `remote`: retain only the remote hardware-encoding/RDP graphics path.
- `both`: retain the local Surface and remote viewer together.
- When no viewer exists, or the viewer stays minimized and no local Surface exists, Android must stop the MediaCodec encoder and graphics-consumption chain to avoid idle encoding and continuous power use.

The Builder's `remote=none|wayvnc|lamco` only determines which remote service, if any, is installed in the RootFS.

### Encoding, input, clipboard, and audio boundaries

- H.264 is provided only by the **Android MediaCodec hardware Surface encoder**. There is no OpenH264, x264, FFmpeg, or libavcodec software fallback; the session fails or has no video when the hardware path is unavailable.
- Lamco does not capture the whole screen through Portal, PipeWire, screencopy, or Android MediaProjection. It consumes only the dedicated ANiri desktop delivered by the Anland bridge.
- Win/Super is forwarded as original RDP input. niri retains native `Mod+T`, `Mod+E`, and related semantics; Win-to-Alt translation is forbidden.
- RDP clipboard support is limited to `CF_UNICODETEXT`, including CJK, emoji, line breaks, and clear. Images, files, HTML, and RTF are unsupported.
- RDPSND is not implemented, so the PC receives no RDP audio. Local Android audio is a separate path.

## Exact version and compatibility matrix

| Component | Repository / annotated tag | Source commit / baseline | Asset / SHA-256 | Status |
| --- | --- | --- | --- | --- |
| ANiri tuned | [`collegeming/ANiri-anland-tuned` / `v26.4.0-anland.5`](https://github.com/collegeming/ANiri-anland-tuned/releases/tag/v26.4.0-anland.5), tag object `975beeef6d99c81d8ad98ac32500c0e96353dbdf` | source `6480280d4baa624d00cf26bb816e4312dc9409c9`; implementation baseline `74ce2a92eb2151d729818a784ced605ec950b56c` | [`niri-arm64-linux-bin`](https://github.com/collegeming/ANiri-anland-tuned/releases/download/v26.4.0-anland.5/niri-arm64-linux-bin) / `54f6aad1a8e47515527ac24fc120ff670675d75cbe6b4be6ae52fcdcfbc0227c` | Actually consumed by the RootFS; [successful three-job run](https://github.com/collegeming/ANiri-anland-tuned/actions/runs/32775049302). Public Arch ARM64 verification confirms `libdisplay-info.so.3`, every direct SONAME, `ldd`, and `--version`. |
| Android anland bridge | [`collegeming/anland-bridge` / `anland-v5.19.3`](https://github.com/collegeming/anland-bridge/releases/tag/anland-v5.19.3), tag object `1d912e982a8f35e90e81255afd9f8444cd319295` | source `e26a080e990d0c9fc18d64b35e161d134bc51e63`; feature baseline `95b2d73ff799639ce8576ff908f13f5a31e024a1` | plain APK, Tracy APK, `anland-daemon.zip`, and `SHA256SUMS`; see below | Final device-side prerequisite; [successful build run](https://github.com/collegeming/anland-bridge/actions/runs/32751299809). Never downloaded or installed into the RootFS. |
| Lamco | `collegeming/lamco-anland-bridge` / `anland-v0.2.0` | `03902875622f04c8c64ab52fd4dc72981bb93e64` | `lamco-anland-bridge-0.2.0-aarch64-unknown-linux-gnu.tar.xz` / `593a2639f7c06bc3f453ae094114f85e03f442f5d9482d132b5662cd9a146eea` | Actually consumed by `remote=lamco`; pin unchanged. |
| Lamco IronRDP pin | `collegeming/IronRDP` / branch `anland-preauth-timeout` | `33fc287b83af35ba3650519fe059db99d1cdf131` | Recorded in Lamco metadata | Pinned by the Lamco Release; unchanged. |

The ANiri Release also provides `BUILD-METADATA.txt` (SHA-256 `37b20cfa0aa5664790a2a0d67d21df41c9bcb58f619c9dc46db284629790064f`) and the CycloneDX SBOM `ANiri-SBOM.cdx.json` (SHA-256 `600e71d2cd3ad52f31f4690556a08e7430297c0aab62894e6f197e7b9e437734`). The Builder and ANiri use the same pinned Arch base index `sha256:f92ed48cdfc274181f16e94e6a4e90e4c90c59a3d14fc7a133483a93ebc16ec6`, ARM64 manifest `sha256:019992bf3dc54ab4ba1515dd80e613d473b2ca7a97e410e1da053ae501b6383d`, and layer `sha256:c714810994102b031ad2f2319282528593ae84ce86b5131b82e859642e3c79f4`.

Android `anland-v5.19.3` device-side assets:

| Asset | Role | SHA-256 / download |
| --- | --- | --- |
| `anland-bridge-5.19.3-plain-release-arm64-v8a.apk` | Normal device installation; recommended default | `f7d698d17a3611f8cb4a0af5c1f1d5781c8c84731f656de744b4251fab5b4c38` / [download](https://github.com/collegeming/anland-bridge/releases/download/anland-v5.19.3/anland-bridge-5.19.3-plain-release-arm64-v8a.apk) |
| `anland-bridge-5.19.3-tracy-profiling-release-arm64-v8a.apk` | Tracy profiling only | `983e2a03aac1f0d56dda2fb9e3ac7048e8d37051492714dd1c918a2e19fe2d29` / [download](https://github.com/collegeming/anland-bridge/releases/download/anland-v5.19.3/anland-bridge-5.19.3-tracy-profiling-release-arm64-v8a.apk) |
| `anland-daemon.zip` | Android host/root Magisk module and daemon | `a258b4a5de851f24cd94fe1232528de2d56d525ea54f0ec478592772da6f6df4` / [download](https://github.com/collegeming/anland-bridge/releases/download/anland-v5.19.3/anland-daemon.zip) |
| `SHA256SUMS` | Release checksum manifest | file SHA-256 `63b82e1e64c3574c94d3d7381fc44ac00df9bbfff5659ea36dad25702a43cc95` / [download](https://github.com/collegeming/anland-bridge/releases/download/anland-v5.19.3/SHA256SUMS) |

These APK/ZIP assets are **for the Android host/root side only**. The Dockerfile, workflow, and RootFS do not download, `COPY`, or install them. `anland-v5.19.2` is not recommended because its Tracy `versionName` was dirty; the final pin is only `anland-v5.19.3`.

The RootFS records `/usr/share/doc/droidspaces-arch-niri/ANIRI-PIN.txt` and `BUILD-COMPATIBILITY.txt`. The workflow also emits external `BUILD-METADATA.txt` and `SHA256SUMS`. The Builder commit comes from the exact runtime `github.sha`; mutable `latest` is not used.

## Active RootFS features

- ARM64 Arch Linux; niri/ANiri over Anland; Noctalia and fuzzel.
- kitty, ghostty, or two separate RootFS variants with `both`.
- fcitx5 + Rime-Ice, Chinese locale, Nemo, neovim, fish/reef/Fisher/Tide, and Maple Mono NF CN.
- Qualcomm KGSL Mesa and an optional Snapdragon 8 Gen 2 UBWC hint.
- systemd 257 old-kernel compatibility, Droidspaces USB manager, optional firmware/binfmt/container integration.
- Optional development tools, compression tools, Docker, and TMOE.
- `remote=none|wayvnc|lamco`.

The default Linux user is `colle` and can be changed at build time. The image currently initializes the Linux account password as `1234`; change it immediately with `passwd` after import. Lamco never reuses this password and requires independent strong RDP credentials.

## GitHub Actions build

The only active workflow is `.github/workflows/build-arch-niri-rootfs.yml`, named **Build and release Droidspaces Arch-Niri RootFS**.

Main inputs:

| Input | Values | Default |
| --- | --- | --- |
| `version` | Safe version/filename label; `candidate` receives run id/attempt suffixes | `candidate` |
| `publish_release` | Publish an immutable tag and Release | `false` |
| `build_mode` | `native-arm64` or `qemu-x86_64` | `native-arm64` |
| `username` | RootFS user | `colle` |
| `terminal` | `kitty|ghostty|both` | `kitty` |
| `remote` | `none|wayvnc|lamco` | `wayvnc` |
| `niri_autostart` | Auto-start niri | `true` |
| `enable_zh_locale` | Chinese locale and Asia/Shanghai timezone | `true` |
| `enable_fcitx_rime` | fcitx5 + Rime-Ice | `true` |
| `enable_qualcomm_mesa` | Qualcomm KGSL Mesa | `true` |
| `enable_systemd257` | systemd 257 compatibility runtime | `true` |
| `enable_usb_manager` | Droidspaces USB manager | `true` |
| `enable_firmware` | Linux firmware packages | `false` |
| `enable_binfmt` | In-RootFS binfmt helpers | `false` |
| `enable_container_integration` | Droidspaces hardware/network integration | `true` |
| `enable_8gen2_wayland` | Snapdragon 8 Gen 2 UBWC hint | `false` |
| `enable_dev_tools` | Development toolchain | `false` |
| `enable_compression_tools` | Additional compression tools | `true` |
| `enable_docker` | Docker packages inside the RootFS | `false` |
| `enable_tmoe` | TMOE integration | `false` |

### Candidate and publication safety

1. Normal validation keeps `publish_release=false`. Outputs remain Actions artifacts and no tag or Release is created.
2. `native-arm64` uses a fixed ARM64 runner, and the native script rejects non-ARM64 hosts.
3. `qemu-x86_64` explicitly registers arm64 QEMU on an x86_64 runner and builds only `linux/arm64`. ARM64 hosts cannot accidentally use this script.
4. `terminal=both` expands to kitty and ghostty variants. Filenames always include the real `remote` and `terminal` values:

   ```text
   Droidspaces-Arch-Niri-Anland-aarch64-<version>-<remote>-<terminal>.tar.xz
   ```

5. Each archive passes `xz -t`, tar listing, and an independent SHA-256 check before the exact asset set is assembled.
6. `publish_release=true` is allowed only on `main` with an explicit non-`candidate` version. The workflow checks that the tag and Release do not exist both before building and immediately before publication; replacement of any existing tag, Release, or asset is refused.
7. Third-party actions are pinned to 40-character commit SHAs. Default permissions are `contents: read`; only the release job receives `contents: write`.

This project does not trigger workflows automatically. A human must explicitly run the workflow. An old run or Release does not validate the current Builder commit.

## Local build

Docker, Buildx, and `xz` are required. Run commands from the repository root.

Native ARM64 host:

```bash
./build_rootfs-native.sh \
  -i Droidspaces-Arch-Niri.Dockerfile \
  -v local \
  -u colle \
  -T both \
  -R lamco \
  -N true -g true -h true -c true -S true \
  -U true -F false -a false -b true -t false \
  -d false -e true -f false -j false
```

An x86_64 host must use the explicit QEMU script:

```bash
./build_rootfs-qemu-aarch64.sh \
  -i Droidspaces-Arch-Niri.Dockerfile \
  -v local \
  -u colle \
  -T kitty \
  -R none \
  -N true -g true -h true -c true -S true \
  -U true -F false -a false -b true -t false \
  -d false -e true -f false -j false
```

The scripts reject the wrong host architecture, a non-canonical Dockerfile, unsafe versions/usernames, and invalid boolean, terminal, or remote values.

## Import and local display

1. Import the `.tar.xz` into a privileged Droidspaces container. Do not follow PRoot setup instructions.
2. Enable GPU and required hardware access for Qualcomm Mesa/niri.
3. Keep `enable_systemd257=true` for 4.19 kernels. `enable_binfmt` is useful only when the target kernel enables `CONFIG_BINFMT_MISC`.
4. Configure the Android Anland side from final Release [`anland-v5.19.3`](https://github.com/collegeming/anland-bridge/releases/tag/anland-v5.19.3) and make the local display socket available at `/run/display.sock`. These are Android host/root assets; do not search for APKs, daemons, or Magisk ZIPs inside the RootFS.
5. `niri.service` auto-starts by default. Inspect it with:

   ```bash
   systemctl status niri.service
   journalctl -u niri.service
   ```

6. Change the Linux account password after the first import: `passwd`.

## Remote access

### `remote=none`

No remote service is installed. Only the local Android Surface display path is used.

### `remote=wayvnc`

wayvnc listens on guest `0.0.0.0:5900` and currently has no VNC password. Use it only on a trusted network and restrict access with a firewall, SSH tunnel, or Droidspaces isolation/port-publication policy.

- **host/shared networking**: connect to `<phone WLAN IP>:5900`.
- **isolated/NAT networking**: publish guest TCP 5900 on a host port and use the `<host address>:<host port>` actually reported by Droidspaces. Without publication, the phone WLAN address cannot directly reach guest port 5900.

wayvnc uses a separate Wayland screencopy/virtual-input path. It is not the Lamco private hardware-encoding bridge.

### `remote=lamco`

The Lamco Release is pinned. Installation verifies its archive entry set, AArch64 ELF, interpreter, dynamic dependencies, metadata, SBOM, and licenses. The RootFS contains no preconfigured bridge token, RDP credentials, config, or TLS private key, and does not enable an unconfigured service.

1. Create `/data/local/tmp/anland-rdp` on the Android host and bind the directory:

   ```text
   /data/local/tmp/anland-rdp -> /run/anland-rdp
   ```

2. Verify the PID 1 mount after the container starts:

   ```bash
   findmnt --task 1 --mountpoint /run/anland-rdp --output TARGET,FSROOT
   ```

3. Select `remote` or `both` in the Android app and obtain its 32-character lowercase hexadecimal bridge token.
4. Configure interactively inside the container:

   ```bash
   sudo setup-lamco-anland-bridge
   ```

   The helper disables xtrace, reads the token/password without echo, rejects an all-zero token and weak passwords, and requires an RDP password of at least 12 characters that differs from the username. It atomically writes a mode-`0600` config owned by the dedicated `lamco-anland-bridge` no-login user and prepares mode-`0700` TLS/socket directories.

5. Inspect the service:

   ```bash
   systemctl status lamco-anland-bridge.service
   journalctl -u lamco-anland-bridge.service
   ```

6. Network endpoint:
   - **host/shared**: connect `mstsc` to `<phone WLAN IP>:3389`.
   - **isolated/NAT**: publish guest TCP 3389 and use the `<host address>:<host port>` actually reported by Droidspaces. It is the phone WLAN IP on port 3389 only when that exact host endpoint was explicitly published.
   - Restrict either endpoint to the intended PC or trusted subnet. Never forward the private UDS or expose compatibility/debug TCP port 33910.

`mstsc` shows a trust warning for the first self-signed certificate. Verify the device identity; production deployments may install a trusted certificate and matching private key.

## Verification status and unverified boundary

The build/static layer can validate:

- `bash -n` and ShellCheck for active Bash; YAML parsing and actionlint for the workflow; Dockerfile parsing.
- active/legacy scope, sole workflow, removed active options, action SHAs, permissions, modes, symlinks, secret signatures, and hard-coded URLs.
- output xz/tar integrity, filenames, variant count, SHA-256, metadata, and exact Release asset set; final archives also reject Android device-side assets, OpenH264/FFmpeg/x264 software-codec packages, and source-build residue.
- Lamco's AArch64 ELF, dependencies, metadata, SBOM/licenses, and refusal of software-H.264 dependencies.

Unless a corresponding device test is recorded, the following remain **unverified**: target-phone import/boot, real GPU behavior, Android Surface lifecycle, MediaCodec, `mstsc` interoperability, end-to-end clipboard, host/NAT UI behavior, power, temperature, and long-duration stability. A successful Actions build is not a substitute for device validation.

## Legacy KDE content

Old Debian/Ubuntu/Fedora/Arch-KDE/Artix/NixOS Dockerfiles, KDE scripts, and workflows are preserved under `legacy/` for historical reference and recovery. They are not active targets:

- GitHub does not discover or run them because they are outside `.github/workflows`.
- Active scripts no longer accept `build_KDE`, `build_KDE_plus`, `enable_anland_kde`, `build_wayland_packages`, `all-wayland`, or related legacy inputs.
- Legacy files may retain pins to the external upstream `Goldzxcbug/Droidspaces-rootfs-KDE-builder`. That is not this repository's self URL and does not indicate active support.

See [legacy/README.md](legacy/README.md).

## Acknowledgements

- [Droidspaces-OSS](https://github.com/ravindu644/Droidspaces-OSS/)
- [niri](https://github.com/niri-wm/niri), [ANiri](https://github.com/Celvra/ANiri), and [Noctalia](https://github.com/noctalia-dev/noctalia)
- [superturtlee/anland](https://github.com/superturtlee/anland)
- [lamco-admin/lamco-rdp-server](https://github.com/lamco-admin/lamco-rdp-server) and [IronRDP](https://github.com/Devolutions/IronRDP)
- [mesa-for-android-container](https://github.com/lfdevs/mesa-for-android-container)
- [Droidspaces-USB-Manager](https://github.com/Yizhou147/Droidspaces-USB-Manager)
