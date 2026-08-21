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

## Deployment-ready Checklist

- Artefaktquelle: `releases/main/artifacts/{gx,wasm,node-red,sync}`
- Metadaten: `releases/main/release.json` (Hashes, Dateigrößen, Source-Commits)
- Checksummen: `releases/main/checksums.sha256` (inkl. neuer Sync-`3.12.1`-ZIP)
- Source-Commits konsistent:
  - `camper-gui-v2` → `bc7ff198fe5147b6e7480f7fcda929c54862365c`
  - `campercontrol-node-red` → `9927b26139d2f16c32f7e333b2f92c82c51bc47e`
  - `sync3-camper` → `fb52cac2bc7ccb0ebac9084577604709163f7e72`
- Release-Manifest ist auf:
  - `status: ready`
  - `deployed: false`
  - `artifactFreeze.status: frozen`
- Branch-Sync-Status: `releases/main` auf `origin/main` clean (`git status` leer)

