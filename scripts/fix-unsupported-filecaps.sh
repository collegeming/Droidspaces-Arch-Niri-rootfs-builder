#!/bin/sh
# Strip file capabilities that the container's capability bounding set does not
# contain. Linux rejects execve with EPERM when a file requests a capability
# outside the bounding set, even for root; this is what broke btop
# (cap_dac_read_search) and would break any future package with similar caps.
#
# Only files that actually carry capabilities are inspected (getcap -r), and
# capabilities supported by the bounding set are preserved. If capsh is not
# available the hook is a no-op rather than guessing.

[ -r /proc/self/status ] || exit 0
command -v getcap >/dev/null 2>&1 || exit 0
command -v setcap >/dev/null 2>&1 || exit 0
command -v capsh >/dev/null 2>&1 || exit 0

bnd=$(awk '/^CapBnd:/{print $2}' /proc/self/status)
[ -n "$bnd" ] || exit 0
supported=$(capsh --decode="$bnd" 2>/dev/null | sed 's/^[^=]*=//' | tr ',' '\n')
[ -n "$supported" ] || exit 0

getcap -r /usr/bin /usr/sbin /usr/lib /usr/lib64 /opt 2>/dev/null | while read -r path caps; do
    [ -n "$path" ] || continue
    [ -e "$path" ] || continue
    # getcap prints "cap_a,cap_b=ep"; keep the flag suffix when rebuilding.
    names=${caps%%=*}
    flags=${caps#*=}
    keep=
    missing=0
    oldifs=$IFS
    IFS=,
    for c in $names; do
        if printf '%s\n' "$supported" | grep -qx "$c"; then
            keep=${keep:+$keep,}$c
        else
            missing=1
        fi
    done
    IFS=$oldifs
    [ "$missing" = 1 ] || continue
    if [ -n "$keep" ]; then
        setcap "$keep=$flags" "$path" 2>/dev/null && \
            echo "trimmed unsupported file capabilities: $path ($caps -> $keep=$flags)"
    else
        setcap -r "$path" 2>/dev/null && \
            echo "stripped unsupported file capabilities: $path ($caps)"
    fi
done
exit 0
