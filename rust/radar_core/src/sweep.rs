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
}
