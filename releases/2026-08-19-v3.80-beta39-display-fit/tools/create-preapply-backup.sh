#!/bin/sh

set -eu

backup_dir=/data/campercontrol/backups
stamp=$(date -u +%Y%m%dT%H%M%SZ)
archive=$backup_dir/maintenance-preapply-$stamp-$$.tar.gz
partial=$archive.partial
hash_file=$archive.sha256

cleanup() {
	status=$?
	trap - EXIT HUP INT TERM
	if [ "$status" -ne 0 ] && [ -f "$partial" ]; then
		rm -f "$partial"
	fi
	exit "$status"
}

trap cleanup EXIT HUP INT TERM

mkdir -p "$backup_dir"
test -d "$backup_dir"
test ! -L "$backup_dir"
test ! -e "$archive"
test ! -e "$partial"
test ! -e "$hash_file"

set --
for relative_path in \
	data/rc.local \
	data/rc.local.disabled \
	data/rc.local.before-camper-dbus \
	data/campercontrol/service \
	data/home/nodered/.node-red/flows.json \
	data/home/nodered/.node-red/flows_venus.json \
	data/home/nodered/.node-red/flows_cred.json \
	data/home/nodered/.node-red/settings.js
do
	if [ -e "/$relative_path" ]; then
		set -- "$@" "$relative_path"
	fi
done

if [ "$#" -eq 0 ]; then
	printf '%s\n' 'PREAPPLY_BACKUP_BLOCKED: no expected persistent configuration paths found' >&2
	exit 1
fi

source_kb=$(du -sk "$@" 2>/dev/null | awk '{sum += $1} END {print sum + 0}')
free_kb=$(df -Pk "$backup_dir" | tail -n 1 | awk '{print $4}')
required_kb=$((source_kb + 8192))
if [ "$free_kb" -lt "$required_kb" ]; then
	printf '%s\n' "NOT_ENOUGH_DATA_SPACE: ${free_kb} KiB free, ${required_kb} KiB required" >&2
	exit 1
fi

tar -czf "$partial" -C / "$@"
gzip -t "$partial"
mv "$partial" "$archive"
archive_hash=$(sha256sum "$archive" | awk '{print $1}')
printf '%s  %s\n' "$archive_hash" "${archive##*/}" > "$hash_file"
sync

trap - EXIT HUP INT TERM
printf 'PREAPPLY_BACKUP=%s\n' "$archive"
printf 'PREAPPLY_BACKUP_SHA256=%s\n' "$archive_hash"
