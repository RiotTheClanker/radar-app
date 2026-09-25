# The open radar format

A plain file format for getting radar data onto the map **with your own
parser**. The app ships decoders for NEXRAD Level 2, Level 3 and MRMS, and
nothing else. If your data is anything else — a research radar, a
different network, a vendor format, your own processing — you write a small
converter in whatever language you like, have it write this format, and
point an addon at the output. The app does the rest: rendering at any zoom,
colour keys, imported `.pal` palettes, the aiming cursor, loops and replay.

A reference writer is in
[`tools/open_format/radar_open.py`](../tools/open_format/radar_open.py)
(standard library only). A working example addon that reads local files is in
[`addons/examples/open-radar/`](addons/examples/open-radar/).

## The file

One JSON object. It can be gzipped (`.json.gz`), which the app detects on
its own, and for real sweeps it should be.

Every file has:

| Field | |
|---|---|
| `format` | Always `"radar-open"` |
| `version` | `1` |
| `kind` | `"polar"` (a sweep from a radar) or `"grid"` (values on a lat/lon grid) |
| `time` | Scan time, UTC: ISO 8601 (`"2026-07-28T05:37:15Z"`) or Unix seconds |
| `product` | What the values are. Picks the colour palette — see below |
| `unit` | Optional. Shown in the key and the cursor readout |
| `name` | Optional. A display name |
| `colors` | Optional. Your own colour scale, which replaces the palette |

Then the values, as either `values` or `packed` (see [Values](#values)).

### Polar

A sweep: radials going round from a site, each a row of gates going out.

```json
{
  "format": "radar-open", "version": 1, "kind": "polar",
  "site": { "lat": 35.333, "lon": -97.278 },
  "time": "2026-07-28T05:37:15Z",
  "product": "reflectivity",
  "elevationDeg": 0.5,
  "firstGateM": 2125,
  "gateSizeM": 250,
  "gates": 1832,
  "azimuths": [0.0, 0.5, 1.0, ...],
  "values": [[...1832 gates...], [...], ...]
}
```

| Field | |
|---|---|
| `site.lat`, `site.lon` | Where the radar is, degrees |
| `elevationDeg` | Tilt of the sweep (default 0.5). Used for beam height |
| `firstGateM` | Range to the **centre** of the first gate, metres |
| `gateSizeM` | Gate spacing, metres |
| `gates` | Gates per radial |
| `azimuths` | Start azimuth of each radial, degrees clockwise from north, in the order the values are |
| — or `radials`, `azimuthStart`, `azimuthStep` | Evenly spaced radials instead of a list (step defaults to 360 / radials) |
| `beamWidthDeg` | How wide each radial is drawn (default 360 / radials, at most 2°) |

Values run radial by radial: all of radial 0's gates, then radial 1's.
Gaps of up to 2° between radials are filled from the nearer radial, so
azimuth jitter does not draw spokes. A radar that did not look somewhere
(sector blanking) leaves a hole, as it should.

### Grid

Values on a regular latitude/longitude grid: a mosaic, a rainfall analysis,
anything that is not one radar's sweep.

```json
{
  "format": "radar-open", "version": 1, "kind": "grid",
  "north": 36.0, "south": 34.9, "east": -96.8, "west": -98.0,
  "nx": 800, "ny": 600,
  "time": "2026-07-28T05:40:00Z",
  "product": "precipitation", "unit": "in",
  "values": [...]
}
```

`nx` columns west to east, `ny` rows **north to south** — row 0 is the
northern edge. Cells are equal steps of latitude and longitude.

A grid has no radar, so the cursor readout gives the value and position
rather than range and beam height.

### Values

**`values`** — a JSON array of numbers, `null` for no data. Flat, or one
nested list per radial / row (what numpy's `tolist()` writes). Simple, and
fine for small data.

**`packed`** — base64 of little-endian binary. Much smaller:

```json
"packed": {
  "type": "u8",
  "base64": "AAoUHigy...",
  "scale": 0.5,
  "offset": -32,
  "nodata": 255
}
```

| Field | |
|---|---|
| `type` | `u8`, `u16`, `i16` or `f32` |
| `scale`, `offset` | value = raw × scale + offset (defaults 1 and 0) |
| `nodata` | Raw value meaning no data. `NaN` is always no data for `f32` |

With numpy: `base64.b64encode(arr.astype('<u2').tobytes())`.

Either way the count must equal the dimensions (`radials × gates`, or
`nx × ny`), or the file is refused with a message saying how many were
expected.

### Product and colours

`product` picks the palette the app draws with — the same one NEXRAD data
of that kind gets, including any `.pal` the user has imported:

| `product` | Palette |
|---|---|
| `reflectivity` (`ref`, `dbz`) | reflectivity |
| `velocity` (`vel`) | velocity |
| `spectrum_width` (`sw`) | spectrum width |
| `zdr` | differential reflectivity |
| `cc` (`rhohv`) | correlation coefficient |
| `kdp` | specific differential phase |
| `hydro_class` (`hca`) | hydrometeor classes; values are class numbers |
| `precipitation` (`precip`, `rain`) | precipitation |
| `vil`, `echo_tops`, `rotation` | as named |
| anything else | reflectivity, unless the file brings `colors` |

For data no radar palette fits — soil moisture, a lightning density, a model
field — include your own scale:

```json
"colors": {
  "stops": [[0.05, "#9EE6FF"], [0.5, "#2E7DFF"], [1.5, "#1BC41B"], [3.0, "#FF3B30"]],
  "interpolate": true
}
```

Values below the first stop are transparent. `#RRGGBBAA` sets alpha.

## Pointing an addon at it

An addon site with an `open` source reads these files for **every** product
it shows. `{product}` becomes the app's short product code, the one on the
toolbar — `REF`, `VEL`, `ZDR`, `CC`, `KDP`, `HCA`, `STP`, `CREF`, `VIL`, `ET`,
`SW`, `SRM`, `ROT` — and `{tilt}` becomes the tilt number, 1–4.

```json
"sites": [
  {
    "id": "XOKC", "name": "Club radar", "lat": 35.40, "lon": -97.60,
    "open": {
      "type": "folder",
      "path": "~/radar/out/{product}/{tilt}",
      "match": "\\.json(\\.gz)?$"
    }
  }
]
```

The source can be any of the addon source types:

- **`folder`** — a folder on this device. `path` is absolute, under `~/`, or
  relative to the addon's folder. Files are only ever read and decoded, never
  sent anywhere. A folder that does not exist yet is an empty listing, not an
  error.
- **`index`** — a URL that lists the files (JSON, text, or a web server's
  directory listing).
- **`s3`** — an S3-compatible bucket.

See [addons.md](addons.md#sources) for the templates, `match`, `headers` and
`days`.

Files are ordered, and replay finds its moment, by the time in the file
name (`…20260728_053715…` and the usual shapes). For a local folder, a file
whose name has no time falls back to when it was written.

Products with no files show "no REF files from XOKC's open source" — so a
site can serve only the products it has.

## What does not work on open data

- **Future radar** (the nowcast) reads NEXRAD and MRMS encodings only.
- **3D** needs a full Level 2 volume.
- **Storm tracks** are NOAA's own product and need Level 3 from NOAA.

## Keeping it working

The engine side is `rust/radar_core/src/open_format.rs`; its tests render the
example addon's files through the same API calls the app makes, so the
reference writer and the reader cannot drift apart unnoticed. A new field is
added there, documented here, and written by `radar_open.py`.
