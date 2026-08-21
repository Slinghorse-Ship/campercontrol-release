#!/usr/bin/env python3
"""Read-only-by-default BlueZ inventory for the optional Shelly BLE PoC.

The default invocation only reads BlueZ's existing ObjectManager state. It
does not scan, connect, pair, bond, call Shelly RPC, or switch a relay.

An active scan is intentionally behind both --experimental-enable and
--scan-seconds. Even that mode only starts/stops BlueZ discovery and never
connects to a device.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import sys
import time
from typing import Any


BLUEZ_SERVICE = "org.bluez"
OBJECT_MANAGER = "org.freedesktop.DBus.ObjectManager"
ADAPTER_IFACE = "org.bluez.Adapter1"
DEVICE_IFACE = "org.bluez.Device1"
SHELLY_1PM_GEN4_MODEL = "S4SW-001P16EU"
SHELLY_1PM_GEN4_BLUETOOTH_ID = "0x1029"
SHELLY_RPC_SERVICE_UUID = "5f6d4f53-5f52-5043-5f53-56435f49445f"


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Inspect existing BlueZ state for a powered Shelly 1PM Gen4"
    )
    parser.add_argument("--adapter", default="hci1", help="BlueZ adapter name (default: hci1)")
    parser.add_argument(
        "--scan-seconds",
        type=float,
        default=0.0,
        help="temporarily start BLE discovery; disabled by default",
    )
    parser.add_argument(
        "--experimental-enable",
        action="store_true",
        help="required acknowledgement for any active scan",
    )
    parser.add_argument(
        "--require-shelly",
        action="store_true",
        help="exit 3 when no Shelly 1PM Gen4 candidate is already visible",
    )
    return parser.parse_args(argv)


def validate_args(args: argparse.Namespace) -> None:
    if args.scan_seconds < 0 or args.scan_seconds > 30:
        raise ValueError("--scan-seconds must be between 0 and 30")
    if args.scan_seconds and not args.experimental_enable:
        raise ValueError("active discovery requires --experimental-enable")


def _plain(value: Any) -> Any:
    """Convert dbus-python containers and scalars into JSON-safe values."""

    if isinstance(value, dict):
        return {str(key): _plain(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_plain(item) for item in value]
    if isinstance(value, bytes):
        return value.hex()
    if isinstance(value, (str, bool, int, float)) or value is None:
        return value
    # dbus.ByteArray and arrays of dbus.Byte are iterable but are not always
    # instances of bytes/list on the old Python stack used by Venus OS.
    try:
        if value.__class__.__name__ == "ByteArray":
            return bytes(value).hex()
    except (TypeError, ValueError):
        pass
    try:
        return int(value)
    except (TypeError, ValueError):
        return str(value)


def _binary_map(value: Any) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, payload in dict(value or {}).items():
        try:
            result[str(int(key))] = bytes(payload).hex()
        except (TypeError, ValueError):
            result[str(key)] = _plain(payload)
    return result


def _name_matches_shelly_1pm_gen4(properties: dict[str, Any]) -> bool:
    names = " ".join(
        str(properties.get(key, "")) for key in ("Name", "Alias")
    ).lower()
    return "shelly1pmg4" in names or "s1pmg4" in names


def build_report(objects: dict[str, dict[str, dict[str, Any]]], adapter: str) -> dict[str, Any]:
    adapters: list[dict[str, Any]] = []
    devices: list[dict[str, Any]] = []
    for path, interfaces in objects.items():
        if ADAPTER_IFACE in interfaces:
            props = interfaces[ADAPTER_IFACE]
            adapters.append(
                {
                    "path": str(path),
                    "name": str(path).rsplit("/", 1)[-1],
                    "address": str(props.get("Address", "")),
                    "alias": str(props.get("Alias", "")),
                    "powered": bool(props.get("Powered", False)),
                    "discovering": bool(props.get("Discovering", False)),
                    "pairable": bool(props.get("Pairable", False)),
                    "uuids": [str(item).lower() for item in props.get("UUIDs", [])],
                }
            )
        if DEVICE_IFACE in interfaces:
            props = interfaces[DEVICE_IFACE]
            uuids = [str(item).lower() for item in props.get("UUIDs", [])]
            devices.append(
                {
                    "path": str(path),
                    "adapterPath": str(props.get("Adapter", "")),
                    "address": str(props.get("Address", "")),
                    "addressType": str(props.get("AddressType", "")),
                    "name": str(props.get("Name", "")),
                    "alias": str(props.get("Alias", "")),
                    "rssi": int(props["RSSI"]) if "RSSI" in props else None,
                    "paired": bool(props.get("Paired", False)),
                    "bonded": bool(props.get("Bonded", False)),
                    "connected": bool(props.get("Connected", False)),
                    "servicesResolved": bool(props.get("ServicesResolved", False)),
                    "uuids": uuids,
                    "manufacturerData": _binary_map(props.get("ManufacturerData", {})),
                    "serviceData": _binary_map(props.get("ServiceData", {})),
                    "nameMatchesShelly1PMGen4": _name_matches_shelly_1pm_gen4(props),
                    "rpcServiceVisible": SHELLY_RPC_SERVICE_UUID in uuids,
                }
            )

    selected_path = next(
        (item["path"] for item in adapters if item["name"] == adapter), None
    )
    candidates = [
        item
        for item in devices
        if item["nameMatchesShelly1PMGen4"]
        and (selected_path is None or item["adapterPath"] == selected_path)
    ]
    return {
        "schema": "campercontrol-shelly-ble-probe-v1",
        "readOnlyInventory": True,
        "target": {
            "device": "Shelly 1PM Gen4",
            "model": SHELLY_1PM_GEN4_MODEL,
            "bluetoothId": SHELLY_1PM_GEN4_BLUETOOTH_ID,
            "rpcServiceUuid": SHELLY_RPC_SERVICE_UUID,
        },
        "adapterRequested": adapter,
        "adapterFound": selected_path is not None,
        "adapters": sorted(adapters, key=lambda item: item["name"]),
        "devices": sorted(devices, key=lambda item: (item["name"], item["address"])),
        "candidates": candidates,
        "dependencies": {
            "dbusPython": True,
            "bleakInstalled": importlib.util.find_spec("bleak") is not None,
            "note": "Bleak is not installed or changed by this probe.",
        },
        "capabilities": {
            "scanImplemented": True,
            "gattConnectImplemented": False,
            "pairingImplemented": False,
            "rpcImplemented": False,
            "relayWriteImplemented": False,
        },
        "powerConstraint": (
            "The installed Shelly is supplied by switched 230 V. When that supply "
            "is off, absence from BlueZ is expected and BLE cannot cold-start it."
        ),
    }


def get_managed_objects() -> tuple[Any, dict[str, Any]]:
    try:
        import dbus  # type: ignore
    except ImportError as error:
        raise RuntimeError("dbus-python is required; nothing was installed") from error
    bus = dbus.SystemBus()
    root = bus.get_object(BLUEZ_SERVICE, "/")
    manager = dbus.Interface(root, OBJECT_MANAGER)
    return bus, manager.GetManagedObjects()


def find_adapter_path(objects: dict[str, Any], adapter: str) -> str | None:
    suffix = "/" + adapter
    return next(
        (
            str(path)
            for path, interfaces in objects.items()
            if str(path).endswith(suffix) and ADAPTER_IFACE in interfaces
        ),
        None,
    )


def scan(bus: Any, objects: dict[str, Any], adapter: str, seconds: float) -> None:
    import dbus  # type: ignore

    path = find_adapter_path(objects, adapter)
    if not path:
        raise RuntimeError(f"BlueZ adapter not found: {adapter}")
    properties = objects[path][ADAPTER_IFACE]
    if not bool(properties.get("Powered", False)):
        raise RuntimeError(f"BlueZ adapter is not powered: {adapter}")
    already_discovering = bool(properties.get("Discovering", False))
    interface = dbus.Interface(bus.get_object(BLUEZ_SERVICE, path), ADAPTER_IFACE)
    if not already_discovering:
        interface.StartDiscovery()
    try:
        time.sleep(seconds)
    finally:
        if not already_discovering:
            interface.StopDiscovery()


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        validate_args(args)
        bus, objects = get_managed_objects()
        scan_performed = False
        if args.scan_seconds:
            scan(bus, objects, args.adapter, args.scan_seconds)
            _, objects = get_managed_objects()
            scan_performed = True
        report = build_report(objects, args.adapter)
        report["activeScanPerformed"] = scan_performed
        print(json.dumps(report, indent=2, sort_keys=True))
        if args.require_shelly and not report["candidates"]:
            return 3
        return 0
    except (RuntimeError, ValueError) as error:
        print(json.dumps({"ok": False, "error": str(error)}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
