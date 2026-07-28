//! GOES GLM (Geostationary Lightning Mapper) L2 LCFA flash reading.
//!
//! The files are netCDF-4, i.e. HDF5. Instead of pulling in libhdf5 (a C
//! dependency that's painful on Android), this is a minimal pure-Rust reader
//! for exactly the subset GOES GLM files use: version-2 object headers,
//! contiguous or single-chunk layouts, deflate + shuffle filters, and
//! fixed-length string attributes.
//!
//! Dataset discovery is attribute-driven: rather than walking group fractal
//! heaps, we scan for object headers ("OHDR") and identify the datasets we
//! want by their `units` / `long_name` attributes. That sidesteps the
//! hairiest parts of HDF5 while staying robust for this fixed producer.

use std::io::Read;

use crate::error::{RadarError, Result};

/// Flashes from one GLM L2 LCFA file (20 seconds of data).
#[derive(Debug, Clone)]
pub struct GlmFlashes {
    /// Unix seconds of the product time.
    pub timestamp: i64,
    pub lats: Vec<f32>,
    pub lons: Vec<f32>,
}

fn err(msg: &str) -> RadarError {
    RadarError::Decompress(format!("glm: {msg}"))
}

fn u16le(b: &[u8], o: usize) -> u16 {
    u16::from_le_bytes([b[o], b[o + 1]])
}
fn u32le(b: &[u8], o: usize) -> u32 {
    u32::from_le_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]])
}
fn u64le(b: &[u8], o: usize) -> u64 {
    u64::from_le_bytes([
        b[o],
        b[o + 1],
        b[o + 2],
        b[o + 3],
        b[o + 4],
        b[o + 5],
        b[o + 6],
        b[o + 7],
    ])
}

#[derive(Debug, Default, Clone)]
struct Dataset {
    units: String,
    long_name: String,
    nelems: usize,
    /// (class, size): class 0 = int, 1 = float, 3 = string
    dt_class: u8,
    dt_size: usize,
    /// contiguous data (addr, size) or single filtered chunk
    data_addr: u64,
    data_size: u64,
    chunked: bool,
    /// v3 chunked layout: address of the v1 B-tree indexing the chunks
    btree_addr: u64,
    /// chunk dimensionality (rank + 1) for B-tree key parsing
    chunk_rank: usize,
    has_deflate: bool,
    /// shuffle element size (0 = no shuffle)
    shuffle_size: usize,
}

/// Parse one message body into `ds`.
fn apply_message(mtype: u8, body: &[u8], ds: &mut Dataset) {
    match mtype {
        0x01 => {
            // Dataspace v2: version, rank, flags, type, dims...
            if body.len() >= 4 && body[0] == 2 {
                let rank = body[1] as usize;
                let mut n = 1usize;
                for d in 0..rank {
                    let o = 4 + d * 8;
                    if o + 8 <= body.len() {
                        n *= u64le(body, o) as usize;
                    }
                }
                ds.nelems = n;
            }
        }
        0x03 => {
            // Datatype: class in low nibble of first byte, size at offset 4
            if body.len() >= 8 {
                ds.dt_class = body[0] & 0x0F;
                ds.dt_size = u32le(body, 4) as usize;
            }
        }
        0x08 => {
            // Data layout v3/v4
            if body.len() < 2 {
                return;
            }
            let ver = body[0];
            let class = body[1];
            if ver == 3 && class == 1 {
                // contiguous: addr + size
                if body.len() >= 18 {
                    ds.data_addr = u64le(body, 2);
                    ds.data_size = u64le(body, 10);
                }
            } else if ver == 3 && class == 2 {
                // chunked with v1 B-tree index:
                // dimensionality(1), btree addr(8), chunk dims u32 each
                if body.len() >= 11 {
                    ds.chunk_rank = body[2] as usize;
                    ds.btree_addr = u64le(body, 3);
                    ds.chunked = true;
                }
            } else if ver == 4 && class == 2 {
                // chunked v4; we only support the "single chunk" index
                let flags = body[2];
                let rank = body[3] as usize;
                let enc = body[4] as usize;
                let mut o = 5 + rank * enc;
                if o >= body.len() {
                    return;
                }
                let index_type = body[o];
                o += 1;
                if index_type == 1 {
                    // single chunk; if filtered: size + filter mask precede addr
                    if flags & 0x02 != 0 {
                        // "do not apply filter to partial edge chunks" etc.
                    }
                    let filtered = flags & 0x01 != 0 || true;
                    if filtered && o + 12 <= body.len() {
                        // chunk size (length_size bytes = 8), filter mask u32
                        if o + 12 + 8 <= body.len() {
                            ds.data_size = u64le(body, o);
                            o += 8;
                            let _mask = u32le(body, o);
                            o += 4;
                            ds.data_addr = u64le(body, o);
                            ds.chunked = true;
                        }
                    }
                }
            }
        }
        0x0B => {
            // Filter pipeline v2
            if body.len() < 2 || body[0] != 2 {
                return;
            }
            let nf = body[1] as usize;
            let mut o = 2;
            for _ in 0..nf {
                if o + 6 > body.len() {
                    break;
                }
                let id = u16le(body, o);
                o += 2;
                // name length field exists only for non-predefined filters
                let name_len = if id >= 256 {
                    let n = u16le(body, o) as usize;
                    o += 2;
                    n
                } else {
                    0
                };
                let _flags = u16le(body, o);
                let nvals = u16le(body, o + 2) as usize;
                o += 4 + name_len;
                if id == 1 {
                    ds.has_deflate = true;
                } else if id == 2 && nvals >= 1 && o + 4 <= body.len() {
                    ds.shuffle_size = u32le(body, o) as usize;
                }
                o += nvals * 4;
            }
        }
        0x0C => {
            // Attribute v3: ver, flags, name_size u16, dt_size u16, ds_size u16,
            // encoding u8, name, datatype, dataspace, data
            if body.len() < 9 || body[0] != 3 {
                return;
            }
            let name_size = u16le(body, 2) as usize;
            let dt_size = u16le(body, 4) as usize;
            let sp_size = u16le(body, 6) as usize;
            let name_off = 9;
            let dt_off = name_off + name_size;
            let sp_off = dt_off + dt_size;
            let data_off = sp_off + sp_size;
            if data_off > body.len() {
                return;
            }
            let name = String::from_utf8_lossy(&body[name_off..dt_off])
                .trim_end_matches('\0')
                .to_string();
            if name != "units" && name != "long_name" {
                return;
            }
            // attribute datatype: fixed-length string (class 3) only
            if dt_off + 8 > body.len() || body[dt_off] & 0x0F != 3 {
                return;
            }
            let str_len = u32le(body, dt_off + 4) as usize;
            if data_off + str_len > body.len() {
                return;
            }
            let val = String::from_utf8_lossy(&body[data_off..data_off + str_len])
                .trim_end_matches('\0')
                .to_string();
            if name == "units" {
                ds.units = val;
            } else {
                ds.long_name = val;
            }
        }
        _ => {}
    }
}

/// Parse a v2 object header at `off`, following continuation blocks.
fn parse_object_header(data: &[u8], off: usize) -> Option<Dataset> {
    if off + 12 > data.len() || &data[off..off + 4] != b"OHDR" {
        return None;
    }
    let ver = data[off + 4];
    if ver != 2 {
        return None;
    }
    let flags = data[off + 5];
    let mut o = off + 6;
    if flags & 0x20 != 0 {
        o += 16; // four timestamps
    }
    if flags & 0x10 != 0 {
        o += 4; // max compact / min dense
    }
    let size_bytes = 1usize << (flags & 0x03);
    if o + size_bytes > data.len() {
        return None;
    }
    let chunk0_size = match size_bytes {
        1 => data[o] as usize,
        2 => u16le(data, o) as usize,
        4 => u32le(data, o) as usize,
        _ => u64le(data, o) as usize,
    };
    o += size_bytes;

    let mut ds = Dataset::default();
    let track_order = flags & 0x04 != 0;

    // (start, end) message regions: chunk 0 plus any continuations
    let mut regions = vec![(o, (o + chunk0_size).min(data.len()))];
    let mut ri = 0;
    while ri < regions.len() {
        let (mut p, end) = regions[ri];
        ri += 1;
        while p + 4 <= end {
            let mtype = data[p];
            let msize = u16le(data, p + 1) as usize;
            let mflags = data[p + 3];
            let _ = mflags;
            let mut body_off = p + 4;
            if track_order {
                body_off += 2;
            }
            let body_end = body_off + msize;
            if body_end > end {
                break;
            }
            let body = &data[body_off..body_end];
            if mtype == 0x10 && body.len() >= 16 {
                // continuation: addr + length; block starts with "OCHK"
                let addr = u64le(body, 0) as usize;
                let len = u64le(body, 8) as usize;
                if addr + 4 <= data.len() && &data[addr..addr + 4] == b"OCHK" {
                    // exclude trailing 4-byte checksum
                    regions.push((addr + 4, (addr + len).min(data.len()).saturating_sub(4)));
                }
            } else {
                apply_message(mtype, body, &mut ds);
            }
            p = body_end;
        }
    }
    Some(ds)
}

/// Collect (chunk_offset_in_dataset, size, file_addr) from a v1 B-tree.
fn walk_btree_v1(
    data: &[u8],
    addr: usize,
    rank: usize,
    out: &mut Vec<(u64, u32, u64)>,
) -> Result<()> {
    if addr + 24 > data.len() || &data[addr..addr + 4] != b"TREE" {
        return Err(err("bad chunk B-tree node"));
    }
    let level = data[addr + 5];
    let entries = u16le(data, addr + 6) as usize;
    // key/pointer pairs start after: sig(4) type(1) level(1) entries(2)
    // left sibling(8) right sibling(8)
    let mut o = addr + 24;
    let key_size = 8 + rank * 8; // chunk size u32 + filter mask u32 + offsets
    for _ in 0..entries {
        if o + key_size + 8 > data.len() {
            return Err(err("truncated B-tree node"));
        }
        let chunk_size = u32le(data, o);
        let chunk_off = u64le(data, o + 8); // first (slowest) dim offset
        let child = u64le(data, o + key_size) as usize;
        if level == 0 {
            out.push((chunk_off, chunk_size, child as u64));
        } else {
            walk_btree_v1(data, child, rank, out)?;
        }
        o += key_size + 8;
    }
    Ok(())
}

fn defilter(ds: &Dataset, mut raw: Vec<u8>) -> Result<Vec<u8>> {
    if ds.has_deflate {
        let mut out = Vec::new();
        flate2::read::ZlibDecoder::new(&raw[..])
            .read_to_end(&mut out)
            .map_err(|e| err(&format!("inflate: {e}")))?;
        raw = out;
    }
    if ds.shuffle_size > 1 {
        let es = ds.shuffle_size;
        let n = raw.len() / es;
        let mut out = vec![0u8; raw.len()];
        for i in 0..n {
            for j in 0..es {
                out[i * es + j] = raw[j * n + i];
            }
        }
        raw = out;
    }
    Ok(raw)
}

/// Read and de-filter a dataset's raw bytes.
fn read_data(data: &[u8], ds: &Dataset) -> Result<Vec<u8>> {
    if ds.chunked && ds.btree_addr != 0 && ds.btree_addr != u64::MAX {
        let mut chunks = Vec::new();
        walk_btree_v1(data, ds.btree_addr as usize, ds.chunk_rank, &mut chunks)?;
        chunks.sort_by_key(|c| c.0);
        let mut out = Vec::new();
        for (_, size, addr) in chunks {
            let a = addr as usize;
            let s = size as usize;
            if a + s > data.len() {
                return Err(err("chunk address out of range"));
            }
            out.extend_from_slice(&defilter(ds, data[a..a + s].to_vec())?);
        }
        return Ok(out);
    }
    let addr = ds.data_addr as usize;
    let size = ds.data_size as usize;
    if addr == 0 || addr + size > data.len() {
        return Err(err("data address out of range"));
    }
    defilter(ds, data[addr..addr + size].to_vec())
}

/// Parse a GLM L2 LCFA netCDF file and return flash positions.
pub fn parse(data: &[u8]) -> Result<GlmFlashes> {
    if data.len() < 48 || &data[0..8] != b"\x89HDF\r\n\x1a\n" {
        return Err(err("not an HDF5 file"));
    }

    // Scan for object headers and identify datasets by their attributes.
    let mut lat: Option<Dataset> = None;
    let mut lon: Option<Dataset> = None;
    let mut ptime: Option<Dataset> = None;
    let mut i = 0;
    while i + 4 <= data.len() {
        if &data[i..i + 4] == b"OHDR" {
            if let Some(ds) = parse_object_header(data, i) {
                let ln = ds.long_name.to_lowercase();
                if ds.units == "degrees_north" && ln.contains("flash") {
                    lat = Some(ds);
                } else if ds.units == "degrees_east" && ln.contains("flash") {
                    lon = Some(ds);
                } else if ds.units.starts_with("seconds since 2000-01-01 12:00") {
                    ptime = Some(ds);
                }
            }
        }
        i += 1;
    }

    let lat = lat.ok_or_else(|| err("flash_lat not found"))?;
    let lon = lon.ok_or_else(|| err("flash_lon not found"))?;

    let read_f32 = |ds: &Dataset| -> Result<Vec<f32>> {
        if ds.dt_size != 4 {
            return Err(err("expected f32 dataset"));
        }
        let raw = read_data(data, ds)?;
        Ok(raw
            .chunks_exact(4)
            .take(ds.nelems)
            .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
            .collect())
    };

    let lats = read_f32(&lat)?;
    let lons = read_f32(&lon)?;

    // product_time: contiguous f64 scalar, seconds since 2000-01-01T12:00Z
    let timestamp = match &ptime {
        Some(ds) if ds.dt_size == 8 && ds.data_size >= 8 => {
            let raw = read_data(data, ds)?;
            let secs = f64::from_le_bytes([
                raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
            ]);
            946_728_000 + secs as i64
        }
        _ => 0,
    };

    Ok(GlmFlashes {
        timestamp,
        lats,
        lons,
    })
}

/// Development aid: dump every identified dataset's parse state.
pub fn debug_dump(data: &[u8]) {
    let mut i = 0;
    while i + 4 <= data.len() {
        if &data[i..i + 4] == b"OHDR" {
            if let Some(ds) = parse_object_header(data, i) {
                if !ds.units.is_empty() || !ds.long_name.is_empty() {
                    if ds.units.contains("degrees") && ds.long_name.to_lowercase().contains("flash")
                    {
                        println!(
                            "OHDR@{i}: units={} nelems={} dtclass={} dtsize={} chunked={} btree={} \
                             deflate={} shuffle={} long_name={:.40}",
                            ds.units, ds.nelems, ds.dt_class, ds.dt_size, ds.chunked,
                            ds.btree_addr, ds.has_deflate, ds.shuffle_size, ds.long_name
                        );
                        match read_data(data, &ds) {
                            Ok(raw) => {
                                let vals: Vec<f32> = raw
                                    .chunks_exact(4)
                                    .take(5)
                                    .map(|c| f32::from_le_bytes([c[0], c[1], c[2], c[3]]))
                                    .collect();
                                println!("   raw len {} first vals {:?}", raw.len(), vals);
                            }
                            Err(e) => println!("   read error: {e}"),
                        }
                    }
                }
            }
        }
        i += 1;
    }
}
