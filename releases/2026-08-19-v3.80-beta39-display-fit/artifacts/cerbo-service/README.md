# CamperControl in gui-v2 Remote Console / VRM

## Ursache des bisherigen Verbindungsfehlers

`CamperNodeRedAdapter.qml` hat im WASM-Build die lokale HTTP-API von Node-RED
verwendet. Das lokale `wasm/index.html` leitete daraus Port 1880 oder 1881 am
Hostnamen der geladenen Seite ab. VRM verwendet dieses `index.html` jedoch
nicht und ein Browser am VRM-Origin kann die lokale Cerbo-API grundsätzlich
nicht erreichen. Eine Freigabe von Port 1880 ins Internet ist ausdrücklich
nicht Teil der Lösung.

## Transportvertrag

Der Dienst `com.victronenergy.campercontrol` (DeviceInstance `0`) liest lokal
`http://127.0.0.1:1880/camper/api/v2/state` und stellt ausschließlich die von
der QML-Oberfläche verwendeten Abschnitte bereit:

- `/State/Ui`
- `/State/Energy`
- `/State/Water`
- `/State/Climate`
- `/State/Lights`
- `/State/Vehicle`
- `/State/Power`

Jeder Wert ist ein eigenständiges, kompaktes JSON-Objekt. Zeitstempel und
Diagnosefelder, die bei jedem Zyklus wechseln, werden entfernt. Ein Fragment
wird nur bei einer inhaltlichen Änderung erneut auf D-Bus geschrieben. Damit
überträgt die vorhandene FlashMQ-D-Bus-Brücke keine vollständigen 30-kB-
Snapshots im Sekundentakt.

`/Command` ist schreibbar und übernimmt dasselbe validierte Befehlsobjekt wie
`POST /camper/api/v2/command`. Antworten erscheinen unter
`/LastCommandResult`. Im VRM-Modus `Nur Lesen` deaktiviert der QML-Adapter den
Schreibpfad; erst `Full` erlaubt W-Topics. Der Dienst selbst besitzt keine
Hardwarelogik und erfindet keine Gerätepfade.

## Installation auf Venus OS

Die vier Dateien aus `cerbo-service/` werden unter
`/data/campercontrol/service/` abgelegt. Danach:

```sh
/data/campercontrol/service/install-campercontrol-dbus.sh
svstat /service/campercontrol-dbus
dbus -y com.victronenergy.campercontrol /Status/ApiConnected GetValue
dbus -y com.victronenergy.campercontrol /State/Ui GetValue
```

Der Installer fügt ausschließlich den idempotenten Ensure-Aufruf vor dem
vorhandenen `exit 0` in `/data/rc.local` ein. Eine vorhandene Datei wird einmal
nach `/data/rc.local.before-camper-dbus` gesichert.

## Rollback

```sh
svc -d /service/campercontrol-dbus
rm /service/campercontrol-dbus
```

Danach wird die einzelne Zeile
`/data/campercontrol/service/ensure-campercontrol-dbus.sh` aus `/data/rc.local`
entfernt. Die Dateien in `/data/campercontrol/service/` können für eine spätere
erneute Aktivierung liegen bleiben.
