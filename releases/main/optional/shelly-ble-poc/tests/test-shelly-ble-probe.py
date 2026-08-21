import argparse
import importlib.util
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools" / "shelly_ble_probe.py"
SPEC = importlib.util.spec_from_file_location("shelly_ble_probe", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(MODULE)


class ShellyBleProbeTests(unittest.TestCase):
    def fixture(self):
        return {
            "/org/bluez/hci1": {
                MODULE.ADAPTER_IFACE: {
                    "Address": "B8:FB:B3:FA:A2:F8",
                    "Alias": "TP-Link UB500",
                    "Powered": True,
                    "Pairable": False,
                    "Discovering": False,
                    "UUIDs": [],
                }
            },
            "/org/bluez/hci1/dev_AA_BB_CC_DD_EE_FF": {
                MODULE.DEVICE_IFACE: {
                    "Adapter": "/org/bluez/hci1",
                    "Address": "AA:BB:CC:DD:EE:FF",
                    "Name": "Shelly1PMG4-AABBCCDDEEFF",
                    "Alias": "Shelly1PMG4-AABBCCDDEEFF",
                    "RSSI": -51,
                    "Paired": False,
                    "Bonded": False,
                    "Connected": False,
                    "ServicesResolved": False,
                    "UUIDs": [MODULE.SHELLY_RPC_SERVICE_UUID.upper()],
                    "ManufacturerData": {2985: bytearray([0x29, 0x10, 0x01])},
                    "ServiceData": {},
                }
            },
        }

    def test_default_arguments_do_not_scan(self):
        args = MODULE.parse_args([])
        self.assertEqual(args.adapter, "hci1")
        self.assertEqual(args.scan_seconds, 0)
        self.assertFalse(args.experimental_enable)
        MODULE.validate_args(args)

    def test_scan_requires_explicit_experimental_gate(self):
        args = argparse.Namespace(scan_seconds=5, experimental_enable=False)
        with self.assertRaisesRegex(ValueError, "experimental-enable"):
            MODULE.validate_args(args)

    def test_scan_duration_is_bounded(self):
        args = argparse.Namespace(scan_seconds=31, experimental_enable=True)
        with self.assertRaisesRegex(ValueError, "between 0 and 30"):
            MODULE.validate_args(args)

    def test_report_finds_exact_shelly_candidate(self):
        report = MODULE.build_report(self.fixture(), "hci1")
        self.assertTrue(report["readOnlyInventory"])
        self.assertTrue(report["adapterFound"])
        self.assertEqual(report["target"]["model"], "S4SW-001P16EU")
        self.assertEqual(report["target"]["bluetoothId"], "0x1029")
        self.assertEqual(len(report["candidates"]), 1)
        self.assertTrue(report["candidates"][0]["rpcServiceVisible"])
        self.assertFalse(report["capabilities"]["pairingImplemented"])
        self.assertFalse(report["capabilities"]["relayWriteImplemented"])

    def test_adapter_lookup_is_exact(self):
        self.assertEqual(
            MODULE.find_adapter_path(self.fixture(), "hci1"), "/org/bluez/hci1"
        )
        self.assertIsNone(MODULE.find_adapter_path(self.fixture(), "hci0"))


if __name__ == "__main__":
    unittest.main()
