#!/bin/sh
set -eu

BASE=/data/campercontrol/service
RC_LOCAL=/data/rc.local
START_LINE=/data/campercontrol/service/ensure-campercontrol-dbus.sh
TEMP=/data/rc.local.camper-dbus.$$

trap 'rm -f "$TEMP"' 0 HUP INT TERM

[ -f "$BASE/campercontrol-dbus.py" ] || exit 1
[ -f "$BASE/campercontrol-dbus-service/run" ] || exit 1
[ -f "$START_LINE" ] || exit 1

chmod 0755 "$BASE/campercontrol-dbus.py"
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

"$START_LINE"
exit 0
