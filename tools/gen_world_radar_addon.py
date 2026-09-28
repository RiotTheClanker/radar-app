#!/usr/bin/env python3
"""Write the built-in "radar beyond the US" addon.

    python3 tools/gen_world_radar_addon.py

Downloads EUMETNET's OPERA radar database — every weather radar in Europe's
network, with its position and status — and writes
app/assets/addons/world-radar.json: the national radar mosaics that have an
open, keyless WMS, plus a marker for each operational European radar.

The app decodes NEXRAD, not the HDF5 (ODIM) other services publish their
per-radar volumes in, so what it can show of another country's weather is
that country's own rendered mosaic. The markers say where the radars are, so
a gap in a mosaic can be told from a radar that is down.
"""

import json
import sys
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "app/assets/addons/world-radar.json"
OPERA = (
    "https://www.eumetnet.eu/wp-content/themes/aeron-child/"
    "observations-programme/current-activities/opera/database/"
    "OPERA_Database/OPERA_RADARS_DB.json"
)

# Each checked by hand to answer GetMap in EPSG:3857 with no key, and to
# draw echoes rather than a grey placeholder. `bounds` keeps a layer from
# being asked for tiles over countries it has nothing for.
OVERLAYS = [
    {
        "id": "canada-rain",
        "name": "Canada — radar (rain)",
        "type": "wms",
        "url": "https://geo.weather.gc.ca/geomet",
        "layers": "RADAR_1KM_RRAI",
        "bounds": [40, -145, 72, -50],
        "attribution": "Radar © Environment and Climate Change Canada",
    },
    {
        "id": "canada-snow",
        "name": "Canada — radar (snow)",
        "type": "wms",
        "url": "https://geo.weather.gc.ca/geomet",
        "layers": "RADAR_1KM_RSNO",
        "bounds": [40, -145, 72, -50],
        "visible": False,
        "attribution": "Radar © Environment and Climate Change Canada",
    },
    {
        "id": "canada-coverage",
        "name": "Canada — radar coverage",
        "type": "wms",
        "url": "https://geo.weather.gc.ca/geomet",
        "layers": "RADAR_COVERAGE_BLUE-OUTLINE",
        "bounds": [40, -145, 72, -50],
        "above": True,
        "visible": False,
        "refreshMinutes": 0,
        "attribution": "Radar © Environment and Climate Change Canada",
    },
    {
        "id": "germany",
        "name": "Germany — radar (DWD)",
        "type": "wms",
        "url": "https://maps.dwd.de/geoserver/dwd/wms",
        "layers": "dwd:Niederschlagsradar",
        "bounds": [46, 2, 56.5, 17.5],
        "attribution": "Radar © Deutscher Wetterdienst",
    },
    {
        "id": "netherlands",
        "name": "Netherlands — radar (KNMI)",
        "type": "wms",
        "url": "https://geoservices.knmi.nl/adagucserver?dataset=RADAR",
        "layers": "RAD_NL25_PCP_CM",
        "styles": "precip-rainbow",
        "bounds": [49, -0.5, 56.5, 11],
        "attribution": "Radar © KNMI (CC BY 4.0)",
    },
    {
        "id": "finland",
        "name": "Finland — radar (FMI)",
        "type": "wms",
        "url": "https://openwms.fmi.fi/geoserver/wms",
        "layers": "Radar:suomi_dbz_eureffin",
        "bounds": [57, 16, 71.5, 35],
        "attribution": "Radar © Finnish Meteorological Institute (CC BY 4.0)",
    },
]


def station(r):
    band = r.get("band") or "?"
    pol = {"D": "dual-pol", "S": "single-pol"}.get(r.get("polarization"), "")
    parts = [f"{band}-band"]
    if r.get("doppler") == "Y":
        parts.append("Doppler")
    if pol:
        parts.append(pol)
    if r.get("maxrange"):
        parts.append(f"range {r['maxrange']} km")
    if r.get("startyear"):
        parts.append(f"since {r['startyear']}")
    notes = ", ".join(parts)
    if r.get("odimcode"):
        notes += f". ODIM id {r['odimcode']}"
    return {
        "name": f"{r['location']}, {r['country']}",
        "lat": round(float(r["latitude"]), 4),
        "lon": round(float(r["longitude"]), 4),
        "notes": notes,
    }


def main():
    req = urllib.request.Request(OPERA, headers={"User-Agent": "taa-yuku-radar tools"})
    with urllib.request.urlopen(req, timeout=60) as f:
        radars = json.load(f)
    # Status 1 is operational; 0 is retired or not yet running.
    live = [r for r in radars if r.get("status") == "1"]
    stations = sorted(
        (station(r) for r in live if r.get("latitude") and r.get("longitude")),
        key=lambda s: s["name"],
    )
    if len(stations) < 100:
        sys.exit(f"only {len(stations)} stations — has the OPERA format changed?")

    addon = {
        "id": "builtin.world-radar",
        "name": "Radar beyond the US",
        "version": "1",
        "author": "Taa'a Yuku Radar",
        "description": (
            "National radar mosaics from Canada, Germany, the Netherlands and "
            "Finland, drawn as map layers, and a marker for every operational "
            "radar in Europe's OPERA network. These are the services' own "
            "images — the cursor and colour key read the US radars only."
        ),
        "format": 1,
        "enabled": False,
        "overlays": [
            {"opacity": 0.8, "refreshMinutes": 5, **o} for o in OVERLAYS
        ],
        "places": [
            {
                "id": "opera",
                "name": "European weather radars (OPERA)",
                "icon": "tower",
                "color": "#9FD3FF",
                "items": stations,
            }
        ],
    }
    OUT.parent.mkdir(parents=True, exist_ok=True)
    OUT.write_text(json.dumps(addon, indent=2, ensure_ascii=False) + "\n")
    print(f"wrote {OUT}: {len(OVERLAYS)} mosaics, {len(stations)} stations")


if __name__ == "__main__":
    main()
