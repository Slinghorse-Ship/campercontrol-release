# CamperControl Display-Fit – Venus OS v3.80 beta 39

Additives Patch-Release auf Basis von
`2026-08-19-v3.80-beta39-design-v1-v2`. Das frühere Release wird nicht
verändert. Dieses Paket korrigiert ausschließlich die gemeinsame V2-Ausgabe
für Ford SYNC, Cerbo GX / GX Touch 50, Remote Console/WASM und Node-RED:

- V2 füllt die reale 800 × 480-Anzeige ohne künstlichen äußeren Rundrahmen bis
  in alle vier Ecken.
- Das Transit-Liniensymbol ist in Tag und Nacht transparent und zeigt den
  kompakten FORD-/Raptor-Grill.
- Oben rechts liegt ein echter Schließen-/Zurück-Knopf. Auf SYNC verwendet er
  den vorhandenen Ford-/FMods-Rückweg, im Browser nur Navigation/Fenster und
  auf GX den vorhandenen gui-v2-Seitenweg. Er sendet keinen Gerätebefehl.
- Node-RED 4.2.2 behandelt Orion `/Mode` als gelatchten Steuerzustand nur bei
  frischer Orion-Telemetrie; bei komplett fehlender Telemetrie bleibt Orion
  offline, ohne einen alten Zustand oder einen erfundenen D-Bus-Pfad anzuzeigen.
- Remote Console verwendet keine lokale Browser-URL zum Cerbo. Ein eigener
  `com.victronenergy.campercontrol`-Dienst veröffentlicht kompakte, getrennte
  JSON-Fragmente nativ über D-Bus und für VRM über den generischen N/R/W-MQTT-
  Transport. Schreibbefehle sind in VRM nur mit **Full Control** möglich.
- V1, reale Adapter, Schaltwege und die Designauswahl bleiben erhalten.

## Kompatibilität

- Cerbo GX: `armv7l`
- Venus OS: `v3.80~39`, Build `20260716174100`
- gui-v2: `1.3.14-r0`, Qt `6.8.3`
- GX SDK: `venus-scarthgap-x86_64-arm-cortexa8hf-neon-toolchain-v3.80~39.sh`
- WASM: Emscripten `3.1.56`
- Ford SYNC 3.4 / FMods: CamperControl `3.11.1`
- Node-RED: CamperControl `4.2.2`, 358 Nodes

Der gui-v2-Build gehört exakt zu diesem Venus-OS-Betastand. Für eine andere
Firmware muss er gegen deren gui-v2-, Qt- und SDK-Version neu gebaut werden.

## Artefakte

- `artifacts/gx/camper-gui-v2-gx.tar.gz` – native GX-Anwendung
- `artifacts/wasm/camper-gui-v2-wasm.tar.gz` – Remote Console/WASM
- `artifacts/cerbo-service/` – D-Bus-/MQTT-Transport mit Installation und
  Rückrolle
- `artifacts/sync/CamperControl-SYNC3-v3.11.1.zip` – Ford-USB-Installer
- `artifacts/node-red/CamperControl_NodeRED.json` – importierbarer Flow
- `artifacts/node-red/camper-dashboard*.{html,css}` – zugehörige Quellen
- `artifacts/node-red/camper-assets/` – geprüfte Laufzeit- und Logo-Assets
- `optional/shelly-ble-poc/` – deaktivierte Diagnosebeilage; kein Bestandteil
  der Installation oder des Flows
- `release.json` – Commits, Toolchains, Dateizahlen und innere Build-Hashes
- `checksums.sha256` – SHA-256 für ausnahmslos jedes ausgelieferte Artefakt

## Vor Installation zwingend prüfen

Im Releaseverzeichnis:

```powershell
./tools/verify-release.ps1
```

Die Prüfung deckt alle Artefakte ab, lehnt unsichere Archivpfade ab, zählt die
Dateien, prüft SYNC-Version, GX-Binary, komprimiertes und dekomprimiertes WASM
sowie die erforderlichen Camper-QML-Dateien.

Der Vorschauserver ist read-only und sendet keine Hardwarebefehle:

```powershell
node ./tools/server.mjs --cerbo http://172.24.24.1:1880 --port 4175
```

## Installationsreihenfolge

Die Reihenfolge ist verbindlich:

1. Cerbo-D-Bus-/MQTT-Transport installieren und seinen Read-/Write-Selbsttest
   erfolgreich abschließen.
2. Node-RED 4.2.2 samt Laufzeitbildern installieren.
3. Native GX-Anwendung installieren und am Touch testen.
4. WASM installieren und lokale sowie VRM Remote Console testen.
5. Ford SYNC unabhängig per USB aktualisieren.

Ohne den Transportdienst zeigt Remote Console bewusst keine erfundenen oder
lokal umgeleiteten Camper-Daten. Ein VRM-Zugang ohne Full Control bleibt lesend;
Schaltflächen dürfen dort keinen Write auslösen.

Der optionale Shelly-BLE-PoC wird in keinem dieser Schritte installiert oder
aktiviert. Sein Standardmodus liest lediglich bestehende BlueZ-Objekte; selbst
ein Scan verlangt zwei bewusste Parameter. Pairing, GATT-RPC und Relais-Writes
sind nicht implementiert.

## GX/WASM sicher und speicherschonend installieren

Die Release-Skripte erwarten vorab entpackte, eindeutig benannte Stage-
Verzeichnisse:

- GX: `/data/campercontrol/staging/camper-gui-v2-display-fit-20260819`
- WASM: `/data/campercontrol/staging/camper-gui-v2-wasm-display-fit-20260819`

Vor dem Entpacken auf dem Cerbo mit
`df -h /opt/victronenergy /var/www /data` und `du -sh` für vorhandene
`gui-v2*`-Verzeichnisse den Platz prüfen. Kein vorhandenes Stage-, Candidate-,
Failed-, Rollback- oder Backup-Ziel überschreiben. Die Skripte prüfen zusätzlich
die Root-Partition für die neue Kopie plus 8 MiB Reserve und `/data` konservativ
für das unkomprimierte Ausgangsvolumen plus 8 MiB Reserve.

Die Stages liegen absichtlich auf `/data`: Dadurch belegen Upload und neuer
Kandidatenbaum nicht gleichzeitig zweimal Platz auf der knappen Root-Partition.

`tools/deploy-gx.sh` und `tools/deploy-wasm.sh` prüfen Dateizahl und inneren
Build-Hash. Vor dem Swap schreiben sie je ein komprimiertes Backup samt
SHA-256-Sidecar nach `/data/campercontrol/backups/`:

- `gui-v2-pre-display-fit-20260819.tar.gz`
- `gui-v2-wasm-pre-display-fit-20260819.tar.gz`

Auf der knappen Root-Partition wird die bisherige Installation nur temporär als
eindeutig benannter Rollback-Baum umbenannt. Bei einem Fehler wird sie sofort
zurückgeschoben. Nach 15 Sekunden stabiler Prozess-/Hashprüfung wird dieser
temporäre Baum gezielt entfernt; es bleibt keine zusätzliche unkomprimierte
Root-Sicherung liegen. Namenskollisionen führen zum Abbruch, nicht zum
Überschreiben.

Die Skripte werden hier nur ausgeliefert. Sie enthalten keine Zugangsdaten und
werden durch die Release-Prüfung oder Vorschau niemals ausgeführt.

Nach erfolgreichem Hardwaretest können hochgeladene Release-Archive und die
beiden oben genannten Stage-Verzeichnisse gezielt entfernt werden. Die
ausgegebenen `COMPRESSED_BACKUP`-Dateien und ihre `.sha256`-Sidecars auf `/data`
mindestens bis nach bestätigter Tag-/Nacht-, Touch-, Einstellungs- und
Remote-Console-Prüfung behalten. Ihre Integrität lässt sich im Backupverzeichnis
mit `sha256sum -c <Dateiname>.sha256` prüfen. Niemals pauschal `/tmp`, `/data`,
`/opt/victronenergy` oder `/var/www` bereinigen.

## Cerbo-Transport, Node-RED und SYNC

Die mitgelieferten Transport-Werkzeuge besitzen getrennte Installations- und
Rollback-Wege. Vor Installation muss deren eigener Preflight die vorhandene
VRM-Portal-ID, D-Bus/MQTT-Verfügbarkeit und die erwarteten Zielpfade bestätigen.
Keine Zugangsdaten werden im Release gespeichert.

Vor dem Node-RED-Import die aktiven Flows exportieren. Dann ausschließlich
`CamperControl_NodeRED.json` importieren und erst nach fehlerfreiem Deploy die
drei Laufzeitbilder `CamperIcon.png`, `VehicleLightsLeft.png` und
`VehicleLightsRight.png` nach
`/data/home/nodered/.node-red/public/camper-assets/` kopieren. Die beiden
`transit-line-symbol-*.png` sind die transparenten, im finalen Flow eingebetteten
Logoquellen und dienen der reproduzierbaren Prüfung.

Für SYNC den Inhalt des ZIPs in das Stammverzeichnis eines leeren USB-Sticks
entpacken. Dort müssen `SyncMyMod` und `DONTINDX.MSA` liegen. Der Installer
sichert die bekannten Ford-QML-Dateien und verweigert unbekannte Stände.

## Validierung

- gemeinsames 800 × 480 Full-Bleed-Verhalten für Tag und Nacht
- transparentes Transit-/FORD-Raptor-Symbol auf allen drei UI-Implementierungen
- Schließen-/Zurück-Pfad ohne Hardwarekommando
- nativer D-Bus- und generischer VRM-N/R/W-MQTT-Transport ohne lokale Browser-
  URL; Writes nur bei VRM Full Control
- GX- und WASM-Releasebuild mit offizieller Projekt-Buildkette
- SYNC-Vertragsprüfungen für Layout, Logo, Close und Installer
- Node-RED: 358 Nodes, `1.390` Assertions, 0 Fehler; 61
  Functions syntaktisch und 378 Verbindungen geprüft
- optionaler Shelly-BLE-Probe: 5 Offline-Vertragstests; standardmäßig
  deaktiviert und ohne Pairing/RPC/Relais-Write
- V1/V2-Auswahl und originale Victron-System-/Einstellungswege bleiben erhalten

Alle exakten Commits, Größen und SHA-256-Werte stehen in `release.json` und
`checksums.sha256`.
