#!/bin/bash
# check-anland-rdp-bridge — ExecStartPre preflight for the anland-rdp-bridge
# service. Validates the binary, the EnvironmentFile, the service data dir,
# and the PID 1 bind mount of the private Android bridge socket, then checks
# the EnvironmentFile carries a valid 3389 listen address and a non-zero
# bridge token. Hard-fails (non-zero) so systemd never starts a misconfigured
# RDP server.
set -euo pipefail

readonly SERVICE_USER="anland-rdp-bridge"
readonly ENV_PATH="/etc/anland-rdp-bridge/env"
readonly DATA_DIR="/var/lib/anland-rdp-bridge"
readonly BRIDGE_DIR="/run/anland-rdp"
readonly ANDROID_BRIDGE_DIR="/data/local/tmp/anland-rdp"
readonly ANDROID_DATA_FS_BRIDGE_DIR="/local/tmp/anland-rdp"
readonly BINARY="/usr/bin/anland_rdp_bridge"

fail() {
    printf 'anland-rdp preflight failed: %s\n' "$1" >&2
    exit 1
}

[[ $EUID -eq 0 ]] || fail "preflight must run as root"
id "$SERVICE_USER" >/dev/null 2>&1 || fail "service user does not exist"
service_uid="$(id -u "$SERVICE_USER")"

[[ -x "$BINARY" ]] || fail "release binary is missing"
[[ -f "$ENV_PATH" && ! -L "$ENV_PATH" ]] || \
    fail "run setup-anland-rdp-bridge to create a regular EnvironmentFile"
[[ "$(stat -c '%a' "$ENV_PATH")" == "600" ]] || fail "EnvironmentFile mode must be 0600"
[[ "$(stat -c '%u' "$ENV_PATH")" == "$service_uid" ]] || \
    fail "EnvironmentFile must be owned by $SERVICE_USER"

[[ -d "$DATA_DIR" && ! -L "$DATA_DIR" ]] || fail "service data directory is missing or unsafe"
[[ "$(stat -c '%a' "$DATA_DIR")" == "700" ]] || fail "data directory mode must be 0700"
[[ "$(stat -c '%u' "$DATA_DIR")" == "$service_uid" ]] || \
    fail "data directory must be owned by $SERVICE_USER"

[[ -d "$BRIDGE_DIR" && ! -L "$BRIDGE_DIR" ]] || \
    fail "$BRIDGE_DIR must be a real directory"
bridge_mount="$(findmnt --task 1 --mountpoint "$BRIDGE_DIR" \
    --noheadings --raw --output TARGET,FSROOT || true)"
case "$bridge_mount" in
    "$BRIDGE_DIR $ANDROID_BRIDGE_DIR"|"$BRIDGE_DIR $ANDROID_DATA_FS_BRIDGE_DIR") ;;
    *) fail "$BRIDGE_DIR must be the PID 1 bind mount of $ANDROID_BRIDGE_DIR" ;;
esac
[[ "$(stat -c '%a' "$BRIDGE_DIR")" == "700" ]] || fail "$BRIDGE_DIR mode must be 0700"
[[ "$(stat -c '%u' "$BRIDGE_DIR")" == "$service_uid" ]] || \
    fail "$BRIDGE_DIR must be owned by $SERVICE_USER"

# EnvironmentFile must carry a :3389 listen address and a non-zero token.
if ! grep -Eq '^ANLAND_LISTEN=[^#[:space:]]+:3389$' "$ENV_PATH"; then
    fail "ANLAND_LISTEN is missing or not on port 3389"
fi
if ! grep -Eq '^ANLAND_BRIDGE_TOKEN=[0-9a-f]{32}$' "$ENV_PATH"; then
    fail "ANLAND_BRIDGE_TOKEN is missing or invalid (must be 32 lowercase hex chars)"
fi
if grep -Fxq 'ANLAND_BRIDGE_TOKEN=00000000000000000000000000000000' "$ENV_PATH"; then
    fail "all-zero bridge tokens are forbidden"
fi
grep -Fxq "ANLAND_BRIDGE_ENDPOINT=$BRIDGE_DIR/bridge.sock" "$ENV_PATH" || \
    fail "ANLAND_BRIDGE_ENDPOINT is unexpected (must be $BRIDGE_DIR/bridge.sock)"
