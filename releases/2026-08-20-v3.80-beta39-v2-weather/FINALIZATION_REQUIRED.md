# Finalisierung abgeschlossen

Dieses Release ist auf die dokumentierten Quellcommits und Venus OS
`v3.80~39` / Build `20260716174100` / ARMv7 eingefroren. GX, WASM, Node-RED,
Wetterdienst und Ford SYNC wurden aus ihren finalen Artefakten übernommen.

Quellpins:

- GUI: `251b7b47124bb474f61a8cdd5217bf0634a87d47`
- Node-RED/Cerbo: `fbf29b334c5c1fc5b05ebeb6f2ce76bc28e036b7`
- SYNC: `325d91084fe32e95b60672bff3e3b0f252e91a4f`

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
