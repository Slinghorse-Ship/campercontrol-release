# CamperControl V2 Weather — Venus OS v3.80~39

V2-only Release für GX Touch 50, Remote Console/WASM, Node-RED und Ford SYNC.
Die tägliche Oberfläche enthält ausschließlich Design V2. Links öffnet eine
unsichtbare Randgeste die vier Cerbo-Favoriten; rechts öffnet eine unsichtbare
Randgeste DWD-Wetter mit 24-Stunden-Kurve, BSH-Tidekurve und sechs Tagen. Es gibt weder Griff
noch sichtbaren Randindikator. Die originale Victron-Systemansicht bleibt über
„System“ erreichbar.

## Daten- und Lastmodell

Nur der Cerbo lädt und normalisiert Wetter. Verwendet wird die bereits vom DWD
aufbereitete MOSMIX_L-Stationsprognose; auf dem Cerbo läuft kein Wettermodell.
GX, WASM und SYNC lesen den kompakten Zustand über
`com.victronenergy.campercontrol/0` und `/State/Weather`. Der Cache liegt in
`/data/campercontrol/cache/weather-v1.json`; Stationsdaten liegen in
`/data/campercontrol/cache/mosmix-stations-v1.cfg`. GPS wird nicht in den Cache
geschrieben. Clients senden nur validierte, minimale Schaltabsichten; im
VRM-Monitor-Modus bleiben Schalt- und Favoritenänderungen gesperrt.

Der Wetterpayload ist auf die UI begrenzt (48 Stunden im Backend, davon 24 in
der Kurve, plus sechs Tage), wird nur bei Änderung auf D-Bus gesetzt und bleibt
bei Netzfehlern aus dem Cache lesbar. Das vermeidet Browser-HTTP, parallele
Downloads und unnötige CPU-/RAM-Last.

## Eingefrorene Quellen und Artefakte

- gui-v2 GX/WASM: `251b7b47124bb474f61a8cdd5217bf0634a87d47`
- Node-RED und Cerbo-Dienste: `fbf29b334c5c1fc5b05ebeb6f2ce76bc28e036b7`
- Ford SYNC: `325d91084fe32e95b60672bff3e3b0f252e91a4f`

Der Flow umfasst 358 Nodes und exakt 691.785 Bytes. Das Cerbo-Paket enthält
genau 19 manifestierte Dateien. Darin sind beide runit-`run`-Dateien,
`device-http-bounded.py`, WLAN-/Privileg-Helfer und der Starlink-Statusleser
enthalten. Nur der Starlink-Statusleser besitzt eine abweichende Zielabbildung:
`starlink-read-status.sh` wird als
`/data/campercontrol/starlink/read-status.sh` installiert. Alle übrigen
Quelldateien landen unter `/data/campercontrol/service`; die Sudoers-Datei wird
zusätzlich mit Modus 0440 nach `/etc/sudoers.d/campercontrol` validiert.

## Speicher- und Stabilitätsprüfung

`tools/campercontrol-health-readonly.sh` misst mit begrenzten, read-only
Zugriffen:

- Root-/Data-Belegung, Load Average und `MemAvailable`,
- Node-RED-RSS und API/Flow-Zustand,
- Größen von `/var/log`, Node-RED-Logs, Context, Release-Store, Incoming,
  Staging und CamperControl-Daten,
- Anzahl/Bytes verwaister Context-`*.tmp`-Dateien,
- Anzahl/Größe alter `gui-v2.pre-*`, Rollback-, Failed- und Candidate-Bäume,
- DWD-D-Bus-Status sowie Wetter-/Stationscache-Größen,
- aktive GX/WASM-Hashes und verifizierte Backups.

Das Healthskript ist ein manueller Momentcheck und wird nicht als Polling-Dienst
installiert. Es wird bewusst kein teures `du /` ausgeführt. Der frühere
Node-RED-OOM-Pfad durch persistierte JavaScript-Timer ist im eingefrorenen Flow
entfernt und durch Vertragsprüfungen abgesichert. Das optionale Cleanup
archiviert zuerst den gesamten Context,
stoppt Node-RED und löscht danach ausschließlich die zuvor eingefrorene Liste
von `*.tmp`-Dateien. Es läuft nie automatisch.

## Update und Wiederherstellung

1. Read-only Audit mit `CamperControl-Maintenance.ps1` ausführen.
2. Firmware manuell installieren.
3. `post-update-status.sh` prüfen. Unbekannte Version, Build oder Architektur
   blockiert die Wiederherstellung.
4. Erst mit expliziter Bestätigung `reinstall-after-update.sh` starten.
5. Zuerst starten der zentrale Wetter-/D-Bus-Dienst und der gebundene lokale
   WLAN-HTTP-Dienst, danach folgen der validierte Node-RED-Flow, GX und WASM.
6. Jeder alte aktive GUI-Baum wird exakt als `gui-v2.pre-*` umbenannt. Vor
   seiner gezielten Löschung entsteht auf `/data/campercontrol/backups` ein
   gzip-geprüftes Archiv mit SHA-256. Wildcard- oder Elternverzeichnis-Löschung
   ist nicht enthalten.
7. Die runit-Serviceverzeichnisse bleiben bei Updates bestehen; ausgetauscht
   wird jeweils nur die `run`-Datei. Ein Fehlschlag stellt alle 19 Dateien,
   beide Links, beide Startzeilen, Sudoers und die vorherigen Servicezustände
   aus der transaktionalen Rollback-Kopie wieder her.
8. Die beiden exakt benannten Entpack-Stages werden nach vollständigem Erfolg
   wieder entfernt; die gehashten Releasearchive auf `/data` bleiben für das
   nächste Firmware-Update erhalten.

Die abgeschlossene Finalisierung ist in `FINALIZATION_REQUIRED.md`
dokumentiert. `checksums.sha256` wird aus diesem Verzeichnis neu erzeugt; die
Werkzeuge blockieren jede Abweichung vor dem Deployment. Pro vollständigem
Reinstall wird genau ein gehashtes Pre-Apply-Backup erzeugt. Dieses Release ist
lokal finalisiert, aber laut Manifest noch nicht deployed.
