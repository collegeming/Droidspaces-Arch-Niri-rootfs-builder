#!/bin/bash

# 为旧 Android 内核构建 systemd 257 兼容运行时。
# 脚本只处理当前 systemd 主版本高于 257 的系统；257 及更低版本会直接跳过。
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
# 某些构建主机将 cc 包装为只读 ccache；Docker 内直接使用编译器更可靠。
export CCACHE_DISABLE=1

readonly SYSTEMD257_TARGET_MAJOR=257
readonly SYSTEMD257_REPO="${SYSTEMD257_REPO:-https://github.com/systemd/systemd.git}"
readonly SYSTEMD257_REF="${SYSTEMD257_REF:-v257-stable}"

WORK_DIR=""
PACKAGE_MANAGER=""
CURRENT_VERSION_LINE=""
SOURCE_COMMIT=""
SOURCE_VERSION=""

log() {
  printf '[systemd257] %s\n' "$*"
}

die() {
  printf '[systemd257] error: %s\n' "$*" >&2
  exit 1
}

cleanup() {
  if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
    rm -rf -- "$WORK_DIR"
  fi
}
trap cleanup EXIT

# 安装依赖、覆盖系统文件和设置包管理器锁定都需要 root 权限。
if [ "$EUID" -ne 0 ]; then
  die "请用 root 运行：sudo bash systemd257.sh"
fi

# systemctl --version 不依赖正在运行的 PID 1，适合在 Docker 构建阶段探测版本。
systemd_version_line() {
  local candidate line

  if command -v systemctl >/dev/null 2>&1; then
    line="$(systemctl --version 2>/dev/null | sed -n '1p')"
    if [ -n "$line" ]; then
      printf '%s\n' "$line"
      return 0
    fi
  fi

  for candidate in /usr/lib/systemd/systemd /lib/systemd/systemd; do
    if [ -x "$candidate" ]; then
      line="$($candidate --version 2>/dev/null | sed -n '1p')"
      if [ -n "$line" ]; then
        printf '%s\n' "$line"
        return 0
      fi
    fi
  done

  return 1
}

systemd_major_from_line() {
  printf '%s\n' "$1" | awk '
    NR == 1 {
      for (i = 1; i <= NF; i++) {
        if ($i ~ /^[0-9]+/) {
          sub(/[^0-9].*$/, "", $i)
          print $i
          exit
        }
      }
    }
  '
}

CURRENT_VERSION_LINE="$(systemd_version_line || true)"
[ -n "$CURRENT_VERSION_LINE" ] || die "无法检测当前 systemd 版本"

CURRENT_MAJOR="$(systemd_major_from_line "$CURRENT_VERSION_LINE")"
case "$CURRENT_MAJOR" in
  ''|*[!0-9]*) die "无法从版本信息中提取主版本：$CURRENT_VERSION_LINE" ;;
esac

log "current version: $CURRENT_VERSION_LINE"
if [ "$CURRENT_MAJOR" -le "$SYSTEMD257_TARGET_MAJOR" ]; then
  log "systemd $CURRENT_MAJOR does not require a 257 compatibility rebuild; skipped"
  exit 0
fi

# 依据当前 RootFS 的包管理器选择依赖安装和软件包锁定方式。
if command -v apt-get >/dev/null 2>&1 && command -v dpkg-query >/dev/null 2>&1; then
  PACKAGE_MANAGER="apt"
elif command -v dnf >/dev/null 2>&1 && command -v rpm >/dev/null 2>&1; then
  PACKAGE_MANAGER="dnf"
elif command -v pacman >/dev/null 2>&1; then
  PACKAGE_MANAGER="pacman"
else
  die "仅支持 apt、dnf 或 pacman 系统"
fi

WORK_DIR="$(mktemp -d -t systemd257.XXXXXXXX)"
SOURCE_DIR="$WORK_DIR/systemd"
BUILD_DIR="$WORK_DIR/build"
STAGE_DIR="$WORK_DIR/stage"
PACKAGES_BEFORE="$WORK_DIR/packages.before"
PACKAGES_AFTER="$WORK_DIR/packages.after"
PACKAGES_NEW="$WORK_DIR/packages.new"

# 保存构建前的软件包集合，构建完成后只移除本脚本新增的构建依赖。
snapshot_packages() {
  local output="$1"

  case "$PACKAGE_MANAGER" in
    apt)
      dpkg-query -W -f='${binary:Package}\n' 2>/dev/null | sort -u > "$output"
      ;;
    dnf)
      rpm -qa --queryformat '%{NAME}\n' | sort -u > "$output"
      ;;
    pacman)
      pacman -Qq | sort -u > "$output"
      ;;
  esac
}

install_build_dependencies() {
  log "installing build dependencies with $PACKAGE_MANAGER"

  case "$PACKAGE_MANAGER" in
    apt)
      local -a packages=(
        build-essential ca-certificates git meson ninja-build pkg-config gperf gettext m4
        python3 python3-jinja2 libcap-dev libmount-dev libblkid-dev libkmod-dev
        libpam0g-dev libseccomp-dev libacl1-dev liblz4-dev libzstd-dev
        liblzma-dev libcrypt-dev
      )
      apt-get update
      apt-get install -y --no-install-recommends "${packages[@]}"
      ;;
    dnf)
      local -a packages=(
        gcc gcc-c++ make diffutils ca-certificates git meson ninja-build pkgconf-pkg-config
        gperf gettext m4 python3 python3-jinja2 libcap-devel libmount-devel libblkid-devel
        kmod-devel pam-devel libseccomp-devel libacl-devel lz4-devel
        libzstd-devel xz-devel libxcrypt-devel
      )
      dnf install -y --setopt=install_weak_deps=False "${packages[@]}"
      ;;
    pacman)
      local -a packages=(
        base-devel ca-certificates git meson ninja pkgconf gperf gettext m4 python
        python-jinja libcap util-linux kmod pam libseccomp acl lz4 zstd xz
        libxcrypt
      )
      pacman -Sy --noconfirm --needed "${packages[@]}"
      ;;
  esac
}

remove_build_dependencies() {
  local package_list

  snapshot_packages "$PACKAGES_AFTER"
  comm -13 "$PACKAGES_BEFORE" "$PACKAGES_AFTER" > "$PACKAGES_NEW"
  if [ ! -s "$PACKAGES_NEW" ]; then
    log "no temporary build packages need to be removed"
    return
  fi

  package_list="$(tr '\n' ' ' < "$PACKAGES_NEW")"
  log "removing temporary build dependencies"

  case "$PACKAGE_MANAGER" in
    apt)
      # shellcheck disable=SC2086
      apt-get purge -y $package_list || true
      apt-get autoremove -y --purge || true
      apt-get clean || true
      ;;
    dnf)
      # clean_requirements_on_remove=False 防止清理构建依赖时波及原有 RootFS 软件包。
      # shellcheck disable=SC2086
      dnf remove -y --setopt=clean_requirements_on_remove=False $package_list || true
      dnf clean all || true
      ;;
    pacman)
      # 只移除构建前不存在的软件包，不递归删除原有孤立依赖。
      # shellcheck disable=SC2086
      pacman -R --noconfirm $package_list || true
      rm -rf /var/cache/pacman/pkg/*
      ;;
  esac
}

snapshot_packages "$PACKAGES_BEFORE"
install_build_dependencies

command -v meson >/dev/null 2>&1 || die "meson 安装失败"
command -v ninja >/dev/null 2>&1 || die "ninja 安装失败"
command -v git >/dev/null 2>&1 || die "git 安装失败"
command -v diff >/dev/null 2>&1 || die "diffutils 安装失败"

log "cloning $SYSTEMD257_REPO ($SYSTEMD257_REF)"
if ! git clone --depth=1 --branch "$SYSTEMD257_REF" "$SYSTEMD257_REPO" "$SOURCE_DIR"; then
  rm -rf -- "$SOURCE_DIR"
  git clone --depth=1 "$SYSTEMD257_REPO" "$SOURCE_DIR"
  git -C "$SOURCE_DIR" fetch --depth=1 origin "$SYSTEMD257_REF"
  git -C "$SOURCE_DIR" checkout --detach FETCH_HEAD
fi
SOURCE_COMMIT="$(git -C "$SOURCE_DIR" rev-parse HEAD)"
if [ ! -r "$SOURCE_DIR/meson.version" ]; then
  die "systemd 源码中缺少 meson.version，无法确认版本"
fi
SOURCE_VERSION="$(sed -n '1p' "$SOURCE_DIR/meson.version" | tr -d '[:space:]')"
SOURCE_MAJOR="$(systemd_major_from_line "$SOURCE_VERSION")"
case "$SOURCE_MAJOR" in
  "$SYSTEMD257_TARGET_MAJOR") ;;
  *) die "源码版本不是 systemd 257：${SOURCE_VERSION:-unknown}" ;;
esac
log "source version: $SOURCE_VERSION (commit=$SOURCE_COMMIT)"

BUILD_JOBS="${SYSTEMD257_JOBS:-}"
if ! printf '%s' "$BUILD_JOBS" | grep -Eq '^[1-9][0-9]*$'; then
  BUILD_JOBS="$(nproc 2>/dev/null || printf '2')"
  if [ "$BUILD_JOBS" -gt 4 ]; then
    BUILD_JOBS=4
  fi
fi

log "configuring systemd 257 (jobs=$BUILD_JOBS)"
meson setup "$BUILD_DIR" "$SOURCE_DIR" \
  --prefix=/usr \
  --sysconfdir=/etc \
  --localstatedir=/var \
  --buildtype=release \
  --auto-features=disabled \
  -Dmode=release \
  -Dsplit-bin=auto \
  -Dinstall-sysconfdir=false \
  -Drpmmacrosdir=no \
  -Dtests=false \
  -Dslow-tests=false \
  -Dfuzz-tests=false \
  -Dintegration-tests=false \
  -Dinstall-tests=false \
  -Dman=disabled \
  -Dhtml=disabled \
  -Dtranslations=false \
  -Defi=false \
  -Dbootloader=disabled \
  -Dukify=disabled \
  -Dkernel-install=false \
  -Dinitrd=false \
  -Dhibernate=false \
  -Drepart=disabled \
  -Dsysupdate=disabled \
  -Dsysupdated=disabled \
  -Dhomed=disabled \
  -Dvmspawn=disabled \
  -Dimportd=disabled \
  -Dremote=disabled \
  -Dmachined=false \
  -Dportabled=false \
  -Dmountfsd=false \
  -Dnsresourced=false \
  -Duserdb=false \
  -Dsysext=false \
  -Dstoragetm=false \
  -Doomd=false \
  -Dcoredump=false \
  -Dpstore=false \
  -Dbacklight=false \
  -Dvconsole=false \
  -Drfkill=false \
  -Dquotacheck=false \
  -Dlibcryptsetup=disabled \
  -Dlibcryptsetup-plugins=disabled \
  -Dlibcurl=disabled \
  -Dmicrohttpd=disabled \
  -Dlibidn2=disabled \
  -Dlibidn=disabled \
  -Didn=false \
  -Dqrencode=disabled \
  -Dgcrypt=disabled \
  -Dgnutls=disabled \
  -Dopenssl=disabled \
  -Ddns-over-tls=false \
  -Ddefault-dnssec=no \
  -Dp11kit=disabled \
  -Dlibfido2=disabled \
  -Dtpm=false \
  -Dtpm2=disabled \
  -Delfutils=disabled \
  -Dlibarchive=disabled \
  -Dxkbcommon=disabled \
  -Dpcre2=disabled \
  -Dglib=disabled \
  -Ddbus=disabled \
  -Dselinux=disabled \
  -Dapparmor=disabled \
  -Dima=false \
  -Dipe=false \
  -Dsmack=false \
  -Dpolkit=disabled \
  -Daudit=disabled \
  -Dfdisk=disabled \
  -Dpwquality=disabled \
  -Dpasswdqc=disabled \
  -Dbpf-framework=disabled \
  -Dlibiptc=disabled \
  -Dzlib=disabled \
  -Dbzip2=disabled \
  -Dseccomp=enabled \
  -Dacl=enabled \
  -Dblkid=enabled \
  -Dkmod=enabled \
  -Dpam=enabled \
  -Dxz=enabled \
  -Dlz4=enabled \
  -Dzstd=enabled \
  -Ddefault-compression=zstd \
  -Dresolve=true \
  -Dnetworkd=true \
  -Dlogind=true \
  -Dhostnamed=true \
  -Dlocaled=true \
  -Dtimedated=true \
  -Dtimesyncd=true \
  -Dsysusers=true \
  -Dtmpfiles=true \
  -Dhwdb=true \
  -Dnss-myhostname=true \
  -Dnss-systemd=true \
  -Dnss-resolve=enabled \
  -Dutmp=true \
  -Ddefault-kill-user-processes=false

log "building systemd 257"
ninja -C "$BUILD_DIR" -j "$BUILD_JOBS"

# 先安装到临时根目录，避免构建过程直接修改当前 RootFS。
mkdir -p "$STAGE_DIR"
DESTDIR="$STAGE_DIR" ninja -C "$BUILD_DIR" install

# 保留发行版较新的公共 libsystemd/libudev ABI。旧版 systemd 可使用新库，
# 同时避免 Arch/Fedora/Ubuntu 的桌面软件因需要新符号而失效。
if [ -d "$STAGE_DIR/usr" ]; then
  find "$STAGE_DIR/usr" \( -type f -o -type l \) \
    \( -name 'libsystemd.so' -o -name 'libsystemd.so.*' \
       -o -name 'libudev.so' -o -name 'libudev.so.*' \) -delete
  find "$STAGE_DIR/usr" -type f \
    \( -name 'libsystemd.pc' -o -name 'libudev.pc' \) -delete
  rm -rf "$STAGE_DIR/usr/include"
fi

# 构建依赖清理必须在覆盖 systemd 前完成，防止包管理器脚本重新安装新版文件。
remove_build_dependencies

log "installing the systemd 257 compatibility runtime"
cp -a "$STAGE_DIR/." /
command -v ldconfig >/dev/null 2>&1 && ldconfig

# 检查动态链接和最终版本，缺少依赖或覆盖失败时立即中止 RootFS 构建。
SYSTEMD_DAEMON=""
for candidate in /usr/lib/systemd/systemd /lib/systemd/systemd; do
  if [ -x "$candidate" ]; then
    SYSTEMD_DAEMON="$candidate"
    break
  fi
done
[ -n "$SYSTEMD_DAEMON" ] || die "安装后找不到 systemd PID 1"

if command -v ldd >/dev/null 2>&1; then
  LDD_OUTPUT="$(ldd "$SYSTEMD_DAEMON" 2>&1 || true)"
  if printf '%s\n' "$LDD_OUTPUT" | grep -q 'not found'; then
    printf '%s\n' "$LDD_OUTPUT" >&2
    die "systemd 257 存在缺失的动态链接库"
  fi
fi

INSTALLED_VERSION_LINE="$(systemd_version_line || true)"
INSTALLED_MAJOR="$(systemd_major_from_line "$INSTALLED_VERSION_LINE")"
if [ "$INSTALLED_MAJOR" != "$SYSTEMD257_TARGET_MAJOR" ]; then
  die "版本验证失败，当前结果为：${INSTALLED_VERSION_LINE:-unknown}"
fi

# 防止 RootFS 后续普通升级把兼容运行时重新覆盖为 258+。
case "$PACKAGE_MANAGER" in
  apt)
    mapfile -t systemd_packages < <(
      dpkg-query -W -f='${binary:Package} ${Status}\n' 2>/dev/null | awk '
        {
          if ($NF != "installed")
            next
          package = $1
          name = package
          sub(/:.*/, "", name)
          if (name == "udev" ||
              name ~ /^systemd(-|$)/ ||
              name ~ /^libsystemd/ ||
              name ~ /^libudev/ ||
              name == "libpam-systemd" ||
              name == "libnss-systemd") {
            print package
          }
        }
      ' | sort -u
    )
    if [ "${#systemd_packages[@]}" -gt 0 ]; then
      apt-mark hold "${systemd_packages[@]}"
    fi
    ;;
  dnf)
    touch /etc/dnf/dnf.conf
    if grep -q '^exclude=' /etc/dnf/dnf.conf; then
      current_excludes="$(sed -n 's/^exclude=//p' /etc/dnf/dnf.conf | head -n1)"
      case " $current_excludes " in
        *' systemd* '*) ;;
        *) sed -i '/^exclude=/{s/$/ systemd*/;}' /etc/dnf/dnf.conf ;;
      esac
    elif grep -q '^excludepkgs=' /etc/dnf/dnf.conf; then
      current_excludes="$(sed -n 's/^excludepkgs=//p' /etc/dnf/dnf.conf | head -n1)"
      case " $current_excludes " in
        *' systemd* '*) ;;
        *) sed -i '/^excludepkgs=/{s/$/ systemd*/;}' /etc/dnf/dnf.conf ;;
      esac
    else
      printf '\n# systemd257: keep the old-kernel compatibility runtime\nexclude=systemd*\n' >> /etc/dnf/dnf.conf
    fi
    ;;
  pacman)
    if grep -q '^IgnorePkg[[:space:]]*=' /etc/pacman.conf; then
      current_ignored="$(sed -n 's/^IgnorePkg[[:space:]]*=[[:space:]]*//p' /etc/pacman.conf | head -n1)"
      for package in systemd systemd-libs systemd-sysvcompat; do
        case " $current_ignored " in
          *" $package "*) ;;
          *)
            sed -i "/^IgnorePkg[[:space:]]*=/{s/$/ $package/;}" /etc/pacman.conf
            current_ignored="$current_ignored $package"
            ;;
        esac
      done
    else
      printf '\n# systemd257: keep the old-kernel compatibility runtime\nIgnorePkg = systemd systemd-libs systemd-sysvcompat\n' >> /etc/pacman.conf
    fi
    ;;
esac

cat > /etc/droidspaces-systemd257 <<EOF
previous_version=$CURRENT_VERSION_LINE
installed_version=$INSTALLED_VERSION_LINE
source_version=$SOURCE_VERSION
source_ref=$SYSTEMD257_REF
source_commit=$SOURCE_COMMIT
package_manager=$PACKAGE_MANAGER
EOF

log "done: $INSTALLED_VERSION_LINE"
