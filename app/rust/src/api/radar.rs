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

/// Decode a full Level 2 (Archive II) volume and render one moment at one
/// elevation cut. `moment`: REF, VEL, SW, ZDR, PHI, or RHO.
pub fn render_level2_frame(
    data: Vec<u8>,
    moment: String,
    elevation_index: u32,
    image_size: u32,
) -> Result<RadarFrame, String> {
    convert(core::render_level2_frame(data, moment, elevation_index, image_size)?)
}

/// Elevation angles (deg) available for a moment in a Level 2 volume.
pub fn level2_cuts(data: Vec<u8>, moment: String) -> Result<Vec<f32>, String> {
    core::level2_cuts(data, moment)
}

/// Viewport-matched render of a Level 3 product (sharp at any zoom).
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
    convert(core::render_level3_view(data, north, south, east, west, width, height)?)
}

/// Viewport-matched render of a Level 2 moment/cut (sharp at any zoom).
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
    convert(core::render_level2_view(
        data,
        moment,
        elevation_index,
        north,
        south,
        east,
        west,
        width,
        height,
    )?)
}

/// Result of sampling a product at a point (the "inspector" tool).
pub struct SampleResult {
    pub value: Option<f32>,
    pub range_folded: bool,
    pub unit: String,
    pub distance_km: f64,
    pub beam_height_m: f64,
}

/// Sample a Level 3 product file at a geographic point.
pub fn sample_level3(data: Vec<u8>, lat: f64, lon: f64) -> Result<SampleResult, String> {
    let s = core::sample_level3(data, lat, lon)?;
    Ok(convert_sample(s))
}

/// Sample a Level 2 volume's moment/cut at a geographic point.
pub fn sample_level2(
    data: Vec<u8>,
    moment: String,
    elevation_index: u32,
    lat: f64,
    lon: f64,
) -> Result<SampleResult, String> {
    let s = core::sample_level2(data, moment, elevation_index, lat, lon)?;
    Ok(convert_sample(s))
}

fn convert_sample(s: core::SampleResult) -> SampleResult {
    SampleResult {
        value: s.value,
        range_folded: s.range_folded,
        unit: s.unit,
        distance_km: s.distance_km,
        beam_height_m: s.beam_height_m,
    }
}

fn convert(f: core::RadarFrame) -> Result<RadarFrame, String> {
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
