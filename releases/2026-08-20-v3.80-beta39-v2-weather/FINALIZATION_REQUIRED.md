# Finalisierung abgeschlossen

Dieses Release ist auf die dokumentierten Quellcommits und Venus OS
`v3.80~39` / Build `20260716174100` / ARMv7 eingefroren. GX, WASM, Node-RED,
Wetterdienst und Ford SYNC wurden aus ihren finalen Artefakten übernommen.

`checksums.sha256` deckt jede Release-Datei ab. `verify-release.ps1` prüft vor
dem Deployment zusätzlich Archivpfade, Dateizahlen, V2-only-Vertrag,
Node-RED-Ressourcengrenzen, Transit-Assets und die Firmware-Pins. Eine spätere
Firmware darf nur nach dem manuellen Kompatibilitätsaudit erneut installiert
werden.
