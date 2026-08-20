#!/bin/sh
set -eu

SERVICE_NAME=campercontrol-dbus
SERVICE_DIR=/data/campercontrol/service/campercontrol-dbus-service
SERVICE_LINK=/service/$SERVICE_NAME
PYTHON_BRIDGE=/data/campercontrol/service/campercontrol-dbus.py
WEATHER_PROVIDER=/data/campercontrol/service/campercontrol_weather.py

[ -x "$PYTHON_BRIDGE" ] || exit 1
[ -r "$WEATHER_PROVIDER" ] || exit 1
[ -x "$SERVICE_DIR/run" ] || exit 1

if [ -L "$SERVICE_LINK" ]; then
    [ "$(readlink "$SERVICE_LINK")" = "$SERVICE_DIR" ] || exit 1
elif [ -e "$SERVICE_LINK" ]; then
    exit 1
else
    ln -s "$SERVICE_DIR" "$SERVICE_LINK"
fi

svc -u "$SERVICE_LINK" >/dev/null 2>&1 || true
exit 0
