#!/bin/sh
set -eu

BINFMT_MISC="/proc/sys/fs/binfmt_misc"

log() { echo "qemu-binfmt: $*"; }

# kernel support check
if ! grep -q binfmt_misc /proc/filesystems 2>/dev/null; then
    log "binfmt_misc not supported by kernel, skipping"
    exit 0
fi

# mount if needed
if ! grep -q "$BINFMT_MISC" /proc/mounts; then
    if ! mount -t binfmt_misc binfmt_misc "$BINFMT_MISC"; then
        log "failed to mount binfmt_misc, skipping"
        exit 0
    fi
fi

# success
exit 0
