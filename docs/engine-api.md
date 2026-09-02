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
| `level2_cuts` | Elevation angles available for a moment |

**Read a value**
| Function | Notes |
|---|---|
| `sample_level3` / `sample_level2` | One-shot: decode, sample a point, throw away |
| `inspect_open_level3` / `inspect_open_level2` | Open a session, keeping the decoded sweep |
| `inspect_sample` / `inspect_site` | Repeated cheap lookups against that session |

**3D**
| Function | Notes |
|---|---|
| `volume3d_open` | Build the grid for one volume + field (REF, SRM, VEL, ZDR, RHO, HCA) |
| `volume3d_render_fly` | Render one free-fly frame — raw RGBA, no PNG encode |
| `render_volume3d` | One-shot still, PNG |
| `volume3d_set_threshold` / `set_hidden_classes` | Repaint without rebuilding the grid |
| `volume3d_set_ground` / `set_terrain` / `ground_bounds` | The basemap drape and elevation relief |
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

## Global sessions

Three things in the engine are **process-global**, not per-caller:

| State | Set by | Guarded by |
|---|---|---|
| The 3D session | `volume3d_open` | `static VOL3D: Mutex<Option<..>>` |
| The inspect session | `inspect_open_level2/3` | `static INSPECT: Mutex<Option<..>>` |
| The palette table | `install_palette` / `reset_palettes` | inside `render` |

There is exactly one of each for the whole process. `inspect_sample` reads
whatever the last `inspect_open_*` put there.

**What this means for a multi-pane UI:** two panes with the cursor switched
on share one inspect session, and the second `inspect_open_*` silently
retargets the first pane's readouts. The current UI does not prevent this —
the cursor is per-pane state and the toolbar acts on the focused pane — so it
is a latent bug, not a solved problem. If you are designing a new UI, either
serialize access behind one owner or push a session handle through the API so
each caller has its own.

Palettes are global on purpose: a `.pal` import is meant to change every
pane's map and key at once, which is why `WorkspaceState.paletteGeneration`
exists to make them all rebuild.

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
- **wgpu with a CPU fallback** does the 3D. It is the only place the engine
  touches a GPU, and the fallback is why headless CI can still run it.
- **The decoders are hand-written** — Level 2, Level 3, GRIB2, and the HDF5
  subset GLM needs. That is deliberate: there is no libhdf5, libgrib or
  eccodes to cross-compile for Android. Do not swap one in casually.
