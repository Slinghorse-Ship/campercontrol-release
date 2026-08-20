#!/bin/sh

# Atomic flow-only deployment. Credentials, settings, nodes and system services
# are not replaced. The frozen hash and node count below are verified before
# Node-RED is stopped.
set -eu

release_id=2026-08-20-v3.80-beta39-v2-weather
release_root=/data/campercontrol/releases/$release_id
artifact=$release_root/artifacts/node-red/flows.json
active=/data/home/nodered/.node-red/flows.json
candidate=/data/home/nodered/.node-red/flows.json.candidate-v2-weather-20260820
pre_file=/data/home/nodered/.node-red/flows.json.pre-v2-weather-20260820
failed_file=/data/home/nodered/.node-red/flows.json.failed-v2-weather-20260820
service=/service/node-red-venus
backup_dir=/data/campercontrol/backups
expected_hash=bd0b68e0a9606c660396a0869a0820a664f17592790fdce645e78b005b4f995c
expected_nodes=358

probe_node_state() {
	python3 - <<'PY' &
import json
import signal
import urllib.request


def alarm_handler(_signum, _frame):
    raise TimeoutError("Node-RED state probe timed out")


signal.signal(signal.SIGALRM, alarm_handler)
signal.alarm(5)
try:
    with urllib.request.urlopen("http://127.0.0.1:1880/camper/api/v2/state", timeout=3) as response:
        payload = response.read(1024 * 1024 + 1)
        if response.status != 200 or len(payload) > 1024 * 1024:
            raise RuntimeError("invalid Node-RED state response")
        document = json.loads(payload)
        if not isinstance(document, dict):
            raise RuntimeError("Node-RED state is not an object")
finally:
    signal.alarm(0)
PY
	probe_pid=$!
	(
		sleep 6
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

case "$expected_hash:$expected_nodes" in
	*__PENDING_*)
		printf '%s\n' 'DEPLOY_BLOCKED_RELEASE_NOT_FINAL: Node-RED hash/count placeholders are unresolved.' >&2
		exit 5
		;;
esac
test -f "$release_root/release.json"
if grep -q '__PENDING_' "$release_root/release.json"; then
	printf '%s\n' 'DEPLOY_BLOCKED_RELEASE_NOT_FINAL' >&2
	exit 5
fi

service_stopped=0
needs_rollback=0
backup_archive=
backup_hash=

remove_exact_file() {
	path=$1
	case "$path" in "$candidate"|"$failed_file") ;; *) printf '%s\n' "REFUSING_UNEXPECTED_FILE: $path" >&2; return 1 ;; esac
	[ ! -e "$path" ] || rm -f "$path"
}

rollback() {
	trap - EXIT HUP INT TERM
	printf '%s\n' 'NODE_RED_DEPLOYMENT_FAILED_ROLLING_BACK'
	svc -d "$service" || true
	sleep 2
	if [ -f "$pre_file" ]; then
		if [ -f "$active" ]; then mv "$active" "$failed_file"; fi
		mv "$pre_file" "$active"
	fi
	sync
	svc -u "$service" || true
	service_stopped=0
	sleep 5
	if [ -f "$active" ] && [ -f "$failed_file" ]; then remove_exact_file "$failed_file" || true; fi
}

on_exit() {
	status=$?
	trap - EXIT HUP INT TERM
	if [ "$status" -ne 0 ]; then
		if [ "$needs_rollback" -eq 1 ]; then rollback; elif [ "$service_stopped" -eq 1 ]; then svc -u "$service" || true; fi
	fi
	exit "$status"
}
trap on_exit EXIT HUP INT TERM

test -f "$release_root/checksums.sha256"
(cd "$release_root" && sha256sum -c checksums.sha256 >/dev/null)
test -f "$artifact"
test -f "$active"
test -e "$service"
test ! -e "$candidate"
test ! -e "$pre_file"
test ! -e "$failed_file"
artifact_hash=$(sha256sum "$artifact" | awk '{print $1}')
test "$artifact_hash" = "$expected_hash"

python3 - "$artifact" "$expected_nodes" <<'PY'
import json
import re
import sys

path, expected = sys.argv[1], int(sys.argv[2])
with open(path, encoding="utf-8") as handle:
    document = json.load(handle)
nodes = document.get("flows", []) if isinstance(document, dict) else document
if not isinstance(nodes, list) or len(nodes) != expected:
    raise SystemExit("unexpected Node-RED node count")
for node in nodes:
    if not isinstance(node, dict) or node.get("type") != "function":
        continue
    source = str(node.get("func", ""))
    if ("setTimeout" in source or "setInterval" in source) and re.search(
        r"(?:context|flow|global)\.set\([^;\n]*(?:timer|interval)", source, re.I
    ):
        raise SystemExit("persistent context contains a timer handle")
serialized = json.dumps(nodes, ensure_ascii=False)
for forbidden in ("designVersion === 'v1'", 'designVersion === "v1"', "camper-dashboard-v1"):
    if forbidden in serialized:
        raise SystemExit("legacy V1 runtime selector/reference found")
for required in (
    "remote_link_protection",
    "if (isRemoteLinkProtected(item)) return 'remote_link_protection';",
    "const invalid = expanded.map(item => validateItem(item)).find(value => value);",
    "commands.length = commandCountBeforeScene",
    "output[index].length = length",
    "origin === 'vrm'",
):
    if required not in serialized:
        raise SystemExit(f"remote Starlink safety contract missing: {required}")
PY

current_hash=$(sha256sum "$active" | awk '{print $1}')
if [ "$current_hash" = "$expected_hash" ]; then
	printf 'NODE_RED_ALREADY_INSTALLED\n'
	printf 'ACTIVE_FLOW_SHA256=%s\n' "$current_hash"
	exit 0
fi

active_kb=$(du -k "$active" | awk '{print $1}')
data_free_kb=$(df -Pk "${active%/*}" | tail -n 1 | awk '{print $4}')
data_required_kb=$((active_kb + 8192))
if [ "$data_free_kb" -lt "$data_required_kb" ]; then
	printf '%s\n' "NOT_ENOUGH_DATA_SPACE: ${data_free_kb} KiB free, ${data_required_kb} KiB required" >&2
	exit 1
fi

cp -p "$artifact" "$candidate"
test "$(sha256sum "$candidate" | awk '{print $1}')" = "$expected_hash"

svc -d "$service"
service_stopped=1
i=0
while [ "$i" -lt 15 ]; do
	if svstat "$service" | grep -q ': down '; then break; fi
	sleep 1
	i=$((i + 1))
done
svstat "$service" | grep -q ': down '

needs_rollback=1
mv "$active" "$pre_file"
mv "$candidate" "$active"
sync
svc -u "$service"
service_stopped=0

i=0
while [ "$i" -lt 30 ]; do
	if probe_node_state >/dev/null 2>&1; then break; fi
	sleep 2
	i=$((i + 1))
done
probe_node_state
svstat "$service" | grep -q ': up '
active_hash=$(sha256sum "$active" | awk '{print $1}')
test "$active_hash" = "$expected_hash"

mkdir -p "$backup_dir"
test -d "$backup_dir"
test ! -L "$backup_dir"
backup_archive=$backup_dir/flows.json.pre-v2-weather-20260820-$current_hash.tar.gz
backup_partial=$backup_archive.partial
backup_hash_file=$backup_archive.sha256
test ! -e "$backup_archive"
test ! -e "$backup_partial"
test ! -e "$backup_hash_file"
tar -czf "$backup_partial" -C "${pre_file%/*}" "${pre_file##*/}"
gzip -t "$backup_partial"
test "$(tar -tzf "$backup_partial" | grep -v '/$' | wc -l | tr -d ' ')" = 1
mv "$backup_partial" "$backup_archive"
backup_hash=$(sha256sum "$backup_archive" | awk '{print $1}')
printf '%s  %s\n' "$backup_hash" "${backup_archive##*/}" > "$backup_hash_file"
sync
test -f "$pre_file"
rm -f "$pre_file"
test ! -e "$pre_file"
needs_rollback=0
trap - EXIT HUP INT TERM

printf 'NODE_RED_DEPLOYMENT_OK\n'
printf 'ACTIVE_FLOW_SHA256=%s\n' "$active_hash"
printf 'COMPRESSED_PRE_FLOW=%s\n' "$backup_archive"
printf 'COMPRESSED_PRE_FLOW_SHA256=%s\n' "$backup_hash"
