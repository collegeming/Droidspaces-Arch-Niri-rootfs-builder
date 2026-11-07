# XRING-O3 Mali stack (rootfs side)

This branch (`xring-o3-mali-device`) replaces the Adreno/KGSL path with the
XRING-O3 + MaliBridge path used by Xiaomi Pad 9 Pro Max. The build plumbing in
this branch targets Arch Linux ARM (`Arch.Dockerfile`). Other distribution
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

## What lives in the rootfs

| Path | Purpose |
|---|---|
| `/opt/mali-stack/<version>` | Immutable Mali stack bundle payload |
| `/opt/mali-stack/current` | Atomic symlink to the active version |
| `/usr/local/lib/droidspaces/device/xring-o3/` | profile, installer, card0 and Anland helpers |
| `/etc/xring-o3/device-profile` | Marks the rootfs as `xring-o3`; `install-mesa` refuses otherwise |
| `/etc/environment` | Zink / MaliBridge / WebKit / card0 environment written by `niri.sh` |
| `/etc/systemd/system/xring-o3-card0.service` | Oneshot that creates `/dev/dri/card0` when the container has `CAP_MKNOD` |
| `/etc/systemd/system/xring-o3-anland-check.service` | Non-blocking boot check for `/run/display.sock` |
| `/opt/mb-sock/budget.conf` | Created from the bundle template only when absent; host server reads it |
| `/usr/local/bin/{zc-run,zc-sync,mbctl,mb-tray}` | Compatibility symlinks into `current/bin` |

The bundle does **not** contain the MaliBridge server, the Anland daemon, the
vendor Mali driver, or any APK/Magisk ZIP. Those are Android-host assets.

## Bundle layout

The Mali stack is not published yet. `install-mali-stack.sh` hard-fails until a
bundle containing all of these exists:

```text
SHA256SUMS                                      # covers every regular file below
mesa/candidate/usr/lib/libEGL_mesa.so.0         # Mesa dt-retire, Arch ARM build
mesa/candidate/usr/lib/dri/zink_dri.so
vkbridge/libvulkan_droidbridge.so               # glibc MaliBridge client ICD, aarch64
share/vulkan/icd.d/droidbridge_icd.json         # references libvulkan_droidbridge.so
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
manifest.env                                    # optional: MALI_STACK_VERSION=<version>
```

`SHA256SUMS` must use the plain `sha256sum` format: 64 hex characters, two
spaces, a relative path without whitespace. Absolute paths, `..`, symlinks, and
files not listed in `SHA256SUMS` are rejected. The installer also requires the
ICD, libgbm shim, libdrmfake, and Mesa libraries to be AArch64 ELF shared objects.

`mesa/candidate/usr/lib` is the layout expected by `zc-run`. A flat `mesa/usr/lib`
tree is not accepted; repack it as `mesa/candidate/usr/lib`.

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
Adreno Mesa, KGSL, or an empty directory. `--status` shows the active version;
`--uninstall --version <version>` removes a version after dropping `current`.
Use `--force` only to replace an existing same-version directory.

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

## Quick verification

```sh
profile=/usr/local/lib/droidspaces/device/xring-o3/profile.sh
"$profile" --check
/usr/local/lib/droidspaces/device/xring-o3/install-mali-stack.sh --status
/usr/local/lib/droidspaces/device/xring-o3/card0.sh --check
/usr/local/lib/droidspaces/device/xring-o3/anland.sh --check
vulkaninfo --summary
eglinfo -B 2>/dev/null | head
```

`vulkaninfo` must list the MaliBridge ICD; `eglinfo` must report Zink when the
Mali stack is active, not llvmpipe. Use `droidspaces-gpu.sh` to switch GL to
llvmpipe only when isolating a driver problem.
