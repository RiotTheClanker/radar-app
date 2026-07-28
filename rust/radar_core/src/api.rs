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
    let sweep = vol
        .sweep(&moment, elevation_index as usize)
        .ok_or_else(|| format!("moment {moment} cut {elevation_index} not in volume"))?;
    let (kind, name, unit) = moment_meta(&moment);
    frame_from_sweep(&sweep, kind, 0, name, unit, vol.vcp as i32, image_size)
}

/// Elevation cuts available for a moment in a Level 2 volume, in scan order.
pub fn level2_cuts(data: Vec<u8>, moment: String) -> Result<Vec<f32>, String> {
    let vol = level2::parse(&data).map_err(|e| e.to_string())?;
    Ok(vol.cuts_for(&moment).iter().map(|c| c.elevation_deg).collect())
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
    SampleResult {
        value,
        range_folded,
        unit,
        distance_km: dist / 1000.0,
        beam_height_m: sweep.beam_height_m(dist),
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
    let sweep = vol
        .sweep(&moment, elevation_index as usize)
        .ok_or_else(|| format!("moment {moment} cut {elevation_index} not in volume"))?;
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
        _ => (ProductKind::Reflectivity, "Base Reflectivity (L2)".into(), "dBZ".into()),
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
