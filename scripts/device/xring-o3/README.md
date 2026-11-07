# XRING-O3 Mali stack (rootfs side)

This branch (`xring-o3-dual-stack`) replaces the Adreno/KGSL path with the
XRING-O3 + MaliBridge path used by Xiaomi Pad 9 Pro Max. The device runs two
coherent GL/Vulkan stacks side by side; the bundle and installer carry both, so
a fresh image reproduces the same per-app mapping. The build plumbing in this
branch targets Arch Linux ARM (`Arch.Dockerfile`). Other distribution
Dockerfiles are untouched, but their `install-mesa --1` calls are rejected by
this branch's Mali-only installer; do not build them from this branch.

| Item | Value |
|---|---|
| SoC / device profile | XRING-O3 |
| GPU | Mali-G2-Ultra-NX |
| Android | 17 |
| DRM node | `/dev/dri/card0` only; **no** `/dev/dri/renderD*` |
| Display transport | Anland Wayland, container socket `/run/display.sock` |
| Graphics transport | GL → Zink → MaliBridge → host server → Mali |
| Bridge socket | `/opt/mb-sock/mali.sock` (container view) |

## Consumer to stack mapping

The bundle carries two validated pairs, and each consumer gets exactly one of
them. A consumer never picks up one half of a pair from another consumer's
environment.

| Consumer | Entry point | Mesa tree | MaliBridge client | Environment source |
|---|---|---|---|---|
| niri session: niri, Xwayland, terminals, spawned apps | `start-desktop-session.sh` (niri branch) | `mesa/kopper` (kopper-retire) | `vkbridge/format` via `droidbridge-format.json` | `session-gpu-env.sh` reads `conf/zc-env.conf` |
| Chrome, DBX | `/usr/local/bin/zc-run` | `mesa/kopper` (kopper-retire) | `vkbridge/format` via `droidbridge-format.json` | `${ZC_PREFIX}/conf/zc-env.conf` |
| Noctalia panel | `/usr/local/bin/noctalia-dt` | `mesa` (dt-retire) | `vkbridge` via `droidbridge_icd.json` (hook2) | `conf/noctalia-env.conf`, overriding the session pair |
| No stack installed yet | any of the above | distribution Mesa | `droidbridge_icd.json` through `VK_DRIVER_FILES` | `/etc/environment`, written by `profile.sh --env` |

The device loads the session pair through `/usr/local/bin/gpu-app-bridge` as the
`desktop-session` ExecStart. This branch reproduces that in
`start-desktop-session.sh` for the niri backend only: it sources
`session-gpu-env.sh` before building the session command, so niri and everything
it spawns start on kopper + format. Other desktops keep the previous behaviour.

`session-gpu-env.sh` exports nothing when `conf/zc-env.conf` is missing or names
files that are not installed, so an image without a Mali stack boots on
`/etc/environment` as before. Noctalia is unaffected either way: `noctalia-dt`
replaces `LD_LIBRARY_PATH`, `VK_DRIVER_FILES` and `LD_PRELOAD` with its own pair.

The device runs the same pairs:

| Chain | Device Mesa directory | Device MaliBridge run | Extra device environment |
|---|---|---|---|
| zc-run | `/opt/mesa-kopper-retire-42194036783/candidate/usr/lib` | `mb-format-42268762436` | `__EGL_VENDOR_LIBRARY_FILENAMES=/opt/mesa-kopper-retire-42194036783/default-egl-vendor.json`, `VKBRIDGE_LOG_LEVEL=1` |
| Noctalia | `/opt/mesa-dt-retire-42369276110/candidate/usr/lib` | `mb-hook2-42378271764` | `LD_PRELOAD=/opt/mb-hook2-42378271764/shim/libvkb_wl_gone.so`, `VKBRIDGE_LOG_LEVEL=2`, `VKBRIDGE_WLHOOK_TRACE=1`, `DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus` |

The two MaliBridge builds differ on purpose: hook2 carries `format-capacity`,
`wsi-lifecycle`, `wl-surface-gone` and the hook2 teardown patch, while the
zc-run chain runs the `format-capacity` build alone.

`profile.sh --env` writes `/etc/environment` as the fallback for a rootfs that
has no Mali stack installed, or whose session script found nothing to load: no
`LD_PRELOAD`, no `LD_LIBRARY_PATH` pinning a Mesa tree. It keeps
`VK_DRIVER_FILES` on `droidbridge_icd.json` because that manifest exists in both
bundle layouts. Once a stack is installed, the session pair comes from
`conf/zc-env.conf` and this file only covers consumers outside the niri session.

## What lives in the rootfs

| Path | Purpose |
|---|---|
| `/opt/mali-stack/<version>` | Immutable Mali stack bundle payload |
| `/opt/mali-stack/current` | Atomic symlink to the active version |
| `/opt/mali-stack/current/conf/zc-env.conf` | Generated; zc-run reads `ZC_MESA_DIR`, `ZC_ICD`, `ZC_EGL_VENDOR_JSON`, bridge socket |
| `/opt/mali-stack/current/conf/noctalia-env.conf` | Generated; paths that `/usr/local/bin/noctalia-dt` exports |
| `/usr/local/bin/noctalia-dt` | Generated wrapper (dt-retire + hook2 + wl-gone shim); niri spawns it at startup |
| `/usr/local/lib/droidspaces/device/xring-o3/session-gpu-env.sh` | Sourced by `start-desktop-session.sh` for niri; exports the session kopper + format pair |
| `/usr/local/lib/droidspaces/device/xring-o3/` | profile, installer, bundle check, card0 and Anland helpers |
| `/etc/xring-o3/device-profile` | Marks the rootfs as `xring-o3`; `install-mesa` refuses otherwise |
| `/etc/environment` | Zink / MaliBridge / WebKit / card0 environment written by `niri.sh` |
| `/etc/systemd/system/xring-o3-card0.service` | Oneshot that creates `/dev/dri/card0` when the container has `CAP_MKNOD` |
| `/etc/systemd/system/xring-o3-anland-check.service` | Non-blocking boot check for `/run/display.sock` |
| `/opt/mb-sock/budget.conf` | Created from the bundle template only when absent; host server reads it |
| `/usr/local/bin/wait-for-mali-bridge` | Symlink to `wait-for-bridge.sh`; `desktop-session.service` runs it as `ExecStartPre` |
| `/usr/local/bin/{zc-run,zc-sync,mbctl,mb-tray}` | Compatibility symlinks into `current/bin` |

The bundle does **not** contain the MaliBridge server, the Anland daemon, the
vendor Mali driver, or any APK/Magisk ZIP. Those are Android-host assets.

## Bundle layout

The Mali stack is not published yet. `install-mali-stack.sh` hard-fails until a
bundle containing all of these exists:

```text
SHA256SUMS                                      # covers every regular file below
manifest.env                                    # optional: MALI_STACK_VERSION=<version>
mesa/candidate/usr/lib/libEGL_mesa.so.0         # dt-retire build
mesa/candidate/usr/lib/libgallium-<version>.so
mesa/candidate/usr/lib/dri/zink_dri.so
mesa/kopper/usr/lib/libEGL_mesa.so.0            # kopper-retire build
mesa/kopper/usr/lib/libgallium-<version>.so
mesa/kopper/usr/lib/dri/zink_dri.so
vkbridge/libvulkan_droidbridge.so               # hook2 client (Noctalia)
vkbridge/format/libvulkan_droidbridge.so        # format-capacity client (zc-run)
vkbridge/shim/libvkb_wl_gone.so                 # Noctalia LD_PRELOAD shim
share/vulkan/icd.d/droidbridge_icd.json         # -> ../../../vkbridge/libvulkan_droidbridge.so
share/vulkan/icd.d/droidbridge-format.json      # -> ../../../vkbridge/format/libvulkan_droidbridge.so
share/xring-o3/noctalia-dt                      # wrapper template
lib/libgbm.so.1                                 # complete 38-symbol libgbm shim
lib/libdrmfake.so                               # libdrm shim for card0/WebKit probes
lib/zc-run/zc-classify
bin/zc-run
bin/zc-sync
bin/mbctl
bin/mb-tray
share/applications/mb-tray.desktop
share/icons/hicolor/scalable/apps/mb-budget.svg # or 48/64/128/256 px PNG
etc/budget.conf                                 # template; server path is /opt/mb-sock/budget.conf
```

`SHA256SUMS` must use the plain `sha256sum` format: 64 hex characters, two
spaces, a relative path without whitespace. Absolute paths, `..`, symlinks, and
files not listed in `SHA256SUMS` are rejected. The installer also requires every
ELF in the bundle to be an AArch64 shared object.

`mesa/candidate/usr/lib`, `mesa/kopper/usr/lib`, `vkbridge/libvulkan_droidbridge.so`
and `share/vulkan/icd.d/droidbridge_icd.json` form layout v1 and stay required, so
an older bundle keeps installing. The kopper tree, the format client, the shim,
`droidbridge-format.json` and the wrapper template form layout v2 and are
all-or-nothing: a bundle carrying only part of that group is rejected, because
it would install a Mesa and MaliBridge pair that the device never ran.

Bundle notes:

- `dri/zink_dri.so` is the dereferenced `libdril_dri.so`; bundles contain no
  symlinks. `libEGL_mesa.so.0` is the dereferenced `libEGL_mesa.so.0.0.0`.
- `libEGL_mesa.so.0` and `dri/zink_dri.so` are byte-identical between the two
  Mesa builds; only `libgallium` differs. Each tree still keeps its own copy, so
  a consumer cannot reach into the other build.
- Both ICD manifests use a bundle-relative `library_path`, so the installed
  manifest keeps working after the bundle is moved to `/opt/mali-stack/<version>`.
- `mesa/kopper` has no `candidate/` level in the bundle. zc-run builds its Mesa
  search path as `$ZC_MESA_DIR/candidate/usr/lib`, so the installer creates
  `mesa/kopper/candidate/usr -> ../usr` inside the installed version directory.
  That link is install-time output, never bundle content.

## Installed tree (generated)

| Path | Content |
|---|---|
| `conf/zc-env.conf` | `ZC_MESA_DIR=…/mesa/kopper`, `ZC_ICD=…/droidbridge-format.json`, EGL vendor manifest, bridge socket, log level, DRM device |
| `conf/noctalia-env.conf` | dt-retire Mesa directory, hook2 ICD, shim path, `VKBRIDGE_LOG_LEVEL=2`, `VKBRIDGE_WLHOOK_TRACE=1`, DBus address, `XDG_RUNTIME_DIR`, noctalia binary |
| `mesa/default-egl-vendor.json` | EGL vendor manifest for `mesa/candidate/usr/lib/libEGL_mesa.so.0` |
| `mesa/kopper/default-egl-vendor.json` | EGL vendor manifest for `mesa/kopper/usr/lib/libEGL_mesa.so.0` |
| `mesa/kopper/candidate/usr` | Relative symlink to `../usr`, the compat view zc-run expects |
| `/usr/local/bin/noctalia-dt` | `share/xring-o3/noctalia-dt` with the stack-current and noctalia binary paths filled in |

A v1 bundle installs with `conf/zc-env.conf` on dt-retire + hook2 and no
`conf/noctalia-env.conf`; the installer logs `布局 v1` in that case.

## Install / switch

```sh
# Published archive
sudo MALI_STACK_VERSION=2026.11.08 \
     MALI_STACK_BUNDLE_URL=https://example.invalid/mali-stack-2026.11.08.tar.zst \
     MALI_STACK_BUNDLE_SHA256=<64 hex> \
     /usr/local/lib/droidspaces/device/xring-o3/install-mali-stack.sh

# Already extracted directory (for local bring-up)
sudo MALI_STACK_VERSION=local-test \
     MALI_STACK_BUNDLE_DIR=/path/to/extracted-bundle \
     /usr/local/lib/droidspaces/device/xring-o3/install-mali-stack.sh
```

The installer stages into `/opt/mali-stack/.staging.<version>.*`, verifies the
whole payload, renames it to `/opt/mali-stack/<version>`, then replaces
`/opt/mali-stack/current` via an atomic symlink rename. It never falls back to
Adreno Mesa, KGSL, or an empty directory. `--status` shows the active version,
the bundle layout (`v1` or `v2`) and whether the generated configs are present;
`--uninstall --version <version>` removes a version after dropping `current`.
Use `--force` only to replace an existing same-version directory.

## Check a bundle

`verify-mali-stack.sh` runs the installer's checks without installing anything.
It accepts an extracted directory or an archive, and exits non-zero on the first
failing group:

```sh
scripts/device/xring-o3/verify-mali-stack.sh /path/to/bundle
scripts/device/xring-o3/verify-mali-stack.sh mali-stack-2026.11.08-v2.tar.zst
# PASS layout=v2 files=23 checks=10
```

It verifies the archive sidecar (`<archive>.sha256`) when present, `SHA256SUMS`
format and per-file hashes, full file coverage, the absence of symlinks, the
layout paths, AArch64 ELF identity for every ELF in the bundle, both ICD
manifests resolving to their own client, and the wrapper template placeholders.
`.tar.zst` extraction uses the `zstd` CLI, or Python with the `zstandard` module
when the CLI is absent.

## Environment written by niri

```text
ANLAND_DRM_DEVICE=/dev/dri/card0
XWAYLAND_GBM_DEVICE=/dev/dri/card0
MESA_LOADER_DRIVER_OVERRIDE=zink
GALLIUM_DRIVER=zink
LIBGL_KOPPER_DISABLE=false
VK_DRIVER_FILES=/opt/mali-stack/current/share/vulkan/icd.d/droidbridge_icd.json
VKBRIDGE_SOCKET=/opt/mb-sock/mali.sock
WEBKIT_WEB_RENDER_DEVICE_FILE=/dev/dri/card0
WEBKIT_DMABUF_RENDERER_DISABLE_GBM=1
WEBKIT_DISABLE_DMABUF_RENDERER=0
GDK_BACKEND=wayland
ZC_PREFIX=/opt/mali-stack/current
ZC_CLASSIFY=/opt/mali-stack/current/lib/zc-run/zc-classify
```

These values are the fallback described under
[Consumer to stack mapping](#consumer-to-stack-mapping): they carry no
`LD_PRELOAD` and no `LD_LIBRARY_PATH`, and `VK_DRIVER_FILES` points at the
manifest that exists in both bundle layouts.

When a bundle is installed, `start-desktop-session.sh` sources
`session-gpu-env.sh`, which replaces the GL/Vulkan half of this environment for
the niri session with the kopper + format pair from `conf/zc-env.conf`, and
drops `LD_PRELOAD`, `VK_ICD_FILENAMES` and `LIBGL_ALWAYS_SOFTWARE` for that
session. `zc-run` and `noctalia-dt` then override the pair they need per app.

`FD_FORCE_KGSL`, `FD_DEV_FEATURES`, `TU_DEBUG`,
`MESA_VK_DEVICE_SELECT_FORCE_DEFAULT_DEVICE`, `LIBGL_ALWAYS_SOFTWARE`, and
`VK_ICD_FILENAMES` are removed from `/etc/environment`. `droidspaces-gpu.sh`
can switch GL to llvmpipe for diagnostics while retaining the MaliBridge Vulkan
path.

## card0

`card0.sh --install` installs a `sysinit.target` oneshot. At container boot it
creates `mknod /dev/dri/card0 c 226 0` when the node is missing and the container
has `CAP_MKNOD`. Failure is logged to `/run/xring-o3-card0.log` and does not block
the desktop. `card0.sh --check` reports the node for interactive diagnosis.
This is required because XRING-O3 exposes only a primary node; Chrome/WebKit and
`--render-node-override=/dev/dri/card0` cannot use `renderD*`.

## Anland: rootfs boundary

The rootfs expects a Unix socket at `/run/display.sock` (`ANLAND_SOCKET`).
`anland.sh --install` writes `/etc/xring-o3/anland.conf` and a non-blocking boot
check; it cannot create the socket. The host side must provide a Droidspaces bind
mount:

```text
/data/local/tmp/<container>-display.sock -> /run/display.sock
```

The Anland daemon creates a random socket path recorded in
`/data/local/Droidspaces/Pids/<container>.asock`. On the Android host, keep a
stable alias and refresh it after a full container stop/start, host reboot, or
Anland daemon restart:

```sh
ln -sfn "$(cat /data/local/Droidspaces/Pids/<container>.asock)" \
    /data/local/tmp/<container>-display.sock
```

Then bind-mount that stable alias to `/run/display.sock`. `droidspaces restart`
and an in-container reboot reuse the live daemon and do not need a refresh.

## Android host: MaliBridge server (not shipped)

Run the MaliBridge server on the Android host, as root, with its socket visible
inside the container as `/opt/mb-sock/mali.sock`. The server needs the vendor
Mali Vulkan driver via `/dev/mali0`; it must not be copied into the rootfs.

Recommended host memory budget for the 4 GB server setting is the same values
as the installed `budget.conf` template:

```sh
VKBRIDGE_MEM_BUDGET_TOTAL_MB=4096 \
VKBRIDGE_MEM_BUDGET_PID_MB=2048 \
VKBRIDGE_MEM_MIN_AVAIL_MB=2048 \
VKBRIDGE_MAP_LIMIT=60000 \
VKBRIDGE_MEM_STATS=1 \
VKBRIDGE_MEM_GUARD=1 \
/data/local/tmp/mbsrv/vkbridge-server \
    --socket /data/local/Droidspaces/Containers/<container>/rootfs/opt/mb-sock/mali.sock \
    --log /data/local/tmp/mbsrv/server.log
```

Environment wins over `budget.conf`; `mbctl set --persist` writes the file.
The server also creates `/opt/mb-sock/control.sock`; `mbctl`/`mb-tray` use it.

### Start order

Start the host server first, then the desktop. `desktop-session.service` runs
`/usr/local/bin/wait-for-mali-bridge 30` as `ExecStartPre`, which waits for
`mali.sock` **and** `control.sock` to be Unix sockets before niri starts. The
gate warns and returns 0 after the timeout, so a desktop without the GPU still
boots; it simply has no hardware renderer.

Readiness covers both sockets: `mali.sock` carries Vulkan/GL traffic and
`control.sock` is the control channel `mbctl` and `mb-tray` use. A server that
has created only `mali.sock` is not ready.

A running desktop does not survive the host server going away. Stopping it while
the desktop runs, for example with the host-side `stop-bridge.sh`, makes niri
fail with `VK_ERROR_DEVICE_LOST` and the session dies with it. After the server
is back and both sockets exist, restart the desktop:

```sh
systemctl restart desktop-session
```

An automatic unit restart that lands before the server listens starts niri
without a renderer, and Noctalia never spawns; only a restart after both sockets
exist restores the GPU session.

## Quick verification

```sh
profile=/usr/local/lib/droidspaces/device/xring-o3/profile.sh
"$profile" --check
"$profile" --show
/usr/local/lib/droidspaces/device/xring-o3/install-mali-stack.sh --status
/usr/local/lib/droidspaces/device/xring-o3/card0.sh --check
/usr/local/lib/droidspaces/device/xring-o3/anland.sh --check
/usr/local/bin/wait-for-mali-bridge 0      # one-shot readiness probe, always exits 0
sh -c '. /usr/local/lib/droidspaces/device/xring-o3/session-gpu-env.sh; env | grep -E "^(LD_LIBRARY_PATH|VK_DRIVER_FILES)="'
zc-run --print-env -- google-chrome       # INJECT must include global-env
vulkaninfo --summary
eglinfo -B 2>/dev/null | head
```

`--status` reports `layout=v2` when the bundle carries both stacks, plus whether
the zc-run manifest, the Noctalia manifest and `/usr/local/bin/noctalia-dt`
exist. `verify-mali-stack.sh` takes the bundle directory or archive, not the
installed tree: the installed tree carries generated configs and the kopper
compat link, which the strict bundle rules reject.

`zc-run --print-env` reports `INJECT=global-env` when zc-run applied
`conf/zc-env.conf` itself instead of inheriting a prepared session environment;
`INJECT=env-preset` means the session already carried the same kopper pair.

`vulkaninfo` must list the MaliBridge ICD; `eglinfo` must report Zink when the
Mali stack is active, not llvmpipe. Use `droidspaces-gpu.sh` to switch GL to
llvmpipe only when isolating a driver problem.
