#!/bin/sh
# apply-preferences.sh — rootfs 构建的最后阶段：应用桌面偏好设置。
#
# 设计目标
#   1. 幂等：内容相同的配置文件不重写；已应用的 profile+version 直接跳过。
#   2. 可回退：覆盖任何已有文件前，先备份到 <状态目录>/backup/<UTC 时间戳>/。
#   3. 失败分级：PREFERENCES_STRICT=false 记录警告并继续；true 则立即失败。
#   4. 跨发行版安全：只在对应软件包/目录存在时执行该步骤，其余记录为跳过。
#   5. 离线优先：只有 packages 步骤需要网络，且使用发行版自身的软件源配置。
#
# 环境变量
#   APPLY_PREFERENCES             true|false，默认 false；false 时立即退出且不写文件
#   PREFERENCES_PROFILE           profile 名称，默认 arch-niri-noctalia
#   PREFERENCES_STRICT            true|false，默认 false
#   PREFERENCES_DRY_RUN           true|false，默认 false；true 时只打印计划
#   PREFERENCES_INSTALL_PACKAGES  true|false，默认 true；packages 步骤总开关
#   PREFERENCES_USER              指定目标用户；默认取第一个 uid>=1000 的普通用户
#   PREFERENCES_FONT_SIZE         kitty 字号，默认 12.0
#   PREFERENCES_ROOT              测试用：给所有路径加前缀，配合 DRY_RUN 使用
#
# 由 Dockerfile 以 `sh apply-preferences.sh` 调用，运行身份为 root。
# 注意：为兼容 dash 等严格 POSIX shell，函数内不使用 local，变量名按函数加前缀避免互扰。

set -eu
umask 022

PREFERENCES_VERSION=2026.11.09

PROFILE=${PREFERENCES_PROFILE:-arch-niri-noctalia}
FONT_SIZE=${PREFERENCES_FONT_SIZE:-12.0}
case $FONT_SIZE in
    '' | *[!0-9.]*) FONT_SIZE=12.0 ;;
esac

# GitHub 直连在部分网络下不稳定；默认用镜像前缀，可用 GH_MIRROR_PREFIX 覆盖。
GH_MIRROR_PREFIX=${GH_MIRROR_PREFIX:-https://gh-proxy.com/}

ROOT=${PREFERENCES_ROOT:-}
ROOT=${ROOT%/}
SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
ASSETS_DIR=$SCRIPT_DIR/assets
STATE_DIR=$ROOT/var/lib/droidspaces-preferences
MANIFEST=$STATE_DIR/manifest.env
TMPFILES=

# TMPDIR 可能从宿主/容器环境继承成不存在的路径（例如 Android 的
# /data/local/tmp 在容器内不存在），mktemp 会全部失败。只在可用时保留。
if [ -z "${TMPDIR:-}" ] || [ ! -d "$TMPDIR" ] || [ ! -w "$TMPDIR" ]; then
    TMPDIR=/tmp
fi
export TMPDIR

USER_NAME=
USER_UID=
USER_GID=
USER_HOME=
BACKUP_DIR=
BACKUP_COUNT=0
TIMESTAMP=
APPLIED=
SKIPPED=
FAILED=
WARNINGS=
STEP_NAME=
STEP_REASON=
LOCALE_ZH_APPLIED=false
DRY_RUN=false
LOG_FILE=${TMPDIR:-/tmp}/droidspaces-preferences.log

# ---------------------------------------------------------------- 基础工具

normalize_bool() {
    case $(printf '%s' "${1:-}" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz') in
        true | 1 | yes | on) printf 'true' ;;
        false | 0 | no | off | '') printf 'false' ;;
        *) return 1 ;;
    esac
}

cleanup_tmp() {
    [ -n "$TMPFILES" ] || return 0
    for ct_file in $TMPFILES; do
        rm -f "$ct_file" 2>/dev/null || true
    done
    TMPFILES=
}

trap cleanup_tmp EXIT
trap 'cleanup_tmp; exit 130' INT TERM HUP

# 结果写入全局 nt_path；不使用命令替换，否则 TMPFILES 的登记会丢在子 shell 里。
new_tmp() {
    nt_path=$(mktemp "${TMPDIR:-/tmp}/droidspaces-preferences.XXXXXX") || return 1
    TMPFILES="$TMPFILES $nt_path"
    return 0
}

drop_tmp() {
    dt_file=${1:-}
    [ -n "$dt_file" ] || return 0
    rm -f "$dt_file" 2>/dev/null || true
    if [ -n "$TMPFILES" ]; then
        TMPFILES=$(printf '%s' " $TMPFILES " | sed "s| $dt_file | |")
    fi
}

log() {
    log_line="[preferences] $*"
    printf '%s\n' "$log_line"
    [ "$DRY_RUN" = true ] && return 0
    printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$log_line" >>"$LOG_FILE" 2>/dev/null || true
}

warn() {
    log "WARNING: $*"
    WARNINGS="${WARNINGS}${WARNINGS:+; }$*"
}

skip_step() {
    STEP_REASON=$1
    log "skip: $STEP_NAME ($1)"
}

fail_step() {
    STEP_REASON=$1
    log "fail: $STEP_NAME ($1)"
}

add_applied() {
    APPLIED="${APPLIED}${APPLIED:+, }$1"
}

add_skipped() {
    SKIPPED="${SKIPPED}${SKIPPED:+, }$1"
}

add_failed() {
    FAILED="${FAILED}${FAILED:+, }$1"
}

env_quote() {
    printf "'%s'" "$(printf '%s' "$1" | tr -d "'" | tr '\n' ' ')"
}

path_exists() {
    [ -e "$ROOT$1" ] || [ -L "$ROOT$1" ]
}

is_dir() {
    [ -d "$ROOT$1" ]
}

have_bin() {
    hb_name=$1
    if [ -n "$ROOT" ]; then
        for hb_dir in /usr/local/sbin /usr/local/bin /usr/bin /bin /usr/sbin /sbin; do
            if [ -e "$ROOT$hb_dir/$hb_name" ]; then
                return 0
            fi
        done
        return 1
    fi
    command -v "$hb_name" >/dev/null 2>&1
}

# 把 github.com 链接改写到镜像前缀；其它链接原样返回。
gh_mirror_url() {
    case "$1" in
        https://github.com/* | https://raw.githubusercontent.com/*)
            printf '%s/%s\n' "${GH_MIRROR_PREFIX%/}" "$1"
            ;;
        *)
            printf '%s\n' "$1"
            ;;
    esac
}

# 下载 URL 到文件；GitHub 链接走镜像，失败重试。
fetch_url() {
    fu_url=$(gh_mirror_url "$1")
    fu_out=$2
    if command -v curl >/dev/null 2>&1; then
        curl -fL --retry 5 --retry-all-errors --retry-delay 5 \
            --connect-timeout 20 --max-time 600 "$fu_url" -o "$fu_out"
    elif command -v wget >/dev/null 2>&1; then
        wget --tries=5 --timeout=20 --waitretry=5 -O "$fu_out" "$fu_url"
    else
        return 1
    fi
}

same_content() {
    sc_first=$(cksum <"$1" 2>/dev/null) || sc_first=missing
    sc_second=$(cksum <"$2" 2>/dev/null) || sc_second=absent
    [ "$sc_first" = "$sc_second" ]
}

# 备份已有文件到 $BACKUP_DIR/<原绝对路径>；同一次运行内同一文件只备份一次。
backup_file() {
    bf_dest=$1
    bf_full=$ROOT$bf_dest
    if [ ! -e "$bf_full" ] && [ ! -L "$bf_full" ]; then
        return 0
    fi
    bf_target=$BACKUP_DIR$bf_dest
    if [ -e "$bf_target" ]; then
        log "backup: $bf_dest 本次运行已备份"
        return 0
    fi
    if [ "$DRY_RUN" = true ]; then
        log "dry-run: would back up $bf_dest -> $bf_target"
        return 0
    fi
    mkdir -p "$(dirname "$bf_target")" || return 1
    cp -p "$bf_full" "$bf_target" || return 1
    BACKUP_COUNT=$((BACKUP_COUNT + 1))
    log "backup: $bf_dest -> $bf_target"
}

# 从标准输入写入 dest：内容相同不落盘，不同则先备份再写。
install_content() {
    ic_dest=$1
    ic_mode=${2:-0644}
    ic_full=$ROOT$ic_dest

    if ! new_tmp; then
        fail_step "mktemp 失败"
        return 1
    fi
    ic_tmp=$nt_path
    cat >"$ic_tmp"

    if [ -f "$ic_full" ] && same_content "$ic_tmp" "$ic_full"; then
        drop_tmp "$ic_tmp"
        log "unchanged: $ic_dest"
        return 0
    fi
    if [ "$DRY_RUN" = true ]; then
        log "dry-run: would write $ic_dest (mode $ic_mode)"
        drop_tmp "$ic_tmp"
        return 0
    fi
    if ! backup_file "$ic_dest"; then
        drop_tmp "$ic_tmp"
        fail_step "备份失败：$ic_dest"
        return 1
    fi

    ic_user_dest=false
    if [ -n "$USER_HOME" ]; then
        case $ic_dest in
            "$USER_HOME"/*) ic_user_dest=true ;;
        esac
    fi
    if [ "$ic_user_dest" = true ]; then
        if ! prepare_user_parent "$ic_dest"; then
            drop_tmp "$ic_tmp"
            return 1
        fi
    else
        if ! mkdir -p "$(dirname "$ic_full")"; then
            drop_tmp "$ic_tmp"
            fail_step "无法创建目录：$(dirname "$ic_dest")"
            return 1
        fi
    fi

    if ! cp "$ic_tmp" "$ic_full"; then
        drop_tmp "$ic_tmp"
        fail_step "写入失败：$ic_dest"
        return 1
    fi
    chmod "$ic_mode" "$ic_full" 2>/dev/null || warn "chmod 失败：$ic_dest"
    if [ "$ic_user_dest" = true ] && [ -z "$ROOT" ] && [ -n "$USER_UID" ]; then
        chown "$USER_UID:$USER_GID" "$ic_full" 2>/dev/null || warn "chown 失败：$ic_dest"
    fi
    drop_tmp "$ic_tmp"
    log "wrote: $ic_dest"
    return 0
}

# 安装仓库内自带资产：install_asset <目标> <assets 相对路径> [权限] [sed 表达式]
install_asset() {
    ia_dest=$1
    ia_rel=$2
    ia_mode=${3:-0644}
    ia_expr=${4:-}
    ia_src=$ASSETS_DIR/$ia_rel
    if [ ! -r "$ia_src" ]; then
        fail_step "缺少资产：$ia_rel"
        return 1
    fi
    if [ -z "$ia_expr" ]; then
        install_content "$ia_dest" "$ia_mode" <"$ia_src"
        return $?
    fi
    if ! new_tmp; then
        fail_step "mktemp 失败"
        return 1
    fi
    ia_tmp=$nt_path
    if ! sed "$ia_expr" "$ia_src" >"$ia_tmp"; then
        drop_tmp "$ia_tmp"
        fail_step "渲染资产失败：$ia_rel"
        return 1
    fi
    install_content "$ia_dest" "$ia_mode" <"$ia_tmp"
    ia_rc=$?
    drop_tmp "$ia_tmp"
    return $ia_rc
}

# 仅当文件不存在时写入；已存在则保留（返回 2）。
install_if_absent() {
    iia_dest=$1
    iia_mode=${2:-0644}
    iia_rel=$3
    if path_exists "$iia_dest"; then
        skip_step "$iia_dest 已存在，保留现有内容"
        return 2
    fi
    install_asset "$iia_dest" "$iia_rel" "$iia_mode"
    return $?
}

# 在用户家目录下逐级创建目录，新建目录属主设为该用户。
prepare_user_parent() {
    pp_dest=$1
    pp_rel=${pp_dest#"$USER_HOME"/}
    pp_dir=$(dirname "$pp_rel")
    if [ "$pp_dir" = "." ]; then
        return 0
    fi
    pp_old_ifs=$IFS
    IFS=/
    # shellcheck disable=SC2086
    set -- $pp_dir
    IFS=$pp_old_ifs
    pp_cur=$USER_HOME
    for pp_part in "$@"; do
        [ -n "$pp_part" ] || continue
        pp_cur=$pp_cur/$pp_part
        pp_full=$ROOT$pp_cur
        [ -d "$pp_full" ] && continue
        if [ "$DRY_RUN" = true ]; then
            log "dry-run: would create directory $pp_cur"
            continue
        fi
        if ! mkdir "$pp_full"; then
            fail_step "无法创建目录：$pp_cur"
            return 1
        fi
        if [ -z "$ROOT" ] && [ -n "$USER_UID" ]; then
            chown "$USER_UID:$USER_GID" "$pp_full" 2>/dev/null || warn "chown 失败：$pp_cur"
        fi
    done
    return 0
}

# 把用户家目录下由构建期创建的子目录交还给用户。旧版 rime 步骤用 install -d
# 以 root 建过 ~/.local/share/fcitx5，导致 colle 连 ~/.local/share/applications
# 都建不出来（Chrome、Qt 应用因此启动即失败）。
fix_user_ownership() {
    if [ -z "$USER_HOME" ] || [ -z "$USER_UID" ]; then
        return 0
    fi
    fu_paths=
    for fu_rel in .config .local .cache .local/share .local/state; do
        fu_full=$ROOT$USER_HOME/$fu_rel
        [ -d "$fu_full" ] || continue
        fu_paths="$fu_paths $fu_full"
    done
    [ -n "$fu_paths" ] || return 0
    if [ "$DRY_RUN" = true ] || [ -n "$ROOT" ]; then
        return 0
    fi
    # shellcheck disable=SC2086
    chown -R "$USER_UID:$USER_GID" $fu_paths 2>/dev/null || warn "chown 用户目录失败"
    return 0
}

# 以 KEY=VALUE 覆盖 /etc/environment 的同名键。桌面会话是 system unit
# （EnvironmentFile=/etc/environment），不读 ~/.config/environment.d；只写
# environment.d 的变量在会话里看不到。systemd/pam_env 都不解析 export 前缀。
set_etc_environment() {
    see_key=$1
    see_val=$2
    see_full=$ROOT/etc/environment
    if ! new_tmp; then
        fail_step "mktemp 失败"
        return 1
    fi
    see_tmp=$nt_path
    [ -f "$see_full" ] || : >"$see_full"
    if ! awk -v k="$see_key" -v v="$see_val" '
        BEGIN { done = 0 }
        $0 ~ "^[[:space:]]*(export[[:space:]]+)?" k "[[:space:]]*=" {
            if (!done) { print k "=" v; done = 1 }
            next
        }
        { print }
        END { if (!done) print k "=" v }
    ' "$see_full" >"$see_tmp"; then
        drop_tmp "$see_tmp"
        fail_step "解析 /etc/environment 失败"
        return 1
    fi
    install_content /etc/environment 0644 <"$see_tmp"
    see_rc=$?
    drop_tmp "$see_tmp"
    return $see_rc
}

# 向文件追加一行（不存在该行时）。
append_line_once() {
    al_dest=$1
    al_line=$2
    al_full=$ROOT$al_dest
    if [ -f "$al_full" ] && grep -qxF "$al_line" "$al_full" 2>/dev/null; then
        log "unchanged: $al_dest (+$al_line)"
        return 0
    fi
    if [ "$DRY_RUN" = true ]; then
        log "dry-run: would append '$al_line' to $al_dest"
        return 0
    fi
    if ! backup_file "$al_dest"; then
        fail_step "备份失败：$al_dest"
        return 1
    fi
    if ! mkdir -p "$(dirname "$al_full")"; then
        fail_step "无法创建目录：$(dirname "$al_dest")"
        return 1
    fi
    if ! printf '%s\n' "$al_line" >>"$al_full"; then
        fail_step "追加失败：$al_dest"
        return 1
    fi
    log "appended: $al_dest (+$al_line)"
    return 0
}

# ---------------------------------------------------------------- 系统探测

detect_user() {
    du_passwd=$ROOT/etc/passwd
    [ -r "$du_passwd" ] || return 1
    if [ -n "${PREFERENCES_USER:-}" ]; then
        du_entry=$(grep "^$PREFERENCES_USER:" "$du_passwd" 2>/dev/null | head -n1) || du_entry=
    else
        du_entry=$(awk -F: '$3 >= 1000 && $3 < 60000 && $1 != "nobody" { print; exit }' "$du_passwd") || du_entry=
    fi
    [ -n "${du_entry:-}" ] || return 1
    USER_NAME=$(printf '%s' "$du_entry" | cut -d: -f1)
    USER_UID=$(printf '%s' "$du_entry" | cut -d: -f3)
    USER_GID=$(printf '%s' "$du_entry" | cut -d: -f4)
    USER_HOME=$(printf '%s' "$du_entry" | cut -d: -f6)
    [ -n "$USER_NAME" ] && [ -n "$USER_HOME" ]
}

is_arch() {
    path_exists /etc/pacman.conf || have_bin pacman
}

desktop_is_niri() {
    or_marker=$ROOT/etc/droidspaces-desktop.conf
    if [ -r "$or_marker" ]; then
        or_desktop=$(sed -n 's/^DESKTOP=//p' "$or_marker" | head -n1)
        [ "$or_desktop" = niri ] && return 0
    fi
    have_bin niri
}

desktop_present() {
    dp_marker=$ROOT/etc/droidspaces-desktop.conf
    if [ -r "$dp_marker" ]; then
        dp_desktop=$(sed -n 's/^DESKTOP=//p' "$dp_marker" | head -n1)
        if [ -n "$dp_desktop" ] && [ "$dp_desktop" != none ]; then
            return 0
        fi
    fi
    have_bin niri || have_bin noctalia
}

# GTK3 在 Arch/Fedora 位于 /usr/lib(64)，Debian/Ubuntu 位于 multiarch 目录。
gtk3_present() {
    [ -d "$ROOT/usr/lib/gtk-3.0" ] && return 0
    [ -d "$ROOT/usr/lib64/gtk-3.0" ] && return 0
    for gt_lib in "$ROOT"/usr/lib/libgtk-3.so.0 "$ROOT"/usr/lib64/libgtk-3.so.0 "$ROOT"/usr/lib/*/libgtk-3.so.0; do
        [ -e "$gt_lib" ] && return 0
    done
    return 1
}

fonts_have_maple() {
    if [ -z "$ROOT" ] && have_bin fc-list; then
        fc-list 2>/dev/null | grep -qi 'maple mono' && return 0
        return 1
    fi
    for fm_dir in /usr/share/fonts /usr/local/share/fonts; do
        is_dir "$fm_dir" || continue
        if find "$ROOT$fm_dir" -maxdepth 3 -iname '*maple*' -print -quit 2>/dev/null | grep -q .; then
            return 0
        fi
    done
    return 1
}

locale_zh_available() {
    if grep -qE '^LANG=zh_CN\.UTF-8' "$ROOT/etc/locale.conf" 2>/dev/null; then
        return 0
    fi
    if [ -z "$ROOT" ] && command -v locale >/dev/null 2>&1 && locale -a 2>/dev/null | grep -qi '^zh_CN\.utf-\?8$'; then
        return 0
    fi
    return 1
}

run_as_user() {
    [ -n "$USER_NAME" ] || return 1
    if [ "$DRY_RUN" = true ]; then
        log "dry-run: would run as $USER_NAME: $*"
        return 0
    fi
    if [ -n "$ROOT" ]; then
        log "skip: PREFERENCES_ROOT 模式下不执行用户命令：$*"
        return 0
    fi
    su -s /bin/sh "$USER_NAME" -c "$*" >/dev/null 2>&1 || return 1
    return 0
}

# ---------------------------------------------------------------- 步骤实现

# 1) 按文档安装缺失的包（仅 Arch；AUR/archlinuxcn 项不在本步骤范围）。
step_packages() {
    if [ "$INSTALL_PACKAGES" != true ]; then
        skip_step "PREFERENCES_INSTALL_PACKAGES=$INSTALL_PACKAGES"
        return 2
    fi
    if ! is_arch; then
        skip_step "非 Arch 系统，跳过按文档补包"
        return 2
    fi
    if ! desktop_present; then
        skip_step "未检测到桌面环境，跳过按文档补包"
        return 2
    fi
    if ! have_bin pacman; then
        skip_step "pacman 不可用"
        return 2
    fi

    packages="noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-jetbrains-mono
fcitx5 fcitx5-chinese-addons fcitx5-rime fcitx5-configtool fcitx5-gtk fcitx5-qt
kitty fish fastfetch nemo nemo-fileroller gvfs gvfs-mtp cinnamon-translations
upower qt5-wayland qt6-wayland neovim wl-clipboard xdg-utils xdg-user-dirs
xdg-terminal-exec"

    if [ "$DRY_RUN" = true ] || [ -n "$ROOT" ]; then
        log "dry-run: would install with pacman --needed: $(printf '%s' "$packages" | tr '\n' ' ')"
        return 0
    fi

    log "同步软件包数据库并安装文档列出的桌面/输入法/字体包"
    pacman -Sy --noconfirm >/dev/null 2>&1 || warn "pacman -Sy 失败，继续尝试安装"
    if pacman -S --needed --noconfirm $packages >/dev/null 2>&1; then
        log "已安装或已存在全部目标包"
    else
        warn "批量安装失败，改为逐包尝试"
        missing=
        for pkg in $packages; do
            pacman -S --needed --noconfirm "$pkg" >/dev/null 2>&1 || missing="$missing $pkg"
        done
        if [ -n "$missing" ]; then
            warn "以下包安装失败，可在设备上手动补装：$missing"
        fi
    fi
    # 只清下载缓存；保留 sync 数据库，镜像离线时也能直接 pacman -S。
    rm -rf /var/cache/pacman/pkg/* 2>/dev/null || true
    return 0
}

# 2) pacman 镜像与并行下载：清华 TUNA 优先、阿里云备用。
step_pacman_mirrors() {
    if ! is_arch; then
        skip_step "非 Arch 系统，跳过镜像源配置"
        return 2
    fi
    if ! path_exists /etc/pacman.conf; then
        skip_step "/etc/pacman.conf 不存在"
        return 2
    fi

    if is_dir /etc/pacman.d; then
        # ALARM 与 x86_64 的镜像路径不同：ALARM 是 /archlinuxarm/$arch/$repo。
        case "$(uname -m)" in
            aarch64 | arm64)
                install_content /etc/pacman.d/mirrorlist 0644 <<'EOF' || return 1
## Droidspaces preferences: 清华 TUNA 优先，阿里云备用（Arch Linux ARM）
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/$arch/$repo
Server = https://mirrors.aliyun.com/archlinuxarm/$arch/$repo
EOF
                ;;
            *)
                install_content /etc/pacman.d/mirrorlist 0644 <<'EOF' || return 1
## Droidspaces preferences: 清华 TUNA 优先，阿里云备用
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinux/$repo/os/$arch
Server = https://mirrors.aliyun.com/archlinux/$repo/os/$arch
EOF
                ;;
        esac
    else
        warn "/etc/pacman.d 不存在，跳过 mirrorlist"
    fi

    # archlinuxcn 提供 paru、rime-ice-git 等 ALARM 官方源没有的包。
    # 首次以仓库级 SigLevel = Never 引导 keyring，装好后删掉这行恢复签名校验。
    if [ "$OFFLINE" = true ]; then
        log "offline: 跳过 archlinuxcn 仓库与 keyring 引导"
    elif ! grep -q '^\[archlinuxcn\]' "$ROOT/etc/pacman.conf" 2>/dev/null; then
        if [ "$DRY_RUN" = true ] || [ -n "$ROOT" ]; then
            log "dry-run: would add [archlinuxcn] repository and bootstrap its keyring"
        else
            {
                printf '\n[archlinuxcn]\n'
                printf 'SigLevel = Never\n'
                printf 'Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxcn/$arch\n'
                printf 'Server = https://repo.archlinuxcn.org/$arch\n'
            } >>"$ROOT/etc/pacman.conf"
            pacman-key --init >/dev/null 2>&1 || warn "pacman-key --init 失败"
            if pacman -Sy --noconfirm archlinux-keyring archlinuxcn-keyring >/dev/null 2>&1; then
                pacman_set_option LocalFileSigLevel 'PackageOptional' || true
                po_conf=$ROOT/etc/pacman.conf
                if new_tmp; then
                    awk '
                        /^\[archlinuxcn\]$/ { in_cn = 1 }
                        in_cn && /^SigLevel = Never$/ { next }
                        /^\[/ && $0 != "[archlinuxcn]" { in_cn = 0 }
                        { print }
                    ' "$po_conf" >"$nt_path" && cat "$nt_path" >"$po_conf"
                    drop_tmp
                fi
                log "已加入 archlinuxcn 仓库并安装 keyring"
            else
                warn "archlinuxcn-keyring 安装失败，保留 SigLevel = Never 以维持可用"
            fi
        fi
    fi

    pacman_set_option ParallelDownloads 10 || return 1
    pacman_set_option Color '' || return 1
    return 0
}

# 2b) archlinuxcn 的 AUR 助手：paru（Maple 字体与雾凇拼音的可选安装通道）。
step_archlinuxcn() {
    if ! is_arch || ! have_bin pacman; then
        skip_step "非 Arch 或无 pacman"
        return 2
    fi
    if [ "$OFFLINE" = true ]; then
        skip_step "PREFERENCES_OFFLINE=true"
        return 2
    fi
    if have_bin paru; then
        log "paru 已安装"
        return 0
    fi
    if [ "$DRY_RUN" = true ] || [ -n "$ROOT" ]; then
        log "dry-run: would install paru from archlinuxcn"
        return 0
    fi
    if pacman -S --needed --noconfirm paru >/dev/null 2>&1; then
        log "已安装 paru"
        return 0
    fi
    warn "paru 安装失败；Maple 字体与雾凇拼音将走镜像下载回退"
    return 0
}

# 2c) Maple Mono NF CN：仓库 → AUR → GitHub Release（走镜像）三级回退。
step_maple_font() {
    if ! is_arch; then
        skip_step "非 Arch 系统"
        return 2
    fi
    if fonts_have_maple; then
        log "Maple Mono 字体已存在"
        return 0
    fi
    if [ "$OFFLINE" = true ]; then
        skip_step "PREFERENCES_OFFLINE=true（跳过 Maple 字体下载/AUR）"
        return 2
    fi
    if [ "$DRY_RUN" = true ] || [ -n "$ROOT" ]; then
        log "dry-run: would install Maple Mono NF CN (repo -> AUR -> release)"
        return 0
    fi

    if pacman -S --needed --noconfirm ttf-maplemono-nf-cn >/dev/null 2>&1; then
        log "已从仓库安装 Maple Mono NF CN"
        return 0
    fi
    if have_bin paru && paru -S --needed --noconfirm ttf-maplemono-nf-cn >/dev/null 2>&1; then
        log "已从 AUR 安装 Maple Mono NF CN"
        return 0
    fi

    mf_zip=${TMPDIR:-/tmp}/MapleMono-NF-CN.zip
    mf_url=https://github.com/subframe7536/maple-font/releases/download/v7.9/MapleMono-NF-CN.zip
    if ! fetch_url "$mf_url" "$mf_zip"; then
        warn "Maple Mono NF CN 下载失败（$mf_url，经 ${GH_MIRROR_PREFIX}）"
        return 1
    fi
    install -d -m 0755 "$ROOT/usr/share/fonts/MapleMono"
    if command -v bsdtar >/dev/null 2>&1; then
        bsdtar -xf "$mf_zip" -C "$ROOT/usr/share/fonts/MapleMono/" || {
            warn "解压 Maple 字体失败"
            rm -f "$mf_zip"
            return 1
        }
    elif command -v unzip >/dev/null 2>&1; then
        unzip -q -o "$mf_zip" -d "$ROOT/usr/share/fonts/MapleMono/" || {
            warn "解压 Maple 字体失败"
            rm -f "$mf_zip"
            return 1
        }
    else
        warn "缺少 bsdtar/unzip，无法解压 Maple 字体"
        rm -f "$mf_zip"
        return 1
    fi
    rm -f "$mf_zip"
    fc-cache -f >/dev/null 2>&1 || true
    if fonts_have_maple; then
        log "已从 Release 安装 Maple Mono NF CN"
        return 0
    fi
    warn "Maple 字体安装后仍未注册到 fontconfig"
    return 1
}

# 2d) 雾凇拼音：archlinuxcn 的 rime-ice-git，失败则从 GitHub 镜像克隆。
step_rime_ice() {
    if ! is_arch; then
        skip_step "非 Arch 系统"
        return 2
    fi
    if path_exists /usr/share/rime-data/rime_ice.schema.yaml || \
        path_exists "$USER_HOME/.local/share/fcitx5/rime/rime_ice.schema.yaml"; then
        log "雾凇拼音已存在"
        rime_deploy_build
        return 0
    fi
    if [ "$OFFLINE" = true ]; then
        skip_step "PREFERENCES_OFFLINE=true（跳过 rime-ice 安装与克隆）"
        return 2
    fi
    if [ "$DRY_RUN" = true ] || [ -n "$ROOT" ]; then
        log "dry-run: would install rime-ice"
        return 0
    fi

    if pacman -S --needed --noconfirm rime-ice-git >/dev/null 2>&1; then
        log "已从 archlinuxcn 安装 rime-ice-git"
        rime_deploy_build
        return 0
    fi
    if [ -z "$USER_HOME" ] || ! have_bin git; then
        warn "无普通用户或 git，无法克隆 rime-ice"
        return 1
    fi
    ri_dir=$USER_HOME/.local/share/fcitx5/rime
    ri_src=$(gh_mirror_url https://github.com/iDvel/rime-ice)
    # 先克隆到临时目录再拷贝：目标目录里保留过 custom_phrase.txt 时，直接
    # git clone 到非空目录必然失败；同时避免留下 root 属主的半成品目录。
    ri_stage=$(mktemp -d "${TMPDIR:-/tmp}/rime-ice.XXXXXX") || {
        warn "mktemp 失败，无法克隆 rime-ice"
        return 1
    }
    prepare_user_parent "$ri_dir/x" || true
    if git clone --depth=1 "$ri_src" "$ri_stage/src" >/dev/null 2>&1; then
        if ! mkdir -p "$ROOT$ri_dir"; then
            rm -rf "$ri_stage"
            warn "无法创建 $ri_dir"
            return 1
        fi
        # 旧用户目录里的 rime-ice 文件会遮蔽共享数据；保留自定义短语。
        find "$ROOT$ri_dir" -mindepth 1 -maxdepth 1 ! -name custom_phrase.txt \
            -exec rm -rf {} + 2>/dev/null || true
        cp -a "$ri_stage/src/." "$ROOT$ri_dir/" || {
            rm -rf "$ri_stage"
            warn "复制 rime-ice 到用户目录失败"
            return 1
        }
        rm -rf "$ri_stage"
        chown -R "$USER_UID:$USER_GID" "$ROOT$ri_dir" 2>/dev/null || true
        log "已从 GitHub 镜像克隆雾凇拼音到 $ri_dir"
        rime_deploy_build
        return 0
    fi
    rm -rf "$ri_stage"
    warn "rime-ice 克隆失败（$ri_src）"
    return 1
}

# 构建期显式部署 Rime：rime_deployer 需要“用户目录 / 共享数据 / 构建目录”
# 三个路径。留给首次登录部署会让用户在前几十秒看到“rime 没有候选词”。
rime_deploy_build() {
    rdb_user=$USER_HOME/.local/share/fcitx5/rime
    rdb_build=$rdb_user/build
    if [ -z "$USER_HOME" ]; then
        return 0
    fi
    # 用户目录不存在时先建出来：rime_deployer 需要它作为用户数据目录，
    # 旧实现在这里直接 return 0，构建期部署从未真正执行。
    if ! path_exists "$rdb_user"; then
        prepare_user_parent "$rdb_user/x" || true
        mkdir -p "$ROOT$rdb_user" 2>/dev/null || true
        chown "$USER_UID:$USER_GID" "$ROOT$rdb_user" 2>/dev/null || true
    fi
    if ! path_exists "$rdb_user"; then
        return 0
    fi
    if ! have_bin rime_deployer; then
        warn "未找到 rime_deployer，跳过构建期部署"
        return 0
    fi
    if [ "$DRY_RUN" = true ] || [ -n "$ROOT" ]; then
        log "dry-run: would run rime_deployer for $rdb_user"
        return 0
    fi
    if run_as_user "rime_deployer --build '$rdb_user' /usr/share/rime-data '$rdb_build'" >/dev/null 2>&1; then
        chown -R "$USER_UID:$USER_GID" "$ROOT$rdb_user" 2>/dev/null || true
        log "已部署 Rime 构建目录：$rdb_build（$(find "$ROOT$rdb_build" -type f 2>/dev/null | wc -l) 个文件）"
        return 0
    fi
    warn "rime_deployer 执行失败；首次登录时由 fcitx5 再部署"
    return 0
}

# 在 pacman.conf 的 [options] 段设置 key = value（value 为空表示裸开关）。
# 已有（含被注释的）同名项就地替换；完全没有才插到 [options] 之后。
pacman_set_option() {
    po_key=$1
    po_value=$2
    po_full=$ROOT/etc/pacman.conf
    if ! new_tmp; then
        fail_step "mktemp 失败"
        return 1
    fi
    po_tmp=$nt_path
    po_pattern="^[[:space:]]*#?[[:space:]]*${po_key}([[:space:]]|=|\$)"
    if grep -qE "$po_pattern" "$po_full" 2>/dev/null; then
        if ! awk -v pat="$po_pattern" -v k="$po_key" -v v="$po_value" '
            BEGIN { done = 0 }
            {
                if (!done && $0 ~ pat) {
                    if (v == "") print k; else print k " = " v
                    done = 1
                    next
                }
                print
            }
        ' "$po_full" >"$po_tmp"; then
            drop_tmp "$po_tmp"
            fail_step "解析 /etc/pacman.conf 失败"
            return 1
        fi
    else
        if ! awk -v k="$po_key" -v v="$po_value" '
            { print }
            !done && /^\[options\]/ {
                if (v == "") print k; else print k " = " v
                done = 1
            }
            END {
                if (!done) {
                    if (v == "") print k; else print k " = " v
                }
            }
        ' "$po_full" >"$po_tmp"; then
            drop_tmp "$po_tmp"
            fail_step "解析 /etc/pacman.conf 失败"
            return 1
        fi
    fi
    install_content /etc/pacman.conf 0644 <"$po_tmp"
    po_rc=$?
    drop_tmp "$po_tmp"
    return $po_rc
}

# 3) 中文 locale 与用户会话语言。
step_locale() {
    if locale_zh_available; then
        log "zh_CN.UTF-8 已可用"
    elif have_bin locale-gen; then
        if ! grep -qxF 'zh_CN.UTF-8 UTF-8' "$ROOT/etc/locale.gen" 2>/dev/null; then
            append_line_once /etc/locale.gen 'zh_CN.UTF-8 UTF-8' || return 1
        fi
        if [ "$DRY_RUN" = true ] || [ -n "$ROOT" ]; then
            log "dry-run: would run locale-gen"
        elif locale-gen >/dev/null 2>&1; then
            log "已生成 zh_CN.UTF-8"
        else
            warn "locale-gen 失败"
        fi
    else
        skip_step "zh_CN.UTF-8 未生成且无 locale-gen（可用 -g true 构建）"
        return 2
    fi

    if ! locale_zh_available; then
        skip_step "zh_CN.UTF-8 仍不可用，跳过用户语言设置"
        return 2
    fi
    if [ -z "$USER_HOME" ]; then
        skip_step "未找到普通用户"
        return 2
    fi
    LOCALE_ZH_APPLIED=true
    install_content "$USER_HOME/.config/environment.d/locale.conf" 0644 <<'EOF' || return 1
# 由 droidspaces-preferences 生成：只设 LANG，单项分类仍可单独覆盖。
LANG=zh_CN.UTF-8
EOF
    return 0
}

# 4) 用户会话环境变量：暗色 GTK、Wayland 输入法。
step_environment() {
    if [ -z "$USER_HOME" ]; then
        skip_step "未找到普通用户"
        return 2
    fi
    installed_any=false

    if gtk3_present; then
        install_asset "$USER_HOME/.config/environment.d/gtk.conf" environment.d/gtk.conf 0644 || return 1
        # 会话是 system unit，只读 /etc/environment；environment.d 只对
        # systemd 用户实例（D-Bus 激活的服务）生效，两边都要写。
        set_etc_environment GTK_THEME "Adwaita:dark" || return 1
        installed_any=true
    else
        warn "未检测到 GTK3，跳过 GTK_THEME=Adwaita:dark"
    fi

    if have_bin fcitx5; then
        install_asset "$USER_HOME/.config/environment.d/input.conf" environment.d/input.conf 0644 || return 1
        set_etc_environment XMODIFIERS "@im=fcitx" || return 1
        set_etc_environment INPUT_METHOD "fcitx" || return 1
        installed_any=true
    else
        warn "未检测到 fcitx5，跳过输入法环境变量"
    fi

    # droidspaces 会把宿主的 TMPDIR=/data/local/tmp 带进容器，该路径在容器里
    # 不存在：Chromium 的 ProcessSingleton 建临时 socket 目录失败后直接退出，
    # 表现就是“双击浏览器没反应”。会话脚本也导出了同一个值，这里保证
    # 非会话路径（systemd 用户服务）同样正确。
    set_etc_environment TMPDIR "/tmp" || return 1
    installed_any=true

    if [ "$installed_any" = false ]; then
        skip_step "未安装 GTK3/fcitx5，无可应用的环境变量"
        return 2
    fi
    return 0
}

# 5) 字体渲染：等宽别名、CJK 回退、RGB 子像素。
step_fontconfig() {
    if [ -z "$USER_HOME" ]; then
        skip_step "未找到普通用户"
        return 2
    fi
    if ! is_dir /etc/fonts; then
        skip_step "/etc/fonts 不存在（fontconfig 未安装）"
        return 2
    fi
    install_asset "$USER_HOME/.config/fontconfig/fonts.conf" fontconfig/fonts.conf 0644 || return 1
    log "提示：字体缓存由登录会话重建，构建期不执行 fc-cache"
    return 0
}

# xring-o3 容器没有用户命名空间，bwrap 建不了 namespace；glycin 用它启动
# SVG 加载器，加载器失败后 GTK 加载任意 SVG 图标都会 assert 并 abort
# （Nemo 启动即崩在这里）。装一个跳过沙箱参数的 bwrap 包装器，等价于
# glycin 文档里的“无沙箱”回退路径。只在设备档案存在时安装，避免影响
# 其他设备上本来可用的沙箱。
ensure_bwrap_fallback() {
    if ! is_dir /usr/local/lib/droidspaces/device/xring-o3; then
        return 0
    fi
    if ! have_bin bwrap; then
        return 0
    fi
    if [ -x /usr/local/bin/bwrap ] && head -1 /usr/local/bin/bwrap 2>/dev/null | grep -q '^#!/bin/sh'; then
        return 0
    fi
    install_content /usr/local/bin/bwrap 0755 <<'EOF_BWRAP' || return 1
#!/bin/sh
# 由 droidspaces-preferences 生成：容器内 bwrap 无法建立 namespace，
# 跳过沙箱参数直接执行目标程序（glycin 的 SVG 加载器依赖这个回退）。
while [ $# -gt 0 ]; do
    case "$1" in
        --seccomp|--dbus-fd|--setenv|--bind|--bind-try|--ro-bind|--ro-bind-try|\
--dev-bind|--dev-bind-try|--symlink|--chdir|--dev|--tmpfs|--proc|--dir|--file|\
--remount-ro|--unsetenv)
            shift 2 ;;
        --*) shift ;;
        *) [ -f "$1" ] && [ -x "$1" ] && exec "$@" ; shift ;;
    esac
done
exit 1
EOF_BWRAP
    log "已安装 bwrap 回退包装器（glycin SVG 加载器）"
    return 0
}

# 6) GTK 字体与暗色主题：仅在 Maple Mono NF CN 已安装时写入。
step_gtk_settings() {
    if [ -z "$USER_HOME" ]; then
        skip_step "未找到普通用户"
        return 2
    fi
    if ! gtk3_present; then
        skip_step "未安装 GTK3"
        return 2
    fi
    if ! fonts_have_maple; then
        log "未安装 Maple Mono NF CN：GTK 仍写入，字体由 fontconfig 回退"
    fi
    ensure_bwrap_fallback || return 1
    install_asset "$USER_HOME/.config/gtk-3.0/settings.ini" gtk-3.0/settings.ini 0644 || return 1
    install_asset "$USER_HOME/.config/gtk-3.0/gtk.css" gtk-3.0/gtk.css 0644 || return 1
    install_asset "$USER_HOME/.config/gtk-4.0/settings.ini" gtk-4.0/settings.ini 0644 || return 1
    return 0
}

# 7) kitty：Catppuccin Frappé、Maple 字体、半透明与模糊。
step_kitty() {
    if [ -z "$USER_HOME" ]; then
        skip_step "未找到普通用户"
        return 2
    fi
    if ! have_bin kitty; then
        skip_step "未安装 kitty"
        return 2
    fi
    if have_bin fish; then
        kitty_expr="s/@FONT_SIZE@/$FONT_SIZE/g"
    else
        kitty_expr="s|^shell /usr/bin/fish|# shell /usr/bin/fish|;s/@FONT_SIZE@/$FONT_SIZE/g"
    fi
    install_asset "$USER_HOME/.config/kitty/themes/frappe.conf" kitty/themes/frappe.conf 0644 || return 1
    install_asset "$USER_HOME/.config/kitty/kitty.conf" kitty/kitty.conf 0644 "$kitty_expr" || return 1
    return 0
}

# 8) fish 配置；tide/reef 插件本身需联网安装，未安装时跳过对应项。
step_fish() {
    if [ -z "$USER_HOME" ]; then
        skip_step "未找到普通用户"
        return 2
    fi
    if ! have_bin fish; then
        skip_step "未安装 fish"
        return 2
    fi
    install_asset "$USER_HOME/.config/fish/config.fish" fish/config.fish 0644 || return 1
    install_asset "$USER_HOME/.config/fish/conf.d/theme.fish" fish/conf.d/theme.fish 0644 || return 1
    install_asset "$USER_HOME/.config/fish/conf.d/fastfetch.fish" fish/conf.d/fastfetch.fish 0644 || return 1
    install_asset "$USER_HOME/.config/fish/conf.d/reef.fish" fish/conf.d/reef.fish 0644 || return 1
    install_asset "$USER_HOME/.config/fish/conf.d/mirrors.fish" fish/conf.d/mirrors.fish 0644 || return 1

    tide_present=false
    if path_exists "$USER_HOME/.config/fish/functions/tide.fish"; then
        tide_present=true
    fi
    if path_exists /usr/share/fish/vendor_functions.d/tide.fish; then
        tide_present=true
    fi
    if [ "$tide_present" = false ]; then
        if [ "$DRY_RUN" = true ] || [ -n "$ROOT" ]; then
            log "dry-run: would install fisher and tide from the GitHub mirror"
        elif [ "$OFFLINE" != true ] && have_bin fish; then
            ft_tmp=${TMPDIR:-/tmp}/fisher.fish
            if fetch_url https://raw.githubusercontent.com/jorgebucaran/fisher/main/functions/fisher.fish "$ft_tmp"; then
                chmod 0644 "$ft_tmp" 2>/dev/null || true
                run_as_user "git config --global url.${GH_MIRROR_PREFIX%/}/https://github.com/.insteadOf https://github.com/" >/dev/null 2>&1 || true
                if run_as_user "fish -c 'source $ft_tmp; fisher install jorgebucaran/fisher ilancosman/tide@v6'" >/dev/null 2>&1; then
                    run_as_user "git config --global --unset-all url.${GH_MIRROR_PREFIX%/}/https://github.com/.insteadOf" >/dev/null 2>&1 || true
                    tide_present=true
                    log "已安装 fisher 与 tide（经 ${GH_MIRROR_PREFIX}）"
                else
                    warn "fisher/tide 安装失败，跳过 tide 配置"
                fi
                rm -f "$ft_tmp"
            else
                warn "fisher.fish 下载失败（经 ${GH_MIRROR_PREFIX}），跳过 tide 配置"
            fi
        fi
        if [ "$tide_present" = false ]; then
            warn "未检测到 tide，跳过 tide-apply.fish（安装 tide 后重跑本脚本即可）"
            return 0
        fi
    fi
    install_asset "$USER_HOME/.config/fish/tide-apply.fish" fish/tide-apply.fish 0755 || return 1
    if [ "$DRY_RUN" = true ] || [ -n "$ROOT" ]; then
        run_as_user "fish --no-config $USER_HOME/.config/fish/tide-apply.fish"
        return 0
    fi
    if run_as_user "fish --no-config $USER_HOME/.config/fish/tide-apply.fish"; then
        log "已写入 tide universal 变量"
    else
        warn "tide 配置脚本执行失败，可在设备上运行 fish ~/.config/fish/tide-apply.fish"
    fi
    return 0
}

# 9) fcitx5 + Rime：开机激活、默认 rime、候选 7 个。
step_fcitx5() {
    if [ -z "$USER_HOME" ]; then
        skip_step "未找到普通用户"
        return 2
    fi
    if ! have_bin fcitx5; then
        skip_step "未安装 fcitx5"
        return 2
    fi

    install_asset "$USER_HOME/.config/fcitx5/config" fcitx5/config 0644 || return 1
    install_asset "$USER_HOME/.config/fcitx5/profile" fcitx5/profile 0644 || return 1

    if path_exists "$USER_HOME/.local/share/fcitx5/themes/catppuccin-mocha-mauve"; then
        install_asset "$USER_HOME/.config/fcitx5/conf/classicui.conf" fcitx5/conf/classicui.conf 0644 || return 1
    else
        log "未安装 catppuccin-mocha-mauve 主题，classicui 仅写 DPI 设置"
        install_content "$USER_HOME/.config/fcitx5/conf/classicui.conf" 0644 <<'EOF' || return 1
[Theme]
PerScreenDPI=True
EOF
    fi

    if path_exists /usr/share/rime-data/rime_ice.schema.yaml || \
        path_exists /usr/share/rime-data/rime_ice.base.dict.yaml || \
        path_exists "$USER_HOME/.local/share/fcitx5/rime/rime_ice.schema.yaml" || \
        path_exists "$USER_HOME/.local/share/fcitx5/rime/rime_ice.base.dict.yaml"; then
        install_asset "$USER_HOME/.local/share/fcitx5/rime/default.custom.yaml" \
            fcitx5/rime/default.custom.yaml 0644 || return 1
        # 部署必须在 default.custom.yaml 落盘之后，否则 page_size 不生效。
        rime_deploy_build
    else
        warn "未安装雾凇拼音（rime-ice），跳过 default.custom.yaml 以避免 Rime 部署失败"
    fi

    # D-Bus 激活 fcitx5 时拿不到会话的 WAYLAND_DISPLAY（systemd 用户实例的
    # 环境在登录时就固定了），fcitx5 会报 "Failed to open wayland connection"
    # 却仍然抢走 org.fcitx.Fcitx5，niri 拉起的实例随即退出，输入法没有候选词。
    # 用系统级 dbus service 覆盖包里的那份，改走先探测 Wayland socket 的包装器。
    install_content /usr/local/bin/fcitx5-dbus 0755 <<'EOF_DBUS' || return 1
#!/bin/sh
# 由 droidspaces-preferences 生成。两个职责：
# 1) D-Bus 激活的 fcitx5 拿不到会话环境，这里从 XDG_RUNTIME_DIR 挑 Wayland socket；
# 2) niri spawn 的实例启动需要约 1 秒，期间若有应用请求输入法会触发激活，
#    于是并存两份。先等总线名出现（最多 4 秒），出现就退出，交给已运行的实例。
if command -v busctl >/dev/null 2>&1; then
    i=0
    while [ "$i" -lt 20 ]; do
        if busctl --user status org.fcitx.Fcitx5 >/dev/null 2>&1; then
            exit 0
        fi
        sleep 0.2
        i=$((i + 1))
    done
fi
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    for s in "$XDG_RUNTIME_DIR"/wayland-?; do
        [ -S "$s" ] || continue
        WAYLAND_DISPLAY=${s##*/}
        export WAYLAND_DISPLAY
        break
    done
fi
exec /usr/bin/fcitx5 "$@"
EOF_DBUS
    # 放在 /usr/local/share 而不是用户目录：会话总线不保证把
    # $XDG_DATA_HOME/dbus-1/services 纳入搜索路径；/usr/local/share 一定在
    # XDG_DATA_DIRS 里且排在 /usr/share 之前，可以覆盖包里的那份。
    install_content /usr/local/share/dbus-1/services/org.fcitx.Fcitx5.service 0644 <<'EOF_SVC' || return 1
[D-BUS Service]
Name=org.fcitx.Fcitx5
Exec=/usr/local/bin/fcitx5-dbus
EOF_SVC

    # fcitx5 只保留一个启动入口：niri 的 spawn-at-startup（带 WAYLAND_DISPLAY）。
    # systemd 用户实例会把 ~/.config/autostart 与 /etc/xdg/autostart 里两份
    # fcitx5 都拉起来，而且没有 Wayland 连接；它们抢走 org.fcitx.Fcitx5 后，
    # niri 拉起的实例退出，输入法就没有候选词。这里删掉用户副本，并用
    # Hidden=true 覆盖系统那份。
    if [ -f "$ROOT$USER_HOME/.config/autostart/fcitx5.desktop" ]; then
        if [ "$DRY_RUN" = true ]; then
            log "dry-run: would remove $USER_HOME/.config/autostart/fcitx5.desktop"
        else
            backup_file "$USER_HOME/.config/autostart/fcitx5.desktop" || true
            rm -f "$ROOT$USER_HOME/.config/autostart/fcitx5.desktop"
            log "已移除重复的 fcitx5 autostart 入口"
        fi
    fi
    install_content "$USER_HOME/.config/autostart/org.fcitx.Fcitx5.desktop" 0644 <<'EOF_HIDDEN' || return 1
[Desktop Entry]
Type=Application
Name=Fcitx5 (disabled by droidspaces-preferences)
Comment=由 niri spawn-at-startup 启动，避免 systemd 用户实例抢总线名
Exec=/bin/true
Hidden=true
NoDisplay=true
EOF_HIDDEN
    return 0
}

# 10) Nemo 默认文件管理器与「在终端中打开」。
step_nemo() {
    if [ -z "$USER_HOME" ]; then
        skip_step "未找到普通用户"
        return 2
    fi
    if ! path_exists /usr/share/applications/nemo.desktop && ! have_bin nemo; then
        skip_step "未安装 Nemo"
        return 2
    fi

    merge_mimeapps || return 1

    if ! have_bin kitty; then
        warn "未安装 kitty，跳过 xdg-terminal-exec 与 Nemo 终端动作"
        return 0
    fi
    # xdg-terminal-exec 读取 ~/.config/xdg-terminal-exec/xdg-terminals.list；
    # 写成 terminal-exec 是死文件（GLib 启动 Terminal=true 应用时读不到）。
    install_asset "$USER_HOME/.config/xdg-terminal-exec/xdg-terminals.list" \
        xdg-terminal-exec/terminal-exec 0644 || return 1
    install_asset /usr/local/bin/open-terminal nemo/open-terminal 0755 || return 1
    if is_dir /usr/share/nemo/actions; then
        install_asset /usr/share/nemo/actions/open-terminal.nemo_action \
            nemo/open-terminal.nemo_action 0644 || return 1
    else
        warn "/usr/share/nemo/actions 不存在，跳过 Nemo 动作文件"
    fi
    return 0
}

merge_mimeapps() {
    mm_dest=$USER_HOME/.config/mimeapps.list
    if [ "$DRY_RUN" = true ]; then
        log "dry-run: would map inode/directory -> nemo.desktop in $mm_dest"
        return 0
    fi
    mm_full=$ROOT$mm_dest
    if ! new_tmp; then
        fail_step "mktemp 失败"
        return 1
    fi
    mm_tmp=$nt_path
    if [ -f "$mm_full" ]; then
        if ! awk '
            BEGIN { in_defaults = 0; written = 0 }
            /^\[/ {
                if (in_defaults && !written) { print "inode/directory=nemo.desktop"; written = 1 }
                in_defaults = ($0 == "[Default Applications]")
            }
            {
                if (in_defaults && $0 ~ /^inode\/directory=/) {
                    if (!written) { print "inode/directory=nemo.desktop"; written = 1 }
                    next
                }
                print
            }
            END { if (in_defaults && !written) print "inode/directory=nemo.desktop" }
        ' "$mm_full" >"$mm_tmp"; then
            drop_tmp "$mm_tmp"
            fail_step "解析 $mm_dest 失败"
            return 1
        fi
        if ! grep -q '^\[Default Applications\]' "$mm_tmp"; then
            if ! printf '%s\n' '[Default Applications]' 'inode/directory=nemo.desktop' >>"$mm_tmp"; then
                drop_tmp "$mm_tmp"
                fail_step "写入 $mm_dest 失败"
                return 1
            fi
        fi
    else
        if ! printf '%s\n' '[Default Applications]' 'inode/directory=nemo.desktop' >"$mm_tmp"; then
            drop_tmp "$mm_tmp"
            fail_step "写入 $mm_dest 失败"
            return 1
        fi
    fi
    install_content "$mm_dest" 0644 <"$mm_tmp"
    mm_rc=$?
    drop_tmp "$mm_tmp"
    return $mm_rc
}

# 11) Noctalia：顶栏铺满 + 外壳字体；既有配置不覆盖。
step_noctalia() {
    if [ -z "$USER_HOME" ]; then
        skip_step "未找到普通用户"
        return 2
    fi
    if ! have_bin noctalia && ! is_dir /usr/share/noctalia; then
        skip_step "未安装 Noctalia"
        return 2
    fi
    install_if_absent "$USER_HOME/.config/noctalia/config.toml" 0644 noctalia/config.toml
    return $?
}

# 12) niri 不读 XDG autostart：追加标记块保证 fcitx5 自启动。
step_niri_ime_autostart() {
    if [ -z "$USER_HOME" ]; then
        skip_step "未找到普通用户"
        return 2
    fi
    if ! have_bin fcitx5; then
        skip_step "未安装 fcitx5"
        return 2
    fi
    niri_config=$USER_HOME/.config/niri/config.kdl
    if ! path_exists "$niri_config"; then
        skip_step "未找到 niri config.kdl（由桌面 profile 负责）"
        return 2
    fi
    niri_full=$ROOT$niri_config
    if grep -q 'spawn-at-startup.*fcitx5' "$niri_full" 2>/dev/null; then
        log "unchanged: $niri_config（fcitx5 自启动已存在）"
        return 0
    fi
    if [ "$DRY_RUN" = true ]; then
        log "dry-run: would append fcitx5 spawn-at-startup block to $niri_config"
        return 0
    fi
    if ! backup_file "$niri_config"; then
        fail_step "备份失败：$niri_config"
        return 1
    fi
    {
        printf '%s\n' '' '// >>> droidspaces-preferences: 输入法自启动（systemd 用户 autostart 已屏蔽）'
        printf '%s\n' 'spawn-at-startup "fcitx5"'
        printf '%s\n' '// <<< droidspaces-preferences'
    } >>"$niri_full" || {
        fail_step "追加失败：$niri_config"
        return 1
    }
    log "appended: $niri_config（fcitx5 spawn-at-startup）"
    return 0
}

# 12b) niri 外观与行为：背景透明、焦点环、壁纸层规则、Noctalia 浮窗。
# 只写一次（带标记）；layout 段是单例，配置项插进已有 layout 块而不是新建。
niri_apply_extras() {
    nae_file=$1
    nae_full=$ROOT$nae_file
    if ! path_exists "$nae_file"; then
        return 2
    fi
    if grep -q 'droidspaces-preferences: niri 外观与行为' "$nae_full" 2>/dev/null; then
        log "unchanged: $nae_file（niri 外观块已存在）"
        return 0
    fi
    if [ "$DRY_RUN" = true ]; then
        log "dry-run: would add niri appearance block to $nae_file"
        return 0
    fi
    if ! backup_file "$nae_file"; then
        fail_step "备份失败：$nae_file"
        return 1
    fi
    if ! new_tmp; then
        fail_step "mktemp 失败"
        return 1
    fi
    nae_tmp=$nt_path
    # layout 段只能出现一次；background-color 插在 layout 开头，focus-ring 的值
    # 在已有块内就地替换（库存配置里 focus-ring 已经是活动节点，重复节点会解析失败）。
    # binds 段同理，只能插在已有 binds 块内。
    awk '
        BEGIN { layout_done = 0; in_fr = 0; fr_named = 0 }
        /^[[:space:]]*layout[[:space:]]*\{/ && !layout_done {
            print
            print "    background-color \"transparent\""
            layout_done = 1
            next
        }
        /^[[:space:]]*focus-ring[[:space:]]*\{/ && !in_fr {
            print
            in_fr = 1
            fr_named = 0
            next
        }
        in_fr && /^[[:space:]]*width[[:space:]]/ {
            print "        width 2"
            next
        }
        in_fr && /^[[:space:]]*active-color[[:space:]]/ {
            print "        active-color \"#8caaee99\""
            next
        }
        in_fr && /^[[:space:]]*inactive-color[[:space:]]/ {
            print "        inactive-color \"transparent\""
            fr_named = 1
            next
        }
        in_fr && /^[[:space:]]*\}/ {
            if (!fr_named) print "        inactive-color \"transparent\""
            print
            in_fr = 0
            next
        }
        { print }
    ' "$nae_full" >"$nae_tmp" || {
        drop_tmp
        fail_step "改写失败：$nae_file"
        return 1
    }
    {
        printf '%s\n' ''
        printf '%s\n' '// >>> droidspaces-preferences: niri 外观与行为（managed）'
        printf '%s\n' 'debug {'
        printf '%s\n' '    honor-xdg-activation-with-invalid-serial'
        printf '%s\n' '}'
        printf '%s\n' 'layer-rule {'
        printf '%s\n' '    match namespace="noctalia-wallpaper"'
        printf '%s\n' '    place-within-backdrop true'
        printf '%s\n' '}'
        printf '%s\n' 'window-rule {'
        printf '%s\n' '    match app-id="noctalia"'
        printf '%s\n' '    open-floating true'
        printf '%s\n' '}'
        printf '%s\n' 'window-rule {'
        printf '%s\n' '    draw-border-with-background false'
        printf '%s\n' '}'
        printf '%s\n' '// <<< droidspaces-preferences: niri 外观与行为'
    } >>"$nae_tmp" || {
        drop_tmp
        fail_step "追加失败：$nae_file"
        return 1
    }
    cat "$nae_tmp" >"$nae_full"
    drop_tmp
    nae_validator=
    if have_bin niri-anland; then
        nae_validator=niri-anland
    elif have_bin niri; then
        nae_validator=niri
    fi
    if [ -n "$nae_validator" ]; then
        if ! nae_err=$("$nae_validator" validate -c "$nae_full" 2>&1); then
            warn "$nae_file 校验失败，已回滚：$(printf '%s' "$nae_err" | tr '\n' ' ' | cut -c1-300)"
            if [ -n "${BACKUP_DIR:-}" ] && [ -f "$BACKUP_DIR$nae_file" ]; then
                cat "$BACKUP_DIR$nae_file" >"$nae_full"
            fi
            return 1
        fi
    fi
    log "appended: $nae_file（niri 外观块）"
    return 0
}

# 库存模板把终端绑定到未安装的 alacritty，并保留 waybar 自启动；早期版本给
# fcitx5 加过 `-r`，会与 D-Bus 激活的实例互相替换。三条都做幂等修正。
niri_fix_launchers() {
    nfl_file=$1
    nfl_full=$ROOT$nfl_file
    path_exists "$nfl_file" || return 2
    if ! grep -qE 'spawn(-sh)? +"alacritty"|: alacritty"|spawn-at-startup +"waybar"|spawn-at-startup +"fcitx5"' \
        "$nfl_full" 2>/dev/null; then
        return 0
    fi
    if [ "$DRY_RUN" = true ]; then
        log "dry-run: would fix launcher bindings in $nfl_file"
        return 0
    fi
    backup_file "$nfl_file" || return 1
    if ! new_tmp; then
        fail_step "mktemp 失败"
        return 1
    fi
    nfl_tmp=$nt_path
    sed -E \
        -e 's/spawn(-sh)? +"alacritty"/spawn\1 "kitty"/' \
        -e 's/: alacritty"/: kitty"/' \
        -e '/^[[:space:]]*spawn-at-startup +"waybar"/d' \
        -e 's/^([[:space:]]*spawn-at-startup +"fcitx5") +"-r"[[:space:]]*$/\1/' \
        "$nfl_full" >"$nfl_tmp" || {
        drop_tmp "$nfl_tmp"
        fail_step "改写失败：$nfl_file"
        return 1
    }
    cat "$nfl_tmp" >"$nfl_full"
    drop_tmp "$nfl_tmp"
    log "fixed: $nfl_file（alacritty→kitty、移除 waybar、fcitx5 去掉 -r）"
    return 0
}

step_niri_extra() {
    if [ -z "$USER_HOME" ]; then
        skip_step "未找到普通用户"
        return 2
    fi
    niri_fix_launchers "$USER_HOME/.config/niri/config.kdl" || true
    niri_fix_launchers /usr/local/share/droidspaces/niri-default-config.kdl || true
    niri_fix_launchers /etc/skel/.config/niri/config.kdl || true
    niri_apply_extras "$USER_HOME/.config/niri/config.kdl" || return $?
    niri_apply_extras /usr/local/share/droidspaces/niri-default-config.kdl || true
    return 0
}

# 13) 中文用户目录，仅在中文本地化生效时。
step_user_dirs() {
    if [ -z "$USER_HOME" ]; then
        skip_step "未找到普通用户"
        return 2
    fi
    if [ "$LOCALE_ZH_APPLIED" != true ]; then
        skip_step "中文 locale 未生效，保留默认用户目录"
        return 2
    fi
    install_asset "$USER_HOME/.config/user-dirs.dirs" xdg-user-dirs/user-dirs.dirs 0644 || return 1
    for dir_name in 桌面 下载 文档 图片 音乐 视频 模板 公共; do
        ud_full=$ROOT$USER_HOME/$dir_name
        if [ -d "$ud_full" ]; then
            continue
        fi
        if [ "$DRY_RUN" = true ]; then
            log "dry-run: would create $USER_HOME/$dir_name"
            continue
        fi
        if ! mkdir "$ud_full"; then
            warn "无法创建 $USER_HOME/$dir_name"
            continue
        fi
        if [ -z "$ROOT" ] && [ -n "$USER_UID" ]; then
            chown "$USER_UID:$USER_GID" "$ud_full" 2>/dev/null || warn "chown 失败：$USER_HOME/$dir_name"
        fi
    done
    return 0
}

# 14) 电源服务：Noctalia 电池图标依赖 UPower 的 D-Bus 接口。
step_services() {
    if ! have_bin upower; then
        skip_step "未安装 upower"
        return 2
    fi
    sv_unit=/usr/lib/systemd/system/upower.service
    if ! path_exists "$sv_unit"; then
        sv_unit=/lib/systemd/system/upower.service
    fi
    if ! path_exists "$sv_unit"; then
        skip_step "upower.service 单元不存在"
        return 2
    fi
    sv_link=/etc/systemd/system/multi-user.target.wants/upower.service
    if [ -L "$ROOT$sv_link" ]; then
        log "unchanged: $sv_link"
        return 0
    fi
    if [ "$DRY_RUN" = true ]; then
        log "dry-run: would enable upower.service"
        return 0
    fi
    if ! mkdir -p "$ROOT/etc/systemd/system/multi-user.target.wants"; then
        fail_step "无法创建 wants 目录"
        return 1
    fi
    if ! ln -sf "$sv_unit" "$ROOT$sv_link"; then
        fail_step "无法启用 upower.service"
        return 1
    fi
    log "enabled: upower.service"
    return 0
}

# ---------------------------------------------------------------- 清单

write_manifest() {
    wm_status=$1
    if [ "$DRY_RUN" = true ]; then
        log "dry-run: would write $MANIFEST (status=$wm_status)"
        return 0
    fi
    mkdir -p "$STATE_DIR" || return 1
    wm_tmp=$MANIFEST.tmp
    {
        printf '%s\n' '# 由 apply-preferences.sh 生成；PROFILE 与 VERSION 均匹配时跳过重复应用。'
        printf 'PREFERENCES_PROFILE=%s\n' "$(env_quote "$PROFILE")"
        printf 'PREFERENCES_VERSION=%s\n' "$(env_quote "$PREFERENCES_VERSION")"
        printf 'PREFERENCES_TIMESTAMP=%s\n' "$(env_quote "$TIMESTAMP")"
        printf 'PREFERENCES_STATUS=%s\n' "$(env_quote "$wm_status")"
        printf 'PREFERENCES_APPLIED_STEPS=%s\n' "$(env_quote "$APPLIED")"
        printf 'PREFERENCES_SKIPPED_STEPS=%s\n' "$(env_quote "$SKIPPED")"
        printf 'PREFERENCES_FAILED_STEPS=%s\n' "$(env_quote "$FAILED")"
        printf 'PREFERENCES_WARNINGS=%s\n' "$(env_quote "$WARNINGS")"
        printf 'PREFERENCES_BACKUP_DIR=%s\n' "$(env_quote "$BACKUP_DIR")"
        printf 'PREFERENCES_BACKUP_FILES=%s\n' "$(env_quote "$BACKUP_COUNT")"
        printf 'PREFERENCES_USER=%s\n' "$(env_quote "$USER_NAME")"
        printf 'PREFERENCES_STRICT=%s\n' "$(env_quote "$STRICT")"
    } >"$wm_tmp" || {
        rm -f "$wm_tmp"
        return 1
    }
    mv -f "$wm_tmp" "$MANIFEST" || {
        rm -f "$wm_tmp"
        return 1
    }
    log "manifest: $MANIFEST（status=$wm_status）"
    return 0
}

manifest_value() {
    sed -n "s/^$1=//p" "$MANIFEST" 2>/dev/null | head -n1 | tr -d "'"
}

# ---------------------------------------------------------------- 主流程

if APPLY_PREFERENCES=$(normalize_bool "${APPLY_PREFERENCES:-false}"); then :; else
    printf '%s\n' "[preferences] APPLY_PREFERENCES=${APPLY_PREFERENCES:-} 不是布尔值，按 false 处理" >&2
    APPLY_PREFERENCES=false
fi
if STRICT=$(normalize_bool "${PREFERENCES_STRICT:-false}"); then :; else
    printf '%s\n' "[preferences] PREFERENCES_STRICT=${PREFERENCES_STRICT:-} 不是布尔值，按 false 处理" >&2
    STRICT=false
fi
if DRY_RUN=$(normalize_bool "${PREFERENCES_DRY_RUN:-false}"); then :; else
    printf '%s\n' "[preferences] PREFERENCES_DRY_RUN=${PREFERENCES_DRY_RUN:-} 不是布尔值，按 false 处理" >&2
    DRY_RUN=false
fi
if INSTALL_PACKAGES=$(normalize_bool "${PREFERENCES_INSTALL_PACKAGES:-true}"); then :; else
    INSTALL_PACKAGES=true
fi
if OFFLINE=$(normalize_bool "${PREFERENCES_OFFLINE:-false}"); then :; else
    OFFLINE=false
fi
# 设备上手工重跑（修配置、补包）用 PREFERENCES_FORCE=true 绕开版本标记。
if FORCE=$(normalize_bool "${PREFERENCES_FORCE:-false}"); then :; else
    FORCE=false
fi

if [ "$APPLY_PREFERENCES" != true ]; then
    printf '%s\n' '[preferences] APPLY_PREFERENCES=false：跳过偏好设置'
    exit 0
fi

TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
BACKUP_DIR=$STATE_DIR/backup/$TIMESTAMP
LOG_FILE=$ROOT/var/log/droidspaces-preferences.log
if [ "$DRY_RUN" = true ] || [ ! -d "$ROOT/var/log" ]; then
    LOG_FILE=${TMPDIR:-/tmp}/droidspaces-preferences.log
fi

log "启动：profile=$PROFILE version=$PREFERENCES_VERSION strict=$STRICT dry_run=$DRY_RUN"

if [ -f "$MANIFEST" ]; then
    marker_profile=$(manifest_value PREFERENCES_PROFILE)
    marker_version=$(manifest_value PREFERENCES_VERSION)
    marker_status=$(manifest_value PREFERENCES_STATUS)
    # 只有上次完整成功才跳过：partial 说明有步骤失败，必须重试。
    if [ "$FORCE" != true ] && [ "$marker_profile" = "$PROFILE" ] && \
        [ "$marker_version" = "$PREFERENCES_VERSION" ] && [ "$marker_status" = applied ]; then
        log "已应用相同 profile+version（$PROFILE@$PREFERENCES_VERSION），跳过"
        exit 0
    fi
    log "检测到旧标记（${marker_profile:-unknown}@${marker_version:-unknown}/${marker_status:-unknown}），重新应用"
fi

if detect_user; then
    log "目标用户：$USER_NAME（$USER_HOME）"
else
    warn "未找到 uid>=1000 的普通用户，用户级步骤将被跳过"
fi

STEPS="pacman_mirrors archlinuxcn packages maple_font rime_ice locale environment fontconfig gtk_settings kitty fish fcitx5 nemo noctalia niri_ime_autostart niri_extra user_dirs services"

for step in $STEPS; do
    STEP_NAME=$step
    STEP_REASON=
    step_rc=0
    "step_$step" || step_rc=$?
    if [ "$step_rc" -eq 0 ]; then
        add_applied "$step"
    elif [ "$step_rc" -eq 2 ]; then
        add_skipped "$step: ${STEP_REASON:-已跳过}"
    else
        add_failed "$step: ${STEP_REASON:-未知错误}"
        if [ "$STRICT" = true ]; then
            write_manifest failed || true
            log "PREFERENCES_STRICT=true：步骤 $step 失败，终止"
            exit 1
        fi
        warn "步骤 $step 失败：${STEP_REASON:-未知错误}；已按非严格模式继续"
    fi
done

# 构建期以 root 写入的用户目录统一交还给用户，修复旧镜像里 root 属主的
# ~/.local（Chrome/Qt 应用因此写不了 ~/.local/share）。
fix_user_ownership

if [ -n "$FAILED" ]; then
    status=partial
else
    status=applied
fi
write_manifest "$status" || warn "写入 manifest 失败"

log "完成：applied=[$APPLIED]"
log "完成：skipped=[$SKIPPED]"
if [ -n "$FAILED" ]; then
    log "完成：failed=[$FAILED]"
fi
if [ "$BACKUP_COUNT" -gt 0 ]; then
    log "备份文件数：$BACKUP_COUNT（$BACKUP_DIR）"
fi
exit 0
