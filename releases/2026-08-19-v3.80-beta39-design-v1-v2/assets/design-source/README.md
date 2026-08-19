# CamperControl Design V2

Interaktiver Arbeitsstand für die nächste CamperControl-Oberfläche. Dieser Ordner ist eine Design- und Bedienreferenz und noch kein installierbares GX-, WASM- oder SYNC-Release.

## Verbindliche Gestaltungsbasis

- Die Home-Seite dieses Prototyps ist das interne Designsystem.
- Bestehende CamperControl-/SYNC-Funktionen und reale Kanalbezeichnungen bleiben die funktionale Quelle.
- Fremde Camper-Systeme werden nicht visuell kopiert. Aktuelle Store-Oberflächen dienen nur zur Kontrolle von Bedienmustern.
- WCS, alte CZone-, Dometic- und Firefly-Abbildungen sind ausdrücklich keine Designreferenzen.

## Aktueller Umfang

- Licht: sechs reale Lichtkreise plus das manuelle Zusatz-Fernlicht auf STAR-Power-Kanal 3. Die gesamte Zonenkarte ist Schalter und Rückmeldung zugleich; Innen-, Seiten-, Heck- und Fernlicht lassen sich zusätzlich direkt im Transitbild bedienen. Weiß und Orange teilen sich eine Frontleistenkarte und werden als schmale Lichtlinie am Dachbalken dargestellt, das Fernlicht belegt den vollständigen Zusatzbalken. Der permanente Dimmer für die gewählte dimmbare Zone bleibt erhalten.
- Transit: Das originale Fahrerfoto bleibt pixelgleich; eine separate SVG-Ebene ergänzt ausschließlich den im Foto fehlenden zweiten Schiebetürgriff. Heck, Rückleuchte, Heckarbeitsleuchte, Dachträgerleuchten und Markise werden nicht verändert.
- Symbole: die aus dem bestehenden SYNC-/Node-RED-Design übernommenen Leuchtentypen – Deckenleuchte, horizontale 3-LED-Seitenleuchte, quadratische 2-x-2-Heckleuchte, Frontleiste, Warnleiste und Fernlichtscheinwerfer. Die verworfene `Rail Light`-Familie ist entfernt. Auch die allgemeinen Linienicons besitzen eine lokale Inline-Fassung; die Bedienoberfläche bleibt ohne Lucide-CDN vollständig sichtbar.
- Klima: reduzierte Geräteansicht ohne wiederholte Kategorien; Home benennt die Funktion eindeutig als `Klimaautomatik` und zeigt Autoterm sowie MaxxFan als zugehörige Geräte. Das Autoterm-Zeitlimit ist optional und standardmäßig eingeklappt.
- Energie: kombinierte Seite `12 V & 230 V` mit fünf tatsächlichen Verbrauchern und zweite Seite `Quellen`. Icons, Fläche, Kontur und Farbe zeigen den Zustand; Kanalnummern sowie sichtbare Ein-/Aus-/Online-Texte entfallen. Die Lichtmaschinenkarte besitzt echte Felder für Leistung, Spannung und Strom und zeigt bei fehlendem Orion-Dienst bewusst Striche statt erfundener Messwerte.
- Solar: `Solar gesamt` öffnet eine eigene Detailansicht mit drei realen MPPT-Reglern und INDEVOLT. Home und die Quellenkarte führen direkt dorthin; ein Zurück-Pfeil führt wieder zu den Quellen.
- Allgemein: Seitentitel, Geräte- und Statusbezeichnungen werden nicht mehrfach wiederholt. Der Header verwendet wieder die konkrete Ford-Transit-3/4-Silhouette aus dem bestehenden CamperControl-Entwurf statt eines generischen Bus-Symbols.
- Zustand: Home-Schnellzugriffe, Lichtkarten, Szenen und Fahrzeug-Hotspots verwenden im Prototyp ein gemeinsames Lichtmodell und können nicht mehr auseinanderlaufen.
- Responsive: neben dem hohen Mobilraster gibt es eine kompakte 601-bis-720-px-Stufe für kleine WASM-Fenster; die Touch-50-Geometrie bleibt unverändert.

## Dateien

- `campercontrol-v2-transit-horizon.html`: Inline-Fragment für die interaktive Designprüfung.
- `campercontrol-v2-transit-horizon-standalone.html`: direkt im Browser öffnende Fassung.
- `transit-line-symbol-source.png`: unveränderte hochauflösende Quellgrafik des wiedergefundenen Ford-Transit-Liniensymbols.
- `transit-line-symbol-dark.png` und `transit-line-symbol-light.png`: exakte, ausschließlich mechanisch ausgeschnittene Header-Symbole aus dem ursprünglichen Doppelmockup; keine Neuzeichnung.
- `campercontrol-v2-light-modern-touch50.png`: geprüfte 800-x-480-Browserreferenz der Lichtseite.
- `campercontrol-v2-energy-modern-touch50.png`: geprüfte 800-x-480-Browserreferenz der Energieseite.
- `campercontrol-v2-solar-detail-touch50.png`: geprüfte 800-x-480-Browserreferenz der Solar-Detailansicht.

## Datenhinweis

Die angezeigten Werte entsprechen dem während der Designprüfung gelesenen Node-RED-Snapshot und sind im HTML eingefroren. Das HTML behauptet deshalb keine Live-Verbindung. Die spätere QML-Umsetzung bindet dieselben Komponenten an `CamperBackendAdapter`.
