#!/usr/bin/env python3
"""Growing Degree Days calculator.

GDD = max(((high_F + low_F) / 2) - 50, 0)

Sums GDD from January 1 of the current year through yesterday for a
given locale. Uses the free Open-Meteo APIs (no API key required).
"""

import argparse
import json
import sys
from datetime import date, timedelta
from urllib.parse import urlencode
from urllib.request import urlopen

GEOCODE_URL = "https://geocoding-api.open-meteo.com/v1/search"
ARCHIVE_URL = "https://archive-api.open-meteo.com/v1/archive"
FORECAST_URL = "https://api.open-meteo.com/v1/forecast"
BASE_TEMP_F = 50.0


def fetch_json(url, params):
    full = f"{url}?{urlencode(params)}"
    with urlopen(full, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))


def geocode(locale):
    data = fetch_json(GEOCODE_URL, {"name": locale, "count": 1, "format": "json"})
    results = data.get("results") or []
    if not results:
        raise SystemExit(f"Could not find location: {locale!r}")
    r = results[0]
    label_parts = [r.get("name"), r.get("admin1"), r.get("country")]
    label = ", ".join(p for p in label_parts if p)
    return r["latitude"], r["longitude"], label


def fetch_daily_temps(lat, lon, start, end):
    """Return list of (date_str, tmax_f, tmin_f) covering [start, end].

    Open-Meteo's archive API lags by ~5 days, so use the forecast API's
    past_days parameter to fill recent gaps.
    """
    today = date.today()
    archive_end = min(end, today - timedelta(days=6))
    days = {}

    if archive_end >= start:
        data = fetch_json(ARCHIVE_URL, {
            "latitude": lat,
            "longitude": lon,
            "start_date": start.isoformat(),
            "end_date": archive_end.isoformat(),
            "daily": "temperature_2m_max,temperature_2m_min",
            "temperature_unit": "fahrenheit",
            "timezone": "auto",
        })
        d = data.get("daily") or {}
        for day, hi, lo in zip(d.get("time", []), d.get("temperature_2m_max", []),
                               d.get("temperature_2m_min", [])):
            days[day] = (hi, lo)

    if end > archive_end:
        past_days = (today - start).days
        past_days = max(1, min(past_days, 92))
        data = fetch_json(FORECAST_URL, {
            "latitude": lat,
            "longitude": lon,
            "daily": "temperature_2m_max,temperature_2m_min",
            "temperature_unit": "fahrenheit",
            "timezone": "auto",
            "past_days": past_days,
            "forecast_days": 1,
        })
        d = data.get("daily") or {}
        for day, hi, lo in zip(d.get("time", []), d.get("temperature_2m_max", []),
                               d.get("temperature_2m_min", [])):
            day_obj = date.fromisoformat(day)
            if start <= day_obj <= end and day not in days:
                days[day] = (hi, lo)

    return sorted((day, hi, lo) for day, (hi, lo) in days.items())


def compute_gdd(daily):
    total = 0.0
    rows = []
    for day, hi, lo in daily:
        if hi is None or lo is None:
            rows.append((day, hi, lo, None))
            continue
        gdd = max(((hi + lo) / 2.0) - BASE_TEMP_F, 0.0)
        total += gdd
        rows.append((day, hi, lo, gdd))
    return total, rows


def main():
    p = argparse.ArgumentParser(description="Growing Degree Days since Jan 1.")
    p.add_argument("locale", help="City name, e.g. 'Madison, WI' or 'Paris'")
    p.add_argument("--verbose", "-v", action="store_true",
                   help="Print per-day high/low/GDD")
    args = p.parse_args()

    today = date.today()
    start = date(today.year, 1, 1)
    end = today - timedelta(days=1)
    if end < start:
        raise SystemExit("No completed days yet this year.")

    lat, lon, label = geocode(args.locale)
    daily = fetch_daily_temps(lat, lon, start, end)
    if not daily:
        raise SystemExit("No temperature data returned.")

    total, rows = compute_gdd(daily)

    if args.verbose:
        print(f"{'date':<12}{'high°F':>8}{'low°F':>8}{'GDD':>8}")
        for day, hi, lo, gdd in rows:
            hi_s = f"{hi:.1f}" if hi is not None else "  n/a"
            lo_s = f"{lo:.1f}" if lo is not None else "  n/a"
            gdd_s = f"{gdd:.1f}" if gdd is not None else "  n/a"
            print(f"{day:<12}{hi_s:>8}{lo_s:>8}{gdd_s:>8}")
        print()

    print(f"Location:        {label} ({lat:.4f}, {lon:.4f})")
    print(f"Period:          {rows[0][0]} through {rows[-1][0]} ({len(rows)} days)")
    print(f"Growing Degree Days (base 50°F): {total:.1f}")


if __name__ == "__main__":
    main()
