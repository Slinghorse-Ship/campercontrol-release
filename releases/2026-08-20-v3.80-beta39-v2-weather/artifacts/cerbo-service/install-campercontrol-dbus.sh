#!/bin/sh
set -eu

BASE=/data/campercontrol/service
RC_LOCAL=/data/rc.local
START_LINE=/data/campercontrol/service/ensure-campercontrol-dbus.sh
SERVICE_LINK=/service/campercontrol-dbus
TEMP=/data/rc.local.camper-dbus.$$

trap 'rm -f "$TEMP"' 0 HUP INT TERM

[ -f "$BASE/campercontrol-dbus.py" ] || exit 1
[ -f "$BASE/campercontrol_weather.py" ] || exit 1
[ -f "$BASE/campercontrol-dbus-service/run" ] || exit 1
[ -f "$START_LINE" ] || exit 1

chmod 0755 "$BASE/campercontrol-dbus.py"
chmod 0644 "$BASE/campercontrol_weather.py"
chmod 0755 "$BASE/campercontrol-dbus-service/run"
chmod 0755 "$START_LINE"

if [ ! -f "$RC_LOCAL" ]; then
    printf '%s\n' '#!/bin/sh' "$START_LINE" 'exit 0' > "$RC_LOCAL"
    chmod 0755 "$RC_LOCAL"
elif ! grep -Fqx "$START_LINE" "$RC_LOCAL"; then
    [ -f /data/rc.local.before-camper-dbus ] || cp -p "$RC_LOCAL" /data/rc.local.before-camper-dbus
    awk -v start="$START_LINE" '
        BEGIN { inserted=0 }
        /^exit[[:space:]]+0[[:space:]]*$/ && !inserted { print start; inserted=1 }
        { print }
        END { if (!inserted) { print start; print "exit 0" } }
    ' "$RC_LOCAL" > "$TEMP"
    chmod 0755 "$TEMP"
    mv "$TEMP" "$RC_LOCAL"
fi

service_was_up=0
if [ -L "$SERVICE_LINK" ] && svstat "$SERVICE_LINK" 2>/dev/null | grep -q ': up '; then
    service_was_up=1
fi

"$START_LINE"
# `svc -u` in the idempotent ensure script starts a stopped/first-install
# service.  Send TERM only when a bridge was already up before ensure; doing so
# unconditionally would terminate the just-started process during validation.
if [ "$service_was_up" -eq 1 ]; then
    svc -t "$SERVICE_LINK" >/dev/null 2>&1 || true
else
    svc -u "$SERVICE_LINK" >/dev/null 2>&1 || true
fi
exit 0
