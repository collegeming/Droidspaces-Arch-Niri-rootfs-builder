
English | [中文](README.md)

---
# 🚀 Droidspaces RootFS Automated Build

This project is designed to provide a fully automated cloud build workflow through GitHub Actions, delivering an out-of-the-box, highly customizable RootFS for Droidspaces.

When triggering the workflow, you can freely configure the target system version, desktop environment size, and various enhancement toggles through a visual menu, making it easy to build a personalized Linux container environment for mobile devices.

## ✨ Features

- **Multi-distro support**: Quickly build RootFS for `Debian-13`, `Ubuntu-24`, `Ubuntu-25`，`Fedora-43`, and `Arch Linux`.
- **On-demand KDE desktop customization**: Multiple KDE desktop scales are available, and you can launch the graphical environment quickly with the `on` script:
  - `conc`: compact edition
  - `min`: minimal build
  - `none`: command-line only (desktop environment not installed)

- **Flexible audio forwarding (PulseAudio)**:
  - Supports both `tcp` (network forwarding) and `socket` (Unix socket) modes.
  - *`socket` mode is strongly recommended*: it relies on local file transfer, offering better performance and lower latency.

- **Native Chinese localization**: Enable Chinese language support with one click and automatically configure the timezone, removing the hassle of manual localization inside the container.
- **Snapdragon GPU hardware acceleration**: Includes enhanced Mesa driver support for Qualcomm Snapdragon GPUs, providing smooth hardware-accelerated desktop performance.  
  Upstream driver source: [lfdevs/mesa-for-android-container](https://github.com/lfdevs/mesa-for-android-container)
- **Modular one-click integration**: The following features can be enabled flexibly through parameters:
  - **Input method**: Native Fcitx5 support.
  - **TMOE deployment**: Includes the TMOE environment. Type `tmoe` in the terminal to automatically install dependencies and launch it.  
    Upstream project: [TMOE](https://github.com/2moe/tmoe)
  - **Cross-architecture support**: Enable `binfmt` for running programs across architectures.  
    Note: Arch Linux does not support this QEMU-based approach.
  - **Container enhancements**: Deep optimization for container recognition of underlying hardware and network environments.
  - **Productivity tools**: Optional integration of development toolchains, compression utilities, and the Docker engine.
- **Account Credentials**: For all built `Rootfs`, the username defaults to: `Gold` (can be customized in the workflow); the password is: `1234`
## 🔥 Quick Start

1. **Fork** this project to your GitHub repository.
2. Go to the **Actions** page and select the workflow **"Build and Release Droidspaces RootFS"** from the left panel.
3. Click **Run workflow**, choose the desired configuration options in the popup menu, and start the workflow.
4. Wait about 10 minutes for the build to finish, then go to the **Releases** page to download the generated RootFS archive and import it into Droidspaces.

## ⚠️ Tips and Notes

### 🖥️ System and Desktop Environment Configuration

- **General requirement**: All users who use this project’s RootFS and enable the KDE desktop environment **must** enable **GPU access** in Droidspaces and configure Termux:X11 properly.
- **Ubuntu / Debian series**: Before enabling the KDE desktop environment, it is strongly recommended to enable **`noseccomp`** in Droidspaces privileged mode settings. Otherwise, some operations inside the container may experience up to 10 seconds of lag.
- **Fedora series**: Some devices **must** enable **hardware access** in Droidspaces! Otherwise, the desktop may flicker and eventually crash.  
  At present, conflicting packages still need to be removed manually; there is no perfect replacement solution yet, so you will need to test on your own device.
- **Arch**: The kernel version must be 5.10 or higher.

### 🛠️ DRI3 Error Fix

If you encounter `DRI3`-related errors when starting the graphical environment, it usually means SELinux permissions are being blocked. Choose **any** of the following methods to fix it based on your situation:

**Method 1: Patch SELinux policy precisely (recommended, using KernelSU as an example)**  
Run the following in the host Android root shell:

```bash
/data/adb/ksud sepolicy patch "allow untrusted_app_27 droidspacesd fd use"
```

**Method 2: Allow the entire `untrusted_app_27` domain (more aggressive)**
Run the following commands in the host root shell.
*Note: this method reduces security. It is recommended to first run the second command below to identify which apps belong to this domain, and only apply the policy patch after confirming there is no risk.*

```bash
# Find apps with targetSdk 26-28:
/system/bin/dumpsys package packages | /system/bin/awk '/^ *Package \[/ {pkg=$2} /targetSdk=(26|27|28)$/ {print "App: " pkg " -> " $1}'

# Allow it after confirming:
 /data/adb/ksud sepolicy patch "permissive untrusted_app_27"
```

**Method 3: Permissive Kernel**
Switch the device SELinux state to Permissive mode directly.

**Method 4: Modify the Droidspaces module configuration file**
Edit the file `/data/adb/modules/droidspaces/etc/droidspaces.te` on the device:

```text
# Find this section:
# Termux related
# Only uncomment line below if you are encountering any problems about dri3
# allow untrusted_app_27 droidspacesd fd use

# Uncomment the last line so it becomes:
allow untrusted_app_27 droidspacesd fd use

Save the file and reboot the device for the change to take effect.
```

## Acknowledgements

* **[Droidspaces-OOS](https://github.com/ravindu644/Droidspaces-OSS/)** - the foundation that made this project possible.
* **[mesa-for-android-container](https://github.com/lfdevs/mesa-for-android-container)** - Snapdragon GPU driver support used for building RootFS.
* **[TMOE](https://github.com/2moe/tmoe)** - a very convenient management tool inside the container.


