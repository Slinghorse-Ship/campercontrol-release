#!/usr/bin/env python3
"""Bridge the local CamperControl API to gui-v2's existing D-Bus/MQTT path.

The browser never connects to Node-RED directly.  FlashMQ's Venus D-Bus plugin
exports this ``com.victronenergy.*`` service as N/R/W MQTT topics both locally
and through VRM.  Native gui-v2 continues to use the loopback HTTP adapter.
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


SERVICE_NAME = "com.victronenergy.campercontrol"
DEVICE_INSTANCE = 0
SERVICE_VERSION = "1.0.0"
API_BASE = "http://127.0.0.1:1880/camper/api/v2"
POLL_SECONDS = 1.0
HTTP_TIMEOUT_SECONDS = 2.0
MAX_COMMAND_BYTES = 16 * 1024
MAX_FRAGMENT_BYTES = 128 * 1024
STATE_SECTIONS = ("ui", "energy", "water", "climate", "lights", "vehicle", "power")

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
    request_id = body.get("requestId", "")
    if request_id and (not isinstance(request_id, str) or len(request_id) > 128):
        raise ValueError("command requestId is invalid")
    canonical = json.dumps(body, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
    return canonical, body


def _http_json(url: str, method: str = "GET", body: dict[str, Any] | None = None) -> dict[str, Any]:
    payload = None
    headers: dict[str, str] = {"Accept": "application/json"}
    if body is not None:
        payload = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(url, data=payload, headers=headers, method=method)
    with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECONDS) as response:
        decoded = json.loads(response.read().decode("utf-8"))
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
        self._last_fragments: dict[str, str] = {}

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
        self._service.add_path(
            "/Command",
            "",
            writeable=True,
            onchangecallback=self._accept_command,
        )
        self._service.add_path("/LastCommandResult", "")
        self._service.register()

    def _accept_command(self, _path: str, raw_value: Any) -> bool:
        try:
            _canonical, body = validate_command_payload(raw_value)
            self._commands.put_nowait(body)
            return True
        except (ValueError, queue.Full) as error:
            self._service["/Status/LastError"] = str(error)[:256]
            return False

    def _apply_state(self, fragments: dict[str, str]) -> bool:
        with self._service as service:
            for section, encoded in fragments.items():
                if self._last_fragments.get(section) != encoded:
                    service[f"/State/{section.title()}"] = encoded
            service["/Status/ApiConnected"] = 1
            service["/Status/LastUpdate"] = int(time.time())
            service["/Status/LastError"] = ""
        self._last_fragments = fragments
        return False

    def _apply_error(self, error: str) -> bool:
        with self._service as service:
            service["/Status/ApiConnected"] = 0
            service["/Status/LastError"] = error[:256]
        return False

    def _apply_command_result(self, result: dict[str, Any]) -> bool:
        encoded = json.dumps(result, ensure_ascii=False, separators=(",", ":"), sort_keys=True)
        self._service["/LastCommandResult"] = encoded
        if result.get("ok") is False:
            self._service["/Status/LastError"] = str(result.get("error", "Befehl fehlgeschlagen"))[:256]
        return False

    def _state_worker(self) -> None:
        while not self._stop.is_set():
            started = time.monotonic()
            try:
                packet = _http_json(f"{API_BASE}/state")
                state = packet.get("state", packet)
                fragments = compact_state(state)
                self._glib.idle_add(self._apply_state, fragments)
            except (OSError, urllib.error.URLError, ValueError, json.JSONDecodeError) as error:
                self._glib.idle_add(self._apply_error, f"Camper API: {error}")
            elapsed = time.monotonic() - started
            self._stop.wait(max(0.05, POLL_SECONDS - elapsed))

    def _command_worker(self) -> None:
        while not self._stop.is_set():
            try:
                body = self._commands.get(timeout=0.5)
            except queue.Empty:
                continue
            try:
                result = _http_json(f"{API_BASE}/command", method="POST", body=body)
            except (OSError, urllib.error.URLError, ValueError, json.JSONDecodeError) as error:
                result = {
                    "ok": False,
                    "error": f"Camper API: {error}",
                    "requestId": body.get("requestId", ""),
                }
            self._glib.idle_add(self._apply_command_result, result)
            self._commands.task_done()

    def start(self) -> None:
        threading.Thread(target=self._state_worker, name="camper-state", daemon=True).start()
        threading.Thread(target=self._command_worker, name="camper-command", daemon=True).start()


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
