#!/usr/bin/env python3
"""Cerbo-owned DWD MOSMIX weather and BSH tide acquisition for CamperControl.

The module deliberately has no QML or browser dependency.  It selects a DWD
MOSMIX_L station from the active GX GPS service, downloads the single-station
forecast, normalizes it to a compact transport contract and keeps an atomic
cache under ``/data``.  When the GX is close to a North Sea tide gauge, the
provider also adds the next BSH high and low water predictions. Consumers only
read the resulting D-Bus/MQTT value.
"""

from __future__ import annotations

import ast
import datetime as dt
import gzip
import io
import json
import math
import os
import re
import subprocess
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
import zipfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError


SOURCE_NAME = "DWD MOSMIX_L"
SOURCE_ATTRIBUTION = "Quelle: Deutscher Wetterdienst"
TIDE_SOURCE_NAME = "BSH"
TIDE_ATTRIBUTION = "© Bundesamt für Seeschifffahrt und Hydrographie (BSH)"
TIDE_LICENSE = "CC BY 4.0"
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
TIDE_API_ROOT = "https://gdi.bsh.de/ldproxy/rest/services/WaterLevelForecast"
TIDE_ITEMS_URL = f"{TIDE_API_ROOT}/collections/waterlevelforecastdata/items"
DEFAULT_CACHE_PATH = Path("/data/campercontrol/cache/weather-v1.json")
DEFAULT_CATALOG_PATH = Path("/data/campercontrol/cache/mosmix-stations-v1.cfg")
DEFAULT_STATION_CONFIG_PATH = Path("/data/campercontrol/weather-station.conf")
DEFAULT_TIDE_CACHE_PATH = Path("/data/campercontrol/cache/bsh-tides-v1.json")
MAX_CATALOG_BYTES = 2 * 1024 * 1024
MAX_KMZ_BYTES = 1024 * 1024
MAX_KML_BYTES = 4 * 1024 * 1024
MAX_SNAPSHOT_BYTES = 16 * 1024
MAX_STATION_CONFIG_BYTES = 128
MAX_TIDE_HITS_BYTES = 16 * 1024
MAX_TIDE_DISCOVERY_PAGE_BYTES = 1536 * 1024
MAX_TIDE_DISCOVERY_TOTAL_BYTES = 4 * 1024 * 1024
MAX_TIDE_STATION_BYTES = 512 * 1024
MAX_TIDE_CACHE_BYTES = 16 * 1024
STALE_AFTER_SECONDS = 12 * 60 * 60
CATALOG_REFRESH_SECONDS = 30 * 24 * 60 * 60
TIDE_REFRESH_SECONDS = 6 * 60 * 60
TIDE_STALE_AFTER_SECONDS = 48 * 60 * 60
TIDE_FAIL_CLOSED_SECONDS = 7 * 24 * 60 * 60
TIDE_RETRY_SECONDS = 6 * 60 * 60
TIDE_EVENT_HORIZON_SECONDS = 9 * 24 * 60 * 60
TIDE_CURVE_PUBLIC_HORIZON_SECONDS = 24 * 60 * 60
# Keep a dense 72-hour normalized curve so the public 24-hour chart remains
# complete throughout the full 48-hour stale window, even when BSH cannot be
# reached. 145 points are roughly half-hourly; the raw 10-minute series is
# never cached or published and the encoded cache remains below 16 KiB.
TIDE_CURVE_CACHE_HORIZON_SECONDS = 72 * 60 * 60
# A tide prediction is useful near the coast and tidal rivers, but a nearest
# station must not make tides appear across inland Germany. Sixty kilometres
# covers common coastal campsites while failing closed well before that occurs.
TIDE_MAX_DISTANCE_KM = 60.0
TIDE_CACHE_EVENT_LIMIT = 32
TIDE_CACHE_CURVE_LIMIT = 145
# Twenty-five interior samples plus two explicitly interpolated 24-hour
# boundaries.  This adds the two visually missing chart endpoints without
# retaining or publishing the roughly ten-minute raw BSH series.
TIDE_PUBLIC_CURVE_LIMIT = 27
TIDE_RAW_EVENT_LIMIT = 256
TIDE_RAW_CURVE_LIMIT = 2048
TIDE_DISCOVERY_RADII_KM = (10.0, 25.0, TIDE_MAX_DISTANCE_KM)
TIDE_DISCOVERY_PAGE_SIZE = 10
TIDE_DISCOVERY_MAX_MATCHES = 48
TIDE_STATION_REUSE_DISTANCE_KM = 10.0
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


@dataclass(frozen=True)
class TideStation:
    station_id: str
    name: str
    latitude: float
    longitude: float
    region: str = "north_sea"


@dataclass(frozen=True)
class HttpResult:
    status: int
    payload: bytes
    etag: str | None = None


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


def _json_object(payload: bytes, maximum_bytes: int, source: str) -> dict[str, Any]:
    if len(payload) > maximum_bytes:
        raise ValueError(f"{source} JSON exceeds size limit")
    try:
        value = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise ValueError(f"invalid {source} JSON") from error
    if not isinstance(value, dict):
        raise ValueError(f"{source} JSON root must be an object")
    return value


def nearest_tide_station(
    stations: Iterable[TideStation], latitude: float, longitude: float
) -> tuple[TideStation, float]:
    candidates = [
        (station, haversine_km(latitude, longitude, station.latitude, station.longitude))
        for station in stations
    ]
    if not candidates:
        raise ValueError("no BSH tide stations available")
    return min(candidates, key=lambda item: item[1])


def tide_station_url(station_id: str) -> str:
    if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,127}", station_id):
        raise ValueError("invalid BSH station id")
    return f"{TIDE_ITEMS_URL}/{urllib.parse.quote(station_id, safe='')}?f=json&lang=en"


def _tide_bbox(latitude: float, longitude: float, radius_km: float) -> tuple[float, float, float, float]:
    latitude_delta = radius_km / 110.574
    longitude_scale = max(0.05, 111.320 * math.cos(math.radians(latitude)))
    longitude_delta = radius_km / longitude_scale
    return (
        max(-180.0, longitude - longitude_delta),
        max(-90.0, latitude - latitude_delta),
        min(180.0, longitude + longitude_delta),
        min(90.0, latitude + latitude_delta),
    )


def _tide_query_url(
    latitude: float,
    longitude: float,
    radius_km: float,
    *,
    hits_only: bool,
    limit: int | None = None,
    offset: int = 0,
) -> str:
    bbox = ",".join(f"{value:.6f}" for value in _tide_bbox(latitude, longitude, radius_km))
    parameters: dict[str, str | int] = {
        "bbox": bbox,
        "region": "north_sea",
        "f": "json",
        "lang": "en",
    }
    if hits_only:
        parameters["result-type"] = "hitsOnly"
    else:
        parameters["limit"] = limit or TIDE_DISCOVERY_PAGE_SIZE
        parameters["offset"] = offset
    return f"{TIDE_ITEMS_URL}?{urllib.parse.urlencode(parameters)}"


def parse_bsh_time(value: Any) -> dt.datetime | None:
    """Parse the OGC API's explicit UTC offset without timezone guessing."""

    text = str(value or "").strip()
    if not text or not re.search(r"(?:Z|[+-]\d{2}:\d{2})$", text):
        return None
    try:
        parsed = dt.datetime.fromisoformat(text.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return None
    return parsed.astimezone(dt.timezone.utc)


def _centimetres_to_metres(value: Any) -> float | None:
    if value is None or isinstance(value, bool):
        return None
    try:
        centimetres = float(str(value).strip())
    except (TypeError, ValueError):
        return None
    if not math.isfinite(centimetres) or abs(centimetres) > 20000:
        return None
    return round(centimetres / 100.0, 2)


def _feature_properties(feature: dict[str, Any]) -> dict[str, Any] | None:
    if feature.get("type") != "Feature":
        return None
    properties = feature.get("properties")
    return properties if isinstance(properties, dict) else None


def _station_from_feature(feature: dict[str, Any]) -> TideStation | None:
    properties = _feature_properties(feature)
    geometry = feature.get("geometry")
    if properties is None or not isinstance(geometry, dict) or geometry.get("type") != "Point":
        return None
    station_id = str(feature.get("id") or "").strip()
    station_name = " ".join(str(properties.get("gauge_label") or "").split())
    region = str(properties.get("region") or "").strip().lower()
    licence = str(properties.get("licence") or "").strip().upper()
    coordinates = geometry.get("coordinates")
    if not isinstance(coordinates, list) or len(coordinates) < 2:
        return None
    try:
        longitude = float(coordinates[0])
        latitude = float(coordinates[1])
    except (TypeError, ValueError):
        return None
    if (
        not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,127}", station_id)
        or not station_name
        or region != "north_sea"
        or TIDE_LICENSE not in licence
        or not math.isfinite(latitude)
        or not math.isfinite(longitude)
        or not (-90 <= latitude <= 90 and -180 <= longitude <= 180)
    ):
        return None
    return TideStation(station_id, station_name, latitude, longitude, region)


def _raw_curve_samples(properties: dict[str, Any], now: dt.datetime) -> list[dict[str, Any]]:
    raw_curve = properties.get("curve")
    if not isinstance(raw_curve, list) or len(raw_curve) > TIDE_RAW_CURVE_LIMIT:
        return []
    current = now.astimezone(dt.timezone.utc)
    start = current - dt.timedelta(hours=2)
    end = current + dt.timedelta(seconds=TIDE_EVENT_HORIZON_SECONDS)
    samples: list[dict[str, Any]] = []
    for item in raw_curve:
        if not isinstance(item, dict):
            continue
        timestamp = parse_bsh_time(item.get("timestamp"))
        if timestamp is None or timestamp < start or timestamp > end:
            continue
        tidal_height = _centimetres_to_metres(item.get("tidal_prediction"))
        forecast_height = _centimetres_to_metres(item.get("automated_curve_forecast"))
        if tidal_height is None and forecast_height is None:
            continue
        samples.append(
            {
                "timestamp": timestamp,
                "tidalHeightM": tidal_height,
                "forecastHeightM": forecast_height,
            }
        )
    samples.sort(key=lambda item: item["timestamp"])
    deduplicated: list[dict[str, Any]] = []
    for sample in samples:
        if deduplicated and sample["timestamp"] == deduplicated[-1]["timestamp"]:
            deduplicated[-1] = sample
        else:
            deduplicated.append(sample)
    return deduplicated


def _downsample_curve(points: list[dict[str, Any]], limit: int) -> list[dict[str, Any]]:
    if len(points) <= limit:
        return points
    if limit < 2:
        return points[:limit]

    # Keep both chart boundaries and the actual turning points. A purely even
    # index sample can miss every HW/NW peak although the source curve is
    # perfectly valid. The remaining slots repeatedly split the largest time
    # gap, which stays deterministic and distributes points across 24 hours.
    extrema: list[int] = []
    for index in range(1, len(points) - 1):
        before = float(points[index - 1]["heightM"])
        current = float(points[index]["heightM"])
        after = float(points[index + 1]["heightM"])
        if (current > before and current >= after) or (current < before and current <= after):
            extrema.append(index)
    if len(extrema) > limit - 2:
        extrema = [
            extrema[round(index * (len(extrema) - 1) / max(1, limit - 3))]
            for index in range(limit - 2)
        ]

    selected = {0, len(points) - 1, *extrema}
    while len(selected) < limit:
        ordered = sorted(selected)
        gaps = [(right - left, left, right) for left, right in zip(ordered, ordered[1:]) if right - left > 1]
        if not gaps:
            break
        _size, left, right = max(gaps)
        selected.add((left + right) // 2)
    return [points[index] for index in sorted(selected)]


def _curve_boundary(points: list[dict[str, Any]], target: dt.datetime) -> dict[str, Any] | None:
    previous: tuple[dt.datetime, float] | None = None
    for point in points:
        timestamp = parse_utc_z(point.get("t"))
        try:
            height = float(point.get("heightM"))
        except (TypeError, ValueError):
            continue
        if timestamp is None or not math.isfinite(height):
            continue
        if timestamp == target:
            return {"t": iso_utc(target), "heightM": round(height, 2)}
        if timestamp > target:
            if previous is None:
                return None
            before_time, before_height = previous
            span = (timestamp - before_time).total_seconds()
            # Gaps beyond three hours indicate missing source data. Do not
            # invent a long straight segment merely to fill a chart edge.
            if span <= 0 or span > 3 * 60 * 60:
                return None
            ratio = (target - before_time).total_seconds() / span
            value = before_height + (height - before_height) * ratio
            return {"t": iso_utc(target), "heightM": round(value, 2)}
        previous = (timestamp, height)
    return None


def _curve_window(
    points: list[dict[str, Any]],
    start: dt.datetime,
    end: dt.datetime,
    limit: int,
) -> list[dict[str, Any]]:
    current = start.astimezone(dt.timezone.utc)
    finish = end.astimezone(dt.timezone.utc)
    ordered = sorted(points, key=lambda item: str(item.get("t") or ""))
    selected: list[dict[str, Any]] = []
    start_point = _curve_boundary(ordered, current)
    if start_point is not None:
        selected.append(start_point)
    for point in ordered:
        timestamp = parse_utc_z(point.get("t"))
        if timestamp is None or timestamp <= current or timestamp >= finish:
            continue
        try:
            height = round(float(point.get("heightM")), 2)
        except (TypeError, ValueError):
            continue
        if math.isfinite(height) and abs(height) <= 200:
            selected.append({"t": iso_utc(timestamp), "heightM": height})
    end_point = _curve_boundary(ordered, finish)
    if end_point is not None:
        selected.append(end_point)
    deduplicated: list[dict[str, Any]] = []
    for point in sorted(selected, key=lambda item: str(item["t"])):
        if deduplicated and point["t"] == deduplicated[-1]["t"]:
            deduplicated[-1] = point
        else:
            deduplicated.append(point)
    return _downsample_curve(deduplicated, limit)


def _normalized_curve(samples: list[dict[str, Any]], now: dt.datetime) -> list[dict[str, Any]]:
    current = now.astimezone(dt.timezone.utc)
    end = current + dt.timedelta(seconds=TIDE_CURVE_CACHE_HORIZON_SECONDS)
    points: list[dict[str, Any]] = []
    for sample in samples:
        timestamp = sample["timestamp"]
        # The official OGC curve's automated forecast is the most useful
        # future water level. The astronomical tidal prediction is the
        # documented fallback when no model value is present.
        height_m = sample.get("forecastHeightM")
        if height_m is None:
            height_m = sample.get("tidalHeightM")
        if height_m is None:
            continue
        points.append({"t": iso_utc(timestamp), "heightM": height_m})
    return _curve_window(points, current, end, TIDE_CACHE_CURVE_LIMIT)


def _curve_extrema(samples: list[dict[str, Any]], now: dt.datetime) -> list[dict[str, Any]]:
    values = [sample for sample in samples if sample.get("tidalHeightM") is not None]
    if len(values) < 3:
        values = [sample for sample in samples if sample.get("forecastHeightM") is not None]
        key = "forecastHeightM"
    else:
        key = "tidalHeightM"
    if len(values) < 3:
        return []

    groups: list[list[dict[str, Any]]] = []
    for sample in values:
        if groups and sample[key] == groups[-1][-1][key]:
            groups[-1].append(sample)
        else:
            groups.append([sample])
    current = now.astimezone(dt.timezone.utc)
    events: list[dict[str, Any]] = []
    for index in range(1, len(groups) - 1):
        previous_height = groups[index - 1][0][key]
        height = groups[index][0][key]
        following_height = groups[index + 1][0][key]
        event_type = ""
        if height > previous_height and height > following_height:
            event_type = "HW"
        elif height < previous_height and height < following_height:
            event_type = "NW"
        if not event_type:
            continue
        sample = groups[index][len(groups[index]) // 2]
        timestamp = sample["timestamp"]
        if timestamp < current:
            continue
        events.append({"t": iso_utc(timestamp), "type": event_type, "heightM": height})
    return events


def _has_future_tides(properties: dict[str, Any], now: dt.datetime) -> bool:
    current = now.astimezone(dt.timezone.utc)
    event_types: set[str] = set()
    raw_events = properties.get("high_water_low_water")
    if isinstance(raw_events, list) and len(raw_events) <= TIDE_RAW_EVENT_LIMIT:
        for item in raw_events:
            if not isinstance(item, dict):
                continue
            timestamp = parse_bsh_time(item.get("event_timestamp"))
            event_type = str(item.get("event") or "").strip().upper()
            if timestamp is not None and timestamp >= current and event_type in ("HW", "NW"):
                event_types.add(event_type)
    if event_types == {"HW", "NW"}:
        return True
    extrema = _curve_extrema(_raw_curve_samples(properties, current), current)
    return {str(item["type"]) for item in extrema} >= {"HW", "NW"}


def parse_tide_hits(payload: bytes) -> int:
    root = _json_object(payload, MAX_TIDE_HITS_BYTES, "BSH OGC hits")
    if root.get("type") != "FeatureCollection":
        raise ValueError("BSH OGC hits response is not a FeatureCollection")
    try:
        matched = int(root.get("numberMatched"))
    except (TypeError, ValueError) as error:
        raise ValueError("BSH OGC hits response has no count") from error
    if matched < 0 or matched > 10000:
        raise ValueError("BSH OGC hits count is outside bounds")
    return matched


def parse_tide_feature_collection(
    payload: bytes,
    now: dt.datetime,
) -> tuple[list[TideStation], int, int]:
    root = _json_object(payload, MAX_TIDE_DISCOVERY_PAGE_BYTES, "BSH OGC station page")
    if root.get("type") != "FeatureCollection":
        raise ValueError("BSH OGC station page is not a FeatureCollection")
    features = root.get("features")
    if not isinstance(features, list) or len(features) > TIDE_DISCOVERY_PAGE_SIZE:
        raise ValueError("BSH OGC station page has an invalid feature count")
    try:
        returned = int(root.get("numberReturned"))
        matched = int(root.get("numberMatched"))
    except (TypeError, ValueError) as error:
        raise ValueError("BSH OGC station page has invalid counters") from error
    if returned != len(features) or returned < 0 or matched < returned:
        raise ValueError("BSH OGC station page counters do not match its features")
    stations: list[TideStation] = []
    for feature in features:
        if not isinstance(feature, dict):
            continue
        station = _station_from_feature(feature)
        properties = _feature_properties(feature)
        if station is not None and properties is not None and _has_future_tides(properties, now):
            stations.append(station)
    return stations, returned, matched


def parse_utc_z(value: Any) -> dt.datetime | None:
    text = str(value or "").strip()
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z", text):
        return None
    return parse_time(text)


def parse_tide_station(
    payload: bytes,
    expected_station_id: str,
    now: dt.datetime,
) -> tuple[str, str, list[dict[str, Any]], list[dict[str, Any]]]:
    """Normalize one official OGC feature without retaining its raw curve."""

    root = _json_object(payload, MAX_TIDE_STATION_BYTES, "BSH OGC station tide")
    station_id = str(root.get("id") or "").strip()
    if station_id != expected_station_id:
        raise ValueError("BSH station response does not match requested gauge")
    station = _station_from_feature(root)
    properties = _feature_properties(root)
    if station is None or properties is None:
        raise ValueError("BSH station tide response is incomplete")

    current = now.astimezone(dt.timezone.utc)
    candidates: list[tuple[dt.datetime, dict[str, Any]]] = []
    raw_events = properties.get("high_water_low_water")
    if isinstance(raw_events, list) and len(raw_events) <= TIDE_RAW_EVENT_LIMIT:
        for item in raw_events:
            if not isinstance(item, dict):
                continue
            event_type = str(item.get("event") or "").strip().upper()
            timestamp = parse_bsh_time(item.get("event_timestamp"))
            if (
                event_type not in ("HW", "NW")
                or timestamp is None
                or timestamp < current
                or timestamp > current + dt.timedelta(seconds=TIDE_EVENT_HORIZON_SECONDS)
            ):
                continue
            height_m = _centimetres_to_metres(item.get("tidal_prediction_value"))
            candidates.append(
                (
                    timestamp,
                    {"t": iso_utc(timestamp), "type": event_type, "heightM": height_m},
                )
            )

    raw_curve = _raw_curve_samples(properties, current)
    available_types = {str(item[1]["type"]) for item in candidates}
    if available_types != {"HW", "NW"}:
        missing_types = {"HW", "NW"} - available_types
        for event in _curve_extrema(raw_curve, current):
            if event.get("type") not in missing_types:
                continue
            timestamp = parse_utc_z(event.get("t"))
            if timestamp is not None:
                candidates.append((timestamp, event))

    candidates.sort(key=lambda item: item[0])
    events: list[dict[str, Any]] = []
    seen: set[tuple[str, str]] = set()
    for _timestamp, event in candidates:
        key = (str(event["t"]), str(event["type"]))
        if key in seen:
            continue
        seen.add(key)
        events.append(event)
        if len(events) >= TIDE_CACHE_EVENT_LIMIT:
            break
    if not any(item["type"] == "HW" for item in events) or not any(item["type"] == "NW" for item in events):
        raise ValueError("BSH station tide response has no future HW/NW pair")
    return station.name, "PNP", events, _normalized_curve(raw_curve, current)


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


# Complete list from the DWD "Wettercode ww" table used by MOSMIX.  The
# second tuple item is the official DWD priority (lower means more relevant
# for the daily representative condition).  Codes 96--99 are not listed in
# the current MOSMIX table; they are handled defensively below, without ever
# inferring hail from the published code 95.
MOSMIX_WW: dict[int, tuple[str, int]] = {
    95: ("thunderstorm", 1),
    57: ("freezing-rain", 2),
    56: ("freezing-rain", 3),
    67: ("freezing-rain", 4),
    66: ("freezing-rain", 5),
    86: ("snow", 6),
    85: ("snow", 7),
    84: ("sleet", 8),
    83: ("sleet", 9),
    82: ("showers", 10),
    81: ("showers", 11),
    80: ("showers", 12),
    75: ("snow", 13),
    73: ("snow", 14),
    71: ("snow", 15),
    69: ("sleet", 16),
    68: ("sleet", 17),
    55: ("drizzle", 18),
    53: ("drizzle", 19),
    51: ("drizzle", 20),
    65: ("rain", 21),
    63: ("rain", 22),
    61: ("rain", 23),
    49: ("fog", 24),
    45: ("fog", 25),
    3: ("cloudy", 26),
    2: ("partly-cloudy", 27),
    1: ("partly-cloudy", 28),
    0: ("clear", 29),
}


def _weather_code(code: float | None) -> int | None:
    if code is None or not math.isfinite(code):
        return None
    return int(round(code))


def weather_icon(code: float | None) -> str:
    value = _weather_code(code)
    if value is None:
        return "unknown"
    configured = MOSMIX_WW.get(value)
    if configured is not None:
        return configured[0]
    # Defensive WMO fallbacks.  MOSMIX currently does not publish these
    # values, but 96/99 explicitly include hail and must not be flattened to
    # ordinary thunder if they appear in a future feed.
    if value in (96, 99):
        return "hail"
    if value in (97, 98):
        return "thunderstorm"
    return "unknown"


def weather_priority(code: float | None) -> int:
    value = _weather_code(code)
    if value is None:
        return 10_000
    configured = MOSMIX_WW.get(value)
    if configured is not None:
        return configured[1]
    if value in (96, 99):
        return 1
    if value in (97, 98):
        return 2
    return 10_000


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
        representative = min(codes, default=None, key=weather_priority)
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
    return load_json_limited(path, MAX_SNAPSHOT_BYTES)


def _read_limited(path: Path, maximum_bytes: int) -> bytes:
    with path.open("rb") as handle:
        payload = handle.read(maximum_bytes + 1)
    if len(payload) > maximum_bytes:
        raise ValueError("cached file exceeds size limit")
    return payload


def load_json_limited(path: Path, maximum_bytes: int) -> dict[str, Any] | None:
    try:
        payload = _read_limited(path, maximum_bytes)
        value = json.loads(payload.decode("utf-8"))
    except (OSError, UnicodeError, ValueError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def save_json(path: Path, value: dict[str, Any]) -> None:
    payload = json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
    _atomic_write(path, payload)


def _encoded_json(value: dict[str, Any]) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")


def _valid_tide_cache(value: dict[str, Any], now: dt.datetime) -> dict[str, Any] | None:
    if value.get("schema") != 1 or value.get("referenceLevel") != "PNP":
        return None
    updated = parse_utc_z(value.get("updatedUtc"))
    current = now.astimezone(dt.timezone.utc)
    if updated is None or updated > current + dt.timedelta(minutes=5):
        return None
    age_seconds = (current - updated).total_seconds()
    if age_seconds >= TIDE_FAIL_CLOSED_SECONDS:
        return None
    station = value.get("station")
    if not isinstance(station, dict):
        return None
    station_id = str(station.get("id") or "")
    station_name = " ".join(str(station.get("name") or "").split())
    try:
        distance_km = float(station.get("distanceKm"))
    except (TypeError, ValueError):
        return None
    if (
        not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,127}", station_id)
        or not station_name
        or not math.isfinite(distance_km)
        or not (0 <= distance_km <= TIDE_MAX_DISTANCE_KM)
    ):
        return None

    normalized_events: list[dict[str, Any]] = []
    events = value.get("events")
    if not isinstance(events, list) or len(events) > TIDE_CACHE_EVENT_LIMIT:
        return None
    for event in events:
        if not isinstance(event, dict):
            continue
        event_type = str(event.get("type") or "").upper()
        timestamp = parse_utc_z(event.get("t"))
        if event_type not in ("HW", "NW") or timestamp is None or timestamp < current:
            continue
        height_m = event.get("heightM")
        if height_m is not None:
            try:
                height_m = round(float(height_m), 2)
            except (TypeError, ValueError):
                height_m = None
            if height_m is not None and (not math.isfinite(height_m) or abs(height_m) > 200):
                height_m = None
        normalized_events.append({"t": iso_utc(timestamp), "type": event_type, "heightM": height_m})
    normalized_events.sort(key=lambda item: str(item["t"]))
    next_high = next((item for item in normalized_events if item["type"] == "HW"), None)
    next_low = next((item for item in normalized_events if item["type"] == "NW"), None)
    if next_high is None or next_low is None:
        return None

    normalized_curve: list[dict[str, Any]] = []
    raw_curve = value.get("curve")
    if isinstance(raw_curve, list) and len(raw_curve) <= TIDE_CACHE_CURVE_LIMIT:
        for point in raw_curve:
            if not isinstance(point, dict):
                continue
            timestamp = parse_utc_z(point.get("t"))
            if timestamp is None:
                continue
            try:
                height_m = round(float(point.get("heightM")), 2)
            except (TypeError, ValueError):
                continue
            if not math.isfinite(height_m) or abs(height_m) > 200:
                continue
            normalized_curve.append({"t": iso_utc(timestamp), "heightM": height_m})
    curve_end = current + dt.timedelta(seconds=TIDE_CURVE_PUBLIC_HORIZON_SECONDS)
    deduplicated_curve = _curve_window(normalized_curve, current, curve_end, TIDE_PUBLIC_CURVE_LIMIT)

    result = {
        "source": TIDE_SOURCE_NAME,
        "attribution": TIDE_ATTRIBUTION,
        "station": {
            "id": station_id,
            "name": station_name,
            "distanceKm": round(distance_km, 1),
        },
        "updatedUtc": iso_utc(updated),
        "stale": age_seconds >= TIDE_STALE_AFTER_SECONDS,
        "referenceLevel": "PNP",
        "nextHigh": {"t": next_high["t"], "heightM": next_high["heightM"]},
        "nextLow": {"t": next_low["t"], "heightM": next_low["heightM"]},
    }
    if len(deduplicated_curve) >= 2:
        result["curve"] = deduplicated_curve
    return result


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


def _safe_etag(value: Any) -> str | None:
    text = str(value or "").strip()
    if not text or len(text) > 256 or "\r" in text or "\n" in text:
        return None
    return text


def _decode_http_payload(payload: bytes, content_encoding: str, maximum_bytes: int) -> bytes:
    encoding = str(content_encoding or "").strip().lower()
    if encoding in ("", "identity"):
        decoded = payload
    elif encoding == "gzip":
        try:
            with gzip.GzipFile(fileobj=io.BytesIO(payload)) as compressed:
                decoded = compressed.read(maximum_bytes + 1)
        except (OSError, EOFError) as error:
            raise ValueError("invalid gzip response") from error
    else:
        raise ValueError("unsupported HTTP content encoding")
    if len(decoded) > maximum_bytes:
        raise ValueError("download exceeds decompressed size limit")
    return decoded


def _download_conditional(
    url: str,
    maximum_bytes: int,
    etag: str | None = None,
    timeout: float = 30.0,
) -> HttpResult:
    headers = {
        "Accept": "application/geo+json, application/json",
        "Accept-Encoding": "gzip",
        "User-Agent": "CamperControl/1.0 (+https://github.com/victronenergy/gui-v2)",
    }
    validated_etag = _safe_etag(etag)
    if validated_etag is not None:
        headers["If-None-Match"] = validated_etag
    request = urllib.request.Request(url, headers=headers)
    try:
        response = urllib.request.urlopen(request, timeout=timeout)
    except urllib.error.HTTPError as error:
        if error.code == 304 and validated_etag is not None:
            return HttpResult(304, b"", _safe_etag(error.headers.get("ETag")) or validated_etag)
        raise
    with response:
        if response.getcode() != 200:
            raise ValueError("unexpected BSH HTTP status")
        declared = int(response.headers.get("Content-Length") or 0)
        if declared > maximum_bytes:
            raise ValueError("download exceeds compressed size limit")
        compressed_payload = response.read(maximum_bytes + 1)
        if len(compressed_payload) > maximum_bytes:
            raise ValueError("download exceeds compressed size limit")
        payload = _decode_http_payload(
            compressed_payload,
            response.headers.get("Content-Encoding") or "",
            maximum_bytes,
        )
        response_etag = _safe_etag(response.headers.get("ETag"))
    return HttpResult(200, payload, response_etag)


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
        tide_cache_path: Path = DEFAULT_TIDE_CACHE_PATH,
        download: Callable[[str, int], bytes] = _download,
        tide_http: Callable[[str, int, str | None], HttpResult] | None = None,
        position_reader: Callable[[], tuple[float, float] | None] = read_gx_position,
        timezone_reader: Callable[[], str] = read_gx_timezone,
        now: Callable[[], dt.datetime] = utc_now,
    ) -> None:
        self.cache_path = cache_path
        self.catalog_path = catalog_path
        self.station_config_path = station_config_path
        self.tide_cache_path = tide_cache_path
        self.download = download
        if tide_http is not None:
            self.tide_http = tide_http
        elif download is _download:
            self.tide_http = _download_conditional
        else:
            self.tide_http = lambda url, maximum, _etag=None: HttpResult(
                200,
                download(url, maximum),
                None,
            )
        self.position_reader = position_reader
        self.timezone_reader = timezone_reader
        self.now = now
        self._tide_next_attempt: dt.datetime | None = None

    def cached(self) -> dict[str, Any] | None:
        value = load_json(self.cache_path)
        if not value:
            return None
        current = self.now()
        snapshot = mark_stale(value, current)
        tides = _valid_tide_cache(
            load_json_limited(self.tide_cache_path, MAX_TIDE_CACHE_BYTES) or {},
            current,
        )
        if tides is None:
            snapshot.pop("tides", None)
        else:
            snapshot["tides"] = tides
        if len(_encoded_json(snapshot)) > MAX_SNAPSHOT_BYTES:
            if isinstance(snapshot.get("tides"), dict) and "curve" in snapshot["tides"]:
                snapshot["tides"] = dict(snapshot["tides"])
                snapshot["tides"].pop("curve", None)
            if len(_encoded_json(snapshot)) > MAX_SNAPSHOT_BYTES:
                snapshot.pop("tides", None)
        return snapshot

    def _catalog(self) -> list[Station]:
        cached_stations: list[Station] | None = None
        cache_is_fresh = False
        try:
            cached = _decode_catalog(_read_limited(self.catalog_path, MAX_CATALOG_BYTES))
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

    def _discover_tide_station(
        self,
        position: tuple[float, float],
        current: dt.datetime,
    ) -> tuple[TideStation, float] | None:
        latitude, longitude = position
        for radius_km in TIDE_DISCOVERY_RADII_KM:
            hits_response = self.tide_http(
                _tide_query_url(latitude, longitude, radius_km, hits_only=True),
                MAX_TIDE_HITS_BYTES,
                None,
            )
            if hits_response.status != 200:
                raise ValueError("unexpected BSH hits response")
            matched = parse_tide_hits(hits_response.payload)
            if matched == 0:
                continue
            if matched > TIDE_DISCOVERY_MAX_MATCHES:
                raise ValueError("too many BSH gauges in bounded search")

            total_bytes = 0
            offset = 0
            candidates: dict[str, TideStation] = {}
            while offset < matched:
                page_response = self.tide_http(
                    _tide_query_url(
                        latitude,
                        longitude,
                        radius_km,
                        hits_only=False,
                        limit=min(TIDE_DISCOVERY_PAGE_SIZE, matched - offset),
                        offset=offset,
                    ),
                    MAX_TIDE_DISCOVERY_PAGE_BYTES,
                    None,
                )
                if page_response.status != 200:
                    raise ValueError("unexpected BSH station page response")
                total_bytes += len(page_response.payload)
                if total_bytes > MAX_TIDE_DISCOVERY_TOTAL_BYTES:
                    raise ValueError("BSH station discovery exceeds total size limit")
                stations, returned, page_matched = parse_tide_feature_collection(
                    page_response.payload,
                    current,
                )
                if page_matched != matched or returned <= 0:
                    raise ValueError("BSH station discovery changed during pagination")
                for station in stations:
                    candidates[station.station_id] = station
                offset += returned

            if not candidates:
                continue
            station, distance_km = nearest_tide_station(candidates.values(), latitude, longitude)
            # A rectangular bbox also includes its farther corners. Only stop
            # when the selected point lies inside the current circular radius;
            # otherwise a closer point may still sit just outside this bbox.
            if distance_km <= radius_km + 0.1:
                return station, distance_km
        return None

    @staticmethod
    def _cached_tide_station(value: dict[str, Any]) -> TideStation | None:
        station = value.get("station")
        if not isinstance(station, dict):
            return None
        station_id = str(station.get("id") or "")
        station_name = " ".join(str(station.get("name") or "").split())
        try:
            latitude = float(station.get("latitude"))
            longitude = float(station.get("longitude"))
        except (TypeError, ValueError):
            return None
        if (
            not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,127}", station_id)
            or not station_name
            or not math.isfinite(latitude)
            or not math.isfinite(longitude)
            or not (-90 <= latitude <= 90 and -180 <= longitude <= 180)
        ):
            return None
        return TideStation(station_id, station_name, latitude, longitude)

    def _tides_for_position(self, position: tuple[float, float] | None) -> dict[str, Any] | None:
        current = self.now().astimezone(dt.timezone.utc)
        cached_value = load_json_limited(self.tide_cache_path, MAX_TIDE_CACHE_BYTES) or {}
        if position is None:
            # Tide selection is location-sensitive. A cached weather station or
            # manual DWD override is not evidence that the vehicle is still
            # close to the cached BSH gauge.
            return None

        cached_station = self._cached_tide_station(cached_value)
        cached_station_id = cached_station.station_id if cached_station is not None else ""
        cached_distance = (
            haversine_km(*position, cached_station.latitude, cached_station.longitude)
            if cached_station is not None
            else math.inf
        )
        cached_tides: dict[str, Any] | None = None
        if cached_station is not None and cached_distance <= TIDE_MAX_DISTANCE_KM:
            cached_value = json.loads(json.dumps(cached_value))
            cached_value["station"]["distanceKm"] = round(cached_distance, 1)
            cached_tides = _valid_tide_cache(cached_value, current)

        station: TideStation | None = None
        distance_km = math.inf
        if cached_station is not None and cached_distance <= TIDE_STATION_REUSE_DISTANCE_KM:
            station = cached_station
            distance_km = cached_distance
        elif self._tide_next_attempt is not None and current < self._tide_next_attempt:
            return cached_tides
        else:
            try:
                selected = self._discover_tide_station(position, current)
            except (OSError, ValueError, UnicodeError, urllib.error.URLError):
                self._tide_next_attempt = current + dt.timedelta(seconds=TIDE_RETRY_SECONDS)
                return cached_tides
            if selected is None:
                self._tide_next_attempt = current + dt.timedelta(seconds=TIDE_REFRESH_SECONDS)
                return None
            station, distance_km = selected

        if station is None or distance_km > TIDE_MAX_DISTANCE_KM:
            return None

        cached_updated = parse_time(cached_value.get("updatedUtc"))
        cached_matches = cached_station_id == station.station_id
        if cached_matches:
            # Distance is derived from the current fix. It is safe to update in
            # memory, while exact GPS coordinates are never persisted or logged.
            cached_value = json.loads(json.dumps(cached_value))
            cached_value["station"]["distanceKm"] = round(distance_km, 1)
            cached_tides = _valid_tide_cache(cached_value, current)
        else:
            cached_tides = None

        if (
            cached_tides is not None
            and cached_updated is not None
            and (current - cached_updated).total_seconds() < TIDE_REFRESH_SECONDS
        ):
            return cached_tides
        if self._tide_next_attempt is not None and current < self._tide_next_attempt:
            return cached_tides

        try:
            cached_etag = _safe_etag(cached_value.get("etag")) if cached_matches else None
            response = self.tide_http(
                tide_station_url(station.station_id),
                MAX_TIDE_STATION_BYTES,
                cached_etag,
            )
            if response.status == 304:
                if not cached_matches or cached_tides is None:
                    raise ValueError("BSH returned 304 without a matching valid cache")
                cached_value["updatedUtc"] = iso_utc(current)
                cached_value["etag"] = response.etag or cached_etag
                cached_value["station"].update(
                    {
                        "name": station.name,
                        "latitude": station.latitude,
                        "longitude": station.longitude,
                        "distanceKm": round(distance_km, 1),
                    }
                )
                encoded = _encoded_json(cached_value)
                if len(encoded) > MAX_TIDE_CACHE_BYTES:
                    raise ValueError("normalized BSH tide cache exceeds size limit")
                _atomic_write(self.tide_cache_path, encoded)
                self._tide_next_attempt = None
                return _valid_tide_cache(cached_value, current)
            if response.status != 200:
                raise ValueError("unexpected BSH station response")
            station_name, reference_level, events, curve = parse_tide_station(
                response.payload,
                station.station_id,
                current,
            )
            normalized_cache = {
                "schema": 1,
                "station": {
                    "id": station.station_id,
                    "name": station_name or station.name,
                    "latitude": station.latitude,
                    "longitude": station.longitude,
                    "distanceKm": round(distance_km, 1),
                },
                "updatedUtc": iso_utc(current),
                "referenceLevel": reference_level,
                "events": events,
                "curve": curve,
            }
            if response.etag is not None:
                normalized_cache["etag"] = response.etag
            encoded = _encoded_json(normalized_cache)
            if len(encoded) > MAX_TIDE_CACHE_BYTES:
                raise ValueError("normalized BSH tide cache exceeds size limit")
            _atomic_write(self.tide_cache_path, encoded)
            self._tide_next_attempt = None
            return _valid_tide_cache(normalized_cache, current)
        except (OSError, ValueError, UnicodeError, urllib.error.URLError):
            self._tide_next_attempt = current + dt.timedelta(seconds=TIDE_RETRY_SECONDS)
            return cached_tides

    def _manual_station_id(self) -> str:
        configured = os.environ.get("CAMPER_WEATHER_STATION", "").strip()
        if not configured:
            try:
                configured = _read_limited(
                    self.station_config_path,
                    MAX_STATION_CONFIG_BYTES,
                ).decode("ascii").splitlines()[0].strip()
            except (OSError, IndexError, UnicodeError, ValueError):
                configured = ""
        return configured if re.fullmatch(r"[A-Za-z0-9]{5}", configured) else ""

    def _select_station(
        self,
        stations: list[Station],
        position: tuple[float, float] | None = None,
    ) -> tuple[Station, float | None]:
        manual = self._manual_station_id()
        if manual:
            for station in stations:
                if station.station_id == manual:
                    return station, None
            raise ValueError(f"configured DWD station {manual} is unknown")
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
        position = self.position_reader()
        station, distance = self._select_station(stations, position)
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
        if len(_encoded_json(snapshot)) > MAX_SNAPSHOT_BYTES:
            raise ValueError("normalized weather snapshot exceeds size limit")
        tides = self._tides_for_position(position)
        if tides is not None:
            candidate = dict(snapshot)
            candidate["tides"] = tides
            if len(_encoded_json(candidate)) <= MAX_SNAPSHOT_BYTES:
                snapshot = candidate
            elif "curve" in tides:
                compact_tides = dict(tides)
                compact_tides.pop("curve", None)
                candidate["tides"] = compact_tides
                if len(_encoded_json(candidate)) <= MAX_SNAPSHOT_BYTES:
                    snapshot = candidate
        save_json(self.cache_path, snapshot)
        return snapshot
