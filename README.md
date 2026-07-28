# Radar App (working title)

A free, open, RadarScope-class weather radar app for **Windows, Android, and Debian Linux**.

**No subscription. No accounts. No servers.** All radar data comes straight from free
NOAA/NWS open-data sources, and every calculation — Level 2 decoding, dealiasing,
derived products, future-radar nowcasting, 3D volume rendering — happens on your device.

## Planned features

- All NEXRAD **Level 2** moments (super-res REF, VEL, SW, ZDR, CC, KDP) and **Level 3** products
- **Automatic distance-based radar site switching** with a national MRMS mosaic at low zoom
- Real-time **lightning** (Blitzortung + GOES GLM, user-selectable)
- NWS **warnings** (tornado / severe / flood polygons) and location alerts
- **Future radar**: on-device optical-flow nowcast (0–60 min) + HRRR model radar (1–18 hr)
- **3D volume view** of storm structure
- Cross-sections, multi-panel view, bin inspector, rotation/hail algorithms
- Historical replay from the Level 2 archive (back to 1991)
- GRLevelX color table (`.pal`) and placefile support

## Architecture

| Piece | Tech |
|---|---|
| UI (all platforms) | Flutter (`app/`) |
| Decode + processing engine | Rust (`rust/radar_core/`), called via `flutter_rust_bridge` |
| Map | `flutter_map` + free raster tiles |
| Data | AWS Open Data (NEXRAD L2/L3, MRMS, GOES, HRRR), api.weather.gov, Blitzortung |

## Building

Prereqs: Flutter SDK, Rust toolchain, and on Linux: `clang ninja-build libgtk-3-dev`.

```
cd app
flutter run -d linux
```
