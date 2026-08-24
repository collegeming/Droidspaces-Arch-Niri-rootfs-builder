# Dockerfile (NixOS 25.05 - aarch64, systemd 257 旧内核兼容)
# 说明：
#   - NixOS 25.05 固定搭载 systemd 257，是最后一个支持 4.19 等
#     旧 Android 内核的大版本，因此天然满足“4.19Core”定位，
#     无需 scripts/systemd257.sh 编译降级（该脚本不适用 NixOS）。
#   - 渠道 https://channels.nixos.org/nixos-25.05 已 EOL 冻结，
#     构建结果可复现，但不再接收安全更新。
#   - 构建方式：在 nixos/nix 容器内声明式生成 configuration.nix，
#     用 make-system-tarball 产出 rootfs tarball 后解压到 /target 导出。
#   - 限制：
#       * Wayland/Anland patched KWin 暂不支持 NixOS（仅 X11 / Termux:X11 路径）；
#       * plasma-mobile 暂不支持 NixOS；
#       * KDE 桌面规模仅支持 min / conc / none；
#       * NixOS 使用 nixpkgs 自带 Mesa（无 KGSL 后端），GPU 为软件渲染回退，
#         高通 KGSL 硬件加速暂不可用（与 mesa-for-android-container 的
#         arch/deb/fedora 定制包不兼容）；
#       * Droidspaces USB Manager 暂未集成（其余发行版均已内置）；
#       * TMOE 面向 apt/dnf/pacman 体系，NixOS 不集成。

ARG TARGETPLATFORM
ARG NIX_IMAGE=nixos/nix:2.28.3

FROM ${NIX_IMAGE} AS customizer

ARG BUILD_KDE
ARG BUILD_KDE_plus
ARG PulseAudio
ARG ENABLE_zh_tz_ARG
ARG ENABLE_binfmt_ARG
ARG ENABLE_yj_ARG
ARG ENABLE_mesa_ARG
ARG ENABLE_anland_kde_ARG
ARG ENABLE_8gen2_wayland_ARG
ARG ENABLE_kfgj_ARG
ARG ENABLE_zip_ARG
ARG ENABLE_docker_ARG
ARG ENABLE_srf_ARG
ARG ENABLE_tmoe_ARG
ARG ENABLE_systemd257_ARG
ARG ENABLE_nosnap_ARG
ARG USERNAME
ARG ANLAND_KDE_RELEASE_REPOSITORY=Goldzxcbug/Droidspaces-rootfs-KDE-builder
ARG ANLAND_KDE_RELEASE_TAG
ARG ANLAND_KDE_PACKAGE_REVISION=unknown

# NixOS 限制检查与说明
RUN if [ "$ENABLE_anland_kde_ARG" = "true" ]; then \
        echo "错误: NixOS-KDE 当前不支持 Wayland/Anland（请选择 Debian-13/Ubuntu-26/Fedora-43/Fedora-44/Arch）" >&2; \
        exit 1; \
    fi && \
    if [ "$BUILD_KDE" = "mobile" ]; then \
        echo "错误: NixOS-KDE 当前不支持 mobile 模式" >&2; \
        exit 1; \
    fi && \
    if [ "$ENABLE_tmoe_ARG" = "true" ]; then \
        echo "--> [跳过] TMOE 面向 apt/dnf/pacman 体系，NixOS 不集成"; \
    fi && \
    if [ "$ENABLE_systemd257_ARG" = "true" ]; then \
        echo "--> [跳过] NixOS 25.05 固定 systemd 257，无需降级构建"; \
    fi && \
    if [ "$ENABLE_mesa_ARG" = "true" ]; then \
        echo "--> [提示] NixOS 使用 nixpkgs 自带 Mesa（无 KGSL 后端），GPU 为软件渲染回退"; \
    fi

# 固定 nixos-25.05 渠道（systemd 257 / Plasma 6.3）
RUN nix-channel --add https://channels.nixos.org/nixos-25.05 nixpkgs && \
    nix-channel --update

# 解压工具（镜像内不含 xz/gnutar）
RUN nix-env -f '<nixpkgs>' -iA xz gnutar

# 生成 configuration.nix。
# 构建开关通过环境变量传入，Nix 端用 builtins.getEnv 读取
# （Docker ARG 在 RUN 阶段自动成为环境变量）。
RUN cat <<'EOF' > /tmp/droidspaces-configuration.nix
{ config, pkgs, lib, ... }:

let
  envBool = name: builtins.getEnv name == "true";
  envStr = name: default:
    let v = builtins.getEnv name; in if v != "" then v else default;

  username = envStr "USERNAME" "Gold";
  kdeMode = envStr "BUILD_KDE" "min";
  kdePlus = envBool "ENABLE_KDE_PLUS";
  zh = envBool "ENABLE_zh_tz_ARG";
  yj = envBool "ENABLE_yj_ARG";
  srf = envBool "ENABLE_srf_ARG";
  zipEnabled = envBool "ENABLE_zip_ARG";
  kfgj = envBool "ENABLE_kfgj_ARG";
  dockerEnabled = envBool "ENABLE_docker_ARG";
  binfmtEnabled = envBool "ENABLE_binfmt_ARG";
  mesaEnabled = envBool "ENABLE_mesa_ARG";
  gen2fix = envBool "ENABLE_8gen2_wayland_ARG";
  pulseMode = envStr "PulseAudio" "socket";

  withKde = kdeMode == "min" || kdeMode == "conc";
in
{
  imports = [ ];

  ############################################
  # 容器与旧内核（4.19）兼容
  ############################################
  boot.isContainer = true;
  # /init 必须是 stage2 激活脚本（activate 后再 exec systemd），
  # 不能是 systemd 二进制（那是 initrd-systemd 路径）。
  boot.initrd.systemd.enable = false;

  # 容器内后续 nixos-rebuild / nix-env 使用
  nix.settings.sandbox = false;
  nix.extraOptions = "experimental-features = nix-command flakes";

  # 首次启动注册 store 数据库并建立 system profile
  boot.postBootCommands = ''
    if [ -f /nix-path-registration ]; then
      ${config.nix.package.out}/bin/nix-store --load-db < /nix-path-registration &&
      rm /nix-path-registration
    fi
    ${config.nix.package.out}/bin/nix-env -p /nix/var/nix/profiles/system --set /run/current-system
  '';

  ############################################
  # 语言与时区
  ############################################
  i18n.defaultLocale = if zh then "zh_CN.UTF-8" else "en_US.UTF-8";
  time.timeZone = if zh then "Asia/Shanghai" else "UTC";
  fonts.packages = with pkgs;
    lib.optionals zh [ noto-fonts noto-fonts-cjk-sans noto-fonts-color-emoji ]
    ++ lib.optionals (!zh) [ noto-fonts noto-fonts-color-emoji ];

  ############################################
  # 网络（enable_yj：容器网络与硬件识别）
  ############################################
  networking.hostName = "droidspaces";
  networking.firewall.enable = false;
  networking.useDHCP = lib.mkDefault false;
  networking.useNetworkd = yj;
  systemd.network = lib.mkMerge [
    (lib.mkIf yj {
      enable = true;
      networks."10-eth-dhcp" = {
        matchConfig.Name = "eth*";
        networkConfig = {
          DHCP = "yes";
          IPv6AcceptRA = true;
        };
        dhcpV4Config = {
          UseDNS = true;
          UseDomains = true;
          RouteMetric = 100;
        };
      };
    })
    { wait-online.enable = false; }
  ];
  services.resolved = lib.mkIf yj { enable = true; };
  # 容器默认复制宿主 resolv.conf，与 systemd-resolved 断言冲突；
  # 启用 resolved（enable_yj）时改为自管，否则保留宿主复制行为
  networking.useHostResolvConf = !yj;
  systemd.services.systemd-networkd-wait-online.enable = false;

  ############################################
  # SSH
  ############################################
  services.openssh = {
    enable = true;
    startWhenNeeded = false;
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = true;
    };
  };

  ############################################
  # 用户与权限（Android 环境适配）
  ############################################
  users.mutableUsers = true;
  users.users.root.initialPassword = "1234";
  users.users."${username}" = {
    isNormalUser = true;
    uid = 1000;
    initialPassword = "1234";
    extraGroups =
      [ "wheel" "video" "input" "tty" "droidspaces-gpu" "aid_inet" "aid_net_raw" ]
      ++ lib.optionals dockerEnabled [ "docker" ];
  };
  users.groups = {
    aid_inet.gid = 3003;
    aid_net_raw.gid = 3004;
    aid_net_admin.gid = 3005;
    droidspaces-gpu.gid = 786;
  };
  security.sudo = {
    enable = true;
    wheelNeedsPassword = true;
  };

  ############################################
  # KDE Plasma（min / conc / none）
  ############################################
  services.xserver.enable = withKde;
  services.displayManager.sddm.enable = false;
  services.desktopManager.plasma6.enable = withKde;
  hardware.graphics.enable = mesaEnabled;

  environment.systemPackages = with pkgs; [
    fastfetch
    git
    nano
    jq
    dialog
    curl
    wget
    bash-completion
    iproute2
    iptables
    net-tools
    dnsutils
  ]
  ++ lib.optionals withKde (lib.optionals (kdeMode == "min") [
    kdePackages.konsole
    kdePackages.dolphin
    kdePackages.kate
    kdePackages.kscreen
  ])
  ++ lib.optionals (kdeMode == "conc") ([
    kdePackages.konsole
    kdePackages.dolphin
    kdePackages.kate
    kdePackages.kscreen
    kdePackages.kinfocenter
    kdePackages.systemsettings
    kdePackages.kfind
    kdePackages.filelight
    kdePackages.kio-extras
    kdePackages.ffmpegthumbs
    kdePackages.kdegraphics-thumbnailers
    kdePackages.plasma-systemmonitor
    firefox
    mesa-utils
    vulkan-tools
  ])
  ++ lib.optionals zipEnabled [ zip unzip p7zip bzip2 glib ]
  ++ lib.optionals kfgj [ gcc gnumake cmake clang llvm python3 python3Packages.pip ]
  ++ lib.optionals dockerEnabled [ docker-client docker-compose ];

  virtualisation.docker.enable = dockerEnabled;

  ############################################
  # 输入法 fcitx5（ENABLE_srf）
  ############################################
  i18n.inputMethod = lib.mkIf srf {
    enable = true;
    type = "fcitx5";
    fcitx5.addons =
      lib.optionals zh [ pkgs.qt6Packages.fcitx5-chinese-addons ]
      ++ [ pkgs.qt6Packages.fcitx5-configtool ];
  };

  ############################################
  # 跨架构 binfmt（ENABLE_binfmt）
  # 说明：注册是否生效取决于宿主 Android 内核是否启用
  # CONFIG_BINFMT_MISC；不支持时服务优雅跳过。
  ############################################
  boot.binfmt.emulatedSystems =
    lib.optionals binfmtEnabled [ "x86_64-linux" "i686-linux" "riscv64-linux" ];
  systemd.services.droidspaces-binfmt-mount = lib.mkIf binfmtEnabled {
    description = "Mount binfmt_misc for cross-architecture support";
    before = [ "systemd-binfmt.service" ];
    wantedBy = [ "sysinit.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    script = ''
      if ! grep -q binfmt_misc /proc/filesystems 2>/dev/null; then
        echo "droidspaces-binfmt: binfmt_misc not supported by kernel, skipping"
        exit 0
      fi
      if ! grep -q /proc/sys/fs/binfmt_misc /proc/mounts 2>/dev/null; then
        mount -t binfmt_misc binfmt_misc /proc/sys/fs/binfmt_misc
      fi
    '';
  };

  ############################################
  # 桌面会话环境变量（等价 /etc/environment）
  ############################################
  environment.sessionVariables =
    {
      XCURSOR_SIZE = "48";
    }
    // (if withKde then { DISPLAY = ":5"; } else { })
    // (lib.optionalAttrs (pulseMode == "socket") { PULSE_SERVER = "unix:/tmp/.pulse-socket"; })
    // (lib.optionalAttrs (pulseMode == "tcp") { PULSE_SERVER = "tcp:127.0.0.1:4713"; })
    // (lib.optionalAttrs srf { GLFW_IM_MODULE = "fcitx"; })
    // (lib.optionalAttrs gen2fix { FD_DEV_FEATURES = "enable_tp_ubwc_flag_hint=1"; });

  ############################################
  # KDE 自启动（等价 plasma-x11.service）
  ############################################
  systemd.services.plasma-x11 = lib.mkIf (withKde && kdePlus) {
    description = "Start Plasma X11";
    after = [ "network.target" ];
    unitConfig = {
      StartLimitIntervalSec = 60;
      StartLimitBurst = 5;
    };
    serviceConfig = {
      Type = "simple";
      User = "${username}";
      PAMName = "login";
      Restart = "on-failure";
      RestartSec = "2s";
    };
    environment = {
      DISPLAY = ":5";
      XCURSOR_SIZE = "48";
    }
    // (lib.optionalAttrs (pulseMode == "socket") { PULSE_SERVER = "unix:/tmp/.pulse-socket"; })
    // (lib.optionalAttrs (pulseMode == "tcp") { PULSE_SERVER = "tcp:127.0.0.1:4713"; });
    script = ''
      export PATH=/run/current-system/sw/bin:$PATH
      exec startplasma-x11
    '';
    wantedBy = [ "multi-user.target" ];
  };

  ############################################
  # 日志与电源键（Android 容器适配）
  ############################################
  services.journald.extraConfig = ''
    Storage=volatile
    SystemMaxUse=200M
    RuntimeMaxUse=200M
    MaxRetentionSec=7day
    ReadKMsg=no
    Audit=no
  '';
  services.logind.settings.Login = {
    HandlePowerKey = "ignore";
    HandleSuspendKey = "ignore";
    HandleHibernateKey = "ignore";
    HandlePowerKeyLongPress = "ignore";
    HandlePowerKeyLongPressHibernate = "ignore";
  };

  ############################################
  # 精简体积
  ############################################
  documentation.enable = false;
  system.stateVersion = "25.05";

  ############################################
  # Droidspaces rootfs tarball
  ############################################
  system.build.droidspacesRootfs = pkgs.callPackage (pkgs.path + "/nixos/lib/make-system-tarball.nix") {
    storeContents = [
      { object = config.system.build.toplevel; symlink = "none"; }
      { object = config.system.build.toplevel + "/init"; symlink = "/sbin/init"; }
    ];
    contents = [
      { source = config.system.build.toplevel + "/."; target = "./"; }
    ];
    extraArgs = "--owner=0";
    extraCommands = pkgs.writeScript "extra-commands.sh" ''
      rm etc
      mkdir -p proc sys dev etc home root tmp var/tmp run mnt srv opt
      chmod 1777 tmp var/tmp
    '';
  };
}
EOF

# 评估并构建 rootfs tarball（sandbox=false：Docker 构建器内无特权）
# ENABLE_KDE_PLUS 从 BUILD_KDE_plus 转换（命名规避 Nix 无关的环境变量风格差异）
RUN export ENABLE_KDE_PLUS="$BUILD_KDE_plus" && \
    nix-build '<nixpkgs/nixos>' \
      -I nixos-config=/tmp/droidspaces-configuration.nix \
      -A config.system.build.droidspacesRootfs \
      --option sandbox false \
      --max-jobs 4 && \
    mkdir -p /target && \
    tar -xJf "$(readlink -f result)/tarball/"nixos-system-*.tar.xz -C /target && \
    ls -la /target && \
    test -x /target/init && test -e /target/sbin/init && \
    echo "--> NixOS rootfs 已解压到 /target"

# 阶段 2：仅导出 /target（即 NixOS rootfs，不含构建器的 nixos/nix 容器本体）
FROM scratch AS export
COPY --from=customizer /target/ /
