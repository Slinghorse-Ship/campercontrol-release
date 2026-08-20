#!/bin/sh

# One-time recovery for orphaned localfilesystem context *.tmp files. It is
# deliberately not part of normal install/reinstall. The fixed, frozen flow
# must already be active and an explicit confirmation is required.
set -eu

confirmation=--confirm-archive-and-remove-context-tmp
expected_flow_hash=bd0b68e0a9606c660396a0869a0820a664f17592790fdce645e78b005b4f995c
flow=/data/home/nodered/.node-red/flows.json
context_root=/data/home/nodered/.node-red/context
service=/service/node-red-venus
backup_dir=/data/campercontrol/backups

if [ "$#" -ne 1 ] || [ "$1" != "$confirmation" ]; then
	printf '%s\n' "Explicit confirmation required: $0 $confirmation" >&2
	exit 2
fi
case "$expected_flow_hash" in __PENDING_*) printf '%s\n' 'CLEANUP_BLOCKED_RELEASE_NOT_FINAL' >&2; exit 5 ;; esac
test -f "$flow"
test "$(sha256sum "$flow" | awk '{print $1}')" = "$expected_flow_hash"
test -d "$context_root"
test ! -L "$context_root"
test -e "$service"

tmp_count=$(find "$context_root" -type f -name '*.tmp' | wc -l | tr -d ' ')
tmp_bytes=$(find "$context_root" -type f -name '*.tmp' -exec stat -c '%s' '{}' ';' | awk '{sum += $1} END {print sum + 0}')
if [ "$tmp_count" -eq 0 ]; then
	printf 'NODE_RED_CONTEXT_TMP_ALREADY_CLEAN\n'
	exit 0
fi

mkdir -p "$backup_dir"
test -d "$backup_dir"
test ! -L "$backup_dir"
context_kb=$(du -sk "$context_root" | awk '{print $1}')
free_kb=$(df -Pk "$backup_dir" | tail -n 1 | awk '{print $4}')
required_kb=$((context_kb + 8192))
if [ "$free_kb" -lt "$required_kb" ]; then
	printf '%s\n' "NOT_ENOUGH_DATA_SPACE: ${free_kb} KiB free, ${required_kb} KiB required" >&2
	exit 1
fi

stamp=$(date -u +%Y%m%dT%H%M%SZ)
archive=$backup_dir/node-red-context-before-tmp-cleanup-$stamp-$$.tar.gz
partial=$archive.partial
hash_file=$archive.sha256
list_file=$backup_dir/node-red-context-tmp-$stamp-$$.list
service_stopped=0

cleanup() {
	status=$?
	trap - EXIT HUP INT TERM
	if [ "$service_stopped" -eq 1 ]; then svc -u "$service" || true; fi
	if [ "$status" -ne 0 ]; then [ ! -f "$partial" ] || rm -f "$partial"; fi
	exit "$status"
}
trap cleanup EXIT HUP INT TERM

svc -d "$service"
service_stopped=1
i=0
while [ "$i" -lt 15 ]; do
	if svstat "$service" | grep -q ': down '; then break; fi
	sleep 1
	i=$((i + 1))
done
svstat "$service" | grep -q ': down '

# Freeze the exact target list only while Node-RED is stopped.
find "$context_root" -type f -name '*.tmp' | sed "s#^$context_root/##" > "$list_file"
test "$(wc -l <"$list_file" | tr -d ' ')" = "$tmp_count"
tar -czf "$partial" -C "${context_root%/*}" "${context_root##*/}"
gzip -t "$partial"
mv "$partial" "$archive"
archive_hash=$(sha256sum "$archive" | awk '{print $1}')
printf '%s  %s\n' "$archive_hash" "${archive##*/}" > "$hash_file"
sync

while IFS= read -r relative; do
	case "$relative" in ''|/*|../*|*/../*|*/..) printf '%s\n' "REFUSING_UNSAFE_CONTEXT_PATH: $relative" >&2; exit 6 ;; esac
	target=$context_root/$relative
	case "$target" in "$context_root"/*) ;; *) printf '%s\n' "REFUSING_OUTSIDE_CONTEXT_PATH: $target" >&2; exit 6 ;; esac
	case "${target##*/}" in *.tmp) ;; *) printf '%s\n' "REFUSING_NON_TMP_CONTEXT_PATH: $target" >&2; exit 6 ;; esac
	test -f "$target"
done < "$list_file"
while IFS= read -r relative; do
	target=$context_root/$relative
	[ ! -f "$target" ] || rm -f "$target"
done < "$list_file"

remaining=$(find "$context_root" -type f -name '*.tmp' | wc -l | tr -d ' ')
test "$remaining" = 0
svc -u "$service"
service_stopped=0
i=0
while [ "$i" -lt 30 ]; do
	if wget -q -T 3 -O /dev/null http://127.0.0.1:1880/camper/api/v2/state 2>/dev/null; then break; fi
	sleep 2
	i=$((i + 1))
done
svstat "$service" | grep -q ': up '
wget -q -T 3 -O /dev/null http://127.0.0.1:1880/camper/api/v2/state
trap - EXIT HUP INT TERM

printf 'NODE_RED_CONTEXT_TMP_CLEANUP_OK\n'
printf 'REMOVED_FILES=%s\n' "$tmp_count"
printf 'REMOVED_BYTES=%s\n' "$tmp_bytes"
printf 'CONTEXT_BACKUP=%s\n' "$archive"
printf 'CONTEXT_BACKUP_SHA256=%s\n' "$archive_hash"
printf 'REMOVED_PATH_LIST=%s\n' "$list_file"
