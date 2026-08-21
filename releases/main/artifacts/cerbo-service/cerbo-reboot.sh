#!/bin/sh

echo "$(date -Iseconds 2>/dev/null || date) Cerbo reboot requested" > /data/log/campercontrol-cerbo-reboot.log
sync
sleep 2
/sbin/reboot
