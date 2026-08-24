#!/bin/bash
set -euo pipefail

readonly SERVICE_USER="lamco-anland-bridge"
readonly CONFIG_PATH="/etc/lamco-anland-bridge/config.toml"
readonly TLS_DIR="/var/lib/lamco-anland-bridge"
readonly BRIDGE_DIR="/run/anland-rdp"
readonly ANDROID_BRIDGE_DIR="/data/local/tmp/anland-rdp"
readonly ANDROID_DATA_FS_BRIDGE_DIR="/local/tmp/anland-rdp"

fail() {
    printf 'Lamco preflight failed: %s\n' "$1" >&2
    exit 1
}

[[ $EUID -eq 0 ]] || fail "preflight must run as root"
id "$SERVICE_USER" >/dev/null 2>&1 || fail "service user does not exist"
service_uid="$(id -u "$SERVICE_USER")"

[[ -x /usr/bin/lamco-anland-bridge ]] || fail "release binary is missing"
[[ -f "$CONFIG_PATH" && ! -L "$CONFIG_PATH" ]] || \
    fail "run setup-lamco-anland-bridge to create a regular config file"
[[ "$(stat -c '%a' "$CONFIG_PATH")" == "600" ]] || fail "config mode must be 0600"
[[ "$(stat -c '%u' "$CONFIG_PATH")" == "$service_uid" ]] || \
    fail "config must be owned by $SERVICE_USER"

[[ -d "$TLS_DIR" && ! -L "$TLS_DIR" ]] || fail "TLS directory is missing or unsafe"
[[ "$(stat -c '%a' "$TLS_DIR")" == "700" ]] || fail "TLS directory mode must be 0700"
[[ "$(stat -c '%u' "$TLS_DIR")" == "$service_uid" ]] || \
    fail "TLS directory must be owned by $SERVICE_USER"

[[ -d "$BRIDGE_DIR" && ! -L "$BRIDGE_DIR" ]] || \
    fail "$BRIDGE_DIR must be a real directory"
bridge_mount="$(findmnt --task 1 --mountpoint "$BRIDGE_DIR" \
    --noheadings --raw --output TARGET,FSROOT || true)"
case "$bridge_mount" in
    "$BRIDGE_DIR $ANDROID_BRIDGE_DIR"|"$BRIDGE_DIR $ANDROID_DATA_FS_BRIDGE_DIR") ;;
    *) fail "$BRIDGE_DIR must be the PID 1 bind mount of $ANDROID_BRIDGE_DIR" ;;
esac
[[ "$(stat -c '%a' "$BRIDGE_DIR")" == "700" ]] || \
    fail "$BRIDGE_DIR mode must be 0700"
[[ "$(stat -c '%u' "$BRIDGE_DIR")" == "$service_uid" ]] || \
    fail "$BRIDGE_DIR must be owned by $SERVICE_USER"

if ! grep -Eq '^listen_addr = "[^"[:space:]]+:3389"$' "$CONFIG_PATH"; then
    fail "RDP listen address is missing or not on port 3389"
fi
grep -Fxq '[security.credentials]' "$CONFIG_PATH" || \
    fail "RDP credentials are required"
grep -Eq '^username = ".+"$' "$CONFIG_PATH" || fail "RDP username is missing"
grep -Eq '^password = ".+"$' "$CONFIG_PATH" || fail "RDP password is missing"
grep -Fxq "cert_path = \"$TLS_DIR/cert.pem\"" "$CONFIG_PATH" || \
    fail "TLS certificate path is unexpected"
grep -Fxq "key_path = \"$TLS_DIR/key.pem\"" "$CONFIG_PATH" || \
    fail "TLS key path is unexpected"
grep -Fxq "endpoint = \"$BRIDGE_DIR/bridge.sock\"" "$CONFIG_PATH" || \
    fail "private bridge endpoint is unexpected"
grep -Eq '^token = "[0-9a-f]{32}"$' "$CONFIG_PATH" || \
    fail "Android bridge token is missing or invalid"
if grep -Fxq 'token = "00000000000000000000000000000000"' "$CONFIG_PATH"; then
    fail "all-zero Android bridge tokens are forbidden"
fi
