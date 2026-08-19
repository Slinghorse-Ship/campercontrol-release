#!/bin/sh

set -eu

release_id=2026-08-19-v3.80-beta39-display-fit
release_root=/data/campercontrol/releases/$release_id
gx_stage=/tmp/camper-gui-v2-display-fit-20260819
wasm_stage=/tmp/camper-gui-v2-wasm-display-fit-20260819
confirmation=--confirm-v3.80~39
force_incompatible=0

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ] || [ "$1" != "$confirmation" ]; then
	printf '%s\n' "Explicit confirmation required: $0 $confirmation [--force-incompatible]" >&2
	exit 2
fi
if [ "$#" -eq 2 ]; then
	[ "$2" = --force-incompatible ] || exit 2
	force_incompatible=1
fi

test "$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)" = "$release_root"
test -x "$release_root/tools/post-update-status.sh"
test -x "$release_root/tools/create-preapply-backup.sh"
test -x "$release_root/tools/install-campercontrol-service.sh"
test -x "$release_root/tools/deploy-gx.sh"
test -x "$release_root/tools/deploy-wasm.sh"
test -f "$release_root/artifacts/gx/camper-gui-v2-gx.tar.gz"
test -f "$release_root/artifacts/wasm/camper-gui-v2-wasm.tar.gz"

status_output=$($release_root/tools/post-update-status.sh)
printf '%s\n' "$status_output"
reinstall_allowed=$(printf '%s\n' "$status_output" | awk -F= '$1 == "REINSTALL_ALLOWED" { print $2 }')
release_integrity=$(printf '%s\n' "$status_output" | awk -F= '$1 == "RELEASE_INTEGRITY" { print $2 }')
modifications=$(printf '%s\n' "$status_output" | awk -F= '$1 == "VENUS_MODIFICATIONS" { print $2 }')
if [ "$release_integrity" != ok ] || [ "$modifications" != enabled ]; then
	printf '%s\n' 'REINSTALL_BLOCKED: release integrity failed or Venus modifications are disabled.' >&2
	exit 3
fi
if [ "$reinstall_allowed" != 1 ] && [ "$force_incompatible" -ne 1 ]; then
	printf '%s\n' 'REINSTALL_BLOCKED: firmware or architecture is incompatible. Review first; explicit --force-incompatible is required.' >&2
	exit 4
fi
if [ "$force_incompatible" -eq 1 ]; then
	printf '%s\n' 'DANGER: forcing a gui-v2 restore on a firmware or architecture not pinned by this release.' >&2
fi

"$release_root/tools/create-preapply-backup.sh"

if [ ! -d "$gx_stage" ]; then
	mkdir "$gx_stage"
	tar -xzf "$release_root/artifacts/gx/camper-gui-v2-gx.tar.gz" -C "$gx_stage"
fi
if [ ! -d "$wasm_stage" ]; then
	mkdir "$wasm_stage"
	tar -xzf "$release_root/artifacts/wasm/camper-gui-v2-wasm.tar.gz" -C "$wasm_stage"
fi

if [ "$force_incompatible" -eq 1 ]; then
	"$release_root/tools/install-campercontrol-service.sh" --force-incompatible
else
	"$release_root/tools/install-campercontrol-service.sh"
fi

if [ "$force_incompatible" -eq 1 ]; then
	"$release_root/tools/deploy-gx.sh" --force-incompatible
	"$release_root/tools/deploy-wasm.sh" --force-incompatible
else
	"$release_root/tools/deploy-gx.sh"
	"$release_root/tools/deploy-wasm.sh"
fi

printf 'POST_UPDATE_REINSTALL_OK\n'
"$release_root/tools/post-update-status.sh"
