# Building a new UI

For the case where the UI is being rewritten rather than tweaked. If you are
changing the existing one, [ui-contract.md](ui-contract.md) is the shorter
read and the one that binds.

## Two routes

**A. Replace `lib/ui/`, keep everything below.** You write widgets; the state
machine, the fetchers and the engine stay as they are. This is the cheap
route and the one the layering was built for — `PaneController` and
`WorkspaceState` were split out of `main.dart` precisely so the chrome could
be replaced without touching data.

**B. A different stack over `radar_core`.** A web, native or non-Flutter UI
linking the engine directly. You then reimplement in your stack what
`lib/data/` does — see [data-sources.md](data-sources.md), which lists every
endpoint so you do not have to reverse-engineer them, and
[engine-api.md](engine-api.md) for the engine surface.

The rest of this page is route A. Route B needs nothing from `lib/` except as
a reference implementation.

## What you are building against

Two objects. Both are `ChangeNotifier`s; neither has ever seen a widget.

### `WorkspaceState` — one per app

Everything true of the whole workspace. Construct one, hold it, dispose it.

```dart
final shared = WorkspaceState();   // starts the alert poll and the clock
```

| Area | Members |
|---|---|
| Alerts | `alerts`, `alertLayers`, `alertError`, `toggleAlertLayer()`, `refreshAlerts()`, `resolveAlertOutlines()` |
| SPC | `outlook`, `reports`, `showOutlook`, `showReports`, `toggleOutlook()`, `toggleReports()` |
| Lightning | `strikes`, `lightning`, `showLightning`, `setLightning()` |
| Map chrome | `basemap`, `setBasemap()`, `showKey`, `toggleKey()`, `myLocation`, `setMyLocation()` |
| Palettes | `paletteGeneration`, `bumpPalette()` |
| Replay | `historyTime`, `setHistoryTime()` |
| The clock | `frameIndex`, `playing`, `frameCount`, `loopLength`, `togglePlay()`, `step()`, `setFrameIndex()`, `setFrameCount()`, `reportFrames()`, `forgetPane()` |
| Caches | `volume()`, `cachedVolume()`, `listing()` |
| Linking | `linkViews`, `linkSite`, `propagatesSite`, `propagatesTilt`, `reachesGroup()` |
| Layout | `layout`, `setLayout()` |

Note `dispose()` — it owns a polling timer and an animation timer, and tests
that forget this fail on pending timers.

### `PaneController` — one per pane

```dart
final pane = PaneController(
  paneId: 0,              // stable index; keys this pane in the shared clock
  shared: shared,
  site: someNexradSite,
  product: productRef,
  tilt: 0,
);
```

Reads (all getters): `site`, `product`, `tilt`, `frames`, `displayFrame`,
`frameTime`, `dataAge`, `isStale`, `elevationDeg`, `loading`, `error`,
`keyScale`, `cursorOn`/`cursorPos`/`cursorSample`/`cursorPinned`,
`tracksOn`/`stormTracks`/`mesos`, `futureOn`/`futureMinutes`/`futureFrame`,
`measuringOn`/`measurePts`, `isolated`, `playing`, `frameIndex`,
`loopLength`, `sampleText`/`samplePos`.

Commands: `setProduct()`, `setTilt()`, `selectSite()`, `syncTo()`,
`toggleCursor()`, `toggleTracks()`, `toggleFuture()`, `setFutureMinutes()`,
`toggleMeasure()`, `addMeasurePoint()`, `toggleIsolate()`, `togglePlay()`,
`step()`, `setFrameCount()`.

Async work: `loadFrames()`, `renderViewport()`, `updateTracks()`,
`renderFuture()`, `openCursorSession()`, `aimCursor()`, `inspect()`,
`prepareVolume()`, `volumeKeys()`, `saveFrameSnapshot()`,
`maybeSwitchMosaic()`.

## The three hooks you must wire

`PaneController` cannot see the map. Your widget owes it three things, set in
`initState`:

```dart
@override
void initState() {
  super.initState();
  _c
    ..viewport = _readViewport
    ..onMoveMap = _moveCamera
    // Read through `widget` each time rather than capturing once, so the
    // callback survives a parent rebuild.
    ..onChanged = (() => widget.onChanged())
    ..addListener(_onPane);

  // Deferred: loadFrames() notifies before its first await, and rebuilding
  // while the State is still being constructed is an error.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (mounted && widget.autoLoad) unawaited(_c.loadFrames());
  });
}

PaneViewport? _readViewport() {
  if (!mounted || !_mapReady) return null;         // null before attach is fine
  final cam = _mapController.camera;
  final vis = cam.visibleBounds;
  return PaneViewport(
    north: vis.north, south: vis.south,
    east: vis.east,   west: vis.west,
    zoom: cam.zoom,
    // THIS PANE's width in physical pixels — not the window's. `_paneSize`
    // comes from a LayoutBuilder around the pane.
    pixelWidth: _paneSize.width * MediaQuery.of(context).devicePixelRatio,
  );
}

void _moveCamera(LatLng center, double zoom) {
  if (_mapReady) _mapController.move(center, zoom);
}
```

Three things in there are load-bearing:

- **`pixelWidth` is the pane's width, never the window's.** This is easy to
  get wrong and expensive when you do: four panes each asking for the
  window's width is four times the render work for the same picture. It was
  a real bug — correct while the map *was* the window, wrong the moment a 2x2
  existed.
- **Returning `null` before the map is attached is expected.** The controller
  handles it; do not fake a viewport to avoid it.
- **`autoLoad` gates the first fetch** until the workspace has settled on a
  site. A cold start that fetches the fallback site and throws it away costs
  about 10 MB per pane on Level 2, so a new UI needs the same gate — and the
  matching `didUpdateWidget` that fires the first honest load when it flips.

## What has to stay in your widget

The controller deliberately cannot do these, because they need a camera or a
`BuildContext`:

- the map itself, headers, readouts, sheets, marker caches
- camera operations — framing an alert, fitting bounds (consult
  `controller.isolated` first: an isolated pane still takes explicit
  commands, just not passive ones)
- navigating into the 3D screen. `prepareVolume()` fetches the bytes; you
  push the route, and you must pass `basemapUrl` or the ground plane is blank
- the "did the tap land on the cursor pin" hit test — it needs
  `latLngToScreenOffset`. Decide, then call `unpinCursor()` or
  `aimCursor(p, fromTap: true)`

## Invariants you inherit

These are in [ui-contract.md](ui-contract.md#invariants--these-look-cosmetic-and-are-not)
in full. The ones that survive a rewrite of the chrome, condensed:

1. **Basemap attribution is a licensing requirement.** CARTO, OSM, Esri and
   OpenTopoMap all require visible credit, alongside `NOAA/NWS` and — when
   that source is on — `lightning © Blitzortung.org`. Not a design choice.
2. **Dark by default is functional.** The app gets used outdoors at night in
   severe weather; a light UI wrecks night vision and washes out the radar
   palettes. If you add a light theme, keep dark the default and keep the
   radar palettes unmodified in both.
3. **Colour keys come from the engine**, so an imported `.pal` changes them.
4. **The colour key shrinks before it disappears** — a pane too small for a
   key drops it rather than overflowing.
5. **Storm tracks always come from reflectivity**, whatever the pane shows,
   positioned by azimuth/range from the site. Panning must not refetch them.
6. **The MRMS hand-over is single-pane only**, or a comparison layout turns
   into four copies of the mosaic.
7. **An isolated pane is out of the group both ways** — it neither follows nor
   drives passive moves, but explicit commands still land on it. A control
   that silently does nothing reads as broken.
8. **3D honours replay time**, or the map shows the past while 3D shows now
   and nothing on screen admits they disagree.
9. **Panes hold their first fetch until the site settles** (`autoLoad`).
10. **Layouts follow the room, not a device class** — a layout is offered when
    every pane it would create clears its minimum size.

## Testing a UI rewrite

The split pays off here: most behaviour is testable with no widget tree.

```
cd app
flutter test test/pane_controller_test.dart     # a pane's state machine
flutter test test/workspace_linking_test.dart   # linking, isolation, the clock
flutter test test/request_cache_test.dart       # de-duplicated fetches
flutter test test/geo_test.dart                 # distance, bearing, beam height
```

Those run in milliseconds and none of them pump a widget. `wx_chrome_test`,
`toolbar_test`, `color_key_test` and `radar_pane_isolate_test` do pump, and
are the ones a rewrite will legitimately need to replace.

Prefer a test on `PaneController` or `WorkspaceState` over a widget test
wherever the behaviour is state rather than layout. If you find yourself
unable to test something without a widget, that is usually a sign it belongs
in the controller.

Watch for: `WorkspaceState` starts real timers in its constructor, so dispose
it inside the test body — the test binding checks for pending timers before
`addTearDown` runs.

## Where to start reading

1. `lib/main.dart` — 26 lines, the whole boot
2. `lib/ui/workspace.dart` — the header comment explains the layout and linking
3. `lib/state/pane_controller.dart` — the header comment explains the split
4. `lib/ui/pane_models.dart` — the product catalog and basemaps, plain data
5. `lib/ui/wx_theme.dart` — every colour, type style and metric, in one place
