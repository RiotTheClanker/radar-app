//! NEXRAD Level 2 (Archive II / Message 31) decoding.
//!
//! Layout verified against live KTLX volumes:
//! - 24-byte volume header (`AR2V0006.xxx`, date, time, ICAO)
//! - a sequence of LDM records: 4-byte big-endian size then a bzip2 stream
//! - the first record holds legacy metadata messages in fixed 2432-byte
//!   slots; later records each hold ~120 Message 31 radials
//! - Message 31: 16-byte message header, then a radial header with pointers
//!   to RVOL/RELV/RRAD constant blocks and DREF/DVEL/DSW/DZDR/DPHI/DRHO/DCFP
//!   moment blocks (8- or 16-bit words, float scale/offset)

use std::collections::BTreeMap;
use std::io::Read;

use crate::error::{RadarError, Result};
use crate::level3::ValueDecoder;
use crate::sweep::{GateData, Sweep, SweepRadial};

/// One radar moment for one elevation cut, still keyed by raw cut number.
#[derive(Debug, Clone)]
struct MomentSweep {
    elevation_deg: f32,
    first_gate_m: f32,
    gate_size_m: f32,
    nbins: u32,
    scale: f32,
    offset: f32,
    timestamp: i64,
    radials: Vec<SweepRadial>,
    max_raw: u16,
}

/// A decoded Level 2 volume: site info plus per-cut, per-moment sweeps.
#[derive(Debug)]
pub struct Level2Volume {
    pub icao: String,
    pub site_lat: f64,
    pub site_lon: f64,
    /// Antenna height above mean sea level, metres — the datum every beam
    /// height in this volume is measured from.
    ///
    /// `beam_height_m` returns height above the antenna, so anything drawn
    /// against a sea-level surface (the 3D terrain) needs this to land on the
    /// same axis. 0.0 when the volume carried no site block.
    pub antenna_alt_m: f64,
    pub vcp: u16,
    /// (elevation_number, moment) -> sweep, in scan order.
    sweeps: BTreeMap<(u8, String), MomentSweep>,
    /// elevation_number -> nyquist velocity (m/s), for Doppler cuts.
    pub nyquist: BTreeMap<u8, f32>,
}

/// Metadata about one available cut for a moment.
#[derive(Debug, Clone)]
pub struct CutInfo {
    pub elevation_number: u8,
    pub elevation_deg: f32,
}

impl Level2Volume {
    /// Cuts (in scan order) that contain the given moment.
    pub fn cuts_for(&self, moment: &str) -> Vec<CutInfo> {
        self.sweeps
            .iter()
            .filter(|((_, m), _)| m == moment)
            .map(|((elnum, _), s)| CutInfo {
                elevation_number: *elnum,
                elevation_deg: s.elevation_deg,
            })
            .collect()
    }

    /// Sweep plus the Nyquist velocity of its cut (0 when unknown).
    pub fn sweep_and_nyquist(&self, moment: &str, index: usize) -> Option<(Sweep, f32)> {
        let (elnum, _) = self
            .sweeps
            .iter()
            .filter(|((_, m), _)| m == moment)
            .map(|((e, _), _)| (*e, ()))
            .nth(index)?;
        let s = self.sweep(moment, index)?;
        let nyq = self.nyquist.get(&elnum).copied().unwrap_or(0.0);
        Some((s, nyq))
    }

    /// Every cut of one moment, lowest elevation first.
    pub fn all_sweeps(&self, moment: &str) -> Vec<Sweep> {
        let n = self.cuts_for(moment).len();
        let mut out: Vec<Sweep> = (0..n).filter_map(|i| self.sweep(moment, i)).collect();
        out.sort_by(|a, b| a.elevation_deg.total_cmp(&b.elevation_deg));
        out
    }

    /// Extract the `index`-th cut (0-based, scan order) of a moment as a
    /// renderable sweep.
    pub fn sweep(&self, moment: &str, index: usize) -> Option<Sweep> {
        let (_, ms) = self
            .sweeps
            .iter()
            .filter(|((_, m), _)| m == moment)
            .nth(index)?;
        Some(Sweep {
            site_lat: self.site_lat,
            site_lon: self.site_lon,
            first_gate_m: ms.first_gate_m,
            gate_size_m: ms.gate_size_m,
            nbins: ms.nbins,
            radials: ms.radials.clone(),
            decoder: ValueDecoder::ScaleOffset {
                scale: ms.scale,
                offset: ms.offset,
            },
            timestamp: ms.timestamp,
            elevation_deg: ms.elevation_deg,
            max_raw: ms.max_raw,
        })
    }
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
fn be_f32(b: &[u8], o: usize) -> f32 {
    f32::from_be_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]])
}

pub fn parse(data: &[u8]) -> Result<Level2Volume> {
    if data.len() < 24 || &data[0..4] != b"AR2V" {
        return Err(RadarError::NoHeader);
    }
    let icao = String::from_utf8_lossy(&data[20..24]).to_string();

    let mut vol = Level2Volume {
        icao,
        site_lat: 0.0,
        site_lon: 0.0,
        antenna_alt_m: 0.0,
        vcp: 0,
        sweeps: BTreeMap::new(),
        nyquist: BTreeMap::new(),
    };

    // Find the compressed records first, then decompress them a batch at a
    // time across threads.
    //
    // Decompression is around 90% of the cost of reading a volume -- 527 ms
    // of 583 on a 4 MB file -- and the records are independent bzip2 streams,
    // so it is the one part of this that parallelises without argument.
    // Parsing stays on this thread because it folds every record into one
    // volume, and it is the cheap tenth anyway.
    let mut spans: Vec<(usize, usize)> = Vec::new();
    let mut pos = 24usize;
    while pos + 4 <= data.len() {
        let size = i32::from_be_bytes([data[pos], data[pos + 1], data[pos + 2], data[pos + 3]]);
        pos += 4;
        let sz = size.unsigned_abs() as usize;
        if sz == 0 || pos + sz > data.len() {
            break;
        }
        spans.push((pos, sz));
        pos += sz;
    }

    // In batches rather than all at once. A volume decompresses to around
    // 55 MB, and holding all of it to save a few milliseconds is a poor trade
    // on a phone; a batch is bounded by the core count instead.
    let threads = std::thread::available_parallelism()
        .map(|n| n.get())
        .unwrap_or(1)
        .clamp(1, 8);

    for batch in spans.chunks(threads) {
        let mut out: Vec<Result<Vec<u8>>> = Vec::new();
        if threads == 1 || batch.len() == 1 {
            for &(off, sz) in batch {
                out.push(inflate(&data[off..off + sz]));
            }
        } else {
            std::thread::scope(|scope| {
                let handles: Vec<_> = batch
                    .iter()
                    .map(|&(off, sz)| scope.spawn(move || inflate(&data[off..off + sz])))
                    .collect();
                for h in handles {
                    // A panicking decompressor is a bug here, not bad input;
                    // bzip2 errors come back as Err rather than unwinding.
                    out.push(h.join().unwrap_or_else(|_| {
                        Err(RadarError::Decompress("decompressor panicked".into()))
                    }));
                }
            });
        }
        // Parsed in the order they appear in the file, because sweeps are
        // keyed by elevation and a record out of order would reshuffle them.
        for rec in out {
            parse_record(&rec?, &mut vol);
        }
    }

    if vol.sweeps.is_empty() {
        return Err(RadarError::NoRadialData);
    }
    Ok(vol)
}

fn inflate(compressed: &[u8]) -> Result<Vec<u8>> {
    let mut rec = Vec::new();
    bzip2::read::MultiBzDecoder::new(compressed)
        .read_to_end(&mut rec)
        .map_err(|e| RadarError::Decompress(e.to_string()))?;
    Ok(rec)
}

fn parse_record(rec: &[u8], vol: &mut Level2Volume) {
    let mut p = 0usize;
    while p + 28 <= rec.len() {
        // 12-byte legacy CTM header, then the 16-byte message header.
        let h = &rec[p + 12..p + 28];
        let msize = be_u16(h, 0) as usize;
        let mtype = h[3];
        if mtype == 31 {
            let payload = &rec[p + 28..];
            parse_msg31(payload, vol);
            // Message size is in halfwords and excludes the CTM header.
            p += 12 + msize * 2;
        } else {
            // Legacy messages sit in fixed 2432-byte slots.
            p += 2432;
        }
        if msize == 0 && mtype != 31 {
            continue;
        }
    }
}

fn parse_msg31(m: &[u8], vol: &mut Level2Volume) {
    if m.len() < 72 {
        return;
    }
    let coll_ms = be_u32(m, 4);
    let coll_date = be_u16(m, 8);
    let az = be_f32(m, 12);
    let azres = m[20];
    let elnum = m[22];
    let elang = be_f32(m, 24);
    let nblocks = be_u16(m, 30) as usize;
    if nblocks > 10 {
        return;
    }
    let timestamp = (coll_date as i64 - 1) * 86400 + (coll_ms / 1000) as i64;
    let delta_az = if azres == 1 { 0.5 } else { 1.0 };

    for bi in 0..nblocks {
        let ptr = be_u32(m, 32 + bi * 4) as usize;
        if ptr + 28 > m.len() {
            continue;
        }
        let b = &m[ptr..];
        match b[0] {
            b'R' => {
                if &b[1..4] == b"VOL" && b.len() >= 44 {
                    vol.site_lat = be_f32(b, 8) as f64;
                    vol.site_lon = be_f32(b, 12) as f64;
                    // Site height (signed — Death Valley sites exist) plus the
                    // feedhorn above it is where the beam actually leaves from,
                    // and so the datum its heights are measured against.
                    // Checked against two real volumes and the independent
                    // NCEI site table: KICX 3244+34 = 3278 m against 10757 ft,
                    // KBYX 2+24 = 26 m against 89 ft.
                    vol.antenna_alt_m =
                        (be_i16(b, 16) as f64) + (be_u16(b, 18) as f64);
                    vol.vcp = be_u16(b, 40);
                } else if &b[1..4] == b"RAD" && b.len() >= 18 {
                    // Radial block: nyquist velocity in 0.01 m/s at offset 16
                    let nyq = be_u16(b, 16) as f32 * 0.01;
                    if nyq > 0.0 {
                        vol.nyquist.entry(elnum).or_insert(nyq);
                    }
                }
            }
            b'D' => {
                let name = String::from_utf8_lossy(&b[1..4]).trim().to_string();
                if name == "CFP" {
                    continue; // clutter filter power — not a display product
                }
                let ngates = be_u16(b, 8) as usize;
                let first_gate_m = be_u16(b, 10) as f32;
                let gate_size_m = be_u16(b, 12) as f32;
                let _snr = be_i16(b, 16);
                let wsize = b[19];
                let scale = be_f32(b, 20);
                let offset = be_f32(b, 24);
                if scale == 0.0 || !scale.is_finite() {
                    continue;
                }

                let (data, max_raw) = match wsize {
                    8 => {
                        if b.len() < 28 + ngates {
                            continue;
                        }
                        let v = b[28..28 + ngates].to_vec();
                        let mx = v.iter().copied().max().unwrap_or(0) as u16;
                        (GateData::U8(v), mx)
                    }
                    16 => {
                        if b.len() < 28 + ngates * 2 {
                            continue;
                        }
                        let v: Vec<u16> =
                            (0..ngates).map(|i| be_u16(b, 28 + i * 2)).collect();
                        let mx = v.iter().copied().max().unwrap_or(0);
                        (GateData::U16(v), mx)
                    }
                    _ => continue,
                };

                let entry = vol
                    .sweeps
                    .entry((elnum, name))
                    .or_insert_with(|| MomentSweep {
                        elevation_deg: elang,
                        first_gate_m,
                        gate_size_m,
                        nbins: ngates as u32,
                        scale,
                        offset,
                        timestamp,
                        radials: Vec::with_capacity(720),
                        max_raw: 0,
                    });
                entry.nbins = entry.nbins.max(ngates as u32);
                entry.max_raw = entry.max_raw.max(max_raw);
                entry.radials.push(SweepRadial {
                    start_az_deg: az,
                    delta_az_deg: delta_az,
                    data,
                });
            }
            _ => {}
        }
    }
}
