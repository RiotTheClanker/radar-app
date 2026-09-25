//! The open radar data format: how someone with their own radar, their own
//! processing, or their own parser gets data onto the map without writing a
//! NEXRAD encoder.
//!
//! A file is one JSON document, gzipped or not. It describes either a
//! **polar** sweep — a site, radials, gates, values — or a **grid** of values
//! over a lat/lon box. Whatever produced it (a Python script, a vendor
//! converter, a cron job over a receiver's output) is the parser; this
//! module only reads the neutral shape it writes. Specified in full in
//! docs/open-format.md.
//!
//! A polar sweep becomes an ordinary [`Sweep`], so it is rendered, coloured,
//! sampled by the cursor and re-coloured by an imported `.pal` exactly as a
//! NEXRAD sweep is. A grid becomes a [`ValueGrid`], rendered by its own
//! rasterizer in [`crate::render::raster`].

use std::io::Read;

use serde_json::Value;

use crate::level3::products::ProductKind;
use crate::level3::ValueDecoder;
use crate::render::color_table::{ColorStop, ColorTable};
use crate::sweep::{GateData, Sweep, SweepRadial};

/// What a file says about itself, for the frame's labels and the colour key.
#[derive(Debug, Clone)]
pub struct OpenMeta {
    pub kind: ProductKind,
    pub name: String,
    pub unit: String,
    pub timestamp: i64,
    /// A colour scale the file brought with it, for data no built-in palette
    /// fits. Wins over the product kind's palette.
    pub colors: Option<ColorTable>,
}

impl OpenMeta {
    pub fn table(&self) -> ColorTable {
        self.colors
            .clone()
            .unwrap_or_else(|| ColorTable::default_for(self.kind))
    }
}

/// A regular lat/lon grid of physical values. `NaN` is no data.
#[derive(Debug, Clone)]
pub struct ValueGrid {
    pub nx: usize,
    pub ny: usize,
    pub north: f64,
    pub south: f64,
    pub east: f64,
    pub west: f64,
    /// Row-major from the north-west corner.
    pub values: Vec<f32>,
}

impl ValueGrid {
    /// The value of the cell containing a point, if it is inside the grid
    /// and has data.
    pub fn sample(&self, lat: f64, lon: f64) -> Option<f32> {
        let dx = (self.east - self.west) / self.nx as f64;
        let dy = (self.north - self.south) / self.ny as f64;
        let gx = ((lon - self.west) / dx).floor() as i64;
        let gy = ((self.north - lat) / dy).floor() as i64;
        if gx < 0 || gy < 0 || gx >= self.nx as i64 || gy >= self.ny as i64 {
            return None;
        }
        let v = self.values[gy as usize * self.nx + gx as usize];
        (!v.is_nan()).then_some(v)
    }
}

#[derive(Debug, Clone)]
pub enum OpenData {
    Polar(Sweep),
    Grid(ValueGrid),
}

#[derive(Debug, Clone)]
pub struct OpenFile {
    pub meta: OpenMeta,
    pub data: OpenData,
}

/// Parse an open-format file. Errors say what is wrong in the terms of the
/// spec, since the person reading them is debugging their own converter.
pub fn parse(bytes: &[u8]) -> Result<OpenFile, String> {
    let text: Vec<u8> = if bytes.len() > 2 && bytes[0] == 0x1f && bytes[1] == 0x8b {
        let mut out = Vec::new();
        flate2::read::GzDecoder::new(bytes)
            .read_to_end(&mut out)
            .map_err(|e| format!("open format: gunzip failed: {e}"))?;
        out
    } else {
        bytes.to_vec()
    };
    let doc: Value = serde_json::from_slice(&text)
        .map_err(|e| format!("open format: not valid JSON ({e})"))?;
    let obj = doc
        .as_object()
        .ok_or("open format: the file must be a JSON object")?;
    if obj.get("format").and_then(Value::as_str) != Some("radar-open") {
        return Err("open format: \"format\" must be \"radar-open\"".into());
    }
    let version = obj.get("version").and_then(Value::as_u64).unwrap_or(1);
    if version > 1 {
        return Err(format!(
            "open format: version {version} is newer than this app reads (1)"
        ));
    }

    let kind = product_kind(obj.get("product").and_then(Value::as_str).unwrap_or(""));
    let meta = OpenMeta {
        kind,
        name: obj
            .get("name")
            .and_then(Value::as_str)
            .map(str::to_string)
            .unwrap_or_else(|| default_name(kind).into()),
        unit: obj
            .get("unit")
            .and_then(Value::as_str)
            .map(str::to_string)
            .unwrap_or_else(|| default_unit(kind).into()),
        timestamp: read_time(obj.get("time"))?,
        colors: match obj.get("colors") {
            Some(v) => Some(read_colors(v)?),
            None => None,
        },
    };

    let data = match obj.get("kind").and_then(Value::as_str) {
        Some("polar") => OpenData::Polar(read_polar(obj, &meta)?),
        Some("grid") => OpenData::Grid(read_grid(obj)?),
        _ => return Err("open format: \"kind\" must be \"polar\" or \"grid\"".into()),
    };
    Ok(OpenFile { meta, data })
}

/// The product names a file may use, mapped onto the palettes the app has.
/// Anything else is `Other`, which uses the reflectivity palette unless the
/// file brings its own `colors`.
pub fn product_kind(p: &str) -> ProductKind {
    match p.to_ascii_lowercase().as_str() {
        "reflectivity" | "ref" | "dbz" => ProductKind::Reflectivity,
        "velocity" | "vel" => ProductKind::Velocity,
        "spectrum_width" | "sw" => ProductKind::SpectrumWidth,
        "zdr" | "differential_reflectivity" => ProductKind::Zdr,
        "cc" | "rhohv" | "correlation_coefficient" => ProductKind::CorrelationCoefficient,
        "kdp" => ProductKind::Kdp,
        "hydro_class" | "hca" => ProductKind::HydroClass,
        "precipitation" | "precip" | "rain" => ProductKind::Precipitation,
        "vil" => ProductKind::Vil,
        "echo_tops" | "et" => ProductKind::EchoTops,
        "rotation" | "azimuthal_shear" => ProductKind::Rotation,
        _ => ProductKind::Other,
    }
}

fn default_name(k: ProductKind) -> &'static str {
    match k {
        ProductKind::Reflectivity => "Reflectivity",
        ProductKind::Velocity => "Velocity",
        ProductKind::SpectrumWidth => "Spectrum Width",
        ProductKind::Zdr => "Differential Reflectivity",
        ProductKind::CorrelationCoefficient => "Correlation Coefficient",
        ProductKind::Kdp => "Specific Differential Phase",
        ProductKind::HydroClass => "Hydrometeor Classification",
        ProductKind::Precipitation => "Precipitation",
        ProductKind::Vil => "Vertically Integrated Liquid",
        ProductKind::EchoTops => "Echo Tops",
        ProductKind::Rotation => "Rotation",
        ProductKind::Other => "Custom data",
    }
}

fn default_unit(k: ProductKind) -> &'static str {
    match k {
        ProductKind::Reflectivity => "dBZ",
        ProductKind::Velocity | ProductKind::SpectrumWidth => "m/s",
        ProductKind::Zdr => "dB",
        ProductKind::Kdp => "deg/km",
        ProductKind::Precipitation => "in",
        ProductKind::Vil => "kg/m²",
        ProductKind::EchoTops => "kft",
        ProductKind::Rotation => "m/s/km",
        _ => "",
    }
}

fn read_time(v: Option<&Value>) -> Result<i64, String> {
    match v {
        None => Err("open format: \"time\" is required (ISO 8601 UTC, or Unix seconds)".into()),
        Some(Value::Number(n)) => n
            .as_f64()
            .map(|s| s as i64)
            .ok_or_else(|| "open format: \"time\" is not a number".into()),
        Some(Value::String(s)) => parse_iso(s)
            .ok_or_else(|| format!("open format: \"time\" \"{s}\" is not ISO 8601 UTC")),
        Some(_) => Err("open format: \"time\" must be a string or a number".into()),
    }
}

/// `YYYY-MM-DDTHH:MM[:SS[.fff]][Z|+00:00]`, UTC only. Enough for a scan
/// time without a date crate.
fn parse_iso(s: &str) -> Option<i64> {
    let s = s.trim();
    let b = s.as_bytes();
    if b.len() < 16 {
        return None;
    }
    let num = |a: usize, n: usize| -> Option<i64> { s.get(a..a + n)?.parse().ok() };
    let (y, mo, d, h, mi) = (num(0, 4)?, num(5, 2)?, num(8, 2)?, num(11, 2)?, num(14, 2)?);
    let sec = if b.len() >= 19 && b[16] == b':' { num(17, 2)? } else { 0 };
    let rest = &s[if b.len() >= 19 && b[16] == b':' { 19 } else { 16 }..];
    let rest = rest.trim_start_matches(|c: char| c == '.' || c.is_ascii_digit());
    if !(rest.is_empty() || rest == "Z" || rest == "+00:00" || rest == "+0000") {
        return None;
    }
    if !(1..=12).contains(&mo) || !(1..=31).contains(&d) || h > 23 || mi > 59 || sec > 60 {
        return None;
    }
    // Days from the civil calendar (Howard Hinnant's algorithm).
    let (y2, m2) = if mo <= 2 { (y - 1, mo + 9) } else { (y, mo - 3) };
    let era = y2.div_euclid(400);
    let yoe = y2 - era * 400;
    let doy = (153 * m2 + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    Some(days * 86_400 + h * 3600 + mi * 60 + sec)
}

fn read_colors(v: &Value) -> Result<ColorTable, String> {
    let obj = v
        .as_object()
        .ok_or("open format: \"colors\" must be an object with \"stops\"")?;
    let stops = obj
        .get("stops")
        .and_then(Value::as_array)
        .ok_or("open format: \"colors.stops\" must be a list of [value, \"#RRGGBB\"]")?;
    let mut out = Vec::new();
    for s in stops {
        let pair = s.as_array().filter(|p| p.len() == 2).ok_or(
            "open format: each colour stop is [value, \"#RRGGBB\"] or [value, \"#RRGGBBAA\"]",
        )?;
        let value = pair[0]
            .as_f64()
            .ok_or("open format: a colour stop's value must be a number")? as f32;
        let color = pair[1]
            .as_str()
            .and_then(hex_color)
            .ok_or("open format: a colour stop's colour must be \"#RRGGBB\" or \"#RRGGBBAA\"")?;
        out.push(ColorStop { value, color });
    }
    if out.is_empty() {
        return Err("open format: \"colors.stops\" is empty".into());
    }
    out.sort_by(|a, b| a.value.total_cmp(&b.value));
    Ok(ColorTable {
        stops: out,
        interpolate: obj.get("interpolate").and_then(Value::as_bool).unwrap_or(true),
        rf_color: [119, 0, 125, 255],
    })
}

fn hex_color(s: &str) -> Option<[u8; 4]> {
    let h = s.trim().trim_start_matches('#');
    let byte = |i: usize| u8::from_str_radix(h.get(i..i + 2)?, 16).ok();
    match h.len() {
        6 => Some([byte(0)?, byte(2)?, byte(4)?, 255]),
        8 => Some([byte(0)?, byte(2)?, byte(4)?, byte(6)?]),
        _ => None,
    }
}

fn num(obj: &serde_json::Map<String, Value>, key: &str) -> Result<f64, String> {
    obj.get(key)
        .and_then(Value::as_f64)
        .ok_or_else(|| format!("open format: \"{key}\" is required and must be a number"))
}

fn count(obj: &serde_json::Map<String, Value>, key: &str) -> Result<usize, String> {
    let n = obj
        .get(key)
        .and_then(Value::as_u64)
        .ok_or_else(|| format!("open format: \"{key}\" is required and must be a whole number"))?;
    if n == 0 || n > 100_000 {
        return Err(format!("open format: \"{key}\" must be between 1 and 100000"));
    }
    Ok(n as usize)
}

/// The values, as physical numbers with `NaN` for no data, from either
/// `"values"` (a JSON array, `null` for no data) or `"packed"` (base64 of
/// little-endian `u8`/`u16`/`i16`/`f32`, value = raw × scale + offset).
fn read_values(obj: &serde_json::Map<String, Value>, expect: usize) -> Result<Vec<f32>, String> {
    let vals: Vec<f32> = if let Some(v) = obj.get("values") {
        let arr = v.as_array().ok_or("open format: \"values\" must be a list")?;
        let mut out = Vec::with_capacity(expect);
        // One level of nesting is accepted too: a list per radial or row is
        // what numpy's tolist() writes.
        for item in arr {
            match item {
                Value::Array(inner) => out.extend(inner.iter().map(json_value)),
                other => out.push(json_value(other)),
            }
        }
        out
    } else if let Some(p) = obj.get("packed") {
        read_packed(p)?
    } else {
        return Err("open format: give the data as \"values\" or \"packed\"".into());
    };
    if vals.len() != expect {
        return Err(format!(
            "open format: expected {expect} values from the dimensions, found {}",
            vals.len()
        ));
    }
    Ok(vals)
}

fn json_value(v: &Value) -> f32 {
    v.as_f64().map(|x| x as f32).unwrap_or(f32::NAN)
}

fn read_packed(p: &Value) -> Result<Vec<f32>, String> {
    let obj = p.as_object().ok_or("open format: \"packed\" must be an object")?;
    let ty = obj
        .get("type")
        .and_then(Value::as_str)
        .ok_or("open format: \"packed.type\" is required: u8, u16, i16 or f32")?;
    let b64 = obj
        .get("base64")
        .and_then(Value::as_str)
        .ok_or("open format: \"packed.base64\" is required")?;
    let raw = base64_decode(b64).ok_or("open format: \"packed.base64\" is not valid base64")?;
    let scale = obj.get("scale").and_then(Value::as_f64).unwrap_or(1.0) as f32;
    let offset = obj.get("offset").and_then(Value::as_f64).unwrap_or(0.0) as f32;
    let nodata = obj.get("nodata").and_then(Value::as_f64);
    let conv = |r: f64| -> f32 {
        if nodata == Some(r) || r.is_nan() {
            f32::NAN
        } else {
            r as f32 * scale + offset
        }
    };
    Ok(match ty {
        "u8" => raw.iter().map(|&b| conv(b as f64)).collect(),
        "u16" => raw
            .chunks_exact(2)
            .map(|c| conv(u16::from_le_bytes([c[0], c[1]]) as f64))
            .collect(),
        "i16" => raw
            .chunks_exact(2)
            .map(|c| conv(i16::from_le_bytes([c[0], c[1]]) as f64))
            .collect(),
        "f32" => raw
            .chunks_exact(4)
            .map(|c| conv(f32::from_le_bytes([c[0], c[1], c[2], c[3]]) as f64))
            .collect(),
        other => return Err(format!("open format: packed type \"{other}\" is not u8, u16, i16 or f32")),
    })
}

fn base64_decode(s: &str) -> Option<Vec<u8>> {
    fn val(c: u8) -> Option<u32> {
        Some(match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' | b'-' => 62,
            b'/' | b'_' => 63,
            _ => return None,
        } as u32)
    }
    let clean: Vec<u8> = s
        .bytes()
        .filter(|c| !c.is_ascii_whitespace() && *c != b'=')
        .collect();
    let mut out = Vec::with_capacity(clean.len() * 3 / 4);
    for chunk in clean.chunks(4) {
        let mut acc = 0u32;
        for (i, &c) in chunk.iter().enumerate() {
            acc |= val(c)? << (18 - 6 * i);
        }
        let bytes = acc.to_be_bytes();
        match chunk.len() {
            4 => out.extend_from_slice(&bytes[1..4]),
            3 => out.extend_from_slice(&bytes[1..3]),
            2 => out.push(bytes[1]),
            _ => return None,
        }
    }
    Some(out)
}

fn read_polar(obj: &serde_json::Map<String, Value>, meta: &OpenMeta) -> Result<Sweep, String> {
    let site = obj
        .get("site")
        .and_then(Value::as_object)
        .ok_or("open format: a polar file needs \"site\": {\"lat\", \"lon\"}")?;
    let site_lat = num(site, "lat")?;
    let site_lon = num(site, "lon")?;
    if site_lat.abs() > 90.0 || site_lon.abs() > 180.0 {
        return Err("open format: site lat/lon out of range".into());
    }
    let gates = count(obj, "gates")?;
    let first_gate_m = num(obj, "firstGateM")? as f32;
    let gate_size_m = num(obj, "gateSizeM")? as f32;
    if gate_size_m <= 0.0 {
        return Err("open format: \"gateSizeM\" must be positive".into());
    }

    // Radials: either an explicit start azimuth each, or a start and a step.
    let starts: Vec<f32> = match obj.get("azimuths") {
        Some(v) => v
            .as_array()
            .ok_or("open format: \"azimuths\" must be a list of degrees")?
            .iter()
            .map(|a| a.as_f64().map(|x| x as f32))
            .collect::<Option<Vec<_>>>()
            .ok_or("open format: every azimuth must be a number")?,
        None => {
            let n = count(obj, "radials")?;
            let a0 = obj.get("azimuthStart").and_then(Value::as_f64).unwrap_or(0.0) as f32;
            let step = obj
                .get("azimuthStep")
                .and_then(Value::as_f64)
                .map(|x| x as f32)
                .unwrap_or(360.0 / n as f32);
            (0..n).map(|i| a0 + step * i as f32).collect()
        }
    };
    if starts.is_empty() {
        return Err("open format: no radials".into());
    }
    let width = obj
        .get("beamWidthDeg")
        .and_then(Value::as_f64)
        .map(|x| x as f32)
        .unwrap_or_else(|| (360.0 / starts.len() as f32).min(2.0));

    let values = read_values(obj, starts.len() * gates)?;
    let (decoder, raw, max_raw) = encode_u16(&values, meta.kind);

    let radials = starts
        .iter()
        .enumerate()
        .map(|(i, &a)| SweepRadial {
            start_az_deg: a.rem_euclid(360.0),
            delta_az_deg: width,
            data: GateData::U16(raw[i * gates..(i + 1) * gates].to_vec()),
        })
        .collect();

    Ok(Sweep {
        site_lat,
        site_lon,
        first_gate_m,
        gate_size_m,
        nbins: gates as u32,
        radials,
        decoder,
        timestamp: meta.timestamp,
        elevation_deg: obj.get("elevationDeg").and_then(Value::as_f64).unwrap_or(0.5) as f32,
        max_raw,
    })
}

/// Pack physical values into the 16-bit raw form a [`Sweep`] carries, with
/// a decoder that undoes it. Raw 0 is no data and 1 is range folded, as in
/// NEXRAD, so data starts at 2. The step is as fine as 65 000 levels across
/// the file's range allows, capped at a thousandth of a unit — below any
/// radar's precision, and it keeps a near-constant field from dividing by
/// nothing.
fn encode_u16(values: &[f32], kind: ProductKind) -> (ValueDecoder, Vec<u16>, u16) {
    if kind == ProductKind::HydroClass {
        let raw: Vec<u16> = values
            .iter()
            .map(|&v| if v.is_nan() || v < 1.0 { 0 } else { v.round().min(65_535.0) as u16 })
            .collect();
        let max = raw.iter().copied().max().unwrap_or(0);
        return (ValueDecoder::Categorical, raw, max);
    }
    let (mut lo, mut hi) = (f32::INFINITY, f32::NEG_INFINITY);
    for &v in values {
        if v.is_finite() {
            lo = lo.min(v);
            hi = hi.max(v);
        }
    }
    if !lo.is_finite() {
        return (ValueDecoder::ScaleOffset { scale: 1.0, offset: 2.0 }, vec![0; values.len()], 0);
    }
    let scale = (65_000.0 / (hi - lo).max(1e-6)).min(1000.0);
    // raw = (v - lo) * scale + 2  =>  v = (raw - offset) / scale
    let offset = 2.0 - lo * scale;
    let raw: Vec<u16> = values
        .iter()
        .map(|&v| {
            if v.is_finite() {
                ((v - lo) * scale + 2.0).round().clamp(2.0, 65_535.0) as u16
            } else {
                0
            }
        })
        .collect();
    let max = raw.iter().copied().max().unwrap_or(0);
    (ValueDecoder::ScaleOffset { scale, offset }, raw, max)
}

fn read_grid(obj: &serde_json::Map<String, Value>) -> Result<ValueGrid, String> {
    let (north, south, east, west) = (
        num(obj, "north")?,
        num(obj, "south")?,
        num(obj, "east")?,
        num(obj, "west")?,
    );
    if north <= south || east <= west || north > 90.0 || south < -90.0 {
        return Err("open format: grid bounds need north > south and east > west".into());
    }
    let nx = count(obj, "nx")?;
    let ny = count(obj, "ny")?;
    if nx * ny > 50_000_000 {
        return Err("open format: grid larger than 50 million cells".into());
    }
    let values = read_values(obj, nx * ny)?;
    Ok(ValueGrid { nx, ny, north, south, east, west, values })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn polar(extra: &str) -> String {
        format!(
            r#"{{"format":"radar-open","version":1,"kind":"polar",
               "site":{{"lat":35.33,"lon":-97.28}},"time":"2026-07-28T05:37:15Z",
               "product":"reflectivity","elevationDeg":0.5,
               "firstGateM":1000,"gateSizeM":1000,"gates":3,
               "radials":4,"azimuthStart":0,"azimuthStep":90{extra}}}"#
        )
    }

    #[test]
    fn polar_values_round_trip_through_the_sweep() {
        let f = parse(polar(r#","values":[[10,20,null],[30,40,50],[0,0,0],[-5,65.5,1]]"#).as_bytes())
            .unwrap();
        assert_eq!(f.meta.timestamp, 1_785_217_035);
        assert_eq!(f.meta.unit, "dBZ");
        let OpenData::Polar(s) = f.data else { panic!("polar") };
        assert_eq!(s.radials.len(), 4);
        assert_eq!(s.radials[1].start_az_deg, 90.0);
        let decode = |r: usize, g: usize| {
            let raw = s.radials[r].data.get(g).unwrap();
            match s.decoder.decode(raw) {
                crate::level3::BinValue::Value(v) => Some(v),
                _ => None,
            }
        };
        assert!((decode(0, 1).unwrap() - 20.0).abs() < 0.01);
        assert!((decode(3, 1).unwrap() - 65.5).abs() < 0.01);
        assert!((decode(3, 0).unwrap() + 5.0).abs() < 0.01);
        assert_eq!(decode(0, 2), None, "null is no data");
    }

    #[test]
    fn packed_u8_with_scale_offset_and_nodata() {
        // raw 0..11 -> value = raw*0.5 - 32, raw 255 = nodata
        let b64 = "AAoUHigyPEZQWmT/"; // 0,10,20,...,100,255
        let f = parse(polar(&format!(
            r#","packed":{{"type":"u8","base64":"{b64}","scale":0.5,"offset":-32,"nodata":255}}"#
        )).as_bytes())
        .unwrap();
        let OpenData::Polar(s) = f.data else { panic!() };
        let raw = s.radials[3].data.get(2).unwrap();
        assert_eq!(s.decoder.decode(raw), crate::level3::BinValue::NoData);
        let raw = s.radials[0].data.get(1).unwrap();
        match s.decoder.decode(raw) {
            crate::level3::BinValue::Value(v) => assert!((v - (-27.0)).abs() < 0.01),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn gzip_is_read() {
        use std::io::Write;
        let mut enc = flate2::write::GzEncoder::new(Vec::new(), flate2::Compression::fast());
        enc.write_all(polar(r#","values":[1,2,3,4,5,6,7,8,9,10,11,12]"#).as_bytes())
            .unwrap();
        assert!(parse(&enc.finish().unwrap()).is_ok());
    }

    #[test]
    fn grid_samples_by_cell() {
        let f = parse(
            br##"{"format":"radar-open","kind":"grid","time":1785217035,
                "product":"soil moisture","unit":"%","north":36,"south":35,
                "east":-97,"west":-98,"nx":2,"ny":2,"values":[1,2,3,null],
                "colors":{"stops":[[0,"#000000"],[4,"#FFFFFF80"]]}}"##,
        )
        .unwrap();
        assert_eq!(f.meta.kind, ProductKind::Other);
        assert_eq!(f.meta.colors.as_ref().unwrap().stops[1].color, [255, 255, 255, 128]);
        let OpenData::Grid(g) = f.data else { panic!() };
        assert_eq!(g.sample(35.9, -97.9), Some(1.0), "row 0 is the north row");
        assert_eq!(g.sample(35.1, -97.9), Some(3.0));
        assert_eq!(g.sample(35.1, -97.1), None, "null");
        assert_eq!(g.sample(40.0, -97.5), None, "outside");
    }

    #[test]
    fn mistakes_are_named() {
        let e = parse(polar(r#","values":[1,2]"#).as_bytes()).unwrap_err();
        assert!(e.contains("expected 12 values"), "{e}");
        let e = parse(br#"{"format":"radar-open","kind":"polar"}"#).unwrap_err();
        assert!(e.contains("\"time\""), "{e}");
        let e = parse(br#"{"format":"nope"}"#).unwrap_err();
        assert!(e.contains("radar-open"), "{e}");
        let e = parse(br#"{"format":"radar-open","time":0,"kind":"cube"}"#).unwrap_err();
        assert!(e.contains("\"kind\""), "{e}");
    }

    #[test]
    fn iso_times() {
        assert_eq!(parse_iso("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(parse_iso("2026-07-28T05:37:15.250Z"), Some(1_785_217_035));
        assert_eq!(parse_iso("2026-07-28T05:37Z"), Some(1_785_217_020));
        assert_eq!(parse_iso("2026-07-28T05:37:15+02:00"), None, "UTC only");
    }

    /// The files the example addon ships, through the same API calls the app
    /// makes: a whole-extent render, a view render, a cursor sample and the
    /// colour key. They are written by tools/open_format/radar_open.py, so
    /// this is also what keeps that script and this reader agreeing.
    #[test]
    fn the_example_addon_files_render_through_the_api() {
        let root = concat!(env!("CARGO_MANIFEST_DIR"), "/../../docs/addons/examples/open-radar/data");
        let mut seen = 0;
        for product in ["REF", "VEL", "STP"] {
            for e in std::fs::read_dir(format!("{root}/{product}")).unwrap() {
                let bytes = std::fs::read(e.unwrap().path()).unwrap();
                let f = crate::api::render_open_frame(bytes.clone(), 256).unwrap();
                assert!(f.png.len() > 100, "{product}: an image came back");
                assert!(f.north > f.south && f.east > f.west);
                let v = crate::api::render_open_view(
                    bytes.clone(), f.north, f.south, f.east, f.west, 300, 200,
                )
                .unwrap();
                assert_eq!((v.width, v.height), (300, 200));
                let scale = crate::api::open_color_scale(bytes.clone()).unwrap();
                assert!(!scale.stops.is_empty());
                let session = crate::api::inspect_open_custom(bytes).unwrap();
                let site = crate::api::inspect_site(session).unwrap();
                assert_eq!(site.is_empty(), product == "STP", "grids have no site");
                crate::api::inspect_close(session);
                seen += 1;
            }
        }
        assert_eq!(seen, 3);
    }

    #[test]
    fn base64_variants() {
        assert_eq!(base64_decode("TWFu").unwrap(), b"Man");
        assert_eq!(base64_decode("TWE=").unwrap(), b"Ma");
        assert_eq!(base64_decode("TQ").unwrap(), b"M");
        assert!(base64_decode("T!!!").is_none());
    }
}
