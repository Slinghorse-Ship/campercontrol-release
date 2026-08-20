#!/bin/sh

# Explicit, compatibility-gated restore after a Venus OS update. Nothing runs
# automatically merely because a new firmware exists.
set -eu

release_id=2026-08-20-v3.80-beta39-v2-weather
release_root=/data/campercontrol/releases/$release_id
gx_archive=$release_root/artifacts/gx/camper-gui-v2-gx-v2-weather.tar.gz
wasm_archive=$release_root/artifacts/wasm/camper-gui-v2-wasm-v2-weather.tar.gz
gx_stage=/data/campercontrol/staging/camper-gui-v2-gx-v2-weather-20260820
wasm_stage=/data/campercontrol/staging/camper-gui-v2-wasm-v2-weather-20260820
gx_candidate=$gx_stage.candidate
wasm_candidate=$wasm_stage.candidate
confirmation=--confirm-v3.80~39
force_incompatible=0

remove_exact_stage() {
	path=$1
	case "$path" in "$gx_stage"|"$wasm_stage"|"$gx_candidate"|"$wasm_candidate") ;; *) printf '%s\n' "REFUSING_UNEXPECTED_STAGE: $path" >&2; return 1 ;; esac
	if [ -e "$path" ]; then
		test -d "$path"
		test ! -L "$path"
		rm -rf "$path"
	fi
}

cleanup() {
	status=$?
	trap - EXIT HUP INT TERM
	if [ "$status" -ne 0 ]; then
		[ ! -e "$gx_candidate" ] || remove_exact_stage "$gx_candidate" || true
		[ ! -e "$wasm_candidate" ] || remove_exact_stage "$wasm_candidate" || true
	fi
	exit "$status"
}
trap cleanup EXIT HUP INT TERM

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ] || [ "$1" != "$confirmation" ]; then
	printf '%s\n' "Explicit confirmation required: $0 $confirmation [--force-incompatible]" >&2
	exit 2
fi
if [ "$#" -eq 2 ]; then
	[ "$2" = --force-incompatible ] || exit 2
	force_incompatible=1
fi

test "$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)" = "$release_root"
for tool in post-update-status.sh create-preapply-backup.sh deploy-node-red.sh install-campercontrol-service.sh deploy-gx.sh deploy-wasm.sh; do test -x "$release_root/tools/$tool"; done
test -f "$gx_archive"
test -f "$wasm_archive"

status_output=$($release_root/tools/post-update-status.sh)
printf '%s\n' "$status_output"
reinstall_allowed=$(printf '%s\n' "$status_output" | awk -F= '$1 == "REINSTALL_ALLOWED" {print $2}' | tail -n 1)
release_integrity=$(printf '%s\n' "$status_output" | awk -F= '$1 == "PERSISTENT_RELEASE_INTEGRITY" {print $2}' | tail -n 1)
modifications=$(printf '%s\n' "$status_output" | awk -F= '$1 == "VENUS_MODIFICATIONS" {print $2}' | tail -n 1)
release_finalized=$(printf '%s\n' "$status_output" | awk -F= '$1 == "RELEASE_FINALIZED" {print $2}' | tail -n 1)
if [ "$release_integrity" != ok ] || [ "$modifications" != enabled ] || [ "$release_finalized" != 1 ]; then
	printf '%s\n' 'REINSTALL_BLOCKED: release integrity, finalization or Venus modification state is not safe.' >&2
	exit 3
fi
if [ "$reinstall_allowed" != 1 ] && [ "$force_incompatible" -ne 1 ]; then
	printf '%s\n' 'REINSTALL_BLOCKED: firmware/build/architecture or root-space check failed. Review first.' >&2
	exit 4
fi
if [ "$force_incompatible" -eq 1 ]; then
	printf '%s\n' 'DANGER: forcing a gui-v2 restore onto firmware not pinned by this release.' >&2
fi

"$release_root/tools/create-preapply-backup.sh"
mkdir -p /data/campercontrol/staging
test -d /data/campercontrol/staging
test ! -L /data/campercontrol/staging

# Never reuse a stage from an older or interrupted attempt.  The deploy
# scripts therefore receive only trees freshly extracted from the frozen,
# checksum-verified release archives.
for path in "$gx_stage" "$wasm_stage" "$gx_candidate" "$wasm_candidate"; do
	if [ -e "$path" ]; then
		printf '%s\n' "REINSTALL_BLOCKED_STALE_STAGE: $path" >&2
		exit 6
	fi
done

gx_archive_bytes=$(stat -c '%s' "$gx_archive")
wasm_archive_bytes=$(stat -c '%s' "$wasm_archive")
archive_kb=$(((gx_archive_bytes + wasm_archive_bytes + 1023) / 1024))
data_required_kb=$((archive_kb * 3 + 32768))
data_free_kb=$(df -Pk /data/campercontrol/staging | tail -n 1 | awk '{print $4}')
if [ "$data_free_kb" -lt "$data_required_kb" ]; then
	printf '%s\n' "NOT_ENOUGH_DATA_SPACE_FOR_STAGES: ${data_free_kb} KiB free, ${data_required_kb} KiB required" >&2
	exit 7
fi

mkdir "$gx_candidate"
tar -xzf "$gx_archive" -C "$gx_candidate"
mv "$gx_candidate" "$gx_stage"
mkdir "$wasm_candidate"
tar -xzf "$wasm_archive" -C "$wasm_candidate"
mv "$wasm_candidate" "$wasm_stage"

# The Cerbo owns state and weather.  Bring up that central transport before
# Node-RED and either UI are allowed to consume it.
if [ "$force_incompatible" -eq 1 ]; then
	"$release_root/tools/install-campercontrol-service.sh" --force-incompatible
	"$release_root/tools/deploy-node-red.sh"
	"$release_root/tools/deploy-gx.sh" --force-incompatible
	"$release_root/tools/deploy-wasm.sh" --force-incompatible
else
	"$release_root/tools/install-campercontrol-service.sh"
	"$release_root/tools/deploy-node-red.sh"
	"$release_root/tools/deploy-gx.sh"
	"$release_root/tools/deploy-wasm.sh"
fi

remove_exact_stage "$gx_stage"
remove_exact_stage "$wasm_stage"
sync
trap - EXIT HUP INT TERM
printf 'POST_UPDATE_REINSTALL_OK\n'
"$release_root/tools/post-update-status.sh"
