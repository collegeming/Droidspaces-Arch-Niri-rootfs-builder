#!/usr/bin/env bash
set -euo pipefail

# The package archives are deliberately kept out of Git. Override these when
# installing packages published by a fork or when pinning an older Release.
readonly DEFAULT_REPOSITORY="Goldzxcbug/Droidspaces-rootfs-KDE-builder"
readonly RELEASE_REPOSITORY="${ANLAND_KDE_RELEASE_REPOSITORY:-$DEFAULT_REPOSITORY}"
RELEASE_TAG="${ANLAND_KDE_RELEASE_TAG:-}"
readonly RELEASE_TAG_PREFIX="anland-kde-packages-"

WORK_DIR=""
UI_LANG="en"
TARGET=""
PACKAGE_TYPE=""
ARCHIVE_PREFIX=""
ARCHIVE_NAME=""
ARCHIVE_TARGET=""
PACKAGE_DIR=""

detect_language() {
    local locale_name="${LC_ALL:-${LC_MESSAGES:-${LANG:-C}}}"
    locale_name="${locale_name,,}"
    if [[ "$locale_name" == zh* ]]; then
        UI_LANG="zh"
    fi
}

msg() {
    if [[ "$UI_LANG" == "zh" ]]; then
        printf '%s' "$1"
    else
        printf '%s' "$2"
    fi
}

log() {
    printf '[anland-kde] %s\n' "$(msg "$1" "$2")"
}

die() {
    printf '[anland-kde] %s: %s\n' "$(msg '错误' 'Error')" "$(msg "$1" "$2")" >&2
    exit 1
}

cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf -- "$WORK_DIR"
    fi
}
trap cleanup EXIT

require_root() {
    if (( EUID == 0 )); then
        return
    fi

    command -v sudo >/dev/null 2>&1 || die "请使用 root 账户运行此脚本。" "Please run this script as root."
    log "正在通过 sudo 重新运行安装程序..." "Restarting the installer with sudo..."
    exec sudo env \
        "ANLAND_KDE_RELEASE_REPOSITORY=$RELEASE_REPOSITORY" \
        "ANLAND_KDE_RELEASE_TAG=$RELEASE_TAG" \
        "${BASH_SOURCE[0]}" "$@"
}

detect_target() {
    [[ -r /etc/os-release ]] || die "无法读取 /etc/os-release。" "Unable to read /etc/os-release."

    # shellcheck disable=SC1091
    source /etc/os-release
    [[ -n "${ID:-}" ]] || die "/etc/os-release 缺少 ID。" "/etc/os-release does not contain ID."
    local distro_id="${ID,,}"
    local version_id="${VERSION_ID:-}"
    local system_name="${PRETTY_NAME:-$distro_id${version_id:+ $version_id}}"

    case "$distro_id" in
        arch|archarm)
            TARGET="Arch Linux"
            PACKAGE_TYPE="pkg.tar.*"
            ARCHIVE_PREFIX="anland-kde-arch-kwin-"
            ARCHIVE_TARGET="arch"
            ;;
        *)
            [[ -n "$version_id" ]] || die "/etc/os-release 缺少 VERSION_ID。" "/etc/os-release does not contain VERSION_ID."
            case "$distro_id:$version_id" in
                debian:13*)
                    TARGET="Debian 13"
                    PACKAGE_TYPE="deb"
                    ARCHIVE_PREFIX="anland-kde-debian13-kwin-"
                    ARCHIVE_TARGET="debian13"
                    ;;
                ubuntu:26.04*)
                    TARGET="Ubuntu 26.04"
                    PACKAGE_TYPE="deb"
                    ARCHIVE_PREFIX="anland-kde-ubuntu2604-kwin-"
                    ARCHIVE_TARGET="ubuntu2604"
                    ;;
                fedora:43*)
                    TARGET="Fedora 43"
                    PACKAGE_TYPE="rpm"
                    ARCHIVE_PREFIX="anland-kde-fedora43-kwin-"
                    ARCHIVE_TARGET="fedora43"
                    ;;
                fedora:44*)
                    TARGET="Fedora 44"
                    PACKAGE_TYPE="rpm"
                    ARCHIVE_PREFIX="anland-kde-fedora44-kwin-"
                    ARCHIVE_TARGET="fedora44"
                    ;;
                *)
                    die "不支持当前系统 ${system_name}。仅支持 Debian 13、Ubuntu 26.04、Fedora 43/44、Arch Linux。" \
                        "Unsupported system: ${system_name}. Supported systems are Debian 13, Ubuntu 26.04, Fedora 43/44, and Arch Linux."
                    ;;
            esac
            ;;
    esac

    log "已识别系统: ${system_name} -> ${TARGET}" "Detected system: ${system_name} -> ${TARGET}"
}

check_architecture() {
    case "$(uname -m)" in
        aarch64|arm64) ;;
        *)
            die "预编译包仅支持 ARM64/aarch64，当前架构为 $(uname -m)。" \
                "The prebuilt packages support ARM64/aarch64 only; current architecture is $(uname -m)."
            ;;
    esac
}

download_file() {
    local url="$1"
    local destination="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 3 --retry-all-errors --connect-timeout 20 "$url" -o "$destination"
    elif command -v wget >/dev/null 2>&1; then
        wget -O "$destination" "$url"
    else
        die "未找到 curl 或 wget，无法下载安装包。" "Neither curl nor wget was found; packages cannot be downloaded."
    fi
}

download_stdout() {
    local url="$1"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --retry 3 --retry-all-errors --connect-timeout 20 "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO- "$url"
    else
        die "未找到 curl 或 wget，无法查询 Release。" "Neither curl nor wget was found; Releases cannot be queried."
    fi
}

validate_release_tag() {
    case "$RELEASE_TAG" in
        "${RELEASE_TAG_PREFIX}"[0-9]*) ;;
        *)
            die "Release tag 必须以 ${RELEASE_TAG_PREFIX} 开头。" \
                "Release tags must start with ${RELEASE_TAG_PREFIX}."
            ;;
    esac
}

resolve_release_tag() {
    local api_url page response candidate

    if [[ -n "$RELEASE_TAG" ]]; then
        validate_release_tag
        return
    fi

    api_url="https://api.github.com/repos/${RELEASE_REPOSITORY}/releases?per_page=100"
    page=1
    while (( page <= 10 )); do
        if ! response="$(download_stdout "${api_url}&page=${page}")"; then
            die "无法查询 GitHub Release 列表。" "Unable to query the GitHub Release list."
        fi

        candidate="$(printf '%s\n' "$response" | tr '{,}' '\n' | \
            sed -nE 's/^[[:space:]]*"tag_name"[[:space:]]*:[[:space:]]*"([A-Za-z0-9._-]+)".*/\1/p' | \
            sed -n "/^${RELEASE_TAG_PREFIX}[0-9]/ { p; q; }")"
        if [[ -n "$candidate" ]]; then
            RELEASE_TAG="$candidate"
            log "已选择不可变 Release: ${RELEASE_TAG}" "Selected immutable Release: ${RELEASE_TAG}"
            return
        fi

        ((page += 1))
    done

    die "未找到可用的 Anland KDE 包 Release。" "No usable Anland KDE package Release was found."
}

resolve_archive_name() {
    local api_url response name
    local -a candidates=()

    api_url="https://api.github.com/repos/${RELEASE_REPOSITORY}/releases/tags/${RELEASE_TAG}"
    if ! response="$(download_stdout "$api_url")"; then
        die "无法读取 Release ${RELEASE_TAG} 的资产列表。" \
            "Unable to read the asset list for Release ${RELEASE_TAG}."
    fi

    # GitHub API 可能返回格式化 JSON，也可能返回单行 JSON；按字段切分后只匹配当前目标前缀。
    while IFS= read -r name; do
        case "$name" in
            "${ARCHIVE_PREFIX}"*.tar.gz) candidates+=("$name") ;;
        esac
    done < <(printf '%s\n' "$response" | tr '{,}' '\n' | \
        sed -nE 's/^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')

    if [[ "${#candidates[@]}" -ne 1 ]]; then
        die "Release ${RELEASE_TAG} 中没有唯一的 ${TARGET} KWin 版本包（找到 ${#candidates[@]} 个）。" \
            "Release ${RELEASE_TAG} does not contain exactly one ${TARGET} KWin version archive (found ${#candidates[@]})."
    fi
    ARCHIVE_NAME="${candidates[0]}"
    log "已选择 ${ARCHIVE_NAME}" "Selected ${ARCHIVE_NAME}"
}

release_download_base() {
    printf 'https://github.com/%s/releases/download/%s' "$RELEASE_REPOSITORY" "$RELEASE_TAG"
}

download_packages() {
    local base_url checksum_file archive_file expected_checksum
    WORK_DIR="$(mktemp -d -t anland-kde.XXXXXXXX)"
    resolve_release_tag
    resolve_archive_name
    base_url="$(release_download_base)"
    checksum_file="$WORK_DIR/SHA256SUMS"
    archive_file="$WORK_DIR/$ARCHIVE_NAME"
    expected_checksum="$WORK_DIR/$ARCHIVE_NAME.sha256"

    log "正在从 GitHub Release 下载 ${TARGET} 预编译包..." \
        "Downloading ${TARGET} prebuilt packages from GitHub Release..."
    download_file "$base_url/$ARCHIVE_NAME" "$archive_file"
    download_file "$base_url/SHA256SUMS" "$checksum_file"

    grep -F "  $ARCHIVE_NAME" "$checksum_file" > "$expected_checksum" || \
        die "Release 校验文件中缺少 ${ARCHIVE_NAME}。" "The Release checksum file does not contain ${ARCHIVE_NAME}."
    (
        cd "$WORK_DIR"
        sha256sum -c "$(basename "$expected_checksum")"
    ) || die "Release 包校验失败。" "Release package checksum verification failed."

    tar -xzf "$archive_file" -C "$WORK_DIR"
    PACKAGE_DIR="$WORK_DIR/anland-kde-packages/$ARCHIVE_TARGET"
    has_packages "$PACKAGE_DIR" || die "未能获取 ${TARGET} 的安装包。" "Could not obtain packages for ${TARGET}."
}

has_packages() {
    local directory="$1"
    compgen -G "$directory/*.${PACKAGE_TYPE}" >/dev/null
}

install_deb_packages() {
    local -a files packages
    local file package

    command -v apt-get >/dev/null 2>&1 || die "未找到 apt-get。" "apt-get was not found."
    command -v dpkg-deb >/dev/null 2>&1 || die "未找到 dpkg-deb。" "dpkg-deb was not found."
    mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.deb' -print | sort)
    ((${#files[@]} > 0)) || die "没有可安装的 deb 包。" "No installable deb packages were found."

    log "正在安装 ${#files[@]} 个 deb 包并自动处理依赖..." \
        "Installing ${#files[@]} deb packages and resolving dependencies..."
    apt-get install -y --allow-downgrades --allow-change-held-packages "${files[@]}"

    for file in "${files[@]}"; do
        package="$(dpkg-deb -f "$file" Package)"
        [[ -n "$package" ]] && packages+=("$package")
    done
    mapfile -t packages < <(printf '%s\n' "${packages[@]}" | sort -u)
    ((${#packages[@]} > 0)) || die "无法读取 deb 包名。" "Could not determine the deb package names."

    log "正在设置 APT hold..." "Applying APT holds..."
    apt-mark hold "${packages[@]}"
    printf '  hold: %s\n' "${packages[@]}"
}

install_rpm_packages() {
    local -a files packages
    local -a exclude_patterns=("kwin*" "xorg-x11-server-Xwayland*")
    local current_excludes exclude_key pattern

    command -v dnf >/dev/null 2>&1 || die "未找到 dnf。" "dnf was not found."
    command -v rpm >/dev/null 2>&1 || die "未找到 rpm。" "rpm was not found."
    mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.rpm' -print | sort)
    ((${#files[@]} > 0)) || die "没有可安装的 rpm 包。" "No installable rpm packages were found."

    log "正在安装 ${#files[@]} 个 rpm 包并自动处理依赖..." \
        "Installing ${#files[@]} rpm packages and resolving dependencies..."
    dnf install -y "${files[@]}"

    mapfile -t packages < <(rpm -qp --queryformat '%{NAME}\n' "${files[@]}" | sort -u)
    log "正在设置 DNF exclude（等效于 hold）..." "Applying DNF excludes (equivalent to hold)..."
    touch /etc/dnf/dnf.conf
    if grep -q '^exclude=' /etc/dnf/dnf.conf; then
        exclude_key="exclude"
    elif grep -q '^excludepkgs=' /etc/dnf/dnf.conf; then
        exclude_key="excludepkgs"
    else
        exclude_key=""
    fi

    if [[ -n "$exclude_key" ]]; then
        current_excludes="$(sed -n "s/^${exclude_key}=//p" /etc/dnf/dnf.conf | head -n1)"
        for pattern in "${exclude_patterns[@]}"; do
            case " $current_excludes " in
                *" $pattern "*) ;;
                *)
                    sed -i "/^${exclude_key}=/{s|$| $pattern|;}" /etc/dnf/dnf.conf
                    current_excludes="$current_excludes $pattern"
                    ;;
            esac
        done
    else
        printf '\n# anland-kde: hold patched KWin/Xwayland packages\nexclude=%s\n' \
            "${exclude_patterns[*]}" >> /etc/dnf/dnf.conf
    fi
    printf '  hold: %s\n' "${packages[@]}"
}

install_arch_packages() {
    local -a files packages
    local pacman_conf

    command -v pacman >/dev/null 2>&1 || die "未找到 pacman。" "pacman was not found."
    mapfile -t files < <(find "$PACKAGE_DIR" -maxdepth 1 -type f -name '*.pkg.tar.*' -print | sort)
    ((${#files[@]} > 0)) || die "没有可安装的 Arch 包。" "No installable Arch packages were found."

    log "正在安装 ${#files[@]} 个 Arch 包..." "Installing ${#files[@]} Arch packages..."
    pacman_conf="$(mktemp -t anland-kde-pacman.XXXXXXXX)"
    cp /etc/pacman.conf "$pacman_conf"
    if grep -q '^#LocalFileSigLevel = Optional$' "$pacman_conf"; then
        sed -i 's/^#LocalFileSigLevel = Optional$/LocalFileSigLevel = Optional/' "$pacman_conf"
    else
        printf '\n[options]\nLocalFileSigLevel = Optional\n' >> "$pacman_conf"
    fi
    pacman --config "$pacman_conf" -U --noconfirm "${files[@]}"
    rm -f -- "$pacman_conf"

    if ! grep -q '^IgnorePkg.*kwin' /etc/pacman.conf; then
        sed -i '/^\[options\]$/a IgnorePkg = kwin xorg-xwayland' /etc/pacman.conf
    fi
    mapfile -t packages < <(pacman -Qq -p "${files[@]}" | sort -u)
    printf '  hold: %s\n' "${packages[@]}"
}

main() {
    detect_language
    require_root "$@"
    detect_target
    check_architecture
    download_packages

    case "$PACKAGE_TYPE" in
        deb) install_deb_packages ;;
        rpm) install_rpm_packages ;;
        pkg.tar.*) install_arch_packages ;;
    esac

    log "安装完成，patched KWin/Xwayland 已锁定。" \
        "Installation complete; patched KWin/Xwayland packages are now locked."
}

main "$@"
