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
    # getcap prints "cap_a,cap_b=ep"; flags are not part of the name.
    caps=${caps%%=*}
    missing=0
    oldifs=$IFS
    IFS=,
    for c in $caps; do
        printf '%s\n' "$supported" | grep -qx "$c" || missing=1
    done
    IFS=$oldifs
    if [ "$missing" = 1 ]; then
        if setcap -r "$path" 2>/dev/null; then
            echo "stripped unsupported file capabilities: $path ($caps)"
        fi
    fi
done
exit 0
