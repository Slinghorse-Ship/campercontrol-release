#!/bin/sh

set -eu

release_id=2026-08-20-v3.80-beta39-v2-weather
script_dir=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
source_root=$(CDPATH= cd "$script_dir/.." && pwd -P)
target_parent=/data/campercontrol/releases
target=$target_parent/$release_id
candidate=$target_parent/.$release_id.candidate

cleanup() {
	status=$?
	trap - EXIT HUP INT TERM
	if [ "$status" -ne 0 ] && [ -d "$candidate" ]; then
		case "$candidate" in
			/data/campercontrol/releases/.*.candidate) rm -rf "$candidate" ;;
			*) printf '%s\n' "REFUSING_UNEXPECTED_REMOVE: $candidate" >&2 ;;
		esac
	fi
	exit "$status"
}

trap cleanup EXIT HUP INT TERM

test "${source_root##*/}" = "$release_id"
test -f "$source_root/release.json"
test -f "$source_root/checksums.sha256"
if grep -q '__PENDING_' "$source_root/release.json"; then
	printf '%s\n' 'PERSISTENT_INSTALL_BLOCKED_RELEASE_NOT_FINAL' >&2
	exit 5
fi
grep -Eq '"status"[[:space:]]*:[[:space:]]*"ready"' "$source_root/release.json"

(
	cd "$source_root"
	sha256sum -c checksums.sha256
)

mkdir -p "$target_parent"
test -d "$target_parent"
test ! -L "$target_parent"

if [ -d "$target" ]; then
	(
		cd "$target"
		sha256sum -c checksums.sha256
	)
	printf 'PERSISTENT_RELEASE_ALREADY_INSTALLED=%s\n' "$target"
	exit 0
fi

test ! -e "$target"
test ! -e "$candidate"

source_kb=$(du -sk "$source_root" | awk '{print $1}')
free_kb=$(df -Pk "$target_parent" | tail -n 1 | awk '{print $4}')
required_kb=$((source_kb + 8192))
if [ "$free_kb" -lt "$required_kb" ]; then
	printf '%s\n' "NOT_ENOUGH_DATA_SPACE: ${free_kb} KiB free, ${required_kb} KiB required" >&2
	exit 1
fi

mkdir "$candidate"
cp -a "$source_root"/. "$candidate"/
(
	cd "$candidate"
	sha256sum -c checksums.sha256
)
find "$candidate/tools" -type f -name '*.sh' -exec chmod 0755 '{}' ';'
find "$candidate/artifacts/cerbo-service" -type f -name '*.sh' -exec chmod 0755 '{}' ';'
mv "$candidate" "$target"
sync

trap - EXIT HUP INT TERM
printf 'PERSISTENT_RELEASE_INSTALLED=%s\n' "$target"
