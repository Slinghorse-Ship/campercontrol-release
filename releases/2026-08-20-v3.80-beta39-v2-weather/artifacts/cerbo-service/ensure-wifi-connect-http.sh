#!/bin/sh
set -eu

SERVICE_NAME=camper-wifi-connect
SERVICE_DIR=/data/campercontrol/service/wifi-connect-http-service
SERVICE_LINK=/service/$SERVICE_NAME
PYTHON_HELPER=/data/campercontrol/service/wifi-connect-connman.py

[ -x "$PYTHON_HELPER" ] || exit 1
[ -x "$SERVICE_DIR/run" ] || exit 1

if [ -L "$SERVICE_LINK" ]; then
    [ "$(readlink "$SERVICE_LINK")" = "$SERVICE_DIR" ] || exit 1
elif [ -e "$SERVICE_LINK" ]; then
    exit 1
else
    ln -s "$SERVICE_DIR" "$SERVICE_LINK"
fi

# svscan notices new /service entries itself. svc is only a bounded nudge and
# may briefly fail while supervise creates its control pipe during early boot.
svc -u "$SERVICE_LINK" >/dev/null 2>&1 || true
exit 0
