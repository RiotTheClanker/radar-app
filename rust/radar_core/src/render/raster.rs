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

/// Render a sweep to a georeferenced RGBA image.
pub fn rasterize_sweep(sweep: &Sweep, table: &ColorTable, size: u32) -> Option<GeoImage> {
    let range_m = sweep.max_range_m() as f64;
    if range_m <= 0.0 || sweep.radials.is_empty() {
        return None;
    }

    let site_lat = sweep.site_lat.to_radians();
    let site_lon = sweep.site_lon.to_radians();

    let dlat = range_m / M_PER_DEG_LAT;
    let dlon = range_m / (M_PER_DEG_LAT * site_lat.cos().abs().max(0.01));
    let north = sweep.site_lat + dlat;
    let south = sweep.site_lat - dlat;
    let east = sweep.site_lon + dlon;
    let west = sweep.site_lon - dlon;

    // Color LUT sized to the actual raw range (256 for 8-bit, larger for
    // 16-bit moments).
    let lut_len = ((sweep.max_raw as usize) + 2).clamp(256, 65536);
    let lut = table.build_lut(&sweep.decoder, lut_len);
    let az_lut = azimuth_lut(sweep);

    let w = size as usize;
    let h = size as usize;
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
        width: size,
        height: size,
        pixels,
        north,
        south,
        east,
        west,
    })
}
