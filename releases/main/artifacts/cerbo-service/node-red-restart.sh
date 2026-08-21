#!/bin/sh

LOG=/data/log/campercontrol-node-red-restart.log
{
    echo "$(date -Iseconds 2>/dev/null || date) Node-RED restart requested"
    sleep 2
    svc -d /service/node-red-venus
    sleep 3
    svc -u /service/node-red-venus
} > "$LOG" 2>&1
