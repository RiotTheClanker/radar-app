# The UI contract

Everything the UI layer is allowed to assume, and everything it must not
break. Read this before changing anything under `app/lib/ui/` or
`app/lib/main.dart`.

## Layers

```
app/lib/
  main.dart              the map screen — widgets only
  ui/                    widgets: theme, toolbar, keys, sounding, 3D
  state/radar_controller.dart   ALL state + data orchestration
  model/                 plain data: Product, Basemap, DisplayFrame, geo
  data/                  fetchers (NOAA, SPC, lightning, files)
  src/rust/api/radar.dart       generated bridge to the Rust engine
```

The rule is one way: **`state/` and below never import `ui/` or
`main.dart`.** The UI reads the controller and draws; it does not fetch,
decode, or cache anything itself.

`RadarController` is a `ChangeNotifier` with no `BuildContext`. That is
deliberate — it is what lets the whole UI be replaced without touching data
flow, and what lets the controller be unit-tested without a widget tree.

## What the UI owes the controller

The controller cannot see the map. The view wires two hooks in `initState`:

| Hook | Purpose |
|---|---|
| `controller.viewport` | returns a `MapViewport` (visible bounds, zoom, pixel width) or `null` if the map isn't attached yet |
| `controller.onMoveMap` | moves the map camera when the controller picks a site or locates the user |

It must also forward map gestures: `controller.onMapMoved(zoom)` on every map
event. That one call drives both the MRMS hand-over and the debounced
viewport re-render — drop it and the radar stops sharpening on zoom.

Transient notices arrive on `controller.messages` (a broadcast `Stream<String>`).
Show them however you like; a `SnackBar` is what ships today. Persistent
failures are `controller.error` / `controller.alertError` instead, and are
meant to stay visible.

## What stays in the view

Anything that genuinely needs a `BuildContext` or the camera:

- bottom sheets (alerts, storm cells, mesocyclones), date/time pickers
- navigation to `Volume3DScreen` and `SoundingScreen`
- `ScaffoldMessenger` snack bars
- `_zoomToAlert` (needs `fitCamera`)
- the 24 px "did the tap land on the cursor pin" hit test, which needs
  `latLngToScreenOffset`. The view decides; it then calls either
  `unpinCursor()` or `aimCursor(p, fromTap: true)`.

## Invariants — these look cosmetic and are not

1. **`ToolBar` uses nested `Wrap`s, never a `Row`.** On a phone in portrait
   the map toolbar's buttons are wider than the screen; a `Row` pushes the
   last few off the edge. See `ui/toolbar.dart`.
2. **Basemap attribution is a licensing requirement.** CARTO, OpenStreetMap,
   Esri and OpenTopoMap all require visible credit. The active basemap's
   `attribution` string has to stay on screen, along with `NOAA/NWS` and —
   when that source is on — `lightning © Blitzortung.org`. A test asserts
   every basemap carries one.
3. **Dark theme is functional.** The app is used outdoors at night during
   severe weather. A light UI washes out the radar palettes and wrecks night
   vision. `ui/theme.dart` is the only place colours are defined globally.
4. **Storm tracks always come from reflectivity**, whatever product is
   displayed, and are positioned by azimuth/range from the site — so panning
   and zooming cannot move them, and must not refetch them.
5. **MRMS takes over below zoom 6 and hands back at 6.5**, but *only* when
   the product is `defaultProduct`. An explicitly chosen product is never
   swapped out from under the user.
6. **Colour keys come from the engine** (`colorScale()`), not from constants
   in Dart, because an imported `.pal` file changes them. `HCA` is the
   exception: it gets `HydroLegend` (a class list) rather than a scale, using
   the NWS's own colours.
7. **Map rotation is disabled** (`InteractiveFlag.all & ~InteractiveFlag.rotate`).
   A twisted radar map is disorienting and hard to undo on touch.
8. **`Volume3DScreen` needs `basemapUrl`** threaded through from the map's
   current choice, or the 3D ground plane goes blank.
9. **The 3D view must honour replay time.** `prepareVolume()` passes
   `historyTime`; without it the map shows the past while 3D silently shows
   now, and nothing on screen says they disagree.

## Generated files — never hand-edit

- `lib/src/rust/frb_generated*.dart` and `lib/src/rust/api/*` —
  `flutter_rust_bridge_codegen`
- `lib/data/nexrad_sites.g.dart`
- `branding/` icons — regenerate with `python3 branding/make_icons.py`

## Before you push

```
cd app
flutter analyze     # must be clean, no new warnings
flutter test
```

Both run in CI (`.github/workflows/build.yml`) along with `cargo test`.
