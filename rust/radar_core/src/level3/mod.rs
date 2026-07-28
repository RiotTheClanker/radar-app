//! NEXRAD Level 3 (NIDS) product decoding.
//!
//! Format reference: NOAA/NWS ICD 2620001 (RPG to Class 1 User).
//! A Level 3 file is: optional WMO/AWIPS text header, an 18-byte Message
//! Header Block, a 102-byte Product Description Block, then (possibly
//! bzip2- or zlib-compressed) Product Symbology / Graphic / Tabular blocks.

pub mod products;

use crate::error::{RadarError, Result};
use products::{product_info, ProductInfo};

/// One decoded radial: azimuth sweep start/extent and one byte per range bin.
#[derive(Debug, Clone)]
pub struct Radial {
    pub start_az_deg: f32,
    pub delta_az_deg: f32,
    pub data: Vec<u8>,
}

/// Digital radial data array (packet code 16) plus everything needed to
/// convert raw byte levels to physical values.
#[derive(Debug, Clone)]
pub struct RadialDataArray {
    pub first_bin: u16,
    pub nbins: u16,
    pub gate_size_m: f32,
    pub radials: Vec<Radial>,
    pub decoder: ValueDecoder,
}

/// Physical meaning of one raw data byte.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum BinValue {
    NoData,
    RangeFolded,
    Value(f32),
}

/// How raw byte levels map to physical values for a given product.
#[derive(Debug, Clone, Copy)]
pub enum ValueDecoder {
    /// Legacy digital products (94, 99): thresholds hold min*10, inc*10.
    LegacyLinear { min: f32, inc: f32 },
    /// Modern digital/dual-pol products: value = (raw - offset) / scale,
    /// raw 0 = no data, raw 1 = range folded.
    ScaleOffset { scale: f32, offset: f32 },
    /// Categorical products (hydrometeor classification): value = raw.
    Categorical,
    /// Unknown product: pass raw through.
    Raw,
}

impl ValueDecoder {
    pub fn decode(&self, raw: u16) -> BinValue {
        match *self {
            ValueDecoder::LegacyLinear { min, inc } => match raw {
                0 => BinValue::NoData,
                1 => BinValue::RangeFolded,
                r => BinValue::Value(min + (r as f32 - 2.0) * inc),
            },
            ValueDecoder::ScaleOffset { scale, offset } => match raw {
                0 => BinValue::NoData,
                1 => BinValue::RangeFolded,
                r => BinValue::Value((r as f32 - offset) / scale),
            },
            ValueDecoder::Categorical => {
                if raw == 0 {
                    BinValue::NoData
                } else {
                    BinValue::Value(raw as f32)
                }
            }
            ValueDecoder::Raw => {
                if raw == 0 {
                    BinValue::NoData
                } else {
                    BinValue::Value(raw as f32)
                }
            }
        }
    }
}

/// A decoded Level 3 product file.
#[derive(Debug, Clone)]
pub struct Level3File {
    pub product_code: i16,
    pub site_lat: f64,
    pub site_lon: f64,
    pub site_height_ft: i16,
    pub op_mode: i16,
    pub vcp: i16,
    /// Unix seconds of the volume scan this product was made from.
    pub volume_scan_time: i64,
    pub generation_time: i64,
    pub elevation_number: i16,
    pub elevation_angle_deg: f32,
    pub info: Option<&'static ProductInfo>,
    pub radial: Option<RadialDataArray>,
}

impl Level3File {
    /// Maximum data range in meters (site to farthest bin edge).
    pub fn max_range_m(&self) -> f32 {
        match &self.radial {
            Some(r) => (r.first_bin as f32 + r.nbins as f32) * r.gate_size_m,
            None => 0.0,
        }
    }

    /// Convert to the common renderable sweep type.
    pub fn to_sweep(&self) -> Option<crate::sweep::Sweep> {
        let r = self.radial.as_ref()?;
        Some(crate::sweep::Sweep {
            site_lat: self.site_lat,
            site_lon: self.site_lon,
            first_gate_m: r.first_bin as f32 * r.gate_size_m,
            gate_size_m: r.gate_size_m,
            nbins: r.nbins as u32,
            radials: r
                .radials
                .iter()
                .map(|rad| crate::sweep::SweepRadial {
                    start_az_deg: rad.start_az_deg,
                    delta_az_deg: rad.delta_az_deg,
                    data: crate::sweep::GateData::U8(rad.data.clone()),
                })
                .collect(),
            decoder: r.decoder,
            timestamp: self.volume_scan_time,
            elevation_deg: self.elevation_angle_deg,
            max_raw: 255,
        })
    }
}

// ---------------------------------------------------------------------------
// Big-endian byte reader
// ---------------------------------------------------------------------------

struct Reader<'a> {
    buf: &'a [u8],
    pos: usize,
}

impl<'a> Reader<'a> {
    fn new(buf: &'a [u8]) -> Self {
        Reader { buf, pos: 0 }
    }

    fn need(&self, n: usize) -> Result<()> {
        if self.pos + n > self.buf.len() {
            Err(RadarError::Truncated {
                needed: n,
                offset: self.pos,
                len: self.buf.len(),
            })
        } else {
            Ok(())
        }
    }

    fn take(&mut self, n: usize) -> Result<&'a [u8]> {
        self.need(n)?;
        let s = &self.buf[self.pos..self.pos + n];
        self.pos += n;
        Ok(s)
    }

    fn u16(&mut self) -> Result<u16> {
        let b = self.take(2)?;
        Ok(u16::from_be_bytes([b[0], b[1]]))
    }

    fn i16(&mut self) -> Result<i16> {
        Ok(self.u16()? as i16)
    }

    fn i32(&mut self) -> Result<i32> {
        let b = self.take(4)?;
        Ok(i32::from_be_bytes([b[0], b[1], b[2], b[3]]))
    }

    fn f32(&mut self) -> Result<f32> {
        let b = self.take(4)?;
        Ok(f32::from_be_bytes([b[0], b[1], b[2], b[3]]))
    }

    fn skip(&mut self, n: usize) -> Result<()> {
        self.need(n)?;
        self.pos += n;
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

/// Locate the Message Header Block, skipping any WMO/AWIPS text header.
///
/// Rather than guessing at text-header line lengths, scan for the position
/// where the structure checks out: PDB divider == -1, plausible lat/lon, and
/// the MHB message code equals the PDB product code.
fn find_header_offset(buf: &[u8]) -> Result<usize> {
    let limit = buf.len().saturating_sub(120).min(256);
    for off in 0..=limit {
        let code = i16::from_be_bytes([buf[off], buf[off + 1]]);
        if !(16..=1000).contains(&code) {
            continue;
        }
        // PDB divider directly after the 18-byte MHB
        if buf[off + 18] != 0xFF || buf[off + 19] != 0xFF {
            continue;
        }
        let lat = i32::from_be_bytes([buf[off + 20], buf[off + 21], buf[off + 22], buf[off + 23]]);
        let lon = i32::from_be_bytes([buf[off + 24], buf[off + 25], buf[off + 26], buf[off + 27]]);
        let pdb_code = i16::from_be_bytes([buf[off + 30], buf[off + 31]]);
        let latf = lat as f64 * 0.001;
        let lonf = lon as f64 * 0.001;
        if pdb_code == code && (-90.0..=90.0).contains(&latf) && (-180.0..=180.0).contains(&lonf) {
            return Ok(off);
        }
    }
    Err(RadarError::NoHeader)
}

fn decompress_symbology(raw: &[u8]) -> Result<Vec<u8>> {
    use std::io::Read;
    if raw.len() >= 3 && &raw[0..3] == b"BZh" {
        let mut out = Vec::new();
        bzip2::read::MultiBzDecoder::new(raw)
            .read_to_end(&mut out)
            .map_err(|e| RadarError::Decompress(e.to_string()))?;
        Ok(out)
    } else if raw.len() >= 2 && raw[0] == 0x78 {
        let mut out = Vec::new();
        flate2::read::ZlibDecoder::new(raw)
            .read_to_end(&mut out)
            .map_err(|e| RadarError::Decompress(e.to_string()))?;
        Ok(out)
    } else {
        Ok(raw.to_vec())
    }
}

/// NEXRAD "modified Julian date" (day 1 = 1970-01-01) + seconds to Unix time.
fn nexrad_time(date: i16, secs: i32) -> i64 {
    ((date as i64) - 1) * 86400 + secs as i64
}

pub fn parse(buf: &[u8]) -> Result<Level3File> {
    if buf.len() < 138 {
        return Err(RadarError::Truncated {
            needed: 138,
            offset: 0,
            len: buf.len(),
        });
    }
    let start = find_header_offset(buf)?;
    let msg = &buf[start..];
    let mut r = Reader::new(msg);

    // Message Header Block (18 bytes)
    let _msg_code = r.i16()?;
    let _msg_date = r.i16()?;
    let _msg_time = r.i32()?;
    let _msg_len = r.i32()?;
    let _src = r.i16()?;
    let _dst = r.i16()?;
    let _nblocks = r.i16()?;

    // Product Description Block (102 bytes)
    let _divider = r.i16()?;
    let site_lat = r.i32()? as f64 * 0.001;
    let site_lon = r.i32()? as f64 * 0.001;
    let site_height_ft = r.i16()?;
    let product_code = r.i16()?;
    let op_mode = r.i16()?;
    let vcp = r.i16()?;
    let _seq = r.i16()?;
    let _vol_num = r.i16()?;
    let scan_date = r.i16()?;
    let scan_time = r.i32()?;
    let gen_date = r.i16()?;
    let gen_time = r.i32()?;
    let _p1 = r.i16()?;
    let _p2 = r.i16()?;
    let elevation_number = r.i16()?;
    let p3 = r.i16()?;
    let thresholds = r.take(32)?.to_vec();
    let _p4_p10 = r.take(14)?;
    let _version_spot = r.i16()?;
    let sym_off_hw = r.i32()?;
    let _gph_off_hw = r.i32()?;
    let _tab_off_hw = r.i32()?;

    let info = product_info(product_code);
    let decoder = build_decoder(product_code, &thresholds);

    // Elevation-based products carry elevation*10 in parameter 3.
    let elevation_angle_deg = p3 as f32 / 10.0;

    let mut radial = None;
    if sym_off_hw > 0 {
        let sym_start = (sym_off_hw as usize) * 2;
        if sym_start < msg.len() {
            let sym = decompress_symbology(&msg[sym_start..])?;
            radial = parse_symbology(&sym, decoder, info)?;
        }
    }

    Ok(Level3File {
        product_code,
        site_lat,
        site_lon,
        site_height_ft,
        op_mode,
        vcp,
        volume_scan_time: nexrad_time(scan_date, scan_time),
        generation_time: nexrad_time(gen_date, gen_time),
        elevation_number,
        elevation_angle_deg,
        info,
        radial,
    })
}

fn build_decoder(product_code: i16, thresholds: &[u8]) -> ValueDecoder {
    match product_code {
        // Linear digital (incl. super-res): threshold halfwords are
        // min*10, inc*10, n_levels
        94 | 99 | 153 | 154 | 155 => {
            let min = i16::from_be_bytes([thresholds[0], thresholds[1]]) as f32 / 10.0;
            let inc = i16::from_be_bytes([thresholds[2], thresholds[3]]) as f32 / 10.0;
            ValueDecoder::LegacyLinear { min, inc }
        }
        // Dual-pol digital: leading float scale + float offset
        159 | 161 | 163 | 167 | 168 | 170 | 172 | 173 | 174 | 175 => {
            let scale = f32::from_be_bytes([thresholds[0], thresholds[1], thresholds[2], thresholds[3]]);
            let offset = f32::from_be_bytes([thresholds[4], thresholds[5], thresholds[6], thresholds[7]]);
            if scale.is_finite() && scale != 0.0 {
                ValueDecoder::ScaleOffset { scale, offset }
            } else {
                ValueDecoder::Raw
            }
        }
        165 | 177 => ValueDecoder::Categorical,
        _ => ValueDecoder::Raw,
    }
}

fn parse_symbology(
    sym: &[u8],
    decoder: ValueDecoder,
    info: Option<&'static ProductInfo>,
) -> Result<Option<RadialDataArray>> {
    let mut r = Reader::new(sym);
    let _divider = r.i16()?;
    let _block_id = r.i16()?;
    let _block_len = r.i32()?;
    let nlayers = r.i16()?;

    for _ in 0..nlayers.max(0) {
        let _layer_divider = r.i16()?;
        let layer_len = r.i32()? as usize;
        let layer_end = (r.pos + layer_len).min(sym.len());

        while r.pos + 2 <= layer_end {
            let code = r.u16()?;
            match code {
                16 => {
                    return Ok(Some(parse_packet16(&mut r, decoder, info)?));
                }
                _ => {
                    // Unknown packet: we can't know its length generically, so
                    // stop scanning this layer and move to the next.
                    r.pos = layer_end;
                }
            }
        }
        r.pos = layer_end;
    }
    Ok(None)
}

fn parse_packet16(
    r: &mut Reader,
    decoder: ValueDecoder,
    info: Option<&'static ProductInfo>,
) -> Result<RadialDataArray> {
    let first_bin = r.u16()?;
    let nbins = r.u16()?;
    let _i_center = r.i16()?;
    let _j_center = r.i16()?;
    let _range_scale = r.u16()?;
    let nradials = r.u16()?;

    // Gate size comes from the product table; fall back to assuming the data
    // extends to 460 km if we don't know the product.
    let gate_size_m = info
        .map(|i| i.gate_size_m)
        .unwrap_or_else(|| 460_000.0 / (first_bin as f32 + nbins as f32).max(1.0));

    let mut radials = Vec::with_capacity(nradials as usize);
    for _ in 0..nradials {
        let nbytes = r.u16()? as usize;
        let start_az_deg = r.u16()? as f32 / 10.0;
        let delta_az_deg = r.u16()? as f32 / 10.0;
        let data = r.take(nbytes)?;
        radials.push(Radial {
            start_az_deg,
            delta_az_deg,
            data: data[..(nbins as usize).min(data.len())].to_vec(),
        });
    }

    Ok(RadialDataArray {
        first_bin,
        nbins,
        gate_size_m,
        radials,
        decoder,
    })
}
