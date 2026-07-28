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

/// Lightning flashes parsed from one GOES GLM L2 LCFA file.
pub struct GlmResult {
    pub timestamp: i64,
    pub lats: Vec<f32>,
    pub lons: Vec<f32>,
}

/// Parse a GOES GLM L2 LCFA netCDF file (pure-Rust HDF5 subset reader).
pub fn parse_glm(data: Vec<u8>) -> Result<GlmResult, String> {
    let g = core::parse_glm(data)?;
    Ok(GlmResult {
        timestamp: g.timestamp,
        lats: g.lats,
        lons: g.lons,
    })
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

/// A rendered 3D volume frame.
pub struct Volume3DFrame {
    pub width: u32,
    pub height: u32,
    pub png: Vec<u8>,
    pub timestamp: i64,
}

/// Render a 3D volume view of a Level 2 volume's reflectivity as a PNG.
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
    let f = core::render_volume3d(data, yaw_deg, pitch_deg, zoom, dbz_min, width, height)?;
    Ok(Volume3DFrame {
        width: f.width,
        height: f.height,
        png: f.png,
        timestamp: f.timestamp,
    })
}

/// Info about an open 3D fly-through session.
pub struct Volume3DInfo {
    pub gpu: bool,
    pub half_extent_m: f32,
    pub top_m: f32,
}

/// Build (or rebuild) the 3D session for one volume + moment
/// (REF, SRM, VEL, ZDR, RHO).
pub fn volume3d_open(
    data: Vec<u8>,
    moment: String,
    threshold: f32,
) -> Result<Volume3DInfo, String> {
    let i = core::volume3d_open(data, moment, threshold)?;
    Ok(Volume3DInfo {
        gpu: i.gpu,
        half_extent_m: i.half_extent_m,
        top_m: i.top_m,
    })
}

/// Update the 3D opacity threshold without rebuilding the grid.
pub fn volume3d_set_threshold(threshold: f32) -> Result<(), String> {
    core::volume3d_set_threshold(threshold)
}

/// A raw RGBA frame (no PNG encode) for fast display.
pub struct RawFrame {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

/// Render one free-fly frame. `clip` = [minx,miny,minz,maxx,maxy,maxz] 0..1.
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
    let f = core::volume3d_render_fly(eye_x, eye_y, eye_z, yaw_deg, pitch_deg, clip, width, height)?;
    Ok(RawFrame {
        width: f.width,
        height: f.height,
        rgba: f.rgba,
    })
}

/// Decode an MRMS national mosaic (gzipped GRIB2) and render a view box.
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
    convert(core::render_mrms_view(data, north, south, east, west, width, height)?)
}

/// Drape a basemap image (RGBA8, north-up, covering the volume extent) on
/// the 3D ground plane.
pub fn volume3d_set_ground(rgba: Vec<u8>, width: u32, height: u32) -> Result<(), String> {
    core::volume3d_set_ground(rgba, width, height)
}

/// Ground-plane bounds of the open 3D session: [north, south, east, west].
pub fn volume3d_ground_bounds() -> Result<Vec<f64>, String> {
    core::volume3d_ground_bounds()
}
