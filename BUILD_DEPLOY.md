# BUILD & DEPLOY — CamperControl-Gesamtrelease

> **Entwurf vom 20.08.2026 – kein freigegebenes Deployment.**
>
> Der aktuelle Arbeitskandidat liegt unter
> `releases/<release-id>`. Seit seinem letzten Freeze
> wurden GUI-, Node-RED-, Wetter-/Tide- und SYNC-Quellen weiterentwickelt. Seine
> derzeitigen Manifest- und Artefakthashes sind deshalb keine finalen Werte für
> den nächsten Rollout. Zusätzlich steht die erneute Live-Abnahme des zentralen
> D-Bus-Dienstes aus. Erst ein neu eingefrorener, vollständig verifizierter und
> live getesteter Stand darf mit `-Apply` installiert werden.

## Zweck dieses Repositorys

Dieses Repository baut nicht eigenständig alle Quellen. Es friert die bereits
getesteten Ergebnisse der drei Quell-Repositories zusammen mit exakt passenden
Installations-, Prüf- und Wartungswerkzeugen ein:

- `camper-gui-v2`: native GX- und WASM-Artefakte
- `campercontrol-node-red`: D-Bus-/Wetterdienst und Node-RED-Flow
- `sync3-camper`: Ford-SYNC-USB-ZIP
- `campercontrol-release`: Manifest, Checksummen, Deployment und Recovery

Die zentrale Installationsreihenfolge ist unveränderlich:

1. CamperControl-D-Bus-/Wetterdienst
2. Node-RED-Flow
3. native GX-Oberfläche
4. Remote-Console/WASM-Oberfläche
5. Ford SYNC separat per USB

Der Cerbo bleibt Eigentümer von Zustand, Wetter, Gezeiten, Schutzlogik und
Schaltvalidierung. GX, WASM und SYNC lesen denselben Vertrag und senden nur
kleine validierte Schaltabsichten.

## Aktuell bekannte Kompatibilitätsbasis

Die vorhandene Kompatibilitätsmatrix enthält genau diesen geprüften Eintrag:

| Eigenschaft | Wert |
|---|---|
| Venus OS | `v3.80~39` |
| Venus-Build | `20260716174100` |
| Architektur | `armv7l` |
| gui-v2-Paket | `1.3.14-r0` |
| Qt | `6.8.3` |
| gui-v2-Quellcommit der bisherigen Basis | `ee6a8f8897832d3e63ffbe98ffdd4389708dfc1e` |
| GX-SDK | `venus-scarthgap-x86_64-arm-cortexa8hf-neon-toolchain-v3.80~39.sh` |
| Emscripten | `3.1.56` |

Die laufenden Tide-/UI-Änderungen benötigen vor der Freigabe einen neuen
sauberen Quellcommit und neu gebaute Artefakte. Eine neue Venus-Firmware wird
nicht aus dieser Tabelle abgeleitet und nicht automatisch portiert.

## Voraussetzungen auf Windows

- PowerShell 7
- Git und Git LFS; nach einem Clone `git lfs install` und `git lfs pull`
- OpenSSH-Client mit `ssh` und `scp`
- Python mit PySide6 6.8.3 für die gui-v2-Vertragstests
- WSL mit Ubuntu 22.04 oder neuer
- das zur Matrix passende Venus-GX-SDK in der von `camper-gui-v2` erwarteten
  Toolchain-Umgebung
- Emscripten 3.1.56 für WASM
- die drei Quell-Repositories lokal und auf den freizugebenden Commits

Zugangsdaten, SSH-Schlüssel und Cerbo-Passwörter gehören nicht in Git, ZIP,
Manifest oder Wartungsbericht.

## Quell-Repositories bauen

Die detaillierten Befehle stehen jeweils in der `BUILD_DEPLOY.md` des
Quell-Repositories. Vor dem Freeze müssen alle drei Worktrees sauber sein und
ihre angezeigten Commits protokolliert werden:

```powershell
git -C ..\camper-gui-v2 status --short
git -C ..\camper-gui-v2 rev-parse HEAD
git -C ..\campercontrol-node-red status --short
git -C ..\campercontrol-node-red rev-parse HEAD
git -C ..\sync3-camper status --short
git -C ..\sync3-camper rev-parse HEAD
```

### Bekannten GX/WASM-Stand über das Wartungstool bauen

Das Wartungstool kann ausschließlich den in
`tools/compatibility-matrix.json` des Releases gepinnten gui-v2-Commit bauen.
Es führt zuerst einen read-only Kompatibilitätscheck des Cerbo aus, verlangt
einen sauberen, exakt passenden GUI-Worktree und installiert nichts:

```powershell
Set-Location .\releases\<release-id>
$workspace = (Resolve-Path ..\..\..).Path
$guiRepository = (Resolve-Path ..\..\..\camper-gui-v2).Path
$buildOutput = Join-Path $workspace 'build\campercontrol-v3.80-beta39'
.\tools\CamperControl-Maintenance.ps1 `
  -CerboHost 172.24.24.1 `
  -IdentityFile $env:USERPROFILE\.ssh\id_ed25519 `
  -Build `
  -GuiRepository $guiRepository `
  -BuildOutputDirectory $buildOutput
```

Der Ausgabeordner muss vorher fehlen. Bei Erfolg enthält er:

```text
camper-gui-v2-gx.tar.gz
camper-gui-v2-wasm.tar.gz
build-manifest.json
checksums.sha256
```

`build-manifest.json` enthält Quellcommit, Firmwarepins, Archivhashes sowie die
inneren GX-, JavaScript- und WASM-Hashes. Das Werkzeug führt die
V2-Panel-/VRM-Verträge und den echten 800 × 480-Smoke-Test vor
`scripts/build-gx.sh` und `scripts/build-wasm.sh` aus.

Dieser Buildweg bleibt absichtlich blockiert, solange der neue GUI-Quellstand
noch nicht als kompatibler Commit in der Matrix festgeschrieben ist.

## Release-Kandidat einfrieren

Der Kandidat enthält nach dem Quellbuild diese installierbaren Pfade:

```text
artifacts/cerbo-service/
artifacts/node-red/flows.json
artifacts/gx/camper-gui-v2-gx-v2-weather.tar.gz
artifacts/wasm/camper-gui-v2-wasm-v2-weather.tar.gz
artifacts/sync/campercontrol-sync-v3.12.0-v2-weather.zip
```

Beim Freeze werden ausschließlich tatsächlich gebaute Dateien übernommen.
Danach werden in `release.json` die drei Quellcommits, Archiv- und Innenhashes,
Größen, Dateizahlen, Node-Zahl, Testzahlen und der Freeze-Status aus den realen
Ausgaben aktualisiert. Werte aus einem älteren Kandidaten dürfen nicht kopiert
werden.

Zusätzlich müssen alle zum Release gehörenden, fest eingebauten Hash-, Pfad-
und Kompatibilitätspins aus denselben realen Ausgaben aktualisiert werden:

```text
tools/deploy-node-red.sh
tools/archive-node-red-context-tmp.sh
tools/deploy-gx.sh
tools/deploy-wasm.sh
tools/post-update-status.sh
tools/compatibility-matrix.json
tools/tests/test-release-tooling.ps1
```

Der aktuelle `verify-release.ps1` vergleicht nicht jeden Node-RED-Deploy-/
Cleanup- und Post-Update-Hardcode mit `release.json`. Bis dieser Vertrag im
Verifier vollständig geschlossen ist, gehört deshalb ein separater
zeilengenauer Pin-Abgleich zum Freeze-Gate.

Erst wenn Manifest und Werkzeuge konsistent sind, wird die vollständige
Checksummliste aus dem Releaseverzeichnis neu geschrieben:

```powershell
Set-Location .\releases\<release-id>
.\tools\write-final-checksums.ps1 -Replace
.\tools\verify-release.ps1
.\tools\tests\test-maintenance.ps1
.\tools\tests\test-release-tooling.ps1
```

`checksums.sha256` deckt jede Datei des Releaseverzeichnisses außer sich selbst
ab. Jede spätere Änderung erfordert eine bewusste neue Finalisierung und alle
drei Prüfungen erneut. Ein grüner Verifier ersetzt nicht die reale
GX-/WASM-/SYNC-Abnahme.

## Read-only Cerbo-Audit

Der Standardmodus des Wartungstools schreibt auf dem Cerbo nichts. Er erzeugt
lokal einen Text-, JSON- und ZIP-Bericht:

```powershell
Set-Location .\releases\<release-id>
$workspace = (Resolve-Path ..\..\..).Path
.\tools\CamperControl-Maintenance.ps1 `
  -CerboHost 172.24.24.1 `
  -IdentityFile $env:USERPROFILE\.ssh\id_ed25519 `
  -ReportDirectory (Join-Path $workspace 'build\campercontrol-audit')
```

Ohne Schlüssel kann `-Authentication Prompt` verwendet werden. Ein unbekannter
Hostschlüssel bleibt standardmäßig blockiert; `-AcceptNewHostKey` darf nur nach
bewusster Fingerprint-Prüfung gesetzt werden.

Der Audit prüft unter anderem Firmware/Build/Architektur, Root- und
Data-Speicher, RAM/Load, Node-RED-RSS/Flow/API, Kontextwachstum, Logs,
D-Bus/Wetter, MQTT-/VRM-Dienste, Orion, den bei 230 V erwartbar ausgeschalteten
Shelly, aktive GX/WASM-Hashes und Backup-Integrität. Das optionale Shelly-BLE-
Experiment wird nicht aktiviert.

## Deployment

Ein Deployment ist nur nach erfolgreichem Verifier, grünem read-only Audit,
neuem Preapply-Backup und expliziter Bestätigung erlaubt. **Für den aktuellen
Entwurf wird absichtlich kein ausführbarer Apply-Befehl angegeben.** Das
vorhandene `release.json` steht technisch noch auf `ready`/`frozen`; das
Wartungstool würde deshalb trotz der oben dokumentierten überholten Artefakte
einen Apply-Versuch zulassen.

Der endgültige Apply-Aufruf wird erst nach neuem Freeze, vollständigem
Pin-Abgleich, Live-Rollbacktest und bewusstem technischen Draft-Block/
Unblock in diese Anleitung aufgenommen.

`-Apply` führt folgende begrenzte Schritte aus:

1. Firmware-, Architektur-, Freeze- und Checksummenprüfung
2. Upload in den exakten Incoming-Pfad unter `/data/campercontrol/incoming`
3. atomare, checksumgeprüfte persistente Kopie unter
   `/data/campercontrol/releases/<release-id>`
4. genau ein komprimiertes Preapply-Backup unter
   `/data/campercontrol/backups`
5. frisches Entpacken beider GUI-Stages unter
   `/data/campercontrol/staging`
6. Dienst → Node-RED → GX → WASM
7. Zustands-/Hashprüfungen und Entfernen nur der exakt benannten Stages

Ein vorhandener beschädigter persistenter Releasebaum und ein vorhandener
Stage blockieren den Lauf; sie werden nicht automatisch überschrieben. Der
Schalter `-ForceFirmwareMismatch` ist kein regulärer Installationsweg und darf
nur nach einer gesonderten manuellen Portierungs- und Kompatibilitätsprüfung
verwendet werden.

Ford SYNC wird anschließend nach der separaten Anleitung per USB installiert.

## Live-Abnahme

Nach dem Deployment müssen mindestens diese Punkte bestätigt werden:

- `/service/campercontrol-dbus` ist stabil `up` und DeviceInstance `0` ist auf
  D-Bus erreichbar.
- `/State/Weather` ist gültiges JSON und höchstens 16 KiB groß. Für den
  nächsten Kandidaten gilt zusätzlich: fehlende Tide-Daten bleiben optional
  und gültige BSH-Daten erreichen alle Clients. Das bestehende eingefrorene
  Serviceartefakt besitzt diesen Tide-Vertrag noch nicht.
- Node-RED hat den eingefrorenen Flowhash und die erwartete Node-Zahl; die
  lokale `/camper/api/v2/state`-Antwort ist gültig.
- GX startet ohne QML-Fehler auf 800 × 480 und „System“ öffnet Victron.
- Remote Console verbindet lokal sowie über VRM/VRM Beta; Monitorbetrieb bleibt
  read-only.
- Direkte und Szenen-Starlink-Aus-Befehle aus einer geschützten
  Remote-Verbindung werden atomar abgelehnt, lokale Bedienung bleibt möglich.
- Favoriten, DWD-Wetter, BSH-Gezeiten, Lichtpositionen, Dimmer, Orion,
  INDEVOLT/Shelly, Klima und Wasser zeigen reale Werte.
- CPU, RAM, Root-/Data-Speicher, Logs und Node-RED-Kontext wachsen im
  Beobachtungszeitraum nicht ungebremst.

Erst danach werden `release.json` als deployed und die Dokumentation als final
markiert.

## Firmware-Update und Reinstall

Das Release wird nicht automatisch auf eine neue Firmware portiert. Der Ablauf
ist bewusst manuell:

1. Vor dem Update read-only Audit und Bericht sichern.
2. Prüfen, dass die persistente Releasekopie und mindestens ein gültiges,
   gehashtes Backup auf `/data` vorhanden sind.
3. Venus-Update manuell installieren.
4. Danach erneut read-only Audit ausführen.
5. Prüfen, ob `/data/rc.local` aktiv ist; `rc.local.disabled` blockiert den
   Reinstall.
6. Nur bei exakt bekannter Firmware/Architektur und nach Freigabe des neu
   eingefrorenen Pakets den dann dokumentierten Apply-Aufruf ausführen.
7. Dienst, Node-RED, GX und WASM erneut live abnehmen.

Auf dem Cerbo zeigt dieses Skript den reinen Status und verändert nichts:

```sh
/data/campercontrol/releases/<release-id>/tools/post-update-status.sh
```

Der explizite geräteseitige Reinstall wird normalerweise vom Windows-Tool
aufgerufen. Sein mutierender Direktaufruf wird in diesem nicht freigegebenen
Entwurf bewusst nicht zur Ausführung dokumentiert.

## Rollback und Aufräumen

- D-Bus-Dienst, Node-RED, GX und WASM besitzen jeweils einen begrenzten
  transaktionalen Fehlerpfad. Bei fehlgeschlagener Validierung wird der vorherige
  aktive Stand wiederhergestellt; ein Fehler darf nicht durch manuelles
  Weiterinstallieren übersprungen werden.
- Das Preapply-Archiv enthält ausschließlich die erwarteten persistenten
  Konfigurations-, Service-, Flow- und Kontextpfade. Eine manuelle
  Gesamtrestaurierung daraus ist kein automatisierter Standardbefehl und wird
  nur nach Prüfung des konkreten Archiv-Inhalts durchgeführt.
- Alte, vom Health-Report exakt benannte `gui-v2.pre-*`-Bäume werden nur mit
  vollständigem Literalpfad über `tools/archive-old-gui-tree.sh` archiviert.
- Verwaiste Node-RED-Context-`*.tmp`-Dateien werden nie automatisch entfernt.
  Nach installiertem timer-sicherem Flow kann das spezielle Archiv-/Cleanup-
  Werkzeug mit seiner langen Bestätigung verwendet werden; vorher nicht.
- Keine Anleitung in diesem Repository erlaubt Wildcard-Löschung eines
  Elternverzeichnisses, `/data`, `/service` oder `/opt/victronenergy`.

## Finaler Dokumentationsstand

Vor der nächsten Freigabe sind außerdem diese aktuell nachgewiesenen Punkte zu
schließen:

- Der eingefrorene alte Releasekandidat übernimmt `tides` noch nicht. Der
  aktuelle Node-RED-Commit `6cb9232ad7c91117c735ef80d14b24753b5e891c`
  transportiert das Feld zwar bis `state.weather`, erzwingt aber noch nicht
  exakt `source: BSH` und akzeptiert `nextHigh: null` beziehungsweise
  `nextLow: null` noch nicht. `heightM: null` funktioniert bereits, besitzt
  aber noch keinen positiven Vertragstest. Der Commit ist außerdem noch nicht
  in einen neuen, verifizierten Gesamt-Release eingefroren.
- Der SYNC-Installer sichert Root/Statusleiste unter `camper-complete` mit
  `.transaction`-Namen, während sein Restore-Skript `camper-statusbar` und
  `.before`-Namen erwartet. Ein vollständiger Ford-QML-Rollback ist so nicht
  möglich.
- Im vorhandenen Kandidaten nennt `artifacts.cerboService.sourceCommit` noch
  `458921008943f9d5d426c35b16f62a09104fdb0c`. Die fünf eingefrorenen
  Service-Dateien entsprechen dagegen bytegenau dem späteren Commit
  `2c47cc527884c3203a38466ca4af76b42722b810`; der Top-Level-Quellpin nennt
  ebenfalls diesen späteren Commit. Der Verifier prüft diese
  Service-Provenienz derzeit nicht.
- Der aktualisierte in-place-runit-Installations- und Rollbackpfad benötigt
  noch eine erfolgreiche Live-Installation sowie einen geprüften Fehlerfall.

Nach erfolgreichem Live-Rollout werden in allen vier `BUILD_DEPLOY.md` die
wirklich ausgelieferten Commits, Artefaktpfade und SHA-256-Werte abgeglichen.
Bis dahin bleibt dieses Dokument ausdrücklich ein Entwurf und enthält bewusst
keine als final ausgegebenen Hashwerte des überholten Kandidaten.

