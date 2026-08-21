#!/bin/sh

SOURCE=/data/campercontrol/service/sudoers-campercontrol
TARGET=/etc/sudoers.d/campercontrol

[ -r "$SOURCE" ] || exit 1
cp "$SOURCE" "$TARGET" || exit 1
chown root:root "$TARGET" || exit 1
chmod 440 "$TARGET" || exit 1
visudo -cf "$TARGET" >/dev/null 2>&1 || {
    rm -f "$TARGET"
    exit 1
}
exit 0
