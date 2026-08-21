#!/bin/sh

# ConnMan already ranks Ethernet above Wi-Fi by technology. When both saved
# services are visible, also persist their service order in ConnMan. We do not
# add routes ourselves: ConnMan must retain ownership so unplugging Ethernet
# can immediately promote Wi-Fi without stale or duplicate default routes.
services="$(connmanctl services 2>/dev/null)"
eth_service="$(printf '%s\n' "$services" | awk '{for(i=1;i<=NF;i++) if($i ~ /^ethernet_/) {print $i; exit}}')"
wifi_service="$(printf '%s\n' "$services" | awk '{for(i=1;i<=NF;i++) if($i ~ /^wifi_/) {print $i; exit}}')"

if [ -n "$eth_service" ] && [ -n "$wifi_service" ]; then
    connmanctl move-before "$eth_service" "$wifi_service" >/dev/null 2>&1 || true
fi

exit 0
