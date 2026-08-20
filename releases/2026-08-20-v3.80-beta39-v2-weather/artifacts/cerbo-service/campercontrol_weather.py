#!/usr/bin/env python3
"""Cerbo-owned DWD MOSMIX weather acquisition for CamperControl.

The module deliberately has no QML or browser dependency.  It selects a DWD
MOSMIX_L station from the active GX GPS service, downloads the single-station
forecast, normalizes it to a compact transport contract and keeps an atomic
cache under ``/data``.  Consumers only read the resulting D-Bus/MQTT value.
"""

from __future__ import annotations

import ast
import datetime as dt
import io
import json
import math
import os
import re
import subprocess
import tempfile
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


SOURCE_NAME = "DWD MOSMIX_L"
SOURCE_ATTRIBUTION = "Quelle: Deutscher Wetterdienst"
SCHEMA_VERSION = 1
STATION_CATALOG_URLS = (
    "https://www.dwd.de/DE/leistungen/met_verfahren_mosmix/"
    "mosmix_stationskatalog.cfg?view=nasPublication&nn=16102",
    "https://www.dwd.de/EN/ourservices/met_application_mosmix/"
    "mosmix_stations.cfg?view=nasPublication&nn=495490",
)
FORECAST_URL = (
    "https://opendata.dwd.de/weather/local_forecasts/mos/MOSMIX_L/"
    "single_stations/{station}/kml/MOSMIX_L_LATEST_{station}.kmz"
)
DEFAULT_CACHE_PATH = Path("/data/campercontrol/cache/weather-v1.json")
DEFAULT_CATALOG_PATH = Path("/data/campercontrol/cache/mosmix-stations-v1.cfg")
DEFAULT_STATION_CONFIG_PATH = Path("/data/campercontrol/weather-station.conf")
MAX_CATALOG_BYTES = 2 * 1024 * 1024
MAX_KMZ_BYTES = 1024 * 1024
MAX_KML_BYTES = 4 * 1024 * 1024
MAX_SNAPSHOT_BYTES = 16 * 1024
STALE_AFTER_SECONDS = 12 * 60 * 60
CATALOG_REFRESH_SECONDS = 30 * 24 * 60 * 60
# MOSMIX_L has four regular model runs per day. A six-hour success interval is
# sufficient to pick up each run without redundant downloads on the Cerbo.
REFRESH_SECONDS = 6 * 60 * 60
RETRY_SECONDS = (15 * 60, 30 * 60, 60 * 60, 3 * 60 * 60)


@dataclass(frozen=True)
class Station:
    station_id: str
    name: str
    latitude: float
    longitude: float
    elevation: float | None = None


def utc_now() -> dt.datetime:
    return dt.datetime.now(dt.timezone.utc)


def iso_utc(value: dt.datetime | None) -> str | None:
    if value is None:
        return None
    return value.astimezone(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z")


def parse_time(value: Any) -> dt.datetime | None:
    text = str(value or "").strip()
    if not text:
        return None
    try:
        parsed = dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.astimezone(dt.timezone.utc)


def _cfg_coordinate(value: str) -> float:
    """Convert DWD CFG degree.minute coordinates to decimal degrees."""
    raw = float(value)
    sign = -1.0 if raw < 0 else 1.0
    absolute = abs(raw)
    degrees = math.floor(absolute)
    minutes = (absolute - degrees) * 100.0
    if minutes >= 60.0:
        raise ValueError(f"invalid DWD coordinate {value}")
    return sign * (degrees + minutes / 60.0)


def parse_station_catalog(text: str) -> list[Station]:
    stations: list[Station] = []
    pattern = re.compile(
        r"^\s*([A-Za-z0-9]{5})\s+(\S{4})\s+(.+?)\s+"
        r"(-?\d{1,3}\.\d{2,})\s+(-?\d{1,3}\.\d{2,})\s+"
        r"(-?\d+(?:\.\d+)?)\s*$"
    )
    for raw_line in text.splitlines():
        match = pattern.match(raw_line)
        if not match:
            continue
        station_id, _icao, name, latitude, longitude, elevation = match.groups()
        try:
            station = Station(
                station_id=station_id,
                name=" ".join(name.split()),
                latitude=_cfg_coordinate(latitude),
                longitude=_cfg_coordinate(longitude),
                elevation=float(elevation),
            )
        except ValueError:
            continue
        if -90 <= station.latitude <= 90 and -180 <= station.longitude <= 180:
            stations.append(station)
    if not stations:
        raise ValueError("DWD station catalog contains no usable stations")
    return stations


def haversine_km(latitude_a: float, longitude_a: float, latitude_b: float, longitude_b: float) -> float:
    radius = 6371.0088
    lat_a = math.radians(latitude_a)
    lat_b = math.radians(latitude_b)
    d_lat = lat_b - lat_a
    d_lon = math.radians(longitude_b - longitude_a)
    value = math.sin(d_lat / 2) ** 2 + math.cos(lat_a) * math.cos(lat_b) * math.sin(d_lon / 2) ** 2
    return radius * 2 * math.atan2(math.sqrt(value), math.sqrt(max(0.0, 1.0 - value)))


def nearest_station(stations: Iterable[Station], latitude: float, longitude: float) -> tuple[Station, float]:
    candidates = [(station, haversine_km(latitude, longitude, station.latitude, station.longitude)) for station in stations]
    if not candidates:
        raise ValueError("no DWD stations available")
    return min(candidates, key=lambda item: item[1])


def _local_name(tag: str) -> str:
    return tag.rsplit("}", 1)[-1]


def _element_attribute(element: ET.Element, wanted: str) -> str:
    for name, value in element.attrib.items():
        if _local_name(name).lower() == wanted.lower():
            return value
    return ""


def _first_text(root: ET.Element, name: str) -> str:
    for element in root.iter():
        if _local_name(element.tag) == name and element.text:
            return element.text.strip()
    return ""


def _series_value(token: str) -> float | None:
    text = token.strip()
    if not text or text == "-":
        return None
    try:
        value = float(text)
    except ValueError:
        return None
    if not math.isfinite(value) or value <= -999:
        return None
    return value


def _parse_kmz(kmz: bytes) -> ET.Element:
    if len(kmz) > MAX_KMZ_BYTES:
        raise ValueError("DWD KMZ exceeds size limit")
    with zipfile.ZipFile(io.BytesIO(kmz)) as archive:
        members = [item for item in archive.infolist() if not item.is_dir() and item.filename.lower().endswith(".kml")]
        if len(members) != 1:
            raise ValueError("DWD KMZ must contain exactly one KML file")
        member = members[0]
        if Path(member.filename).name != member.filename or member.file_size > MAX_KML_BYTES:
            raise ValueError("unsafe or oversized DWD KML member")
        payload = archive.read(member)
    if len(payload) > MAX_KML_BYTES:
        raise ValueError("DWD KML exceeds size limit")
    upper_prefix = payload[:4096].upper()
    if b"<!DOCTYPE" in upper_prefix or b"<!ENTITY" in upper_prefix:
        raise ValueError("unsafe DWD KML document type")
    return ET.fromstring(payload)


def parse_mosmix_kmz(kmz: bytes) -> tuple[str | None, str, dict[str, list[float | None]], list[dt.datetime]]:
    root = _parse_kmz(kmz)
    times: list[dt.datetime] = []
    for element in root.iter():
        if _local_name(element.tag) != "TimeStep" or not element.text:
            continue
        parsed = parse_time(element.text)
        if parsed is not None:
            times.append(parsed)
    if not times:
        raise ValueError("DWD forecast has no time steps")

    station_name = ""
    for placemark in root.iter():
        if _local_name(placemark.tag) != "Placemark":
            continue
        station_name = _first_text(placemark, "description") or _first_text(placemark, "name")
        break

    series: dict[str, list[float | None]] = {}
    wanted = {"TTT", "R101", "RR1c", "DD", "FF", "FX1", "ww"}
    for element in root.iter():
        if _local_name(element.tag) != "Forecast":
            continue
        element_name = _element_attribute(element, "elementName")
        if element_name not in wanted:
            continue
        value_text = ""
        for child in element.iter():
            if _local_name(child.tag) == "value" and child.text:
                value_text = child.text
                break
        values = [_series_value(token) for token in value_text.split()]
        if len(values) < len(times):
            values.extend([None] * (len(times) - len(values)))
        series[element_name] = values[: len(times)]

    issue_time = parse_time(_first_text(root, "IssueTime"))
    return iso_utc(issue_time), station_name, series, times


def weather_icon(code: float | None) -> str:
    if code is None:
        return "unknown"
    value = int(round(code))
    if value in (95, 96, 97, 98, 99):
        return "storm"
    if value in range(71, 80) or value in (85, 86):
        return "snow"
    if value in range(45, 50):
        return "fog"
    if value in range(50, 70) or value in range(80, 85):
        return "rain"
    if value == 0:
        return "clear"
    if value in (1, 2):
        return "partly-cloudy"
    return "cloudy"


def _normalized_hour(series: dict[str, list[float | None]], times: list[dt.datetime], index: int) -> dict[str, Any]:
    def item(name: str) -> float | None:
        values = series.get(name, [])
        return values[index] if index < len(values) else None

    temperature_k = item("TTT")
    weather_code = item("ww")
    return {
        "t": iso_utc(times[index]),
        "tempC": None if temperature_k is None else round(temperature_k - 273.15, 1),
        "precipProbabilityPct": None if item("R101") is None else round(max(0.0, min(100.0, item("R101") or 0.0))),
        "precipMm": None if item("RR1c") is None else round(max(0.0, item("RR1c") or 0.0), 2),
        "ww": None if weather_code is None else int(round(weather_code)),
        "icon": weather_icon(weather_code),
        "windKmh": None if item("FF") is None else round(max(0.0, item("FF") or 0.0) * 3.6, 1),
        "windDeg": None if item("DD") is None else round((item("DD") or 0.0) % 360.0),
        "gustKmh": None if item("FX1") is None else round(max(0.0, item("FX1") or 0.0) * 3.6, 1),
    }


def _sun_event(date: dt.date, latitude: float, longitude: float, sunrise: bool) -> dt.datetime | None:
    zenith = math.radians(90.833)
    day = date.timetuple().tm_yday
    longitude_hour = longitude / 15.0
    approximate = day + ((6.0 if sunrise else 18.0) - longitude_hour) / 24.0
    mean_anomaly = 0.9856 * approximate - 3.289
    anomaly_rad = math.radians(mean_anomaly)
    true_longitude = (mean_anomaly + 1.916 * math.sin(anomaly_rad) + 0.020 * math.sin(2 * anomaly_rad) + 282.634) % 360.0
    right_ascension = math.degrees(math.atan(0.91764 * math.tan(math.radians(true_longitude)))) % 360.0
    right_ascension += math.floor(true_longitude / 90.0) * 90.0 - math.floor(right_ascension / 90.0) * 90.0
    right_ascension /= 15.0
    sin_declination = 0.39782 * math.sin(math.radians(true_longitude))
    cos_declination = math.cos(math.asin(sin_declination))
    denominator = cos_declination * math.cos(math.radians(latitude))
    if abs(denominator) < 1e-12:
        return None
    cos_hour = (math.cos(zenith) - sin_declination * math.sin(math.radians(latitude))) / denominator
    if cos_hour > 1.0 or cos_hour < -1.0:
        return None
    hour_angle = 360.0 - math.degrees(math.acos(cos_hour)) if sunrise else math.degrees(math.acos(cos_hour))
    local_mean = hour_angle / 15.0 + right_ascension - 0.06571 * approximate - 6.622
    utc_hour = (local_mean - longitude_hour) % 24.0
    midnight = dt.datetime.combine(date, dt.time.min, tzinfo=dt.timezone.utc)
    return midnight + dt.timedelta(hours=utc_hour)


def _safe_timezone(name: str) -> ZoneInfo:
    try:
        return ZoneInfo(name or "UTC")
    except ZoneInfoNotFoundError:
        return ZoneInfo("UTC")


def build_snapshot(
    station: Station,
    distance_km: float | None,
    timezone_name: str,
    model_run_utc: str | None,
    station_name: str,
    series: dict[str, list[float | None]],
    times: list[dt.datetime],
    now: dt.datetime | None = None,
) -> dict[str, Any]:
    now_utc = (now or utc_now()).astimezone(dt.timezone.utc)
    timezone = _safe_timezone(timezone_name)
    all_hours = [_normalized_hour(series, times, index) for index in range(len(times))]
    future_hours = [item for item in all_hours if (parse_time(item["t"]) or now_utc) >= now_utc - dt.timedelta(minutes=30)]
    hourly = future_hours[:48]

    by_date: dict[dt.date, list[dict[str, Any]]] = {}
    for item in future_hours:
        timestamp = parse_time(item["t"])
        if timestamp is None:
            continue
        by_date.setdefault(timestamp.astimezone(timezone).date(), []).append(item)

    today = now_utc.astimezone(timezone).date()
    daily: list[dict[str, Any]] = []
    for offset in range(6):
        date = today + dt.timedelta(days=offset)
        items = by_date.get(date, [])
        temperatures = [item["tempC"] for item in items if item["tempC"] is not None]
        amounts = [item["precipMm"] for item in items if item["precipMm"] is not None]
        probabilities = [item["precipProbabilityPct"] for item in items if item["precipProbabilityPct"] is not None]
        winds = [item["windKmh"] for item in items if item["windKmh"] is not None]
        gusts = [item["gustKmh"] for item in items if item["gustKmh"] is not None]
        codes = [item["ww"] for item in items if item["ww"] is not None]
        representative = max(codes, default=None, key=lambda code: (weather_icon(code) != "clear", code))
        rise = _sun_event(date, station.latitude, station.longitude, True)
        setting = _sun_event(date, station.latitude, station.longitude, False)
        daily.append(
            {
                "date": date.isoformat(),
                "minC": None if not temperatures else round(min(temperatures), 1),
                "maxC": None if not temperatures else round(max(temperatures), 1),
                # A missing DWD hour must not silently become zero in an aggregate.
                "precipMm": None if not items or len(amounts) != len(items) else round(sum(amounts), 1),
                "maxHourlyPrecipProbabilityPct": (
                    None if not items or len(probabilities) != len(items) else round(max(probabilities))
                ),
                "ww": representative,
                "icon": weather_icon(representative),
                "windMaxKmh": None if not winds else round(max(winds), 1),
                "gustMaxKmh": None if not gusts else round(max(gusts), 1),
                "riseUtc": iso_utc(rise),
                "setUtc": iso_utc(setting),
            }
        )

    snapshot: dict[str, Any] = {
        "schema": SCHEMA_VERSION,
        "source": SOURCE_NAME,
        "attribution": SOURCE_ATTRIBUTION,
        "station": {
            "id": station.station_id,
            "name": station_name or station.name,
        },
        "modelRunUtc": model_run_utc,
        "fetchedAtUtc": iso_utc(now_utc),
        "stale": False,
        "timezone": timezone_name or "UTC",
        "sun": {
            "date": today.isoformat(),
            "riseUtc": daily[0]["riseUtc"] if daily else None,
            "setUtc": daily[0]["setUtc"] if daily else None,
            "origin": "calculated",
        },
        "hourly": hourly,
        "daily": daily,
    }
    encoded = json.dumps(snapshot, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
    if len(encoded) > MAX_SNAPSHOT_BYTES:
        raise ValueError("normalized weather snapshot exceeds size limit")
    return snapshot


def mark_stale(snapshot: dict[str, Any], now: dt.datetime | None = None) -> dict[str, Any]:
    copy = json.loads(json.dumps(snapshot))
    fetched = parse_time(copy.get("fetchedAtUtc"))
    current = (now or utc_now()).astimezone(dt.timezone.utc)
    copy["stale"] = fetched is None or (current - fetched).total_seconds() >= STALE_AFTER_SECONDS
    cutoff = current - dt.timedelta(hours=1)
    copy["hourly"] = [
        item
        for item in copy.get("hourly", [])
        if isinstance(item, dict) and (parse_time(item.get("t")) or dt.datetime.min.replace(tzinfo=dt.timezone.utc)) >= cutoff
    ][:48]
    timezone = _safe_timezone(str(copy.get("timezone") or "UTC"))
    today = current.astimezone(timezone).date()
    copy["daily"] = [
        item
        for item in copy.get("daily", [])
        if isinstance(item, dict)
        and isinstance(item.get("date"), str)
        and item["date"] >= today.isoformat()
    ][:6]
    sun = copy.get("sun")
    if isinstance(sun, dict) and sun.get("date") != today.isoformat():
        copy["sun"] = {"date": today.isoformat(), "riseUtc": None, "setUtc": None, "origin": "calculated"}
    return copy


def _atomic_write(path: Path, payload: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, path)
    finally:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass


def load_json(path: Path) -> dict[str, Any] | None:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def save_json(path: Path, value: dict[str, Any]) -> None:
    payload = json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
    _atomic_write(path, payload)


def _decode_catalog(payload: bytes) -> str:
    try:
        return payload.decode("utf-8")
    except UnicodeDecodeError:
        return payload.decode("latin-1")


def _download(url: str, maximum_bytes: int, timeout: float = 30.0) -> bytes:
    request = urllib.request.Request(
        url,
        headers={
            "Accept": "*/*",
            "User-Agent": "CamperControl/1.0 (+https://github.com/victronenergy/gui-v2)",
        },
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        declared = int(response.headers.get("Content-Length") or 0)
        if declared > maximum_bytes:
            raise ValueError("download exceeds size limit")
        payload = response.read(maximum_bytes + 1)
    if len(payload) > maximum_bytes:
        raise ValueError("download exceeds size limit")
    return payload


def _parse_dbus_output(output: str) -> Any:
    """Parse both dbus CLI formats used by Venus OS releases.

    Some services print ``value = ...`` while others return the scalar alone.
    Treat empty/oversized output as unavailable and never interpret stderr.
    """
    text = str(output or "").strip()
    if not text or len(text) > 4096:
        return None
    match = re.search(r"^\s*value\s*=\s*(.+?)\s*$", text, re.MULTILINE | re.IGNORECASE)
    raw = (match.group(1) if match else text).strip()
    if not raw or raw.lower().startswith(("error", "failed", "traceback")):
        return None
    try:
        return ast.literal_eval(raw)
    except (SyntaxError, ValueError):
        try:
            return float(raw)
        except ValueError:
            return raw.strip("'\"") or None


def _dbus_value(service: str, path: str) -> Any:
    result = subprocess.run(
        ["dbus", "-y", service, path, "GetValue"],
        capture_output=True,
        text=True,
        timeout=6,
        check=False,
    )
    if result.returncode != 0:
        return None
    return _parse_dbus_output(result.stdout)


def read_gx_position() -> tuple[float, float] | None:
    service = _dbus_value("com.victronenergy.system", "/GpsService")
    if not isinstance(service, str) or not service.startswith("com.victronenergy."):
        return None
    connected = _dbus_value(service, "/Connected")
    fix = _dbus_value(service, "/Fix")
    try:
        if int(connected) != 1 or int(fix) < 1:
            return None
    except (TypeError, ValueError):
        return None
    latitude = _dbus_value(service, "/Position/Latitude")
    longitude = _dbus_value(service, "/Position/Longitude")
    try:
        lat = float(latitude)
        lon = float(longitude)
    except (TypeError, ValueError):
        return None
    if not (-90 <= lat <= 90 and -180 <= lon <= 180):
        return None
    return lat, lon


def read_gx_timezone() -> str:
    value = _dbus_value("com.victronenergy.settings", "/Settings/System/TimeZone")
    candidate = value.strip().lstrip("/") if isinstance(value, str) else ""
    if not candidate:
        return "UTC"
    try:
        ZoneInfo(candidate)
    except (KeyError, ValueError):
        return "UTC"
    return candidate


class WeatherProvider:
    def __init__(
        self,
        cache_path: Path = DEFAULT_CACHE_PATH,
        catalog_path: Path = DEFAULT_CATALOG_PATH,
        station_config_path: Path = DEFAULT_STATION_CONFIG_PATH,
        download: Callable[[str, int], bytes] = _download,
        position_reader: Callable[[], tuple[float, float] | None] = read_gx_position,
        timezone_reader: Callable[[], str] = read_gx_timezone,
        now: Callable[[], dt.datetime] = utc_now,
    ) -> None:
        self.cache_path = cache_path
        self.catalog_path = catalog_path
        self.station_config_path = station_config_path
        self.download = download
        self.position_reader = position_reader
        self.timezone_reader = timezone_reader
        self.now = now

    def cached(self) -> dict[str, Any] | None:
        value = load_json(self.cache_path)
        return mark_stale(value, self.now()) if value else None

    def _catalog(self) -> list[Station]:
        cached_stations: list[Station] | None = None
        cache_is_fresh = False
        try:
            cached = _decode_catalog(self.catalog_path.read_bytes())
            cached_stations = parse_station_catalog(cached)
            cache_is_fresh = self.now().timestamp() - self.catalog_path.stat().st_mtime < CATALOG_REFRESH_SECONDS
        except (OSError, UnicodeDecodeError, ValueError):
            pass
        if cached_stations is not None and cache_is_fresh:
            return cached_stations
        last_error: Exception | None = None
        for url in STATION_CATALOG_URLS:
            try:
                payload = self.download(url, MAX_CATALOG_BYTES)
                text = _decode_catalog(payload)
                stations = parse_station_catalog(text)
                _atomic_write(self.catalog_path, payload)
                return stations
            except (OSError, ValueError, UnicodeError, urllib.error.URLError) as error:
                last_error = error
        if cached_stations is not None:
            return cached_stations
        raise RuntimeError(f"DWD station catalog unavailable: {last_error}")

    def _manual_station_id(self) -> str:
        configured = os.environ.get("CAMPER_WEATHER_STATION", "").strip()
        if not configured:
            try:
                configured = self.station_config_path.read_text(encoding="ascii").splitlines()[0].strip()
            except (OSError, IndexError, UnicodeError):
                configured = ""
        return configured if re.fullmatch(r"[A-Za-z0-9]{5}", configured) else ""

    def _select_station(self, stations: list[Station]) -> tuple[Station, float | None]:
        manual = self._manual_station_id()
        if manual:
            for station in stations:
                if station.station_id == manual:
                    return station, None
            raise ValueError(f"configured DWD station {manual} is unknown")
        position = self.position_reader()
        if position is not None:
            return nearest_station(stations, *position)
        cached = load_json(self.cache_path) or {}
        cached_id = str((cached.get("station") or {}).get("id") or "")
        for station in stations:
            if station.station_id == cached_id:
                return station, None
        raise RuntimeError("no GX GPS fix, cached station or manual DWD station")

    def refresh(self) -> dict[str, Any]:
        stations = self._catalog()
        station, distance = self._select_station(stations)
        kmz = self.download(FORECAST_URL.format(station=station.station_id), MAX_KMZ_BYTES)
        model_run, station_name, series, times = parse_mosmix_kmz(kmz)
        snapshot = build_snapshot(
            station=station,
            distance_km=distance,
            timezone_name=self.timezone_reader(),
            model_run_utc=model_run,
            station_name=station_name,
            series=series,
            times=times,
            now=self.now(),
        )
        save_json(self.cache_path, snapshot)
        return snapshot
