# The engine API

`rust/radar_core/` is the whole app minus the pixels: it decodes NEXRAD
Level 2 and Level 3, MRMS and GOES GLM, derives products, classifies
hydrometeors, forecasts motion, and rasterizes all of it to georeferenced
images. It has no Flutter dependency and no server component.

Read this if you are calling the engine from anything other than the current
Flutter app — or if you are changing what the app asks of it.

## Two ways in

**From Dart.** `app/rust/src/api/radar.rs` is the FFI surface.
`flutter_rust_bridge_codegen` reads it and writes `app/lib/src/rust/`, so
`pub fn render_level2_frame(...)` there becomes `renderLevel2Frame(...)` in
Dart — named arguments, camelCase, `Future`-returning. Adding a function
means editing that file and re-running codegen; see
[CONTRIBUTING.md](../CONTRIBUTING.md#regenerating-the-bridge).

**Directly.** Depend on `radar_core` and call `radar_core::api`. The bridge
crate holds no logic — every function in it delegates — so nothing is lost by
skipping it. `src/bin/` and `examples/` already do exactly this and are the
best worked examples:

```
cd rust/radar_core
cargo run --bin l2dump -- <archive2-file>     # decode a Level 2 volume
cargo run --bin l3dump -- <level3-file>       # decode a Level 3 product
cargo run --example viewtest                  # viewport render
cargo run --example vol3dtest                 # 3D volume
cargo run --example nowcasttest               # future radar
cargo run --example mrmstest                  # national mosaic
cargo run --example paltest                   # .pal colour table import
cargo run --example hcagrade                  # HCA vs. the NWS product
```

`tools/fetch_testdata.sh` pulls today's sample Level 3 files into
`tools/testdata/` to feed them.

## Calling conventions

Deliberately boring, because the bindings generator has to cope with it:

- Inputs are owned (`Vec<u8>`, `String`, `f64`), never borrowed.
- Errors are `Result<T, String>`. There is a real `RadarError` inside the
  engine (`src/error.rs`); it is stringified at the API edge.
- Images come back as **PNG bytes** (`RadarFrame.png`) or, on the hot 3D path,
  as raw RGBA (`RawFrame`) to skip the encode.
- Every image carries its own geographic bounds — `north`/`south`/`east`/
  `west` — so the caller stretches it across those and does no projection
  maths of its own.
- Nothing is fetched by the engine. You hand it bytes. See
  [data-sources.md](data-sources.md) for where those bytes come from.

## The surface, by job

Signatures are in `app/rust/src/api/radar.rs` (bridge) and
`rust/radar_core/src/api.rs` (engine); both are doc-commented. This is the
map, not a substitute for reading them.

**Render a frame**
| Function | Notes |
|---|---|
| `render_level2_frame` | Decode an Archive II volume, render one moment at one cut, fixed square image |
| `render_level3_frame` | Same for a Level 3 product file |
| `render_level3_view` / `render_level2_view` | **Viewport-matched**: pass the visible bounds and pixel size, get exactly those pixels. This is what keeps the map sharp at any zoom — prefer these |
| `render_mrms_view` | The national mosaic, from gzipped GRIB2 |
| `render_cape_view` | An HRRR model field on a Lambert Conformal grid. The frame's `timestamp` is the **model run time**, not the fetch time |
| `level2_cuts` | Elevation angles available for a moment |

**Read a value**
| Function | Notes |
|---|---|
| `sample_level3` / `sample_level2` | One-shot: decode, sample a point, throw away |
| `inspect_open_level3` / `inspect_open_level2` | Open a session, keeping the decoded sweep. Returns a handle |
| `inspect_sample` / `inspect_site` | Repeated cheap lookups against the handle |
| `inspect_close` | Free a session. A no-op on an unknown handle |

**3D**
| Function | Notes |
|---|---|
| `volume3d_open` | Build the grid for one volume + field (REF, SRM, VEL, ZDR, RHO, HCA) |
| `volume3d_render_fly` | Render one free-fly frame — raw RGBA, no PNG encode |
| `render_volume3d` | One-shot still, PNG |
| `volume3d_set_threshold` / `set_hidden_classes` | Repaint without rebuilding the grid |
| `volume3d_set_ground` / `set_terrain` / `ground_bounds` | The basemap drape and elevation relief. Send terrain as metres above **sea level**; the engine shifts it onto the volume's datum (the antenna) itself |
| `volume3d_show_cone` | Shade the unsampled column above the radar |

**Derived and decoded**
| Function | Notes |
|---|---|
| `nowcast_view` | Motion between two frames, extrapolated. `source` is `"L3"` or `"MRMS"` |
| `storm_tracks` | NWS SCIT cells out of a Level 3 STI product |
| `mesocyclones` | NWS mesocyclone/TVS detections. An empty list means none detected, not an error |
| `parse_glm` | GOES GLM lightning, via a hand-written HDF5 subset reader |

**Colour**
| Function | Notes |
|---|---|
| `color_scale` | The scale a product is actually drawn with, so a key matches the map |
| `install_palette` | Import a `.pal`; returns the product family it applies to |
| `reset_palettes` | Back to the built-ins |

## Sessions and global state

Some engine calls leave something open behind them. Which of those are
per-caller and which are process-wide is the thing to get right when several
panes are live at once.

| State | Opened by | Scope |
|---|---|---|
| Inspect sessions | `inspect_open_level2/3` | **Per caller** — keyed by a `u32` handle |
| The 3D session | `volume3d_open` | Process-global (`static VOL3D`) |
| The palette table | `install_palette` / `reset_palettes` | Process-global, deliberately |

### Inspect sessions are per-caller

An open returns a handle; `inspect_sample` and `inspect_site` take it back,
and `inspect_close` frees it. Open as many as you have cursors.

Two rules the current UI follows and a new one should too:

- **Close what you open.** A pane closes its handle when its cursor is
  switched off and again on dispose. `inspect_close` on an unknown handle is
  a no-op, so shutting down needs no ordering care.
- **Re-check the handle after every `await`.** Handles are never reused, so a
  sample still in flight when the pane reloads fails rather than silently
  answering from the new sweep — but your own state can still be stale, so
  compare the handle you sent against the one the pane currently holds before
  writing a readout.

This was a single global slot until [PR
#41](https://github.com/RiotTheClanker/radar-app/pull/41). Two panes with a
cursor up shared one session, and the second open silently retargeted the
first pane's readouts — a reflectivity pane reporting velocity numbers under
a reflectivity label, with no error and nothing on screen saying so. If you
are adding anything else the engine holds open per pane, key it by handle
the same way.

### The 3D session is still global

There is one `VOL3D` for the whole process. That holds only because 3D is a
full-screen route today: opening it leaves the workspace, so there is never a
second viewer. **The day 3D becomes a pane, it needs the same handle
treatment**, and for the same reason — the second opener would take over the
first one's volume.

### Palettes are global on purpose

A `.pal` import is meant to change every pane's map and key at once, which is
why `WorkspaceState.paletteGeneration` exists to make them all rebuild.

## Things that will bite

- **Colour keys must come from `color_scale()`**, never from constants in the
  UI, or an imported `.pal` will change the map and not the key. HCA is the
  exception: it is class ids, not a quantity, and gets its own legend using
  the NWS's own colours.
- **Level 2 volumes are 5–15 MB.** Decoding is fast; fetching four copies of
  the same one is not. Cache by object key.
- **Ask for the pixels you will draw.** The `*_view` functions size the render
  to what you pass. Passing the window's width for a pane that is a quarter
  of the window is four times the work, and was a real bug.
- **Two datums meet in the 3D view.** Echo heights are measured from the
  radar antenna (`beam_height_m`); terrain arrives measured from sea level.
  `set_terrain` reconciles them using the antenna altitude parsed out of the
  volume's own site block. Anything else drawn in that space has to pick a
  datum deliberately — they differ by 3.3 km at the highest site in the
  network, and by 26 m at the lowest.
- **wgpu with a CPU fallback** does the 3D. It is the only place the engine
  touches a GPU, and the fallback is why headless CI can still run it.
- **There are two GRIB2 readers, and they share nothing.** `mrms.rs` handles a
  plain lat/lon grid (template 3.0) with PNG-compressed values (5.41).
  `grib2.rs` handles Lambert Conformal (3.30) with complex packing and spatial
  differencing (5.3), which is what model output uses. Neither reads the
  other's files. Two traps in the format: signed integers are **sign-magnitude**
  (a decimal scale of -1 arrives as `0x8001`, and reads as -32767 if taken as
  two's complement), and the packed values are **second differences** that have
  to be integrated twice from initial values stored ahead of them.
- **The decoders are hand-written** — Level 2, Level 3, GRIB2, and the HDF5
  subset GLM needs. That is deliberate: there is no libhdf5, libgrib or
  eccodes to cross-compile for Android. Do not swap one in casually.
