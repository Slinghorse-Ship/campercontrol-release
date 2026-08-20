#!/bin/sh

# Read-only firmware/update decision report. It delegates all resource probes to
# the bounded health script and only calculates whether automatic reinstall is
# compatible with this frozen release.
set -u

release_id=2026-08-20-v3.80-beta39-v2-weather
release_root=/data/campercontrol/releases/$release_id
expected_venus_version='v3.80~39'
expected_venus_build='20260716174100'
expected_arch=armv7l
expected_gx_hash=2e216949aeac78c7ab1151cce994caa19b7e37afeee098ec9273750a272df7d6
expected_wasm_hash=5ac4e5196baee2ed6423aff90dd20e066810e842f9accd8dc09a99356617b494
health_script=$release_root/tools/campercontrol-health-readonly.sh

if [ ! -x "$health_script" ]; then
	printf '%s\n' "HEALTH_SCRIPT_MISSING=$health_script" >&2
	exit 1
fi
health_output=$($health_script)
printf '%s\n' "$health_output"

fact() {
	printf '%s\n' "$health_output" | awk -F= -v key="$1" '$1 == key {sub(/^[^=]*=/, ""); print; exit}'
}

actual_version=$(fact VENUS_VERSION)
actual_build=$(fact VENUS_BUILD)
actual_arch=$(fact ARCHITECTURE)
release_integrity=$(fact PERSISTENT_RELEASE_INTEGRITY)
modifications=$(fact VENUS_MODIFICATIONS)
root_free_kb=$(fact ROOT_FREE_KB)

release_finalized=1
for pending_file in "$release_root/release.json" "$release_root/tools/deploy-node-red.sh" "$release_root/tools/archive-node-red-context-tmp.sh"; do
	if [ ! -f "$pending_file" ] || grep -q '__PENDING_' "$pending_file"; then release_finalized=0; fi
done

reinstall_allowed=1
[ "$actual_version" = "$expected_venus_version" ] || reinstall_allowed=0
[ "$actual_build" = "$expected_venus_build" ] || reinstall_allowed=0
[ "$actual_arch" = "$expected_arch" ] || reinstall_allowed=0
[ "$release_integrity" = ok ] || reinstall_allowed=0
[ "$modifications" = enabled ] || reinstall_allowed=0
[ "$release_finalized" = 1 ] || reinstall_allowed=0
case "$root_free_kb" in ''|*[!0-9]*) reinstall_allowed=0 ;; *) [ "$root_free_kb" -ge 32768 ] || reinstall_allowed=0 ;; esac

printf 'RELEASE_ID=%s\n' "$release_id"
printf 'EXPECTED_VENUS_VERSION=%s\n' "$expected_venus_version"
printf 'EXPECTED_VENUS_BUILD=%s\n' "$expected_venus_build"
printf 'EXPECTED_ARCHITECTURE=%s\n' "$expected_arch"
printf 'EXPECTED_GX_SHA256=%s\n' "$expected_gx_hash"
printf 'EXPECTED_WASM_GZIP_SHA256=%s\n' "$expected_wasm_hash"
printf 'RELEASE_FINALIZED=%s\n' "$release_finalized"
printf 'REINSTALL_ALLOWED=%s\n' "$reinstall_allowed"
