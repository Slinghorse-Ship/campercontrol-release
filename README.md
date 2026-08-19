# CamperControl releases

Versionierte, reproduzierbare Auslieferungen der CamperControl-Oberflächen.

Dieses Repository ergänzt die drei Quellcode-Repositories. Es enthält die tatsächlich gebauten Pakete, die zugehörigen Deployment- und Prüfwerkzeuge, Produktionsbilder, Designreferenzen und Touch-50-Screenshots. Passwörter, SSH-Schlüssel und gerätespezifische Zugangsdaten dürfen hier nicht abgelegt werden.

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

