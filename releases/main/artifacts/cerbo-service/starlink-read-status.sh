#!/bin/sh

GRPCURL=${CAMPER_STARLINK_GRPCURL:-/data/campercontrol/starlink/grpcurl}
DISH=192.168.100.1:9200

# Zweite, hardwareseitige Freigabe direkt vor jeder Abfrage. Node-RED allein
# darf bei ausgeschaltetem STAR-Power-Kanal 5 keinen Starlink-Prozess starten.
switch_service="$(dbus -y 2>/dev/null | grep '^com.victronenergy.switch' | head -n 1)"
channel_state=""
if [ -n "$switch_service" ]; then
    channel_state="$(dbus -y "$switch_service" /SwitchableOutput/4/State GetValue 2>/dev/null | awk '/value =/ {print $3}' | tail -n 1)"
fi

if [ "$channel_state" = "0" ]; then
    printf '%s\n' '{"powered":false,"online":false,"status":"Ausgeschaltet"}'
    exit 0
fi
if [ "$channel_state" != "1" ]; then
    printf '%s\n' '{"powered":null,"online":false,"status":"Kanalrückmeldung nicht verfügbar","error":"channel_feedback_unavailable"}'
    exit 2
fi
if [ ! -x "$GRPCURL" ]; then
    printf '%s\n' '{"powered":true,"online":false,"status":"Starlink-Client fehlt","error":"grpcurl_missing"}'
    exit 3
fi

# BufferedReader.read() wartet trotz kleiner Pipe-Schreibblöcke bis EOF oder
# bis zum 65.537. Byte. So wird normales, gestückelt ausgegebenes JSON nicht
# wie bei `dd count=1` nach dem ersten kurzen read abgeschnitten. Bei Overflow
# wird grpcurl sofort beendet; ansonsten wird sein Exitcode unverändert an den
# Node-RED-Exec-Ausgang weitergereicht. stdout+stderr bleiben zusammen auf
# maximal 64 KiB plus genau ein Markerbyte begrenzt.
exec /usr/bin/python3 - "$GRPCURL" "$DISH" <<'PY'
import signal
import subprocess
import sys

maximum = 64 * 1024
command = [
    sys.argv[1],
    "-max-time", "5",
    "-plaintext",
    "-d", '{"get_diagnostics":{}}',
    sys.argv[2],
    "SpaceX.API.Device.Device/Handle",
]

try:
    process = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
    )
except OSError as error:
    sys.stdout.write(("grpcurl_start_failed: " + str(error))[:512] + "\n")
    raise SystemExit(127)

assert process.stdout is not None
timed_out = False

def wall_clock_timeout(_signum, _frame):
    global timed_out
    timed_out = True
    if process.poll() is None:
        process.kill()
    raise TimeoutError("grpcurl wall-clock timeout")

signal.signal(signal.SIGALRM, wall_clock_timeout)
signal.alarm(8)
try:
    payload = process.stdout.read(maximum + 1)
    overflow = len(payload) > maximum
    if overflow and process.poll() is None:
        process.kill()
    return_code = process.wait()
except TimeoutError:
    payload = b"grpcurl_timeout\n"
    overflow = False
    try:
        return_code = process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
        return_code = 124
finally:
    signal.alarm(0)

sys.stdout.buffer.write(payload)
sys.stdout.buffer.flush()
if timed_out:
    raise SystemExit(124)
if overflow:
    raise SystemExit(90)
if return_code < 0:
    raise SystemExit(128 + min(127, -return_code))
raise SystemExit(return_code)
PY
