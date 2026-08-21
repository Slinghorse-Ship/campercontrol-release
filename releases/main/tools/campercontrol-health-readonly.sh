#!/bin/sh

# Low-overhead, read-only Cerbo audit. No temporary files, service changes,
# D-Bus writes, scans or recursive whole-filesystem walks are performed.
set -u

release_root="$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)"
release_id="$(basename "$release_root")"
release_root=/data/campercontrol/releases/$release_id
weather_cache=/data/campercontrol/cache/weather-v1.json
weather_station_cache=/data/campercontrol/cache/mosmix-stations-v1.cfg
weather_location_config=/data/campercontrol/weather-location.json
weather_station_override=/data/campercontrol/weather-station.conf
node_context=/data/home/nodered/.node-red/context

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

file_bytes() {
	if [ -f "$1" ]; then stat -c '%s' "$1" 2>/dev/null || wc -c <"$1"; else printf '0'; fi
}

dir_kb() {
	if [ -d "$1" ]; then du -sk "$1" 2>/dev/null | awk '{print $1 + 0}'; else printf '0'; fi
}

df_fact() {
	# Parse from the right so a diagnostic host with spaces in the filesystem
	# label cannot shift the POSIX size/used/available/use columns.
	df -Pk "$1" 2>/dev/null | tail -n 1 | awk -v column="$2" '{
		if (column == 2) print $(NF-4);
		else if (column == 3) print $(NF-3);
		else if (column == 4) print $(NF-2);
		else if (column == 5) print $(NF-1);
	}'
}

emit SCHEMA campercontrol-health-v2
emit TIMESTAMP_UTC "$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf unknown)"
if [ -f /opt/victronenergy/version ]; then
	emit VENUS_VERSION "$(sed -n '1{s/\r$//;p;}' /opt/victronenergy/version)"
	emit VENUS_BUILD "$(sed -n '3{s/\r$//;p;}' /opt/victronenergy/version)"
else
	emit VENUS_VERSION missing
	emit VENUS_BUILD missing
fi
emit ARCHITECTURE "$(uname -m 2>/dev/null || printf unknown)"
emit ROOT_TOTAL_KB "$(df_fact / 2)"
emit ROOT_USED_KB "$(df_fact / 3)"
emit ROOT_FREE_KB "$(df_fact / 4)"
emit ROOT_USE_PERCENT "$(df_fact / 5)"
emit DATA_TOTAL_KB "$(df_fact /data 2)"
emit DATA_USED_KB "$(df_fact /data 3)"
emit DATA_FREE_KB "$(df_fact /data 4)"
emit DATA_USE_PERCENT "$(df_fact /data 5)"
emit TMP_FREE_KB "$(df_fact /tmp 4)"

if [ -r /proc/loadavg ]; then
	set -- $(sed -n '1p' /proc/loadavg)
	emit LOADAVG_1 "$1"
	emit LOADAVG_5 "$2"
	emit LOADAVG_15 "$3"
else
	emit LOADAVG_1 unavailable
	emit LOADAVG_5 unavailable
	emit LOADAVG_15 unavailable
fi
mem_available=$(awk '/^MemAvailable:/ {print $2; found=1} END {if (!found) print 0}' /proc/meminfo 2>/dev/null)
if [ "$mem_available" = 0 ]; then
	mem_available=$(awk '/^(MemFree|Buffers|Cached):/ {sum += $2} END {print sum + 0}' /proc/meminfo 2>/dev/null)
fi
emit MEM_AVAILABLE_KB "$mem_available"
emit MEM_TOTAL_KB "$(awk '/^MemTotal:/ {print $2 + 0}' /proc/meminfo 2>/dev/null)"

node_rss_kb=0
node_pids=
for proc_dir in /proc/[0-9]*; do
	[ -r "$proc_dir/cmdline" ] || continue
	cmdline=$(tr '\000' ' ' <"$proc_dir/cmdline" 2>/dev/null || true)
	case "$cmdline" in
		*node-red*|*red.js*)
			pid=${proc_dir##*/}
			rss=$(awk '/^VmRSS:/ {print $2 + 0}' "$proc_dir/status" 2>/dev/null)
			node_rss_kb=$((node_rss_kb + ${rss:-0}))
			node_pids=${node_pids}${node_pids:+,}$pid
			;;
	esac
done
emit NODE_RED_PIDS "${node_pids:-missing}"
emit NODE_RED_RSS_KB "$node_rss_kb"

# Exact, bounded directories only: this locates growth without an expensive
# `du /` walk on the Cerbo.
emit VAR_LOG_KB "$(dir_kb /var/log)"
emit DATA_LOG_KB "$(dir_kb /data/log)"
emit NODE_RED_LOG_KB "$(dir_kb /var/log/node-red-venus)"
emit NODE_RED_CONTEXT_KB "$(dir_kb "$node_context")"
emit CAMPERCONTROL_DATA_KB "$(dir_kb /data/campercontrol)"
emit CAMPERCONTROL_RELEASES_KB "$(dir_kb /data/campercontrol/releases)"
emit CAMPERCONTROL_STAGING_KB "$(dir_kb /data/campercontrol/staging)"
emit CAMPERCONTROL_INCOMING_KB "$(dir_kb /data/campercontrol/incoming)"
emit GX_ACTIVE_TREE_KB "$(dir_kb /opt/victronenergy/gui-v2)"
emit WASM_ACTIVE_TREE_KB "$(dir_kb /var/www/venus/gui-v2)"

context_tmp_count=0
context_tmp_bytes=0
if [ -d "$node_context" ]; then
	context_tmp_count=$(find "$node_context" -type f -name '*.tmp' 2>/dev/null | wc -l | tr -d ' ')
	context_tmp_bytes=$(find "$node_context" -type f -name '*.tmp' -exec stat -c '%s' '{}' ';' 2>/dev/null | awk '{sum += $1} END {print sum + 0}')
fi
emit NODE_RED_CONTEXT_TMP_COUNT "$context_tmp_count"
emit NODE_RED_CONTEXT_TMP_BYTES "$context_tmp_bytes"

old_gui_count=0
old_gui_kb=0
old_gui_paths=
for base in /opt/victronenergy /var/www/venus; do
	for path in "$base"/gui-v2.pre-* "$base"/gui-v2.rollback-* "$base"/gui-v2.failed-* "$base"/gui-v2.candidate-*; do
		[ -d "$path" ] || continue
		[ ! -L "$path" ] || continue
		case "$path" in
			/opt/victronenergy/gui-v2.pre-*|/opt/victronenergy/gui-v2.rollback-*|/opt/victronenergy/gui-v2.failed-*|/opt/victronenergy/gui-v2.candidate-*|/var/www/venus/gui-v2.pre-*|/var/www/venus/gui-v2.rollback-*|/var/www/venus/gui-v2.failed-*|/var/www/venus/gui-v2.candidate-*) ;;
			*) continue ;;
		esac
		old_gui_count=$((old_gui_count + 1))
		path_kb=$(dir_kb "$path")
		old_gui_kb=$((old_gui_kb + path_kb))
		old_gui_paths=${old_gui_paths}${old_gui_paths:+,}$path
	done
done
emit OLD_GUI_TREE_COUNT "$old_gui_count"
emit OLD_GUI_TREE_KB "$old_gui_kb"
emit OLD_GUI_TREE_PATHS "${old_gui_paths:-none}"

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
	if (cd "$release_root" && sha256sum -c checksums.sha256 >/dev/null 2>&1); then emit PERSISTENT_RELEASE_INTEGRITY ok; else emit PERSISTENT_RELEASE_INTEGRITY failed; fi
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
if [ -e /service/campercontrol-dbus ] && command -v svstat >/dev/null 2>&1; then emit CAMPER_SERVICE_STATUS "$(svstat /service/campercontrol-dbus 2>&1 || true)"; else emit CAMPER_SERVICE_STATUS unavailable; fi

weather_raw=
if command -v dbus >/dev/null 2>&1; then
	emit CAMPER_DBUS_API_CONNECTED "$(dbus -y com.victronenergy.campercontrol /Status/ApiConnected GetValue 2>&1 || true)"
	emit WEATHER_LAST_UPDATE "$(dbus -y com.victronenergy.campercontrol /Status/WeatherLastUpdate GetValue 2>&1 || true)"
	emit WEATHER_ERROR "$(dbus -y com.victronenergy.campercontrol /Status/WeatherError GetValue 2>&1 || true)"
	weather_raw=$(dbus -y com.victronenergy.campercontrol /State/Weather GetValue 2>/dev/null || true)
	if printf '%s' "$weather_raw" | grep -q '"hourly"'; then weather_status=ready; elif [ -n "$weather_raw" ]; then weather_status=empty-or-invalid; else weather_status=missing; fi
	orion_service=$(dbus -y com.victronenergy.system /ServiceMapping/com_victronenergy_alternator_289 GetValue 2>/dev/null | tr -d "'\"" || true)
	case "$orion_service" in
		com.victronenergy.*) emit ORION_DBUS_MODE "$(dbus -y "$orion_service" /Mode GetValue 2>&1 || true)" ;;
		*) emit ORION_DBUS_MODE unavailable ;;
	esac
	shelly_service=$(dbus -y com.victronenergy.system /ServiceMapping/com_victronenergy_acload_50 GetValue 2>/dev/null | tr -d "'\"" || true)
	case "$shelly_service" in
		com.victronenergy.*) emit SHELLY_DBUS_STATE "$(dbus -y "$shelly_service" /SwitchableOutput/0/State GetValue 2>&1 || true)" ;;
		*) emit SHELLY_DBUS_STATE unavailable ;;
	esac
else
	emit CAMPER_DBUS_API_CONNECTED unavailable
	emit WEATHER_LAST_UPDATE unavailable
	emit WEATHER_ERROR unavailable
	weather_status=unavailable
	emit ORION_DBUS_MODE unavailable
	emit SHELLY_DBUS_STATE unavailable
fi
emit WEATHER_DBUS_STATUS "$weather_status"
emit WEATHER_DBUS_STATE_BYTES "$(printf '%s' "$weather_raw" | wc -c | tr -d ' ')"
emit WEATHER_CACHE_PATH "$weather_cache"
emit WEATHER_CACHE_BYTES "$(file_bytes "$weather_cache")"
emit WEATHER_STATION_CACHE_BYTES "$(file_bytes "$weather_station_cache")"
emit WEATHER_LOCATION_CONFIG_BYTES "$(file_bytes "$weather_location_config")"
emit WEATHER_LOCATION_CONFIG "$(if [ -f "$weather_location_config" ]; then printf present; else printf default-gps; fi)"
emit WEATHER_STATION_OVERRIDE "$(if [ -f "$weather_station_override" ]; then printf present; else printf automatic; fi)"

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
if command -v python3 >/dev/null 2>&1; then
	bounded_node_probe() {
		python3 - <<'PY' &
import json
import signal
import urllib.request


def alarm_handler(_signum, _frame):
    raise TimeoutError("local HTTP probe timed out")


def load(path, limit):
    signal.alarm(5)
    try:
        with urllib.request.urlopen("http://127.0.0.1:1880" + path, timeout=3) as response:
            payload = response.read(limit + 1)
            if response.status != 200 or len(payload) > limit:
                raise RuntimeError("invalid local HTTP response")
            return json.loads(payload)
    finally:
        signal.alarm(0)


signal.signal(signal.SIGALRM, alarm_handler)
state = None
flows = None
try:
    state = load("/camper/api/v2/state", 1024 * 1024)
except Exception:
    pass
if isinstance(state, dict):
    try:
        flows = load("/flows", 4 * 1024 * 1024)
    except Exception:
        pass
print("reachable" if isinstance(state, dict) else "unreachable")
flow_items = flows.get("flows", []) if isinstance(flows, dict) else flows
print(len(flow_items) if isinstance(flow_items, list) else "unavailable")
if isinstance(state, dict):
    energy = state.get("energy", {})
    orion = energy.get("orion", {})
    grid = energy.get("indevolt", {}).get("gridConnection", {})
    print("orion_online=%s;orion_mode=%s;orion_state=%s;shelly_available=%s;shelly_on=%s" % (
        orion.get("online"), orion.get("mode"), orion.get("stateText"), grid.get("available"), grid.get("on")
    ))
else:
    print("unavailable")
PY
		probe_pid=$!
		(
			sleep 12
			kill -TERM "$probe_pid" 2>/dev/null || true
			sleep 1
			kill -KILL "$probe_pid" 2>/dev/null || true
		) >/dev/null 2>&1 &
		watchdog_pid=$!
		if wait "$probe_pid"; then probe_status=0; else probe_status=$?; fi
		kill "$watchdog_pid" 2>/dev/null || true
		wait "$watchdog_pid" 2>/dev/null || true
		return "$probe_status"
	}
	node_probe=$(bounded_node_probe 2>/dev/null || true)
	node_api=$(printf '%s\n' "$node_probe" | sed -n '1p')
	node_flow_count=$(printf '%s\n' "$node_probe" | sed -n '2p')
	node_state_summary=$(printf '%s\n' "$node_probe" | sed -n '3p')
	[ -n "$node_api" ] || node_api=unreachable
	[ -n "$node_flow_count" ] || node_flow_count=unavailable
	[ -n "$node_state_summary" ] || node_state_summary=unavailable
fi
emit NODE_RED_API "$node_api"
emit NODE_RED_FLOW_COUNT "$node_flow_count"
emit NODE_RED_STATE "$node_state_summary"

runtime_flow_path=missing
for candidate_flow in /data/home/nodered/.node-red/flows.json /data/home/nodered/.node-red/flows_venus.json; do
	if [ -f "$candidate_flow" ]; then runtime_flow_path=$candidate_flow; break; fi
done
emit NODE_RED_FLOW_PATH "$runtime_flow_path"
if [ "$runtime_flow_path" = missing ]; then emit NODE_RED_FLOW_SHA256 missing; else emit NODE_RED_FLOW_SHA256 "$(file_hash "$runtime_flow_path")"; fi

backup_count=0
latest_backup=missing
latest_backup_integrity=missing
if [ -d /data/campercontrol/backups ]; then
	backup_count=$(find /data/campercontrol/backups -maxdepth 1 -type f -name '*.tar.gz' 2>/dev/null | wc -l | tr -d ' ')
	latest_backup=$(ls -1t /data/campercontrol/backups/*.tar.gz 2>/dev/null | head -n 1 || true)
	if [ -n "$latest_backup" ] && [ -f "$latest_backup.sha256" ]; then
		if (cd /data/campercontrol/backups && sha256sum -c "${latest_backup##*/}.sha256" >/dev/null 2>&1); then latest_backup_integrity=ok; else latest_backup_integrity=failed; fi
	fi
fi
emit BACKUP_COUNT "$backup_count"
emit BACKUP_TOTAL_KB "$(dir_kb /data/campercontrol/backups)"
emit LATEST_BACKUP "${latest_backup:-missing}"
emit LATEST_BACKUP_INTEGRITY "$latest_backup_integrity"
