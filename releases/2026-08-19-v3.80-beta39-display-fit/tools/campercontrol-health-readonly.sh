#!/bin/sh

# Remote half of CamperControl-Maintenance.ps1. This script deliberately uses
# only read operations. It writes neither a temporary file nor a service value.
set -u

release_id=2026-08-19-v3.80-beta39-display-fit
release_root=/data/campercontrol/releases/$release_id

clean_value() {
	printf '%s' "$1" | tr '\r\n\t' '   '
}

emit() {
	printf '%s=%s\n' "$1" "$(clean_value "$2")"
}

file_hash() {
	if [ -f "$1" ] && command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" 2>/dev/null | awk '{print $1}'
	else
		printf 'missing'
	fi
}

emit SCHEMA campercontrol-health-v1
emit TIMESTAMP_UTC "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf unknown)"
if [ -f /opt/victronenergy/version ]; then
	emit VENUS_VERSION "$(tr -d '\r\n' </opt/victronenergy/version)"
else
	emit VENUS_VERSION missing
fi
emit ARCHITECTURE "$(uname -m 2>/dev/null || printf unknown)"
emit ROOT_FREE_KB "$(df -Pk / 2>/dev/null | awk 'NR == 2 {print $4}' | tail -n 1)"
emit DATA_FREE_KB "$(df -Pk /data 2>/dev/null | awk 'NR == 2 {print $4}' | tail -n 1)"
emit TMP_FREE_KB "$(df -Pk /tmp 2>/dev/null | awk 'NR == 2 {print $4}' | tail -n 1)"

if [ -e /data/rc.local.disabled ]; then
	emit VENUS_MODIFICATIONS disabled
elif [ -f /data/rc.local ] && [ -x /data/rc.local ]; then
	emit VENUS_MODIFICATIONS enabled
elif [ -f /data/rc.local ]; then
	emit VENUS_MODIFICATIONS not-executable
else
	emit VENUS_MODIFICATIONS missing
fi

if [ -f "$release_root/checksums.sha256" ]; then
	if (cd "$release_root" && sha256sum -c checksums.sha256 >/dev/null 2>&1); then
		emit PERSISTENT_RELEASE_INTEGRITY ok
	else
		emit PERSISTENT_RELEASE_INTEGRITY failed
	fi
else
	emit PERSISTENT_RELEASE_INTEGRITY missing
fi

emit GX_SHA256 "$(file_hash /opt/victronenergy/gui-v2/venus-gui-v2)"
emit WASM_GZIP_SHA256 "$(file_hash /var/www/venus/gui-v2/venus-gui-v2.wasm.gz)"

if [ -L /service/campercontrol-dbus ]; then
	emit CAMPER_SERVICE_LINK "$(readlink /service/campercontrol-dbus 2>/dev/null || printf unreadable)"
elif [ -e /service/campercontrol-dbus ]; then
	emit CAMPER_SERVICE_LINK unexpected-non-symlink
else
	emit CAMPER_SERVICE_LINK missing
fi
if [ -e /service/campercontrol-dbus ] && command -v svstat >/dev/null 2>&1; then
	emit CAMPER_SERVICE_STATUS "$(svstat /service/campercontrol-dbus 2>&1 || true)"
else
	emit CAMPER_SERVICE_STATUS unavailable
fi
if command -v dbus >/dev/null 2>&1; then
	emit CAMPER_DBUS_API_CONNECTED "$(dbus -y com.victronenergy.campercontrol /Status/ApiConnected GetValue 2>&1 || true)"
	emit ORION_DBUS_MODE "$(dbus -y com.victronenergy.alternator/289 /Mode GetValue 2>&1 || true)"
	emit SHELLY_DBUS_STATE "$(dbus -y com.victronenergy.acload/50 /SwitchableOutput/0/State GetValue 2>&1 || true)"
else
	emit CAMPER_DBUS_API_CONNECTED unavailable
	emit ORION_DBUS_MODE unavailable
	emit SHELLY_DBUS_STATE unavailable
fi

processes=$(ps w 2>/dev/null || ps 2>/dev/null || true)
printf '%s\n' "$processes" | grep -qi flashmq && mqtt_flashmq=running || mqtt_flashmq=missing
printf '%s\n' "$processes" | grep -Eqi 'dbus-flashmq|mqtt.*dbus|dbus.*mqtt' && mqtt_gxdbus=running || mqtt_gxdbus=not-observed
printf '%s\n' "$processes" | grep -Eqi 'gxrpc|vrm.*rpc' && mqtt_gxrpc=running || mqtt_gxrpc=not-observed
printf '%s\n' "$processes" | grep -Eqi 'vrmlogger|vrm-portal' && vrm_logger=running || vrm_logger=not-observed
emit MQTT_FLASHMQ "$mqtt_flashmq"
emit MQTT_GXDBUS "$mqtt_gxdbus"
emit MQTT_GXRPC "$mqtt_gxrpc"
emit VRM_LOGGER "$vrm_logger"

node_api=unreachable
node_flow_count=unavailable
node_state_summary=unavailable
if command -v wget >/dev/null 2>&1; then
	if wget -q -T 5 -O /dev/null http://127.0.0.1:1880/camper/api/v2/state 2>/dev/null; then
		node_api=reachable
	fi
	if command -v python3 >/dev/null 2>&1; then
		node_flow_count=$(wget -q -T 5 -O - http://127.0.0.1:1880/flows 2>/dev/null | python3 -c 'import json,sys
try:
 d=json.load(sys.stdin); f=d.get("flows",[]) if isinstance(d,dict) else d; print(len(f) if isinstance(f,list) else "invalid")
except Exception: print("unavailable")' 2>/dev/null || printf unavailable)
		node_state_summary=$(wget -q -T 5 -O - http://127.0.0.1:1880/camper/api/v2/state 2>/dev/null | python3 -c 'import json,sys
try:
 d=json.load(sys.stdin); e=d.get("energy",{}); o=e.get("orion",{}); g=e.get("indevolt",{}).get("gridConnection",{}); print("orion_online=%s;orion_mode=%s;orion_state=%s;shelly_available=%s;shelly_on=%s"%(o.get("online"),o.get("mode"),o.get("stateText"),g.get("available"),g.get("on")))
except Exception: print("unavailable")' 2>/dev/null || printf unavailable)
	fi
fi
emit NODE_RED_API "$node_api"
emit NODE_RED_FLOW_COUNT "$node_flow_count"
emit NODE_RED_STATE "$node_state_summary"

runtime_flow_path=missing
for candidate in \
	/data/home/nodered/.node-red/flows.json \
	/data/home/nodered/.node-red/flows_venus.json
do
	if [ -f "$candidate" ]; then
		runtime_flow_path=$candidate
		break
	fi
done
emit NODE_RED_FLOW_PATH "$runtime_flow_path"
if [ "$runtime_flow_path" = missing ]; then
	emit NODE_RED_FLOW_SHA256 missing
else
	emit NODE_RED_FLOW_SHA256 "$(file_hash "$runtime_flow_path")"
fi

backup_count=0
latest_backup=missing
latest_backup_integrity=missing
if [ -d /data/campercontrol/backups ]; then
	backup_count=$(find /data/campercontrol/backups -maxdepth 1 -type f -name '*.tar.gz' 2>/dev/null | wc -l | tr -d ' ')
	latest_backup=$(ls -1t /data/campercontrol/backups/*.tar.gz 2>/dev/null | head -n 1 || true)
	if [ -n "$latest_backup" ] && [ -f "$latest_backup.sha256" ]; then
		if (cd /data/campercontrol/backups && sha256sum -c "${latest_backup##*/}.sha256" >/dev/null 2>&1); then
			latest_backup_integrity=ok
		else
			latest_backup_integrity=failed
		fi
	fi
fi
emit BACKUP_COUNT "$backup_count"
emit LATEST_BACKUP "${latest_backup:-missing}"
emit LATEST_BACKUP_INTEGRITY "$latest_backup_integrity"
