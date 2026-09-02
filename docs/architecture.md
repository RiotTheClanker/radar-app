# Architecture

How the app is put together, and where the seams are. Start here; the other
docs go deeper on one layer each.

- [ui-contract.md](ui-contract.md) — the rules the current UI layer follows
- [ui-development.md](ui-development.md) — building a new UI on the Dart seams
- [engine-api.md](engine-api.md) — the Rust engine surface and its constraints
- [data-sources.md](data-sources.md) — every external endpoint the app hits

## The shape of it

There is no server. The app fetches raw bytes from public NOAA/NWS buckets,
hands them to a Rust engine on the device, and gets back georeferenced images
and decoded values to draw. Everything expensive — Level 2 decoding, the
3D raymarcher, the nowcast, hydrometeor classification — is Rust.

```
     NOAA / NWS / SPC / Blitzortung          (public HTTP + one websocket)
                  |
                  |  raw bytes
                  v
   app/lib/data/  fetchers, no decoding, no widgets
                  |
                  v
   app/lib/state/ PaneController — one pane's state and orchestration
   app/lib/ui/    WorkspaceState — state shared by every pane
                  |
                  |  Vec<u8> in, PNG/RGBA + values out
                  v
   app/lib/src/rust/     GENERATED bindings  (flutter_rust_bridge)
   app/rust/src/api/     bridge crate — thin, owned types, String errors
   rust/radar_core/      the engine: decode, process, render
```

## Repository map

```
app/                      the Flutter app
  lib/main.dart           boot: init the bridge, install the theme, run
  lib/ui/                 widgets — the only layer that may hold a BuildContext
  lib/state/              PaneController: one pane's state, no widgets
  lib/data/               network fetchers and file IO, no widgets
  lib/src/rust/           GENERATED Dart bindings — never hand-edit
  rust/                   the bridge crate (rust_lib_radar_app)
    src/api/radar.rs      the FFI surface; codegen reads this
  rust_builder/           vendored cargokit build glue; leave it alone
  test/                   Dart tests
  android/ linux/ windows/  per-platform shells
rust/radar_core/          the engine crate — pure Rust, no Flutter
  src/level2/ level3/     NEXRAD decoders (hand-written; no libhdf5/eccodes)
  src/mrms.rs glm.rs      MRMS GRIB2 and GOES GLM readers
  src/process/            derived products, HCA, nowcast, storm tracks, 3D grid
  src/render/             rasterizer, colour tables, wgpu raymarcher
  src/api.rs              the engine's public API
  src/bin/ examples/      headless debug tools — run these without Flutter
packaging/                .deb script and the Inno Setup installer
branding/                 one SVG plus the generator that fans it out
tools/                    NEXRAD site table generator, test-data fetcher
docs/                     you are here
```

## The four layers, and the one-way rule

`ui/` → `state/` → `data/` → the bridge. Imports only ever point down that
list.

**`state/` and `data/` never import a widget.** Neither `PaneController` nor
`WorkspaceState` may touch a `BuildContext`. That is the whole point: the
chrome can be redrawn — or thrown away and rewritten — without going near
fetching, decoding or rendering. If a new UI can be written by replacing
`lib/ui/` alone, the rule held.

Two consequences worth knowing before you fight them:

- The controller cannot see the map. It gets the camera through the
  `viewport` / `onMoveMap` hooks the widget installs. See
  [ui-contract.md](ui-contract.md#what-the-widget-owes-the-controller).
- Anything needing a camera or a `BuildContext` stays in the widget: the hit
  tests, the sheets, `applyCamera`, navigating into the 3D screen.

## Who owns state

`WorkspaceState` owns what is true of the whole app; `PaneController` owns
what is true of one pane. The test: would four panes each want their own
copy? Then it belongs to the pane. Would four copies mean four times the
network, or four clocks drifting apart? Then it belongs to the workspace.
The full split is a table in [ui-contract.md](ui-contract.md#who-owns-what).

## Two Rust crates, and why

| Crate | Path | What it is |
|---|---|---|
| `radar_core` | `rust/radar_core/` | The engine. Pure Rust. Knows nothing about Flutter or FFI. |
| `rust_lib_radar_app` | `app/rust/` | A thin `cdylib`/`staticlib` that re-exports the engine in shapes `flutter_rust_bridge` can generate bindings for. |

The bridge crate holds no logic. Every function in `app/rust/src/api/radar.rs`
delegates to `radar_core::api`, converting types where the generator needs
owned values and `String` errors. That split is what makes a non-Flutter UI
possible: link `radar_core` directly and the bridge crate is simply not in
the picture.

## What happens when a pane loads a frame

Worth following once — most bugs live somewhere on this path.

1. The workspace decides the pane's site (nearest radar to you, or the
   fallback) and lets it load. Panes hold their first fetch until the site is
   settled; a cold start that fetches the wrong site and throws it away costs
   about 10 MB per pane on Level 2.
2. `PaneController.loadFrames()` asks `lib/data/` for the recent object keys
   for that site and product, then for the bytes. Level 2 volumes go through
   `WorkspaceState`'s `VolumeCache`, so four panes comparing four moments of
   the same volume download it once.
3. The bytes go to the engine — `renderLevel2View` / `renderLevel3View` /
   `renderMrmsView` — along with the pane's visible bounds and **its own**
   pixel width. Back comes a georeferenced PNG plus metadata.
4. The widget decodes the PNG into an `ImageProvider` and overlays it on the
   map at the returned bounds.
5. Panning or zooming re-renders at the new viewport rather than stretching
   the image, which is why it stays sharp. That re-render is generation-
   counted so a slow one cannot land after a newer one.

## Threading

There are **no Dart isolates in this app**. All the heavy work happens in
Rust, and `flutter_rust_bridge` runs those calls on its own worker threads,
so the Dart UI thread stays free. From Dart every engine call is just an
`await`.

> Naming collision: "isolate" in this codebase almost always means a *pane
> isolated from the linked group* — see `toggleIsolate`,
> `radar_pane_isolate_test.dart` — not `dart:isolate`.

Some engine calls leave a session open behind them, and whether that session
is per-caller matters as soon as more than one pane is live. Cursor-inspect
sessions are **per-caller**, keyed by a handle the opener passes back on every
read. The 3D session is still **process-global**, which holds only because 3D
is a full-screen route rather than a pane. See
[engine-api.md](engine-api.md#sessions-and-global-state).

## Generated files — never hand-edit

| File | Regenerate with |
|---|---|
| `app/lib/src/rust/**`, `app/rust/src/frb_generated.rs` | `flutter_rust_bridge_codegen generate` |
| `app/lib/data/nexrad_sites.g.dart` | `python3 tools/gen_sites.py` |
| `branding/` icon outputs, Android mipmaps, `.ico` | `python3 branding/make_icons.py` |

`app/rust_builder/` is vendored build tooling that ships with
`flutter_rust_bridge`. It is excluded from analysis and is not ours to edit.

See [CONTRIBUTING.md](../CONTRIBUTING.md) for the commands and when to run
them.
