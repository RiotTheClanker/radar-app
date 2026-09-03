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

/// Render a model field on a Lambert Conformal grid into a web-Mercator view
/// box, the same way [`rasterize_latlon_view`] does for a lat/lon one.
///
/// Values are physical rather than a packed byte, so this samples the colour
/// table directly instead of going through a 256-entry lookup — a CAPE field
/// spans 0 to 5000 J/kg and quantising it to 256 steps to save a compare per
/// pixel would be a strange trade.
///
/// Nearest-neighbour. The grid is 3 km and the screen is rarely finer than
/// that over a useful area; interpolating would smooth a field that is
/// already smooth and hide where the model put a sharp gradient.
pub fn rasterize_lambert_view(
    field: &crate::grib2::Grib2Field,
    table: &ColorTable,
    north: f64,
    south: f64,
    east: f64,
    west: f64,
    width: u32,
    height: u32,
) -> Option<GeoImage> {
    if north <= south || east <= west || field.values.is_empty() {
        return None;
    }
    let w = width as usize;
    let h = height as usize;
    let mut pixels = vec![0u8; w * h * 4];
    let y_n = merc_y(north.to_radians());
    let y_s = merc_y(south.to_radians());

    for py in 0..h {
        let ty = (py as f64 + 0.5) / h as f64;
        let lat = inv_merc_y(y_n + (y_s - y_n) * ty).to_degrees();
        let row = &mut pixels[py * w * 4..(py + 1) * w * 4];
        for px in 0..w {
            let tx = (px as f64 + 0.5) / w as f64;
            let lon = west + (east - west) * tx;
            let (gi, gj) = field.grid.to_grid(lat, lon);
            let Some(idx) = field.grid.index(gi, gj) else {
                continue; // outside the model domain
            };
            let color = table.sample(field.values[idx]);
            if color[3] == 0 {
                continue; // below the scale, e.g. air that is not unstable
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
/// Map each 0.1-degree azimuth slot to the radial that covers it.
///
/// Each radial claims `delta_az_deg` worth of slots from where it starts.
/// That tiles perfectly for Level 3, whose radials are exactly one degree
/// apart on whole degrees. Level 2 super-resolution radials are nominally
/// half a degree apart but their reported start azimuths drift, so radial n
/// covers 10.0-10.5 while radial n+1 starts at 10.57 and the slot between
/// belongs to nobody. Every unclaimed slot is a thin black spoke through the
/// echo, radiating from the site -- issue #28.
///
/// Unclaimed slots are therefore given to whichever neighbouring radial is
/// angularly nearer, but only across small gaps. A radar that genuinely did
/// not look somewhere -- sector blanking, a failed transmit -- leaves a wide
/// hole, and smearing a radial across it would invent coverage. Two degrees
/// is far more than any drift and far less than any real outage.
fn azimuth_lut(sweep: &Sweep) -> Vec<i32> {
    const SLOTS: usize = 3600;
    /// Widest gap to close: two degrees, in 0.1-degree slots.
    const MAX_FILL: i32 = 20;

    let mut lut = vec![-1i32; SLOTS];
    for (idx, rad) in sweep.radials.iter().enumerate() {
        let start = (rad.start_az_deg * 10.0).round() as i32;
        let steps = (rad.delta_az_deg * 10.0).round().max(1.0) as i32;
        for s in 0..steps {
            let a = ((start + s) % 3600 + 3600) % 3600;
            lut[a as usize] = idx as i32;
        }
    }
    fill_azimuth_gaps(&mut lut, MAX_FILL);
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

/// Give unclaimed azimuth slots to whichever neighbouring radial is nearer,
/// across gaps no wider than `max_fill` slots.
///
/// Radials claim slots by their reported width, which tiles perfectly for
/// Level 3 but not for Level 2: super-resolution start azimuths drift, so
/// slivers between consecutive radials belong to nobody. In a 2D raster those
/// slivers are black spokes radiating from the site; in the 3D grid they are
/// empty columns. Issue #28.
///
/// The width limit is what separates drift from absence. A radar that
/// genuinely did not look somewhere leaves a wide hole, and stretching a
/// radial across it would invent coverage.
pub(crate) fn fill_azimuth_gaps(lut: &mut [i32], max_fill: i32) {
    let n = lut.len();
    if n == 0 || lut.iter().all(|&v| v < 0) {
        return;
    }
    // How far, and to which radial, walking each way around the circle. Two
    // passes so a gap straddling due north is measured correctly.
    let scan = |rev: bool| {
        let mut who = vec![-1i32; n];
        let mut far = vec![i32::MAX; n];
        let (mut last, mut d) = (-1i32, i32::MAX);
        for pass in 0..2 {
            for i in 0..n {
                let a = if rev { n - 1 - i } else { i };
                if lut[a] >= 0 {
                    last = lut[a];
                    d = 0;
                } else if d != i32::MAX {
                    d += 1;
                }
                if pass == 1 {
                    who[a] = last;
                    far[a] = d;
                }
            }
        }
        (who, far)
    };
    let (fwd, fwd_d) = scan(false);
    let (bwd, bwd_d) = scan(true);

    for a in 0..n {
        if lut[a] >= 0 {
            continue;
        }
        let (near, dist) = if fwd_d[a] <= bwd_d[a] {
            (fwd[a], fwd_d[a])
        } else {
            (bwd[a], bwd_d[a])
        };
        if near >= 0 && dist <= max_fill {
            lut[a] = near;
        }
    }
}

#[cfg(test)]
mod lut_tests {
    use super::*;
    use crate::level3::ValueDecoder;
    use crate::sweep::{GateData, SweepRadial};

    /// Radials at the given start azimuths, each claiming `delta` degrees.
    fn sweep_with(starts: &[f32], delta: f32) -> Sweep {
        Sweep {
            site_lat: 35.0,
            site_lon: -97.0,
            first_gate_m: 2125.0,
            gate_size_m: 250.0,
            nbins: 4,
            radials: starts
                .iter()
                .map(|&a| SweepRadial {
                    start_az_deg: a,
                    delta_az_deg: delta,
                    data: GateData::U8(vec![100u8; 4]),
                })
                .collect(),
            decoder: ValueDecoder::ScaleOffset {
                scale: 2.0,
                offset: 66.0,
            },
            timestamp: 0,
            elevation_deg: 0.5,
            max_raw: 255,
        }
    }

    /// Issue #28. Super-resolution start azimuths drift, so consecutive
    /// radials do not tile: this is the pattern that left black spokes.
    #[test]
    fn drifting_half_degree_radials_leave_no_holes() {
        let starts: Vec<f32> = (0..720)
            .map(|i| {
                let base = i as f32 * 0.5;
                // A small wobble, as the real reported azimuths have.
                base + if i % 3 == 0 { 0.07 } else { 0.0 }
            })
            .collect();
        let lut = azimuth_lut(&sweep_with(&starts, 0.5));
        let holes = lut.iter().filter(|&&v| v < 0).count();
        assert_eq!(holes, 0, "{holes} azimuth slots would draw as spokes");
    }

    #[test]
    fn perfectly_tiled_level3_radials_are_untouched() {
        let starts: Vec<f32> = (0..360).map(|i| i as f32).collect();
        let lut = azimuth_lut(&sweep_with(&starts, 1.0));
        assert!(lut.iter().all(|&v| v >= 0));
        // Slot 105 is 10.5 degrees, which belongs to the radial starting at 10.
        assert_eq!(lut[105], 10);
    }

    #[test]
    fn a_real_missing_sector_stays_missing() {
        // Radials covering only 0-90 degrees: the rest is not drift, it is
        // data the radar never produced, and filling it would invent
        // coverage across three quarters of the sweep.
        let starts: Vec<f32> = (0..180).map(|i| i as f32 * 0.5).collect();
        let lut = azimuth_lut(&sweep_with(&starts, 0.5));
        assert!(lut[0..900].iter().all(|&v| v >= 0), "the scanned arc is filled");
        assert_eq!(lut[1800], -1, "due south was never scanned");
        assert_eq!(lut[2700], -1, "due west was never scanned");
    }

    #[test]
    fn a_gap_across_due_north_is_closed() {
        // The wrap point is where a one-directional fill would fail.
        let starts: Vec<f32> = (0..720)
            .map(|i| i as f32 * 0.5)
            .filter(|&a| !(a >= 359.5 || a < 0.5))
            .collect();
        let lut = azimuth_lut(&sweep_with(&starts, 0.5));
        assert!(lut[3595] >= 0, "just before north");
        assert!(lut[0] >= 0, "due north itself");
        assert!(lut[3] >= 0, "just after north");
    }
}
