# Radar

[![build](https://github.com/RiotTheClanker/radar-app/actions/workflows/build.yml/badge.svg)](https://github.com/RiotTheClanker/radar-app/actions/workflows/build.yml)

A free, open, RadarScope-class weather radar app for **Windows, Android, and
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
- Reflectivity, storm-relative wind, ground-relative wind, ZDR, and CC as
  selectable 3D fields

**Situational awareness**
- Live NWS warnings, tap for the full text
- SPC convective outlook and today's storm reports
- Lightning from Blitzortung, GOES GLM satellite, or both
- **Aiming cursor**: hover (or tap to pin) for the exact value, range,
  compass heading, and beam height, with a range ring drawn from the radar
- **Historical replay** back to 1991 — the whole app, including 3D and the
  nowcast, runs on the moment you pick
- Distance/bearing measuring, PNG snapshots (2D and 3D)
- GRLevelX `.pal` color table import
- Four basemaps: dark, OpenStreetMap, satellite, topographic

## Controls

**Map** — drag to pan, pinch or scroll to zoom. Long-press for a one-shot
value readout. Toolbar, left to right: lightning source, 3D volume, future
radar, severe-weather layers, basemap, my location, aiming cursor, more
(replay / measure / snapshot / color tables), reload.

**3D view** — fills the screen, with the controls floating over the storm.
Drag to look, two fingers to pan, pinch to fly. On desktop: `W` `A` `S` `D`
to move, `Space` / `Shift` for altitude, `Ctrl` to speed up, scroll to dolly.
On touch, use the on-screen stick and altitude pad. The scissors button
reveals slice planes; the layers button switches the 3D field; the eye button
hides the stick and every other control, leaving just the storm.

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

> Only the Linux package has been verified on real hardware so far. The
> Windows and Android builds come out of CI and have not been smoke-tested
> yet, and neither is code-signed — expect the usual "unknown publisher"
> warnings.

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
./packaging/build-deb.sh 0.1.0
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
lightning, and Blitzortung.org for ground-network lightning.

## License

MIT — see [LICENSE](LICENSE). Not affiliated with NOAA or the NWS; never rely
on this as your only source of warnings.
