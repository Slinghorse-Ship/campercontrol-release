#!/bin/sh

LOG=/data/log/campercontrol-bluetooth-repair.log
LOCK=/var/run/campercontrol-bluetooth-repair.lock

if ! ( set -C; : > "$LOCK" ) 2>/dev/null; then
    echo "bluetooth repair already running"
    exit 0
fi

cleanup() {
    # The sensor service must never remain down, even if an old UART adapter
    # does not answer a controller command.
    svc -u /service/dbus-ble-sensors 2>/dev/null || true
    rm -f "$LOCK"
}
trap cleanup EXIT INT TERM

{
    echo "$(date -Iseconds 2>/dev/null || date) bluetooth repair started"
    svc -d /service/dbus-ble-sensors 2>/dev/null || true
    sleep 2
    found=0
    for adapter in /sys/class/bluetooth/hci*; do
        [ -d "$adapter" ] || continue
        found=1
        name="$(basename "$adapter")"
        # The original Broadcom UART controller on old Cerbo hardware can
        # block indefinitely on btmgmt power commands. Bringing an existing
        # HCI device up plus restarting the Victron service is safe and
        # sufficient; USB adapters are handled by the same command.
        hciconfig "$name" up 2>&1 || true
    done
    svc -u /service/dbus-ble-sensors 2>/dev/null || true
    sleep 3
    [ "$found" -eq 1 ] && hciconfig -a 2>/dev/null || echo "no bluetooth adapter found"
    svstat /service/dbus-ble-sensors 2>/dev/null || true
    echo "$(date -Iseconds 2>/dev/null || date) bluetooth repair finished"
} > "$LOG" 2>&1
