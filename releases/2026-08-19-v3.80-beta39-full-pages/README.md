# 2026-08-19 – Venus OS v3.80 beta 39

Vollständige CamperControl-Auslieferung für Cerbo GX, GX Touch 50, Remote Console/WASM, Node-RED und Ford SYNC.

## Prüfung

- offizieller GX-Build erfolgreich
- offizieller WASM-Build erfolgreich
- native GX-Oberfläche auf dem Cerbo gestartet
- Remote Console bei 800 × 480 geladen
- QML-Touch-Smoke-Test einschließlich aller Detailseiten erfolgreich
- Node-RED: 358 Nodes, 1.267 Assertions, 0 Fehler

Vor einer Installation zuerst aus diesem Verzeichnis ausführen:

```powershell
./tools/verify-release.ps1
```

Die beiden Deployment-Skripte sind die unveränderten, release-spezifischen Skripte der geprüften Installation. Sie prüfen Dateizahl und innere Build-Prüfsumme und führen bei einem Fehler eine Rückrolle aus. Die Installation verändert `/opt/victronenergy/gui-v2` beziehungsweise `/var/www/venus/gui-v2`; deshalb darf sie nur bewusst auf dem vorgesehenen Cerbo ausgeführt werden.

Das Repository enthält keine Zugangsdaten. SSH-Authentifizierung muss außerhalb des Repositories bereitgestellt werden.

