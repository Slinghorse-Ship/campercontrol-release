#!/bin/sh

set -eu

release_id=2026-08-19-v3.80-beta39-display-fit
release_root=/data/campercontrol/releases/$release_id
service_link=/service/campercontrol-dbus
service_dir=/data/campercontrol/service/campercontrol-dbus-service
start_line=/data/campercontrol/service/ensure-campercontrol-dbus.sh

if [ "$#" -ne 1 ] || [ "$1" != --confirm-disable-campercontrol-dbus ]; then
	printf '%s\n' "Explicit confirmation required: $0 --confirm-disable-campercontrol-dbus" >&2
	exit 2
fi
test "$(CDPATH= cd "$(dirname "$0")/../.." && pwd -P)" = "$release_root"
test -x "$release_root/tools/create-preapply-backup.sh"

if [ -e "$service_link" ] && [ ! -L "$service_link" ]; then
	printf '%s\n' "REFUSING_NON_SYMLINK_SERVICE: $service_link" >&2
	exit 3
fi
if [ -L "$service_link" ] && [ "$(readlink "$service_link")" != "$service_dir" ]; then
	printf '%s\n' "REFUSING_FOREIGN_SERVICE_LINK: $service_link" >&2
	exit 3
fi

line_present=0
grep -Fqx "$start_line" /data/rc.local 2>/dev/null && line_present=1
grep -Fqx "$start_line" /data/rc.local.disabled 2>/dev/null && line_present=1
if [ ! -L "$service_link" ] && [ "$line_present" -eq 0 ]; then
	printf 'CAMPERCONTROL_SERVICE_ALREADY_DISABLED\n'
	exit 0
fi

"$release_root/tools/create-preapply-backup.sh"
if [ -L "$service_link" ]; then
	svc -d "$service_link" >/dev/null 2>&1 || true
	rm "$service_link"
fi

for rc_file in /data/rc.local /data/rc.local.disabled; do
	if [ -f "$rc_file" ] && grep -Fqx "$start_line" "$rc_file"; then
		temporary=$rc_file.campercontrol-rollback.$$
		trap 'rm -f "$temporary"' EXIT HUP INT TERM
		awk -v line="$start_line" '$0 != line { print }' "$rc_file" > "$temporary"
		chmod --reference="$rc_file" "$temporary" 2>/dev/null || chmod 0755 "$temporary"
		mv "$temporary" "$rc_file"
		trap - EXIT HUP INT TERM
	fi
done
sync

printf 'CAMPERCONTROL_SERVICE_DISABLED\n'
printf 'SERVICE_FILES_RETAINED=%s\n' /data/campercontrol/service
