# DWD and BSH data licenses

CamperControl software and the weather/tide data it processes have separate licenses. The PolyForm Noncommercial software license does not apply to DWD or BSH data.

## Deutscher Wetterdienst (DWD)

- Data source: DWD Open Data, MOSMIX_L single-station forecasts
- License: [Creative Commons Attribution 4.0 International (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/)
- Official terms: [DWD Open Data FAQ](https://www.dwd.de/DE/leistungen/opendata/faqs_opendata.html)
- Required visible source: **Quelle: Deutscher Wetterdienst**

CamperControl selects one station, extracts and normalizes hourly MOSMIX values, derives compact daily aggregates and icon groups, calculates local sun times separately, and caches a bounded subset. These are processing changes by CamperControl; DWD does not endorse CamperControl.

## Bundesamt für Seeschifffahrt und Hydrographie (BSH)

- Data source: [BSH WaterLevelForecast API](https://gdi.bsh.de/ldproxy/rest/services/WaterLevelForecast)
- License: [Creative Commons Attribution 4.0 International (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/)
- Required source: **© Bundesamt für Seeschifffahrt und Hydrographie (BSH)**

CamperControl restricts selection to validated North Sea point stations, chooses a nearby station or the defined Wilhelmshaven fallback, normalizes timestamps to UTC, converts centimetres to metres, reduces the curve to bounded samples and derives/interpolates display boundaries. These are processing changes by CamperControl. The BSH does not endorse CamperControl and accepts no liability for the displayed information; the API does not replace official BSH publications.

## Reuse

CC BY 4.0 permits reuse, including commercial reuse, when its conditions are met. Copies or exports of DWD/BSH data must retain an appropriate source citation, a link to CC BY 4.0 and an indication of processing changes. No CamperControl term may impose additional legal or technical restrictions on the DWD/BSH data itself. Third-party data embedded by either provider may have additional notices.

