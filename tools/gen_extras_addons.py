#!/usr/bin/env python3
"""Write the map-reference and hazards addons.

    python3 tools/gen_extras_addons.py

Two of the services these use — the Census Bureau's TIGERweb and the NHC's
tropical map service — are ArcGIS WMS servers, which name layers by number,
and the numbers move when a layer is added (a new year's districts, a sixth
storm slot). So they are looked up here by title from each server's
GetCapabilities, and a run fails loudly if a title has gone, rather than the
app quietly drawing the wrong layer.

Writes docs/addons/catalog/map-layers.json and docs/addons/catalog/hazards.json.
"""

import json
import re
import sys
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "docs/addons/catalog"
AUTHOR = "Taa'a Yuku Radar"

TIGER = (
    "https://tigerweb.geo.census.gov/arcgis/services/TIGERweb/"
    "tigerWMS_Current/MapServer/WMSServer"
)
NHC = (
    "https://mapservices.weather.noaa.gov/tropical/services/tropical/"
    "NHC_tropical_weather/MapServer/WMSServer"
)
ESRI = "https://server.arcgisonline.com/ArcGIS/rest/services"

WMS_NS = {"w": "http://www.opengis.net/wms"}


def layers_by_title(url):
    """Every named layer on a WMS server, as title → name."""
    req = urllib.request.Request(
        f"{url}?SERVICE=WMS&REQUEST=GetCapabilities",
        headers={"User-Agent": "taa-yuku-radar tools"},
    )
    with urllib.request.urlopen(req, timeout=60) as f:
        root = ET.fromstring(f.read())
    out = {}
    for layer in root.iter(f"{{{WMS_NS['w']}}}Layer"):
        name = layer.find("w:Name", WMS_NS)
        title = layer.find("w:Title", WMS_NS)
        if name is not None and title is not None and name.text and title.text:
            out[title.text.strip()] = name.text.strip()
    return out


def need(table, title, where):
    if title not in table:
        sys.exit(f"{where} has no layer titled {title!r} any more")
    return table[title]


def map_layers():
    tiger = layers_by_title(TIGER)
    return {
        "id": "map-layers",
        "name": "Map reference layers",
        "version": "1",
        "author": AUTHOR,
        "description": (
            "County and state lines, town names and roads drawn over the "
            "radar, so you can tell which county a storm is in without "
            "switching basemaps. Hillshade under it, for terrain. Each is "
            "its own switch in Layers."
        ),
        "format": 1,
        "overlays": [
            {
                "id": "counties",
                "name": "County lines (US)",
                "type": "wms",
                "url": TIGER,
                "layers": need(tiger, "Counties", "TIGERweb"),
                "bounds": [17, -180, 72, -64],
                "minZoom": 5,
                "above": True,
                "opacity": 0.9,
                "attribution": "Boundaries: US Census Bureau TIGERweb",
            },
            {
                "id": "states",
                "name": "State lines (US)",
                "type": "wms",
                "url": TIGER,
                "layers": need(tiger, "States", "TIGERweb"),
                "bounds": [17, -180, 72, -64],
                "above": True,
                "attribution": "Boundaries: US Census Bureau TIGERweb",
            },
            {
                "id": "labels",
                "name": "Place names",
                "type": "tiles",
                "url": f"{ESRI}/Canvas/World_Dark_Gray_Reference/MapServer/tile/{{z}}/{{y}}/{{x}}",
                "above": True,
                "attribution": "Labels © Esri, HERE, Garmin, © OpenStreetMap contributors",
            },
            {
                "id": "roads",
                "name": "Roads",
                "type": "tiles",
                "url": f"{ESRI}/Reference/World_Transportation/MapServer/tile/{{z}}/{{y}}/{{x}}",
                "minZoom": 6,
                "above": True,
                "opacity": 0.7,
                "visible": False,
                "attribution": "Roads © Esri, HERE, Garmin, © OpenStreetMap contributors",
            },
            {
                "id": "hillshade",
                "name": "Hillshade",
                "type": "tiles",
                "url": f"{ESRI}/Elevation/World_Hillshade_Dark/MapServer/tile/{{z}}/{{y}}/{{x}}",
                "opacity": 0.35,
                "visible": False,
                "attribution": "Hillshade © Esri",
            },
        ],
    }


def hazards():
    nhc = layers_by_title(NHC)
    # Every storm slot's cone, track and watches/warnings. Most are empty
    # most of the time; an empty layer draws nothing and costs one small
    # transparent tile.
    want = ("Forecast Cone", "Forecast Track", "Watch-Warning")
    storm = re.compile(r"^(AT|EP|CP)\d ")
    names = [
        nhc[t]
        for t in sorted(nhc)
        if storm.match(t) and t.endswith(want)
    ]
    if len(names) < 15:
        sys.exit(f"only {len(names)} NHC storm layers — has the service changed?")
    return {
        "id": "hazards",
        "name": "Hurricanes, wildfires and earthquakes",
        "version": "1",
        "author": AUTHOR,
        "description": (
            "The NHC's forecast cones, tracks and coastal watches for every "
            "active tropical storm; the perimeters of large US wildfires; "
            "and earthquakes of magnitude 2.5 and up in the last day. Each "
            "refreshes on its own and is its own switch in Layers."
        ),
        "format": 1,
        "overlays": [
            {
                "id": "tropical",
                "name": "Tropical storms (NHC cones)",
                "type": "wms",
                "url": NHC,
                "layers": ",".join(names),
                "above": True,
                "opacity": 0.85,
                "refreshMinutes": 30,
                "attribution": "Tropical: NOAA National Hurricane Center",
            },
            {
                "id": "wildfires",
                "name": "Wildfire perimeters (US, 1000+ acres)",
                "type": "geojson",
                "url": (
                    "https://services3.arcgis.com/T4QMspbfLg3qTGWY/arcgis/rest/"
                    "services/WFIGS_Interagency_Perimeters_Current/FeatureServer/0/"
                    "query?where=attr_IncidentSize%3E%3D1000"
                    "&outFields=poly_IncidentName,attr_IncidentSize,"
                    "attr_PercentContained&outSR=4326&f=geojson"
                    "&maxAllowableOffset=0.002&geometryPrecision=4"
                ),
                "label": "poly_IncidentName",
                # The feed carries every unburned island as its own ring —
                # thousands of them. Anything under ~half a km goes.
                "simplify": 150,
                "stroke": "#FF6D00",
                "fill": "#FF6D0040",
                "width": 1.5,
                "above": True,
                "refreshMinutes": 30,
                "attribution": "Wildfires: NIFC WFIGS",
            },
            {
                "id": "earthquakes",
                "name": "Earthquakes (M2.5+, past day)",
                "type": "geojson",
                "url": "https://earthquake.usgs.gov/earthquakes/feed/v1.0/summary/2.5_day.geojson",
                "label": "title",
                "stroke": "#FFEB3B",
                "above": True,
                "refreshMinutes": 5,
                "attribution": "Earthquakes: USGS",
            },
        ],
    }


def write(name, addon):
    path = ASSETS / name
    path.write_text(json.dumps(addon, indent=2, ensure_ascii=False) + "\n")
    print(f"wrote {path}")


def main():
    ASSETS.mkdir(parents=True, exist_ok=True)
    write("map-layers.json", map_layers())
    write("hazards.json", hazards())


if __name__ == "__main__":
    main()
