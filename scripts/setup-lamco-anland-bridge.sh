#!/bin/bash
set +x
set -euo pipefail

readonly SERVICE_USER="lamco-anland-bridge"
readonly CONFIG_DIR="/etc/lamco-anland-bridge"
readonly CONFIG_PATH="$CONFIG_DIR/config.toml"
readonly TLS_DIR="/var/lib/lamco-anland-bridge"
readonly BRIDGE_DIR="/run/anland-rdp"
readonly ANDROID_BRIDGE_DIR="/data/local/tmp/anland-rdp"
readonly ANDROID_DATA_FS_BRIDGE_DIR="/local/tmp/anland-rdp"
readonly SERVICE="lamco-anland-bridge.service"

temp_config=""
bridge_token=""
rdp_username=""
rdp_password=""
cleanup() {
    [[ -z "$temp_config" ]] || rm -f "$temp_config"
    unset bridge_token rdp_username rdp_password
}
trap cleanup EXIT

fail() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

escape_toml_basic_string() {
    local value="$1"
    value="${value//\\/\\\\}"
    value="${value//\"/\\\"}"
    printf '%s' "$value"
}

[[ $EUID -eq 0 ]] || fail "run this setup command as root"
id "$SERVICE_USER" >/dev/null 2>&1 || fail "service user $SERVICE_USER does not exist"
[[ -x /usr/bin/lamco-anland-bridge ]] || fail "lamco-anland-bridge is not installed"
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

printf 'Android bridge token (32 lowercase hexadecimal characters): '
IFS= read -r -s bridge_token
printf '\n'
[[ "$bridge_token" =~ ^[0-9a-f]{32}$ ]] || \
    fail "the Android bridge token must be exactly 32 lowercase hexadecimal characters"
[[ "$bridge_token" != "00000000000000000000000000000000" ]] || \
    fail "refusing an all-zero Android bridge token"

printf 'RDP username: '
IFS= read -r rdp_username
[[ -n "$rdp_username" ]] || fail "the RDP username must not be empty"
[[ "$rdp_username" != *[[:cntrl:]]* ]] || \
    fail "the RDP username must not contain control characters"

printf 'RDP password (hidden, at least 12 characters): '
IFS= read -r -s rdp_password
printf '\n'
[[ ${#rdp_password} -ge 12 ]] || fail "the RDP password must contain at least 12 characters"
[[ "$rdp_password" != *[[:cntrl:]]* ]] || \
    fail "the RDP password must not contain control characters"
[[ "$rdp_password" != "$rdp_username" ]] || \
    fail "the RDP password must differ from the username"
case "${rdp_password,,}" in
    1234|password|password123|password1234|changeme|replace-with-a-strong-password)
        fail "refusing a known weak or placeholder RDP password"
        ;;
esac

printf 'Confirm RDP password: '
IFS= read -r -s password_confirmation
printf '\n'
[[ "$password_confirmation" == "$rdp_password" ]] || fail "RDP passwords do not match"
unset password_confirmation

if [[ -e "$CONFIG_PATH" || -L "$CONFIG_PATH" ]]; then
    [[ -f "$CONFIG_PATH" && ! -L "$CONFIG_PATH" ]] || \
        fail "$CONFIG_PATH exists but is not a regular non-symlink file"
    printf '%s already exists. Replace it? [y/N] ' "$CONFIG_PATH"
    IFS= read -r replace_config
    [[ "$replace_config" == "y" || "$replace_config" == "Y" ]] || \
        fail "configuration was not changed"
fi

if [[ -e "$CONFIG_DIR" || -L "$CONFIG_DIR" ]]; then
    [[ -d "$CONFIG_DIR" && ! -L "$CONFIG_DIR" ]] || \
        fail "$CONFIG_DIR must be a real directory"
fi
if [[ -e "$TLS_DIR" || -L "$TLS_DIR" ]]; then
    [[ -d "$TLS_DIR" && ! -L "$TLS_DIR" ]] || \
        fail "$TLS_DIR must be a real directory"
fi
install -d -o root -g root -m 0755 "$CONFIG_DIR"
install -d -o "$service_uid" -g "$service_gid" -m 0700 "$TLS_DIR"
temp_config="$(mktemp "$CONFIG_DIR/.config.toml.XXXXXX")"
chmod 0600 "$temp_config"
chown "$service_uid:$service_gid" "$temp_config"

escaped_username="$(escape_toml_basic_string "$rdp_username")"
escaped_password="$(escape_toml_basic_string "$rdp_password")"
cat > "$temp_config" <<EOF
[server]
listen_addr = "0.0.0.0:3389"
handshake_timeout_seconds = 15

[security]
cert_path = "$TLS_DIR/cert.pem"
key_path = "$TLS_DIR/key.pem"
require_tls_13 = false

[security.credentials]
username = "$escaped_username"
password = "$escaped_password"

[anland_bridge]
endpoint = "$BRIDGE_DIR/bridge.sock"
token = "$bridge_token"
width = 1920
height = 1080
fps = 30
EOF
chmod 0600 "$temp_config"
chown "$service_uid:$service_gid" "$temp_config"
mv -f "$temp_config" "$CONFIG_PATH"
temp_config=""

systemctl daemon-reload
systemctl restart "$SERVICE"
systemctl enable "$SERVICE"
printf 'Lamco Anland RDP is configured for TLS-protected access on port 3389.\n'
printf 'Restrict TCP 3389 to trusted clients and never expose the private bridge socket.\n'
