# CamperControl Design V2

Interaktiver Arbeitsstand für die nächste CamperControl-Oberfläche. Dieser Ordner ist eine Design- und Bedienreferenz und noch kein installierbares GX-, WASM- oder SYNC-Release.

## Verbindliche Gestaltungsbasis

- Die Home-Seite dieses Prototyps ist das interne Designsystem.
- Bestehende CamperControl-/SYNC-Funktionen und reale Kanalbezeichnungen bleiben die funktionale Quelle.
- Fremde Camper-Systeme werden nicht visuell kopiert. Aktuelle Store-Oberflächen dienen nur zur Kontrolle von Bedienmustern.
- WCS, alte CZone-, Dometic- und Firefly-Abbildungen sind ausdrücklich keine Designreferenzen.

## Aktueller Umfang

- Licht: sechs reale STAR-Power-Kreise, Szenen, getrennte Auswahl- und Schaltflächen, permanenter Dimmer für die gewählte dimmbare Zone und passive Transit-Darstellung ohne Hotspots.
- Symbole: eigene 24-x-24-Monoline-Familie `Rail Light` für Navigation, Innenraum, links, rechts, hinten, Tagfahrlicht und Warnlicht.
- Klima: Autoterm-Zeitlimit ist optional und standardmäßig eingeklappt.
- Energie: kombinierte Seite `12 V & 230 V` und zweite Seite `Quellen`.
- Home: `Solar gesamt` öffnet direkt `Energie > Quellen` und hebt die Solaraufteilung hervor.

## Dateien

- `campercontrol-v2-transit-horizon.html`: Inline-Fragment für die interaktive Designprüfung.
- `campercontrol-v2-transit-horizon-standalone.html`: direkt im Browser öffnende Fassung.
- `campercontrol-v2-light-modern-touch50.png`: geprüfte 800-x-480-Browserreferenz der Lichtseite.

## Datenhinweis

Die angezeigten Werte entsprechen dem während der Designprüfung gelesenen Node-RED-Snapshot und sind im HTML eingefroren. Das HTML behauptet deshalb keine Live-Verbindung. Die spätere QML-Umsetzung bindet dieselben Komponenten an `CamperBackendAdapter`.
