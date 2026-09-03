//! GRIB2 for model fields: Lambert Conformal grids, complex packing.
//!
//! Separate from [`crate::mrms`], which reads the one shape MRMS ships — a
//! plain lat/lon grid (template 3.0) with the values PNG-compressed (template
//! 5.41). Model output is neither. HRRR puts its fields on a Lambert
//! Conformal conic (3.30) and packs them with complex packing and spatial
//! differencing (5.3), so none of the MRMS path applies and none of this
//! applies to MRMS.
//!
//! Written by hand for the same reason as every other decoder here: there is
//! no libgrib or eccodes to cross-compile for Android. Complex packing is
//! involved but self-contained, and — this was the open question before any
//! of it was written — HRRR does *not* use JPEG2000, which would have meant
//! a C dependency this project exists without.
//!
//! ## Two things that will catch you out
//!
//! **Signed integers are sign-magnitude, not two's complement.** The high bit
//! is the sign and the rest is the value, so a decimal scale factor of -1
//! arrives as `0x8001`. Read it as two's complement and you get -32767 and a
//! field scaled by 10^32767.
//!
//! **The values are differenced before they are packed.** What comes out of
//! the bit stream is a second difference; the field is recovered by
//! integrating twice from the two initial values stored ahead of it.

use crate::error::{RadarError, Result};

fn err(msg: &str) -> RadarError {
    // Same shape as the MRMS reader's: the error enum has no variant for
    // "this file is not what it claims", and adding one for two decoders is
    // less useful than the message saying which decoder gave up.
    RadarError::Decompress(format!("grib2: {msg}"))
}

/// Read a big-endian sign-magnitude integer.
///
/// GRIB2's own convention, and not the one any CPU uses.
fn sign_magnitude(bytes: &[u8]) -> i64 {
    if bytes.is_empty() {
        return 0;
    }
    let mut v: i64 = 0;
    for &b in bytes {
        v = (v << 8) | b as i64;
    }
    let sign_bit = 1i64 << (bytes.len() * 8 - 1);
    if v & sign_bit != 0 {
        -(v & !sign_bit)
    } else {
        v
    }
}

fn be_u16(b: &[u8], o: usize) -> u16 {
    u16::from_be_bytes([b[o], b[o + 1]])
}

fn be_u32(b: &[u8], o: usize) -> u32 {
    u32::from_be_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]])
}

fn be_f32(b: &[u8], o: usize) -> f32 {
    f32::from_be_bytes([b[o], b[o + 1], b[o + 2], b[o + 3]])
}

/// Big-endian bit reader over the packed data section.
///
/// Values are not byte-aligned — a 10-bit field packs eight values into ten
/// bytes — so everything after the group headers has to be read a bit at a
/// time.
struct BitReader<'a> {
    buf: &'a [u8],
    bit: usize,
}

impl<'a> BitReader<'a> {
    fn new(buf: &'a [u8]) -> Self {
        Self { buf, bit: 0 }
    }

    /// Read `n` bits (n <= 32). Reads past the end yield zeros rather than
    /// panicking: a truncated file should decode to a short field, not bring
    /// the app down.
    fn read(&mut self, n: u8) -> u32 {
        let mut out: u32 = 0;
        for _ in 0..n {
            let byte = self.buf.get(self.bit >> 3).copied().unwrap_or(0);
            out = (out << 1) | ((byte >> (7 - (self.bit & 7))) & 1) as u32;
            self.bit += 1;
        }
        out
    }

    /// Group headers are each padded to a byte boundary.
    fn align(&mut self) {
        self.bit = (self.bit + 7) & !7;
    }
}

/// A Lambert Conformal conic grid, as template 3.30 describes it.
///
/// Only what is needed to turn a latitude and longitude into a position in
/// the grid, which is the one direction the renderer asks for: it walks the
/// output pixels and samples the field, rather than walking the field and
/// scattering it.
#[derive(Debug, Clone)]
pub struct LambertGrid {
    pub nx: usize,
    pub ny: usize,
    /// Grid spacing, metres.
    pub dx: f64,
    pub dy: f64,
    /// Cone constant, and the projection's scale term.
    n: f64,
    f: f64,
    /// Central meridian, degrees east, wrapped to +/-180.
    lov: f64,
    /// Projected position of grid point (0, 0), metres.
    x0: f64,
    y0: f64,
    /// True when rows run south to north, which is how HRRR ships.
    j_north: bool,
}

/// Radius of the sphere GRIB2 shape-of-earth code 6 specifies.
const EARTH_R: f64 = 6_371_229.0;

impl LambertGrid {
    fn rho(&self, lat_deg: f64) -> f64 {
        let t = (45.0 + lat_deg / 2.0).to_radians().tan();
        EARTH_R * self.f / t.powf(self.n)
    }

    fn project(&self, lat: f64, lon: f64) -> (f64, f64) {
        // Wrap the longitude difference so a point either side of the
        // antimeridian does not come out half a world away.
        let dl = ((lon - self.lov + 180.0).rem_euclid(360.0)) - 180.0;
        let theta = self.n * dl.to_radians();
        let r = self.rho(lat);
        (r * theta.sin(), -r * theta.cos())
    }

    /// Fractional grid position of a latitude/longitude. Outside the grid is
    /// perfectly legal and comes back out of range, for the caller to reject.
    pub fn to_grid(&self, lat: f64, lon: f64) -> (f64, f64) {
        self.row(lat).at(lon)
    }

    /// Everything about a projection that depends only on the latitude.
    ///
    /// A rendered row is one latitude across many longitudes, and the
    /// expensive half of the conic projection — a `tan` raised to the cone
    /// constant — depends on latitude alone. Hoisting it turns one `powf` per
    /// pixel into one per row: at 900x900 that is nine hundred instead of
    /// eight hundred thousand.
    pub fn row(&self, lat: f64) -> LambertRow<'_> {
        LambertRow {
            grid: self,
            rho: self.rho(lat),
        }
    }

    /// Index into the value array, or None when off the grid.
    pub fn index(&self, gi: f64, gj: f64) -> Option<usize> {
        if !gi.is_finite() || !gj.is_finite() {
            return None;
        }
        let i = gi.round();
        let j = gj.round();
        if i < 0.0 || j < 0.0 || i >= self.nx as f64 || j >= self.ny as f64 {
            return None;
        }
        Some(j as usize * self.nx + i as usize)
    }
}

/// One latitude's worth of projection, with the latitude-dependent term
/// already paid for. See [`LambertGrid::row`].
pub struct LambertRow<'a> {
    grid: &'a LambertGrid,
    rho: f64,
}

impl LambertRow<'_> {
    /// Fractional grid position of a longitude on this row.
    pub fn at(&self, lon: f64) -> (f64, f64) {
        let g = self.grid;
        let dl = ((lon - g.lov + 180.0).rem_euclid(360.0)) - 180.0;
        let theta = g.n * dl.to_radians();
        self.from_theta(theta.sin(), theta.cos())
    }

    fn from_theta(&self, sin_t: f64, cos_t: f64) -> (f64, f64) {
        let g = self.grid;
        let x = self.rho * sin_t;
        let y = -self.rho * cos_t;
        let gi = (x - g.x0) / g.dx;
        let gj = (y - g.y0) / g.dy;
        (gi, if g.j_north { gj } else { -gj })
    }

    /// Walk this row at a fixed longitude step, which is what rendering into
    /// an equirectangular view box does.
    ///
    /// The angle advances by a constant, so the sine and cosine advance by a
    /// rotation rather than being recomputed — two transcendentals per pixel
    /// become four multiplies. Over the width of a view the accumulated
    /// error is far below a grid cell, and the projection tests would catch
    /// it if it were not.
    pub fn walk(&self, lon0: f64, dlon: f64, count: usize) -> LambertWalk<'_> {
        let g = self.grid;
        let dl0 = ((lon0 - g.lov + 180.0).rem_euclid(360.0)) - 180.0;
        let theta0 = g.n * dl0.to_radians();
        let step = g.n * dlon.to_radians();
        LambertWalk {
            row: self,
            sin_t: theta0.sin(),
            cos_t: theta0.cos(),
            sin_d: step.sin(),
            cos_d: step.cos(),
            left: count,
        }
    }
}

/// A row being walked at a fixed longitude step. See [`LambertRow::walk`].
pub struct LambertWalk<'a> {
    row: &'a LambertRow<'a>,
    sin_t: f64,
    cos_t: f64,
    sin_d: f64,
    cos_d: f64,
    left: usize,
}

impl Iterator for LambertWalk<'_> {
    type Item = (f64, f64);

    fn next(&mut self) -> Option<(f64, f64)> {
        if self.left == 0 {
            return None;
        }
        self.left -= 1;
        let out = self.row.from_theta(self.sin_t, self.cos_t);
        // Angle addition: rotate (sin, cos) by the constant step.
        let s = self.sin_t * self.cos_d + self.cos_t * self.sin_d;
        let c = self.cos_t * self.cos_d - self.sin_t * self.sin_d;
        self.sin_t = s;
        self.cos_t = c;
        Some(out)
    }
}

/// One decoded field: the values, and the grid they sit on.
pub struct Grib2Field {
    pub values: Vec<f32>,
    pub grid: LambertGrid,
    /// Reference time of the model run, unix seconds.
    pub run_time: i64,
}

/// Walk the sections of one GRIB2 message.
fn sections(data: &[u8]) -> Result<[Option<(usize, usize)>; 8]> {
    if data.len() < 16 || &data[0..4] != b"GRIB" {
        return Err(err("not a GRIB message"));
    }
    if data[7] != 2 {
        return Err(err("only GRIB edition 2"));
    }
    let mut out: [Option<(usize, usize)>; 8] = Default::default();
    let mut pos = 16usize;
    while pos + 5 <= data.len() {
        if &data[pos..(pos + 4).min(data.len())] == b"7777" {
            break;
        }
        let len = be_u32(data, pos) as usize;
        let num = data[pos + 4] as usize;
        if len == 0 || pos + len > data.len() || num > 7 {
            return Err(err("bad GRIB section"));
        }
        out[num] = Some((pos, len));
        pos += len;
    }
    Ok(out)
}

fn parse_grid(s: &[u8]) -> Result<LambertGrid> {
    if s.len() < 73 {
        return Err(err("grid section too short"));
    }
    let template = be_u16(s, 12);
    if template != 30 {
        return Err(err(
            "only Lambert Conformal grids (template 3.30) are supported",
        ));
    }
    let nx = be_u32(s, 30) as usize;
    let ny = be_u32(s, 34) as usize;
    let la1 = be_u32(s, 38) as f64 / 1e6;
    let lo1 = be_u32(s, 42) as f64 / 1e6;
    let lad = be_u32(s, 47) as f64 / 1e6;
    let lov_raw = be_u32(s, 51) as f64 / 1e6;
    let dx = be_u32(s, 55) as f64 / 1e3;
    let dy = be_u32(s, 59) as f64 / 1e3;
    let scan = s[64];
    let latin1 = sign_magnitude(&s[65..69]) as f64 / 1e6;
    let latin2 = sign_magnitude(&s[69..73]) as f64 / 1e6;

    if nx == 0 || ny == 0 || dx <= 0.0 || dy <= 0.0 {
        return Err(err("degenerate grid"));
    }

    // The cone constant. Equal standard parallels mean the cone is tangent
    // rather than secant, which is HRRR's case and where the general formula
    // divides by zero.
    let n = if (latin1 - latin2).abs() < 1e-9 {
        latin1.to_radians().sin()
    } else {
        let t1 = (45.0 + latin1 / 2.0).to_radians().tan();
        let t2 = (45.0 + latin2 / 2.0).to_radians().tan();
        (latin1.to_radians().cos() / latin2.to_radians().cos()).ln() / (t2 / t1).ln()
    };
    if n.abs() < 1e-12 {
        return Err(err("degenerate cone constant"));
    }
    let f = latin1.to_radians().cos() * (45.0 + latin1 / 2.0).to_radians().tan().powf(n) / n;

    let lov = ((lov_raw + 180.0).rem_euclid(360.0)) - 180.0;
    let lon1 = ((lo1 + 180.0).rem_euclid(360.0)) - 180.0;
    let _ = lad; // Reference latitude; the cone is already fixed by latin1/2.

    let mut grid = LambertGrid {
        nx,
        ny,
        dx,
        dy,
        n,
        f,
        lov,
        x0: 0.0,
        y0: 0.0,
        // Bit 2 of the scanning mode: set means rows run south to north.
        j_north: scan & 0x40 != 0,
    };
    // Anchor on the first grid point, which is what la1/lo1 name.
    let (x0, y0) = grid.project(la1, lon1);
    grid.x0 = x0;
    grid.y0 = y0;
    Ok(grid)
}

/// Model run reference time from the identification section.
fn parse_run_time(s: &[u8]) -> i64 {
    if s.len() < 21 {
        return 0;
    }
    let (y, mo, d) = (be_u16(s, 12) as i64, s[14] as i64, s[15] as i64);
    let (h, mi, sec) = (s[16] as i64, s[17] as i64, s[18] as i64);
    // Days from the civil epoch — Howard Hinnant's algorithm, which needs no
    // calendar library and is exact for any proleptic Gregorian date.
    let y2 = if mo <= 2 { y - 1 } else { y };
    let era = if y2 >= 0 { y2 } else { y2 - 399 } / 400;
    let yoe = y2 - era * 400;
    let mp = (mo + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    days * 86_400 + h * 3600 + mi * 60 + sec
}

/// Unpack data representation template 5.3 — complex packing with spatial
/// differencing — into scaled physical values.
fn unpack_complex(s5: &[u8], s7: &[u8]) -> Result<Vec<f32>> {
    if s5.len() < 49 {
        return Err(err("packing section too short"));
    }
    let npts = be_u32(s5, 5) as usize;
    let reference = be_f32(s5, 11);
    let binary_scale = sign_magnitude(&s5[15..17]) as i32;
    let decimal_scale = sign_magnitude(&s5[17..19]) as i32;
    let nbits = s5[19];
    let ngroups = be_u32(s5, 31) as usize;
    let gw_ref = s5[35] as u32;
    let gw_bits = s5[36];
    let gl_ref = be_u32(s5, 37);
    let gl_inc = s5[41] as u32;
    let gl_last = be_u32(s5, 42);
    let gl_bits = s5[46];
    let order = s5[47];
    let extra = s5[48] as usize;

    if ngroups == 0 || npts == 0 {
        return Err(err("no data"));
    }
    if order > 2 {
        return Err(err("only first and second order spatial differencing"));
    }
    if s7.len() < 5 {
        return Err(err("data section too short"));
    }
    let body = &s7[5..];

    // The differencing preamble: `order` initial values, then the minimum of
    // all the differences, which was subtracted to keep them non-negative.
    let mut p = 0usize;
    let mut initial = [0i64; 2];
    for slot in initial.iter_mut().take(order as usize) {
        if p + extra > body.len() {
            return Err(err("truncated spatial differencing header"));
        }
        *slot = sign_magnitude(&body[p..p + extra]);
        p += extra;
    }
    let gmin = if order > 0 {
        if p + extra > body.len() {
            return Err(err("truncated spatial differencing header"));
        }
        let v = sign_magnitude(&body[p..p + extra]);
        p += extra;
        v
    } else {
        0
    };

    let mut br = BitReader::new(&body[p..]);
    let mut refs = Vec::with_capacity(ngroups);
    for _ in 0..ngroups {
        refs.push(br.read(nbits) as i64);
    }
    br.align();
    let mut widths = Vec::with_capacity(ngroups);
    for _ in 0..ngroups {
        widths.push((gw_ref + br.read(gw_bits)) as u8);
    }
    br.align();
    let mut lens = Vec::with_capacity(ngroups);
    for _ in 0..ngroups {
        lens.push(gl_ref + gl_inc * br.read(gl_bits));
    }
    br.align();
    // The last group's length is stored outright rather than scaled.
    if let Some(last) = lens.last_mut() {
        *last = gl_last;
    }

    let mut vals: Vec<i64> = Vec::with_capacity(npts);
    for g in 0..ngroups {
        let (r, w, l) = (refs[g], widths[g], lens[g] as usize);
        if w == 0 {
            // A group whose values are all the same carries no bits at all.
            vals.resize(vals.len() + l, r);
        } else {
            for _ in 0..l {
                vals.push(r + br.read(w) as i64);
            }
        }
        if vals.len() > npts {
            break;
        }
    }
    vals.truncate(npts);
    if vals.len() != npts {
        return Err(err("packed data ran out before the grid was filled"));
    }

    // Integrate back. What was packed is a difference; the field is recovered
    // from the initial values stored ahead of it.
    if order >= 1 {
        for v in vals.iter_mut() {
            *v += gmin;
        }
        if order == 1 {
            vals[0] = initial[0];
            for i in 1..vals.len() {
                vals[i] += vals[i - 1];
            }
        } else {
            vals[0] = initial[0];
            if vals.len() > 1 {
                vals[1] = initial[1];
            }
            for i in 2..vals.len() {
                vals[i] += 2 * vals[i - 1] - vals[i - 2];
            }
        }
    }

    let bs = (2.0f64).powi(binary_scale);
    let ds = (10.0f64).powi(-decimal_scale);
    Ok(vals
        .into_iter()
        .map(|v| ((reference as f64 + v as f64 * bs) * ds) as f32)
        .collect())
}

/// Decode one GRIB2 message carrying a model field.
pub fn parse(data: &[u8]) -> Result<Grib2Field> {
    let sec = sections(data)?;
    let (p3, l3) = sec[3].ok_or_else(|| err("no grid section"))?;
    let (p5, l5) = sec[5].ok_or_else(|| err("no packing section"))?;
    let (p7, l7) = sec[7].ok_or_else(|| err("no data section"))?;

    let grid = parse_grid(&data[p3..p3 + l3])?;
    let s5 = &data[p5..p5 + l5];
    let template = be_u16(s5, 9);
    if template != 3 {
        return Err(err(
            "only complex packing with spatial differencing (template 5.3)",
        ));
    }
    // A bitmap would mean some points carry no value. HRRR's fields are full
    // grids, and guessing at what a missing point should render as is worse
    // than refusing the file.
    if let Some((p6, l6)) = sec[6] {
        if l6 >= 6 && data[p6 + 5] != 255 {
            return Err(err("bitmapped fields are not supported"));
        }
    }

    let values = unpack_complex(s5, &data[p7..p7 + l7])?;
    if values.len() != grid.nx * grid.ny {
        return Err(err("value count does not match the grid"));
    }
    let run_time = sec[1]
        .map(|(p, l)| parse_run_time(&data[p..p + l]))
        .unwrap_or(0);
    Ok(Grib2Field {
        values,
        grid,
        run_time,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The encoding that catches everyone: GRIB2 puts the sign in the high
    /// bit and the magnitude in the rest, so a plain two's-complement read of
    /// a decimal scale factor of -1 gives -32767.
    #[test]
    fn signed_values_are_sign_magnitude() {
        assert_eq!(sign_magnitude(&[0x00, 0x01]), 1);
        assert_eq!(sign_magnitude(&[0x80, 0x01]), -1);
        assert_eq!(sign_magnitude(&[0x00, 0x00]), 0);
        assert_eq!(sign_magnitude(&[0x80, 0x00]), 0, "negative zero is zero");
        assert_eq!(sign_magnitude(&[0x7f, 0xff]), 32767);
        assert_eq!(sign_magnitude(&[0xff, 0xff]), -32767);
    }

    #[test]
    fn bits_are_read_big_endian_across_byte_boundaries() {
        // 1010 1010 1100 1100 -> 10 bits is 1010101011 = 683.
        let mut br = BitReader::new(&[0b1010_1010, 0b1100_1100]);
        assert_eq!(br.read(10), 0b1010101011);
        assert_eq!(br.read(6), 0b001100);
    }

    #[test]
    fn reading_past_the_end_yields_zeros_rather_than_panicking() {
        let mut br = BitReader::new(&[0xff]);
        assert_eq!(br.read(8), 255);
        assert_eq!(br.read(8), 0);
    }
}
