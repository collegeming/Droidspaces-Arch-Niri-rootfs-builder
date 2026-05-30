[中文](README.md) | English

---

🚀 Droidspaces RootFS Auto-Build

This project aims to achieve fully automated cloud building via GitHub Actions, providing ready‑to‑use, highly customized RootFS for Droidspaces.

When triggering the workflow, you can freely configure the target system version, desktop environment scale, and various enhancement feature switches through a visual menu, easily crafting your own tailored mobile Linux container environment.

✨ Core Features

· Multi‑distribution support – Quickly build RootFS for Debian‑13, Ubuntu‑24, Ubuntu‑25 and Arch Linux.
· Customizable KDE Desktop – Multiple KDE desktop scales. Combine with the on script to launch the graphical interface instantly:
  · conc – Lightweight edition
  · min – Minimal build
  · none – Command‑line only (no desktop)
· Flexible PulseAudio forwarding – Supports tcp (network forwarding) and socket (socket) modes.
    The socket mode is strongly recommended: it relies on local file transfer for higher efficiency and lower latency.
· Native Chinese localization – One‑click Chinese language environment setup with automatic timezone calibration, completely solving Chinese display and configuration headaches inside the container.
· Snapdragon GPU hardware acceleration – Built‑in Mesa driver enhancements for Qualcomm Snapdragon GPUs, delivering a smooth hardware‑accelerated desktop experience. [Driver upstream: lfdevs/mesa-for-android-container](https://github.com/lfdevs/mesa-for-android-container)
· Modular one‑click integration – Flexibly enable the following features via parameters:
  · Input method – Native Fcitx5 support.
  · TMOE deployment – Integrated TMOE environment. Simply type tmoe in the terminal to automatically install dependencies and run. [Project upstream: TMOE](https://github.com/2moe/tmoe)
  · Cross‑architecture support – Enable binfmt for cross‑architecture execution (Note: Arch Linux does not currently support this QEMU approach).
  · Container enhancements – Deep optimization for container recognition of underlying hardware and network environment.
  · Productivity tools – Optional integration of development toolchains, compression toolkits, and Docker container engine.

🔥 Quick Start

1. Fork this project to your GitHub repository.
2. Go to the Actions page, select the "Build and Release Droidspaces RootFS" workflow on the left.
3. Click Run workflow, choose your desired configuration options in the pop‑up visual menu, then run.
4. Wait about 10 minutes for the build to finish. Head to the Releases page, download the generated RootFS tarball, import it into Droidspaces, and you are ready to go.

⚠️ Pitfall Guide & Important Notes

🖥️ System & Desktop Environment Configuration

· General requirement – All users using this RootFS with a KDE desktop must enable GPU access permission in Droidspaces and have Termux:X11 properly configured.
· Ubuntu / Debian derivatives – Before launching the KDE desktop, it is strongly recommended to enable noseccomp in Droidspaces’ privileged mode configuration. Otherwise, some operations inside the container may suffer from lag of up to 10 seconds.
· Fedora derivatives – You must enable hardware access permission in Droidspaces! Failure to do so will cause screen flickering and eventual desktop crash (currently requires manual removal of conflicting packages; no perfect replacement yet).
· Arch Linux – The kernel version must be 5.10 or higher.

🛠️ DRI3 Error Workarounds

If you encounter DRI3‑related errors when starting the graphical environment, an SELinux permission block is the cause. Choose one of the following methods to fix it:

Method 1: Targeted SELinux policy patch (recommended, using KernelSU as example)
Run in the host (Android) root terminal:

```bash
/data/adb/ksud sepolicy patch "allow untrusted_app_27 droidspacesd fd use"
```

Method 2: Make the entire untrusted_app_27 domain permissive (more aggressive)
Execute the following commands in the host root terminal. Note: This reduces security. It is recommended to run the second command first to check which apps belong to this domain and confirm no risk before applying the policy patch.

```bash
# Check which apps have targetSdk 26–28:
/system/bin/dumpsys package packages | /system/bin/awk '/^ *Package \[/ {pkg=$2} /targetSdk=(26|27|28)$/ {print "App: " pkg " -> " $1}'

# After confirming, apply the permissive policy:
/data/adb/ksud sepolicy patch "permissive untrusted_app_27"
```

Method 3: Permissive Kernel
Directly switch the device’s SELinux to Permissive mode.

Method 4: Modify the Droidspaces module configuration file
Edit the file /data/adb/modules/droidspaces/etc/droidspaces.te:

```text
# Find the section:
# Termux related
# Only uncommet line below if you are encounter any problems about dri3
# allow untrusted_app_27 droidspacesd fd use

# Uncomment the last line to:
allow untrusted_app_27 droidspacesd fd use
```

Save the file and reboot the device for the changes to take effect.