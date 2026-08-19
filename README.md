# CamperControl releases

Versionierte, reproduzierbare Auslieferungen der CamperControl-Oberflächen.

Dieses Repository ergänzt die drei Quellcode-Repositories. Es enthält die tatsächlich gebauten Pakete, die zugehörigen Deployment- und Prüfwerkzeuge, Produktionsbilder, Designreferenzen und Touch-50-Screenshots. Passwörter, SSH-Schlüssel und gerätespezifische Zugangsdaten dürfen hier nicht abgelegt werden.

## Aktuelles Release

`releases/2026-08-19-v3.80-beta39-display-fit` ist das additive Patch-Release
für GX Touch 50, Remote Console/WASM, Ford SYNC und Node-RED. Es ergänzt den
weiterhin unveränderten Stand
`2026-08-19-v3.80-beta39-design-v1-v2` um 800 × 480 Full-Bleed, das transparente
Transit-/FORD-Raptor-Symbol, den oberen Schließen-/Zurück-Knopf und die aktuelle
Transport-/Orion-Härtung. V1 bleibt vollständig erreichbar. Vor einer
Installation immer zuerst das dortige `tools/verify-release.ps1` ausführen.

## Repositories der Quellen

- `camper-gui-v2`: angepasste Victron-GX- und WASM-Oberfläche
- `campercontrol-node-red`: Flow, Dashboard, Cerbo-Dienste und Tests
- `sync3-camper`: Ford-SYNC-QML-Anwendung

Jede Releasebeschreibung pinnt die genauen Quell-Commits. Große Binärdateien und Bilder werden mit Git LFS versioniert. Nach einem Clone müssen deshalb `git lfs install` und `git lfs pull` ausgeführt werden.

## Inhalt eines Releases

- `artifacts/`: unmittelbar installierbare GX-, WASM-, SYNC- und Node-RED-Pakete
- `assets/production/`: im Build verwendete Bilder
- `assets/design-source/`: eingefrorene Design- und Bildreferenzen
- `screenshots/`: geprüfte Referenzdarstellung
- `tools/`: exakt zum Release gehörende Deployment- und Prüfskripte
- `release.json`: Firmware-, Commit- und Buildzuordnung
- `checksums.sha256`: Integritätsprüfung der wichtigsten Dateien
