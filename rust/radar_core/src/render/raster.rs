//! Radial-to-raster rendering.
//!
//! Output images are sampled in Web Mercator so a map view can stretch them
//! linearly between corner coordinates with no visible misregistration.
//! Each pixel is inverse-mapped to (azimuth, range) from the radar site and
//! looks up the matching gate — no polygon tessellation, no seams.

use crate::sweep::{GateData, Sweep};
use crate::render::ColorTable;

const EARTH_R: f64 = 6_371_000.0;
const M_PER_DEG_LAT: f64 = 111_320.0;

#[derive(Debug, Clone)]
pub struct GeoImage {
    pub width: u32,
    pub height: u32,
    /// RGBA, row-major from the north-west corner.
    pub pixels: Vec<u8>,
    pub north: f64,
    pub south: f64,
    pub east: f64,
    pub west: f64,
}

fn merc_y(lat_rad: f64) -> f64 {
    (std::f64::consts::FRAC_PI_4 + lat_rad / 2.0).tan().ln()
}

fn inv_merc_y(y: f64) -> f64 {
    2.0 * y.exp().atan() - std::f64::consts::FRAC_PI_2
}

/// Sample a sweep into a view box as *raw encoded values* (not colors).
/// Used by the nowcaster, which needs to track and warp the field itself.
#[allow(clippy::too_many_arguments)]
pub fn sweep_raw_view(
    sweep: &Sweep,
    north: f64,
    south: f64,
    east: f64,
    west: f64,
    width: u32,
    height: u32,
) -> Vec<u8> {
    let w = width as usize;
    let h = height as usize;
    let mut out = vec![0u8; w * h];
    if north <= south || east <= west || sweep.radials.is_empty() {
        return out;
    }
    let site_lat = sweep.site_lat.to_radians();
    let site_lon = sweep.site_lon.to_radians();
    let az_lut = azimuth_lut(sweep);
    let y_n = merc_y(north.to_radians());
    let y_s = merc_y(south.to_radians());
    let sin_site = site_lat.sin();
    let cos_site = site_lat.cos();
    let inv_gate = 1.0 / sweep.gate_size_m as f64;
    let gate_origin = sweep.first_gate_m as f64 - sweep.gate_size_m as f64 * 0.5;
    let nbins = sweep.nbins as i64;

    for py in 0..h {
        let ty = (py as f64 + 0.5) / h as f64;
        let lat = inv_merc_y(y_n + (y_s - y_n) * ty);
        let sin_lat = lat.sin();
        let cos_lat = lat.cos();
        for px in 0..w {
            let tx = (px as f64 + 0.5) / w as f64;
            let lon = (west + (east - west) * tx).to_radians();
            let dlon_r = lon - site_lon;
            let cos_c = (sin_site * sin_lat + cos_site * cos_lat * dlon_r.cos()).clamp(-1.0, 1.0);
            let dist = cos_c.acos() * EARTH_R;
            let bin = ((dist - gate_origin) * inv_gate) as i64;
            if bin < 0 || bin >= nbins {
                continue;
            }
            let az = dlon_r
                .sin()
                .mul_add(cos_lat, 0.0)
                .atan2(cos_site * sin_lat - sin_site * cos_lat * dlon_r.cos())
                .to_degrees();
            let az10 = (((az * 10.0).round() as i32) % 3600 + 3600) % 3600;
            let ridx = az_lut[az10 as usize];
            if ridx < 0 {
                continue;
            }
            if let Some(raw) = sweep.radials[ridx as usize].data.get(bin as usize) {
                out[py * w + px] = raw.min(255) as u8;
            }
        }
    }
    out
}

/// Sample a lat/lon grid into a view box as raw encoded values.
#[allow(clippy::too_many_arguments)]
pub fn latlon_raw_view(
    grid: &crate::mrms::LatLonGrid,
    north: f64,
    south: f64,
    east: f64,
    west: f64,
    width: u32,
    height: u32,
) -> Vec<u8> {
    let w = width as usize;
    let h = height as usize;
    let mut out = vec![0u8; w * h];
    if north <= south || east <= west {
        return out;
    }
    let y_n = merc_y(north.to_radians());
    let y_s = merc_y(south.to_radians());
    let dx = (grid.east - grid.west) / grid.nx as f64;
    let dy = (grid.north - grid.south) / grid.ny as f64;
    for py in 0..h {
        let ty = (py as f64 + 0.5) / h as f64;
        let lat = inv_merc_y(y_n + (y_s - y_n) * ty).to_degrees();
        let gy = ((grid.north - lat) / dy) as i64;
        if gy < 0 || gy >= grid.ny as i64 {
            continue;
        }
        for px in 0..w {
            let tx = (px as f64 + 0.5) / w as f64;
            let lon = west + (east - west) * tx;
            let gx = ((lon - grid.west) / dx) as i64;
            if gx < 0 || gx >= grid.nx as i64 {
                continue;
            }
            out[py * w + px] = grid.data[gy as usize * grid.nx + gx as usize];
        }
    }
    out
}

/// Colorize a raw-value grid with a product's decoder and palette.
pub fn colorize(
    raw: &[u8],
    width: u32,
    height: u32,
    decoder: &crate::level3::ValueDecoder,
    table: &ColorTable,
    north: f64,
    south: f64,
    east: f64,
    west: f64,
) -> GeoImage {
    let lut = table.build_lut(decoder, 256);
    let mut pixels = vec![0u8; raw.len() * 4];
    for (i, &v) in raw.iter().enumerate() {
        let c = lut[v as usize];
        if c[3] == 0 {
            continue;
        }
        pixels[i * 4..i * 4 + 4].copy_from_slice(&c);
    }
    GeoImage {
        width,
        height,
        pixels,
        north,
        south,
        east,
        west,
    }
}

/// Render a regular lat/lon grid (MRMS mosaic) into a Web Mercator view box.
#[allow(clippy::too_many_arguments)]
pub fn rasterize_latlon_view(
    grid: &crate::mrms::LatLonGrid,
    table: &ColorTable,
    north: f64,
    south: f64,
    east: f64,
    west: f64,
    width: u32,
    height: u32,
) -> Option<GeoImage> {
    if north <= south || east <= west || grid.data.is_empty() {
        return None;
    }
    // Grid values use the shared dBZ encoding (raw = dBZ*2 + 66).
    let lut = table.build_lut(
        &crate::level3::ValueDecoder::ScaleOffset {
            scale: 2.0,
            offset: 66.0,
        },
        256,
    );

    let w = width as usize;
    let h = height as usize;
    let mut pixels = vec![0u8; w * h * 4];
    let y_n = merc_y(north.to_radians());
    let y_s = merc_y(south.to_radians());
    let dx = (grid.east - grid.west) / grid.nx as f64;
    let dy = (grid.north - grid.south) / grid.ny as f64;

    for py in 0..h {
        let ty = (py as f64 + 0.5) / h as f64;
        let lat = inv_merc_y(y_n + (y_s - y_n) * ty).to_degrees();
        let gy = ((grid.north - lat) / dy) as i64;
        if gy < 0 || gy >= grid.ny as i64 {
            continue;
        }
        let grow = &grid.data[gy as usize * grid.nx..(gy as usize + 1) * grid.nx];
        let row = &mut pixels[py * w * 4..(py + 1) * w * 4];
        for px in 0..w {
            let tx = (px as f64 + 0.5) / w as f64;
            let lon = west + (east - west) * tx;
            let gx = ((lon - grid.west) / dx) as i64;
            if gx < 0 || gx >= grid.nx as i64 {
                continue;
            }
            let color = lut[grow[gx as usize] as usize];
            if color[3] == 0 {
                continue;
            }
            let o = px * 4;
            row[o..o + 4].copy_from_slice(&color);
        }
    }

    Some(GeoImage {
        width,
        height,
        pixels,
        north,
        south,
        east,
        west,
    })
}

/// Build a 0.1°-resolution azimuth -> radial-index lookup table.
fn azimuth_lut(sweep: &Sweep) -> Vec<i32> {
    let mut lut = vec![-1i32; 3600];
    for (idx, rad) in sweep.radials.iter().enumerate() {
        let start = (rad.start_az_deg * 10.0).round() as i32;
        let steps = (rad.delta_az_deg * 10.0).round().max(1.0) as i32;
        for s in 0..steps {
            let a = ((start + s) % 3600 + 3600) % 3600;
            lut[a as usize] = idx as i32;
        }
    }
    lut
}

/// Geographic bounding box of a sweep's full data disk.
pub fn sweep_bounds(sweep: &Sweep) -> (f64, f64, f64, f64) {
    let range_m = sweep.max_range_m() as f64;
    let site_lat = sweep.site_lat.to_radians();
    let dlat = range_m / M_PER_DEG_LAT;
    let dlon = range_m / (M_PER_DEG_LAT * site_lat.cos().abs().max(0.01));
    (
        sweep.site_lat + dlat,
        sweep.site_lat - dlat,
        sweep.site_lon + dlon,
        sweep.site_lon - dlon,
    )
}

/// Render a sweep's full data disk to a square georeferenced RGBA image.
pub fn rasterize_sweep(sweep: &Sweep, table: &ColorTable, size: u32) -> Option<GeoImage> {
    let (north, south, east, west) = sweep_bounds(sweep);
    rasterize_sweep_view(sweep, table, north, south, east, west, size, size)
}

/// Render a sweep into an arbitrary Web Mercator view box. This is what
/// keeps gates sharp: the app asks for exactly the visible region at screen
/// resolution instead of stretching one fixed whole-disk image.
#[allow(clippy::too_many_arguments)]
pub fn rasterize_sweep_view(
    sweep: &Sweep,
    table: &ColorTable,
    north: f64,
    south: f64,
    east: f64,
    west: f64,
    width: u32,
    height: u32,
) -> Option<GeoImage> {
    let range_m = sweep.max_range_m() as f64;
    if range_m <= 0.0 || sweep.radials.is_empty() || north <= south || east <= west {
        return None;
    }

    let site_lat = sweep.site_lat.to_radians();
    let site_lon = sweep.site_lon.to_radians();

    // Color LUT sized to the actual raw range (256 for 8-bit, larger for
    // 16-bit moments).
    let lut_len = ((sweep.max_raw as usize) + 2).clamp(256, 65536);
    let lut = table.build_lut(&sweep.decoder, lut_len);
    let az_lut = azimuth_lut(sweep);

    let w = width as usize;
    let h = height as usize;
    let mut pixels = vec![0u8; w * h * 4];

    let y_n = merc_y(north.to_radians());
    let y_s = merc_y(south.to_radians());
    let sin_site = site_lat.sin();
    let cos_site = site_lat.cos();
    let inv_gate = 1.0 / sweep.gate_size_m as f64;
    // Gate i covers [first_gate + (i-0.5)*gate, first_gate + (i+0.5)*gate).
    let gate_origin = sweep.first_gate_m as f64 - sweep.gate_size_m as f64 * 0.5;
    let nbins = sweep.nbins as i64;

    for py in 0..h {
        // Row latitude via Mercator interpolation between the box edges.
        let ty = (py as f64 + 0.5) / h as f64;
        let lat = inv_merc_y(y_n + (y_s - y_n) * ty);
        let sin_lat = lat.sin();
        let cos_lat = lat.cos();
        let row = &mut pixels[py * w * 4..(py + 1) * w * 4];

        for px in 0..w {
            let tx = (px as f64 + 0.5) / w as f64;
            let lon = (west + (east - west) * tx).to_radians();
            let dlon_r = lon - site_lon;

            // Great-circle distance and initial bearing from the site.
            let cos_c = (sin_site * sin_lat + cos_site * cos_lat * dlon_r.cos()).clamp(-1.0, 1.0);
            let dist = cos_c.acos() * EARTH_R;

            let bin = ((dist - gate_origin) * inv_gate) as i64;
            if bin < 0 || bin >= nbins {
                continue;
            }

            let az = dlon_r
                .sin()
                .mul_add(cos_lat, 0.0)
                .atan2(cos_site * sin_lat - sin_site * cos_lat * dlon_r.cos())
                .to_degrees();
            let az10 = (((az * 10.0).round() as i32) % 3600 + 3600) % 3600;
            let ridx = az_lut[az10 as usize];
            if ridx < 0 {
                continue;
            }
            let data = &sweep.radials[ridx as usize].data;
            let raw = match data {
                GateData::U8(v) => match v.get(bin as usize) {
                    Some(&b) => b as usize,
                    None => continue,
                },
                GateData::U16(v) => match v.get(bin as usize) {
                    Some(&b) => b as usize,
                    None => continue,
                },
            };
            let color = lut[raw.min(lut_len - 1)];
            if color[3] == 0 {
                continue;
            }
            let o = px * 4;
            row[o..o + 4].copy_from_slice(&color);
        }
    }

    Some(GeoImage {
        width,
        height,
        pixels,
        north,
        south,
        east,
        west,
    })
}
