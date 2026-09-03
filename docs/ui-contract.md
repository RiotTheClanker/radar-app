# The UI contract

What the UI layer may assume, and what it must not break. Read this before
changing anything under `app/lib/ui/`.

## Layers

```
app/lib/
  main.dart                  boots the app; nothing lives here
  ui/workspace.dart          layout, linking, the docked toolbars
  ui/radar_pane.dart         one pane's map and chrome — widgets only
  ui/wx_theme.dart           every colour, type style and metric
  ui/pane_models.dart        plain data: RadarProduct, Basemap, DisplayFrame
  ui/geo.dart                distance/bearing, beam height, geodesic rings
  state/pane_controller.dart ONE PANE's state + orchestration
  ui/workspace_state.dart    state shared by ALL panes
  data/                      fetchers (NOAA, SPC, lightning, files)
  src/rust/api/radar.dart    generated bridge to the Rust engine
```

The rule is one way: **`state/` and `data/` never import a widget.** Neither
`PaneController` nor `WorkspaceState` may touch `BuildContext`. That is what
lets the chrome be redrawn — or replaced outright — without going anywhere
near fetching, decoding or rendering.

## Who owns what

Getting this wrong is the main way to break a multi-pane layout.

| Belongs to `WorkspaceState` | Belongs to `PaneController` |
|---|---|
| alerts, SPC outlook and reports | site, product, tilt |
| lightning strikes and source | loaded frames, colour key |
| basemap, `showKey` | cursor, storm tracks, mesocyclones |
| replay time (`historyTime`) | measuring tool, nowcast |
| the animation clock | that pane's *isolated* clock |
| palette generation | |
| request caches (`listing`, `volume`) | |

The test: would four panes each want their own copy? Then it is the pane's.
Would four copies mean four times the network, or four clocks that drift
apart? Then it is the workspace's.

Panes report their loop length up with `reportFrames(paneId, n)` and drop out
with `forgetPane(paneId)`, so the shared loop is as long as its longest pane.
An isolated pane does neither.

## What the widget owes the controller

`PaneController` cannot see the map. `RadarPaneState` wires two hooks in
`initState`:

| Hook | Purpose |
|---|---|
| `controller.viewport` | returns a `PaneViewport` — visible bounds, zoom, and **this pane's** pixel width — or `null` before the map is attached |
| `controller.onMoveMap` | moves this pane's camera |
| `controller.onChanged` | the workspace toolbar needs a repaint |

`pixelWidth` is the pane's own width times the device pixel ratio, **never
the window's**. Sizing renders to the window was a real bug: correct while
the map *was* the window, and four times too many pixels in a 2x2.

## What stays in the widget

Anything needing a `BuildContext` or the camera:

- the map, the pane header, the readouts, the sheets, the marker caches
- `applyCamera` / `frameBounds` (camera ops; they consult `controller.isolated`)
- `open3D` — the controller fetches the volume, the widget navigates
- the 24 px "did the tap land on the cursor pin" hit test, which needs
  `latLngToScreenOffset`. The widget decides, then calls either
  `unpinCursor()` or `aimCursor(p, fromTap: true)`.

## Invariants — these look cosmetic and are not

1. **Basemap attribution is a licensing requirement.** CARTO, OpenStreetMap,
   Esri and OpenTopoMap all require visible credit. The active basemap's
   `attribution` has to stay on screen, with `NOAA/NWS`, and — when that
   source is on — `lightning © Blitzortung.org`.
2. **Dark theme is functional.** The app is used outdoors at night during
   severe weather. A light UI washes out the radar palettes and wrecks night
   vision. `wx_theme.dart` is the only place colours are defined.
3. **The bars scroll, they do not wrap.** A fixed-height docked strip cannot
   wrap, and on a phone in portrait the buttons are wider than the screen —
   hence the horizontal scroll with a fade at the edge, so a clipped label
   reads as scrollable rather than broken.
4. **The colour key shrinks before it disappears.** `ColorKey` takes a bar
   height; a pane below roughly 210x200 drops it. A fixed 168 px bar in a
   ~155 px pane painted an overflow stripe across all four panes.
5. **The MRMS hand-over is single-pane only** (`maybeSwitchMosaic(multiPane:)`,
   below zoom 6.0, back at 6.5, and only from `productRef`). In a comparison
   layout it would replace the velocity and dual-pol panes with four copies
   of the same mosaic.
6. **Storm tracks always come from reflectivity**, whatever product the pane
   displays, and are positioned by azimuth/range from the site — so panning
   and zooming cannot move them, and must not refetch them.
7. **Colour keys come from the engine** (`colorScale()`), never from Dart
   constants, because an imported `.pal` changes them. `HCA` is the
   exception: it gets `HydroLegend`, using the NWS's own colours.
8. **A locked (isolated) pane is out of the group both ways** — it neither
   follows nor broadcasts passive moves. Explicit commands still land on it:
   picking a radar, "my location", framing an alert. A control that silently
   does nothing reads as broken.
9. **`Volume3DScreen` needs `basemapUrl`**, or the 3D ground plane goes blank.
10. **The 3D view must honour replay time.** `prepareVolume()` passes
    `historyTime`; without it the map shows the past while 3D shows now, and
    nothing on screen says they disagree.
11. **Panes hold their first fetch until the site is settled** (`autoLoad`).
    A cold start that fetches the fallback site and throws it away costs
    10 MB per pane on a Level 2 product.
12. **Layouts follow the room, not a device class.** A layout is offered when
    every pane it creates clears 260x190 (`PaneLayout.fitsIn`). A layout that
    stops fitting is re-drawn, not discarded, so the user's choice returns
    when the window grows back.
13. **Pane-owned engine state is keyed by a handle, never by a global.** The
    aiming cursor keeps a decoded sweep open in the engine so each move is a
    lookup instead of a re-parse. That session belongs to the pane:
    `inspectOpenLevel2`/`inspectOpenLevel3` return an id, every
    `inspectSample`/`inspectSite` passes it back, and the pane closes it in
    `dispose`. It was one global slot, so the second pane to switch its cursor
    on took the first pane's session over — in a reflectivity-vs-velocity
    layout that showed a velocity number under a reflectivity label, with no
    error and nothing on screen saying so. Anything else the engine holds open
    per pane needs the same treatment. (`VOL3D` is still a single global; it
    holds only because 3D is a full-screen route, and stops holding the day 3D
    becomes a pane.)
14. **A model layer says so, with its run time.** Every other source in this
    app was measured by an instrument. CAPE comes from the HRRR forecast
    model, and drawn at the same apparent confidence as a radar return —
    beside live warnings, in an app whose own README says never to rely on it
    as your only source — it will be read as an observation. The attribution
    line names the model and the run whenever the layer is on, and says when
    that run has gone stale. Any future model layer inherits this.

## Generated files — never hand-edit

- `lib/src/rust/frb_generated*.dart`, `lib/src/rust/api/*` — `flutter_rust_bridge_codegen`
- `lib/data/nexrad_sites.g.dart`
- `branding/` icons — regenerate with `python3 branding/make_icons.py`

## Before you push

```
cd app
flutter analyze     # must be clean
flutter test
```

Both run in CI along with `cargo test`. Prefer a test on `PaneController` or
`WorkspaceState` over a widget test where the behaviour is state, not
layout — those need no `pumpWidget` and run in milliseconds.
