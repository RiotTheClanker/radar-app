# Data sources

Every byte the app pulls from the outside world, and from where. All of it is
free, keyless and public. There is no account, no API key and no server of
ours anywhere in this list.

Useful in two situations: reimplementing the fetch layer in another stack, and
working out which upstream broke when something stops appearing.

## Rules the fetch layer follows

- **Fetchers do not decode.** They return bytes. Decoding is the engine's job
  — see [engine-api.md](engine-api.md).
- **Identify yourself.** `lib/data/identity.dart` builds one User-Agent —
  `taa-yuku-radar/<version> (+<repo url>)` — from the app name, version and
  URL. api.weather.gov and the OSM tile servers both ask clients to say who
  they are and how to reach them, and both will block anonymous abuse. Use
  `userAgentHeader` on anything hitting a `.gov` or a community tile server.
- **Everything is time-boxed.** Requests carry explicit timeouts (6–20 s
  depending on payload). A stalled fetch must not wedge the UI.
- **Don't fetch the same thing twice.** `WorkspaceState`'s `VolumeCache` and
  `Coalescer` collapse duplicate in-flight requests across panes.

## Radar

| Source | Endpoint | Shape | Cadence |
|---|---|---|---|
| **NEXRAD Level 2** | `unidata-nexrad-level2.s3.amazonaws.com` | Archive II, bzip2-chunked. Keys: `2026/07/28/KTLX/KTLX20260728_053715_V06` | One volume per 4–10 min, available ~2 min after the scan completes. 5–15 MB each |
| **NEXRAD Level 3** | `unidata-nexrad-level3.s3.amazonaws.com` | One product per file. Keys: `TLX_N0B_2026_07_28_05_09_07` | Per elevation scan. Small |
| **MRMS mosaic** | `noaa-mrms-pds.s3.amazonaws.com`, product `CONUS/MergedReflectivityQCComposite_00.50` | gzipped GRIB2, whole CONUS in one grid | ~2 min |

All three are plain anonymous S3: `?list-type=2&prefix=…&max-keys=1000`
returns an XML key listing in ascending time order, so the newest frames are
at the end of the list. Level 2 and Level 3 listings walk backwards a day at
a time, because a radar in maintenance can be quiet for a while.

**Historical replay** is the same buckets with an older prefix — which is why
replay reaches back to 1991 without any special-casing.

## Warnings and outlooks

| Source | Endpoint | Notes |
|---|---|---|
| **NWS active alerts** | `api.weather.gov/alerts/active?status=actual` | GeoJSON. Polled every 60 s. Category (warning / watch / advisory) is derived from the event name — the NWS does not label it directly |
| **County-issued alerts** | `api.weather.gov` zone lookups | Alerts with no polygon. Outlines are resolved **only** for switched-on categories; resolving every zone nationwide would be hundreds of requests for shapes nobody asked to see |
| **SPC convective outlook** | `spc.noaa.gov/products/outlook/day{1,2,3}otlk_cat.nolyr.geojson` | Categorical areas |
| **SPC storm reports** | `spc.noaa.gov/climo/reports/today.csv` | Today's local storm reports |

## Lightning

| Source | Endpoint | Notes |
|---|---|---|
| **Blitzortung** | `wss://ws1/ws7/ws8.blitzortung.org` | Websocket. Connect, send `{"a": 111}`, receive LZW-compressed JSON, one strike per message. Community network, **free for non-commercial use, and credited in the UI** — that attribution is a condition, not decoration. Reconnects with backoff across the three hosts |
| **GOES GLM** | `noaa-goes19` (East) and `noaa-goes18` (West) S3 buckets | 20-second LCFA files, polled every 30 s, ~1–2 min behind real time, Americas coverage. netCDF/HDF5 — parsed by the engine's own HDF5 subset reader, not libhdf5 |

Strikes are aged out at 20 minutes and the map is repainted on a 2-second
timer rather than per strike, since a busy night delivers them faster than
anyone can see.

## Surface observations

| Source | Endpoint | Notes |
|---|---|---|
| **METAR** | `aviationweather.gov/api/data/metar?bbox=…&format=json` | Current surface observations: temperature, dewpoint, wind, gust, altimeter setting, station elevation, all in one record. Keyless. Takes a bounding box, which is what makes one request enough — the app asks for CONUS once and shares it across panes. Polled every 10 minutes; routine METARs are hourly with specials between, so faster only refetches the same readings |

Two fields are **not the type they look like**, and a plain cast throws on
ordinary weather: `wdir` is the string `"VRB"` when the wind will not sit
still, and `visib` is `"10+"` when it is unlimited. `readNum` in
`lib/data/surface_obs.dart` exists for that, and anything unparseable becomes
"not reported" rather than a number nobody measured.

`altim` is the **altimeter setting**, not true mean-sea-level pressure — the
reduction uses the standard atmosphere rather than the column's real
temperature. Fine to plot and to compare between neighbours; not the right
input for an MSLP analysis without correcting it first.

CONUS-only, which matches the MRMS mosaic — so this is an existing coverage
edge rather than a new one.

## Model fields

| Source | Endpoint | Notes |
|---|---|---|
| **HRRR** | `noaa-hrrr-bdp-pds.s3.amazonaws.com/hrrr.YYYYMMDD/conus/hrrr.tHHz.wrfsfcf00.grib2` | Hourly 3 km CONUS model. Currently surface CAPE; CIN, 0-1/0-6 km shear and storm-relative helicity are in the same file |

**Never fetch the whole file.** It is around 130 MB and carries 170 fields.
Beside it sits a `.idx` sidecar — a few kilobytes of text naming each field's
byte offset — so one field is an HTTP range request: about **800 KB** for
CAPE, a fifth of one Level 2 volume. `lib/data/hrrr_fetcher.dart` does this;
a `200` response instead of a `206` means the range was ignored and is
refused rather than accepted.

**Match the level, not just the parameter.** The file holds three CAPE
records — surface, and mixed-layer over 180-0 mb and 90-0 mb. They are
different numbers in the same units, so a loose match draws one and labels it
the other with nothing reporting an error.

> **This is the only source here that is not a measurement.** Everything else
> was seen by an instrument. A forecast drawn at the same apparent confidence
> as a radar return, beside live warnings, will be read as an observation —
> so a model layer names the model and its run time on screen whenever it is
> on. See invariant 14 in [ui-contract.md](ui-contract.md).

Decoding it needed a GRIB2 reader the MRMS one could not provide — Lambert
Conformal grids and complex packing rather than lat/lon and PNG. See
[engine-api.md](engine-api.md).

## Soundings

| Source | Endpoint | Notes |
|---|---|---|
| **SPC observed** | `spc.noaa.gov/exper/soundings/{stamp}_OBS/` | Primary. One small text file per launch, on a host already in use |
| **rucsoundings** | `rucsoundings.noaa.gov/get_soundings.cgi` | Fallback, different text format |

Deliberately **not** IGRA, NOAA's authoritative radiosonde archive: it ships a
station's whole history as one zip (80 MB for Norman) and lags days. Right
for research, wrong for "what went up tonight". Indices — CAPE, CIN, LI,
LCL/LFC/EL, PW, shear, SRH — are all computed on-device in
`lib/data/sounding_indices.dart`.

## Map and terrain

| Source | Endpoint | Attribution required |
|---|---|---|
| CARTO Dark | `basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png` | `© OpenStreetMap © CARTO` |
| OpenStreetMap | `tile.openstreetmap.org/{z}/{x}/{y}.png` | `© OpenStreetMap contributors` |
| Esri Satellite | `server.arcgisonline.com/.../World_Imagery/MapServer/tile/{z}/{y}/{x}` | `Imagery © Esri` |
| OpenTopoMap | `tile.opentopomap.org/{z}/{x}/{y}.png` | `© OpenStreetMap © OpenTopoMap (CC-BY-SA)` |
| AWS Terrain Tiles | `s3.amazonaws.com/elevation-tiles-prod/terrarium/{z}/{x}/{y}.png` | Free open dataset |

**The attribution is a licensing requirement, not a UI preference.** Whatever
the new UI looks like, the active basemap's credit has to be visible on
screen, together with `NOAA/NWS` and — when that source is on —
`lightning © Blitzortung.org`.

Terrain tiles are "terrarium" PNGs packing metres above sea level across the
three colour channels. That encoding **cannot be resampled as an image**:
blending two colours does not blend two heights, and every 256 m boundary in
the red channel comes out as a spike. Decode to heights first, resample
after. `lib/data/terrain_tiles.dart` does; anything reimplementing it must
too.

Basemap tiles are also stitched into a single north-up image for the 3D
ground plane (`lib/data/basemap_tiles.dart`), which is why `Volume3DScreen`
needs a `basemapUrl`.

## Location

GPS via `geolocator` where the device has it and permission is granted;
`ipapi.co/json/` as a fallback. The two are **not** interchangeable — IP
geolocation on a phone resolves the carrier's gateway, which can be a
different city — so it is a last resort that only sets the initial radar site.

Nothing is requested at startup, and the app works fine with location
refused: it opens on the default site.

## Local files

Not network, but part of the data layer (`lib/data/user_files.dart`), plain
paths with no plugins so all three platforms behave the same:

| What | Where |
|---|---|
| Imported `.pal` colour tables | `~/.config/taa-yuku-radar/palettes/` (app data dir on Android) |
| PNG snapshots | `~/Pictures/taa-yuku-radar/` |

## Etiquette

These are public goods and none of them bills us. Keep it that way:

- Cache and coalesce. Four panes on one storm should not be four downloads.
- Poll no faster than the data updates — 2 minutes for MRMS, 4–10 for a
  Level 2 volume. Faster only fetches the same file again.
- Send the User-Agent on `.gov` and community endpoints.
- Back off on failure rather than retrying tightly.
- The engine never fetches. Keep it that way, so a caller can always see and
  control what goes over the wire.
