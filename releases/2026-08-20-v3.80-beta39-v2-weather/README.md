# CamperControl V2 Weather — Venus OS v3.80~39

V2-only Release für GX Touch 50, Remote Console/WASM, Node-RED und Ford SYNC.
Die tägliche Oberfläche enthält ausschließlich Design V2. Links öffnet eine
unsichtbare Randgeste die vier Cerbo-Favoriten; rechts öffnet eine unsichtbare
Randgeste DWD-Wetter mit 24-Stunden-Kurve und sechs Tagen. Es gibt weder Griff
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
5. Zuerst startet der zentrale Wetter-/D-Bus-Dienst, danach folgen der
   validierte Node-RED-Flow, GX und WASM.
6. Jeder alte aktive GUI-Baum wird exakt als `gui-v2.pre-*` umbenannt. Vor
   seiner gezielten Löschung entsteht auf `/data/campercontrol/backups` ein
   gzip-geprüftes Archiv mit SHA-256. Wildcard- oder Elternverzeichnis-Löschung
   ist nicht enthalten.
7. Die beiden exakt benannten Entpack-Stages werden nach vollständigem Erfolg
   wieder entfernt; die gehashten Releasearchive auf `/data` bleiben für das
   nächste Firmware-Update erhalten.

Die abgeschlossene Finalisierung ist in `FINALIZATION_REQUIRED.md`
dokumentiert. `checksums.sha256` wird aus diesem Verzeichnis neu erzeugt; die
Werkzeuge blockieren jede Abweichung vor dem Deployment.
