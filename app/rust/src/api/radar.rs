//! Bridge surface for the radar_core engine.

use radar_core::api as core;

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
    pub png: Vec<u8>,
    pub north: f64,
    pub south: f64,
    pub east: f64,
    pub west: f64,
}

/// Decode a raw Level 3 product file and render it to a georeferenced RGBA
/// PNG image, ready to overlay on the map.
pub fn render_level3_frame(data: Vec<u8>, image_size: u32) -> Result<RadarFrame, String> {
    let f = core::render_level3_frame(data, image_size)?;
    Ok(RadarFrame {
        product_code: f.product_code,
        product_name: f.product_name,
        unit: f.unit,
        site_lat: f.site_lat,
        site_lon: f.site_lon,
        timestamp: f.timestamp,
        elevation_deg: f.elevation_deg,
        vcp: f.vcp,
        width: f.width,
        height: f.height,
        png: f.png,
        north: f.north,
        south: f.south,
        east: f.east,
        west: f.west,
    })
}
