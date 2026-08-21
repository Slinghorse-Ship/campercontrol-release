# Shelly 1PM Gen4 über BLE – experimentelle Option

Stand: 2026-08-19. Diese Notiz beschreibt eine mögliche Diagnose- und spätere
Fallback-Verbindung. Sie aktiviert weder Bluetooth-RPC noch Pairing und ändert
keinen CamperControl-Flow oder Cerbo-Dienst.

## Ergebnis in einem Satz

BLE-RPC ist technisch möglich, aber kein Ersatz für den vorhandenen
WLAN/Victron-Pfad und insbesondere kein Weg, den stromlosen Shelly zu starten.
Für das Fahrzeug bleibt WLAN über den nativen Venus-Dienst der Primärpfad; BLE
kann erst nach einem Test am eingeschalteten Gerät als optionale Diagnose oder
als begrenzter Kommunikations-Fallback bewertet werden.

## Tatsächlich verbautes Gerät

- Gerät: Shelly 1PM Gen4
- Modell: `S4SW-001P16EU`
- Bluetooth-ID laut Hersteller: `0x1029`
- Kanal: `switch:0`
- zuletzt dokumentierte IP: `172.24.24.159`
- WLAN: `venus-einstein-62e`
- Firmware laut Geräteansicht:
  `20260710-101121/2.0.0-g87fbfa4`
- zuletzt in der Geräteansicht gesehen: `2026-08-18 17:08:24`

Shelly nennt für dieses Modell Bluetooth 5.0, maximal etwa 10 m Reichweite in
Gebäuden und 30 m im Freien; die real erreichbare Distanz hängt ausdrücklich
von den örtlichen Bedingungen ab. Quelle:
[Shelly 1PM Gen4 Knowledge Base](https://kb.shelly.cloud/knowledge-base/shelly-1pm-gen4).

## Vorhandener CamperControl-Pfad

Der aktuelle Flow hat keine fest codierte Shelly-IP und keinen direkten
Shelly-HTTP-RPC-Aufruf. Venus OS veröffentlicht das Gerät als
`com.victronenergy.acload/50` (`S1PMG4 - channel 0`).

Gelesen werden:

- `/Connected`
- `/SwitchableOutput/0/State`
- `/SwitchableOutput/0/Status`
- `/Ac/L1/Voltage`
- `/Ac/L1/Current`
- `/Ac/L1/Power`
- `/Ac/L1/Energy/Forward`

Geschaltet wird ausschließlich
`com.victronenergy.acload/50 /SwitchableOutput/0/State`. Die verbindliche
Umsetzung steht in `scripts/build-flow.js` bei `shelly_grid_state_out`; die
Vertragsprüfungen stehen in `tests/validate-flow.js` und
`tests/runtime-readonly.js`.

Damit bleiben Node-RED, GX und Browser auf demselben Victron-D-Bus-Zustand. Ein
separater BLE-Zweig darf diesen Zustand nicht parallel überschreiben oder einen
fehlenden Dienst als `AUS` interpretieren.

## Harte Leistungsgrenze

Der verbaute Shelly wird nur versorgt, wenn die vorgeschaltete 230-V-Versorgung
bereits vorhanden ist. Bei ausgeschaltetem 230 V ist daher Folgendes erwartet:

- kein WLAN,
- kein Venus-Dienst `com.victronenergy.acload/50`,
- kein BLE-Advertisement,
- keine GATT-Verbindung und kein BLE-RPC.

BLE kann den Shelly deshalb nicht aus dem stromlosen Zustand einschalten. Das
Repository belegt nicht, welches konkrete, dauerhaft versorgte Hardwareelement
den Shelly elektrisch speist. CamperControl kann den MultiPlus separat schalten,
aber aus dem Softwarevertrag folgt keine bestätigte Verdrahtung vom MultiPlus
zum Shelly. Diese Zuordnung muss am Schaltplan oder am Fahrzeug verifiziert
werden und wird hier nicht erfunden.

`acload/50` fehlt bei ausgeschaltetem 230 V somit erwartbar. Der korrekte Zustand
ist `nicht verfügbar/stromlos`, nicht `Relais AUS` und nicht automatisch
`WLAN-Fehler`. Nach Wiederkehr der Versorgung muss auf die erneute Venus-
Erkennung gewartet werden. Ein alter Schaltwunsch darf beim Wiederverbinden nicht
ungeprüft erneut gesendet werden. Ebenfalls noch unbekannt ist die reale
`switch:0.initial_state`-Konfiguration; sie ist bei eingeschaltetem Gerät über
`Switch.GetConfig` read-only zu erfassen.

## BLE-RPC ist nicht BTHome

BTHome/Advertisements eignen sich für passive Sensor- und Präsenzdaten. Ein
Advertisement ist jedoch kein bidirektionaler JSON-RPC-Kanal und kann keinen
`Switch.Set`-Befehl transportieren. Für dieses Relais ist die relevante Option
Shellys eigener RPC-Dienst über eine verschlüsselte GATT-Verbindung.

Shelly Gen2+ verwendet JSON-RPC für Status und Befehle. Für Kanal 0 sind die
offiziellen Methoden `Switch.GetStatus` und `Switch.Set` mit
`{"id":0,"on":true|false}`. `Switch.GetStatus` liefert unter anderem Ausgang,
Leistung, Spannung, Strom, Frequenz, Energie und Temperatur. Quellen:
[Shelly RPC Protocol](https://shelly-api-docs.shelly.cloud/gen2/General/RPCProtocol/)
und [Switch component](https://shelly-api-docs.shelly.cloud/gen2/ComponentsAndServices/Switch/).

Shelly veröffentlicht außerdem ein offizielles Apache-2.0-Beispiel für seinen
GATT-RPC-Dienst. Es verwendet Bleak und die vier Shelly-RPC-GATT-
Characteristics; das Beispiel ist ein Referenzwerkzeug, keine Aussage über
Produktionsreife auf Venus OS:
[ALLTERCO shelly-bt-rpc.py](https://github.com/ALLTERCO/Utilities/blob/master/shelly-bluetooth-rpc/shelly-bt-rpc.py).

## Firmware 2.0 und Bonding

Die installierte Firmware ist `2.0.0`. Seit Firmware 2.0 verlangt Shelly für
BLE-RPC außerhalb des initialen Provisionierungsfensters:

1. `BLE.rpc.enable=true`,
2. ein explizites `BLE.StartPairing`-Fenster,
3. GATT-Pairing und dauerhaftes Bonding des Clients.

Die Verbindung verwendet GATT-Verschlüsselung und -Authentisierung; Shelly
beschreibt `Just Works` und bis zu 20 gespeicherte Bonds. Das Aktivieren von RPC
kann einen Neustart verlangen. Quelle:
[Shelly BLE Security and Bonding](https://shelly-api-docs.shelly.cloud/gen2/ComponentsAndServices/BLE/).

Das sind Konfigurationsmutationen am Shelly und am BlueZ-Bond-Store. Sie wurden
bewusst nicht durchgeführt.

## Cerbo-Livebefund

- BlueZ `5.72`
- aktiver Adapter: `hci1`, TP-Link UB500,
  `B8:FB:B3:FA:A2:F8`
- Adapter eingeschaltet; LE, Secure Connections und Privacy vorhanden
- `hci0` ist durch den vorhandenen Disable-Watcher absichtlich deaktiviert
- `hci1 Pairable=no`
- beim read-only Check keine bekannten Shelly-Geräte sichtbar; es wurde kein
  Scan gestartet, weil der Shelly vermutlich stromlos war

Für ein späteres Bonding braucht BlueZ zusätzlich einen Pairing-Agenten und
persistente Schlüssel. `Pairable=no` allein beweist weder, dass ausgehendes
Client-Pairing funktioniert, noch dass die Schlüssel einen Cerbo-Neustart
überleben.

Der Ruuvi FB31 benutzt bereits Bluetooth und erscheint in Venus als
`com.victronenergy.temperature/24`. Dauerhafte Scans und häufige GATT-
Verbindungen über denselben Adapter können dessen Advertisement-Empfang
beeinflussen. Ein möglicher BLE-Zweig muss deshalb kurze, serialisierte
Transaktionen, Backoff und Messungen der Ruuvi-Ausfallrate verwenden. Ein
permanenter Scan ist nicht vorgesehen.

## Empfehlung

1. **Produktion:** WLAN und der native Venus-Dienst bleiben primär.
2. **BLE jetzt:** nur experimentelle Diagnose bei nachweislich versorgtem
   Shelly; kein automatischer Fallback und kein Schalten.
3. **Späterer Status-Fallback:** erst nach bestandenem Powered-Test darf BLE
   read-only `Switch.GetStatus` liefern. Der Status muss als Quelle `ble`
   markiert werden und darf den D-Bus-Zustand nicht überschreiben.
4. **Späteres Schalten:** nur mit eigener, standardmäßig deaktivierter Option,
   genau einem `Switch.Set`, anschließender `Switch.GetStatus`-Bestätigung,
   Timeout und ohne automatisches Wiederholen nach Spannungswiederkehr.

BLE hat gegenüber WLAN die geringere Hersteller-Reichweite und teilt sich den
2,4-GHz-Bereich sowie einen Cerbo-Adapter mit anderen Sensoren. Es ist deshalb
kein robusterer genereller Primärpfad. Es kann lediglich helfen, wenn der
Shelly versorgt ist, WLAN/Venus aber vorübergehend nicht funktioniert.

## Minimaler Powered-PoC (noch nicht ausgeführt)

1. 230 V bewusst einschalten und am Shelly Spannungsversorgung bestätigen.
2. `python3 tools/shelly_ble_probe.py` ausführen. Das liest nur die bereits von
   BlueZ bekannten Objekte und scannt nicht.
3. Falls nötig, einmalig und beaufsichtigt maximal zehn Sekunden scannen:
   `python3 tools/shelly_ble_probe.py --experimental-enable --scan-seconds 10`.
   Der Probe verbindet, paart und schaltet weiterhin nicht.
4. Über den bestehenden WLAN-Pfad read-only `BLE.GetConfig`,
   `Switch.GetConfig`, `Shelly.GetDeviceInfo` und `Switch.GetStatus` sichern.
5. Nur nach separater Freigabe `rpc.enable` aktivieren und ein kurzes
   `BLE.StartPairing`-Fenster öffnen; Bond-Recovery über einen Cerbo-Neustart
   testen. Das ist ausdrücklich nicht Teil des Probe-Tools.
6. Mit dem offiziellen Shelly/Bleak-Referenzclient zunächst nur
   `Shelly.GetDeviceInfo` und `Switch.GetStatus` lesen.
7. WLAN bei weiter versorgtem Shelly kontrolliert unterbrechen und BLE-Status,
   Reichweite, Latenz sowie Ruuvi-Empfang messen.
8. Erst danach über einen separaten Testplan genau einen `Switch.Set`-Befehl
   erwägen. Der stromlose Fall bleibt unabhängig davon unlösbar.

## Probe-Tool und Abhängigkeiten

`tools/shelly_ble_probe.py` verwendet nur das auf Venus übliche
`dbus-python`, liest standardmäßig BlueZ ObjectManager und installiert nichts.
Es implementiert absichtlich weder Pairing noch GATT-RPC noch Relaisbefehle.
Ein aktiver Scan benötigt zwei explizite Parameter und ist auf 30 Sekunden
begrenzt. Das Tool meldet lediglich, ob `bleak` bereits vorhanden ist; Bleak
wird nicht vorausgesetzt oder automatisch installiert.

Die Offline-Vertragstests liegen in `tests/test-shelly-ble-probe.py`.
