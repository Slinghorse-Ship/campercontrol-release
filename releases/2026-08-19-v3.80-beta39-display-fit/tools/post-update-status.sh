#!/bin/sh

set -u

release_id=2026-08-19-v3.80-beta39-display-fit
expected_venus_version='v3.80~39'
expected_arch=armv7l
expected_gx_hash=__GX_BINARY_SHA256__
expected_wasm_hash=__WASM_GZIP_SHA256__
release_root=/data/campercontrol/releases/$release_id
version_file=/opt/victronenergy/version
gx_binary=/opt/victronenergy/gui-v2/venus-gui-v2
wasm_gzip=/var/www/venus/gui-v2/venus-gui-v2.wasm.gz

value_or_missing() {
	if [ -f "$1" ]; then
		cat "$1" | tr -d '\r\n'
	else
		printf 'missing'
	fi
}

actual_version=$(value_or_missing "$version_file")
actual_arch=$(uname -m 2>/dev/null || printf 'unknown')
release_integrity=missing
if [ -f "$release_root/checksums.sha256" ]; then
	if (cd "$release_root" && sha256sum -c checksums.sha256 >/dev/null 2>&1); then
		release_integrity=ok
	else
		release_integrity=failed
	fi
fi

modifications=unknown
if [ -e /data/rc.local.disabled ]; then
	modifications=disabled
elif [ -f /data/rc.local ] && [ -x /data/rc.local ]; then
	modifications=enabled
elif [ -f /data/rc.local ]; then
	modifications=not-executable
else
	modifications=missing
fi

gx_hash=missing
[ -f "$gx_binary" ] && gx_hash=$(sha256sum "$gx_binary" | awk '{print $1}')
wasm_hash=missing
[ -f "$wasm_gzip" ] && wasm_hash=$(sha256sum "$wasm_gzip" | awk '{print $1}')

service_link=missing
if [ -L /service/campercontrol-dbus ]; then
	service_link=$(readlink /service/campercontrol-dbus)
elif [ -e /service/campercontrol-dbus ]; then
	service_link=unexpected-non-symlink
fi

service_status=unavailable
if [ -e /service/campercontrol-dbus ]; then
	service_status=$(svstat /service/campercontrol-dbus 2>&1 || true)
fi

dbus_api_connected=unavailable
if command -v dbus >/dev/null 2>&1; then
	dbus_api_connected=$(dbus -y com.victronenergy.campercontrol /Status/ApiConnected GetValue 2>&1 || true)
fi

node_api=unavailable
if command -v wget >/dev/null 2>&1; then
	if wget -q -T 5 -O /dev/null http://127.0.0.1:1880/camper/api/v2/state; then
		node_api=reachable
	fi
fi

reinstall_allowed=1
[ "$actual_version" = "$expected_venus_version" ] || reinstall_allowed=0
[ "$actual_arch" = "$expected_arch" ] || reinstall_allowed=0
[ "$release_integrity" = ok ] || reinstall_allowed=0
[ "$modifications" = enabled ] || reinstall_allowed=0

printf 'RELEASE_ID=%s\n' "$release_id"
printf 'RELEASE_ROOT=%s\n' "$release_root"
printf 'RELEASE_INTEGRITY=%s\n' "$release_integrity"
printf 'VENUS_VERSION=%s\n' "$actual_version"
printf 'EXPECTED_VENUS_VERSION=%s\n' "$expected_venus_version"
printf 'ARCHITECTURE=%s\n' "$actual_arch"
printf 'EXPECTED_ARCHITECTURE=%s\n' "$expected_arch"
printf 'VENUS_MODIFICATIONS=%s\n' "$modifications"
printf 'GX_SHA256=%s\n' "$gx_hash"
printf 'EXPECTED_GX_SHA256=%s\n' "$expected_gx_hash"
printf 'WASM_GZIP_SHA256=%s\n' "$wasm_hash"
printf 'EXPECTED_WASM_GZIP_SHA256=%s\n' "$expected_wasm_hash"
printf 'CAMPERCONTROL_SERVICE_LINK=%s\n' "$service_link"
printf 'CAMPERCONTROL_SERVICE_STATUS=%s\n' "$service_status"
printf 'CAMPERCONTROL_DBUS_API_CONNECTED=%s\n' "$dbus_api_connected"
printf 'NODE_RED_API=%s\n' "$node_api"
printf 'REINSTALL_ALLOWED=%s\n' "$reinstall_allowed"
