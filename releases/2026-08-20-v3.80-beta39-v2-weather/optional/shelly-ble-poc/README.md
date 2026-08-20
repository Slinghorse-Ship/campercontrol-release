# Optionaler Shelly-BLE-PoC – deaktiviert

Diese Beilage stammt aus `campercontrol-node-red` Commit
`72319a32789ab199a08b45edaa434f832fcdbb7f` und gehört **nicht** zur
Produktionsinstallation dieses Releases.

- nicht im Node-RED-Flow eingebettet
- nicht in einem Cerbo-, GX- oder WASM-Deploy-Skript referenziert
- nicht automatisch ausgeführt
- kein Pairing, kein Bonding, kein GATT-RPC und kein Relais-Schreibbefehl
- aktiver Scan nur nach den zwei bewussten Parametern
  `--experimental-enable --scan-seconds N`, maximal 30 Sekunden

Der Standardaufruf des Probe-Tools liest nur bereits bekannte BlueZ-Objekte.
Auch dieser read-only Aufruf ist optional und wurde nicht auf dem Cerbo
aktiviert. Verbindlich sind die Einschränkungen und der beaufsichtigte Testplan
in `docs/SHELLY_1PM_GEN4_BLE_EXPERIMENT.md`.
