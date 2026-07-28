//! A `Sweep` is the common renderable unit: one full antenna rotation of one
//! moment/product, with everything needed to rasterize it. Both Level 2 and
//! Level 3 decoders produce sweeps so the renderer only has one input type.

use crate::level3::ValueDecoder;

/// Raw gate data — Level 2 moments come in 8- and 16-bit word sizes.
#[derive(Debug, Clone)]
pub enum GateData {
    U8(Vec<u8>),
    U16(Vec<u16>),
}

impl GateData {
    pub fn len(&self) -> usize {
        match self {
            GateData::U8(v) => v.len(),
            GateData::U16(v) => v.len(),
        }
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }

    #[inline]
    pub fn get(&self, i: usize) -> Option<u16> {
        match self {
            GateData::U8(v) => v.get(i).map(|&b| b as u16),
            GateData::U16(v) => v.get(i).copied(),
        }
    }
}

#[derive(Debug, Clone)]
pub struct SweepRadial {
    pub start_az_deg: f32,
    pub delta_az_deg: f32,
    pub data: GateData,
}

#[derive(Debug, Clone)]
pub struct Sweep {
    pub site_lat: f64,
    pub site_lon: f64,
    /// Range from the radar to the center of the first gate, meters.
    pub first_gate_m: f32,
    pub gate_size_m: f32,
    pub nbins: u32,
    pub radials: Vec<SweepRadial>,
    pub decoder: ValueDecoder,
    /// Unix seconds of data collection.
    pub timestamp: i64,
    pub elevation_deg: f32,
    /// Highest raw value that is real data (used to size color LUTs).
    pub max_raw: u16,
}

impl Sweep {
    pub fn max_range_m(&self) -> f32 {
        self.first_gate_m + self.nbins as f32 * self.gate_size_m
    }

    /// Sample the sweep at a geographic point. Returns the raw gate value
    /// (still encoded) and the great-circle distance in meters, or None when
    /// the point is outside coverage.
    pub fn sample_raw(&self, lat: f64, lon: f64) -> Option<(u16, f64)> {
        const EARTH_R: f64 = 6_371_000.0;
        let site_lat = self.site_lat.to_radians();
        let site_lon = self.site_lon.to_radians();
        let p_lat = lat.to_radians();
        let dlon = lon.to_radians() - site_lon;

        let cos_c = (site_lat.sin() * p_lat.sin()
            + site_lat.cos() * p_lat.cos() * dlon.cos())
        .clamp(-1.0, 1.0);
        let dist = cos_c.acos() * EARTH_R;

        let gate_origin = self.first_gate_m as f64 - self.gate_size_m as f64 * 0.5;
        let bin = ((dist - gate_origin) / self.gate_size_m as f64) as i64;
        if bin < 0 || bin >= self.nbins as i64 {
            return None;
        }

        let az = (dlon.sin() * p_lat.cos())
            .atan2(site_lat.cos() * p_lat.sin() - site_lat.sin() * p_lat.cos() * dlon.cos())
            .to_degrees();
        let az_norm = if az < 0.0 { az + 360.0 } else { az };
        let radial = self.radials.iter().find(|r| {
            let start = r.start_az_deg as f64;
            let end = start + r.delta_az_deg as f64;
            (az_norm >= start && az_norm < end)
                || (az_norm + 360.0 >= start && az_norm + 360.0 < end)
        })?;
        let raw = radial.data.get(bin as usize)?;
        Some((raw, dist))
    }

    /// Beam center height above the radar in meters at a given range,
    /// using the standard 4/3-earth-radius refraction model.
    pub fn beam_height_m(&self, range_m: f64) -> f64 {
        const KE_R: f64 = 6_371_000.0 * 4.0 / 3.0;
        let el = (self.elevation_deg as f64).to_radians();
        (range_m * range_m + KE_R * KE_R + 2.0 * range_m * KE_R * el.sin()).sqrt() - KE_R
    }
}
