#!/bin/sh

# Read-only CamperControl service status. Output is deliberately simple
# key=value text so Node-RED can parse it without optional shell packages.

value() {
    printf '%s=%s\n' "$1" "$(printf '%s' "$2" | tr '\r\n\t' '   ')"
}

iface_status() {
    iface="$1"
    state="missing"
    carrier=""
    address=""
    if [ -d "/sys/class/net/$iface" ]; then
        state="$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo unknown)"
        carrier="$(cat "/sys/class/net/$iface/carrier" 2>/dev/null || true)"
        address="$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk 'NR==1 {print $4}')"
    fi
    value "${iface}_state" "$state"
    value "${iface}_carrier" "$carrier"
    value "${iface}_address" "$address"
}

route_line="$(ip -4 route show default 2>/dev/null | head -n 1)"
route_gateway="$(printf '%s\n' "$route_line" | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}')"
route_interface="$(printf '%s\n' "$route_line" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')"
route_source=""
if [ -n "$route_interface" ]; then
    route_source="$(ip -4 -o addr show dev "$route_interface" 2>/dev/null | awk 'NR==1 {print $4}')"
fi

value status_version 1
value timestamp "$(date +%s)"
value route_present "$([ -n "$route_interface" ] && echo 1 || echo 0)"
value route_interface "$route_interface"
value route_gateway "$route_gateway"
value route_source "$route_source"
value route_line "$route_line"
value preferred_uplink eth0
if [ "$route_interface" = "eth0" ]; then
    value preferred_uplink_active 1
elif [ "$(cat /sys/class/net/eth0/carrier 2>/dev/null || echo 0)" = "1" ]; then
    value preferred_uplink_active 0
else
    # Wi-Fi is the intended fallback whenever Ethernet has no carrier.
    value preferred_uplink_active 1
fi

if ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1; then
    value internet_reachable 1
else
    value internet_reachable 0
fi

iface_status eth0
iface_status wlan0
iface_status ap0

wifi_ssid="$(iw dev wlan0 link 2>/dev/null | sed -n 's/^[[:space:]]*SSID: //p' | head -n 1)"
ap_ssid="$(iw dev ap0 info 2>/dev/null | sed -n 's/^[[:space:]]*ssid //p' | head -n 1)"
value wlan0_ssid "$wifi_ssid"
value ap0_ssid "$ap_ssid"

value forwarding "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo 0)"
if iptables -C FORWARD -i ap0 -j VENUS_AP_OUT >/dev/null 2>&1; then value bridge_forward 1; else value bridge_forward 0; fi
for uplink in eth0 wlan0; do
    if iptables -t nat -C POSTROUTING -s 172.24.24.0/24 -o "$uplink" -j MASQUERADE >/dev/null 2>&1; then
        value "nat_${uplink}" 1
    else
        value "nat_${uplink}" 0
    fi
done
if nc -z -w 1 172.24.24.1 53 >/dev/null 2>&1; then value ap_dns 1; else value ap_dns 0; fi

if svstat /service/node-red-venus 2>/dev/null | grep -q ': up '; then value node_red_up 1; else value node_red_up 0; fi
if svstat /service/dbus-ble-sensors 2>/dev/null | grep -q ': up '; then value bluetooth_service_up 1; else value bluetooth_service_up 0; fi

adapter_count=0
adapter_list=""
for adapter in /sys/class/bluetooth/hci*; do
    [ -d "$adapter" ] || continue
    adapter_count=$((adapter_count + 1))
    name="$(basename "$adapter")"
    address="$(hciconfig "$name" 2>/dev/null | sed -n 's/.*BD Address: \([^ ]*\).*/\1/p')"
    [ -n "$adapter_list" ] && adapter_list="$adapter_list, "
    adapter_list="${adapter_list}${name} ${address}"
done
value bluetooth_adapter_count "$adapter_count"
value bluetooth_adapters "$adapter_list"

# The actual sensor values and names are read by one consolidated Python D-Bus
# process. The general status poll must never launch another per-sensor process
# cascade; it reports the cached discovery written by that reader instead.
sensor_cache="/tmp/camper-temperature-sensors.cache"
if [ -r "$sensor_cache" ]; then
    sensor_count="$(wc -l < "$sensor_cache" | tr -d ' ')"
    sensor_list="$(cut -f3 "$sensor_cache" 2>/dev/null | sed '/^$/d' | paste -sd ', ' -)"
else
    sensor_count=0
    sensor_list=""
fi
value bluetooth_sensor_count "$sensor_count"
value bluetooth_sensors "$sensor_list"

cpu_milli="$(for zone in /sys/class/thermal/thermal_zone*/temp; do [ -r "$zone" ] && cat "$zone"; done | sort -nr | head -n 1)"
if [ -n "$cpu_milli" ]; then
    value cpu_temperature "$(awk -v t="$cpu_milli" 'BEGIN {printf "%.1f", t/1000}')"
else
    value cpu_temperature ""
fi
