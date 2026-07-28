//! MRMS national mosaic reading (GRIB2, PNG-packed).
//!
//! MRMS CONUS products are gzipped GRIB2 with a 7000x3500 0.01-degree
//! lat/lon grid and data representation template 5.41 (PNG compression) —
//! which means the payload is an ordinary 16-bit grayscale PNG, so no
//! external GRIB library is needed.
//!
//! Rows are decoded streaming and max-pooled down to a coarser grid: the
//! national view never needs 1 km resolution, and it keeps peak memory in
//! single-digit megabytes instead of ~50 MB.

use std::io::Read;

use crate::error::{RadarError, Result};

/// A regular lat/lon grid of encoded values (raw = value*2 + 66, 0 = none).
#[derive(Debug, Clone)]
pub struct LatLonGrid {
    pub nx: usize,
    pub ny: usize,
    pub north: f64,
    pub south: f64,
    pub east: f64,
    pub west: f64,
    /// Row-major from the north-west corner.
    pub data: Vec<u8>,
    pub timestamp: i64,
}

fn err(m: &str) -> RadarError {
    RadarError::Decompress(format!("mrms: {m}"))
}

fn be_u16(b: &[u8], o: usize) -> u16 {
    u16::from_be_bytes([b[o], b[o + 1]])
}
fn be_i16(b: &[u8], o: usize) -> i16 {
    be_u16(b, o) as i16
}
fn be_u32(b: &[u8], o: usize) -> u32 {
    u32::from_be_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]])
}
fn be_i32(b: &[u8], o: usize) -> i32 {
    be_u32(b, o) as i32
}

/// Parse a (possibly gzipped) MRMS GRIB2 message into a downsampled grid.
/// `pool` is the max-pooling factor (3 => ~3 km cells).
pub fn parse(data: &[u8], pool: usize) -> Result<LatLonGrid> {
    let raw: Vec<u8> = if data.len() > 2 && data[0] == 0x1f && data[1] == 0x8b {
        let mut out = Vec::new();
        flate2::read::GzDecoder::new(data)
            .read_to_end(&mut out)
            .map_err(|e| err(&format!("gunzip: {e}")))?;
        out
    } else {
        data.to_vec()
    };
    if raw.len() < 16 || &raw[0..4] != b"GRIB" {
        return Err(err("not a GRIB2 message"));
    }

    let mut pos = 16usize;
    let (mut nx, mut ny) = (0usize, 0usize);
    let (mut north, mut south, mut east, mut west) = (0f64, 0f64, 0f64, 0f64);
    let (mut r_ref, mut e_scale, mut d_scale, mut nbits) = (0f32, 0i16, 0i16, 0u8);
    let mut timestamp = 0i64;
    let mut png_payload: Option<&[u8]> = None;

    while pos + 5 <= raw.len() {
        if &raw[pos..pos + 4] == b"7777" {
            break;
        }
        let slen = be_u32(&raw, pos) as usize;
        if slen < 5 || pos + slen > raw.len() {
            return Err(err("bad section length"));
        }
        let s = &raw[pos..pos + slen];
        match s[4] {
            1 => {
                // Identification: reference time at octets 13-19
                if slen >= 21 {
                    let year = be_u16(s, 12) as i32;
                    let (mo, dy, hh, mi, ss) =
                        (s[14] as u32, s[15] as u32, s[16] as u32, s[17] as u32, s[18] as u32);
                    timestamp = unix_from_utc(year, mo, dy, hh, mi, ss);
                }
            }
            3 => {
                let tmpl = be_u16(s, 12);
                if tmpl != 0 {
                    return Err(err("only lat/lon grid template 3.0 supported"));
                }
                nx = be_u32(s, 30) as usize;
                ny = be_u32(s, 34) as usize;
                let la1 = be_i32(s, 46) as f64 * 1e-6;
                let lo1 = be_i32(s, 50) as f64 * 1e-6;
                let la2 = be_i32(s, 55) as f64 * 1e-6;
                let lo2 = be_i32(s, 59) as f64 * 1e-6;
                let scan = s[71];
                // MRMS uses scan mode 0: west->east, north->south.
                if scan & 0x40 != 0 {
                    return Err(err("unsupported scan mode (south-to-north)"));
                }
                north = la1.max(la2);
                south = la1.min(la2);
                let (mut w, mut e) = (lo1.min(lo2), lo1.max(lo2));
                if w > 180.0 {
                    w -= 360.0;
                }
                if e > 180.0 {
                    e -= 360.0;
                }
                west = w;
                east = e;
            }
            5 => {
                let tmpl = be_u16(s, 9);
                if tmpl != 41 {
                    return Err(err("only PNG packing (template 5.41) supported"));
                }
                r_ref = f32::from_be_bytes([s[11], s[12], s[13], s[14]]);
                e_scale = be_i16(s, 15);
                d_scale = be_i16(s, 17);
                nbits = s[19];
            }
            7 => png_payload = Some(&raw[pos + 5..pos + slen]),
            _ => {}
        }
        pos += slen;
    }

    let payload = png_payload.ok_or_else(|| err("no data section"))?;
    if nx == 0 || ny == 0 {
        return Err(err("no grid definition"));
    }

    let pool = pool.max(1);
    let out_nx = nx.div_ceil(pool);
    let out_ny = ny.div_ceil(pool);
    let mut out = vec![0u8; out_nx * out_ny];

    // value = (R + X * 2^E) / 10^D
    let two_e = (2f64).powi(e_scale as i32);
    let ten_d = (10f64).powi(d_scale as i32);

    let decoder = png::Decoder::new(payload);
    let mut reader = decoder
        .read_info()
        .map_err(|e| err(&format!("png header: {e}")))?;
    let info = reader.info();
    if info.width as usize != nx {
        return Err(err("png width does not match grid"));
    }
    let bytes_per_sample = if nbits > 8 { 2 } else { 1 };
    let mut row = vec![0u8; reader.output_line_size(nx as u32)];

    for j in 0..ny {
        let r = reader
            .next_row()
            .map_err(|e| err(&format!("png row {j}: {e}")))?;
        let Some(r) = r else { break };
        row[..r.data().len()].copy_from_slice(r.data());
        let oy = j / pool;
        let orow = &mut out[oy * out_nx..(oy + 1) * out_nx];
        for i in 0..nx {
            let x = if bytes_per_sample == 2 {
                u16::from_be_bytes([row[i * 2], row[i * 2 + 1]]) as f64
            } else {
                row[i] as f64
            };
            let v = (r_ref as f64 + x * two_e) / ten_d;
            // MRMS encodes missing/no-coverage as large negatives.
            if v < -90.0 {
                continue;
            }
            let enc = (v * 2.0 + 66.0).round().clamp(2.0, 255.0) as u8;
            let ox = i / pool;
            if enc > orow[ox] {
                orow[ox] = enc; // max pool keeps storm cores
            }
        }
    }

    Ok(LatLonGrid {
        nx: out_nx,
        ny: out_ny,
        north,
        south,
        east,
        west,
        data: out,
        timestamp,
    })
}

fn unix_from_utc(y: i32, mo: u32, d: u32, h: u32, mi: u32, s: u32) -> i64 {
    // Days from civil (Howard Hinnant's algorithm).
    let y_adj = if mo <= 2 { y - 1 } else { y };
    let era = if y_adj >= 0 { y_adj } else { y_adj - 399 } / 400;
    let yoe = (y_adj - era * 400) as i64;
    let mp = ((mo as i64) + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d as i64 - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era as i64 * 146097 + doe - 719468;
    days * 86400 + h as i64 * 3600 + mi as i64 * 60 + s as i64
}
