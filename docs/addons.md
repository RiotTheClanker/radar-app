# Addons

An addon is a JSON file that adds things the app does not ship for everyone:
**radar sites** (with their own data source — a bucket, a web listing, or a
folder on this device, and in NEXRAD or in [your own parser's
output](open-format.md)), **map overlays**, **ground locations**, **themes**,
and **colour tables**. It is for the niche uses — a
county's roads and shelters, a university radar nobody put on AWS, a chase
team's own tile server, a red night-vision theme.

An addon is data, never code. Nothing in one runs; the worst a bad addon can
do is point at a URL that does not answer.

Working examples are in [addons/examples/](addons/examples/).

## Installing

**From a link.** Tools → Addons… → paste a link to the `.json` → Install. It
is checked before anything is saved, and installing the same addon again
replaces it — which is how an update is done.

**By hand.** Drop files into the addons folder:

| Platform | Folder |
|---|---|
| Linux | `~/.config/taa-yuku-radar/addons/` |
| Windows | `%USERPROFILE%\.config\taa-yuku-radar\addons\` |
| Android | the app's data directory, `.config/taa-yuku-radar/addons/` |

The folder is shown at the bottom of the Addons dialog. Either of these is an
addon:

- a single file, `anything.json`
- a folder holding an `addon.json`, plus the files it refers to (GeoJSON, CSV,
  `.pal`)

Press ↻ in the Addons dialog after changing files. Each addon has a switch,
and anything the loader skipped is listed under it with the reason.

## The manifest

```json
{
  "id": "okc-spotters",
  "name": "OKC spotter pack",
  "version": "1.0",
  "author": "Central OK Spotters",
  "description": "Club radar, county roads, shelters.",
  "homepage": "https://example.org",
  "format": 1,

  "sites":    [ ... ],
  "overlays": [ ... ],
  "places":   [ ... ],
  "themes":   [ ... ],
  "palettes": [ "palettes/BR.pal" ]
}
```

Only `id` and `name` are required. `id` is letters, digits, `.`, `-` and
`_`; it names the file an installed addon is saved as, and it is what the
app remembers your choices by, so keep it stable across versions.

A mistake in one item skips that item with a warning, and the rest of the
addon still loads. A file that is not JSON, or has no `id`/`name`, is listed
as an error.

### Colours

`#RGB`, `#RRGGBB`, or `#RRGGBBAA` — alpha **last**, the way CSS writes it.

### Files

`file` paths are relative to the addon's folder, and must stay inside it:
`..`, absolute paths and drive letters are refused. An addon installed from a
link is a single file with no folder, so it has to reach everything by `url`.

## Radar sites

```json
"sites": [
  {
    "id": "XOKC",
    "name": "Club radar",
    "state": "OK",
    "lat": 35.40, "lon": -97.60, "elevFt": 1200,
    "shortId": "OKC",
    "attribution": "Radar data © Central OK Spotters",
    "level2": {
      "type": "s3",
      "url": "https://club-radar.s3.amazonaws.com",
      "prefix": "{yyyy}/{MM}/{dd}/{site}/",
      "match": "_V06$"
    },
    "level3": {
      "type": "index",
      "url": "https://example.org/radar/{site3}/{product}/",
      "headers": { "Authorization": "Bearer …" }
    }
  }
]
```

| Field | |
|---|---|
| `id` | Required. Upper-cased. Reusing a built-in id (`KTLX`) **replaces** that site — for pointing it at a mirror |
| `lat`, `lon` | Required, degrees |
| `name`, `state`, `elevFt` | Optional; a built-in id borrows the built-in's |
| `shortId` | The id Level 3 file names use, if it is not the last three letters of `id` |
| `attribution` | Shown on the map while a pane is on this site |
| `level2`, `level3` | Where NEXRAD data is. See below |
| `open` | Where **open-format** data is — for data the app has no decoder for. Used for every product; `level2`/`level3` are then ignored. See [open-format.md](open-format.md) |

An addon site shows on the map as a **diamond** rather than a dot, and in the
radar picker with its addon's name, so it is always clear the data is not
from NOAA.

**What the files are depends on the role.** A `level2` source holds NEXRAD
Archive II, a `level3` source NIDS products — the formats the app decodes
itself. Anything else goes through an `open` source: your own parser (in any
language) writes the [open radar format](open-format.md), a small JSON
description of a sweep or a grid, and the app renders it with its own
palettes, cursor and key.

**A missing level.** A site that re-defines a built-in id falls back to
NOAA's bucket for any level it gives no source for. A *new* id does not — it
shows an error instead. NOAA's Level 3 keys go by the last three letters, so
a private radar called `XTLX` would otherwise quietly be shown KTLX's data.

### Sources

| Field | |
|---|---|
| `type` | `s3`, `index` (the default), or `folder` |
| `url` | For `s3`, the bucket's base URL. For `index`, the URL of the listing |
| `path` | For `folder`: the folder, absolute, under `~/`, or relative to the addon's folder |
| `prefix` | `s3` only: the key prefix to list |
| `match` | A regular expression; only matching entries are frames |
| `headers` | Sent with every listing and download from this source |
| `days` | How many days back to look, 1–14 (default 2) |
| `attribution` | Credit for this source, shown while it is on screen |

`url` and `prefix` are templates:

| Token | Becomes |
|---|---|
| `{site}` | the site id, `XOKC` |
| `{site3}` | the short id, `OKC` |
| `{product}` | the Level 3 product code: `N0B`, `N0G`, `N1B`, `NST`, … For an `open` source, the app's short code instead: `REF`, `VEL`, `ZDR`, `CC`, … |
| `{tilt}` | the tilt as numbered on the toolbar, 1–4 (`open` sources) |
| `{yyyy}` `{MM}` `{dd}` | the UTC date |

A template with a date in it is listed a day at a time, newest first. Use one
for any source that holds more than a few days: otherwise the whole history
is listed every minute.

A Level 3 source needs `{product}` somewhere, or every product shows the same
files.

**`s3`** lists with `?list-type=2&prefix=…` — the protocol the NOAA buckets
use, and what MinIO, Cloudflare R2, Wasabi, Backblaze B2 and most object
stores answer to. The bucket has to allow anonymous listing, or take its
credentials in `headers`.

**`index`** takes any URL that returns a list of files:

- **JSON** — an array of names, or of objects with `url`/`href`/`key`/`name`/
  `file` and optionally `time` (ISO 8601 or Unix seconds); or an object
  holding such an array under `files`, `items` or `entries`
- **a directory listing** — nginx `autoindex on`, Apache, `python3 -m
  http.server`. Every `href` is read; parent and sort links are skipped
- **plain text** — one name or URL per line; `#` starts a comment

Relative names resolve against the listing's URL.

**`folder`** lists a folder on this device — a receiver's output directory,
a sync folder, whatever a converter writes into. The files are only ever
read and decoded, never sent anywhere. A folder that does not exist yet is an
empty listing rather than an error. A file whose name carries no time is
placed by when it was written. On Android the folder has to be one the app
can read — its own data directory is the reliable choice.

### Scan times

Frames are put in order, and replay finds the right moment, by the scan time.
That comes from `time` in a JSON index, or else from the file name — which
works for the usual shapes:

```
KTLX20260728_053715_V06          TLX_N0B_2026_07_28_05_37_15
radar-20260728-053715.gz         scan_2026-07-28T05:37:15Z
```

Files with no readable time are still shown live (in name order), but are
left out of replay: a file that could be from any moment cannot honestly be
shown as the past.

### Security

`headers` sit in the addon file on the device, in plain text, and go only to
that source's host. Prefer `https`; a plain `http` source is warned about,
since the data and any token travel in the clear.

## Overlays

```json
"overlays": [
  {
    "id": "roads", "name": "County roads", "type": "geojson",
    "file": "roads.geojson",
    "stroke": "#FFD54F", "width": 1.5, "above": true
  },
  {
    "id": "spotters", "name": "Live spotter positions", "type": "geojson",
    "url": "https://example.org/spotters.geojson",
    "refreshMinutes": 2, "label": "callsign"
  },
  {
    "id": "shade", "name": "Hillshade", "type": "tiles",
    "url": "https://tiles.example.org/hillshade/{z}/{x}/{y}.png",
    "opacity": 0.4, "maxZoom": 13,
    "attribution": "Hillshade © Example"
  }
]
```

| Field | |
|---|---|
| `type` | `geojson` or `tiles` |
| `url` | GeoJSON URL, or a tile template with `{z}`, `{x}`, `{y}` |
| `file` | GeoJSON beside the manifest (folder addons) |
| `data` | GeoJSON written inline in the manifest |
| `stroke`, `fill`, `width` | Default style. Features can override with [simplestyle](https://github.com/mapbox/simplestyle-spec) keys: `stroke`, `fill`, `stroke-width`, `stroke-opacity`, `fill-opacity`, `marker-color` |
| `opacity` | 0–1 for the whole layer |
| `label` | Property to name features by (default `name`, then `title`) |
| `above` | `true` draws over the radar (boundaries, roads). Default is under it (imagery, shading) |
| `refreshMinutes` | Refetch a GeoJSON `url` this often; 0 (default) fetches once |
| `minZoom`, `maxZoom` | Only drawn between these zooms |
| `visible` | `false` to start switched off |
| `attribution` | Shown on the map while the layer is on. **Required by most tile providers** |

Overlays are switched on and off in **Layers → ADDONS**. A layer that is on
but failed to load says why there.

Tapping a GeoJSON point shows its properties.

## Places

Ground locations: shelters, spotter posts, schools, home.

```json
"places": [
  {
    "id": "shelters", "name": "Public shelters",
    "icon": "shelter", "color": "#6FBF73",
    "items": [
      { "name": "Main St Library", "lat": 35.47, "lon": -97.52,
        "notes": "Basement, enter by the north door" }
    ],
    "file": "shelters.csv"
  }
]
```

`items` and `file` can be used together. `file` is a `.csv` or a GeoJSON of
points (named by `name`/`title`, notes from `notes`/`description`).

A CSV is `name,lat,lon,notes`. With a header row the columns can be in any
order and go by name (`lat`/`latitude`, `lon`/`lng`/`longitude`,
`notes`/`description`), which is usually what a spreadsheet export has.

`icon` is one of: `pin`, `home`, `shelter`, `school`, `hospital`, `fire`,
`police`, `spotter`, `camera`, `flag`, `star`, `tower`, `airport`, `water`.

Tapping a place gives its distance and bearing from the pane's radar, and how
high the beam is over it at the current tilt — the answer to "why can't the
radar see the rotation I can see from here".

## Themes

```json
"themes": [
  {
    "id": "night-red", "name": "Night (red)",
    "basemap": "Dark",
    "colors": {
      "bg0": "#000000", "bg1": "#0A0000", "bg2": "#140000", "bg3": "#200000",
      "line": "#2A0000", "lineBright": "#440000",
      "text": "#E03030", "textDim": "#992020", "textFaint": "#601414",
      "accent": "#FF4040", "warn": "#FF6A00", "danger": "#FF0000",
      "good": "#C04040"
    }
  }
]
```

Themes colour the chrome — bars, menus, text, borders — and never the radar,
whose colours are data and come from its colour tables. Pick one in **Tools →
THEME**. Any key left out keeps the built-in colour.

| Key | Used for |
|---|---|
| `bg0` | map background, the space between panes |
| `bg1` | the bars |
| `bg2` | menus, raised controls |
| `bg3` | hover |
| `line`, `lineBright` | hairlines; the focused pane's border |
| `text`, `textDim`, `textFaint` | three levels of text |
| `accent` | selection, "this is on" |
| `warn`, `danger`, `good` | status: stale data, errors, the forecast readout |

`basemap` optionally switches the basemap with the theme (`Dark`,
`OpenStreetMap`, `Satellite`, `Topographic`) — a red night theme over a
bright satellite basemap has undone itself.

Keep it dark. The app is used outdoors at night in severe weather, and a
light background washes out the radar palettes and night vision. A light
theme still loads, with a warning.

## Colour tables

```json
"palettes": ["palettes/BR_dark.pal", "palettes/BV.pal"]
```

`.pal` files in the addon folder. They join the list in **Tools → COLOUR
TABLES**, the same as ones dropped in the palettes folder.

## For developers

| | |
|---|---|
| `lib/data/addons.dart` | manifest model, parser, folder loader, install/remove, settings |
| `lib/data/radar_source.dart` | `AddonSite`, `DataSource`, the S3/index listers, and the dispatch every radar fetch goes through |
| `lib/data/geojson.dart` | GeoJSON → shapes |
| `lib/ui/workspace_state.dart` | enabled addons, the merged site list, layer toggles, overlay fetches, the theme |
| `lib/ui/addon_ui.dart` | the Addons dialog and the place/feature sheets |
| `lib/ui/wx_theme.dart` | `WxPalette` — what a theme can change |

Adding a field: parse it in `addons.dart` with a warning for a bad value,
never an exception; add it here; add a test to `test/addons_test.dart`. A new
theme key needs adding to both `WxPalette.keys` and `themeColorKeys` — a
test holds the two together, since `data/` cannot import the UI.
