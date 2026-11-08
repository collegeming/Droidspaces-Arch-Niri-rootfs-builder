#!/usr/bin/env bash

anland_package_family() {
    local desktop="${1:-}"
    local backend="${2:-}"

    [[ "$backend" == anland-wayland ]] || return 1
    case "$desktop" in
        kde|kde-mobile) printf '%s\n' kde ;;
        gnome) printf '%s\n' gnome ;;
        # Release 是 anland-session-packages / anland-session-manifest，
        # 正好是 anland-${family}-packages / anland-${family}-manifest 的形状。
        anland-next) printf '%s\n' session ;;
        niri|hyprland|mango|denial) printf '%s\n' "$desktop" ;;
        *) return 1 ;;
    esac
}

# Download one release asset. GitHub's web CDN occasionally answers 5xx to CI
# runners, so retry with backoff and fall back to the REST asset endpoint,
# which streams the same bytes. GH_MIRROR_PREFIX can point at a GitHub mirror
# (for example https://ghfast.top/); runners with direct access leave it unset.
anland_fetch_release_asset() {
    local repository="$1"
    local tag="$2"
    local asset="$3"
    local base="https://github.com/${repository}/releases/download/${tag}/${asset}"
    local prefix="${GH_MIRROR_PREFIX:-}"
    local token="${GITHUB_TOKEN:-}"
    local url tmp attempt id
    local -a auth=()

    tmp="$(mktemp)" || return 1
    for attempt in 1 2 3 4 5; do
        if [[ -n "$prefix" ]]; then
            url="${prefix%/}/${base}"
        else
            url="$base"
        fi
        if curl -fsSL --connect-timeout 20 --max-time 90 \
            --retry 3 --retry-delay 5 --retry-all-errors -o "$tmp" "$url"; then
            cat "$tmp"
            rm -f "$tmp"
            return 0
        fi
        [[ "$attempt" -lt 5 ]] && sleep $((attempt * 10))
    done

    [[ -n "$token" ]] && auth=(-H "Authorization: Bearer ${token}")
    if command -v jq >/dev/null 2>&1; then
        id="$(curl -fsSL --connect-timeout 20 --max-time 60 "${auth[@]}" \
            -H 'Accept: application/vnd.github+json' \
            "https://api.github.com/repos/${repository}/releases/tags/${tag}" 2>/dev/null |
            jq -r --arg name "$asset" '.assets[] | select(.name == $name) | .id' |
            head -n 1)"
    fi
    if [[ -n "$id" ]] && curl -fsSL --connect-timeout 20 --max-time 90 \
        "${auth[@]}" -H 'Accept: application/octet-stream' \
        -o "$tmp" "https://api.github.com/repos/${repository}/releases/assets/${id}"; then
        cat "$tmp"
        rm -f "$tmp"
        return 0
    fi
    rm -f "$tmp"
    return 1
}

anland_prepare_release() {
    local family="${1:-}"
    local repository="${2:-}"
    local revision="${3:-}"
    local manifest release_manifest

    case "$family" in kde|gnome|session|niri|hyprland|mango|denial) ;; *) return 1 ;; esac
    [[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || {
        echo "错误：Wayland 软件包仓库必须是 owner/repository 格式。" >&2
        return 1
    }

    ANLAND_RESOLVED_RELEASE_TAG="anland-${family}-packages"
    ANLAND_RESOLVED_REVISION="$revision"
    if [[ -n "$ANLAND_RESOLVED_REVISION" ]]; then
        [[ "$ANLAND_RESOLVED_REVISION" =~ ^[A-Za-z0-9._-]+$ ]] || {
            echo "错误：Anland 包 revision 格式无效。" >&2
            return 1
        }
        return
    fi

    command -v curl >/dev/null 2>&1 || {
        echo "错误：启用 Anland 时需要 curl 读取软件包 Release 清单。" >&2
        return 1
    }
    manifest="anland-${family}-manifest"
    if ! release_manifest="$(anland_fetch_release_asset \
        "$repository" "$ANLAND_RESOLVED_RELEASE_TAG" "$manifest")"; then
        echo "错误：无法下载 Anland ${family^^} 包 Release 清单。" >&2
        return 1
    fi

    ANLAND_RESOLVED_REVISION="$(printf '%s\n' "$release_manifest" | awk -F= '
        $1 == "format" { format = substr($0, index($0, "=") + 1) }
        $1 == "revision" { revision = substr($0, index($0, "=") + 1); revisions++ }
        END {
            if (format == "1" && revisions == 1 && revision ~ /^[A-Za-z0-9._-]+$/) {
                print revision
            }
        }
    ')"
    [[ -n "$ANLAND_RESOLVED_REVISION" ]] || {
        echo "错误：Release 清单缺少有效 revision。" >&2
        return 1
    }
}
