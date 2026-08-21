# CamperControl releases

Versionierte, reproduzierbare Auslieferungen der CamperControl-Oberflächen.

Dieses Repository ergänzt die drei Quellcode-Repositories. Es enthält die tatsächlich gebauten Pakete, die zugehörigen Deployment- und Prüfwerkzeuge, Produktionsbilder, Designreferenzen und Touch-50-Screenshots. Passwörter, SSH-Schlüssel und gerätespezifische Zugangsdaten dürfen hier nicht abgelegt werden.

## Aktuelles Release

Das aktuelle, lokal finalisierte und noch nicht deployte Paket ist
[`releases/2026-08-20-v3.80-beta39-v2-weather/`](releases/2026-08-20-v3.80-beta39-v2-weather/).
Es enthält die V2-Oberfläche für GX Touch 50 und Remote Console/WASM, den
zugehörigen Ford-SYNC-Stand, den Node-RED-Flow sowie den zentralen Cerbo-Dienst
für DWD-Wetter und echte BSH-Nordsee-Tidedaten.

Die installierbaren Pakete liegen unter
[`artifacts/`](releases/2026-08-20-v3.80-beta39-v2-weather/artifacts/), die
releasegebundenen Prüf- und Deploymentskripte unter
[`tools/`](releases/2026-08-20-v3.80-beta39-v2-weather/tools/) und die exakt zum
eingefrorenen GUI-Quellcommit gehörenden Bilder unter
[`assets/production/`](releases/2026-08-20-v3.80-beta39-v2-weather/assets/production/).
Vor einer Installation immer zuerst
[`tools/verify-release.ps1`](releases/2026-08-20-v3.80-beta39-v2-weather/tools/verify-release.ps1)
ausführen. Ein Deployment erfolgt erst nach erfolgreicher lokaler Prüfung und
ausdrücklicher Freigabe.

## Repositories der Quellen

- `camper-gui-v2`: angepasste Victron-GX- und WASM-Oberfläche
- `campercontrol-node-red`: Flow, Dashboard, Cerbo-Dienste und Tests
- `sync3-camper`: Ford-SYNC-QML-Anwendung

Jede Releasebeschreibung pinnt die genauen Quell-Commits. Große Binärdateien und Bilder werden mit Git LFS versioniert. Nach einem Clone müssen deshalb `git lfs install` und `git lfs pull` ausgeführt werden.

## Inhalt eines Releases

- `releases/<version>/artifacts/`: unmittelbar installierbare GX-, WASM-,
  SYNC-, Node-RED- und Cerbo-Pakete
- `releases/<version>/assets/production/`: im Build verwendete Bilder
- `releases/<version>/assets/design-source/`: optional eingefrorene Design- und
  Bildreferenzen
- `releases/<version>/screenshots/`: geprüfte Referenzdarstellung
- `releases/<version>/tools/`: exakt zum Release gehörende Deployment- und
  Prüfskripte
- `releases/<version>/release.json`: Firmware-, Commit- und Buildzuordnung
- `releases/<version>/checksums.sha256`: Integritätsprüfung der Release-Dateien

## Lizenz

Originale CamperControl-Releasewerkzeuge und Dokumentation stehen unter der
[PolyForm Noncommercial License 1.0.0](LICENSE-CAMPERCONTROL.md). Kommerzielle
Nutzung ist nicht erlaubt. Dieses Repository verteilt zugleich Bestandteile
mit anderen Rechten, insbesondere Victron Energy `gui-v2`; deshalb sind die
Zuordnung in [NOTICE.md](NOTICE.md) und das jeweilige `LICENSES/`-Verzeichnis
eines Releases verbindlicher Bestandteil der Auslieferung.

Aus Lucide abgeleitete Navigationssymbole behalten ihre
[ISC-/MIT-Lizenz](LICENSE-LUCIDE.txt); der Lizenztext wird ebenfalls in jedes
Release aufgenommen.

DWD- und BSH-Daten stehen unabhängig davon unter CC BY 4.0. Die erforderlichen
Quellen- und Verarbeitungshinweise enthält [DATA-LICENSES.md](DATA-LICENSES.md).
