#!/bin/sh
# noctalia-location-sync.sh: keep Noctalia's location pinned to the public IP's
# city instead of a hard-coded address.
#
# Noctalia's built-in auto locate calls https://api.noctalia.dev/geolocate,
# which for carrier-NAT addresses can return a country centroid with city=null.
# This helper asks two independent IP geolocation services, writes the detected
# city into Noctalia's settings.toml ([location] auto_locate=false), and lets
# Noctalia's own config watcher re-resolve weather. It runs once at session
# start and then every 30 minutes.
#
# Sources, in order:
#   1. https://ipinfo.io/json        city + "lat,lon"
#   2. https://ipwho.is/             city + latitude/longitude
#   3. https://api.noctalia.dev/geolocate  lat/lng only (address left empty, so
#      Noctalia uses the manual-coordinate path)
#
# No hard-coded city: if every source fails, the existing setting is left alone.

PATH=/usr/local/bin:/usr/bin:/usr/sbin:/bin:/sbin
export PATH

settings="${NOCTALIA_SETTINGS:-$HOME/.local/state/noctalia/settings.toml}"
log() { printf '%s %s\n' "$(date '+%F %T')" "$*"; }

fetch() {
    # fetch URL TIMEOUT
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL --max-time 8 "$1" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q -T 8 -O - "$1" 2>/dev/null
    fi
}

# Sets: city lat lon
detect_ip_location() {
    city= lat= lon=

    body=$(fetch "https://ipinfo.io/json")
    if [ -n "$body" ]; then
        city=$(printf '%s' "$body" | sed -n 's/.*"city"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
        loc=$(printf '%s' "$body" | sed -n 's/.*"loc"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
        lat=${loc%%,*}
        lon=${loc#*,}
        [ "$lon" = "$loc" ] && lon=
        [ -n "$lat" ] && [ -n "$lon" ] && { printf '%s\n' "$city|$lat|$lon"; return 0; }
    fi

    body=$(fetch "https://ipwho.is/")
    if [ -n "$body" ]; then
        printf '%s' "$body" | grep -q '"success"[[:space:]]*:[[:space:]]*true' || body=
    fi
    if [ -n "$body" ]; then
        city=$(printf '%s' "$body" | sed -n 's/.*"city"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
        lat=$(printf '%s' "$body" | sed -n 's/.*"latitude"[[:space:]]*:[[:space:]]*\([-0-9.]*\).*/\1/p' | head -n1)
        lon=$(printf '%s' "$body" | sed -n 's/.*"longitude"[[:space:]]*:[[:space:]]*\([-0-9.]*\).*/\1/p' | head -n1)
        [ -n "$lat" ] && [ -n "$lon" ] && { printf '%s\n' "$city|$lat|$lon"; return 0; }
    fi

    body=$(fetch "https://api.noctalia.dev/geolocate")
    if [ -n "$body" ]; then
        city=$(printf '%s' "$body" | sed -n 's/.*"city"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1)
        lat=$(printf '%s' "$body" | sed -n 's/.*"lat"[[:space:]]*:[[:space:]]*\([-0-9.]*\).*/\1/p' | head -n1)
        lon=$(printf '%s' "$body" | sed -n 's/.*"lng"[[:space:]]*:[[:space:]]*\([-0-9.]*\).*/\1/p' | head -n1)
        [ -n "$lat" ] && [ -n "$lon" ] && { printf '%s\n' "$city|$lat|$lon"; return 0; }
    fi
    return 1
}

write_location() {
    # $1 city, $2 lat, $3 lon
    [ -r "$settings" ] || return 1
    tmp="$settings.tmp.$$"
    awk -v addr="$1" -v lat="$2" -v lon="$3" '
        BEGIN { inloc = 0; done = 0 }
        /^\[location\]$/ {
            inloc = 1; done = 1
            print
            print "auto_locate = false"
            print "address = \"" addr "\""
            if (lat != "" && lon != "") {
                print "latitude = " lat
                print "longitude = " lon
            }
            next
        }
        inloc && /^\[/ { inloc = 0 }
        inloc { next }
        { print }
        END {
            if (!done) {
                print ""
                print "[location]"
                print "auto_locate = false"
                print "address = \"" addr "\""
                if (lat != "" && lon != "") {
                    print "latitude = " lat
                    print "longitude = " lon
                }
            }
        }
    ' "$settings" > "$tmp" || { rm -f "$tmp"; return 1; }
    if cmp -s "$tmp" "$settings"; then
        rm -f "$tmp"
        return 2
    fi
    chmod 0644 "$tmp"
    mv "$tmp" "$settings"
}

sync_once() {
    line=$(detect_ip_location) || { log "ip location unavailable; keep current settings"; return 1; }
    city=${line%%|*}
    rest=${line#*|}
    lat=${rest%%|*}
    lon=${rest#*|}
    case "$lat" in ''|*[!0-9.-]*) log "invalid latitude: $lat"; return 1 ;; esac
    case "$lon" in ''|*[!0-9.-]*) log "invalid longitude: $lon"; return 1 ;; esac

    write_location "$city" "$lat" "$lon"
    rc=$?
    case $rc in
        0) log "location updated: city='${city:-（空）}' lat=$lat lon=$lon" ;;
        2) log "location unchanged: city='${city:-（空）}' lat=$lat lon=$lon" ;;
        *) log "failed to write $settings"; return 1 ;;
    esac
    return 0
}

# One immediate pass, then refresh periodically. A failed pass retries sooner.
sync_once || sleep 300

while :; do
    sleep 1800
    sync_once || sleep 300
done
