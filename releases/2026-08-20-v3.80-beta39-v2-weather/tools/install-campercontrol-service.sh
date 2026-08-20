#!/bin/sh

set -eu

release_id=2026-08-20-v3.80-beta39-v2-weather
release_root=/data/campercontrol/releases/$release_id
source_dir=$release_root/artifacts/cerbo-service
service_root=/data/campercontrol/service
service_dir=$service_root/campercontrol-dbus-service
service_link=/service/campercontrol-dbus
start_line=/data/campercontrol/service/ensure-campercontrol-dbus.sh
candidate=/data/campercontrol/.camper-dbus-$release_id.candidate
rollback=/data/campercontrol/.camper-dbus-$release_id.rollback
expected_version='v3.80~39'
expected_build='20260716174100'
expected_arch=armv7l
force_incompatible=0
committed=0
swap_started=0
old_service_had_link=0
old_service_was_up=0

wait_service_down() {
	path=$1
	i=0
	while [ "$i" -lt 15 ]; do
		if svstat "$path" 2>/dev/null | grep -q ': down '; then return 0; fi
		sleep 1
		i=$((i + 1))
	done
	svstat "$path" 2>/dev/null | grep -q ': down '
}

wait_service_up() {
	path=$1
	i=0
	while [ "$i" -lt 20 ]; do
		if svstat "$path" 2>/dev/null | grep -q ': up '; then return 0; fi
		sleep 1
		i=$((i + 1))
	done
	svstat "$path" 2>/dev/null | grep -q ': up '
}

stop_linked_service() {
	if [ -L "$service_link" ]; then
		svc -d "$service_link" >/dev/null 2>&1 || true
		wait_service_down "$service_link"
	fi
}

validate_bridge_identity() {
	dbus -y com.victronenergy.campercontrol /DeviceInstance GetValue 2>/dev/null | grep -Eq '(^|[^0-9])0([^0-9]|$)'
}

validate_weather_state() {
	python3 - <<'PY'
import json

import dbus

bus = dbus.SystemBus()
service = "com.victronenergy.campercontrol"


def value(path):
    obj = bus.get_object(service, path)
    return str(dbus.Interface(obj, "com.victronenergy.BusItem").GetValue())


weather = value("/State/Weather")
encoded = weather.encode("utf-8")
if len(encoded) > 16 * 1024:
    raise SystemExit(f"weather snapshot exceeds 16 KiB: {len(encoded)}")
document = json.loads(weather)
if not isinstance(document, dict):
    raise SystemExit("weather snapshot is not a JSON object")
if document:
    print(f"WEATHER_STATE=ready WEATHER_BYTES={len(encoded)}")
else:
    error = value("/Status/WeatherError").strip()
    detail = error if error else "initial_fetch_pending"
    print(f"WEATHER_STATE=pending WEATHER_BYTES={len(encoded)} DETAIL={detail}")
PY
}

if [ "$#" -gt 1 ]; then
	printf '%s\n' "Usage: $0 [--force-incompatible]" >&2
	exit 2
fi
if [ "$#" -eq 1 ]; then
	[ "$1" = --force-incompatible ] || exit 2
	force_incompatible=1
fi

cleanup() {
	status=$?
	trap - EXIT HUP INT TERM
	if [ "$status" -ne 0 ] && [ "$committed" -eq 0 ]; then
		# Stop the candidate process before restoring any executable underneath
		# it.  This also makes first-install rollback remove a quiescent link.
		if [ "$swap_started" -eq 1 ]; then
			stop_linked_service || true
		fi
		if [ "$swap_started" -eq 1 ] && [ -d "$rollback" ]; then
			for relative in campercontrol-dbus.py campercontrol_weather.py ensure-campercontrol-dbus.sh install-campercontrol-dbus.sh campercontrol-dbus-service; do
				case "$service_root/$relative" in
					/data/campercontrol/service/*) rm -rf "$service_root/$relative" ;;
					*) printf '%s\n' 'REFUSING_UNEXPECTED_SERVICE_ROLLBACK_TARGET' >&2 ;;
				esac
				[ -e "$rollback/$relative" ] && mv "$rollback/$relative" "$service_root/$relative"
			done
			if [ -f "$rollback/rc.local" ]; then
				cp -p "$rollback/rc.local" /data/rc.local
			elif [ -f "$rollback/rc.local.was-missing" ]; then
				rm -f /data/rc.local
			fi
		fi
		if [ "$swap_started" -eq 1 ] && [ -d "$rollback" ]; then
			if [ -f "$rollback/service-link.was-missing" ]; then
				[ ! -L "$service_link" ] || rm "$service_link"
			elif [ -f "$rollback/service-link.target" ]; then
				old_target=$(cat "$rollback/service-link.target")
				if [ -L "$service_link" ] && [ "$(readlink "$service_link")" != "$old_target" ]; then rm "$service_link"; fi
				[ -L "$service_link" ] || ln -s "$old_target" "$service_link"
			fi
			if [ "$old_service_had_link" -eq 1 ]; then
				if [ "$old_service_was_up" -eq 1 ]; then
					svc -u "$service_link" >/dev/null 2>&1 || true
					if wait_service_up "$service_link" && validate_bridge_identity; then
						printf '%s\n' 'CAMPERCONTROL_SERVICE_ROLLBACK_OK' >&2
					else
						printf '%s\n' 'CAMPERCONTROL_SERVICE_ROLLBACK_VALIDATION_FAILED' >&2
					fi
				else
					svc -d "$service_link" >/dev/null 2>&1 || true
				fi
			fi
		fi
	fi
	for path in "$candidate" "$rollback"; do
		case "$path" in
			/data/campercontrol/.camper-dbus-$release_id.candidate|/data/campercontrol/.camper-dbus-$release_id.rollback) [ ! -e "$path" ] || rm -rf "$path" ;;
			*) printf '%s\n' "REFUSING_UNEXPECTED_CLEANUP: $path" >&2 ;;
		esac
	done
	exit "$status"
}
trap cleanup EXIT HUP INT TERM

actual_version=$(sed -n '1{s/\r$//;p;}' /opt/victronenergy/version)
actual_build=$(sed -n '3{s/\r$//;p;}' /opt/victronenergy/version)
actual_arch=$(uname -m)
if [ "$actual_version" != "$expected_version" ] || [ "$actual_build" != "$expected_build" ] || [ "$actual_arch" != "$expected_arch" ]; then
	if [ "$force_incompatible" -ne 1 ]; then
		printf '%s\n' "INCOMPATIBLE: expected $expected_version/$expected_build/$expected_arch, got $actual_version/$actual_build/$actual_arch" >&2
		exit 3
	fi
	printf '%s\n' 'DANGER: forcing the transport service onto an unpinned firmware/architecture.' >&2
fi

test "$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)" = "$release_root"
test -f "$release_root/release.json"
test -f "$release_root/checksums.sha256"
if grep -q '__PENDING_' "$release_root/release.json"; then
	printf '%s\n' 'SERVICE_INSTALL_BLOCKED_RELEASE_NOT_FINAL' >&2
	exit 5
fi
(cd "$release_root" && sha256sum -c checksums.sha256 >/dev/null)
test -d /data/campercontrol
test ! -L /data/campercontrol
if [ -e "$service_root" ]; then
	test -d "$service_root"
	test ! -L "$service_root"
fi
test -f "$source_dir/campercontrol-dbus.py"
test -f "$source_dir/campercontrol_weather.py"
test -f "$source_dir/ensure-campercontrol-dbus.sh"
test -f "$source_dir/install-campercontrol-dbus.sh"
test -f "$source_dir/campercontrol-dbus-service/run"
test ! -e /data/rc.local.disabled
test ! -e "$candidate"
test ! -e "$rollback"
if [ -e "$service_link" ] && [ ! -L "$service_link" ]; then
	printf '%s\n' "REFUSING_NON_SYMLINK_SERVICE: $service_link" >&2
	exit 4
fi
if [ -L "$service_link" ] && [ "$(readlink "$service_link")" != "$service_dir" ]; then
	printf '%s\n' "REFUSING_FOREIGN_SERVICE_LINK: $service_link" >&2
	exit 4
fi

if [ -L "$service_link" ]; then
	old_service_had_link=1
	if svstat "$service_link" 2>/dev/null | grep -q ': up '; then old_service_was_up=1; fi
fi

same=1
for relative in campercontrol-dbus.py campercontrol_weather.py ensure-campercontrol-dbus.sh install-campercontrol-dbus.sh campercontrol-dbus-service/run; do
	if [ ! -f "$service_root/$relative" ] || [ "$(sha256sum "$source_dir/$relative" | awk '{print $1}')" != "$(sha256sum "$service_root/$relative" | awk '{print $1}')" ]; then
		same=0
	fi
done
if [ "$same" -eq 1 ] && [ -L "$service_link" ] && grep -Fqx "$start_line" /data/rc.local 2>/dev/null; then
	"$service_root/ensure-campercontrol-dbus.sh"
	wait_service_up "$service_link"
	validate_bridge_identity
	validate_weather_state
	printf 'CAMPERCONTROL_SERVICE_ALREADY_INSTALLED=%s\n' "$service_root"
	committed=1
	exit 0
fi

mkdir "$candidate" "$rollback"
cp -p "$source_dir/campercontrol-dbus.py" "$candidate/"
cp -p "$source_dir/campercontrol_weather.py" "$candidate/"
cp -p "$source_dir/ensure-campercontrol-dbus.sh" "$candidate/"
cp -p "$source_dir/install-campercontrol-dbus.sh" "$candidate/"
mkdir "$candidate/campercontrol-dbus-service"
cp -p "$source_dir/campercontrol-dbus-service/run" "$candidate/campercontrol-dbus-service/run"
chmod 0755 "$candidate/campercontrol-dbus.py" "$candidate/campercontrol_weather.py" "$candidate/ensure-campercontrol-dbus.sh" "$candidate/install-campercontrol-dbus.sh" "$candidate/campercontrol-dbus-service/run"

if [ -f /data/rc.local ]; then
	cp -p /data/rc.local "$rollback/rc.local"
else
	: > "$rollback/rc.local.was-missing"
fi
if [ -L "$service_link" ]; then
	printf '%s\n' "$(readlink "$service_link")" > "$rollback/service-link.target"
else
	: > "$rollback/service-link.was-missing"
fi

if [ "$old_service_had_link" -eq 1 ]; then
	stop_linked_service
fi

mkdir -p "$service_root"
test -d "$service_root"
test ! -L "$service_root"
swap_started=1
for relative in campercontrol-dbus.py campercontrol_weather.py ensure-campercontrol-dbus.sh install-campercontrol-dbus.sh campercontrol-dbus-service; do
	[ ! -e "$service_root/$relative" ] || mv "$service_root/$relative" "$rollback/$relative"
	mv "$candidate/$relative" "$service_root/$relative"
done
rmdir "$candidate"

"$service_root/install-campercontrol-dbus.sh"
wait_service_up "$service_link"
validate_bridge_identity
dbus -y com.victronenergy.campercontrol /Status/WeatherError GetValue >/dev/null 2>&1
dbus -y com.victronenergy.campercontrol /State/Weather GetValue >/dev/null 2>&1
validate_weather_state

committed=1
rm -rf "$rollback"
trap - EXIT HUP INT TERM
printf 'CAMPERCONTROL_SERVICE_INSTALLED=%s\n' "$service_root"
