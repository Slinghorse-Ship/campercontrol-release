# Finalisierung abgeschlossen

Dieses Release ist auf die dokumentierten Quellcommits und Venus OS
`v3.80~39` / Build `20260716174100` / ARMv7 eingefroren. GX, WASM, Node-RED,
Wetterdienst und Ford SYNC wurden aus ihren finalen Artefakten übernommen.

Quellpins:

- GUI-Build: `9e5a5282162b590b1e446958d97bf268915b3c23`
- Node-RED/Cerbo: `8805a01e5068bea46e3b4138039c9e260b6b1051`
- SYNC: `8819d7378ed219836116574bbec3b5cfe31df01a`

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
