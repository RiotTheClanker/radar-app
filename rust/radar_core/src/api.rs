//! Public engine API — this is the surface exposed to the Flutter app via
//! flutter_rust_bridge. Signatures stay simple (owned types, String errors)
//! so the generated bindings are clean.

use crate::level2;
use crate::level3;
use crate::level3::products::ProductKind;
use crate::render::{self, ColorTable};
use crate::sweep::Sweep;

/// A ready-to-display radar frame: RGBA pixels plus the geographic bounds the
/// map should stretch them across, and metadata for the UI.
pub struct RadarFrame {
    pub product_code: i32,
    pub product_name: String,
    pub unit: String,
    pub site_lat: f64,
    pub site_lon: f64,
    /// Unix seconds of the source volume scan.
    pub timestamp: i64,
    pub elevation_deg: f32,
    pub vcp: i32,
    pub width: u32,
    pub height: u32,
    /// PNG-encoded RGBA image (transparent where there is no data).
    pub png: Vec<u8>,
    pub north: f64,
    pub south: f64,
    pub east: f64,
    pub west: f64,
}

fn encode_png(width: u32, height: u32, rgba: &[u8]) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    {
        let mut enc = png::Encoder::new(&mut out, width, height);
        enc.set_color(png::ColorType::Rgba);
        enc.set_depth(png::BitDepth::Eight);
        let mut writer = enc.write_header().map_err(|e| e.to_string())?;
        writer.write_image_data(rgba).map_err(|e| e.to_string())?;
    }
    Ok(out)
}

/// Decode a raw Level 3 product file and render it to a georeferenced image.
pub fn render_level3_frame(data: Vec<u8>, image_size: u32) -> Result<RadarFrame, String> {
    let file = level3::parse(&data).map_err(|e| e.to_string())?;
    let kind = file
        .info
        .map(|i| i.kind)
        .unwrap_or(ProductKind::Reflectivity);
    let sweep = file
        .to_sweep()
        .ok_or_else(|| "product contains no radial data".to_string())?;
    let name = file
        .info
        .map(|i| i.name.to_string())
        .unwrap_or_else(|| format!("Product {}", file.product_code));
    let unit = file.info.map(|i| i.unit.to_string()).unwrap_or_default();
    frame_from_sweep(
        &sweep,
        kind,
        file.product_code as i32,
        name,
        unit,
        file.vcp as i32,
        image_size,
    )
}

/// Decode a full Level 2 (Archive II) volume and render one moment at one
/// elevation cut. `moment` is REF, VEL, SW, ZDR, PHI, or RHO;
/// `elevation_index` is the 0-based index among cuts containing that moment.
pub fn render_level2_frame(
    data: Vec<u8>,
    moment: String,
    elevation_index: u32,
    image_size: u32,
) -> Result<RadarFrame, String> {
    let vol = level2::parse(&data).map_err(|e| e.to_string())?;
    let sweep = level2_sweep(&vol, &moment, elevation_index as usize)?;
    let (kind, name, unit) = moment_meta(&moment);
    frame_from_sweep(&sweep, kind, 0, name, unit, vol.vcp as i32, image_size)
}

/// Elevation cuts available for a moment in a Level 2 volume, in scan order.
pub fn level2_cuts(data: Vec<u8>, moment: String) -> Result<Vec<f32>, String> {
    let vol = level2::parse(&data).map_err(|e| e.to_string())?;
    Ok(match moment.as_str() {
        "CREF" | "VIL" | "ET" => vec![0.0],
        "SRM" | "ROT" => vol.cuts_for("VEL").iter().map(|c| c.elevation_deg).collect(),
        _ => vol.cuts_for(&moment).iter().map(|c| c.elevation_deg).collect(),
    })
}

/// Viewport-matched render of a Level 3 product: rasterize only the given
/// Web Mercator box at the given pixel size, so gates stay sharp at any zoom.
#[allow(clippy::too_many_arguments)]
pub fn render_level3_view(
    data: Vec<u8>,
    north: f64,
    south: f64,
    east: f64,
    west: f64,
    width: u32,
    height: u32,
) -> Result<RadarFrame, String> {
    let file = level3::parse(&data).map_err(|e| e.to_string())?;
    let kind = file.info.map(|i| i.kind).unwrap_or(ProductKind::Reflectivity);
    let sweep = file
        .to_sweep()
        .ok_or_else(|| "product contains no radial data".to_string())?;
    let name = file
        .info
        .map(|i| i.name.to_string())
        .unwrap_or_else(|| format!("Product {}", file.product_code));
    let unit = file.info.map(|i| i.unit.to_string()).unwrap_or_default();
    let table = ColorTable::default_for(kind);
    let img = render::rasterize_sweep_view(&sweep, &table, north, south, east, west, width, height)
        .ok_or_else(|| "empty view".to_string())?;
    build_frame(&sweep, img, file.product_code as i32, name, unit, file.vcp as i32)
}

/// Viewport-matched render of a Level 2 moment/cut.
#[allow(clippy::too_many_arguments)]
pub fn render_level2_view(
    data: Vec<u8>,
    moment: String,
    elevation_index: u32,
    north: f64,
    south: f64,
    east: f64,
    west: f64,
    width: u32,
    height: u32,
) -> Result<RadarFrame, String> {
    let vol = level2::parse(&data).map_err(|e| e.to_string())?;
    let sweep = level2_sweep(&vol, &moment, elevation_index as usize)?;
    let (kind, name, unit) = moment_meta(&moment);
    let table = ColorTable::default_for(kind);
    let img = render::rasterize_sweep_view(&sweep, &table, north, south, east, west, width, height)
        .ok_or_else(|| "empty view".to_string())?;
    build_frame(&sweep, img, 0, name, unit, vol.vcp as i32)
}

/// Lightning flashes parsed from one GOES GLM L2 LCFA file.
pub struct GlmResult {
    pub timestamp: i64,
    pub lats: Vec<f32>,
    pub lons: Vec<f32>,
}

/// Parse a GOES GLM L2 LCFA netCDF file (pure-Rust HDF5 subset reader).
pub fn parse_glm(data: Vec<u8>) -> Result<GlmResult, String> {
    let f = crate::glm::parse(&data).map_err(|e| e.to_string())?;
    Ok(GlmResult {
        timestamp: f.timestamp,
        lats: f.lats,
        lons: f.lons,
    })
}

/// Result of sampling a product at a point (the "inspector" tool).
pub struct SampleResult {
    /// Physical value at the gate, if there is data there.
    pub value: Option<f32>,
    pub range_folded: bool,
    pub unit: String,
    pub distance_km: f64,
    /// Beam center height above the radar, meters (4/3-earth model).
    pub beam_height_m: f64,
    /// Compass bearing from the radar to the sampled point.
    pub azimuth_deg: f64,
    /// Elevation angle of the sampled sweep.
    pub elevation_deg: f32,
}

fn sample_sweep(sweep: &Sweep, unit: String, lat: f64, lon: f64) -> SampleResult {
    let sampled = sweep.sample_raw(lat, lon);
    let (value, range_folded, dist) = match sampled {
        Some((raw, dist)) => match sweep.decoder.decode(raw) {
            crate::level3::BinValue::Value(v) => (Some(v), false, dist),
            crate::level3::BinValue::RangeFolded => (None, true, dist),
            crate::level3::BinValue::NoData => (None, false, dist),
        },
        None => (None, false, 0.0),
    };
    // Bearing from the radar to the sampled point.
    let la1 = sweep.site_lat.to_radians();
    let la2 = lat.to_radians();
    let dlon = (lon - sweep.site_lon).to_radians();
    let y = dlon.sin() * la2.cos();
    let x = la1.cos() * la2.sin() - la1.sin() * la2.cos() * dlon.cos();
    let mut az = y.atan2(x).to_degrees();
    if az < 0.0 {
        az += 360.0;
    }

    SampleResult {
        value,
        range_folded,
        unit,
        distance_km: dist / 1000.0,
        beam_height_m: sweep.beam_height_m(dist),
        azimuth_deg: az,
        elevation_deg: sweep.elevation_deg,
    }
}

/// Sample a Level 3 product file at a geographic point.
pub fn sample_level3(data: Vec<u8>, lat: f64, lon: f64) -> Result<SampleResult, String> {
    let file = level3::parse(&data).map_err(|e| e.to_string())?;
    let sweep = file
        .to_sweep()
        .ok_or_else(|| "product contains no radial data".to_string())?;
    let unit = file.info.map(|i| i.unit.to_string()).unwrap_or_default();
    Ok(sample_sweep(&sweep, unit, lat, lon))
}

/// Sample a Level 2 volume's moment/cut at a geographic point.
pub fn sample_level2(
    data: Vec<u8>,
    moment: String,
    elevation_index: u32,
    lat: f64,
    lon: f64,
) -> Result<SampleResult, String> {
    let vol = level2::parse(&data).map_err(|e| e.to_string())?;
    let sweep = level2_sweep(&vol, &moment, elevation_index as usize)?;
    let (_, _, unit) = moment_meta(&moment);
    Ok(sample_sweep(&sweep, unit, lat, lon))
}

fn moment_meta(moment: &str) -> (ProductKind, String, String) {
    match moment {
        "VEL" => (ProductKind::Velocity, "Base Velocity (L2)".into(), "m/s".into()),
        "SW" => (ProductKind::SpectrumWidth, "Spectrum Width (L2)".into(), "m/s".into()),
        "ZDR" => (ProductKind::Zdr, "Differential Reflectivity (L2)".into(), "dB".into()),
        "PHI" => (ProductKind::Kdp, "Differential Phase (L2)".into(), "deg".into()),
        "RHO" => (
            ProductKind::CorrelationCoefficient,
            "Correlation Coefficient (L2)".into(),
            "".into(),
        ),
        "SRM" => (
            ProductKind::Velocity,
            "Storm-Relative Velocity (derived)".into(),
            "m/s".into(),
        ),
        "ROT" => (
            ProductKind::Rotation,
            "Rotation / Azimuthal Shear (derived)".into(),
            "m/s/km".into(),
        ),
        "CREF" => (
            ProductKind::Reflectivity,
            "Composite Reflectivity (derived)".into(),
            "dBZ".into(),
        ),
        "VIL" => (ProductKind::Vil, "Vertically Integrated Liquid (derived)".into(), "kg/m²".into()),
        "ET" => (ProductKind::EchoTops, "Echo Tops (derived)".into(), "kft".into()),
        _ => (ProductKind::Reflectivity, "Base Reflectivity (L2)".into(), "dBZ".into()),
    }
}

/// Default storm motion for SRM until a user setting / STI estimate exists.
const DEFAULT_STORM_FROM_DEG: f32 = 240.0;
const DEFAULT_STORM_SPEED_MS: f32 = 12.0;

/// Resolve a real or derived moment into a renderable sweep.
fn level2_sweep(
    vol: &level2::Level2Volume,
    moment: &str,
    index: usize,
) -> Result<Sweep, String> {
    match moment {
        "SRM" => {
            // Level 2 velocity is already dealiased by the RDA, so use it
            // directly; process::dealias stays available for repairing the
            // occasional RDA failure once that's detectable.
            let (s, _nyq) = vol
                .sweep_and_nyquist("VEL", index)
                .ok_or_else(|| format!("VEL cut {index} not in volume"))?;
            Ok(crate::process::storm_relative(
                &s,
                DEFAULT_STORM_FROM_DEG,
                DEFAULT_STORM_SPEED_MS,
            ))
        }
        "ROT" => {
            let (s, _nyq) = vol
                .sweep_and_nyquist("VEL", index)
                .ok_or_else(|| format!("VEL cut {index} not in volume"))?;
            Ok(crate::process::azimuthal_shear(&s))
        }
        "CREF" | "VIL" | "ET" => {
            let cuts = vol.all_sweeps("REF");
            let vp = crate::process::volume_products(&cuts)
                .ok_or_else(|| "no reflectivity cuts in volume".to_string())?;
            Ok(match moment {
                "CREF" => vp.composite,
                "VIL" => vp.vil,
                _ => vp.echo_tops,
            })
        }
        _ => vol
            .sweep(moment, index)
            .ok_or_else(|| format!("moment {moment} cut {index} not in volume")),
    }
}

fn frame_from_sweep(
    sweep: &Sweep,
    kind: ProductKind,
    product_code: i32,
    name: String,
    unit: String,
    vcp: i32,
    image_size: u32,
) -> Result<RadarFrame, String> {
    let table = ColorTable::default_for(kind);
    let img = render::rasterize_sweep(sweep, &table, image_size)
        .ok_or_else(|| "no radial data".to_string())?;
    build_frame(sweep, img, product_code, name, unit, vcp)
}

fn build_frame(
    sweep: &Sweep,
    img: render::GeoImage,
    product_code: i32,
    name: String,
    unit: String,
    vcp: i32,
) -> Result<RadarFrame, String> {
    Ok(RadarFrame {
        product_code,
        product_name: name,
        unit,
        site_lat: sweep.site_lat,
        site_lon: sweep.site_lon,
        timestamp: sweep.timestamp,
        elevation_deg: sweep.elevation_deg,
        vcp,
        width: img.width,
        height: img.height,
        png: encode_png(img.width, img.height, &img.pixels)?,
        north: img.north,
        south: img.south,
        east: img.east,
        west: img.west,
    })
}

/// Render a 3D volume view of a Level 2 volume's reflectivity as a PNG.
/// Camera orbits the radar: yaw/pitch in degrees, zoom 1.0 = whole volume.
#[allow(clippy::too_many_arguments)]
pub fn render_volume3d(
    data: Vec<u8>,
    yaw_deg: f32,
    pitch_deg: f32,
    zoom: f32,
    dbz_min: f32,
    width: u32,
    height: u32,
) -> Result<Volume3DFrame, String> {
    let vol = level2::parse(&data).map_err(|e| e.to_string())?;
    let cuts = vol.all_sweeps("REF");
    let grid = crate::process::grid3d::build_grid(&cuts, 384, 40, 120_000.0, 16_000.0)
        .ok_or_else(|| "no reflectivity cuts in volume".to_string())?;
    let img = crate::render::volume3d::render_volume(
        &grid, yaw_deg, pitch_deg, zoom, dbz_min, width, height, 4.0,
    );
    Ok(Volume3DFrame {
        width: img.width,
        height: img.height,
        png: encode_png(img.width, img.height, &img.rgba)?,
        timestamp: cuts.first().map(|c| c.timestamp).unwrap_or(0),
    })
}

/// A rendered 3D volume frame.
pub struct Volume3DFrame {
    pub width: u32,
    pub height: u32,
    pub png: Vec<u8>,
    pub timestamp: i64,
}

// ---------------------------------------------------------------------------
// 3D fly-through session (GPU raymarcher with CPU-built grids)
// ---------------------------------------------------------------------------

use crate::process::grid3d::{build_grid_encoded, Grid3D, GridEncode, ENCODE_DBZ};
use std::collections::BTreeMap;
use std::sync::atomic::{AtomicU32, Ordering};
use std::sync::Mutex;

struct Vol3DSession {
    grid: Grid3D,
    moment: String,
    gpu: Option<crate::render::gpu3d::GpuVolume>,
    site_lat: f64,
    site_lon: f64,
    /// The two ways of filtering, held so either can be changed without the
    /// caller having to resend the other.
    threshold: f32,
    hidden_classes: Vec<u8>,
}

// One session for the whole process, which holds only because 3D is a
// full-screen route: opening it leaves the workspace, so there is never a
// second viewer. If 3D ever becomes a pane, this needs the handle-per-caller
// treatment the inspect sessions below got, and for the same reason — the
// second opener would silently take over the first one's volume.
static VOL3D: Mutex<Option<Vol3DSession>> = Mutex::new(None);

const Z_EXAG: f32 = 4.0;

fn grid_encode_for(moment: &str) -> GridEncode {
    match moment {
        "VEL" | "SRM" => GridEncode { scale: 2.0, offset: 128.0, min_show: -999.0, no_echo: 0.0 },
        "ZDR" => GridEncode { scale: 16.0, offset: 66.0, min_show: -3.9, no_echo: 0.0 },
        "RHO" => GridEncode { scale: 200.0, offset: -35.0, min_show: 0.2, no_echo: 1.0 },
        _ => ENCODE_DBZ,
    }
}

/// Palette + opacity transfer for the 3D view, keyed by moment + threshold.
/// Grid the three dual-pol moments on a shared lattice and classify.
///
/// All three are required: classifying from one moment is guesswork, so a
/// volume without ZDR or RHO (a legacy, non-dual-pol scan) is an error rather
/// than a degraded picture.
pub fn build_hca_grid(vol: &level2::Level2Volume) -> Result<Grid3D, String> {
    use crate::process::hca;
    const NXY: usize = 384;
    const NZ: usize = 40;
    const EXT: f32 = 120_000.0;
    const TOP: f32 = 16_000.0;

    let dec = |e: GridEncode| move |raw: u8| (raw as f32 - e.offset) / e.scale;
    let mut grid_for = |m: &str| -> Result<(Grid3D, GridEncode), String> {
        let cuts = vol.all_sweeps(m);
        if cuts.is_empty() {
            return Err(format!(
                "this volume has no {m}, so it cannot be classified \
                 (dual-pol moments are needed)"
            ));
        }
        let enc = grid_encode_for(m);
        let g = build_grid_encoded(&cuts, NXY, NZ, EXT, TOP, enc)
            .ok_or_else(|| format!("no usable {m} cuts in volume"))?;
        Ok((g, enc))
    };

    let (z, ez) = grid_for("REF")?;
    let (zdr, ezdr) = grid_for("ZDR")?;
    let (rho, erho) = grid_for("RHO")?;

    let melt = hca::detect_melting_level(&z, &rho, dec(ez), dec(erho));
    Ok(hca::build_grid_hca(
        &z,
        &zdr,
        &rho,
        dec(ez),
        dec(ezdr),
        dec(erho),
        melt,
    ))
}

/// [`hidden`] carries class ids the classified field is not to draw; it is
/// ignored by every continuous field, which filters on [`threshold`] instead.
fn palette_3d(moment: &str, threshold: f32, hidden: &[u8]) -> [[u8; 4]; 256] {
    if moment == "HCA" {
        use crate::process::hca::Class;
        // Discrete classes, so the table is a lookup rather than a ramp and
        // `threshold` has no meaning here: there is no continuous floor to
        // raise, and any ordering of the classes to slide along would be one
        // we invented. The key is the filter instead, and `hidden` is
        // whichever classes have been switched off in it — an arbitrary set,
        // not a cutoff, so "graupel and hail only" is reachable.
        let mut pal = [[0u8; 4]; 256];
        for c in Class::ALL {
            if hidden.contains(&(c as u8)) {
                continue;
            }
            let quiet = matches!(c, Class::GroundClutter | Class::Biological);
            let [r, g, b] = c.color();
            pal[c as usize] = [r, g, b, if quiet { 90 } else { 150 }];
        }
        return pal;
    }
    let enc = grid_encode_for(moment);
    let kind = match moment {
        "VEL" | "SRM" => ProductKind::Velocity,
        "ZDR" => ProductKind::Zdr,
        "RHO" => ProductKind::CorrelationCoefficient,
        _ => ProductKind::Reflectivity,
    };
    let table = ColorTable::default_for(kind);
    let mut pal = [[0u8; 4]; 256];
    for raw in 2..256usize {
        let v = (raw as f32 - enc.offset) / enc.scale;
        // Opacity (0..1, scaled in-shader): strong signal = more opaque.
        let a = match moment {
            "VEL" | "SRM" => {
                let thr = threshold * 0.6; // slider 0-50 -> 0-30 m/s
                ((v.abs() - thr) / 20.0).clamp(0.0, 0.85)
            }
            // ZDR is interesting when it departs from zero in either
            // direction, so filter on magnitude (slider 0-50 -> 0-8 dB).
            "ZDR" => {
                let thr = threshold * 0.16;
                if v.abs() < thr {
                    0.0
                } else {
                    ((v.abs() - thr) / 3.0).clamp(0.04, 0.75)
                }
            }
            // For CC the signal is *low* values (debris, melting layer,
            // non-meteorological), so the slider raises a ceiling instead:
            // 0 shows everything, 50 isolates CC below ~0.5.
            "RHO" => {
                let ceiling = 1.05 - threshold * 0.011;
                if v > ceiling {
                    0.0
                } else {
                    ((ceiling - v) / 0.25).clamp(0.04, 0.8)
                }
            }
            _ => {
                if v < threshold {
                    0.0
                } else {
                    ((v - threshold) / 25.0).clamp(0.03, 1.0)
                }
            }
        };
        if a > 0.0 {
            let c = table.sample(v);
            pal[raw] = [c[0], c[1], c[2], (a * 255.0) as u8];
        }
    }
    pal
}

/// Session info returned by [`volume3d_open`].
pub struct Volume3DInfo {
    pub gpu: bool,
    pub half_extent_m: f32,
    /// Vertical extent in *exaggerated* world units used by the camera.
    pub top_m: f32,
}

/// Build (or rebuild) the 3D session for one volume + moment.
///
/// `hidden_classes` applies to the classified field only, and is passed in at
/// open rather than set afterwards so switching fields cannot flash a frame
/// with the switched-off classes back on.
pub fn volume3d_open(
    data: Vec<u8>,
    moment: String,
    threshold: f32,
    hidden_classes: Vec<u8>,
) -> Result<Volume3DInfo, String> {
    let vol = level2::parse(&data).map_err(|e| e.to_string())?;
    let cuts = match moment.as_str() {
        // Classification needs three moments at once; `cuts` is only used
        // below for the cone-of-silence limit, so reflectivity stands in.
        "HCA" => vol.all_sweeps("REF"),
        "SRM" => vol
            .all_sweeps("VEL")
            .iter()
            .map(|s| crate::process::storm_relative(s, DEFAULT_STORM_FROM_DEG, DEFAULT_STORM_SPEED_MS))
            .collect::<Vec<_>>(),
        m @ ("VEL" | "ZDR" | "RHO") => vol.all_sweeps(m),
        _ => vol.all_sweeps("REF"),
    };
    let categorical = moment == "HCA";
    let grid = if categorical {
        build_hca_grid(&vol)?
    } else {
        build_grid_encoded(&cuts, 384, 40, 120_000.0, 16_000.0, grid_encode_for(&moment))
            .ok_or_else(|| format!("no {moment} cuts in volume"))?
    };
    let pal = palette_3d(&moment, threshold, &hidden_classes);
    // The top cut is where the cone of silence begins.
    let el_max = cuts
        .iter()
        .map(|c| c.elevation_deg)
        .fold(f32::MIN, f32::max);
    let mut gpu = crate::render::gpu3d::GpuVolume::new(&grid, &pal, Z_EXAG, categorical).ok();
    if let Some(g) = gpu.as_mut() {
        g.set_beam_limits(el_max);
    }
    let info = Volume3DInfo {
        gpu: gpu.is_some(),
        half_extent_m: grid.half_extent_m,
        top_m: grid.top_m * Z_EXAG,
    };
    *VOL3D.lock().unwrap() = Some(Vol3DSession {
        grid,
        moment,
        gpu,
        site_lat: vol.site_lat,
        site_lon: vol.site_lon,
        threshold,
        hidden_classes,
    });
    Ok(info)
}

/// Update the opacity threshold without rebuilding the grid.
pub fn volume3d_set_threshold(threshold: f32) -> Result<(), String> {
    let mut guard = VOL3D.lock().unwrap();
    let s = guard.as_mut().ok_or("no 3D session")?;
    s.threshold = threshold;
    s.repaint();
    Ok(())
}

/// Show or hide individual classes of the classified field, by class id.
///
/// An arbitrary set rather than a cutoff: the classes have no natural order
/// to slide along — is graupel more or less than heavy rain? — and picking
/// one would decide for the user which combinations are reachable. Hiding
/// everything but graupel and hail is a reasonable thing to want.
pub fn volume3d_set_hidden_classes(classes: Vec<u8>) -> Result<(), String> {
    let mut guard = VOL3D.lock().unwrap();
    let s = guard.as_mut().ok_or("no 3D session")?;
    s.hidden_classes = classes;
    s.repaint();
    Ok(())
}

impl Vol3DSession {
    /// Rebuild the palette from whatever the filters are now. The grid is
    /// untouched, so this is a table upload rather than a re-grid.
    fn repaint(&self) {
        if let Some(gpu) = &self.gpu {
            gpu.update_palette(&palette_3d(&self.moment, self.threshold, &self.hidden_classes));
        }
    }
}

/// A raw (unencoded) RGBA frame for fast display.
pub struct RawFrame {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

/// Render one free-fly frame from the open 3D session.
#[allow(clippy::too_many_arguments)]
pub fn volume3d_render_fly(
    eye_x: f32,
    eye_y: f32,
    eye_z: f32,
    yaw_deg: f32,
    pitch_deg: f32,
    clip: Vec<f32>,
    width: u32,
    height: u32,
) -> Result<RawFrame, String> {
    let guard = VOL3D.lock().unwrap();
    let s = guard.as_ref().ok_or("no 3D session")?;
    let gpu = s.gpu.as_ref().ok_or("no GPU in session")?;
    let c = |i: usize, d: f32| clip.get(i).copied().unwrap_or(d);
    let rgba = gpu.render(
        &crate::render::gpu3d::FlyParams {
            eye: [eye_x, eye_y, eye_z],
            yaw_deg,
            pitch_deg,
            fov_deg: 55.0,
            clip_min: [c(0, 0.0), c(1, 0.0), c(2, 0.0)],
            clip_max: [c(3, 1.0), c(4, 1.0), c(5, 1.0)],
        },
        width,
        height,
    )?;
    Ok(RawFrame {
        width,
        height,
        rgba,
    })
}

/// Decode an MRMS national mosaic (gzipped GRIB2) and render the given
/// Web Mercator view box. One decode covers the whole CONUS.
#[allow(clippy::too_many_arguments)]
pub fn render_mrms_view(
    data: Vec<u8>,
    north: f64,
    south: f64,
    east: f64,
    west: f64,
    width: u32,
    height: u32,
) -> Result<RadarFrame, String> {
    let grid = crate::mrms::parse(&data, 3).map_err(|e| e.to_string())?;
    let table = ColorTable::reflectivity_default();
    let img = render::rasterize_latlon_view(&grid, &table, north, south, east, west, width, height)
        .ok_or_else(|| "empty view".to_string())?;
    Ok(RadarFrame {
        product_code: 0,
        product_name: "National Mosaic (MRMS)".into(),
        unit: "dBZ".into(),
        site_lat: (grid.north + grid.south) * 0.5,
        site_lon: (grid.east + grid.west) * 0.5,
        timestamp: grid.timestamp,
        elevation_deg: 0.0,
        vcp: 0,
        width: img.width,
        height: img.height,
        png: encode_png(img.width, img.height, &img.pixels)?,
        north: img.north,
        south: img.south,
        east: img.east,
        west: img.west,
    })
}

/// Drape a basemap image on the 3D ground plane. The image must cover the
/// volume's horizontal extent exactly, north-up, as RGBA8.
pub fn volume3d_set_ground(rgba: Vec<u8>, width: u32, height: u32) -> Result<(), String> {
    let mut guard = VOL3D.lock().unwrap();
    let s = guard.as_mut().ok_or("no 3D session")?;
    if let Some(gpu) = s.gpu.as_mut() {
        gpu.set_ground(&rgba, width, height);
    }
    Ok(())
}

/// Draw the cone of silence — the unsampled column above the radar's top cut
/// — as a translucent haze, so you can see what the radar cannot.
pub fn volume3d_show_cone(show: bool) -> Result<(), String> {
    let mut guard = VOL3D.lock().unwrap();
    let s = guard.as_mut().ok_or("no 3D session")?;
    if let Some(gpu) = s.gpu.as_mut() {
        gpu.set_show_cone(show);
    }
    Ok(())
}

/// Give the ground relief. `heights` is metres above sea level on a north-up
/// grid covering the same extent as the basemap, row-major from the north
/// edge. Pass an empty slice to go back to a flat plane.
pub fn volume3d_set_terrain(heights: Vec<f32>, width: u32, height: u32) -> Result<(), String> {
    let mut guard = VOL3D.lock().unwrap();
    let s = guard.as_mut().ok_or("no 3D session")?;
    if let Some(gpu) = s.gpu.as_mut() {
        if heights.is_empty() {
            gpu.clear_terrain();
        } else {
            gpu.set_terrain(&heights, width, height);
        }
    }
    Ok(())
}

/// Geographic bounds of the open 3D session's ground plane, so the app can
/// fetch matching map tiles: [north, south, east, west].
pub fn volume3d_ground_bounds() -> Result<Vec<f64>, String> {
    let guard = VOL3D.lock().unwrap();
    let s = guard.as_ref().ok_or("no 3D session")?;
    let ex = s.grid.half_extent_m as f64;
    let lat = s.site_lat;
    let dlat = ex / 111_320.0;
    let dlon = ex / (111_320.0 * lat.to_radians().cos().abs().max(0.01));
    Ok(vec![lat + dlat, lat - dlat, s.site_lon + dlon, s.site_lon - dlon])
}

/// Extrapolate radar echoes forward in time, entirely on-device.
///
/// `prev` and `latest` are two consecutive source files (Level 3 product
/// files when `source` is "L3", gzipped MRMS GRIB2 when "MRMS"). Motion is
/// estimated between them and the latest field is advected `minutes` ahead.
#[allow(clippy::too_many_arguments)]
pub fn nowcast_view(
    prev: Vec<u8>,
    latest: Vec<u8>,
    source: String,
    minutes: f32,
    north: f64,
    south: f64,
    east: f64,
    west: f64,
    width: u32,
    height: u32,
) -> Result<RadarFrame, String> {
    let (a_raw, b_raw, decoder, kind, name, unit, t_prev, t_latest, site) =
        if source == "MRMS" {
            let ga = crate::mrms::parse(&prev, 3).map_err(|e| e.to_string())?;
            let gb = crate::mrms::parse(&latest, 3).map_err(|e| e.to_string())?;
            let a = render::latlon_raw_view(&ga, north, south, east, west, width, height);
            let b = render::latlon_raw_view(&gb, north, south, east, west, width, height);
            (
                a,
                b,
                crate::level3::ValueDecoder::ScaleOffset {
                    scale: 2.0,
                    offset: 66.0,
                },
                ProductKind::Reflectivity,
                "National Mosaic — Forecast".to_string(),
                "dBZ".to_string(),
                ga.timestamp,
                gb.timestamp,
                ((gb.north + gb.south) * 0.5, (gb.east + gb.west) * 0.5),
            )
        } else {
            let fa = level3::parse(&prev).map_err(|e| e.to_string())?;
            let fb = level3::parse(&latest).map_err(|e| e.to_string())?;
            let sa = fa.to_sweep().ok_or("previous frame has no radial data")?;
            let sb = fb.to_sweep().ok_or("latest frame has no radial data")?;
            let a = render::sweep_raw_view(&sa, north, south, east, west, width, height);
            let b = render::sweep_raw_view(&sb, north, south, east, west, width, height);
            let kind = fb.info.map(|i| i.kind).unwrap_or(ProductKind::Reflectivity);
            let name = format!(
                "{} — Forecast",
                fb.info.map(|i| i.name).unwrap_or("Radar")
            );
            (
                a,
                b,
                sb.decoder,
                kind,
                name,
                fb.info.map(|i| i.unit.to_string()).unwrap_or_default(),
                fa.volume_scan_time,
                fb.volume_scan_time,
                (fb.site_lat, fb.site_lon),
            )
        };

    let w = width as usize;
    let h = height as usize;
    let (dx, dy) = crate::process::nowcast::estimate_motion(&a_raw, &b_raw, w, h);

    // Scale the observed displacement to the requested lead time.
    let gap = (t_latest - t_prev).max(60) as f32;
    let scale = minutes * 60.0 / gap;
    let out = crate::process::nowcast::advect(&b_raw, w, h, dx * scale, dy * scale);

    let table = ColorTable::default_for(kind);
    let img = render::colorize(
        &out, width, height, &decoder, &table, north, south, east, west,
    );

    Ok(RadarFrame {
        product_code: 0,
        product_name: name,
        unit,
        site_lat: site.0,
        site_lon: site.1,
        timestamp: t_latest + (minutes * 60.0) as i64,
        elevation_deg: 0.0,
        vcp: 0,
        width: img.width,
        height: img.height,
        png: encode_png(img.width, img.height, &img.pixels)?,
        north: img.north,
        south: img.south,
        east: img.east,
        west: img.west,
    })
}

/// One projected position along a storm's forecast path.
pub struct TrackPoint {
    pub minutes: f32,
    pub lat: f64,
    pub lon: f64,
}

/// A storm cell as the NWS's own SCIT reports it.
pub struct StormTrack {
    /// The NWS cell id, e.g. "O8". Stable between volumes, so a cell can be
    /// followed by name across scans.
    pub id: String,
    pub lat: f64,
    pub lon: f64,
    /// False when the cell has no movement solution yet; the motion fields
    /// are then meaningless and `forecast` is empty.
    pub tracked: bool,
    pub speed_kt: f32,
    /// Degrees true the storm is heading toward. The product quotes the
    /// direction it comes *from*, like wind; this is the opposite, which is
    /// what an arrow points along.
    pub heading_deg: f32,
    pub forecast: Vec<TrackPoint>,
    /// NWS forecast track error in nautical miles, where given.
    pub error_nm: f32,
}

/// Read storm tracks out of a Level 3 STI product (code 58).
///
/// These are NOAA's, not ours: the NWS runs SCIT across seven reflectivity
/// thresholds with full vertical integration and publishes the result, which
/// beats anything derivable here from a single threshold on one 2D field, and
/// carries a forecast error estimate we could not produce at all.
pub fn storm_tracks(data: Vec<u8>) -> Result<Vec<StormTrack>, String> {
    let f = level3::parse(&data).map_err(|e| e.to_string())?;
    let tab = f
        .tabular
        .as_deref()
        .ok_or("this product carries no storm table")?;
    Ok(
        crate::process::sti::parse(tab, f.site_lat, f.site_lon)
            .into_iter()
            .map(|c| StormTrack {
                id: c.id,
                lat: c.lat,
                lon: c.lon,
                tracked: c.movement.is_some(),
                speed_kt: c.movement.map_or(0.0, |m| m.speed_kt),
                heading_deg: c.movement.map_or(0.0, |m| m.heading_deg()),
                forecast: c
                    .forecast
                    .into_iter()
                    .map(|p| TrackPoint {
                        minutes: p.minutes,
                        lat: p.lat,
                        lon: p.lon,
                    })
                    .collect(),
                error_nm: c.error_fcst_nm.unwrap_or(0.0),
            })
            .collect(),
    )
}

/// One mesocyclone as the NWS's algorithm reports it.
pub struct MesoHit {
    pub id: String,
    pub lat: f64,
    pub lon: f64,
    /// Strength rank as printed, 1-9 with a trailing L for low-topped.
    /// The NWS treats 5 and above as significant.
    pub rank: String,
    /// The storm cell this belongs to, matching the storm track ids.
    pub storm_id: String,
    /// Peak rotational velocity, knots.
    pub max_rv_kt: f32,
    /// The tornado vortex signature algorithm fired on this circulation.
    pub tvs: bool,
    /// Mesocyclone Strength Index, -1 when absent.
    pub msi: i32,
    /// Motion exactly as the product prints it, e.g. "025/8". Deliberately a
    /// string: the table does not say whether the bearing is the direction of
    /// travel or the direction it came from, and the storm table quotes the
    /// latter. Rendering it as an arrow without knowing would risk pointing
    /// every one of them backwards.
    pub motion: String,
}

/// Read mesocyclone detections from a Level 3 MD product (code 141).
///
/// On a quiet volume the product is a 150-byte shell with no tabular block,
/// which is not an error: it means nothing was detected.
pub fn mesocyclones(data: Vec<u8>) -> Result<Vec<MesoHit>, String> {
    let f = level3::parse(&data).map_err(|e| e.to_string())?;
    let Some(tab) = f.tabular.as_deref() else {
        return Ok(Vec::new());
    };
    Ok(crate::process::mda::parse(tab, f.site_lat, f.site_lon)
        .into_iter()
        .map(|m| MesoHit {
            id: m.id,
            lat: m.lat,
            lon: m.lon,
            rank: m.rank,
            storm_id: m.storm_id,
            max_rv_kt: m.max_rv_kt,
            tvs: m.tvs,
            msi: m.msi.unwrap_or(-1),
            motion: m
                .motion
                .map_or(String::new(), |(d, s)| format!("{d:03.0}/{s:.0}")),
        })
        .collect())
}

/// Import a `.pal` color table; it replaces the built-in palette
/// for whichever product family the file declares. Returns that family.
pub fn install_palette(text: String) -> Result<String, String> {
    crate::palette::install_pal(&text)
}

/// Drop all imported palettes and go back to the built-in ones.
pub fn reset_palettes() {
    crate::palette::clear_custom();
}

// ---------------------------------------------------------------------------
// Inspect sessions: keep a decoded sweep around so an aiming cursor can sample
// it continuously without re-parsing the source file every move.
//
// There is one session per caller, not one per process. Several panes can have
// a cursor up at once, on different sites, products and tilts; a single global
// slot meant whichever pane opened last silently answered everyone else's
// samples, so a reflectivity readout could be showing a velocity number. Each
// open returns a handle and every read takes it back.
// ---------------------------------------------------------------------------

/// A decoded sweep held open for sampling, with the unit its values are in.
struct InspectSession {
    sweep: Sweep,
    unit: String,
}

static INSPECT: Mutex<BTreeMap<u32, InspectSession>> = Mutex::new(BTreeMap::new());

/// Handles are never reused. A `u32` keeps the generated Dart binding a plain
/// `int`, and a session is opened per cursor toggle or reload, so the counter
/// cannot run out inside a process lifetime.
static NEXT_INSPECT: AtomicU32 = AtomicU32::new(1);

/// File a decoded sweep and hand back the handle that reads it.
fn inspect_store(sweep: Sweep, unit: String) -> u32 {
    let id = NEXT_INSPECT.fetch_add(1, Ordering::Relaxed);
    INSPECT
        .lock()
        .unwrap()
        .insert(id, InspectSession { sweep, unit });
    id
}

/// Run `f` over the session `id` names.
fn with_inspect<T>(id: u32, f: impl FnOnce(&InspectSession) -> T) -> Result<T, String> {
    let guard = INSPECT.lock().unwrap();
    let session = guard.get(&id).ok_or("no inspect session")?;
    Ok(f(session))
}

/// Open a Level 3 product file for repeated sampling. Returns the session
/// handle to pass to [`inspect_sample`] and [`inspect_site`].
pub fn inspect_open_level3(data: Vec<u8>) -> Result<u32, String> {
    let file = level3::parse(&data).map_err(|e| e.to_string())?;
    let sweep = file
        .to_sweep()
        .ok_or_else(|| "product contains no radial data".to_string())?;
    let unit = file.info.map(|i| i.unit.to_string()).unwrap_or_default();
    Ok(inspect_store(sweep, unit))
}

/// Open a Level 2 moment/cut (including derived pseudo-moments) for
/// repeated sampling. Returns the session handle.
pub fn inspect_open_level2(
    data: Vec<u8>,
    moment: String,
    elevation_index: u32,
) -> Result<u32, String> {
    let vol = level2::parse(&data).map_err(|e| e.to_string())?;
    let sweep = level2_sweep(&vol, &moment, elevation_index as usize)?;
    let (_, _, unit) = moment_meta(&moment);
    Ok(inspect_store(sweep, unit))
}

/// Sample the session at a point.
pub fn inspect_sample(session: u32, lat: f64, lon: f64) -> Result<SampleResult, String> {
    with_inspect(session, |s| {
        sample_sweep(&s.sweep, s.unit.clone(), lat, lon)
    })
}

/// Radar site position of the session: [lat, lon].
pub fn inspect_site(session: u32) -> Result<Vec<f64>, String> {
    with_inspect(session, |s| vec![s.sweep.site_lat, s.sweep.site_lon])
}

/// Drop a session and free its sweep. Closing a handle that is already gone
/// is not an error: a caller shutting down should not have to care whether an
/// open it started ever finished.
pub fn inspect_close(session: u32) {
    INSPECT.lock().unwrap().remove(&session);
}

/// How many sessions are open. For tests — the UI has no use for it.
pub fn inspect_open_count() -> usize {
    INSPECT.lock().unwrap().len()
}

/// One breakpoint of a product's color scale.
pub struct ColorScaleStop {
    pub value: f32,
    pub r: u8,
    pub g: u8,
    pub b: u8,
    pub a: u8,
}

/// Everything the UI needs to draw a key for what the colors mean.
pub struct ColorScale {
    /// Breakpoints in ascending value order.
    pub stops: Vec<ColorScaleStop>,
    /// True when the renderer blends between stops, false when it steps.
    /// The key should be drawn the same way or it will not match the map.
    pub interpolate: bool,
    pub unit: String,
    /// Purple by convention, for bins that are range folded.
    pub rf_r: u8,
    pub rf_g: u8,
    pub rf_b: u8,
}

/// The color scale a product is drawn with, so the key matches the map.
///
/// Pass `moment` for Level 2 and derived products, or leave it empty and pass
/// the Level 3 `product_code` from the rendered frame. Both routes end at the
/// same `ColorTable::default_for`, which is also where a user's imported
/// `.pal` table takes over — so the key follows a custom palette too.
pub fn color_scale(product_code: i32, moment: String) -> Result<ColorScale, String> {
    let (kind, unit) = if !moment.is_empty() {
        let (kind, _, unit) = moment_meta(&moment);
        (kind, unit)
    } else {
        match level3::products::product_info(product_code as i16) {
            Some(info) => (info.kind, info.unit.to_string()),
            // Code 0 is the MRMS mosaic, which renders as reflectivity.
            None => (ProductKind::Reflectivity, "dBZ".to_string()),
        }
    };

    let table = ColorTable::default_for(kind);
    Ok(ColorScale {
        stops: table
            .stops
            .iter()
            .map(|s| ColorScaleStop {
                value: s.value,
                r: s.color[0],
                g: s.color[1],
                b: s.color[2],
                a: s.color[3],
            })
            .collect(),
        interpolate: table.interpolate,
        unit,
        rf_r: table.rf_color[0],
        rf_g: table.rf_color[1],
        rf_b: table.rf_color[2],
    })
}


#[cfg(test)]
mod tests {
    use super::*;
    use crate::process::hca::Class;

    use crate::level3::ValueDecoder;
    use crate::sweep::{GateData, SweepRadial};

    /// The session map is process-wide, so the tests that count what is open
    /// take turns rather than racing each other's opens.
    static INSPECT_TESTS: Mutex<()> = Mutex::new(());

    /// A one-radial sweep at the given site whose every gate decodes to
    /// `value`, so a sample can be traced back to which sweep answered it.
    fn flat_sweep(site_lat: f64, site_lon: f64, value: f32) -> Sweep {
        Sweep {
            site_lat,
            site_lon,
            first_gate_m: 0.0,
            gate_size_m: 250.0,
            nbins: 400,
            radials: vec![SweepRadial {
                start_az_deg: 0.0,
                delta_az_deg: 360.0,
                data: GateData::U8(vec![2u8; 400]),
            }],
            // raw 2 decodes to `value`.
            decoder: ValueDecoder::LegacyLinear { min: value, inc: 0.0 },
            timestamp: 0,
            elevation_deg: 0.5,
            max_raw: 255,
        }
    }

    /// The bug this replaced: one global slot meant a second pane opening a
    /// cursor took over the first pane's readout, so a reflectivity pane
    /// started reporting velocity numbers with no sign anything was wrong.
    #[test]
    fn two_sessions_answer_from_their_own_sweep() {
        let _turn = INSPECT_TESTS.lock();
        let a = inspect_store(flat_sweep(35.0, -97.0, 40.0), "dBZ".into());
        let b = inspect_store(flat_sweep(41.0, -104.0, -22.0), "kt".into());
        assert_ne!(a, b, "each open gets its own handle");

        // Opening b must not have disturbed a, in value or in unit.
        let sa = inspect_sample(a, 35.1, -97.0).unwrap();
        assert_eq!(sa.value, Some(40.0));
        assert_eq!(sa.unit, "dBZ");

        let sb = inspect_sample(b, 41.1, -104.0).unwrap();
        assert_eq!(sb.value, Some(-22.0));
        assert_eq!(sb.unit, "kt");

        assert_eq!(inspect_site(a).unwrap(), vec![35.0, -97.0]);
        assert_eq!(inspect_site(b).unwrap(), vec![41.0, -104.0]);

        inspect_close(a);
        inspect_close(b);
    }

    /// Closing is what keeps a long session from piling up sweeps, and a
    /// closed handle must not resolve to whatever is opened next.
    #[test]
    fn closing_frees_the_session_and_only_that_session() {
        let _turn = INSPECT_TESTS.lock();
        let before = inspect_open_count();
        let a = inspect_store(flat_sweep(35.0, -97.0, 40.0), "dBZ".into());
        let b = inspect_store(flat_sweep(35.0, -97.0, 10.0), "dBZ".into());
        assert_eq!(inspect_open_count(), before + 2);

        inspect_close(a);
        assert_eq!(inspect_open_count(), before + 1);
        assert!(inspect_sample(a, 35.1, -97.0).is_err());
        assert!(inspect_site(a).is_err());
        assert_eq!(inspect_sample(b, 35.1, -97.0).unwrap().value, Some(10.0));

        // A pane that closes twice on its way out is not an error.
        inspect_close(a);
        inspect_close(b);
        assert_eq!(inspect_open_count(), before);
    }

    /// Handles are not recycled, so a sample that was in flight when the pane
    /// reloaded fails rather than silently reading the new sweep.
    #[test]
    fn a_closed_handle_is_never_handed_out_again() {
        let _turn = INSPECT_TESTS.lock();
        let a = inspect_store(flat_sweep(35.0, -97.0, 40.0), "dBZ".into());
        inspect_close(a);
        let b = inspect_store(flat_sweep(35.0, -97.0, 40.0), "dBZ".into());
        assert_ne!(a, b);
        inspect_close(b);
    }

    /// Sampling without opening is an error, not a panic or a stale value.
    #[test]
    fn an_unknown_handle_is_an_error() {
        let Err(err) = inspect_sample(u32::MAX, 35.0, -97.0) else {
            panic!("an unopened handle sampled successfully");
        };
        assert!(err.contains("no inspect session"), "{err}");
    }

    fn visible(hidden: &[u8]) -> Vec<Class> {
        let pal = palette_3d("HCA", 0.0, hidden);
        Class::BY_SEVERITY
            .iter()
            .copied()
            .filter(|c| pal[*c as usize][3] > 0)
            .collect()
    }

    #[test]
    fn nothing_hidden_draws_every_class() {
        assert_eq!(visible(&[]).len(), Class::ALL.len());
    }

    /// Hiding one class hides exactly that class. The filter used to be a
    /// single switch over clutter and biological together, so turning off
    /// clutter alone was not expressible.
    #[test]
    fn hiding_one_class_leaves_the_rest_alone() {
        for c in Class::ALL {
            let left = visible(&[c as u8]);
            assert_eq!(left.len(), Class::ALL.len() - 1, "{:?}", c.label());
            assert!(!left.contains(&c), "{:?} still drawn", c.label());
        }
    }

    /// The point of a per-class filter rather than a cutoff: an arbitrary
    /// combination, here the two that mean an updraft.
    #[test]
    fn an_arbitrary_subset_is_reachable() {
        let hide: Vec<u8> = Class::ALL
            .iter()
            .filter(|c| !matches!(c, Class::Graupel | Class::HailRain))
            .map(|c| *c as u8)
            .collect();
        assert_eq!(visible(&hide), vec![Class::Graupel, Class::HailRain]);
    }

    #[test]
    fn hiding_everything_is_allowed_and_empties_the_volume() {
        let all: Vec<u8> = Class::ALL.iter().map(|c| *c as u8).collect();
        assert!(visible(&all).is_empty());
    }

    /// A stale id from an older build must not blank the volume or panic.
    #[test]
    fn unknown_class_ids_are_ignored() {
        assert_eq!(visible(&[0, 200, 255]).len(), Class::ALL.len());
    }

    /// The classified field has no continuous floor, so the threshold slider
    /// must not quietly filter it as well.
    #[test]
    fn the_threshold_does_not_touch_the_classified_field() {
        for thr in [0.0f32, 10.0, 25.0, 50.0] {
            let pal = palette_3d("HCA", thr, &[]);
            let shown = Class::ALL.iter().filter(|c| pal[**c as usize][3] > 0).count();
            assert_eq!(shown, Class::ALL.len(), "threshold {thr}");
        }
    }

    /// Rain before heavy rain before graupel before hail: the order a storm
    /// is read in, and the order the key lists the classes in. Not the order
    /// the palette indices happen to run.
    #[test]
    fn the_reading_order_runs_light_to_heavy() {
        let rank = |c: Class| Class::BY_SEVERITY.iter().position(|&x| x == c).unwrap();
        assert!(rank(Class::LightRain) < rank(Class::HeavyRain));
        assert!(rank(Class::HeavyRain) < rank(Class::Graupel));
        assert!(rank(Class::Graupel) < rank(Class::HailRain));
        assert!(rank(Class::GroundClutter) < rank(Class::Biological));
        assert!(rank(Class::Biological) < rank(Class::IceCrystals));
    }

    /// Every class in the reading order is a class that exists, exactly once.
    #[test]
    fn the_reading_order_is_a_permutation_of_the_classes() {
        let mut a = Class::BY_SEVERITY.to_vec();
        let mut b = Class::ALL.to_vec();
        a.sort_by_key(|c| *c as u8);
        b.sort_by_key(|c| *c as u8);
        assert_eq!(a, b);
    }
}
