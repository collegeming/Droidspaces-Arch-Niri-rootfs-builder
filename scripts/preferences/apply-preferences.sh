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

PREFERENCES_VERSION=2026.11.10

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

# 统计花括号净值（忽略 "" 字符串与 // 注释）；供 niri 配置改写后做平衡自检。
brace_sum() {
    awk '
        {
            line = $0
            kept = ""
            quoted = 0
            for (i = 1; i <= length(line); i++) {
                c = substr(line, i, 1)
                if (quoted) {
                    if (c == "\"") quoted = 0
                    continue
                }
                if (c == "\"") { quoted = 1; continue }
                if (c == "/" && substr(line, i + 1, 1) == "/") break
                kept = kept c
            }
            nopen = gsub(/{/, "{", kept)
            nclose = gsub(/}/, "}", kept)
            sum += nopen - nclose
        }
        END { printf "%d\n", sum + 0 }
    ' "$1"
}

# 为一次改写建立"本函数动手前"的回滚基线，结果写入全局 rb_path。
# BACKUP_DIR 里放的是该文件本次运行的首次备份：若同一文件在本次运行里已被
# 前面的步骤改过（例如 niri_fix_launchers 已迁移 fcitx5 自启动），从备份恢复
# 会把那些修改一并抹掉，所以回滚必须用调用前的即时快照。
rollback_snapshot() {
    if ! new_tmp; then
        return 1
    fi
    rb_path=$nt_path
    if ! cat "$1" >"$rb_path" 2>/dev/null; then
        drop_tmp "$rb_path"
        rb_path=
        return 1
    fi
    return 0
}

# 用基线恢复；基线不可用时才退回 BACKUP_DIR<原路径>。
restore_snapshot() {
    if [ -n "${1:-}" ] && [ -f "$1" ]; then
        cat "$1" >"$2" && return 0
    fi
    if [ -n "${BACKUP_DIR:-}" ] && [ -f "$BACKUP_DIR$3" ]; then
        cat "$BACKUP_DIR$3" >"$2" && return 0
    fi
    return 1
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

# 从 /etc/environment 按键名删行（保留其它行）。fcitx5 在 Wayland 下按
# XMODIFIERS/INPUT_METHOD 自动探测，历史镜像里写死的 GTK_IM_MODULE/QT_IM_MODULE
# 会让 GTK4/Qt6 退回旧路径，必须清掉。
unset_etc_environment() {
    uee_key=$1
    uee_full=$ROOT/etc/environment
    [ -f "$uee_full" ] || return 0
    grep -qE "^[[:space:]]*(export[[:space:]]+)?$uee_key[[:space:]]*=" "$uee_full" 2>/dev/null || return 0
    if [ "$DRY_RUN" = true ]; then
        log "dry-run: would drop $uee_key from /etc/environment"
        return 0
    fi
    if ! new_tmp; then
        fail_step "mktemp 失败"
        return 1
    fi
    uee_tmp=$nt_path
    if ! awk -v k="$uee_key" '
        $0 ~ "^[[:space:]]*(export[[:space:]]+)?" k "[[:space:]]*=" { next }
        { print }
    ' "$uee_full" >"$uee_tmp"; then
        drop_tmp "$uee_tmp"
        fail_step "解析 /etc/environment 失败"
        return 1
    fi
    install_content /etc/environment 0644 <"$uee_tmp"
    uee_rc=$?
    drop_tmp "$uee_tmp"
    return $uee_rc
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

# 可用性只看系统 locale 列表；/etc/locale.conf 只代表会话配置，不能当作可用。
locale_zh_available() {
    command -v locale >/dev/null 2>&1 || return 1
    locale -a 2>/dev/null | grep -qi '^zh_CN\.utf-\?8$'
}

# 会话是否真的生效：systemd 会话读 /etc/locale.conf 里实际的 LANG= 值。
locale_zh_configured() {
    lzc_lang=$(sed -n 's/^[[:space:]]*LANG=//p' "$ROOT/etc/locale.conf" 2>/dev/null | tail -n1 | tr -d '"')
    case $lzc_lang in
        zh_CN.UTF-8 | zh_CN.utf8 | zh_CN.utf-8) return 0 ;;
    esac
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

    # 对应文档 02:126（可选）：Qt 翻译包由脚本尝试安装，缺失不判失败。
    # 末行是 reef 工具包（搜索/查看/跳转类 CLI），缺失只 warn，不进必需包断言。
    packages="noto-fonts noto-fonts-cjk noto-fonts-emoji ttf-jetbrains-mono
fcitx5 fcitx5-chinese-addons fcitx5-rime fcitx5-configtool fcitx5-gtk fcitx5-qt
kitty fish fastfetch nemo nemo-fileroller gvfs gvfs-mtp cinnamon-translations
upower qt5-wayland qt6-wayland qt5-translations qt6-translations neovim
wl-clipboard xdg-utils xdg-user-dirs xdg-terminal-exec
ripgrep fd sd dust procs eza bat zoxide"

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
    # 批量安装会吞掉单包错误，这里断言文档要求的必需包真的在位。
    # 离线构建看不到真实软件源，只记为跳过/警告，不把产物判成失败。
    req_missing=
    for pkg in kitty fish nemo fcitx5 fcitx5-rime; do
        pacman -Q "$pkg" >/dev/null 2>&1 || req_missing="$req_missing $pkg"
    done
    if [ -n "$req_missing" ]; then
        if [ "$OFFLINE" = true ]; then
            warn "离线构建缺少必需包：$req_missing"
            skip_step "离线构建，跳过必需包校验"
            return 2
        fi
        fail_step "缺少必需包：$req_missing"
        return 1
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

    # LocalFileSigLevel 必须无条件设置：除了 archlinuxcn 引导，本地 .pkg.tar.zst
    # 安装（离线补包）也需要放行缺失签名，不能只在首次添加 archlinuxcn 时设置。
    pacman_set_option LocalFileSigLevel 'PackageOptional' || return 1

    if is_dir /etc/pacman.d; then
        # ALARM 与 x86_64 的镜像路径不同：ALARM 是 /archlinuxarm/$arch/$repo。
        case "$(uname -m)" in
            aarch64 | arm64)
                install_content /etc/pacman.d/mirrorlist 0644 <<'EOF' || return 1
## Droidspaces preferences: 清华 TUNA 优先，阿里云备用（Arch Linux ARM）
Server = https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/$arch/$repo
Server = https://mirrors.aliyun.com/archlinuxarm/$arch/$repo
# 官方 ALARM 源兜底：镜像同步滞后或 404 时仍能安装
Server = https://mirror.archlinuxarm.org/$arch/$repo
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
                printf 'Server = https://mirrors.ustc.edu.cn/archlinuxcn/$arch\n'
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

# 用 makepkg 构建 AUR 包再以 root 安装。paru 拒绝 root 运行（镜像构建和
# 设备上重跑都是 root），所以这里用一次性构建用户完成编译，避免为此开放
# 免密 pacman 权限。返回 0 表示已安装或已存在。
aur_build_install() {
    abi_pkg=$1
    if pacman -Qq "$abi_pkg" >/dev/null 2>&1; then
        log "AUR 包已安装：$abi_pkg"
        return 0
    fi
    abi_user=droidspaces-aurbuild
    abi_home=/var/tmp/$abi_user
    abi_work=$(mktemp -d "/tmp/aur-$abi_pkg.XXXXXX") || return 1
    if ! id "$abi_user" >/dev/null 2>&1; then
        useradd --system --create-home --home-dir "$abi_home" --shell /bin/bash \
            "$abi_user" 2>/dev/null || { rm -rf "$abi_work"; return 1; }
    fi
    chown -R "$abi_user:$abi_user" "$abi_work"

    abi_cloned=false
    for _ in 1 2 3; do
        if runuser -u "$abi_user" -- env HOME="$abi_home" \
            git clone --depth=1 "https://aur.archlinux.org/$abi_pkg.git" \
            "$abi_work/$abi_pkg" >/dev/null 2>&1; then
            abi_cloned=true
            break
        fi
        rm -rf "$abi_work/$abi_pkg"
        sleep 3
    done
    if [ "$abi_cloned" != true ] || [ ! -f "$abi_work/$abi_pkg/.SRCINFO" ]; then
        warn "AUR 克隆失败：$abi_pkg"
        rm -rf "$abi_work"
        return 1
    fi

    abi_srcinfo=$abi_work/$abi_pkg/.SRCINFO
    abi_deps=$(
        {
            sed -n 's/^[[:space:]]*depends = //p' "$abi_srcinfo"
            sed -n 's/^[[:space:]]*makedepends = //p' "$abi_srcinfo"
            sed -n 's/^[[:space:]]*\(depends\|makedepends\)_aarch64 = //p' "$abi_srcinfo"
        } | sed 's/[<>=].*$//' | sort -u
    )
    abi_need_ffmpeg=false
    abi_missing=
    for abi_dep in $abi_deps; do
        case "$abi_dep" in
            *.so) abi_need_ffmpeg=true; continue ;;
        esac
        pacman -Qq "$abi_dep" >/dev/null 2>&1 || abi_missing="$abi_missing $abi_dep"
    done
    if [ "$abi_need_ffmpeg" = true ]; then
        pacman -Qq ffmpeg >/dev/null 2>&1 || abi_missing="$abi_missing ffmpeg"
    fi
    if [ -n "$abi_missing" ]; then
        # shellcheck disable=SC2086
        pacman -S --needed --noconfirm --asdeps $abi_missing >/dev/null 2>&1 || {
            warn "AUR 依赖安装失败：$abi_missing"
            rm -rf "$abi_work"
            return 1
        }
    fi

    # makepkg 会 clone GitHub 源码；直连不通时按仓库约定走镜像前缀。
    abi_env="HOME=$abi_home"
    if ! timeout 15 git ls-remote --exit-code https://github.com \
            >/dev/null 2>&1; then
        abi_env="$abi_env GIT_CONFIG_COUNT=1"
        abi_env="$abi_env GIT_CONFIG_KEY_0=url.${GH_MIRROR_PREFIX%/}/https://github.com/.insteadOf"
        abi_env="$abi_env GIT_CONFIG_VALUE_0=https://github.com/"
    fi
    # shellcheck disable=SC2086
    if ! runuser -u "$abi_user" -- env $abi_env bash -c \
        'cd "$1" && makepkg --cleanbuild --clean --noconfirm' _ "$abi_work/$abi_pkg"; then
        warn "AUR 构建失败：$abi_pkg"
        rm -rf "$abi_work"
        return 1
    fi

    # 一个 AUR 配方可能产出多个包（reef 的配方同时给 reef 和 reef-tools），
    # 必须全部安装，只取第一个会漏掉本体。
    abi_files=$(find "$abi_work/$abi_pkg" -maxdepth 1 -type f \
        -name '*.pkg.tar.*' ! -name '*.sig' -print)
    if [ -z "$abi_files" ]; then
        warn "AUR 构建没有产出包：$abi_pkg"
        rm -rf "$abi_work"
        return 1
    fi
    abi_conf=/tmp/pacman-aur-$abi_pkg.conf
    sed -e '/^[[:space:]]*LocalFileSigLevel[[:space:]]*=/d' \
        -e '/^\[options\][[:space:]]*$/a LocalFileSigLevel = Optional' \
        /etc/pacman.conf > "$abi_conf"
    # shellcheck disable=SC2086
    if pacman --config "$abi_conf" -U --noconfirm $abi_files >/dev/null 2>&1; then
        log "已从 AUR 构建并安装：$abi_pkg"
    else
        warn "AUR 包安装失败：$abi_pkg"
        rm -f "$abi_conf"
        rm -rf "$abi_work"
        return 1
    fi
    rm -f "$abi_conf"
    rm -rf "$abi_work"
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
    elif [ "$DRY_RUN" = true ] || [ -n "$ROOT" ]; then
        log "dry-run: would install paru from archlinuxcn"
        return 0
    elif pacman -S --needed --noconfirm paru >/dev/null 2>&1; then
        log "已安装 paru"
    else
        warn "paru 安装失败；Maple 字体与雾凇拼音将走镜像下载回退"
        return 0
    fi

    # reef/reef-tools 只在 AUR，失败不影响构建（登录时 conf.d 会打印未安装提示）。
    if [ "$DRY_RUN" = true ] || [ -n "$ROOT" ]; then
        log "dry-run: would build reef/reef-tools from AUR"
        return 0
    fi
    # paru 用 makepkg 构建 AUR 包，需要 base-devel。缺了它 reef 只会 warn 后跳过，
    # 镜像会静默没有 reef；这里显式兜底（已安装时 pacman 立即返回）。
    pacman -S --needed --noconfirm --asdeps base-devel >/dev/null 2>&1 || \
        warn "base-devel 安装失败，AUR 包（reef/reef-tools）可能无法构建"
    # paru 在 root 下直接拒绝（"can't install AUR package as root"），构建期和
    # 设备重跑都是 root，所以走 makepkg + pacman -U。
    if aur_build_install reef; then
        aur_build_install reef-tools || \
            warn "reef-tools 安装失败（reef 本体已安装），已跳过"
    else
        warn "reef 安装失败（AUR/网络不可用？），已跳过"
    fi
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
    # 可用不等于生效：user_dirs 依赖会话真正使用中文 locale。
    if locale_zh_configured; then
        LOCALE_ZH_APPLIED=true
    else
        warn "/etc/locale.conf 的 LANG 不是 zh_CN.UTF-8，user_dirs 保持默认目录"
    fi
    # 文档 02:15：只设 LANG。旧镜像的 /etc/locale.conf 里带 LC_ALL=，
    # 它会压过 LANG，升级路径也必须清掉；没有该行就完全不动。
    if grep -qE '^[[:space:]]*LC_ALL=' "$ROOT/etc/locale.conf" 2>/dev/null; then
        if [ "$DRY_RUN" = true ]; then
            log "dry-run: would drop LC_ALL from /etc/locale.conf（文档 02:15：只设 LANG）"
        elif ! new_tmp; then
            fail_step "mktemp 失败，无法清理 LC_ALL"
            return 1
        else
            lc_tmp=$nt_path
            if ! awk '!/^[[:space:]]*LC_ALL=/' "$ROOT/etc/locale.conf" >"$lc_tmp"; then
                drop_tmp "$lc_tmp"
                fail_step "改写 /etc/locale.conf 失败"
                return 1
            fi
            if ! install_content /etc/locale.conf 0644 <"$lc_tmp"; then
                drop_tmp "$lc_tmp"
                return 1
            fi
            drop_tmp "$lc_tmp"
            log "fixed: /etc/locale.conf（文档 02:15：只设 LANG，删除 LC_ALL=）"
        fi
    fi
    # 只在系统本身使用中文 locale 时改用户会话语言：英文镜像（-g false）不应
    # 被偏好脚本悄悄切成中文。
    if locale_zh_configured; then
        install_content "$USER_HOME/.config/environment.d/locale.conf" 0644 <<'EOF' || return 1
# 由 droidspaces-preferences 生成：只设 LANG，单项分类仍可单独覆盖。
LANG=zh_CN.UTF-8
EOF
    else
        log "系统 LANG 不是 zh_CN.UTF-8，跳过用户会话语言设置"
    fi
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
        # 历史镜像写死过 GTK_IM_MODULE/QT_IM_MODULE，会让 GTK4/Qt6 走旧的
        # XIM 兼容路径；fcitx5 在 Wayland 下靠 XMODIFIERS 自动探测，删掉更稳。
        unset_etc_environment GTK_IM_MODULE || return 1
        unset_etc_environment QT_IM_MODULE || return 1
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

    # 主线 /etc/environment 带 XCURSOR_SIZE=48；容器内没有该变量时光标会按
    # 默认的 24px 加载，在平板高分屏上过小。
    set_etc_environment XCURSOR_SIZE "48" || return 1
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
    # GTK4 没有 GTK_THEME 等价物，用 gtk.css 的 color-scheme 声明暗色。
    install_asset "$USER_HOME/.config/gtk-4.0/gtk.css" gtk-4.0/gtk.css 0644 || return 1
    return 0
}

# 6b) neovim：最小可用默认配置（行号、真彩、系统剪贴板）。
step_nvim() {
    if [ -z "$USER_HOME" ]; then
        skip_step "未找到普通用户"
        return 2
    fi
    if ! have_bin nvim; then
        skip_step "未安装 neovim"
        return 2
    fi
    install_asset "$USER_HOME/.config/nvim/init.lua" nvim/init.lua 0644 || return 1
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
    install_asset "$USER_HOME/.config/fastfetch/config.jsonc" fastfetch/config.jsonc 0644 || return 1
    # fastfetch 的 command 模块直接调用这两个脚本，缺失会在每次登录多打两行失败。
    install_asset /usr/local/bin/ff-shell-stack fastfetch/ff-shell-stack 0755 || return 1
    install_asset /usr/local/bin/ff-sdks fastfetch/ff-sdks 0755 || return 1

    # 登录默认 shell 改为 fish。放在 tide 处理之前：tide 未安装时本步骤会提前
    # return 2，放到后面就永远不会执行。
    if [ "$DRY_RUN" = true ] || [ -n "$ROOT" ]; then
        log "dry-run: would chsh -s /usr/bin/fish $USER_NAME"
    elif chsh -s /usr/bin/fish "$USER_NAME" 2>/dev/null; then
        log "已将 $USER_NAME 的登录 shell 设为 fish"
    else
        warn "chsh -s /usr/bin/fish $USER_NAME 失败，登录 shell 保持原值"
    fi

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
            # 没装上 tide 是跳过而不是成功，manifest 的 skipped 才能反映真实情况。
            skip_step "未安装 tide"
            return 2
        fi
    fi
    install_asset "$USER_HOME/.config/fish/tide-apply.fish" fish/tide-apply.fish 0755 || return 1
    if [ "$DRY_RUN" = true ] || [ -n "$ROOT" ]; then
        run_as_user "fish -c 'source $USER_HOME/.config/fish/tide-apply.fish'"
        return 0
    fi
    if run_as_user "fish -c 'source $USER_HOME/.config/fish/tide-apply.fish'"; then
        log "已写入 tide universal 变量"
    else
        warn "tide 配置脚本执行失败，可在设备上运行 fish ~/.config/fish/tide-apply.fish"
    fi
    return 0
}

# 候选窗主题：发行版只带 default/default-dark，classicui 里写死的
# catppuccin-mocha-mauve 并不存在，候选窗会退回默认样式。主题体积很小
# （tarball 约 98KB），直接从上游源码包取，失败不影响输入法本身。
ensure_fcitx_theme() {
    eft_dest=/usr/share/fcitx5/themes/catppuccin-mocha-mauve
    if path_exists "$eft_dest"; then
        log "fcitx5 主题已存在：$eft_dest"
        return 0
    fi
    if [ "$OFFLINE" = true ]; then
        warn "PREFERENCES_OFFLINE=true，跳过 catppuccin-mocha-mauve 主题下载"
        return 1
    fi
    if [ "$DRY_RUN" = true ]; then
        log "dry-run: would install $eft_dest"
        return 0
    fi
    if ! have_bin tar; then
        warn "缺少 tar，无法解压 catppuccin-mocha-mauve 主题"
        return 1
    fi
    eft_stage=$(mktemp -d "${TMPDIR:-/tmp}/fcitx5-theme.XXXXXX" 2>/dev/null) || {
        warn "mktemp 失败，无法安装 catppuccin-mocha-mauve 主题"
        return 1
    }
    eft_url=$(gh_mirror_url https://github.com/catppuccin/fcitx5/archive/refs/heads/main.tar.gz)
    if ! fetch_url "$eft_url" "$eft_stage/main.tar.gz"; then
        rm -rf "$eft_stage"
        warn "catppuccin fcitx5 主题下载失败（$eft_url）"
        return 1
    fi
    if ! tar -xzf "$eft_stage/main.tar.gz" -C "$eft_stage" 2>/dev/null; then
        rm -rf "$eft_stage"
        warn "解压 catppuccin fcitx5 主题失败"
        return 1
    fi
    # 归档顶层目录名带分支后缀（如 fcitx5-main），用通配避开具体版本。
    eft_src=
    for eft_cand in "$eft_stage"/*/src/catppuccin-mocha-mauve; do
        if [ -d "$eft_cand" ]; then
            eft_src=$eft_cand
            break
        fi
    done
    if [ -z "$eft_src" ]; then
        rm -rf "$eft_stage"
        warn "主题包内未找到 src/catppuccin-mocha-mauve"
        return 1
    fi
    if ! mkdir -p "$ROOT/usr/share/fcitx5/themes"; then
        rm -rf "$eft_stage"
        warn "无法创建 /usr/share/fcitx5/themes"
        return 1
    fi
    rm -rf "$ROOT$eft_dest"
    if ! cp -a "$eft_src" "$ROOT$eft_dest"; then
        rm -rf "$eft_stage"
        warn "复制 catppuccin-mocha-mauve 主题失败"
        return 1
    fi
    chmod -R a+rX "$ROOT$eft_dest" 2>/dev/null || true
    rm -rf "$eft_stage"
    log "已安装 fcitx5 主题：$eft_dest"
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
    # 只有 rime 插件真的存在时才把默认输入法设为 rime；否则 fcitx5 找不到
    # 该引擎，开机后没有候选词，退回 fcitx5-chinese-addons 自带的 pinyin。
    # fcitx5-rime 装出来的插件名是 librime.so（Arch 的 fcitx5 也按此命名），
    # 既不是 rime.so，也没有 /usr/lib/fcitx5/rime/ 目录；后两者只作回退兼容。
    if path_exists /usr/lib/fcitx5/librime.so || \
        path_exists /usr/lib/fcitx5/rime.so || is_dir /usr/lib/fcitx5/rime; then
        install_asset "$USER_HOME/.config/fcitx5/profile" fcitx5/profile 0644 || return 1
    else
        warn "未检测到 fcitx5 rime 插件，默认输入法改用 pinyin"
        install_asset "$USER_HOME/.config/fcitx5/profile" fcitx5/profile 0644 's/=rime$/=pinyin/' || return 1
    fi

    ensure_fcitx_theme || true
    if path_exists /usr/share/fcitx5/themes/catppuccin-mocha-mauve || \
        path_exists "$USER_HOME/.local/share/fcitx5/themes/catppuccin-mocha-mauve" || \
        [ "$DRY_RUN" = true ]; then
        install_asset "$USER_HOME/.config/fcitx5/conf/classicui.conf" fcitx5/conf/classicui.conf 0644 || return 1
    else
        warn "catppuccin-mocha-mauve 主题不可用，classicui 仅写 DPI 设置"
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
# 由 droidspaces-preferences 生成。职责：
# 1) D-Bus 激活的 fcitx5 拿不到会话环境，这里从 XDG_RUNTIME_DIR 挑 Wayland socket；
# 2) niri spawn 的实例启动需要约 1 秒，期间若有应用请求输入法会触发激活，
#    于是并存两份。先等总线名出现（最多 1 秒），出现就退出，交给已运行的实例；
# 3) systemd 用户实例在 default.target 阶段启动，niri 可能还没建好 Wayland
#    socket。此时先等 socket 出现（最多 30 秒），避免 fcitx5 报
#    "Failed to open wayland connection" 后成为没有总线名的第二份。
if command -v busctl >/dev/null 2>&1; then
    i=0
    # 1 秒足够覆盖“D-Bus 激活正在起”的窗口；再久只会拖慢登录。
    while [ "$i" -lt 5 ]; do
        if busctl --user status org.fcitx.Fcitx5 >/dev/null 2>&1; then
            exit 0
        fi
        sleep 0.2
        i=$((i + 1))
    done
fi
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ -n "${XDG_RUNTIME_DIR:-}" ]; then
    # 0.2 秒 × 150 次 = 30 秒上限；socket 一出现立即结束等待。
    w=0
    while [ "$w" -lt 150 ]; do
        ws_ready=
        for s in "$XDG_RUNTIME_DIR"/wayland-?; do
            if [ -S "$s" ]; then
                ws_ready=1
                break
            fi
        done
        [ "$ws_ready" = 1 ] && break
        sleep 0.2
        w=$((w + 1))
    done
    for s in "$XDG_RUNTIME_DIR"/wayland-?; do
        [ -S "$s" ] || continue
        WAYLAND_DISPLAY=${s##*/}
        export WAYLAND_DISPLAY
        break
    done
fi
if command -v busctl >/dev/null 2>&1; then
    # 等满仍无 owner：会话启动的那份没有注册到总线（缺 DBUS_SESSION_BUS_ADDRESS
    # 时就是这样），留着它只会与新实例并存、候选词落到错误进程。按精确 pid 结束
    # 未持有总线名的 fcitx5，再启动本实例。
    owner=$(busctl --user status org.fcitx.Fcitx5 2>/dev/null | sed -n 's/^PID=//p')
    for pr in /proc/[0-9]*; do
        pid=${pr#/proc/}
        [ "$(cat "$pr/comm" 2>/dev/null)" = fcitx5 ] || continue
        [ "$pid" = "${owner:-}" ] && continue
        kill "$pid" 2>/dev/null || true
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

    # 会话入口以 systemd 用户单元为主：unit 与 niri 的 spawn-at-startup 走同一个
    # wrapper，wrapper 见到已有总线名会立即退出，所以两者并存不会拉起两份实例。
    install_asset "$USER_HOME/.config/systemd/user/fcitx5-session.service" \
        systemd/user/fcitx5-session.service 0644 || return 1
    fcitx_wants=$USER_HOME/.config/systemd/user/default.target.wants
    fcitx_link=$fcitx_wants/fcitx5-session.service
    # 相对链接：unit 目录随家目录整体迁移或挂载到别处时仍然有效。
    if [ "$(readlink "$ROOT$fcitx_link" 2>/dev/null || true)" = ../fcitx5-session.service ]; then
        log "unchanged: $fcitx_link"
    elif [ "$DRY_RUN" = true ]; then
        log "dry-run: would link $fcitx_link -> ../fcitx5-session.service"
    else
        if ! prepare_user_parent "$fcitx_link"; then
            fail_step "无法创建 $fcitx_wants"
            return 1
        fi
        if ! ln -sfn ../fcitx5-session.service "$ROOT$fcitx_link"; then
            fail_step "无法创建 $fcitx_link"
            return 1
        fi
        if [ -z "$ROOT" ] && [ -n "$USER_UID" ]; then
            chown -h "$USER_UID:$USER_GID" "$ROOT$fcitx_link" 2>/dev/null || \
                warn "chown 失败：$fcitx_link"
        fi
        log "linked: $fcitx_link -> ../fcitx5-session.service"
    fi

    # niri 的 spawn-at-startup 保留作 systemd 单元未起时的兜底；autostart 里的
    # 两份仍要屏蔽：它们既不经过 wrapper，也拿不到会话的 WAYLAND_DISPLAY。删掉
    # 用户副本，并用 Hidden=true 覆盖系统那份。
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

    # 在活动会话里重跑本脚本时，旧的 fcitx5 仍持有旧配置：候选窗主题/profile
    # 不生效，而且改配置期间掉总线名后会被 D-Bus 激活出第二个实例（实测两个
    # fcitx5，org.fcitx.Fcitx5 无 owner）。这里只在确有会话时做一次干净重启，
    # 镜像构建阶段没有 wayland socket，自然跳过。
    if [ "$DRY_RUN" != true ] && [ -z "$ROOT" ] && [ -n "$USER_UID" ] && \
        [ -S "/run/user/$USER_UID/wayland-1" ]; then
        if pgrep -u "$USER_UID" -x fcitx5 >/dev/null 2>&1; then
            log "检测到活动会话中的 fcitx5，重启以加载新配置"
            pkill -u "$USER_UID" -x fcitx5 >/dev/null 2>&1 || true
            sleep 1
            pkill -9 -u "$USER_UID" -x fcitx5 >/dev/null 2>&1 || true
            run_as_user "XDG_RUNTIME_DIR=/run/user/$USER_UID \
                WAYLAND_DISPLAY=wayland-1 \
                DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$USER_UID/bus \
                setsid /usr/local/bin/fcitx5-dbus >/dev/null 2>&1 &" || \
                warn "重启 fcitx5 失败；下次登录会重新启动"
        fi
    fi
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
    # Arch 的 xdg-utils 不提供 default-file-manager 属性（实测 `xdg-settings set
    # default-file-manager` 直接打印用法并返回非零）。`inode/directory` 已由
    # mimeapps.list 覆盖，这里只在支持该属性时才额外写，避免无意义的告警。
    if run_as_user "xdg-settings --list 2>/dev/null | grep -qx default-file-manager"; then
        run_as_user "xdg-settings set default-file-manager nemo.desktop" || \
            warn "xdg-settings 设置默认文件管理器失败（nemo.desktop）"
    fi

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
    merge_mimeapps_into "$USER_HOME/.config/mimeapps.list" || return 1
    # 系统级兜底：新建用户/未应用偏好的会话也能用 Nemo 打开目录。
    merge_mimeapps_into /etc/xdg/mimeapps.list || return 1
    return 0
}

# 幂等地把 inode/directory -> nemo.desktop 写进单个 mimeapps.list，
# [Default Applications] 里的其它键与其它分组原样保留。
merge_mimeapps_into() {
    mmi_dest=$1
    if [ "$DRY_RUN" = true ]; then
        log "dry-run: would map inode/directory -> nemo.desktop in $mmi_dest"
        return 0
    fi
    mmi_full=$ROOT$mmi_dest
    if ! new_tmp; then
        fail_step "mktemp 失败"
        return 1
    fi
    mmi_tmp=$nt_path
    if [ -f "$mmi_full" ]; then
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
        ' "$mmi_full" >"$mmi_tmp"; then
            drop_tmp "$mmi_tmp"
            fail_step "解析 $mmi_dest 失败"
            return 1
        fi
        if ! grep -q '^\[Default Applications\]' "$mmi_tmp"; then
            if ! printf '%s\n' '[Default Applications]' 'inode/directory=nemo.desktop' >>"$mmi_tmp"; then
                drop_tmp "$mmi_tmp"
                fail_step "写入 $mmi_dest 失败"
                return 1
            fi
        fi
    else
        if ! printf '%s\n' '[Default Applications]' 'inode/directory=nemo.desktop' >"$mmi_tmp"; then
            drop_tmp "$mmi_tmp"
            fail_step "写入 $mmi_dest 失败"
            return 1
        fi
    fi
    install_content "$mmi_dest" 0644 <"$mmi_tmp"
    mmi_rc=$?
    drop_tmp "$mmi_tmp"
    return $mmi_rc
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
    # 用 install_asset 覆盖而不是 install_if_absent：胶囊/间距等偏好会随版本
    # 调整，保留旧文件会让升级后的镜像看不到新值。覆盖前按统一机制备份。
    install_asset "$USER_HOME/.config/noctalia/config.toml" noctalia/config.toml 0644
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
        # 走包装器而不是裸 fcitx5：启动瞬间若有 D-Bus 激活先占了总线名，裸实例会
        # 永久成为“无总线”的第二份；包装器会等名、清理无名实例后再 exec。
        printf '%s\n' 'spawn-at-startup "/usr/local/bin/fcitx5-dbus"'
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
    if ! rollback_snapshot "$nae_full"; then
        drop_tmp "$nae_tmp"
        fail_step "回滚基线创建失败：$nae_file"
        return 1
    fi
    nae_orig=$rb_path
    # layout 段只能出现一次；background-color 插在 layout 开头，focus-ring 的值
    # 在已有块内就地替换（库存配置里 focus-ring 已经是活动节点，重复节点会解析失败）。
    # shadow 节点同理只能有一个：仅在库存配置没有 shadow 块时补一份光晕阴影
    #（对应 Nyxuri §4）；已有块交给 niri_fix_shadow 幂等修补。
    nae_has_shadow=false
    if grep -q '^[[:space:]]*shadow[[:space:]]*{' "$nae_full" 2>/dev/null; then
        nae_has_shadow=true
    fi
    # 圆角规则同理只补一次：库存配置已有活动 geometry-corner-radius 时不重复写。
    nae_has_radius=false
    if niri_has_active_radius "$nae_full"; then
        nae_has_radius=true
    fi
    # binds 段同理，只能插在已有 binds 块内。
    awk -v has_shadow="$nae_has_shadow" '
        BEGIN { layout_done = 0; in_fr = 0; fr_named = 0 }
        /^[[:space:]]*layout[[:space:]]*\{/ && !layout_done {
            print
            print "    background-color \"transparent\""
            if (has_shadow == "false") {
                print "    shadow {"
                print "        // 对应 Nyxuri §4：光晕阴影。"
                print "        on"
                print "        softness 28"
                print "        spread 6"
                print "        offset x=0 y=0"
                print "        draw-behind-window false"
                print "        color \"#b6c7e795\""
                print "        inactive-color \"#00000045\""
                print "    }"
            }
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
        drop_tmp "$nae_tmp"
        drop_tmp "$nae_orig"
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
        # niri 26.04-modified 不认识 default-window-width/height，写了会导致
        # 整份配置校验失败（unexpected node）。浮窗尺寸改用 niri 默认值；
        # 文档 01:64 记为不可实现。
        printf '%s\n' 'window-rule {'
        printf '%s\n' '    match app-id="noctalia"'
        printf '%s\n' '    open-floating true'
        printf '%s\n' '}'
        # kitty 只保留半透明；模糊必须由 niri 合成层做，kitty 的
        # background_blur 在 Wayland 下不生效。
        # 注意：niri 的 KDL 解析器不接受 `}` 紧跟值的内联子块
        # （`background-effect { blur true }` 会整份配置校验失败），
        # 必须写成多行块，且 `}` 前有换行。
        printf '%s\n' 'window-rule {'
        printf '%s\n' '    match app-id="^kitty$"'
        printf '%s\n' '    background-effect {'
        printf '%s\n' '        blur true'
        printf '%s\n' '    }'
        printf '%s\n' '}'
        printf '%s\n' 'window-rule {'
        printf '%s\n' '    draw-border-with-background false'
        printf '%s\n' '}'
        if [ "$nae_has_radius" = false ]; then
            # 全窗口圆角 12 + 裁剪；已有活动规则时由 niri_fix_corner_radius 跳过。
            printf '%s\n' 'window-rule {'
            printf '%s\n' '    geometry-corner-radius 12'
            printf '%s\n' '    clip-to-geometry true'
            printf '%s\n' '}'
        fi
        printf '%s\n' '// <<< droidspaces-preferences: niri 外观与行为'
    } >>"$nae_tmp" || {
        drop_tmp "$nae_tmp"
        drop_tmp "$nae_orig"
        fail_step "追加失败：$nae_file"
        return 1
    }
    cat "$nae_tmp" >"$nae_full"
    drop_tmp "$nae_tmp"
    nae_validator=
    if have_bin niri-anland; then
        nae_validator=niri-anland
    elif have_bin niri; then
        nae_validator=niri
    fi
    if [ -n "$nae_validator" ]; then
        if ! nae_err=$("$nae_validator" validate -c "$nae_full" 2>&1); then
            warn "$nae_file 校验失败，已回滚：$(printf '%s' "$nae_err" | tr '\n' ' ' | cut -c1-300)"
            restore_snapshot "$nae_orig" "$nae_full" "$nae_file" || warn "回滚失败：$nae_file"
            drop_tmp "$nae_orig"
            return 1
        fi
    fi
    drop_tmp "$nae_orig"
    log "appended: $nae_file（niri 外观块）"
    return 0
}

# layout 的幂等修补：
#   1) layout 块内 gaps 统一为 8（对应文档 01:59）；
#   2) 删除 niri 26.04 不支持的 default-window-width/height。旧版本脚本曾把它们
#      写进 Noctalia 的 window-rule，niri 26.04-modified 校验时报
#      unexpected node default-window-width 并整体拒绝加载。浮窗尺寸改用 niri
#      默认值；文档 01:64 记为不可实现。
# 只改已存在的 layout，不新建块；括号深度判定保证不动 layout 之外的节点。
# 备份 → temp → validate → 失败回滚。
niri_fix_layout_noctalia() {
    nfln_file=$1
    nfln_full=$ROOT$nfln_file
    path_exists "$nfln_file" || return 2

    if ! new_tmp; then
        fail_step "mktemp 失败"
        return 1
    fi
    nfln_tmp=$nt_path
    awk '
        function delta(line,   i, c, q, kept, o, cl) {
            kept = ""; q = 0
            for (i = 1; i <= length(line); i++) {
                c = substr(line, i, 1)
                if (q) { if (c == "\"") q = 0; continue }
                if (c == "\"") { q = 1; continue }
                if (c == "/" && substr(line, i + 1, 1) == "/") break
                kept = kept c
            }
            o = gsub(/{/, "{", kept)
            cl = gsub(/}/, "}", kept)
            return o - cl
        }
        {
            line = $0
            d = delta(line)
            before = depth
            depth = before + d

            # layout 只认第一个顶层节点；单行 inline 的 layout 不处理。
            if (!in_layout && before == 0 && d > 0 && line ~ /^[[:space:]]*layout[[:space:]]*\{/) {
                in_layout = 1
                layout_depth = depth
                print
                print "    gaps 8"
                next
            }
            # 直接子层的旧 gaps 行删掉，由上面插入的那行统一。
            if (in_layout && before == layout_depth && line ~ /^[[:space:]]*gaps[[:space:]]/) next
            if (in_layout && depth < layout_depth) in_layout = 0
            # niri 26.04 不认识这两个键，任何位置都删。
            if (line ~ /^[[:space:]]*default-window-(width|height)[[:space:]]/) next
            print
        }
    ' "$nfln_full" >"$nfln_tmp" || {
        drop_tmp "$nfln_tmp"
        fail_step "改写失败：$nfln_file"
        return 1
    }
    if same_content "$nfln_tmp" "$nfln_full"; then
        drop_tmp "$nfln_tmp"
        return 0
    fi
    if [ "$DRY_RUN" = true ]; then
        drop_tmp "$nfln_tmp"
        log "dry-run: would normalize gaps and drop default-window-* in $nfln_file"
        return 0
    fi
    backup_file "$nfln_file" || {
        drop_tmp "$nfln_tmp"
        return 1
    }
    if ! rollback_snapshot "$nfln_full"; then
        drop_tmp "$nfln_tmp"
        fail_step "回滚基线创建失败：$nfln_file"
        return 1
    fi
    nfln_orig=$rb_path
    cat "$nfln_tmp" >"$nfln_full"
    drop_tmp "$nfln_tmp"
    nfln_validator=
    if have_bin niri-anland; then
        nfln_validator=niri-anland
    elif have_bin niri; then
        nfln_validator=niri
    fi
    if [ -n "$nfln_validator" ]; then
        if ! nfln_err=$("$nfln_validator" validate -c "$nfln_full" 2>&1); then
            warn "$nfln_file 校验失败，已回滚：$(printf '%s' "$nfln_err" | tr '\n' ' ' | cut -c1-300)"
            restore_snapshot "$nfln_orig" "$nfln_full" "$nfln_file" || warn "回滚失败：$nfln_file"
            drop_tmp "$nfln_orig"
            return 1
        fi
    fi
    drop_tmp "$nfln_orig"
    log "fixed: $nfln_file（layout gaps 8；移除 default-window-*）"
    return 0
}

# 阴影光晕的幂等修补（对应 Nyxuri §4）：
#   在已有 layout 块的直接子层保证 shadow 为 on，softness 28、spread 6、
#   offset x=0 y=0、draw-behind-window false、color #b6c7e795、
#   inactive-color #00000045。只改已存在的 layout，不新建块。
# 改写按花括号深度判定，只在 layout 的直接子层动手，绝不跨出 layout 块；
# 写回前对输入/输出各做一次括号计数自检（open==close），不等就失败回滚。
# 写法与 niri_fix_layout_noctalia 一致：备份 → temp → 自检 → validate → 失败回滚。
niri_fix_shadow() {
    nfs_file=$1
    nfs_full=$ROOT$nfs_file
    path_exists "$nfs_file" || return 2

    if ! new_tmp; then
        fail_step "mktemp 失败"
        return 1
    fi
    nfs_tmp=$nt_path
    awk '
        # 计算一行的花括号净值：忽略 "" 字符串和 // 注释里的括号。
        function delta(line,   i, c, q, kept, o, cl) {
            kept = ""; q = 0
            for (i = 1; i <= length(line); i++) {
                c = substr(line, i, 1)
                if (q) { if (c == "\"") q = 0; continue }
                if (c == "\"") { q = 1; continue }
                if (c == "/" && substr(line, i + 1, 1) == "/") break
                kept = kept c
            }
            o = gsub(/{/, "{", kept)
            cl = gsub(/}/, "}", kept)
            return o - cl
        }
        function shadow_block() {
            print "    shadow {"
            print "        // 对应 Nyxuri §4：光晕阴影。"
            print "        on"
            print "        softness 28"
            print "        spread 6"
            print "        offset x=0 y=0"
            print "        draw-behind-window false"
            print "        color \"#b6c7e795\""
            print "        inactive-color \"#00000045\""
            print "    }"
        }
        function fill_missing() {
            if (!has_on) print "        on"
            if (!has_soft) print "        softness 28"
            if (!has_spread) print "        spread 6"
            if (!has_offset) print "        offset x=0 y=0"
            if (!has_draw) print "        draw-behind-window false"
            if (!has_color) print "        color \"#b6c7e795\""
            if (!has_inactive) print "        inactive-color \"#00000045\""
        }
        {
            line = $0
            d = delta(line)
            before = depth
            depth = before + d

            # layout 只认第一个顶层节点；单行 inline 的 layout 不处理。
            if (!in_layout && before == 0 && d > 0 && line ~ /^[[:space:]]*layout[[:space:]]*\{/) {
                in_layout = 1
                layout_depth = depth
                print
                next
            }

            # shadow 必须在 layout 的直接子层出现。
            if (in_layout && !in_shadow && before == layout_depth && d > 0 && \
                line ~ /^[[:space:]]*shadow[[:space:]]*\{/) {
                in_shadow = 1
                shadow_seen = 1
                shadow_depth = depth
                has_on = 0; has_soft = 0; has_spread = 0; has_offset = 0
                has_draw = 0; has_color = 0; has_inactive = 0
                print
                next
            }

            if (in_shadow) {
                # 只改写 shadow 的直接子层；更深的嵌套原样通过。
                if (before == shadow_depth) {
                    if (line ~ /^[[:space:]]*\/\/[[:space:]]*on[[:space:]]*$/) {
                        if (!has_on) {
                            print "        on"
                            has_on = 1
                        }
                        next
                    }
                    if (line ~ /^[[:space:]]*on[[:space:]]*$/) { has_on = 1; print; next }
                    if (line ~ /^[[:space:]]*softness[[:space:]]/) { print "        softness 28"; has_soft = 1; next }
                    if (line ~ /^[[:space:]]*spread[[:space:]]/) { print "        spread 6"; has_spread = 1; next }
                    if (line ~ /^[[:space:]]*offset[[:space:]]/) { print "        offset x=0 y=0"; has_offset = 1; next }
                    if (line ~ /^[[:space:]]*draw-behind-window[[:space:]]/) { print "        draw-behind-window false"; has_draw = 1; next }
                    if (line ~ /^[[:space:]]*inactive-color[[:space:]]/) { print "        inactive-color \"#00000045\""; has_inactive = 1; next }
                    if (line ~ /^[[:space:]]*color[[:space:]]/) { print "        color \"#b6c7e795\""; has_color = 1; next }
                }
                # 深度回落到 shadow 之前即为其收尾行：补齐缺失项再输出。
                if (depth < shadow_depth) {
                    fill_missing()
                    in_shadow = 0
                }
                print
                next
            }

            # layout 收尾：整份 layout 都没有 shadow 时，在它的直接子层末尾补一份。
            if (in_layout && depth < layout_depth) {
                if (!shadow_seen) {
                    shadow_block()
                    shadow_seen = 1
                }
                in_layout = 0
            }
            print
        }
    ' "$nfs_full" >"$nfs_tmp" || {
        drop_tmp "$nfs_tmp"
        fail_step "改写失败：$nfs_file"
        return 1
    }
    if same_content "$nfs_tmp" "$nfs_full"; then
        drop_tmp "$nfs_tmp"
        return 0
    fi
    if [ "$DRY_RUN" = true ]; then
        drop_tmp "$nfs_tmp"
        log "dry-run: would adjust niri shadow glow in $nfs_file"
        return 0
    fi
    # 括号计数自检：改写前后净值必须一致且为 0，否则绝不写回。
    nfs_in=$(brace_sum "$nfs_full") || {
        drop_tmp "$nfs_tmp"
        fail_step "括号计数失败：$nfs_file"
        return 1
    }
    nfs_out=$(brace_sum "$nfs_tmp") || {
        drop_tmp "$nfs_tmp"
        fail_step "括号计数失败：$nfs_file"
        return 1
    }
    if [ "$nfs_out" != "$nfs_in" ] || [ "$nfs_out" != 0 ]; then
        drop_tmp "$nfs_tmp"
        warn "$nfs_file 阴影改写后花括号不平衡（$nfs_in -> $nfs_out），已放弃写回"
        return 1
    fi
    backup_file "$nfs_file" || {
        drop_tmp "$nfs_tmp"
        return 1
    }
    if ! rollback_snapshot "$nfs_full"; then
        drop_tmp "$nfs_tmp"
        fail_step "回滚基线创建失败：$nfs_file"
        return 1
    fi
    nfs_orig=$rb_path
    cat "$nfs_tmp" >"$nfs_full"
    drop_tmp "$nfs_tmp"
    nfs_validator=
    if have_bin niri-anland; then
        nfs_validator=niri-anland
    elif have_bin niri; then
        nfs_validator=niri
    fi
    if [ -n "$nfs_validator" ]; then
        if ! nfs_err=$("$nfs_validator" validate -c "$nfs_full" 2>&1); then
            warn "$nfs_file 校验失败，已回滚：$(printf '%s' "$nfs_err" | tr '\n' ' ' | cut -c1-300)"
            restore_snapshot "$nfs_orig" "$nfs_full" "$nfs_file" || warn "回滚失败：$nfs_file"
            drop_tmp "$nfs_orig"
            return 1
        fi
    fi
    drop_tmp "$nfs_orig"
    log "fixed: $nfs_file（阴影光晕 softness 28 / spread 6）"
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
    # fcitx5 自启动统一改走包装器。旧版本给它加过 -r，也要一并去掉；这里的
    # `-r` 不写成 "-r" 引号形式，避免某些 sed 实现把引号当语法字符吃掉。
    sed -E \
        -e 's/spawn(-sh)? +"alacritty"/spawn\1 "kitty"/' \
        -e 's/: alacritty"/: kitty"/' \
        -e '/^[[:space:]]*spawn-at-startup +"waybar"/d' \
        -e 's|^([[:space:]]*spawn-at-startup) +"fcitx5"( +-r)?[[:space:]]*$|\1 "/usr/local/bin/fcitx5-dbus"|' \
        "$nfl_full" >"$nfl_tmp" || {
        drop_tmp "$nfl_tmp"
        fail_step "改写失败：$nfl_file"
        return 1
    }
    cat "$nfl_tmp" >"$nfl_full"
    drop_tmp "$nfl_tmp"
    log "fixed: $nfl_file（alacritty→kitty、移除 waybar、fcitx5 改走包装器）"
    return 0
}

# kitty 的 background_blur 在 niri Wayland 下不生效，模糊改由 niri 合成：
# 幂等保证配置里有 kitty 的 window-rule，并清掉误写到 niri 配置里的该键。
# 旧版脚本写出的单行内联规则会让 niri 的 KDL 解析失败，这里一并改写为多行块。
# 写法与 niri_fix_launchers 一致：备份 → temp → 改写 → validate → 失败回滚。
niri_fix_terminal_blur() {
    ntb_file=$1
    ntb_full=$ROOT$ntb_file
    path_exists "$ntb_file" || return 2
    ntb_key=false
    ntb_rule=false
    ntb_inline=false
    if grep -q '^[[:space:]]*background_blur[[:space:]]' "$ntb_full" 2>/dev/null; then
        ntb_key=true
    fi
    if grep -qF 'match app-id="^kitty$"' "$ntb_full" 2>/dev/null; then
        ntb_rule=true
    fi
    # 旧版脚本写的是单行内联规则（`window-rule { match ...; background-effect { blur true } }`）。
    # niri 的 KDL 解析器不接受 `}` 紧跟值的内联子块，这种行会让整份配置
    # 校验失败，必须就地改写为多行块。
    if awk '
        /^[[:space:]]*(\/\/|\/-)/ { next }
        index($0, "background-effect") > 0 && index($0, "match app-id=\"^kitty$\"") > 0 { found = 1 }
        END { exit(found ? 0 : 1) }
    ' "$ntb_full" 2>/dev/null; then
        ntb_inline=true
    fi
    if [ "$ntb_key" = false ] && [ "$ntb_rule" = true ] && [ "$ntb_inline" = false ]; then
        return 0
    fi
    if [ "$DRY_RUN" = true ]; then
        log "dry-run: would ensure kitty blur window-rule in $ntb_file"
        return 0
    fi
    backup_file "$ntb_file" || return 1
    if ! new_tmp; then
        fail_step "mktemp 失败"
        return 1
    fi
    ntb_tmp=$nt_path
    # 一次改写完成两件事：删掉误写的 background_blur 键，把内联 kitty 规则
    # 展开成多行块。多行块里 background-effect 独占一行，第二遍不会再命中。
    awk '
        /^[[:space:]]*background_blur[[:space:]]/ { next }
        /^[[:space:]]*(\/\/|\/-)/ { print; next }
        {
            if (index($0, "background-effect") > 0 && index($0, "match app-id=\"^kitty$\"") > 0) {
                ind = ""
                if (match($0, /[^[:space:]]/) > 1) ind = substr($0, 1, RSTART - 1)
                print ind "window-rule {"
                print ind "    match app-id=\"^kitty$\""
                print ind "    background-effect {"
                print ind "        blur true"
                print ind "    }"
                print ind "}"
                next
            }
            print
        }
    ' "$ntb_full" >"$ntb_tmp" || {
        drop_tmp "$ntb_tmp"
        fail_step "改写失败：$ntb_file"
        return 1
    }
    if [ "$ntb_rule" = false ]; then
        {
            printf '%s\n' ''
            printf '%s\n' '// >>> droidspaces-preferences: kitty 模糊（managed）'
            printf '%s\n' '// niri 的 KDL 解析器不接受内联子块，必须多行书写。'
            printf '%s\n' 'window-rule {'
            printf '%s\n' '    match app-id="^kitty$"'
            printf '%s\n' '    background-effect {'
            printf '%s\n' '        blur true'
            printf '%s\n' '    }'
            printf '%s\n' '}'
            printf '%s\n' '// <<< droidspaces-preferences: kitty 模糊'
        } >>"$ntb_tmp" || {
            drop_tmp "$ntb_tmp"
            fail_step "追加失败：$ntb_file"
            return 1
        }
    fi
    if ! rollback_snapshot "$ntb_full"; then
        drop_tmp "$ntb_tmp"
        fail_step "回滚基线创建失败：$ntb_file"
        return 1
    fi
    ntb_orig=$rb_path
    cat "$ntb_tmp" >"$ntb_full"
    drop_tmp "$ntb_tmp"
    ntb_validator=
    if have_bin niri-anland; then
        ntb_validator=niri-anland
    elif have_bin niri; then
        ntb_validator=niri
    fi
    if [ -n "$ntb_validator" ]; then
        if ! ntb_err=$("$ntb_validator" validate -c "$ntb_full" 2>&1); then
            warn "$ntb_file 校验失败，已回滚：$(printf '%s' "$ntb_err" | tr '\n' ' ' | cut -c1-300)"
            restore_snapshot "$ntb_orig" "$ntb_full" "$ntb_file" || warn "回滚失败：$ntb_file"
            drop_tmp "$ntb_orig"
            return 1
        fi
    fi
    drop_tmp "$ntb_orig"
    log "fixed: $ntb_file（kitty 模糊 window-rule，多行化）"
    return 0
}

# 设备上已安装的 kitty.conf 可能还留着失效的 background_blur，一并删掉。
kitty_drop_background_blur() {
    kdb_dest=$USER_HOME/.config/kitty/kitty.conf
    kdb_full=$ROOT$kdb_dest
    [ -f "$kdb_full" ] || return 0
    grep -q '^[[:space:]]*background_blur[[:space:]]' "$kdb_full" 2>/dev/null || return 0
    if [ "$DRY_RUN" = true ]; then
        log "dry-run: would drop background_blur from $kdb_dest"
        return 0
    fi
    backup_file "$kdb_dest" || return 1
    if ! new_tmp; then
        fail_step "mktemp 失败"
        return 1
    fi
    kdb_tmp=$nt_path
    sed -E '/^[[:space:]]*background_blur[[:space:]]/d' "$kdb_full" >"$kdb_tmp" || {
        drop_tmp "$kdb_tmp"
        fail_step "改写失败：$kdb_dest"
        return 1
    }
    cat "$kdb_tmp" >"$kdb_full"
    drop_tmp "$kdb_tmp"
    log "fixed: $kdb_dest（移除 background_blur）"
    return 0
}

# 判断配置里是否存在「活动」的 geometry-corner-radius。
# 只看未被 /- 注释掉的节点：niri 的 /-window-rule 里子行仍是普通文本，
# 单纯 grep 会把注释示例当成已生效。
niri_has_active_radius() {
    nhcr_full=$1
    awk '
        function delta(line,   i, c, q, kept, o, cl) {
            kept = ""; q = 0
            for (i = 1; i <= length(line); i++) {
                c = substr(line, i, 1)
                if (q) { if (c == "\"") q = 0; continue }
                if (c == "\"") { q = 1; continue }
                if (c == "/" && substr(line, i + 1, 1) == "/") break
                kept = kept c
            }
            o = gsub(/{/, "{", kept)
            cl = gsub(/}/, "}", kept)
            return o - cl
        }
        {
            d = delta($0)
            depth += d
            line = $0
            sub(/^[[:space:]]+/, "", line)
            # /- 关掉的节点：带块的开头进入禁用态，直到深度回落。
            if (line ~ /^\/-/) {
                if (d > 0) { disabled = 1; dis_depth = depth }
                next
            }
            if (disabled) {
                if (depth < dis_depth) disabled = 0
                next
            }
            if (line ~ /^geometry-corner-radius[[:space:]]/) { found = 1; exit }
        }
        END { exit(found ? 0 : 1) }
    ' "$nhcr_full" 2>/dev/null
}

# 全窗口圆角 12 + 裁剪的幂等修补：库存配置的圆角规则往往还是 /- 注释示例，
# 或根本没有。已有活动规则时不动。
niri_fix_corner_radius() {
    nfc_file=$1
    nfc_full=$ROOT$nfc_file
    path_exists "$nfc_file" || return 2
    if niri_has_active_radius "$nfc_full"; then
        return 0
    fi
    if [ "$DRY_RUN" = true ]; then
        log "dry-run: would add corner-radius window-rule to $nfc_file"
        return 0
    fi
    backup_file "$nfc_file" || return 1
    if ! new_tmp; then
        fail_step "mktemp 失败"
        return 1
    fi
    nfc_tmp=$nt_path
    cp "$nfc_full" "$nfc_tmp" || {
        drop_tmp "$nfc_tmp"
        fail_step "读取失败：$nfc_file"
        return 1
    }
    {
        printf '%s\n' ''
        printf '%s\n' '// >>> droidspaces-preferences: 圆角（managed）'
        printf '%s\n' 'window-rule {'
        printf '%s\n' '    geometry-corner-radius 12'
        printf '%s\n' '    clip-to-geometry true'
        printf '%s\n' '}'
        printf '%s\n' '// <<< droidspaces-preferences: 圆角'
    } >>"$nfc_tmp" || {
        drop_tmp "$nfc_tmp"
        fail_step "追加失败：$nfc_file"
        return 1
    }
    if ! rollback_snapshot "$nfc_full"; then
        drop_tmp "$nfc_tmp"
        fail_step "回滚基线创建失败：$nfc_file"
        return 1
    fi
    nfc_orig=$rb_path
    cat "$nfc_tmp" >"$nfc_full"
    drop_tmp "$nfc_tmp"
    nfc_validator=
    if have_bin niri-anland; then
        nfc_validator=niri-anland
    elif have_bin niri; then
        nfc_validator=niri
    fi
    if [ -n "$nfc_validator" ]; then
        if ! nfc_err=$("$nfc_validator" validate -c "$nfc_full" 2>&1); then
            warn "$nfc_file 校验失败，已回滚：$(printf '%s' "$nfc_err" | tr '\n' ' ' | cut -c1-300)"
            restore_snapshot "$nfc_orig" "$nfc_full" "$nfc_file" || warn "回滚失败：$nfc_file"
            drop_tmp "$nfc_orig"
            return 1
        fi
    fi
    drop_tmp "$nfc_orig"
    log "fixed: $nfc_file（圆角 12 + clip）"
    return 0
}

# 键盘布局补丁：老配置生成时 xkb 块里只有注释示例（`// layout "us,ru"`），
# 没有活动行，布局随系统 locale 走，部分镜像上 Mod 键位置会不对。seed 里有
# `layout "us"`，升级路径也要补上。只在已有 xkb 块内插入：xkb 是单例节点，
# 另起一块会让 niri 整份配置校验失败。
niri_fix_xkb_layout() {
    nfx_file=$1
    nfx_full=$ROOT$nfx_file
    path_exists "$nfx_file" || return 2
    if grep -qE '^[[:space:]]*layout[[:space:]]+"us"' "$nfx_full" 2>/dev/null; then
        return 0
    fi
    # 没有 xkb 块就不新建：缺块说明这份配置本来就不想管键盘映射。
    # 单行 `xkb {}` 不算块（在它后面插入会落到块外），按无块处理。
    if ! grep -qE '^[[:space:]]*xkb[[:space:]]*\{[[:space:]]*$' "$nfx_full" 2>/dev/null; then
        return 0
    fi
    if [ "$DRY_RUN" = true ]; then
        log "dry-run: would add xkb layout \"us\" to $nfx_file"
        return 0
    fi
    backup_file "$nfx_file" || return 1
    if ! new_tmp; then
        fail_step "mktemp 失败"
        return 1
    fi
    nfx_tmp=$nt_path
    # 插在第一个 xkb { 行之后，12 空格缩进与 seed 一致。
    awk '
        {
            print
            if (!done && $0 ~ /^[[:space:]]*xkb[[:space:]]*\{[[:space:]]*$/) {
                print "            layout \"us\""
                done = 1
            }
        }
    ' "$nfx_full" >"$nfx_tmp" || {
        drop_tmp "$nfx_tmp"
        fail_step "改写失败：$nfx_file"
        return 1
    }
    if same_content "$nfx_tmp" "$nfx_full"; then
        drop_tmp "$nfx_tmp"
        return 0
    fi
    if ! rollback_snapshot "$nfx_full"; then
        drop_tmp "$nfx_tmp"
        fail_step "回滚基线创建失败：$nfx_file"
        return 1
    fi
    nfx_orig=$rb_path
    cat "$nfx_tmp" >"$nfx_full"
    drop_tmp "$nfx_tmp"
    # 自检：活动行必须真的落盘（awk 未命中 xkb 行时能兜住）。
    if ! grep -qE '^[[:space:]]*layout[[:space:]]+"us"' "$nfx_full" 2>/dev/null; then
        warn "$nfx_file 的 xkb layout 未写入，已回滚"
        restore_snapshot "$nfx_orig" "$nfx_full" "$nfx_file" || warn "回滚失败：$nfx_file"
        drop_tmp "$nfx_orig"
        return 1
    fi
    nfx_validator=
    if have_bin niri-anland; then
        nfx_validator=niri-anland
    elif have_bin niri; then
        nfx_validator=niri
    fi
    if [ -n "$nfx_validator" ]; then
        if ! nfx_err=$("$nfx_validator" validate -c "$nfx_full" 2>&1); then
            warn "$nfx_file 校验失败，已回滚：$(printf '%s' "$nfx_err" | tr '\n' ' ' | cut -c1-300)"
            restore_snapshot "$nfx_orig" "$nfx_full" "$nfx_file" || warn "回滚失败：$nfx_file"
            drop_tmp "$nfx_orig"
            return 1
        fi
    fi
    drop_tmp "$nfx_orig"
    log "fixed: $nfx_file（xkb layout us）"
    return 0
}

# 是否存在某个按键的「活动」绑定行（忽略 // 与 /- 注释）。
# 只比较键名本身，避免 Mod+S 误判成 Mod+Shift+...。
niri_bind_line() {
    nbl_file=$1
    nbl_key=$2
    nbl_need=${3:-}
    awk -v k="$nbl_key" -v need="$nbl_need" '
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (line ~ /^\/\// || line ~ /^\/-/) next
            if (index(line, k) != 1) next
            if (substr(line, length(k) + 1) !~ /^[[:space:]]/) next
            if (need != "" && index(line, need) == 0) next
            found = 1
            exit
        }
        END { exit(found ? 0 : 1) }
    ' "$nbl_file" 2>/dev/null
}

# Noctalia 面板键位：只注入已存在的 binds 块内。binds 是单例节点，
# 再追加一个 binds 块会让 niri 整份配置校验失败。
# 同时把旧绑定就地换掉：Mod+D 的 fuzzel（包已删除）、Mod+Comma 的
# consume-window-into-column（改为设置面板）。
niri_inject_binds() {
    nib_file=$1
    nib_full=$ROOT$nib_file
    path_exists "$nib_file" || return 2
    if ! grep -qE '^[[:space:]]*binds[[:space:]]*\{' "$nib_full" 2>/dev/null; then
        warn "$nib_file 没有 binds 块，跳过 Noctalia 键位注入"
        return 2
    fi
    nib_need_space=true
    nib_need_control=true
    nib_need_e=true
    nib_fix_comma=false
    nib_fix_d=false
    if niri_bind_line "$nib_full" 'Mod+Space'; then nib_need_space=false; fi
    if niri_bind_line "$nib_full" 'Mod+S'; then nib_need_control=false; fi
    # Mod+E 打开文件管理器。niri_bind_line 按键名整词比较，
    # 不会把 Mod+Escape 当成 Mod+E。
    if niri_bind_line "$nib_full" 'Mod+E'; then nib_need_e=false; fi
    if niri_bind_line "$nib_full" 'Mod+Comma' 'consume-window-into-column'; then
        nib_fix_comma=true
    fi
    # fuzzel 已不在安装清单，老配置里的 Mod+D 会 spawn 一个不存在的程序。
    if niri_bind_line "$nib_full" 'Mod+D' 'fuzzel'; then
        nib_fix_d=true
    fi
    if [ "$nib_need_space" = false ] && [ "$nib_need_control" = false ] && \
        [ "$nib_need_e" = false ] && \
        [ "$nib_fix_comma" = false ] && [ "$nib_fix_d" = false ]; then
        return 0
    fi
    if [ "$DRY_RUN" = true ]; then
        log "dry-run: would inject Noctalia keybinds into $nib_file"
        return 0
    fi
    if ! new_tmp; then
        fail_step "mktemp 失败"
        return 1
    fi
    nib_tmp=$nt_path
    awk -v need_space="$nib_need_space" -v need_control="$nib_need_control" \
        -v need_e="$nib_need_e" \
        -v fix_comma="$nib_fix_comma" -v fix_d="$nib_fix_d" '
        function inject(ind) {
            if (need_e == "true" && !done_e) {
                print ind "Mod+E hotkey-overlay-title=\"Open Files: nemo\" { spawn \"nemo\"; }"
                done_e = 1
            }
            if (need_space == "true" && !done_space) {
                print ind "Mod+Space hotkey-overlay-title=\"Toggle Launcher: noctalia\" { spawn-sh \"noctalia msg panel-toggle launcher\"; }"
                done_space = 1
            }
            if (need_control == "true" && !done_control) {
                print ind "Mod+S hotkey-overlay-title=\"Open Control Center: noctalia\" { spawn-sh \"noctalia msg panel-open control-center\"; }"
                done_control = 1
            }
        }
        {
            line = $0
            probe = line
            sub(/^[[:space:]]+/, "", probe)
            is_cmt = (probe ~ /^\/\// || probe ~ /^\/-/)

            if (!in_binds && !is_cmt && probe ~ /^binds[[:space:]]*\{/) in_binds = 1

            # Mod+D 原来 spawn fuzzel；fuzzel 已从安装清单删除（D11），改走 Noctalia。
            if (in_binds && fix_d == "true" && !done_d && !is_cmt && \
                index(probe, "Mod+D") == 1 && index(line, "fuzzel") > 0) {
                ind = substr(line, 1, length(line) - length(probe))
                print ind "Mod+D hotkey-overlay-title=\"Toggle Launcher: noctalia\" { spawn-sh \"noctalia msg panel-toggle launcher\"; }"
                done_d = 1
                next
            }
            # Mod+Comma 原绑定换成 Noctalia 设置开关。
            if (in_binds && fix_comma == "true" && !done_comma && !is_cmt && \
                index(probe, "Mod+Comma") == 1 && index(line, "consume-window-into-column") > 0) {
                ind = substr(line, 1, length(line) - length(probe))
                print ind "Mod+Comma hotkey-overlay-title=\"Toggle Settings: noctalia\" { spawn-sh \"noctalia msg settings-toggle\"; }"
                done_comma = 1
                next
            }
            if (in_binds && !is_cmt) {
                tmp = line
                opens = gsub(/{/, "{", tmp)
                tmp = line
                closes = gsub(/}/, "}", tmp)
                depth += opens - closes
                # binds 块收尾：在闭合括号前补缺失的键位。
                if (depth == 0) {
                    inject("    ")
                    in_binds = 0
                }
            }
            print
        }
    ' "$nib_full" >"$nib_tmp" || {
        drop_tmp "$nib_tmp"
        fail_step "改写失败：$nib_file"
        return 1
    }
    if same_content "$nib_tmp" "$nib_full"; then
        drop_tmp "$nib_tmp"
        return 0
    fi
    if ! rollback_snapshot "$nib_full"; then
        drop_tmp "$nib_tmp"
        fail_step "回滚基线创建失败：$nib_file"
        return 1
    fi
    nib_orig=$rb_path
    cat "$nib_tmp" >"$nib_full"
    drop_tmp "$nib_tmp"
    # 自检：该补的键位必须真的落进 binds 块内（awk 找不到闭合括号时能兜住）。
    nib_ok=true
    if [ "$nib_need_space" = true ] && ! niri_bind_line "$nib_full" 'Mod+Space'; then
        nib_ok=false
    fi
    if [ "$nib_need_control" = true ] && ! niri_bind_line "$nib_full" 'Mod+S'; then
        nib_ok=false
    fi
    if [ "$nib_need_e" = true ] && ! niri_bind_line "$nib_full" 'Mod+E'; then
        nib_ok=false
    fi
    if [ "$nib_fix_comma" = true ] && \
        niri_bind_line "$nib_full" 'Mod+Comma' 'consume-window-into-column'; then
        nib_ok=false
    fi
    if [ "$nib_fix_d" = true ] && niri_bind_line "$nib_full" 'Mod+D' 'fuzzel'; then
        nib_ok=false
    fi
    if [ "$nib_ok" = false ]; then
        warn "$nib_file 键位注入未生效，已回滚"
        restore_snapshot "$nib_orig" "$nib_full" "$nib_file" || warn "回滚失败：$nib_file"
        drop_tmp "$nib_orig"
        return 1
    fi
    nib_validator=
    if have_bin niri-anland; then
        nib_validator=niri-anland
    elif have_bin niri; then
        nib_validator=niri
    fi
    if [ -n "$nib_validator" ]; then
        if ! nib_err=$("$nib_validator" validate -c "$nib_full" 2>&1); then
            warn "$nib_file 校验失败，已回滚：$(printf '%s' "$nib_err" | tr '\n' ' ' | cut -c1-300)"
            restore_snapshot "$nib_orig" "$nib_full" "$nib_file" || warn "回滚失败：$nib_file"
            drop_tmp "$nib_orig"
            return 1
        fi
    fi
    drop_tmp "$nib_orig"
    log "fixed: $nib_file（Noctalia 键位）"
    return 0
}

step_niri_extra() {
    if [ -z "$USER_HOME" ]; then
        skip_step "未找到普通用户"
        return 2
    fi
    # 顺序很重要：先把老配置里的非法/过期写法就地修好，最后才跑
    # niri_apply_extras 追加受管块并做整份 validate。旧版脚本留下的单行内联
    # window-rule（background-effect 内联）会让 apply_extras 校验失败并回滚，
    # 所以 terminal_blur 的修复必须排在它前面。
    for niri_cfg in "$USER_HOME/.config/niri/config.kdl"         /usr/local/share/droidspaces/niri-default-config.kdl         /etc/skel/.config/niri/config.kdl; do
        niri_fix_launchers "$niri_cfg" || true
        niri_fix_xkb_layout "$niri_cfg" || true
        niri_fix_layout_noctalia "$niri_cfg" || true
        niri_fix_shadow "$niri_cfg" || true
        niri_fix_terminal_blur "$niri_cfg" || true
        niri_fix_corner_radius "$niri_cfg" || true
        niri_inject_binds "$niri_cfg" || true
    done
    # 外观块最后加：它的 validate 覆盖整份文件，前面必须已经没有坏写法。
    niri_apply_extras "$USER_HOME/.config/niri/config.kdl" || return $?
    niri_apply_extras /usr/local/share/droidspaces/niri-default-config.kdl || true
    # /etc/skel 也要拿到同一套外观块，否则新建用户没有透明背景/圆角/模糊。
    niri_apply_extras /etc/skel/.config/niri/config.kdl || true
    kitty_drop_background_blur || true
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

# 13b) /etc/skel：把用户侧同名配置再铺一份，新建用户直接可用。
# 只复制配置文本，不复制 Rime 数据本体（build/ 与 userdb 由首次部署生成）。
# skel 文件保持 root:root 0644，install_content 不会对其 chown。
step_skel() {
    sk_dir=/etc/skel
    sk_copied=false
    for sk_item in \
        "fcitx5/config|.config/fcitx5/config" \
        "fcitx5/profile|.config/fcitx5/profile" \
        "fcitx5/conf/classicui.conf|.config/fcitx5/conf/classicui.conf" \
        "fcitx5/rime/default.custom.yaml|.config/fcitx5/rime/default.custom.yaml" \
        "gtk-3.0/settings.ini|.config/gtk-3.0/settings.ini" \
        "gtk-3.0/gtk.css|.config/gtk-3.0/gtk.css" \
        "gtk-4.0/settings.ini|.config/gtk-4.0/settings.ini" \
        "gtk-4.0/gtk.css|.config/gtk-4.0/gtk.css" \
        "kitty/themes/frappe.conf|.config/kitty/themes/frappe.conf" \
        "fastfetch/config.jsonc|.config/fastfetch/config.jsonc" \
        "fontconfig/fonts.conf|.config/fontconfig/fonts.conf" \
        "environment.d/gtk.conf|.config/environment.d/gtk.conf" \
        "environment.d/input.conf|.config/environment.d/input.conf" \
        "noctalia/config.toml|.config/noctalia/config.toml" \
        "xdg-terminal-exec/terminal-exec|.config/xdg-terminal-exec/xdg-terminals.list" \
        "xdg-user-dirs/user-dirs.dirs|.config/user-dirs.dirs" \
        "nvim/init.lua|.config/nvim/init.lua"; do
        sk_rel=${sk_item%%|*}
        sk_dst=${sk_item#*|}
        if [ ! -r "$ASSETS_DIR/$sk_rel" ]; then
            log "skel: 跳过缺失资产 $sk_rel"
            continue
        fi
        install_asset "$sk_dir/$sk_dst" "$sk_rel" 0644 || return 1
        sk_copied=true
    done

    # kitty.conf 含 @FONT_SIZE@，与用户侧同样渲染后再落盘。
    if [ -r "$ASSETS_DIR/kitty/kitty.conf" ]; then
        install_asset "$sk_dir/.config/kitty/kitty.conf" kitty/kitty.conf 0644 \
            "s/@FONT_SIZE@/$FONT_SIZE/g" || return 1
        sk_copied=true
    else
        log "skel: 跳过缺失资产 kitty/kitty.conf"
    fi

    # fish/**：配置与插件胶水脚本（不含任何数据/缓存）。
    for sk_src in "$ASSETS_DIR"/fish/config.fish "$ASSETS_DIR"/fish/conf.d/*.fish \
        "$ASSETS_DIR"/fish/tide-apply.fish; do
        [ -f "$sk_src" ] || continue
        sk_rel=${sk_src#"$ASSETS_DIR"/}
        install_asset "$sk_dir/.config/$sk_rel" "$sk_rel" 0644 || return 1
        sk_copied=true
    done

    merge_mimeapps_into "$sk_dir/.config/mimeapps.list" || return 1
    sk_copied=true

    sk_unit=systemd/user/fcitx5-session.service
    if [ -r "$ASSETS_DIR/$sk_unit" ]; then
        install_asset "$sk_dir/.config/systemd/user/fcitx5-session.service" "$sk_unit" 0644 || return 1
        sk_want=$sk_dir/.config/systemd/user/default.target.wants
        if [ "$DRY_RUN" = true ]; then
            log "dry-run: would link $sk_want/fcitx5-session.service -> ../fcitx5-session.service"
        else
            if ! mkdir -p "$ROOT$sk_want"; then
                fail_step "无法创建 $sk_want"
                return 1
            fi
            if ! ln -sfn ../fcitx5-session.service "$ROOT$sk_want/fcitx5-session.service"; then
                fail_step "无法创建 skel wants 链接"
                return 1
            fi
        fi
        sk_copied=true
    else
        log "skel: 跳过缺失资产 $sk_unit"
    fi

    if [ "$sk_copied" = false ]; then
        skip_step "没有可同步到 /etc/skel 的资产"
        return 2
    fi
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

STEPS="pacman_mirrors archlinuxcn packages maple_font rime_ice locale environment fontconfig gtk_settings nvim kitty fish fcitx5 nemo noctalia niri_ime_autostart niri_extra user_dirs skel services"

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
