#!/bin/sh
set -eu

BASE=/data/campercontrol/service
RC_LOCAL=/data/rc.local
START_LINE=/data/campercontrol/service/ensure-wifi-connect-http.sh
TEMP=/data/rc.local.camper-wifi.$$

trap 'rm -f "$TEMP"' 0 HUP INT TERM

[ -f "$BASE/wifi-connect-connman.py" ] || exit 1
[ -f "$BASE/wifi-connect-http-service/run" ] || exit 1
[ -f "$BASE/ensure-wifi-connect-http.sh" ] || exit 1

chmod 0755 "$BASE/wifi-connect-connman.py"
chmod 0755 "$BASE/wifi-connect-http-service/run"
chmod 0755 "$BASE/ensure-wifi-connect-http.sh"

if [ ! -f "$RC_LOCAL" ]; then
    printf '%s\n' '#!/bin/sh' "$START_LINE" 'exit 0' > "$RC_LOCAL"
    chmod 0755 "$RC_LOCAL"
elif ! grep -Fqx "$START_LINE" "$RC_LOCAL"; then
    [ -f /data/rc.local.before-camper-wifi-connect ] || cp -p "$RC_LOCAL" /data/rc.local.before-camper-wifi-connect
    awk -v start="$START_LINE" '
        BEGIN { inserted=0 }
        /^exit[[:space:]]+0[[:space:]]*$/ && !inserted { print start; inserted=1 }
        { print }
        END { if (!inserted) { print start; print "exit 0" } }
    ' "$RC_LOCAL" > "$TEMP"
    chmod 0755 "$TEMP"
    mv "$TEMP" "$RC_LOCAL"
fi

"$BASE/ensure-wifi-connect-http.sh"
exit 0
