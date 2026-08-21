#!/bin/sh

LOG=/data/log/campercontrol-network-repair.log
LOCK=/var/run/campercontrol-network-repair.lock

if ! ( set -C; : > "$LOCK" ) 2>/dev/null; then
    echo "network repair already running"
    exit 0
fi
trap 'rm -f "$LOCK"' EXIT INT TERM

{
    echo "$(date -Iseconds 2>/dev/null || date) network repair started"
    killall connmand 2>/dev/null || true
    waited=0
    while [ "$waited" -lt 20 ]; do
        pidof connmand >/dev/null 2>&1 && break
        sleep 1
        waited=$((waited + 1))
    done
    sleep 3
    route_waited=0
    while [ "$route_waited" -lt 20 ]; do
        ip -4 route show default 2>/dev/null | grep -q '^default ' && break
        sleep 1
        route_waited=$((route_waited + 1))
    done
    if [ -x /data/campercontrol/service/prefer-lan.sh ]; then
        /data/campercontrol/service/prefer-lan.sh
    fi
    if [ -x /data/venus-ap-internet.sh ]; then
        /data/venus-ap-internet.sh
    fi
    echo "default route: $(ip -4 route show default 2>/dev/null | head -n 1)"
    echo "$(date -Iseconds 2>/dev/null || date) network repair finished"
} > "$LOG" 2>&1
