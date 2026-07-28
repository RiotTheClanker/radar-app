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
use std::sync::Mutex;

struct Vol3DSession {
    grid: Grid3D,
    moment: String,
    gpu: Option<crate::render::gpu3d::GpuVolume>,
    site_lat: f64,
    site_lon: f64,
}

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
fn palette_3d(moment: &str, threshold: f32) -> [[u8; 4]; 256] {
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
pub fn volume3d_open(data: Vec<u8>, moment: String, threshold: f32) -> Result<Volume3DInfo, String> {
    let vol = level2::parse(&data).map_err(|e| e.to_string())?;
    let cuts = match moment.as_str() {
        "SRM" => vol
            .all_sweeps("VEL")
            .iter()
            .map(|s| crate::process::storm_relative(s, DEFAULT_STORM_FROM_DEG, DEFAULT_STORM_SPEED_MS))
            .collect::<Vec<_>>(),
        m @ ("VEL" | "ZDR" | "RHO") => vol.all_sweeps(m),
        _ => vol.all_sweeps("REF"),
    };
    let grid = build_grid_encoded(&cuts, 384, 40, 120_000.0, 16_000.0, grid_encode_for(&moment))
        .ok_or_else(|| format!("no {moment} cuts in volume"))?;
    let pal = palette_3d(&moment, threshold);
    let gpu = crate::render::gpu3d::GpuVolume::new(&grid, &pal, Z_EXAG).ok();
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
    });
    Ok(info)
}

/// Update the opacity threshold without rebuilding the grid.
pub fn volume3d_set_threshold(threshold: f32) -> Result<(), String> {
    let guard = VOL3D.lock().unwrap();
    let s = guard.as_ref().ok_or("no 3D session")?;
    if let Some(gpu) = &s.gpu {
        gpu.update_palette(&palette_3d(&s.moment, threshold));
    }
    Ok(())
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

/// Import a GRLevelX `.pal` color table; it replaces the built-in palette
/// for whichever product family the file declares. Returns that family.
pub fn install_palette(text: String) -> Result<String, String> {
    crate::palette::install_pal(&text)
}

/// Drop all imported palettes and go back to the built-in ones.
pub fn reset_palettes() {
    crate::palette::clear_custom();
}

// ---------------------------------------------------------------------------
// Inspect session: keep one decoded sweep around so an aiming cursor can
// sample it continuously without re-parsing the source file every move.
// ---------------------------------------------------------------------------

static INSPECT: Mutex<Option<(Sweep, String)>> = Mutex::new(None);

/// Open a Level 3 product file for repeated sampling.
pub fn inspect_open_level3(data: Vec<u8>) -> Result<(), String> {
    let file = level3::parse(&data).map_err(|e| e.to_string())?;
    let sweep = file
        .to_sweep()
        .ok_or_else(|| "product contains no radial data".to_string())?;
    let unit = file.info.map(|i| i.unit.to_string()).unwrap_or_default();
    *INSPECT.lock().unwrap() = Some((sweep, unit));
    Ok(())
}

/// Open a Level 2 moment/cut (including derived pseudo-moments) for
/// repeated sampling.
pub fn inspect_open_level2(
    data: Vec<u8>,
    moment: String,
    elevation_index: u32,
) -> Result<(), String> {
    let vol = level2::parse(&data).map_err(|e| e.to_string())?;
    let sweep = level2_sweep(&vol, &moment, elevation_index as usize)?;
    let (_, _, unit) = moment_meta(&moment);
    *INSPECT.lock().unwrap() = Some((sweep, unit));
    Ok(())
}

/// Sample the open inspect session at a point.
pub fn inspect_sample(lat: f64, lon: f64) -> Result<SampleResult, String> {
    let guard = INSPECT.lock().unwrap();
    let (sweep, unit) = guard.as_ref().ok_or("no inspect session")?;
    Ok(sample_sweep(sweep, unit.clone(), lat, lon))
}

/// Radar site position of the open inspect session: [lat, lon].
pub fn inspect_site() -> Result<Vec<f64>, String> {
    let guard = INSPECT.lock().unwrap();
    let (sweep, _) = guard.as_ref().ok_or("no inspect session")?;
    Ok(vec![sweep.site_lat, sweep.site_lon])
}
