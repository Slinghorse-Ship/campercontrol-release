#!/bin/sh

set -eu

release_id=2026-08-20-v3.80-beta39-v2-weather
release_root=/data/campercontrol/releases/$release_id
source_dir=$release_root/artifacts/cerbo-service
service_root=/data/campercontrol/service
starlink_root=/data/campercontrol/starlink
dbus_service_dir=$service_root/campercontrol-dbus-service
dbus_service_link=/service/campercontrol-dbus
wifi_service_dir=$service_root/wifi-connect-http-service
wifi_service_link=/service/camper-wifi-connect
dbus_start_line=$service_root/ensure-campercontrol-dbus.sh
wifi_start_line=$service_root/ensure-wifi-connect-http.sh
sudoers_target=/etc/sudoers.d/campercontrol
candidate=/data/campercontrol/.camper-services-$release_id.candidate
rollback=/data/campercontrol/.camper-services-$release_id.rollback
expected_version='v3.80~39'
expected_build='20260716174100'
expected_arch=armv7l
expected_file_count=19
force_incompatible=0
committed=0
swap_started=0
old_dbus_had_link=0
old_dbus_was_up=0
old_dbus_had_dir=0
old_dbus_had_run=0
old_wifi_had_link=0
old_wifi_was_up=0
old_wifi_had_dir=0
old_wifi_had_run=0

# Complete positive allow-list for the frozen Cerbo payload. Paths below a
# runit service directory are swapped separately so updates preserve the
# directory/supervise inode.
service_files='
bluetooth-repair.sh
campercontrol_weather.py
campercontrol-dbus.py
cerbo-reboot.sh
device-http-bounded.py
ensure-campercontrol-dbus.sh
ensure-wifi-connect-http.sh
install-campercontrol-dbus.sh
install-privileges.sh
install-wifi-connect-http.sh
network-repair.sh
node-red-restart.sh
prefer-lan.sh
status.sh
sudoers-campercontrol
wifi-connect-connman.py
'
executable_service_files='
bluetooth-repair.sh
campercontrol-dbus.py
cerbo-reboot.sh
device-http-bounded.py
ensure-campercontrol-dbus.sh
ensure-wifi-connect-http.sh
install-campercontrol-dbus.sh
install-privileges.sh
install-wifi-connect-http.sh
network-repair.sh
node-red-restart.sh
prefer-lan.sh
status.sh
wifi-connect-connman.py
'
run_files='
campercontrol-dbus-service/run
wifi-connect-http-service/run
'
required_files="$service_files
$run_files
starlink-read-status.sh"

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
	link=$1
	if [ -L "$link" ]; then
		svc -d "$link" >/dev/null 2>&1 || true
		wait_service_down "$link"
	fi
}

validate_bridge_identity() {
	dbus -y com.victronenergy.campercontrol /DeviceInstance GetValue 2>/dev/null | grep -Eq '(^|[^0-9])0([^0-9]|$)'
}

wait_bridge_identity() {
	i=0
	while [ "$i" -lt 45 ]; do
		if validate_bridge_identity; then return 0; fi
		sleep 1
		i=$((i + 1))
	done
	validate_bridge_identity
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

runtime_target() {
	case "$1" in
		starlink-read-status.sh) printf '%s\n' "$starlink_root/read-status.sh" ;;
		*) printf '%s\n' "$service_root/$1" ;;
	esac
}

candidate_target() {
	case "$1" in
		starlink-read-status.sh) printf '%s\n' "$candidate/starlink/read-status.sh" ;;
		*) printf '%s\n' "$candidate/service/$1" ;;
	esac
}

rollback_target() {
	case "$1" in
		starlink-read-status.sh) printf '%s\n' "$rollback/starlink/read-status.sh" ;;
		*) printf '%s\n' "$rollback/service/$1" ;;
	esac
}

assert_regular_or_missing() {
	path=$1
	if [ -e "$path" ] || [ -L "$path" ]; then
		test -f "$path"
		test ! -L "$path"
	fi
}

restore_service_link() {
	name=$1
	link=$2
	if [ -f "$rollback/$name-link.was-missing" ]; then
		[ ! -L "$link" ] || rm "$link"
	elif [ -f "$rollback/$name-link.target" ]; then
		old_target=$(cat "$rollback/$name-link.target")
		if [ -L "$link" ] && [ "$(readlink "$link")" != "$old_target" ]; then rm "$link"; fi
		[ -L "$link" ] || ln -s "$old_target" "$link"
	fi
}

remove_transaction_tree() {
	path=$1
	case "$path" in
		"$candidate"|"$rollback") ;;
		*) printf '%s\n' "REFUSING_UNEXPECTED_TRANSACTION_CLEANUP: $path" >&2; return 1 ;;
	esac
	if [ -e "$path" ]; then
		test -d "$path"
		test ! -L "$path"
		rm -rf "$path"
	fi
}

remove_first_install_service_dir() {
	path=$1
	case "$path" in
		/data/campercontrol/service/campercontrol-dbus-service|/data/campercontrol/service/wifi-connect-http-service) ;;
		*) printf '%s\n' "REFUSING_UNEXPECTED_FIRST_INSTALL_ROLLBACK_TARGET: $path" >&2; return 1 ;;
	esac
	if [ -e "$path" ]; then
		test -d "$path"
		test ! -L "$path"
		rm -rf "$path"
	fi
}

restore_regular_payload() {
	for relative in $service_files starlink-read-status.sh; do
		target=$(runtime_target "$relative")
		old=$(rollback_target "$relative")
		case "$target" in
			/data/campercontrol/service/*|/data/campercontrol/starlink/read-status.sh) rm -f "$target" ;;
			*) printf '%s\n' "REFUSING_UNEXPECTED_SERVICE_ROLLBACK_TARGET: $target" >&2; return 1 ;;
		esac
		[ ! -e "$old" ] || mv "$old" "$target"
	done
}

cleanup() {
	status=$?
	trap - EXIT HUP INT TERM
	if [ "$status" -ne 0 ] && [ "$committed" -eq 0 ] && [ "$swap_started" -eq 1 ] && [ -d "$rollback" ]; then
		stop_linked_service "$dbus_service_link" || true
		stop_linked_service "$wifi_service_link" || true
		restore_service_link dbus "$dbus_service_link" || true
		restore_service_link wifi "$wifi_service_link" || true
		restore_regular_payload || true

		if [ "$old_dbus_had_dir" -eq 1 ]; then
			test -d "$dbus_service_dir"; test ! -L "$dbus_service_dir"
			rm -f "$dbus_service_dir/run"
			if [ "$old_dbus_had_run" -eq 1 ]; then mv "$rollback/service/campercontrol-dbus-service/run" "$dbus_service_dir/run"; fi
		else
			remove_first_install_service_dir "$dbus_service_dir" || true
		fi
		if [ "$old_wifi_had_dir" -eq 1 ]; then
			test -d "$wifi_service_dir"; test ! -L "$wifi_service_dir"
			rm -f "$wifi_service_dir/run"
			if [ "$old_wifi_had_run" -eq 1 ]; then mv "$rollback/service/wifi-connect-http-service/run" "$wifi_service_dir/run"; fi
		else
			remove_first_install_service_dir "$wifi_service_dir" || true
		fi

		if [ -f "$rollback/rc.local" ]; then cp -p "$rollback/rc.local" /data/rc.local; elif [ -f "$rollback/rc.local.was-missing" ]; then rm -f /data/rc.local; fi
		if [ -f "$rollback/sudoers-campercontrol" ]; then cp -p "$rollback/sudoers-campercontrol" "$sudoers_target"; elif [ -f "$rollback/sudoers-campercontrol.was-missing" ]; then rm -f "$sudoers_target"; fi

		if [ "$old_dbus_had_link" -eq 1 ]; then
			if [ "$old_dbus_was_up" -eq 1 ]; then
				svc -u "$dbus_service_link" >/dev/null 2>&1 || true
				wait_service_up "$dbus_service_link" && wait_bridge_identity || printf '%s\n' 'CAMPERCONTROL_DBUS_ROLLBACK_VALIDATION_FAILED' >&2
			else
				svc -d "$dbus_service_link" >/dev/null 2>&1 || true
			fi
		fi
		if [ "$old_wifi_had_link" -eq 1 ]; then
			if [ "$old_wifi_was_up" -eq 1 ]; then
				svc -u "$wifi_service_link" >/dev/null 2>&1 || true
				wait_service_up "$wifi_service_link" || printf '%s\n' 'CAMPERCONTROL_WIFI_ROLLBACK_VALIDATION_FAILED' >&2
			else
				svc -d "$wifi_service_link" >/dev/null 2>&1 || true
			fi
		fi
		printf '%s\n' 'CAMPERCONTROL_SERVICES_ROLLBACK_ATTEMPTED' >&2
	fi
	remove_transaction_tree "$candidate" || true
	remove_transaction_tree "$rollback" || true
	exit "$status"
}
trap cleanup EXIT HUP INT TERM

if [ "$#" -gt 1 ]; then printf '%s\n' "Usage: $0 [--force-incompatible]" >&2; exit 2; fi
if [ "$#" -eq 1 ]; then [ "$1" = --force-incompatible ] || exit 2; force_incompatible=1; fi

actual_version=$(sed -n '1{s/\r$//;p;}' /opt/victronenergy/version)
actual_build=$(sed -n '3{s/\r$//;p;}' /opt/victronenergy/version)
actual_arch=$(uname -m)
if [ "$actual_version" != "$expected_version" ] || [ "$actual_build" != "$expected_build" ] || [ "$actual_arch" != "$expected_arch" ]; then
	if [ "$force_incompatible" -ne 1 ]; then
		printf '%s\n' "INCOMPATIBLE: expected $expected_version/$expected_build/$expected_arch, got $actual_version/$actual_build/$actual_arch" >&2
		exit 3
	fi
	printf '%s\n' 'DANGER: forcing the Cerbo services onto an unpinned firmware/architecture.' >&2
fi

test "$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)" = "$release_root"
test -f "$release_root/release.json"
test -f "$release_root/checksums.sha256"
if grep -q '__PENDING_' "$release_root/release.json"; then printf '%s\n' 'SERVICE_INSTALL_BLOCKED_RELEASE_NOT_FINAL' >&2; exit 5; fi
(cd "$release_root" && sha256sum -c checksums.sha256 >/dev/null)

test -d /data/campercontrol
test ! -L /data/campercontrol
test ! -e /data/rc.local.disabled
assert_regular_or_missing /data/rc.local
assert_regular_or_missing "$sudoers_target"
for directory in "$service_root" "$starlink_root" "$dbus_service_dir" "$wifi_service_dir"; do
	if [ -e "$directory" ] || [ -L "$directory" ]; then test -d "$directory"; test ! -L "$directory"; fi
done
test ! -e "$candidate"
test ! -e "$rollback"

actual_file_count=$(find "$source_dir" -type f | wc -l | tr -d ' ')
[ "$actual_file_count" -eq "$expected_file_count" ] || { printf '%s\n' "CERBO_PAYLOAD_FILE_COUNT_MISMATCH: expected $expected_file_count, got $actual_file_count" >&2; exit 5; }
[ -z "$(find "$source_dir" -type l -print -quit)" ] || { printf '%s\n' 'CERBO_PAYLOAD_CONTAINS_SYMLINK' >&2; exit 5; }
for relative in $required_files; do
	test -f "$source_dir/$relative"
	test ! -L "$source_dir/$relative"
	assert_regular_or_missing "$(runtime_target "$relative")"
done

for link_contract in "$dbus_service_link:$dbus_service_dir" "$wifi_service_link:$wifi_service_dir"; do
	link=${link_contract%%:*}
	directory=${link_contract#*:}
	if [ -e "$link" ] && [ ! -L "$link" ]; then printf '%s\n' "REFUSING_NON_SYMLINK_SERVICE: $link" >&2; exit 4; fi
	if [ -L "$link" ] && [ "$(readlink "$link")" != "$directory" ]; then printf '%s\n' "REFUSING_FOREIGN_SERVICE_LINK: $link" >&2; exit 4; fi
done

if [ -L "$dbus_service_link" ]; then old_dbus_had_link=1; if svstat "$dbus_service_link" 2>/dev/null | grep -q ': up '; then old_dbus_was_up=1; fi; fi
if [ -e "$dbus_service_dir" ]; then old_dbus_had_dir=1; if [ -e "$dbus_service_dir/run" ]; then old_dbus_had_run=1; fi; fi
if [ -L "$wifi_service_link" ]; then old_wifi_had_link=1; if svstat "$wifi_service_link" 2>/dev/null | grep -q ': up '; then old_wifi_was_up=1; fi; fi
if [ -e "$wifi_service_dir" ]; then old_wifi_had_dir=1; if [ -e "$wifi_service_dir/run" ]; then old_wifi_had_run=1; fi; fi

same=1
for relative in $required_files; do
	target=$(runtime_target "$relative")
	if [ ! -f "$target" ] || [ "$(sha256sum "$source_dir/$relative" | awk '{print $1}')" != "$(sha256sum "$target" | awk '{print $1}')" ]; then same=0; fi
done
if [ ! -f "$sudoers_target" ] || [ "$(sha256sum "$source_dir/sudoers-campercontrol" | awk '{print $1}')" != "$(sha256sum "$sudoers_target" | awk '{print $1}')" ]; then same=0; fi
if [ "$same" -eq 1 ] &&
	[ -L "$dbus_service_link" ] && [ "$(readlink "$dbus_service_link")" = "$dbus_service_dir" ] &&
	[ -L "$wifi_service_link" ] && [ "$(readlink "$wifi_service_link")" = "$wifi_service_dir" ] &&
	grep -Fqx "$dbus_start_line" /data/rc.local 2>/dev/null &&
	grep -Fqx "$wifi_start_line" /data/rc.local 2>/dev/null; then
	"$service_root/ensure-campercontrol-dbus.sh"
	"$service_root/ensure-wifi-connect-http.sh"
	wait_service_up "$dbus_service_link"
	wait_service_up "$wifi_service_link"
	wait_bridge_identity
	validate_weather_state
	visudo -cf "$sudoers_target" >/dev/null 2>&1
	printf 'CAMPERCONTROL_SERVICES_ALREADY_INSTALLED=%s\n' "$service_root"
	committed=1
	exit 0
fi

source_kb=$(du -sk "$source_dir" 2>/dev/null | awk '{print $1 + 0}')
free_kb=$(df -Pk /data/campercontrol | tail -n 1 | awk '{print $4}')
required_kb=$((source_kb * 3 + 8192))
if [ "$free_kb" -lt "$required_kb" ]; then printf '%s\n' "NOT_ENOUGH_DATA_SPACE_FOR_SERVICES: ${free_kb} KiB free, ${required_kb} KiB required" >&2; exit 7; fi

mkdir "$candidate" "$rollback"
mkdir "$candidate/service" "$candidate/starlink" "$rollback/service" "$rollback/starlink"
mkdir "$candidate/service/campercontrol-dbus-service" "$candidate/service/wifi-connect-http-service"
mkdir "$rollback/service/campercontrol-dbus-service" "$rollback/service/wifi-connect-http-service"
for relative in $required_files; do cp -p "$source_dir/$relative" "$(candidate_target "$relative")"; done
chmod 0644 "$candidate/service/campercontrol_weather.py" "$candidate/service/sudoers-campercontrol"
for relative in $executable_service_files; do chmod 0755 "$candidate/service/$relative"; done
chmod 0755 "$candidate/service/campercontrol-dbus-service/run" "$candidate/service/wifi-connect-http-service/run" "$candidate/starlink/read-status.sh"

if [ -f /data/rc.local ]; then cp -p /data/rc.local "$rollback/rc.local"; else : > "$rollback/rc.local.was-missing"; fi
if [ -f "$sudoers_target" ]; then cp -p "$sudoers_target" "$rollback/sudoers-campercontrol"; else : > "$rollback/sudoers-campercontrol.was-missing"; fi
if [ -L "$dbus_service_link" ]; then printf '%s\n' "$(readlink "$dbus_service_link")" > "$rollback/dbus-link.target"; else : > "$rollback/dbus-link.was-missing"; fi
if [ -L "$wifi_service_link" ]; then printf '%s\n' "$(readlink "$wifi_service_link")" > "$rollback/wifi-link.target"; else : > "$rollback/wifi-link.was-missing"; fi

stop_linked_service "$dbus_service_link"
stop_linked_service "$wifi_service_link"
mkdir -p "$service_root" "$starlink_root"
test -d "$service_root"; test ! -L "$service_root"
test -d "$starlink_root"; test ! -L "$starlink_root"
swap_started=1

for relative in $service_files; do
	target=$service_root/$relative
	[ ! -e "$target" ] || mv "$target" "$rollback/service/$relative"
	mv "$candidate/service/$relative" "$target"
done
if [ -e "$starlink_root/read-status.sh" ]; then mv "$starlink_root/read-status.sh" "$rollback/starlink/read-status.sh"; fi
mv "$candidate/starlink/read-status.sh" "$starlink_root/read-status.sh"

if [ "$old_dbus_had_dir" -eq 1 ]; then
	if [ "$old_dbus_had_run" -eq 1 ]; then mv "$dbus_service_dir/run" "$rollback/service/campercontrol-dbus-service/run"; fi
	mv "$candidate/service/campercontrol-dbus-service/run" "$dbus_service_dir/run"
	rmdir "$candidate/service/campercontrol-dbus-service"
else
	mv "$candidate/service/campercontrol-dbus-service" "$dbus_service_dir"
fi
if [ "$old_wifi_had_dir" -eq 1 ]; then
	if [ "$old_wifi_had_run" -eq 1 ]; then mv "$wifi_service_dir/run" "$rollback/service/wifi-connect-http-service/run"; fi
	mv "$candidate/service/wifi-connect-http-service/run" "$wifi_service_dir/run"
	rmdir "$candidate/service/wifi-connect-http-service"
else
	mv "$candidate/service/wifi-connect-http-service" "$wifi_service_dir"
fi
rmdir "$candidate/service" "$candidate/starlink" "$candidate"

"$service_root/install-campercontrol-dbus.sh"
"$service_root/install-wifi-connect-http.sh"
"$service_root/install-privileges.sh"
wait_service_up "$dbus_service_link"
wait_service_up "$wifi_service_link"
wait_bridge_identity
dbus -y com.victronenergy.campercontrol /Status/WeatherError GetValue >/dev/null 2>&1
dbus -y com.victronenergy.campercontrol /State/Weather GetValue >/dev/null 2>&1
validate_weather_state
visudo -cf "$sudoers_target" >/dev/null 2>&1
[ "$(readlink "$dbus_service_link")" = "$dbus_service_dir" ]
[ "$(readlink "$wifi_service_link")" = "$wifi_service_dir" ]
grep -Fqx "$dbus_start_line" /data/rc.local
grep -Fqx "$wifi_start_line" /data/rc.local
for relative in $required_files; do
	target=$(runtime_target "$relative")
	[ "$(sha256sum "$source_dir/$relative" | awk '{print $1}')" = "$(sha256sum "$target" | awk '{print $1}')" ]
done
[ "$(sha256sum "$source_dir/sudoers-campercontrol" | awk '{print $1}')" = "$(sha256sum "$sudoers_target" | awk '{print $1}')" ]

committed=1
remove_transaction_tree "$rollback"
trap - EXIT HUP INT TERM
printf 'CAMPERCONTROL_SERVICES_INSTALLED=%s\n' "$service_root"
