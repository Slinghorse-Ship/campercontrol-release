#!/bin/sh

set -eu

stage=/tmp/camper-gui-v2-design-v1-v2-20260819
active=/opt/victronenergy/gui-v2
candidate=/opt/victronenergy/gui-v2.design-v1-v2-20260819
backup=/opt/victronenergy/gui-v2.pre-design-v1-v2-20260819
failed=/opt/victronenergy/gui-v2.failed-design-v1-v2-20260819
service=/service/start-gui
expected_hash=418c2d7d26d531a9ae870cef2f3b75655365edbe9b981adead2328919c7ff643
expected_files=938

service_stopped=0
needs_rollback=0

rollback() {
	trap - EXIT HUP INT TERM
	printf '%s\n' 'DEPLOYMENT_FAILED_ROLLING_BACK'
	svc -d "$service" || true
	sleep 2
	if [ -d "$active" ]; then
		mv "$active" "$failed"
	fi
	if [ -d "$backup" ]; then
		mv "$backup" "$active"
	fi
	sync
	svc -u "$service" || true
	sleep 5
	svstat "$service" || true
}

on_exit() {
	status=$?
	trap - EXIT HUP INT TERM
	if [ "$status" -ne 0 ]; then
		if [ "$needs_rollback" -eq 1 ]; then
			rollback
		elif [ "$service_stopped" -eq 1 ]; then
			svc -u "$service" || true
		fi
	fi
	exit "$status"
}

trap on_exit EXIT HUP INT TERM

test -d "$stage"
test -d "$active"
test ! -e "$candidate"
test ! -e "$backup"
test ! -e "$failed"

staged_files=$(find "$stage" -type f | wc -l | tr -d ' ')
staged_hash=$(sha256sum "$stage/venus-gui-v2" | awk '{print $1}')
test "$staged_files" = "$expected_files"
test "$staged_hash" = "$expected_hash"
test -f "$stage/Victron/VenusOS/pages/camper/CamperLights.qml"
test -f "$stage/Victron/VenusOS/pages/camper/CamperPower.qml"
test -f "$stage/Victron/VenusOS/pages/camper/CamperDetails.qml"
test -f "$stage/Victron/VenusOS/pages/camper/CamperWaterDetails.qml"
test -f "$stage/Victron/VenusOS/components/camper/CamperDesignSettings.qml"
test -f "$stage/Victron/VenusOS/pages/camper/CamperSystem.qml"
test -f "$stage/Victron/VenusOS/pages/settings/PageCamperSettings.qml"
test -f "$stage/Victron/VenusOS/pages/camper/v2/CamperV2Shell.qml"
test -f "$stage/Victron/VenusOS/pages/camper/v2/CamperV2Lights.qml"
test -f "$stage/Victron/VenusOS/pages/camper/v2/CamperV2Energy.qml"
chmod 700 "$stage/venus-gui-v2"

/opt/victronenergy/swupdate-scripts/remount-rw.sh

mkdir "$candidate"
cp -a "$stage"/. "$candidate"/
candidate_files=$(find "$candidate" -type f | wc -l | tr -d ' ')
candidate_hash=$(sha256sum "$candidate/venus-gui-v2" | awk '{print $1}')
test "$candidate_files" = "$expected_files"
test "$candidate_hash" = "$expected_hash"
test "$(stat -c '%a' "$candidate/venus-gui-v2")" = 700

svc -d "$service"
service_stopped=1
i=0
while [ "$i" -lt 10 ]; do
	if svstat "$service" | grep -q ': down '; then
		break
	fi
	sleep 1
	i=$((i + 1))
done
svstat "$service" | grep -q ': down '

mv "$active" "$backup"
needs_rollback=1
mv "$candidate" "$active"
sync

svc -u "$service"
service_stopped=0
sleep 5
pid_first=$(pidof venus-gui-v2 | awk '{print $1}')
test -n "$pid_first"
svstat "$service" | grep -q ': up '

sleep 10
pid_second=$(pidof venus-gui-v2 | awk '{print $1}')
test -n "$pid_second"
test "$pid_first" = "$pid_second"
svstat "$service" | grep -q ': up '
active_hash=$(sha256sum "$active/venus-gui-v2" | awk '{print $1}')
test "$active_hash" = "$expected_hash"

needs_rollback=0
trap - EXIT HUP INT TERM

printf 'DEPLOYMENT_OK\n'
printf 'GUI_PID=%s\n' "$pid_second"
printf 'ACTIVE_BIN_SHA256=%s\n' "$active_hash"
printf 'ON_DEVICE_BACKUP=%s\n' "$backup"
svstat "$service"
