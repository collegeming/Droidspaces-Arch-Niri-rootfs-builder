#!/bin/bash
# setup-anland-rdp-bridge — interactive first-run configuration for the
# anland-rdp-bridge service.
#
# anland-rdp-bridge is ENV-driven (no config.toml, no RDP credentials — TLS
# with no NLA, self-signed cert generated on first run). This script collects
# the operator-supplied values (the bridge token MUST match the Android-side
# anland-bridge consumer), writes an EnvironmentFile the systemd unit sources,
# creates the service user + data dir, and enables the service.
set +x
set -euo pipefail

readonly SERVICE_USER="anland-rdp-bridge"
readonly ENV_DIR="/etc/anland-rdp-bridge"
readonly ENV_PATH="$ENV_DIR/env"
readonly DATA_DIR="/var/lib/anland-rdp-bridge"
readonly BRIDGE_DIR="/run/anland-rdp"
readonly ANDROID_BRIDGE_DIR="/data/local/tmp/anland-rdp"
readonly ANDROID_DATA_FS_BRIDGE_DIR="/local/tmp/anland-rdp"
readonly SERVICE="anland-rdp-bridge.service"
readonly BINARY="/usr/bin/anland_rdp_bridge"

temp_env=""
cleanup() {
    [[ -z "$temp_env" ]] || rm -f "$temp_env"
}
trap cleanup EXIT

fail() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

[[ $EUID -eq 0 ]] || fail "run this setup command as root"
id "$SERVICE_USER" >/dev/null 2>&1 || fail "service user $SERVICE_USER does not exist (install the anland-rdp variant first)"
[[ -x "$BINARY" ]] || fail "$BINARY is not installed"

# The private bridge socket lives at /run/anland-rdp/bridge.sock — a PID 1
# bind mount of the Android-side directory. It must already exist.
[[ -d "$BRIDGE_DIR" && ! -L "$BRIDGE_DIR" ]] || \
    fail "$BRIDGE_DIR must already be the Droidspaces directory bind mount"
bridge_mount="$(findmnt --task 1 --mountpoint "$BRIDGE_DIR" \
    --noheadings --raw --output TARGET,FSROOT || true)"
case "$bridge_mount" in
    "$BRIDGE_DIR $ANDROID_BRIDGE_DIR"|"$BRIDGE_DIR $ANDROID_DATA_FS_BRIDGE_DIR") ;;
    *) fail "$BRIDGE_DIR is not the PID 1 bind mount of $ANDROID_BRIDGE_DIR" ;;
esac

service_uid="$(id -u "$SERVICE_USER")"
service_gid="$(id -g "$SERVICE_USER")"
chown "$service_uid:$service_gid" "$BRIDGE_DIR"
chmod 0700 "$BRIDGE_DIR"

# --- operator-supplied configuration --------------------------------------
printf 'Android bridge token (32 lowercase hexadecimal characters): '
IFS= read -r -s bridge_token
printf '\n'
[[ "$bridge_token" =~ ^[0-9a-f]{32}$ ]] || \
    fail "the Android bridge token must be exactly 32 lowercase hexadecimal characters"
[[ "$bridge_token" != "00000000000000000000000000000000" ]] || \
    fail "refusing an all-zero Android bridge token"

printf 'RDP listen address [0.0.0.0:3389]: '
IFS= read -r listen_addr
listen_addr="${listen_addr:-0.0.0.0:3389}"
[[ "$listen_addr" =~ ^[0-9A-Za-z.]+:[0-9]+$ ]] || fail "invalid listen address: $listen_addr"

printf 'Stream width  [1280]: '
IFS= read -r width
width="${width:-1280}"
[[ "$width" =~ ^[0-9]+$ && "$width" -ge 320 && "$width" -le 8192 ]] || \
    fail "width must be 320..8192"

printf 'Stream height [720]: '
IFS= read -r height
height="${height:-720}"
[[ "$height" =~ ^[0-9]+$ && "$height" -ge 320 && "$height" -le 8192 ]] || \
    fail "height must be 320..8192"

printf 'Stream fps    [30]: '
IFS= read -r fps
fps="${fps:-30}"
[[ "$fps" =~ ^[0-9]+$ && "$fps" -ge 1 && "$fps" -le 60 ]] || \
    fail "fps must be 1..60"

# --- write the EnvironmentFile --------------------------------------------
if [[ -e "$ENV_PATH" || -L "$ENV_PATH" ]]; then
    [[ -f "$ENV_PATH" && ! -L "$ENV_PATH" ]] || fail "$ENV_PATH exists but is not a regular file"
    printf '%s already exists. Replace it? [y/N] ' "$ENV_PATH"
    IFS= read -r replace_env
    [[ "$replace_env" == "y" || "$replace_env" == "Y" ]] || fail "configuration was not changed"
fi
install -d -o root -g root -m 0755 "$ENV_DIR"
install -d -o "$service_uid" -g "$service_gid" -m 0700 "$DATA_DIR"
temp_env="$(mktemp "$ENV_DIR/.env.XXXXXX")"
chmod 0600 "$temp_env"
chown "$service_uid:$service_gid" "$temp_env"
cat > "$temp_env" <<EOF
# Managed by setup-anland-rdp-bridge — edit or re-run setup to change.
ANLAND_LISTEN=$listen_addr
ANLAND_BRIDGE_ENDPOINT=$BRIDGE_DIR/bridge.sock
ANLAND_BRIDGE_TOKEN=$bridge_token
ANLAND_WIDTH=$width
ANLAND_HEIGHT=$height
ANLAND_FPS=$fps
ANLAND_MAX_WIDTH=4096
ANLAND_MAX_HEIGHT=2160
EOF
chmod 0600 "$temp_env"
chown "$service_uid:$service_gid" "$temp_env"
mv -f "$temp_env" "$ENV_PATH"
temp_env=""

systemctl daemon-reload
systemctl restart "$SERVICE"
systemctl enable "$SERVICE"
printf 'Anland RDP Bridge is configured for TLS-protected access on %s.\n' "$listen_addr"
printf 'Restrict TCP 3389 to trusted clients and never expose the private bridge socket.\n'
printf 'Mirror the bridge token to the Android anland consumer if you have not already.\n'
