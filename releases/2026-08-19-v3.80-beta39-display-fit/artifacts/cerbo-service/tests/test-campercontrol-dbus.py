#!/usr/bin/env python3

import importlib.util
import json
import pathlib
import unittest


# In the source repository this test lives one level above cerbo-service. The
# release keeps the test beside the packaged service so it stays offline and
# self-contained.
MODULE_PATH = pathlib.Path(__file__).parents[1] / "campercontrol-dbus.py"
SPEC = importlib.util.spec_from_file_location("campercontrol_dbus", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
SPEC.loader.exec_module(MODULE)


class CamperControlDbusContractTest(unittest.TestCase):
    def test_compact_state_preserves_ui_sections_and_removes_volatile_values(self):
        state = {
            "sequence": 9,
            "ui": {"designVersion": "v2", "quickAccess": [{"id": "pump", "seen": 123}]},
            "energy": {"battery": {"soc": 87.5, "lastSeen": 123}},
            "water": {"fresh": {"level": None}},
            "climate": {"roomTemperature": 21.4},
            "lights": {"items": [{"id": "inside_main", "on": True}]},
            "vehicle": {"highBeam": {"manualOn": False}},
            "power": {"inverter": {"on": True}},
            "system": {"network": {"password": "must-not-cross-vrm"}},
        }
        fragments = MODULE.compact_state(state)
        self.assertEqual(tuple(fragments), MODULE.STATE_SECTIONS)
        self.assertEqual(json.loads(fragments["energy"]), {"battery": {"soc": 87.5}})
        self.assertNotIn("seen", fragments["ui"])
        self.assertNotIn("password", "".join(fragments.values()))

    def test_command_validation_accepts_current_api_shape(self):
        raw = json.dumps(
            {
                "target": "starpower",
                "action": "dim",
                "value": 55,
                "channel": 9,
                "requestId": "gui-v2-mqtt-1",
            }
        )
        canonical, body = MODULE.validate_command_payload(raw)
        self.assertEqual(body["channel"], 9)
        self.assertEqual(json.loads(canonical), body)

    def test_command_validation_rejects_non_commands_and_oversize_payloads(self):
        for value in ("", "[]", '{"target":"x"}', "x" * (MODULE.MAX_COMMAND_BYTES + 1)):
            with self.subTest(value=value[:20]):
                with self.assertRaises(ValueError):
                    MODULE.validate_command_payload(value)


if __name__ == "__main__":
    unittest.main()
