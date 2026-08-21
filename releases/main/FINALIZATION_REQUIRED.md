# Finalisierung abgeschlossen

Dieses Release ist auf die dokumentierten Quellcommits und Venus OS
`v3.80~39` / Build `20260716174100` / ARMv7 eingefroren. GX, WASM, Node-RED,
Wetterdienst und Ford SYNC wurden aus ihren finalen Artefakten übernommen.

Quellpins:

- GUI-Build: `bc7ff198fe5147b6e7480f7fcda929c54862365c`
- Node-RED/Cerbo: `9927b26139d2f16c32f7e333b2f92c82c51bc47e`
- SYNC: `fb52cac2bc7ccb0ebac9084577604709163f7e72`

Die Cerbo-Inventarliste umfasst genau 19 Dateien mit Ziel, Modus, Bytezahl und
SHA-256. `device-http-bounded.py` ist enthalten; der einzige Sonderpfad ist
`starlink-read-status.sh` nach `/data/campercontrol/starlink/read-status.sh`.
Der Installer hält beide runit-Serviceverzeichnisse stabil und rollt Dateien,
Links, Startzeilen, Sudoers und Servicezustände gemeinsam zurück. Der gesamte
Reinstall erzeugt genau ein Pre-Apply-Backup.

`checksums.sha256` deckt jede Release-Datei ab. `verify-release.ps1` prüft vor
dem Deployment zusätzlich Archivpfade, Dateizahlen, V2-only-Vertrag,
Node-RED-Ressourcengrenzen, Transit-Assets und die Firmware-Pins. Eine spätere
Firmware darf nur nach dem manuellen Kompatibilitätsaudit erneut installiert
werden. Das Manifest steht weiterhin auf `deployed: false`; diese
Finalisierung hat weder den Cerbo kontaktiert noch ein Zielsystem verändert.

