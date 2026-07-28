//! Public engine API — this is the surface exposed to the Flutter app via
//! flutter_rust_bridge. Signatures stay simple (owned types, String errors)
//! so the generated bindings are clean.

use crate::level3;
use crate::render::{self, ColorTable};

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
        .unwrap_or(level3::products::ProductKind::Reflectivity);
    let table = ColorTable::default_for(kind);
    let img = render::rasterize_radials(&file, &table, image_size)
        .ok_or_else(|| "product contains no radial data".to_string())?;

    Ok(RadarFrame {
        product_code: file.product_code as i32,
        product_name: file
            .info
            .map(|i| i.name.to_string())
            .unwrap_or_else(|| format!("Product {}", file.product_code)),
        unit: file.info.map(|i| i.unit.to_string()).unwrap_or_default(),
        site_lat: file.site_lat,
        site_lon: file.site_lon,
        timestamp: file.volume_scan_time,
        elevation_deg: file.elevation_angle_deg,
        vcp: file.vcp as i32,
        width: img.width,
        height: img.height,
        png: encode_png(img.width, img.height, &img.pixels)?,
        north: img.north,
        south: img.south,
        east: img.east,
        west: img.west,
    })
}
