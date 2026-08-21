#!/bin/sh

# Explicit cleanup for one health-reported gui-v2.pre-* directory. No glob is
# accepted as input and no other candidate/rollback/failed/active tree matches.
set -eu

usage() {
	printf '%s\n' "Usage: $0 --path /opt/victronenergy/gui-v2.pre-NAME --confirm" >&2
	exit 2
}

[ "$#" -eq 3 ] || usage
[ "$1" = --path ] || usage
target=$2
[ "$3" = --confirm ] || usage
case "$target" in
	/opt/victronenergy/gui-v2.pre-*) label=native; expected_parent=/opt/victronenergy ;;
	/var/www/venus/gui-v2.pre-*) label=wasm; expected_parent=/var/www/venus ;;
	*) printf '%s\n' "REFUSING_NON_PRE_GUI_TREE: $target" >&2; exit 3 ;;
esac
case "$target" in *'*'*|*'?'*|*'['*|*']'*|*'..'*) printf '%s\n' 'REFUSING_AMBIGUOUS_PATH' >&2; exit 3 ;; esac
[ "${target%/*}" = "$expected_parent" ] || { printf '%s\n' 'REFUSING_NON_DIRECT_PRE_TREE' >&2; exit 3; }
test -d "$target"
test ! -L "$target"

backup_dir=/data/campercontrol/backups
mkdir -p "$backup_dir"
test -d "$backup_dir"
test ! -L "$backup_dir"
source_kb=$(du -sk "$target" | awk '{print $1}')
free_kb=$(df -Pk "$backup_dir" | tail -n 1 | awk '{print $4}')
required_kb=$((source_kb + 8192))
if [ "$free_kb" -lt "$required_kb" ]; then
	printf '%s\n' "NOT_ENOUGH_DATA_SPACE: ${free_kb} KiB free, ${required_kb} KiB required" >&2
	exit 1
fi

tree_hash=$(find "$target" -type f -exec sha256sum '{}' ';' | sha256sum | awk '{print $1}')
archive=$backup_dir/gui-v2-pre-manual-$label-${tree_hash}.tar.gz
partial=$archive.partial
hash_file=$archive.sha256
source_files=$(find "$target" -type f | wc -l | tr -d ' ')
if [ -e "$archive" ] || [ -e "$hash_file" ]; then
	test -f "$archive"
	test -f "$hash_file"
	(cd "$backup_dir" && sha256sum -c "${hash_file##*/}")
else
	test ! -e "$partial"
	tar -czf "$partial" -C "${target%/*}" "${target##*/}"
	gzip -t "$partial"
	archived_files=$(tar -tzf "$partial" | grep -v '/$' | wc -l | tr -d ' ')
	test "$archived_files" = "$source_files"
	mv "$partial" "$archive"
	archive_hash=$(sha256sum "$archive" | awk '{print $1}')
	printf '%s  %s\n' "$archive_hash" "${archive##*/}" > "$hash_file"
	sync
fi
archive_hash=$(sha256sum "$archive" | awk '{print $1}')
archived_files=$(tar -tzf "$archive" | grep -v '/$' | wc -l | tr -d ' ')
test "$archived_files" = "$source_files"

# Exact target was validated above; no wildcard or parent path is removed.
rm -rf "$target"
test ! -e "$target"
printf 'OLD_GUI_TREE_ARCHIVED_AND_REMOVED=%s\n' "$target"
printf 'ARCHIVE=%s\n' "$archive"
printf 'ARCHIVE_SHA256=%s\n' "$archive_hash"
