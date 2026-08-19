#!/bin/sh

set -eu

stage=/tmp/camper-gui-v2-wasm-design-v1-v2-20260819
active=/var/www/venus/gui-v2
candidate=/var/www/venus/gui-v2.design-v1-v2-20260819
backup=/var/www/venus/gui-v2.pre-design-v1-v2-20260819
failed=/var/www/venus/gui-v2.failed-design-v1-v2-20260819
expected_hash=02aeaf22588f0bbe98e5da391668a95f33eb46500984259f0987541906be4dca
expected_files=21
needs_rollback=0

rollback() {
	trap - EXIT HUP INT TERM
	printf '%s\n' 'WASM_DEPLOYMENT_FAILED_ROLLING_BACK'
	if [ -d "$active" ]; then
		mv "$active" "$failed"
	fi
	if [ -d "$backup" ]; then
		mv "$backup" "$active"
	fi
}

on_exit() {
	status=$?
	trap - EXIT HUP INT TERM
	if [ "$status" -ne 0 ] && [ "$needs_rollback" -eq 1 ]; then
		rollback
	fi
	exit "$status"
}

trap on_exit EXIT HUP INT TERM

test -d "$stage"
test -d "$active"
test ! -e "$candidate"
test ! -e "$backup"
test ! -e "$failed"

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

find "$stage" -type d -exec chmod 755 '{}' ';'
find "$stage" -type f -exec chmod 644 '{}' ';'

/opt/victronenergy/swupdate-scripts/remount-rw.sh

mkdir "$candidate"
cp -a "$stage"/. "$candidate"/
candidate_files=$(find "$candidate" -type f | wc -l | tr -d ' ')
candidate_hash=$(sha256sum "$candidate/venus-gui-v2.wasm.gz" | awk '{print $1}')
test "$candidate_files" = "$expected_files"
test "$candidate_hash" = "$expected_hash"

mv "$active" "$backup"
needs_rollback=1
mv "$candidate" "$active"
sync

active_hash=$(sha256sum "$active/venus-gui-v2.wasm.gz" | awk '{print $1}')
test "$active_hash" = "$expected_hash"
test -f "$active/index.html"

needs_rollback=0
trap - EXIT HUP INT TERM

printf 'WASM_DEPLOYMENT_OK\n'
printf 'ACTIVE_WASM_GZ_SHA256=%s\n' "$active_hash"
printf 'ON_DEVICE_BACKUP=%s\n' "$backup"
