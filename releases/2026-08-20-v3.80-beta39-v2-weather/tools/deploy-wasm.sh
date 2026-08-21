#!/bin/sh

# Atomic Remote Console/WASM deployment. The exact old gui-v2.pre-* tree is
# archived and verified on /data before its targeted removal from root.
set -eu

force_incompatible=0
release_id=2026-08-20-v3.80-beta39-v2-weather
release_root=/data/campercontrol/releases/$release_id
artifact_freeze_status=frozen
artifact_source_commit=251b7b47124bb474f61a8cdd5217bf0634a87d47
expected_source_commit=251b7b47124bb474f61a8cdd5217bf0634a87d47
if [ "$artifact_freeze_status" != frozen ] || [ "$artifact_source_commit" != "$expected_source_commit" ]; then
	printf '%s\n' "DEPLOY_BLOCKED_UNFROZEN_ARTIFACTS: status=$artifact_freeze_status artifact=$artifact_source_commit expected=$expected_source_commit" >&2
	exit 5
fi
test -f "$release_root/release.json"
test -f "$release_root/checksums.sha256"
if grep -q '__PENDING_' "$release_root/release.json"; then
	printf '%s\n' 'DEPLOY_BLOCKED_RELEASE_NOT_FINAL' >&2
	exit 5
fi
(cd "$release_root" && sha256sum -c checksums.sha256 >/dev/null)
if [ "$#" -gt 1 ]; then
	printf '%s\n' 'Usage: deploy-wasm.sh [--force-incompatible]' >&2
	exit 2
fi
if [ "$#" -eq 1 ]; then
	[ "$1" = --force-incompatible ] || exit 2
	force_incompatible=1
fi

stage=/data/campercontrol/staging/camper-gui-v2-wasm-v2-weather-20260820
active=/var/www/venus/gui-v2
candidate=/var/www/venus/gui-v2.candidate-v2-weather-20260820
pre_tree=/var/www/venus/gui-v2.pre-v2-weather-20260820
failed_tree=/var/www/venus/gui-v2.failed-v2-weather-20260820
backup_dir=/data/campercontrol/backups
version_file=/opt/victronenergy/version
expected_venus_version='v3.80~39'
expected_venus_build='20260716174100'
expected_arch=armv7l
expected_hash=657ca9ca082b309c0204ee3ab91205122a64819ee36ffbb90093f2981e220778
expected_files=21
needs_rollback=0
backup_archive=
backup_hash=

remove_exact_temporary_tree() {
	path=$1
	case "$path" in
		"$candidate"|"$failed_tree") ;;
		*) printf '%s\n' "REFUSING_UNEXPECTED_TEMPORARY_TREE: $path" >&2; return 1 ;;
	esac
	if [ -e "$path" ]; then
		test -d "$path"
		test ! -L "$path"
		rm -rf "$path"
	fi
}

archive_and_remove_exact_pre_tree() {
	path=$1
	[ "$path" = "$pre_tree" ] || {
		printf '%s\n' "REFUSING_UNEXPECTED_PRE_TREE: $path" >&2
		return 1
	}
	test -d "$path"
	test ! -L "$path"
	pre_parent=${path%/*}
	pre_name=${path##*/}
	pre_files=$(find "$path" -type f | wc -l | tr -d ' ')
	backup_stamp=$(date -u +%Y%m%dT%H%M%SZ)
	backup_archive=$backup_dir/${pre_name}-${backup_stamp}-$$-${current_hash}.tar.gz
	backup_partial=$backup_archive.partial
	backup_hash_file=$backup_archive.sha256
	test ! -e "$backup_archive"
	test ! -e "$backup_partial"
	test ! -e "$backup_hash_file"
	tar -czf "$backup_partial" -C "$pre_parent" "$pre_name"
	gzip -t "$backup_partial"
	archived_files=$(tar -tzf "$backup_partial" | grep -v '/$' | wc -l | tr -d ' ')
	test "$archived_files" = "$pre_files"
	mv "$backup_partial" "$backup_archive"
	backup_hash=$(sha256sum "$backup_archive" | awk '{print $1}')
	printf '%s  %s\n' "$backup_hash" "${backup_archive##*/}" > "$backup_hash_file"
	sync
	(cd "$backup_dir" && sha256sum -c "${backup_hash_file##*/}")
	backup_hash=$(sha256sum "$backup_archive" | awk '{print $1}')
	archived_files=$(tar -tzf "$backup_archive" | grep -v '/$' | wc -l | tr -d ' ')
	test "$archived_files" = "$pre_files"
	rm -rf "$path"
	test ! -e "$path"
}

rollback() {
	trap - EXIT HUP INT TERM
	printf '%s\n' 'WASM_DEPLOYMENT_FAILED_ROLLING_BACK'
	if [ -d "$pre_tree" ]; then
		if [ -d "$active" ]; then mv "$active" "$failed_tree"; fi
		mv "$pre_tree" "$active"
	fi
	sync
	if [ -d "$active" ] && [ -d "$failed_tree" ]; then
		remove_exact_temporary_tree "$failed_tree" || true
	fi
}

on_exit() {
	status=$?
	trap - EXIT HUP INT TERM
	if [ "$status" -ne 0 ]; then
		if [ "$needs_rollback" -eq 1 ]; then rollback; fi
		if [ -n "${backup_partial:-}" ] && [ -f "$backup_partial" ]; then rm -f "$backup_partial"; fi
	fi
	exit "$status"
}
trap on_exit EXIT HUP INT TERM

test -d "$active"
test ! -L "$active"
test -f "$version_file"
actual_venus_version=$(sed -n '1{s/\r$//;p;}' "$version_file")
actual_venus_build=$(sed -n '3{s/\r$//;p;}' "$version_file")
actual_arch=$(uname -m)
if [ "$actual_venus_version" != "$expected_venus_version" ] || [ "$actual_venus_build" != "$expected_venus_build" ] || [ "$actual_arch" != "$expected_arch" ]; then
	if [ "$force_incompatible" -ne 1 ]; then
		printf '%s\n' "INCOMPATIBLE_FIRMWARE: expected ${expected_venus_version}/${expected_venus_build}/${expected_arch}, got ${actual_venus_version}/${actual_venus_build}/${actual_arch}" >&2
		exit 2
	fi
	printf '%s\n' "DANGER_FORCE_INCOMPATIBLE_FIRMWARE: expected ${expected_venus_version}/${expected_venus_build}/${expected_arch}, got ${actual_venus_version}/${actual_venus_build}/${actual_arch}" >&2
fi

current_hash=$(sha256sum "$active/venus-gui-v2.wasm.gz" | awk '{print $1}')
if [ "$current_hash" = "$expected_hash" ]; then
	printf 'WASM_ALREADY_INSTALLED\n'
	printf 'ACTIVE_WASM_GZ_SHA256=%s\n' "$current_hash"
	exit 0
fi

test -d "$stage"
test ! -L "$stage"
test ! -e "$candidate"
test ! -e "$pre_tree"
test ! -e "$failed_tree"
staged_files=$(find "$stage" -type f | wc -l | tr -d ' ')
staged_hash=$(sha256sum "$stage/venus-gui-v2.wasm.gz" | awk '{print $1}')
test "$staged_files" = "$expected_files"
test "$staged_hash" = "$expected_hash"
test -f "$stage/index.html"
test -f "$stage/venus-gui-v2.js"
test -f "$stage/venus-gui-v2.wasm.sha256"
gzip -t "$stage/venus-gui-v2.wasm.gz"
# Remote Console does not depend on a browser-to-Node-RED URL.  The frozen
# application uses the central com.victronenergy.campercontrol MQTT service;
# its contract is verified against the GX/WASM source payload before staging.

stage_kb=$(du -sk "$stage" | awk '{print $1}')
root_free_kb=$(df -Pk "$active" | tail -n 1 | awk '{print $4}')
root_required_kb=$((stage_kb + 8192))
if [ "$root_free_kb" -lt "$root_required_kb" ]; then
	printf '%s\n' "NOT_ENOUGH_ROOT_SPACE: ${root_free_kb} KiB free, ${root_required_kb} KiB required" >&2
	exit 1
fi

mkdir -p "$backup_dir"
test -d "$backup_dir"
test ! -L "$backup_dir"
active_kb=$(du -sk "$active" | awk '{print $1}')
data_free_kb=$(df -Pk "$backup_dir" | tail -n 1 | awk '{print $4}')
data_required_kb=$((active_kb + 8192))
if [ "$data_free_kb" -lt "$data_required_kb" ]; then
	printf '%s\n' "NOT_ENOUGH_DATA_SPACE: ${data_free_kb} KiB free, ${data_required_kb} KiB required" >&2
	exit 1
fi

find "$stage" -type d -exec chmod 755 '{}' ';'
find "$stage" -type f -exec chmod 644 '{}' ';'
/opt/victronenergy/swupdate-scripts/remount-rw.sh
mkdir "$candidate"
cp -a "$stage"/. "$candidate"/
candidate_files=$(find "$candidate" -type f | wc -l | tr -d ' ')
candidate_hash=$(sha256sum "$candidate/venus-gui-v2.wasm.gz" | awk '{print $1}')
test "$candidate_files" = "$expected_files"
test "$candidate_hash" = "$expected_hash"

needs_rollback=1
mv "$active" "$pre_tree"
mv "$candidate" "$active"
sync
active_hash=$(sha256sum "$active/venus-gui-v2.wasm.gz" | awk '{print $1}')
test "$active_hash" = "$expected_hash"
test -f "$active/index.html"
sleep 15
active_hash_after_wait=$(sha256sum "$active/venus-gui-v2.wasm.gz" | awk '{print $1}')
test "$active_hash_after_wait" = "$expected_hash"
test -f "$active/index.html"

archive_and_remove_exact_pre_tree "$pre_tree"
needs_rollback=0
sync
trap - EXIT HUP INT TERM

printf 'WASM_DEPLOYMENT_OK\n'
printf 'RELEASE_ID=%s\n' "$release_id"
printf 'ACTIVE_WASM_GZ_SHA256=%s\n' "$active_hash_after_wait"
printf 'COMPRESSED_PRE_TREE=%s\n' "$backup_archive"
printf 'COMPRESSED_PRE_TREE_SHA256=%s\n' "$backup_hash"
printf 'ROOT_PRE_TREE_REMOVED=%s\n' "$pre_tree"
