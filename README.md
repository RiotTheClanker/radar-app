# Radar

[![build](https://github.com/RiotTheClanker/radar-app/actions/workflows/build.yml/badge.svg)](https://github.com/RiotTheClanker/radar-app/actions/workflows/build.yml)

A free, open, professional-grade weather radar app for **Windows, Android, and
Debian Linux**.

**No subscription. No accounts. No servers.** Radar data comes straight from
free NOAA/NWS open-data sources, and every calculation — Level 2 decoding,
derived products, future-radar nowcasting, 3D volume rendering — happens on
your device.

## Features

**Radar data**
- Full **NEXRAD Level 2**: every moment (REF, VEL, SW, ZDR, PHI, RHO), every
  elevation cut, super-resolution, decoded on-device
- All the common **Level 3** products with tilt selection
- **National MRMS mosaic**, which takes over automatically when you zoom out
- Sharp at any zoom: the visible area is re-rendered at screen resolution
  rather than stretching one fixed image

**Derived on-device**
- Composite reflectivity, VIL, echo tops
- Storm-relative velocity and rotation (azimuthal shear)
- **Future radar**: motion is tracked between scans and extrapolated up to
  60 minutes ahead — computed locally, not fetched from a server

**3D**
- GPU-raymarched storm volumes you can **fly through** (WASD + mouse, or an
  on-screen stick on touch)
- Slice planes, a basemap draped on the ground, compass and radar pin
- Optional **3D terrain** under the storm, and an optional shaded **cone of
  silence** showing the column above the radar that no scan reaches
- Reflectivity, storm-relative wind, ground-relative wind, ZDR, and CC as
  selectable 3D fields

**Situational awareness**
- Live NWS warnings, watches and advisories, each layer separate, tap for the
  full text — plus a list of everything active, including the county-issued
  alerts that have no polygon to draw
- SPC convective outlook and today's storm reports
- **Upper-air soundings**: the latest radiosonde launch from the site nearest
  you, plotted on a log-pressure axis with the wind profile alongside, and
  CAPE, CIN, LI, LCL/LFC/EL, precipitable water, shear and storm-relative
  helicity all worked out on the device
- Lightning from Blitzortung, GOES GLM satellite, or both
- **Aiming cursor**: hover (or tap to pin) for the exact value, range,
  compass heading, and beam height, with a range ring drawn from the radar
- **Historical replay** back to 1991 — the whole app, including 3D and the
  nowcast, runs on the moment you pick
- Distance/bearing measuring, PNG snapshots (2D and 3D)
- `.pal` color table import
- Four basemaps: dark, OpenStreetMap, satellite, topographic

## Controls

**Map** — drag to pan, pinch or scroll to zoom. Long-press for a one-shot
value readout. Toolbar, left to right: lightning source, 3D volume, future
radar, alert layers (warnings / watches / advisories, and the full list),
basemap, my location, aiming cursor, more
(replay / measure / color key / sounding / snapshot / color tables), reload.

**Color key** — a scale down the right edge showing what the colors mean for
whatever product is up, in that product's own units. It is built from the
same table the renderer used, so an imported `.pal` changes the key too.
Toggle it under the more menu.

**3D view** — fills the screen, with the controls floating over the storm.
Drag to look, two fingers to pan, pinch to fly. On desktop: `W` `A` `S` `D`
to move, `Space` / `Shift` for altitude, `Ctrl` to speed up, scroll to dolly.
On touch, use the on-screen stick and altitude pad. The scissors button
reveals slice planes; the layers button switches the 3D field; the mountain
button drapes the storm over real terrain; the bars button shades the cone of
silence; the eye button hides the stick and every other control, leaving just
the storm.

Terrain is off by default — it is a second set of tiles to fetch, and it is
not always wanted. Elevation comes from the free AWS Terrain Tiles dataset.

**Location** — the app opens on the radar nearest you, and the my-location
button re-centers there. It uses GPS when you grant permission and falls back
to IP geolocation otherwise, which is city-level and on mobile data resolves
your carrier rather than you. Nothing is asked for at startup and the app
works fine with location refused — it just opens on the default site.

**Files** — drop `.pal` color tables in `~/.config/radar-app/palettes/`.
Snapshots are written to `~/Pictures/radar-app/`.

## Install

Grab a build from the [releases
page](https://github.com/RiotTheClanker/radar-app/releases).

**Debian / Ubuntu**

```
sudo apt install ./radar-app_<version>_amd64.deb
```

**Windows** — run `radar-app-<version>-windows-setup.exe`.

**Android** — install the APK matching your device's ABI (`arm64-v8a` for
almost anything modern).

> Linux and Android `arm64-v8a` are tested on real hardware each release. The
> Windows build comes out of CI and has not been smoke-tested.
>
> Nothing is code-signed yet, so Windows shows an "unknown publisher" warning
> and Android asks about installing from an unknown source.
>
> On Android there is a second consequence worth knowing: release builds are
> still signed with a *debug* key, and CI generates a fresh one on every run.
> Android refuses to install an APK over one signed by a different key, so
> upgrading in place usually fails and you have to uninstall first. Signing
> with one stable key would fix that, and is the main reason to bother.

## Build from source

Prereqs: [Flutter](https://flutter.dev) 3.44+, a Rust toolchain, and on Linux
`clang cmake ninja-build pkg-config libgtk-3-dev`.

```
cd app
flutter pub get
flutter run -d linux      # or -d windows, or a connected Android device
```

Package a `.deb`:

```
cd app && flutter build linux --release && cd ..
./packaging/build-deb.sh 0.1.2
```

## Architecture

| Piece | Tech |
|---|---|
| UI, all platforms | Flutter (`app/`) |
| Decode, processing, rendering | Rust (`rust/radar_core/`) via `flutter_rust_bridge` |
| 3D | wgpu raymarcher, with a CPU fallback |
| Map | `flutter_map` + your choice of free basemap |

The Rust crate does the heavy lifting and has no server component: NEXRAD
Level 2/3, MRMS GRIB2, and GOES GLM are all parsed with hand-written readers,
so there is no libhdf5/libgrib/libeccodes dependency to fight on mobile.

Debug tools live in `rust/radar_core/src/bin` and `examples/` — `l2dump`,
`l3dump`, and small harnesses for the 3D, nowcast, MRMS, and palette paths.

## Data sources

NEXRAD Level 2/3 and MRMS (NOAA Open Data on AWS), api.weather.gov for
warnings, SPC for outlooks and storm reports, GOES GLM for satellite
lightning, Blitzortung.org for ground-network lightning, AWS Terrain Tiles
for 3D terrain elevation, and SPC observed soundings (falling back to
rucsoundings.noaa.gov) for radiosonde data.

## License

MIT — see [LICENSE](LICENSE). Not affiliated with NOAA or the NWS; never rely
on this as your only source of warnings.
