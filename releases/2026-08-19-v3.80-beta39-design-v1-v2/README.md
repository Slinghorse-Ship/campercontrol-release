# CamperControl V1/V2 – Venus OS v3.80 beta 39

Gemeinsames Release des klassischen CamperControl-Designs V1 und des nativen
`Transit Horizon`-Designs V2 für Cerbo GX / GX Touch 50, Remote Console/WASM,
Node-RED und Ford SYNC 3.

V2 ist der native Port der eingefrorenen Referenz
`assets/design-source/campercontrol-v2-transit-horizon.html`. Weder die GX-/WASM-
noch die SYNC-Ausgabe bettet diese HTML-Datei ein: Beide sind eigenständige QML-
Implementierungen und verwenden dieselben realen Adapter und Befehle wie V1.

## Kompatibilität

- Cerbo GX: `armv7l`
- Venus OS: `v3.80~39`, Build `20260716174100`
- gui-v2: `1.3.14`
- Qt: `6.8.3`
- GX SDK: `venus-scarthgap-x86_64-arm-cortexa8hf-neon-toolchain-v3.80~39.sh`
- WASM: Emscripten `3.1.56`
- Ford-Paket: CamperControl SYNC `3.11.0`
- Node-RED-Paket: CamperControl `4.2.0`, 358 Nodes

Der gui-v2-Fork ist für genau diesen Venus-OS-Betastand gebaut. Vor einem Einsatz
auf einer anderen Firmware muss er gegen deren gui-v2-/Qt-Version neu geprüft und
gebaut werden.

## Design auswählen

V2 ist bei einer neuen Installation die Vorgabe. Eine ausdrücklich gespeicherte
V1-Auswahl bleibt erhalten.

- GX Touch / Remote Console: `Einstellungen` → `CamperControl` → `Design`
- Ford SYNC: `Einstellungen` → `OBERFLÄCHE` → `V1` oder `V2`
- Node-RED: `EINST.` → `OBERFLÄCHE` → `DESIGN V1` oder `DESIGN V2`

Die Auswahl wird nicht automatisch zwischen den Zielen synchronisiert: gui-v2
nutzt seine lokale Qt-Einstellung, Ford seine FMods-Konfigurationsdatei und
Node-RED den persistenten Flow-Kontext. Beide Designs teilen innerhalb des
jeweiligen Ziels dieselben Live-Daten und Hardwarebefehle.

## Artefakte

- `artifacts/gx/camper-gui-v2-gx.tar.gz`: native GX-Anwendung
- `artifacts/wasm/camper-gui-v2-wasm.tar.gz`: Remote Console/WASM
- `artifacts/sync/CamperControl-SYNC3-v3.11.0.zip`: Ford-SYNC-Installer
- `artifacts/node-red/CamperControl_NodeRED.json`: importierbarer 358-Node-Flow
- `artifacts/node-red/camper-dashboard*.{html,css}`: Dashboard-Quellen
- `artifacts/node-red/camper-assets/`: Bilder unter den vom Flow erwarteten Namen
- `screenshots/`: geprüfte 800 × 480 Referenzdarstellungen
- `release.json`: genaue Commits, Toolchain und innere Build-Prüfsummen
- `checksums.sha256`: Integrität der ausgelieferten Dateien

## Vor jeder Installation prüfen

Im Releaseverzeichnis:

```powershell
./tools/verify-release.ps1
```

Der mitgelieferte Node-RED-Vorschauserver ist read-only und sendet keine
Hardwarebefehle:

```powershell
node ./tools/server.mjs --cerbo http://172.24.24.1:1880
```

Für das produktive Node-RED-Dashboard den Inhalt von
`artifacts/node-red/camper-assets/` nach
`/data/home/nodered/.node-red/public/camper-assets/` kopieren. Die Dateinamen sind
bereits exakt auf `CamperIcon.png`, `VehicleLightsLeft.png` und
`VehicleLightsRight.png` abgebildet.

## Installation und Rückrolle

`tools/deploy-gx.sh` und `tools/deploy-wasm.sh` prüfen Dateizahl sowie die innere
Build-Prüfsumme, bevor sie Verzeichnisse auf dem Cerbo austauschen. Sie legen auf
dem Gerät jeweils ein Backup an und rollen bei einem Fehler zurück.

Die Skripte verändern `/opt/victronenergy/gui-v2` beziehungsweise
`/var/www/venus/gui-v2`. Sie werden in diesem Release nur bereitgestellt und wurden
nicht automatisch auf ein Gerät ausgeführt. Zugangsdaten und SSH-Schlüssel sind
nicht enthalten.

## Validierung

- V1 und V2 getrennte Darstellungswege, gemeinsame echte Daten-/Command-Adapter
- V2 Home, Licht, Klima, 12/230 V, Energiequellen, Solar-Detail, Wasser und System
- Victron-Einstellungen bleiben aus dem Camper-System erreichbar
- QML-Formatierung, QML-Lint und 800 × 480 Touch-Smokes erfolgreich
- Ford: Qt5-Laden, Persistenz, 13 Touch-/State-/Command-Prüfungen und Installer-Test
- Node-RED: 358 Nodes, 1.378 Assertions, 0 Fehler; 61 Functions syntaktisch geprüft
- fehlende oder veraltete Sensordaten werden als nicht verfügbar dargestellt und
  nicht durch Prototyp-Demowerte ersetzt

Die offiziellen GX- und WASM-Buildresultate sowie deren Hashes stehen in
`release.json`.
