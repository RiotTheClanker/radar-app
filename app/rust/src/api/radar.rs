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
    /// Compass bearing from the radar to the sampled point.
    pub azimuth_deg: f64,
    /// Elevation angle of the sampled sweep.
    pub elevation_deg: f32,
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
        azimuth_deg: s.azimuth_deg,
        elevation_deg: s.elevation_deg,
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

/// On-device future radar: estimate motion between two consecutive frames
/// and extrapolate. `source` is "L3" or "MRMS".
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
    convert(core::nowcast_view(
        prev, latest, source, minutes, north, south, east, west, width, height,
    )?)
}

/// One projected position along a storm's forecast path.
pub struct TrackPoint {
    pub minutes: f32,
    pub lat: f64,
    pub lon: f64,
}

/// A storm cell as the NWS's own SCIT reports it.
pub struct StormTrack {
    /// NWS cell id, e.g. "O8" — stable between volumes.
    pub id: String,
    pub lat: f64,
    pub lon: f64,
    /// False when the cell has no movement solution yet.
    pub tracked: bool,
    pub speed_kt: f32,
    /// Degrees true the storm is heading toward.
    pub heading_deg: f32,
    pub forecast: Vec<TrackPoint>,
    /// NWS forecast track error in nautical miles, where given.
    pub error_nm: f32,
}

/// Read storm tracks out of a Level 3 STI product (code 58, key `xxx_NST_`).
pub fn storm_tracks(data: Vec<u8>) -> Result<Vec<StormTrack>, String> {
    Ok(core::storm_tracks(data)?
        .into_iter()
        .map(|s| StormTrack {
            id: s.id,
            lat: s.lat,
            lon: s.lon,
            tracked: s.tracked,
            speed_kt: s.speed_kt,
            heading_deg: s.heading_deg,
            forecast: s
                .forecast
                .into_iter()
                .map(|p| TrackPoint {
                    minutes: p.minutes,
                    lat: p.lat,
                    lon: p.lon,
                })
                .collect(),
            error_nm: s.error_nm,
        })
        .collect())
}

/// One mesocyclone as the NWS's algorithm reports it.
pub struct MesoHit {
    pub id: String,
    pub lat: f64,
    pub lon: f64,
    /// Strength rank as printed; the NWS treats 5 and above as significant.
    pub rank: String,
    /// The storm cell this belongs to, matching the storm track ids.
    pub storm_id: String,
    pub max_rv_kt: f32,
    /// The tornado vortex signature algorithm fired on this circulation.
    pub tvs: bool,
    /// Mesocyclone Strength Index, -1 when absent.
    pub msi: i32,
    /// Motion as the product prints it, e.g. "025/8" — see the engine for why
    /// this is not an angle.
    pub motion: String,
}

/// Read mesocyclone detections from a Level 3 MD product (key `xxx_NMD_`).
/// An empty list means nothing was detected, not an error.
pub fn mesocyclones(data: Vec<u8>) -> Result<Vec<MesoHit>, String> {
    Ok(core::mesocyclones(data)?
        .into_iter()
        .map(|m| MesoHit {
            id: m.id,
            lat: m.lat,
            lon: m.lon,
            rank: m.rank,
            storm_id: m.storm_id,
            max_rv_kt: m.max_rv_kt,
            tvs: m.tvs,
            msi: m.msi,
            motion: m.motion,
        })
        .collect())
}

/// Import a `.pal` color table. Returns the product family it
/// applies to.
pub fn install_palette(text: String) -> Result<String, String> {
    core::install_palette(text)
}

/// Drop imported palettes and return to the built-in ones.
pub fn reset_palettes() {
    core::reset_palettes()
}

/// Open a Level 3 product file for repeated cursor sampling.
pub fn inspect_open_level3(data: Vec<u8>) -> Result<(), String> {
    core::inspect_open_level3(data)
}

/// Open a Level 2 moment/cut for repeated cursor sampling.
pub fn inspect_open_level2(
    data: Vec<u8>,
    moment: String,
    elevation_index: u32,
) -> Result<(), String> {
    core::inspect_open_level2(data, moment, elevation_index)
}

/// Sample the open inspect session at a point (fast; no re-decode).
pub fn inspect_sample(lat: f64, lon: f64) -> Result<SampleResult, String> {
    Ok(convert_sample(core::inspect_sample(lat, lon)?))
}

/// Radar site of the open inspect session: [lat, lon].
pub fn inspect_site() -> Result<Vec<f64>, String> {
    core::inspect_site()
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
    /// True when the renderer blends between stops, false when it steps. The
    /// key must be drawn the same way or it will not match the map.
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
/// the Level 3 `product_code` from the rendered frame.
pub fn color_scale(product_code: i32, moment: String) -> Result<ColorScale, String> {
    let s = core::color_scale(product_code, moment)?;
    Ok(ColorScale {
        stops: s
            .stops
            .into_iter()
            .map(|st| ColorScaleStop {
                value: st.value,
                r: st.r,
                g: st.g,
                b: st.b,
                a: st.a,
            })
            .collect(),
        interpolate: s.interpolate,
        unit: s.unit,
        rf_r: s.rf_r,
        rf_g: s.rf_g,
        rf_b: s.rf_b,
    })
}

/// Give the 3D ground relief. `heights` is metres above sea level on a
/// north-up grid covering the same extent as the basemap, row-major from the
/// north edge. Pass an empty list to go back to a flat plane.
pub fn volume3d_set_terrain(heights: Vec<f32>, width: u32, height: u32) -> Result<(), String> {
    core::volume3d_set_terrain(heights, width, height)
}

/// Draw the cone of silence — the unsampled column above the radar's top cut
/// — as a translucent haze, so you can see what the radar cannot.
pub fn volume3d_show_cone(show: bool) -> Result<(), String> {
    core::volume3d_show_cone(show)
}
