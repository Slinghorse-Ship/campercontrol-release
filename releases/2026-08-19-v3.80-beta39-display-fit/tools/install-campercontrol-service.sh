#!/bin/sh

set -eu

release_id=2026-08-19-v3.80-beta39-display-fit
release_root=/data/campercontrol/releases/$release_id
source_dir=$release_root/artifacts/cerbo-service
service_root=/data/campercontrol/service
service_dir=$service_root/campercontrol-dbus-service
service_link=/service/campercontrol-dbus
start_line=/data/campercontrol/service/ensure-campercontrol-dbus.sh
candidate=/data/campercontrol/.camper-dbus-$release_id.candidate
rollback=/data/campercontrol/.camper-dbus-$release_id.rollback
expected_version='v3.80~39'
expected_arch=armv7l
force_incompatible=0
committed=0

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
		if [ -d "$rollback" ]; then
			for relative in campercontrol-dbus.py ensure-campercontrol-dbus.sh install-campercontrol-dbus.sh campercontrol-dbus-service; do
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
		if [ -L "$service_link" ] && [ "$(readlink "$service_link")" = "$service_dir" ] && [ -f "$rollback/service-link.was-missing" ]; then
			rm "$service_link"
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

actual_version=$(tr -d '\r\n' </opt/victronenergy/version)
actual_arch=$(uname -m)
if [ "$actual_version" != "$expected_version" ] || [ "$actual_arch" != "$expected_arch" ]; then
	if [ "$force_incompatible" -ne 1 ]; then
		printf '%s\n' "INCOMPATIBLE: expected $expected_version/$expected_arch, got $actual_version/$actual_arch" >&2
		exit 3
	fi
	printf '%s\n' 'DANGER: forcing the transport service onto an unpinned firmware/architecture.' >&2
fi

test "$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)" = "$release_root"
test -f "$release_root/checksums.sha256"
(cd "$release_root" && sha256sum -c checksums.sha256 >/dev/null)
test -f "$source_dir/campercontrol-dbus.py"
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

same=1
for relative in campercontrol-dbus.py ensure-campercontrol-dbus.sh install-campercontrol-dbus.sh campercontrol-dbus-service/run; do
	if [ ! -f "$service_root/$relative" ] || [ "$(sha256sum "$source_dir/$relative" | awk '{print $1}')" != "$(sha256sum "$service_root/$relative" | awk '{print $1}')" ]; then
		same=0
	fi
done
if [ "$same" -eq 1 ] && [ -L "$service_link" ] && grep -Fqx "$start_line" /data/rc.local 2>/dev/null; then
	"$service_root/ensure-campercontrol-dbus.sh"
	sleep 2
	svstat "$service_link" | grep -q '^up:'
	printf 'CAMPERCONTROL_SERVICE_ALREADY_INSTALLED=%s\n' "$service_root"
	committed=1
	exit 0
fi

"$release_root/tools/create-preapply-backup.sh"
mkdir "$candidate" "$rollback"
cp -p "$source_dir/campercontrol-dbus.py" "$candidate/"
cp -p "$source_dir/ensure-campercontrol-dbus.sh" "$candidate/"
cp -p "$source_dir/install-campercontrol-dbus.sh" "$candidate/"
mkdir "$candidate/campercontrol-dbus-service"
cp -p "$source_dir/campercontrol-dbus-service/run" "$candidate/campercontrol-dbus-service/run"
chmod 0755 "$candidate/campercontrol-dbus.py" "$candidate/ensure-campercontrol-dbus.sh" "$candidate/install-campercontrol-dbus.sh" "$candidate/campercontrol-dbus-service/run"

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

mkdir -p "$service_root"
for relative in campercontrol-dbus.py ensure-campercontrol-dbus.sh install-campercontrol-dbus.sh campercontrol-dbus-service; do
	[ ! -e "$service_root/$relative" ] || mv "$service_root/$relative" "$rollback/$relative"
	mv "$candidate/$relative" "$service_root/$relative"
done
rmdir "$candidate"

"$service_root/install-campercontrol-dbus.sh"
sleep 3
svstat "$service_link" | grep -q '^up:'
dbus -y com.victronenergy.campercontrol /DeviceInstance GetValue 2>/dev/null | grep -Eq '(^|[^0-9])0([^0-9]|$)'

committed=1
rm -rf "$rollback"
trap - EXIT HUP INT TERM
printf 'CAMPERCONTROL_SERVICE_INSTALLED=%s\n' "$service_root"
