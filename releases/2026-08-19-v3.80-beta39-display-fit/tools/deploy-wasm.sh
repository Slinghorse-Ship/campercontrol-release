#!/bin/sh

set -eu

force_incompatible=0
if [ "$#" -gt 1 ]; then
	printf '%s\n' 'Usage: deploy-wasm.sh [--force-incompatible]' >&2
	exit 2
fi
if [ "$#" -eq 1 ]; then
	[ "$1" = --force-incompatible ] || exit 2
	force_incompatible=1
fi

stage=/data/campercontrol/staging/camper-gui-v2-wasm-display-fit-20260819
active=/var/www/venus/gui-v2
candidate=/var/www/venus/gui-v2.display-fit-20260819
rollback_tree=/var/www/venus/gui-v2.rollback-display-fit-20260819
failed_tree=/var/www/venus/gui-v2.failed-display-fit-20260819
backup_dir=/data/campercontrol/backups
version_file=/opt/victronenergy/version
expected_venus_version='v3.80~39'
expected_venus_build='20260716174100'
expected_arch=armv7l
expected_hash=296de31be0ed3152a33344efe1974299a627ffd7eb152f99d83176e6963823d7
expected_files=21
needs_rollback=0

remove_temporary_tree() {
	case "$1" in
		"$candidate"|"$rollback_tree"|"$failed_tree") ;;
		*) printf '%s\n' "REFUSING_UNEXPECTED_REMOVE: $1" >&2; return 1 ;;
	esac
	if [ -e "$1" ]; then
		rm -rf "$1"
	fi
}

rollback() {
	trap - EXIT HUP INT TERM
	printf '%s\n' 'WASM_DEPLOYMENT_FAILED_ROLLING_BACK'
	if [ -d "$rollback_tree" ]; then
		if [ -d "$active" ]; then
			mv "$active" "$failed_tree"
		fi
		mv "$rollback_tree" "$active"
	fi
	sync
	if [ -d "$active" ] && [ -d "$failed_tree" ]; then
		remove_temporary_tree "$failed_tree" || true
	fi
}

on_exit() {
	status=$?
	trap - EXIT HUP INT TERM
	if [ "$status" -ne 0 ]; then
		if [ "$needs_rollback" -eq 1 ]; then
			rollback
		fi
		if [ -n "${backup_partial:-}" ] && [ -f "$backup_partial" ]; then
			rm -f "$backup_partial"
		fi
	fi
	exit "$status"
}

trap on_exit EXIT HUP INT TERM

test -d "$active"
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

backup_archive=$backup_dir/gui-v2-wasm-pre-display-fit-20260819-$current_hash.tar.gz
backup_partial=$backup_archive.partial
backup_hash_file=$backup_archive.sha256

test -d "$stage"
test ! -e "$candidate"
test ! -e "$rollback_tree"
test ! -e "$failed_tree"
test ! -e "$backup_partial"
if [ -e "$backup_archive" ] || [ -e "$backup_hash_file" ]; then
	test -f "$backup_archive"
	test -f "$backup_hash_file"
	(
		cd "$backup_dir"
		sha256sum -c "${backup_hash_file##*/}"
	)
	reuse_backup=1
else
	reuse_backup=0
fi

staged_files=$(find "$stage" -type f | wc -l | tr -d ' ')
staged_hash=$(sha256sum "$stage/venus-gui-v2.wasm.gz" | awk '{print $1}')
test "$staged_files" = "$expected_files"
test "$staged_hash" = "$expected_hash"
test -f "$stage/index.html"
test -f "$stage/venus-gui-v2.js"
test -f "$stage/venus-gui-v2.wasm.sha256"
gzip -t "$stage/venus-gui-v2.wasm.gz"
grep -q "const nodeRedUrl = location.protocol === 'https:'" "$stage/index.html"
grep -q "':1881'" "$stage/index.html"
grep -q "':1880'" "$stage/index.html"

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
if [ "$reuse_backup" -eq 0 ]; then
	active_kb=$(du -sk "$active" | awk '{print $1}')
	data_free_kb=$(df -Pk "$backup_dir" | tail -n 1 | awk '{print $4}')
	data_required_kb=$((active_kb + 8192))
	if [ "$data_free_kb" -lt "$data_required_kb" ]; then
		printf '%s\n' "NOT_ENOUGH_DATA_SPACE: ${data_free_kb} KiB free, ${data_required_kb} KiB required" >&2
		exit 1
	fi

	active_parent=${active%/*}
	active_name=${active##*/}
	active_files=$(find "$active" -type f | wc -l | tr -d ' ')
	tar -czf "$backup_partial" -C "$active_parent" "$active_name"
	gzip -t "$backup_partial"
	backup_files=$(tar -tzf "$backup_partial" | grep -v '/$' | wc -l | tr -d ' ')
	test "$backup_files" = "$active_files"
	mv "$backup_partial" "$backup_archive"
	backup_hash=$(sha256sum "$backup_archive" | awk '{print $1}')
	printf '%s  %s\n' "$backup_hash" "${backup_archive##*/}" > "$backup_hash_file"
	sync
else
	backup_hash=$(sha256sum "$backup_archive" | awk '{print $1}')
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
mv "$active" "$rollback_tree"
mv "$candidate" "$active"
sync

active_hash=$(sha256sum "$active/venus-gui-v2.wasm.gz" | awk '{print $1}')
test "$active_hash" = "$expected_hash"
test -f "$active/index.html"
sleep 15
active_hash_after_wait=$(sha256sum "$active/venus-gui-v2.wasm.gz" | awk '{print $1}')
test "$active_hash_after_wait" = "$expected_hash"
test -f "$active/index.html"

needs_rollback=0
remove_temporary_tree "$rollback_tree"
sync
trap - EXIT HUP INT TERM

printf 'WASM_DEPLOYMENT_OK\n'
printf 'ACTIVE_WASM_GZ_SHA256=%s\n' "$active_hash_after_wait"
printf 'COMPRESSED_BACKUP=%s\n' "$backup_archive"
printf 'COMPRESSED_BACKUP_SHA256=%s\n' "$backup_hash"
printf 'ROOT_ROLLBACK_REMOVED=%s\n' "$rollback_tree"
