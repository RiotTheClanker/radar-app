//! On-device derived products: dealiasing, storm-relative motion, and
//! volume-integrated products (composite reflectivity, VIL, echo tops).

use crate::level3::ValueDecoder;
use crate::sweep::{GateData, Sweep, SweepRadial};

/// Decode a gate to a physical value (None for no-data/range-folded).
#[inline]
fn value(sweep: &Sweep, raw: u16) -> Option<f32> {
    match sweep.decoder.decode(raw) {
        crate::level3::BinValue::Value(v) => Some(v),
        _ => None,
    }
}

/// Simple radial-continuity velocity dealiasing.
///
/// Walks each radial outward keeping a running reference velocity; when a
/// gate jumps by more than the Nyquist interval it is unfolded by the
/// multiple of 2·Vn that brings it closest to the reference. The first valid
/// gate of each radial is seeded from the previous radial for azimuthal
/// continuity.
pub fn dealias(sweep: &mut Sweep, nyquist_ms: f32) {
    if nyquist_ms <= 0.0 {
        return;
    }
    let (scale, offset) = match sweep.decoder {
        ValueDecoder::ScaleOffset { scale, offset } => (scale, offset),
        _ => return,
    };
    let vn2 = 2.0 * nyquist_ms;
    let mut prev_radial_seed: Option<f32> = None;

    for radial in &mut sweep.radials {
        let mut reference: Option<f32> = prev_radial_seed;
        let mut first_valid: Option<f32> = None;
        let n = radial.data.len();
        for i in 0..n {
            let raw = radial.data.get(i).unwrap_or(0);
            if raw <= 1 {
                continue;
            }
            let mut v = (raw as f32 - offset) / scale;
            if let Some(r) = reference {
                if (v - r).abs() > nyquist_ms {
                    let k = ((r - v) / vn2).round();
                    v += k * vn2;
                }
            }
            if first_valid.is_none() {
                first_valid = Some(v);
            }
            reference = Some(v);
            let new_raw = (v * scale + offset).round();
            let new_raw = new_raw.clamp(2.0, 65535.0) as u16;
            match &mut radial.data {
                GateData::U8(d) => d[i] = new_raw.min(255) as u8,
                GateData::U16(d) => d[i] = new_raw,
            }
        }
        prev_radial_seed = first_valid;
    }
    // Dealiased values can exceed the original raw range.
    sweep.max_raw = 65535.min(sweep.max_raw as u32 * 4) as u16;
}

/// Subtract the radial component of a storm motion vector from a velocity
/// sweep. `storm_from_deg` is the direction the storm is moving FROM
/// (meteorological convention), `storm_speed_ms` its speed.
pub fn storm_relative(sweep: &Sweep, storm_from_deg: f32, storm_speed_ms: f32) -> Sweep {
    let (scale, offset) = match sweep.decoder {
        ValueDecoder::ScaleOffset { scale, offset } => (scale, offset),
        _ => return sweep.clone(),
    };
    let toward = (storm_from_deg + 180.0).to_radians();
    let mut out = sweep.clone();
    for radial in &mut out.radials {
        let az = (radial.start_az_deg + radial.delta_az_deg * 0.5).to_radians();
        // Component of storm motion along this radial (positive = away).
        let radial_component = storm_speed_ms * (az - toward).cos();
        let n = radial.data.len();
        for i in 0..n {
            let raw = radial.data.get(i).unwrap_or(0);
            if raw <= 1 {
                continue;
            }
            let v = (raw as f32 - offset) / scale - radial_component;
            let new_raw = (v * scale + offset).round().clamp(2.0, 65535.0) as u16;
            match &mut radial.data {
                GateData::U8(d) => d[i] = new_raw.min(255) as u8,
                GateData::U16(d) => d[i] = new_raw,
            }
        }
    }
    out
}

/// Build a 0.5°-resolution azimuth -> radial index map for a sweep.
fn az_index(sweep: &Sweep) -> Vec<i32> {
    let mut lut = vec![-1i32; 720];
    for (i, r) in sweep.radials.iter().enumerate() {
        let start = (r.start_az_deg * 2.0).round() as i32;
        let steps = (r.delta_az_deg * 2.0).round().max(1.0) as i32;
        for s in 0..steps {
            let a = ((start + s) % 720 + 720) % 720;
            lut[a as usize] = i as i32;
        }
    }
    lut
}

/// Products integrated over all reflectivity cuts of a volume scan.
pub struct VolumeProducts {
    /// Composite (column-max) reflectivity, dBZ.
    pub composite: Sweep,
    /// Vertically integrated liquid, kg/m².
    pub vil: Sweep,
    /// Echo tops (highest 18.3 dBZ), kft above radar level.
    pub echo_tops: Sweep,
}

/// Compute composite reflectivity, VIL, and echo tops from a volume's
/// reflectivity cuts (ordered lowest to highest elevation).
pub fn volume_products(cuts: &[Sweep]) -> Option<VolumeProducts> {
    if cuts.is_empty() {
        return None;
    }
    let base = &cuts[0];
    let nbins = base.nbins as usize;
    let gate = base.gate_size_m;
    let n_radials = base.radials.len();

    let luts: Vec<Vec<i32>> = cuts.iter().map(az_index).collect();
    let cos_el: Vec<f64> = cuts
        .iter()
        .map(|c| (c.elevation_deg as f64).to_radians().cos())
        .collect();

    let mut cref_radials = Vec::with_capacity(n_radials);
    let mut vil_radials = Vec::with_capacity(n_radials);
    let mut top_radials = Vec::with_capacity(n_radials);

    for base_radial in &base.radials {
        let az = base_radial.start_az_deg + base_radial.delta_az_deg * 0.5;
        let az_slot = (((az * 2.0).round() as i32) % 720 + 720) % 720;

        let mut cref = vec![0u8; nbins];
        let mut vilv = vec![0u8; nbins];
        let mut tops = vec![0u8; nbins];

        for bin in 0..nbins {
            let ground_range = base.first_gate_m as f64 + (bin as f64 + 0.5) * gate as f64;
            let mut col: Vec<(f32, f32)> = Vec::with_capacity(cuts.len()); // (dBZ, height m)
            let mut max_dbz = f32::MIN;

            for (k, cut) in cuts.iter().enumerate() {
                let ridx = luts[k][az_slot as usize];
                if ridx < 0 {
                    continue;
                }
                // Slant range that puts the beam over this ground range.
                let slant = ground_range / cos_el[k];
                let gi = ((slant - cut.first_gate_m as f64) / cut.gate_size_m as f64) as i64;
                if gi < 0 {
                    continue;
                }
                let Some(raw) = cuts[k].radials[ridx as usize].data.get(gi as usize) else {
                    continue;
                };
                let Some(dbz) = value(cut, raw) else { continue };
                let h = cut.beam_height_m(slant) as f32;
                col.push((dbz, h));
                max_dbz = max_dbz.max(dbz);
            }

            if col.is_empty() {
                continue;
            }
            if max_dbz > -30.0 {
                cref[bin] = ((max_dbz * 2.0 + 66.0).round()).clamp(2.0, 255.0) as u8;
            }

            // VIL: trapezoidal integration between consecutive cut heights,
            // reflectivity capped at 56 dBZ per the operational algorithm.
            let mut vil = 0.0f64;
            for w in col.windows(2) {
                let (z1, h1) = w[0];
                let (z2, h2) = w[1];
                if z1 < 0.0 && z2 < 0.0 {
                    continue;
                }
                let zl1 = 10f64.powf(z1.min(56.0) as f64 / 10.0);
                let zl2 = 10f64.powf(z2.min(56.0) as f64 / 10.0);
                let dh = (h2 - h1).max(0.0) as f64;
                vil += 3.44e-6 * ((zl1 + zl2) / 2.0).powf(4.0 / 7.0) * dh;
            }
            if vil > 0.05 {
                vilv[bin] = ((vil * 2.0 + 2.0).round()).clamp(2.0, 255.0) as u8;
            }

            // Echo top: highest cut still at/above 18.3 dBZ.
            let mut top_m = 0.0f32;
            for &(dbz, h) in &col {
                if dbz >= 18.3 && h > top_m {
                    top_m = h;
                }
            }
            if top_m > 0.0 {
                let kft = top_m * 3.28084 / 1000.0;
                tops[bin] = ((kft * 2.0 + 2.0).round()).clamp(2.0, 255.0) as u8;
            }
        }

        let mk = |data: Vec<u8>| SweepRadial {
            start_az_deg: base_radial.start_az_deg,
            delta_az_deg: base_radial.delta_az_deg,
            data: GateData::U8(data),
        };
        cref_radials.push(mk(cref));
        vil_radials.push(mk(vilv));
        top_radials.push(mk(tops));
    }

    let template = |radials: Vec<SweepRadial>, scale: f32, offset: f32| Sweep {
        site_lat: base.site_lat,
        site_lon: base.site_lon,
        first_gate_m: base.first_gate_m,
        gate_size_m: base.gate_size_m,
        nbins: base.nbins,
        radials,
        decoder: ValueDecoder::ScaleOffset { scale, offset },
        timestamp: base.timestamp,
        elevation_deg: 0.0,
        max_raw: 255,
    };

    Some(VolumeProducts {
        composite: template(cref_radials, 2.0, 66.0),
        vil: template(vil_radials, 2.0, 2.0),
        echo_tops: template(top_radials, 2.0, 2.0),
    })
}
