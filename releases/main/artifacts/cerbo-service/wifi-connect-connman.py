#!/usr/bin/python3
"""Connect the external Venus OS Wi-Fi adapter through ConnMan.

The request is one JSON object on stdin::

    {"service":"/net/connman/service/wifi_...","passphrase":"...","ssid":"..."}

Only the selected ConnMan service on ``wlan0`` is accepted.  Credentials are
kept in memory, are never written to disk and are never included in output.
The program emits exactly one JSON object and then exits.
"""

from __future__ import annotations

import json
import os
import re
import signal
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
from typing import Any, Mapping


MAX_REQUEST_BYTES = 16 * 1024
DEFAULT_INTERFACE = "wlan0"
DEFAULT_TIMEOUT_SECONDS = 45
HTTP_BIND = "127.0.0.1"
HTTP_PORT = 18543
HTTP_CALLER_HEADER = "X-Camper-Control"
HTTP_CALLER_VALUE = "node-red"
SERVICE_RE = re.compile(
    r"^/net/connman/service/wifi_([0-9a-fA-F]{12})_"
    r"([0-9a-fA-F]+)_managed_([A-Za-z0-9_]+)$"
)
INTERFACE_RE = re.compile(r"^[A-Za-z0-9_.:-]{1,15}$")
SUCCESS_STATES = frozenset(("ready", "online"))


class RequestError(ValueError):
    """A safe, user-facing request validation error."""

    def __init__(self, code: str, message: str):
        super().__init__(message)
        self.code = code
        self.message = message


class ServiceStopped(Exception):
    """Raised by the local signal handler to unwind the HTTP service cleanly."""


def decode_request(raw: Any) -> dict[str, Any]:
    if isinstance(raw, str):
        raw = raw.encode("utf-8")
    if len(raw) > MAX_REQUEST_BYTES:
        raise RequestError("request_too_large", "JSON request is too large")
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise RequestError("invalid_json", "stdin must contain one UTF-8 JSON object")
    if not isinstance(value, dict):
        raise RequestError("invalid_request", "JSON request must be an object")
    return value


def read_request(stream: Any) -> dict[str, Any]:
    raw = stream.buffer.read(MAX_REQUEST_BYTES + 1) if hasattr(stream, "buffer") else stream.read(MAX_REQUEST_BYTES + 1)
    return decode_request(raw)


def validate_request(value: Mapping[str, Any]) -> dict[str, str]:
    allowed = {"service", "passphrase", "password", "ssid"}
    unknown = sorted(set(value) - allowed)
    if unknown:
        raise RequestError("unknown_field", "unsupported JSON field")

    service = value.get("service")
    if not isinstance(service, str) or not SERVICE_RE.fullmatch(service):
        raise RequestError("invalid_service", "service must be a scanned ConnMan Wi-Fi object path")

    primary = value.get("passphrase")
    alias = value.get("password")
    if primary is not None and alias is not None and primary != alias:
        raise RequestError("conflicting_passphrase", "passphrase fields do not match")
    passphrase = primary if primary is not None else alias
    if passphrase is None:
        passphrase = ""
    if not isinstance(passphrase, str):
        raise RequestError("invalid_passphrase", "passphrase must be a string")
    if "\x00" in passphrase or len(passphrase.encode("utf-8")) > 256:
        raise RequestError("invalid_passphrase", "passphrase has an invalid length")

    ssid = value.get("ssid", "")
    if ssid is None:
        ssid = ""
    if not isinstance(ssid, str):
        raise RequestError("invalid_ssid", "ssid must be a string")
    if "\x00" in ssid or len(ssid.encode("utf-8")) > 128:
        raise RequestError("invalid_ssid", "ssid has an invalid length")

    return {"service": service, "passphrase": passphrase, "ssid": ssid}


def configured_interface() -> str:
    interface = os.environ.get("CAMPER_WIFI_INTERFACE", DEFAULT_INTERFACE)
    if not INTERFACE_RE.fullmatch(interface):
        raise RequestError("invalid_configuration", "configured Wi-Fi interface is invalid")
    return interface


def configured_timeout() -> int:
    try:
        timeout = int(os.environ.get("CAMPER_WIFI_CONNECT_TIMEOUT", str(DEFAULT_TIMEOUT_SECONDS)))
    except ValueError:
        timeout = DEFAULT_TIMEOUT_SECONDS
    return max(10, min(timeout, 90))


def interface_mac(interface: str) -> str:
    try:
        with open("/sys/class/net/{}/address".format(interface), "r", encoding="ascii") as handle:
            return handle.read().strip().replace(":", "").lower()
    except OSError:
        raise RequestError("interface_missing", "configured external Wi-Fi interface is not available")


def validate_service(
    service: str,
    properties: Mapping[str, Any],
    interface: str,
    actual_mac: str,
) -> dict[str, str]:
    match = SERVICE_RE.fullmatch(service)
    if match is None:
        raise RequestError("invalid_service", "service path is invalid")
    if match.group(1).lower() != actual_mac.lower():
        raise RequestError("wrong_interface", "selected network does not belong to the external Wi-Fi adapter")
    if str(properties.get("Type", "")) != "wifi":
        raise RequestError("wrong_service_type", "selected ConnMan service is not Wi-Fi")

    ethernet = properties.get("Ethernet", {})
    dbus_interface = str(ethernet.get("Interface", "")) if isinstance(ethernet, Mapping) else ""
    if dbus_interface and dbus_interface != interface:
        raise RequestError("wrong_interface", "selected network belongs to a different interface")

    state = str(properties.get("State", "unknown"))
    name = str(properties.get("Name", ""))
    return {"state": state, "name": name}


def safe_error_name(error: Any) -> str:
    try:
        name = error.get_dbus_name()
    except Exception:
        name = ""
    if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_.]+", name):
        return "net.connman.Error.Failed"
    return name


def error_code_from_name(name: str) -> str:
    lower = name.lower()
    if "alreadyconnected" in lower:
        return "already_connected"
    if "invalidkey" in lower or "auth" in lower or "passphrase" in lower:
        return "authentication_failed"
    if "inprogress" in lower:
        return "connection_in_progress"
    if "notregistered" in lower:
        return "agent_not_registered"
    if "notfound" in lower or "unknownobject" in lower:
        return "service_not_available"
    if "permission" in lower or "accessdenied" in lower:
        return "permission_denied"
    if "canceled" in lower or "aborted" in lower:
        return "connection_canceled"
    return "connection_failed"


def build_agent_class(dbus: Any, dbus_service: Any):
    class Canceled(dbus.DBusException):
        _dbus_error_name = "net.connman.Agent.Error.Canceled"

    class Agent(dbus_service.Object):
        def __init__(self, bus: Any, path: str, selected_service: str, passphrase: str, ssid: str):
            super().__init__(bus, path)
            self.selected_service = selected_service
            self.passphrase = passphrase
            self.ssid = ssid
            self.reported_error = ""
            self.was_released = False
            self.was_canceled = False

        def clear_credentials(self) -> None:
            self.passphrase = ""

        @dbus_service.method("net.connman.Agent", in_signature="", out_signature="")
        def Release(self):
            self.was_released = True
            self.clear_credentials()

        @dbus_service.method("net.connman.Agent", in_signature="os", out_signature="")
        def ReportError(self, path, error):
            if str(path) == self.selected_service:
                candidate = str(error)
                if re.fullmatch(r"[A-Za-z0-9_.-]+", candidate):
                    self.reported_error = candidate

        @dbus_service.method("net.connman.Agent", in_signature="os", out_signature="")
        def RequestBrowser(self, path, url):
            del path, url
            raise Canceled("interactive browser login is not supported")

        @dbus_service.method("net.connman.Agent", in_signature="oa{sv}", out_signature="a{sv}")
        def RequestInput(self, path, fields):
            if str(path) != self.selected_service:
                raise Canceled("unexpected service")

            response = {}
            if "Passphrase" in fields and self.passphrase:
                response["Passphrase"] = dbus.String(self.passphrase)
            if "Name" in fields and self.ssid:
                response["Name"] = dbus.String(self.ssid)
            if "SSID" in fields and "Name" not in response and self.ssid:
                response["SSID"] = dbus.ByteArray(self.ssid.encode("utf-8"))

            for field_name, attributes in fields.items():
                requirement = str(attributes.get("Requirement", "")) if isinstance(attributes, Mapping) else ""
                if requirement != "mandatory" or field_name in response:
                    continue
                alternates = attributes.get("Alternates", []) if isinstance(attributes, Mapping) else []
                if any(str(alternate) in response for alternate in alternates):
                    continue
                raise Canceled("required credential type is not supported")
            return response

        @dbus_service.method("net.connman.Agent", in_signature="", out_signature="")
        def Cancel(self):
            self.was_canceled = True
            self.clear_credentials()

    return Agent


def find_service(manager: Any, selected_path: str) -> Mapping[str, Any]:
    for path, properties in manager.GetServices(timeout=5):
        if str(path) == selected_path:
            return properties
    raise RequestError("service_not_available", "selected network is no longer available; scan again")


def connect(request: Mapping[str, str]) -> dict[str, Any]:
    # Imports remain local so request validation and unit tests need no Venus OS modules.
    import dbus
    import dbus.service
    from dbus.mainloop.glib import DBusGMainLoop
    from gi.repository import GLib

    DBusGMainLoop(set_as_default=True)
    bus = dbus.SystemBus()
    manager = dbus.Interface(bus.get_object("net.connman", "/"), "net.connman.Manager")
    properties = find_service(manager, request["service"])

    interface = configured_interface()
    selected = validate_service(request["service"], properties, interface, interface_mac(interface))
    ssid = request["ssid"] or selected["name"]
    result_base = {"service": request["service"], "ssid": ssid, "interface": interface}
    if selected["state"] in SUCCESS_STATES:
        return dict(result_base, ok=True, status="already_connected", state=selected["state"])

    timeout_seconds = configured_timeout()
    agent_path = "/campercontrol/connman/agent/p{}".format(os.getpid())
    Agent = build_agent_class(dbus, dbus.service)
    agent = Agent(bus, agent_path, request["service"], request["passphrase"], ssid)
    manager.RegisterAgent(dbus.ObjectPath(agent_path), timeout=5)
    registered = True
    mainloop = GLib.MainLoop()
    outcome: dict[str, Any] = {}
    pending = None

    service_proxy = bus.get_object("net.connman", request["service"], introspect=False)
    service_interface = dbus.Interface(service_proxy, "net.connman.Service")

    def current_state() -> str:
        try:
            current = service_interface.GetProperties(timeout=5)
            return str(current.get("State", "unknown"))
        except Exception:
            return "unknown"

    def finish_success() -> None:
        outcome.update(ok=True, status="connected", state=current_state())
        mainloop.quit()

    def finish_error(error: Any) -> None:
        name = safe_error_name(error)
        state = current_state()
        if state in SUCCESS_STATES or error_code_from_name(name) == "already_connected":
            outcome.update(ok=True, status="already_connected", state=state, dbusError=name)
        else:
            code = error_code_from_name(name)
            if agent.reported_error in ("invalid-key", "auth-failed", "login-failed"):
                code = "authentication_failed"
            outcome.update(ok=False, status="error", error=code, state=state, dbusError=name)
        mainloop.quit()

    def finish_timeout() -> bool:
        nonlocal pending
        if outcome:
            return False
        try:
            if pending is not None:
                pending.cancel()
        except Exception:
            pass
        outcome.update(ok=False, status="timeout", error="connection_timeout", state=current_state())
        agent.clear_credentials()
        mainloop.quit()
        return False

    timeout_source = GLib.timeout_add_seconds(timeout_seconds, finish_timeout)
    try:
        pending = service_interface.Connect(
            reply_handler=finish_success,
            error_handler=finish_error,
            timeout=timeout_seconds + 5,
        )
        mainloop.run()
    finally:
        try:
            GLib.source_remove(timeout_source)
        except Exception:
            pass
        agent.clear_credentials()
        if registered and not agent.was_released:
            try:
                manager.UnregisterAgent(dbus.ObjectPath(agent_path), timeout=5)
            except Exception:
                pass
        try:
            agent.remove_from_connection()
        except Exception:
            pass

    return dict(result_base, **outcome)


def emit(payload: Mapping[str, Any]) -> None:
    sys.stdout.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
    sys.stdout.flush()


def acquire_lock():
    import fcntl

    handle = open("/tmp/camper-wifi-connect.lock", "a+", encoding="ascii")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        handle.close()
        raise RequestError("connection_busy", "another Wi-Fi connection attempt is already running")
    return handle


def execute_request(raw_request: Mapping[str, Any]) -> tuple[dict[str, Any], int]:
    lock = None
    request = None
    try:
        request = validate_request(raw_request)
        lock = acquire_lock()
        response = connect(request)
        return response, 200 if response.get("ok") else 502
    except RequestError as error:
        status = 409 if error.code == "connection_busy" else 400
        return {"ok": False, "status": "error", "error": error.code, "message": error.message}, status
    except Exception as error:
        name = safe_error_name(error)
        return {
            "ok": False,
            "status": "error",
            "error": error_code_from_name(name),
            "dbusError": name,
        }, 500
    finally:
        if request is not None:
            request["passphrase"] = ""
        if lock is not None:
            lock.close()


class LoopbackHTTPServer(HTTPServer):
    allow_reuse_address = True

    def handle_error(self, request, client_address):
        # Never let BaseServer print a request-related traceback.
        del request, client_address


class ConnectRequestHandler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "CamperWiFi"
    sys_version = ""

    def setup(self):
        super().setup()
        self.connection.settimeout(10)

    def log_message(self, format, *args):
        # BaseHTTPRequestHandler otherwise logs the path and client.  Requests,
        # credentials and responses must never enter persistent logs.
        del format, args

    def log_error(self, format, *args):
        del format, args

    def _json(self, status: int, payload: Mapping[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()
        self.close_connection = True

    def _loopback_client(self) -> bool:
        return bool(self.client_address and self.client_address[0] in ("127.0.0.1", "::1"))

    def do_GET(self):
        if not self._loopback_client():
            self._json(403, {"ok": False, "status": "error", "error": "loopback_only"})
            return
        if self.path != "/health":
            self._json(404, {"ok": False, "status": "error", "error": "not_found"})
            return
        try:
            interface = configured_interface()
            interface_mac(interface)
            self._json(200, {"ok": True, "status": "ready", "interface": interface})
        except RequestError as error:
            self._json(503, {"ok": False, "status": "error", "error": error.code})

    def do_POST(self):
        raw = b""
        request_value = None
        if not self._loopback_client():
            self._json(403, {"ok": False, "status": "error", "error": "loopback_only"})
            return
        if self.path != "/connect":
            self._json(404, {"ok": False, "status": "error", "error": "not_found"})
            return
        if self.headers.get(HTTP_CALLER_HEADER, "") != HTTP_CALLER_VALUE:
            self._json(403, {"ok": False, "status": "error", "error": "caller_header_required"})
            return
        content_type = self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
        if content_type != "application/json":
            self._json(415, {"ok": False, "status": "error", "error": "json_required"})
            return
        if self.headers.get("Transfer-Encoding"):
            self._json(400, {"ok": False, "status": "error", "error": "content_length_required"})
            return
        try:
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            length = -1
        if length < 1:
            self._json(400, {"ok": False, "status": "error", "error": "content_length_required"})
            return
        if length > MAX_REQUEST_BYTES:
            self._json(413, {"ok": False, "status": "error", "error": "request_too_large"})
            return
        try:
            raw = self.rfile.read(length)
            if len(raw) != length:
                raise RequestError("incomplete_request", "request body is incomplete")
            request_value = decode_request(raw)
            response, status = execute_request(request_value)
            if response.get("error") == "connection_timeout":
                status = 504
            self._json(status, response)
        except RequestError as error:
            self._json(400, {"ok": False, "status": "error", "error": error.code, "message": error.message})
        finally:
            if isinstance(request_value, dict):
                if "passphrase" in request_value:
                    request_value["passphrase"] = ""
                if "password" in request_value:
                    request_value["password"] = ""
            raw = b""

    def do_OPTIONS(self):
        # Deliberately no CORS support.  A browser page cannot drive the local
        # control service; only Node-RED supplies the required caller header.
        self._json(405, {"ok": False, "status": "error", "error": "method_not_allowed"})


def create_http_server(port: int = HTTP_PORT) -> LoopbackHTTPServer:
    return LoopbackHTTPServer((HTTP_BIND, port), ConnectRequestHandler)


def acquire_daemon_lock():
    import fcntl

    handle = open("/tmp/camper-wifi-connect-http.lock", "a+", encoding="ascii")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        handle.close()
        raise RequestError("daemon_already_running", "Wi-Fi HTTP service is already running")
    return handle


def serve() -> int:
    daemon_lock = None
    server = None
    pid_path = "/run/camper-wifi-connect-http.pid"
    previous_term = signal.getsignal(signal.SIGTERM)
    previous_int = signal.getsignal(signal.SIGINT)

    def stop_service(signum, frame):
        del signum, frame
        raise ServiceStopped()

    try:
        daemon_lock = acquire_daemon_lock()
        server = create_http_server()
        temporary_pid = pid_path + ".new"
        with open(temporary_pid, "w", encoding="ascii") as handle:
            handle.write(str(os.getpid()) + "\n")
        os.replace(temporary_pid, pid_path)
        signal.signal(signal.SIGTERM, stop_service)
        signal.signal(signal.SIGINT, stop_service)
        server.serve_forever(poll_interval=0.5)
        return 0
    except ServiceStopped:
        return 0
    except RequestError:
        return 6
    except Exception:
        return 7
    finally:
        if server is not None:
            server.server_close()
        try:
            os.unlink(pid_path)
        except OSError:
            pass
        if daemon_lock is not None:
            daemon_lock.close()
        signal.signal(signal.SIGTERM, previous_term)
        signal.signal(signal.SIGINT, previous_int)


def run_once() -> int:
    try:
        raw_request = read_request(sys.stdin)
    except RequestError as error:
        emit({"ok": False, "status": "error", "error": error.code, "message": error.message})
        return 2
    response, status = execute_request(raw_request)
    emit(response)
    if status == 200:
        return 0
    return 2 if status in (400, 409) else 4


def main(argv=None) -> int:
    arguments = list(sys.argv[1:] if argv is None else argv)
    if arguments == ["--serve"]:
        return serve()
    if arguments:
        emit({"ok": False, "status": "error", "error": "invalid_arguments"})
        return 2
    return run_once()


if __name__ == "__main__":
    raise SystemExit(main())
