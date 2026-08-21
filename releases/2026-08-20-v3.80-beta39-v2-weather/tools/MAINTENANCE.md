# CamperControl Maintenance

`CamperControl-Maintenance.ps1` ist ein eigenständig nutzbares Windows-
Wartungswerkzeug. Ohne Schalter liest es ausschließlich Statusdaten. Es führt
auf dem Cerbo keine Dateiänderung, keinen D-Bus-Write, keinen Service-Neustart
und keinen Gerätebefehl aus. Lokal entstehen nur ein Text-, JSON- und ZIP-
Bericht im Temp-Verzeichnis oder im explizit gewählten `-ReportDirectory`.

## Read-only Audit

Bevorzugt wird ein bereits eingerichteter SSH-Schlüssel:

```powershell
./tools/CamperControl-Maintenance.ps1 -CerboHost 172.24.24.1 -IdentityFile $env:USERPROFILE/.ssh/id_ed25519
```

Ist nur ein Passwort vorhanden, fordert OpenSSH es interaktiv an. Es wird weder
als Parameter übernommen noch gespeichert oder in einen Bericht geschrieben:

```powershell
./tools/CamperControl-Maintenance.ps1 -Authentication Prompt
```

Unbekannte Hostschlüssel werden standardmäßig abgelehnt. Nur bewusstes
`-AcceptNewHostKey` darf einen neuen Schlüssel in `known_hosts` aufnehmen.

Der Bericht prüft Firmware/Build/Architektur, Root-/Data-Belegung,
`MemAvailable`, Load Average, Node-RED-RSS, `rc.local` sowie
`rc.local.disabled`, die persistente Releasekopie, GX/WASM-Hashes, den im
Manifest finalisierten Node-RED-Count, Flow/API, CamperControl-D-Bus,
FlashMQ/GXdbus/GXrpc/VRM, Orion und Shelly/INDEVOLT sowie komprimierte Backups.
Zusätzlich werden nur klar begrenzte Verzeichnisse vermessen: Logs,
Node-RED-Context, verwaiste Context-`*.tmp`-Dateien, CamperControl-Daten und alte
`gui-v2.pre-*`/Rollback/Candidate-Bäume. Ein stromloser Shelly bei
ausgeschaltetem 230 V wird ausdrücklich als erwarteter Aus-Zustand bewertet;
der optionale BLE-PoC wird nie automatisch aktiviert.

Der Wettercheck liest ausschließlich `/State/Weather`,
`/Status/WeatherLastUpdate` und `/Status/WeatherError` sowie die Größen der
exakten Cache-Dateien. MOSMIX_L ist bereits beim DWD aufbereitet; der Cerbo
berechnet kein Vorhersagemodell. GX, WASM und SYNC laden Wetter nicht selbst.

## Anwenden und Restore nach Firmware-Update

`-Apply` ist eine getrennte, explizite Aktion. Vor jeder Änderung wird ein
komprimiertes, gehashtes Backup nach `/data/campercontrol/backups` geschrieben.
Eine unbekannte Firmware blockiert den Restore. `-ForceFirmwareMismatch` ist
nur zusammen mit `-Apply` verfügbar und ersetzt keine Kompatibilitätsprüfung:

```powershell
./tools/CamperControl-Maintenance.ps1 -Apply -Confirm
```

Das Werkzeug überschreibt weder eine beschädigte persistente Releasekopie noch
einen vorhandenen `/data/campercontrol/staging`-Stage. Nach einem Venus-Update kann `/data/rc.local` in
`/data/rc.local.disabled` umbenannt sein; dann bleibt der Restore blockiert, bis
Modifikationen bewusst wieder aktiviert und auditiert wurden.

Das eine Pre-Apply-Backup umfasst zusätzlich den Starlink-Helferbaum,
`rc.local.before-camper-wifi-connect` und die installierte Sudoers-Datei. Der
anschließende Cerbo-Service-Tausch ist separat transaktional: genau 19
manifestierte Dateien werden aus einer Candidate-Struktur übernommen. Die
beiden runit-Serviceverzeichnisse samt `supervise`-Zustand werden nicht ersetzt;
nur ihre jeweilige `run`-Datei wird atomar getauscht. Der Starlink-Statusleser
wird explizit nach `/data/campercontrol/starlink/read-status.sh` abgebildet.

Der Upload verwendet `/data/campercontrol/incoming`, die Entpack-Stages liegen
unter `/data/campercontrol/staging`; der knappe beziehungsweise RAM-basierte
`/tmp` wird dafür nicht benutzt. Der exakte Incoming-Pfad wird erst nach
erfolgreicher persistenter Installation entfernt. Beim GX-/WASM-Tausch bleibt
der alte aktive Baum als
ein exakter `gui-v2.pre-v2-weather-20260820`-Pfad erhalten. Erst nachdem der neue
Prozess beziehungsweise WASM-Hash stabil geprüft wurde, wird genau dieser Baum
nach `/data/campercontrol/backups` komprimiert, das Archiv gezählt und gehasht
und anschließend genau dieser eine Pfad entfernt. Es gibt keine Löschung über
`gui-v2.*`, ein Elternverzeichnis oder einen unvalidierten Parameter.
Ein bereits vorhandener, vom Health-Report exakt benannter `gui-v2.pre-*`-Baum
kann separat und nur mit vollständigem Literalpfad archiviert werden:

```sh
./tools/archive-old-gui-tree.sh \
  --path /opt/victronenergy/gui-v2.pre-BEISPIEL --confirm
```

Candidate-, Failed-, Rollback- und aktive Bäume akzeptiert dieses Tool nicht.

Die bekannte Node-RED-Context-Aufblähung darf erst nach Installation des
finalisierten, Timer-sicheren Flows bereinigt werden:

```sh
/data/campercontrol/releases/2026-08-20-v3.80-beta39-v2-weather/tools/archive-node-red-context-tmp.sh \
  --confirm-archive-and-remove-context-tmp
```

Das Tool stoppt Node-RED, archiviert den gesamten Context mit SHA-256, friert
die exakte `*.tmp`-Liste ein und entfernt ausschließlich diese Dateien. Es ist
kein Bestandteil des normalen Reinstall und startet nie automatisch.

## BuildKnownCompatible

`-Build` baut ausschließlich einen Eintrag aus `compatibility-matrix.json`.
Voraussetzungen sind Windows PowerShell 7, Git, Python mit PySide6 6.8.3, WSL
mit Ubuntu 22.04 oder neuer, der passende Venus-GX-SDK sowie Emscripten 3.1.56.
Das gui-v2-Repository muss sauber sein und exakt auf dem in der Matrix
festgelegten Commit stehen.

```powershell
./tools/CamperControl-Maintenance.ps1 `
  -Build `
  -GuiRepository C:\src\camper-gui-v2 `
  -BuildOutputDirectory C:\build\campercontrol-v3.80-beta39
```

Vor den offiziellen `scripts/build-gx.sh` und `scripts/build-wasm.sh` laufen der
V2-Panelvertrag, der VRM-Transportvertrag und der reale
800 × 480-Touch-/Viewport-Test. Danach
entstehen zwei Archive, innere Hashes, `build-manifest.json` und
`checksums.sha256` im neuen Ausgabeordner. Der Build installiert und deployed
nichts.

Bei unbekannter Firmware, falschem Commit, Dirty Worktree, fehlender Toolchain,
Testfehler oder API-/Mergekonflikt stoppt das Werkzeug mit Bericht. Es checkt
niemals selbst einen Branch aus, merged nicht und portiert keine Quellen.
Netzwerkzugriff ist standardmäßig aus; `-AllowNetwork` erlaubt höchstens ein
gezieltes `git fetch` des gepinnten Commits und niemals `pull`, Checkout oder
Merge. Für vollständig offline nutzbare Releases müssen Repository, Toolchains
und dieses Releasepaket vorher lokal beziehungsweise auf USB vorhanden sein.

## Offline-Test

```powershell
./tools/tests/test-maintenance.ps1
```

Der Test parst beide Skripte, prüft die Read-only-/Credential-Verträge, die
Kompatibilitätsmatrix sowie die JSON-/Text-/ZIP-Berichterzeugung, ohne den Cerbo
zu kontaktieren.
