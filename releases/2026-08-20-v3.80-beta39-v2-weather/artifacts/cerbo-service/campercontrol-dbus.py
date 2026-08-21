#!/usr/bin/env python3
"""Bridge the local CamperControl API to gui-v2's existing D-Bus/MQTT path.

Neither native gui-v2 nor its WASM build connects to Node-RED directly.
FlashMQ's Venus D-Bus plugin exports this ``com.victronenergy.*`` service as
N/R/W MQTT topics both locally and through VRM; native GX reads the same
service over D-Bus.  The loopback HTTP API remains private to this bridge.
"""

from __future__ import annotations

import json
import logging
import os
import queue
import sys
import threading
import time
import urllib.error
import urllib.request
from typing import Any

SERVICE_DIRECTORY = os.path.dirname(os.path.abspath(__file__))
if SERVICE_DIRECTORY not in sys.path:
    sys.path.insert(0, SERVICE_DIRECTORY)

from campercontrol_weather import MAX_SNAPSHOT_BYTES as MAX_WEATHER_BYTES
from campercontrol_weather import RETRY_SECONDS, REFRESH_SECONDS, WeatherProvider


SERVICE_NAME = "com.victronenergy.campercontrol"
DEVICE_INSTANCE = 0
SERVICE_VERSION = "1.2.0"
API_BASE = "http://127.0.0.1:1880/camper/api/v2"
POLL_SECONDS = 1.0
STATE_ERROR_BACKOFF_SECONDS = (1.0, 2.0, 5.0, 10.0)
STATUS_HEARTBEAT_SECONDS = 60
HTTP_TIMEOUT_SECONDS = 2.0
MAX_COMMAND_BYTES = 16 * 1024
MAX_COMMAND_RESPONSE_BYTES = 64 * 1024
MAX_STATE_RESPONSE_BYTES = 320 * 1024
MAX_FRAGMENT_BYTES = 128 * 1024
STATE_SECTIONS = ("ui", "energy", "water", "climate", "lights", "vehicle", "power", "operations")

# These fields are useful for Node-RED diagnostics but would force MQTT updates
# even when every value rendered by the camper UI is unchanged.
VOLATILE_KEYS = frozenset(
    {
        "timestamp",
        "sequence",
        "seen",
        "receivedAt",
        "received_at",
        "lastSeen",
        "stateSince",
        "firstSeen",
        "lastDiscovered",
        "lastAttempt",
        "createdAt",
        "deadlineAt",
        "completedAt",
        "durationMs",
        "acknowledgedAt",
    }
)


def _without_volatile(value: Any) -> Any:
    if isinstance(value, dict):
        return {
            key: _without_volatile(child)
            for key, child in value.items()
            if key not in VOLATILE_KEYS
        }
    if isinstance(value, list):
        return [_without_volatile(child) for child in value]
    return value


def compact_state(state: Any) -> dict[str, str]:
    """Return deterministic JSON fragments matching the QML state contract."""
    if not isinstance(state, dict):
        raise ValueError("state must be an object")

    fragments: dict[str, str] = {}
    for section in STATE_SECTIONS:
        value = _without_volatile(state.get(section, {}))
        encoded = json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        if len(encoded.encode("utf-8")) > MAX_FRAGMENT_BYTES:
            raise ValueError(f"state fragment {section} exceeds {MAX_FRAGMENT_BYTES} bytes")
        fragments[section] = encoded
    return fragments


def validate_command_payload(raw_value: Any) -> tuple[str, dict[str, Any]]:
    """Validate and canonicalize one QML command before forwarding it locally."""
    if not isinstance(raw_value, str):
        raise ValueError("command must be a JSON string")
    if not raw_value or len(raw_value.encode("utf-8")) > MAX_COMMAND_BYTES:
        raise ValueError("command size is invalid")
    try:
        body = json.loads(raw_value)
    except json.JSONDecodeError as error:
        raise ValueError("command is not valid JSON") from error
    if not isinstance(body, dict):
        raise ValueError("command must be an object")
    for key in ("target", "action"):
        value = body.get(key)
        if not isinstance(value, str) or not value or len(value) > 64:
            raise ValueError(f"command {key} is invalid")
    origin = body.get("origin")
    if origin not in ("vrm", "gx"):
        raise ValueError("command origin must be vrm or gx")
    request_id = body.get("requestId", "")
    if request_id and (not isinstance(request_id, str) or len(request_id) > 128):
        raise ValueError("command requestId is invalid")
    canonical = json.dumps(body, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    return canonical, body


def _http_json(
    url: str,
    maximum_bytes: int,
    method: str = "GET",
    body: dict[str, Any] | None = None,
) -> dict[str, Any]:
    if maximum_bytes <= 0:
        raise ValueError("API response size limit must be positive")
    payload = None
    headers: dict[str, str] = {"Accept": "application/json"}
    if body is not None:
        payload = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=payload, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
        declared_header = response.headers.get("Content-Length")
        if declared_header not in (None, ""):
            try:
                declared = int(declared_header)
            except (TypeError, ValueError) as error:
                raise ValueError("API response has invalid Content-Length") from error
            if declared < 0 or declared > maximum_bytes:
                raise ValueError(f"API response exceeds {maximum_bytes} bytes")
        response_payload = response.read(maximum_bytes + 1)
    if len(response_payload) > maximum_bytes:
        raise ValueError(f"API response exceeds {maximum_bytes} bytes")
    decoded = json.loads(response_payload.decode("utf-8"))
    if not isinstance(decoded, dict):
        raise ValueError("API response must be an object")
    return decoded


def _load_venus_modules() -> tuple[Any, Any, Any]:
    from dbus.mainloop.glib import DBusGMainLoop
    from gi.repository import GLib

    candidates = (
        "/opt/victronenergy/dbus-systemcalc-py/ext/velib_python",
        "/opt/victronenergy/dbus-switch/ext/velib_python",
        "/opt/victronenergy/dbus-pump/ext/velib_python",
    )
    for candidate in candidates:
        if os.path.isfile(os.path.join(candidate, "vedbus.py")):
            sys.path.insert(0, candidate)
            break
    else:
        raise RuntimeError("Venus vedbus.py was not found")

    from vedbus import VeDbusService

    return DBusGMainLoop, GLib, VeDbusService


class CamperControlBridge:
    def __init__(self, glib: Any, service_class: Any) -> None:
        self._glib = glib
        self._service = service_class(SERVICE_NAME, register=False)
        self._commands: queue.Queue[dict[str, Any]] = queue.Queue(maxsize=32)
        self._stop = threading.Event()
        self._state_delivery_lock = threading.Lock()
        self._pending_state_delivery: tuple[str, Any] | None = None
        self._state_delivery_scheduled = False
        self._weather_delivery_lock = threading.Lock()
        self._pending_weather_delivery: tuple[str, Any] | None = None
        self._weather_delivery_scheduled = False
        self._last_fragments: dict[str, str] = {}
        self._last_weather = ""
        self._last_status_update = 0
        self._api_connected = 0
        self._last_error = "Starting"
        self._weather = WeatherProvider()

        self._service.add_mandatory_paths(
            processname=__file__,
            processversion=SERVICE_VERSION,
            connection="CamperControl Node-RED API v2",
            deviceinstance=DEVICE_INSTANCE,
            productid=None,
            productname="CamperControl bridge",
            firmwareversion=SERVICE_VERSION,
            hardwareversion=None,
            connected=1,
        )
        self._service.add_path("/Status/SchemaVersion", 1)
        self._service.add_path("/Status/ApiConnected", 0)
        self._service.add_path("/Status/LastUpdate", 0)
        self._service.add_path("/Status/LastError", "Starting")
        for section in STATE_SECTIONS:
            self._service.add_path(f"/State/{section.title()}", "{}")
        self._service.add_path("/State/Weather", "{}")
        self._service.add_path("/Status/WeatherLastUpdate", 0)
        self._service.add_path("/Status/WeatherError", "")
        self._service.add_path(
            "/Command",
            "",
            writeable=True,
            onchangecallback=self._accept_command,
        )
        self._service.add_path("/LastCommandResult", "")
        self._service.register()

        cached_weather = self._weather.cached()
        if cached_weather:
            self._apply_weather(cached_weather)

    def _accept_command(self, _path: str, raw_value: Any) -> bool:
        try:
            _canonical, body = validate_command_payload(raw_value)
            self._commands.put_nowait(body)
            return True
        except (ValueError, queue.Full) as error:
            self._last_error = str(error)[:256]
            self._service["/Status/LastError"] = self._last_error
            return False

    def _apply_state(self, fragments: dict[str, str]) -> bool:
        now = int(time.time())
        changed = any(self._last_fragments.get(section) != encoded for section, encoded in fragments.items())
        heartbeat_due = now - self._last_status_update >= STATUS_HEARTBEAT_SECONDS
        with self._service as service:
            for section, encoded in fragments.items():
                if self._last_fragments.get(section) != encoded:
                    service[f"/State/{section.title()}"] = encoded
            if self._api_connected != 1:
                service["/Status/ApiConnected"] = 1
                self._api_connected = 1
            if changed or heartbeat_due:
                service["/Status/LastUpdate"] = now
                self._last_status_update = now
            if self._last_error:
                service["/Status/LastError"] = ""
                self._last_error = ""
        self._last_fragments = fragments
        return False

    def _apply_error(self, error: str) -> bool:
        message = error[:256]
        with self._service as service:
            if self._api_connected != 0:
                service["/Status/ApiConnected"] = 0
                self._api_connected = 0
            if self._last_error != message:
                service["/Status/LastError"] = message
                self._last_error = message
        return False

    def _queue_state_delivery(self, kind: str, payload: Any) -> None:
        """Coalesce worker updates into at most one outstanding GLib callback."""
        if kind not in ("state", "error"):
            raise ValueError("unknown state delivery kind")
        with self._state_delivery_lock:
            self._pending_state_delivery = (kind, payload)
            if self._state_delivery_scheduled:
                return
            self._state_delivery_scheduled = True
        try:
            self._glib.idle_add(self._drain_state_delivery)
        except Exception:
            with self._state_delivery_lock:
                self._state_delivery_scheduled = False
            raise

    def _drain_state_delivery(self) -> bool:
        with self._state_delivery_lock:
            delivery = self._pending_state_delivery
            self._pending_state_delivery = None
            if delivery is None:
                self._state_delivery_scheduled = False
                return False

        kind, payload = delivery
        try:
            if kind == "state":
                self._apply_state(payload)
            else:
                self._apply_error(payload)
        except Exception:  # keep the single GLib source usable after D-Bus errors
            logging.exception("failed to publish CamperControl %s update", kind)

        with self._state_delivery_lock:
            if self._pending_state_delivery is not None:
                return True
            self._state_delivery_scheduled = False
            return False

    def _apply_command_result(self, result: dict[str, Any]) -> bool:
        encoded = json.dumps(result, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        self._service["/LastCommandResult"] = encoded
        if result.get("ok") is False:
            self._last_error = str(result.get("error", "Befehl fehlgeschlagen"))[:256]
            self._service["/Status/LastError"] = self._last_error
        return False

    def _apply_weather(self, weather: dict[str, Any]) -> bool:
        encoded = json.dumps(weather, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        if len(encoded.encode("utf-8")) > MAX_WEATHER_BYTES:
            self._service["/Status/WeatherError"] = "Wetterdaten überschreiten das Transportlimit"
            return False
        if encoded != self._last_weather:
            self._service["/State/Weather"] = encoded
            self._last_weather = encoded
        self._service["/Status/WeatherLastUpdate"] = int(time.time())
        self._service["/Status/WeatherError"] = ""
        return False

    def _apply_weather_error(self, error: str) -> bool:
        self._service["/Status/WeatherError"] = error[:256]
        cached = self._weather.cached()
        if cached:
            self._apply_weather(cached)
            self._service["/Status/WeatherError"] = error[:256]
        return False

    def _queue_weather_delivery(self, kind: str, payload: Any) -> None:
        """Keep only the newest weather result and one GLib idle source."""
        if kind not in ("weather", "error"):
            raise ValueError("unknown weather delivery kind")
        with self._weather_delivery_lock:
            self._pending_weather_delivery = (kind, payload)
            if self._weather_delivery_scheduled:
                return
            self._weather_delivery_scheduled = True
        try:
            self._glib.idle_add(self._drain_weather_delivery)
        except Exception:
            with self._weather_delivery_lock:
                self._weather_delivery_scheduled = False
            raise

    def _drain_weather_delivery(self) -> bool:
        with self._weather_delivery_lock:
            delivery = self._pending_weather_delivery
            self._pending_weather_delivery = None
            if delivery is None:
                self._weather_delivery_scheduled = False
                return False

        kind, payload = delivery
        try:
            if kind == "weather":
                self._apply_weather(payload)
            else:
                self._apply_weather_error(payload)
        except Exception:  # preserve the single source after D-Bus/cache errors
            logging.exception("failed to publish CamperControl %s update", kind)

        with self._weather_delivery_lock:
            if self._pending_weather_delivery is not None:
                return True
            self._weather_delivery_scheduled = False
            return False

    def _state_worker(self) -> None:
        failure_index = 0
        while not self._stop.is_set():
            started = time.monotonic()
            try:
                packet = _http_json(
                    f"{API_BASE}/state",
                    maximum_bytes=MAX_STATE_RESPONSE_BYTES,
                )
                state = packet.get("state", packet)
                fragments = compact_state(state)
                self._queue_state_delivery("state", fragments)
                failure_index = 0
                delay = max(0.05, POLL_SECONDS - (time.monotonic() - started))
            except (OSError, urllib.error.URLError, ValueError, json.JSONDecodeError) as error:
                self._queue_state_delivery("error", f"Camper API: {error}")
                delay = STATE_ERROR_BACKOFF_SECONDS[min(failure_index, len(STATE_ERROR_BACKOFF_SECONDS) - 1)]
                failure_index += 1
            self._stop.wait(delay)

    def _command_worker(self) -> None:
        while not self._stop.is_set():
            try:
                body = self._commands.get(timeout=0.5)
            except queue.Empty:
                continue
            try:
                result = _http_json(
                    f"{API_BASE}/command",
                    maximum_bytes=MAX_COMMAND_RESPONSE_BYTES,
                    method="POST",
                    body=body,
                )
            except (OSError, urllib.error.URLError, ValueError, json.JSONDecodeError) as error:
                result = {
                    "ok": False,
                    "error": f"Camper API: {error}",
                    "requestId": body.get("requestId", ""),
                }
            self._glib.idle_add(self._apply_command_result, result)
            self._commands.task_done()

    def _weather_worker(self) -> None:
        retry_index = 0
        while not self._stop.is_set():
            try:
                weather = self._weather.refresh()
                self._queue_weather_delivery("weather", weather)
                retry_index = 0
                delay = REFRESH_SECONDS
            except Exception as error:  # provider errors must never stop the D-Bus bridge
                self._queue_weather_delivery("error", f"DWD-Wetter: {error}")
                delay = RETRY_SECONDS[min(retry_index, len(RETRY_SECONDS) - 1)]
                retry_index += 1
            self._stop.wait(delay)

    def start(self) -> None:
        threading.Thread(target=self._state_worker, name="camper-state", daemon=True).start()
        threading.Thread(target=self._command_worker, name="camper-command", daemon=True).start()
        threading.Thread(target=self._weather_worker, name="camper-weather", daemon=True).start()


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    dbus_main_loop, glib, service_class = _load_venus_modules()
    dbus_main_loop(set_as_default=True)
    bridge = CamperControlBridge(glib, service_class)
    bridge.start()
    logging.info("registered %s instance %s", SERVICE_NAME, DEVICE_INSTANCE)
    glib.MainLoop().run()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
