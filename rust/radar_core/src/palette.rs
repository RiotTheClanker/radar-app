//! `.pal` color table import.
//!
//! There is a large community library of these files, so supporting the
//! format lets people bring the palettes they already use. Format:
//!
//! ```text
//! Product: BR
//! Units: DBZ
//! Color:   5  4 233 231            ; value + RGB
//! Color:  10  1 159 244  3 0 244   ; RGB at this stop and at the next
//! SolidColor: 65 255 255 255       ; no interpolation into the next stop
//! ```
//!
//! Parsed tables are stored globally and consulted by
//! [`crate::render::ColorTable::default_for`], so every render path — 2D,
//! 3D, and nowcast — picks them up.

use std::collections::HashMap;
use std::sync::Mutex;

use crate::level3::products::ProductKind;
use crate::render::color_table::{ColorStop, ColorTable};

static CUSTOM: Mutex<Option<HashMap<u8, ColorTable>>> = Mutex::new(None);

fn kind_key(kind: ProductKind) -> u8 {
    match kind {
        ProductKind::Reflectivity => 0,
        ProductKind::Velocity => 1,
        ProductKind::SpectrumWidth => 2,
        ProductKind::Zdr => 3,
        ProductKind::CorrelationCoefficient => 4,
        ProductKind::Kdp => 5,
        ProductKind::HydroClass => 6,
        ProductKind::Precipitation => 7,
        ProductKind::Vil => 8,
        ProductKind::EchoTops => 9,
        ProductKind::Rotation => 10,
        ProductKind::Other => 11,
    }
}

/// Which product family a `.pal` file's `Product:` line refers to.
fn kind_from_product(tag: &str) -> ProductKind {
    let t = tag.trim().to_uppercase();
    match t.as_str() {
        "BV" | "SRV" | "BASEVELOCITY" | "VEL" => ProductKind::Velocity,
        "SW" | "SPECTRUMWIDTH" => ProductKind::SpectrumWidth,
        "ZDR" | "DIFFERENTIALREFLECTIVITY" => ProductKind::Zdr,
        "CC" | "RHOHV" | "CORRELATIONCOEFFICIENT" => ProductKind::CorrelationCoefficient,
        "KDP" | "SPECIFICDIFFERENTIALPHASE" => ProductKind::Kdp,
        "HC" | "HCA" => ProductKind::HydroClass,
        "ET" | "ECHOTOPS" => ProductKind::EchoTops,
        "VIL" => ProductKind::Vil,
        "STP" | "OHP" | "PRECIP" => ProductKind::Precipitation,
        _ => ProductKind::Reflectivity,
    }
}

/// Look up a user-imported table for a product kind.
pub fn custom_for(kind: ProductKind) -> Option<ColorTable> {
    CUSTOM
        .lock()
        .ok()?
        .as_ref()?
        .get(&kind_key(kind))
        .cloned()
}

/// Forget all imported tables (back to the built-in palettes).
pub fn clear_custom() {
    if let Ok(mut g) = CUSTOM.lock() {
        *g = None;
    }
}

/// Parse a `.pal` file and install it. Returns the product kind it applies
/// to, as a display string.
pub fn install_pal(text: &str) -> Result<String, String> {
    let (kind, table) = parse_pal(text)?;
    let mut g = CUSTOM.lock().map_err(|_| "palette lock".to_string())?;
    g.get_or_insert_with(HashMap::new)
        .insert(kind_key(kind), table);
    Ok(format!("{kind:?}"))
}

/// Parse a `.pal` file into a color table.
pub fn parse_pal(text: &str) -> Result<(ProductKind, ColorTable), String> {
    // One entry per Color line: value, color at that value, and optionally
    // the color the ramp should reach just before the *next* entry.
    struct Entry {
        value: f32,
        c1: [u8; 4],
        c2: Option<[u8; 4]>,
        solid: bool,
    }

    let mut kind = ProductKind::Reflectivity;
    let mut entries: Vec<Entry> = Vec::new();
    let mut rf: Option<[u8; 4]> = None;
    let mut scale = 1.0f32;

    for raw_line in text.lines() {
        let line = raw_line.split(';').next().unwrap_or("").trim();
        if line.is_empty() {
            continue;
        }
        let (key, rest) = match line.split_once(':') {
            Some((k, v)) => (k.trim().to_lowercase(), v.trim()),
            None => continue,
        };
        let nums: Vec<f32> = rest
            .split_whitespace()
            .filter_map(|t| t.parse::<f32>().ok())
            .collect();

        match key.as_str() {
            "product" => kind = kind_from_product(rest),
            "scale" => {
                if let Some(&v) = nums.first() {
                    if v != 0.0 {
                        scale = v;
                    }
                }
            }
            "rf" => {
                if nums.len() >= 3 {
                    rf = Some([nums[0] as u8, nums[1] as u8, nums[2] as u8, 255]);
                }
            }
            "color" | "solidcolor" | "color4" | "solidcolor4" => {
                let has_alpha = key.ends_with('4');
                let width = if has_alpha { 4 } else { 3 };
                if nums.len() < 1 + width {
                    continue;
                }
                let take = |i: usize| -> [u8; 4] {
                    [
                        nums[i] as u8,
                        nums[i + 1] as u8,
                        nums[i + 2] as u8,
                        if has_alpha { nums[i + 3] as u8 } else { 255 },
                    ]
                };
                let c1 = take(1);
                let c2 = if nums.len() >= 1 + 2 * width {
                    Some(take(1 + width))
                } else {
                    None
                };
                entries.push(Entry {
                    value: nums[0] * scale,
                    c1,
                    c2,
                    solid: key.starts_with("solid"),
                });
            }
            _ => {}
        }
    }

    if entries.is_empty() {
        return Err("no Color: entries found in .pal file".into());
    }
    entries.sort_by(|a, b| a.value.total_cmp(&b.value));

    // Expand into breakpoints. A second color ramps toward the next entry;
    // SolidColor holds its color flat across its own band.
    let mut stops: Vec<ColorStop> = Vec::new();
    for i in 0..entries.len() {
        let e = &entries[i];
        stops.push(ColorStop {
            value: e.value,
            color: e.c1,
        });
        let next_value = entries.get(i + 1).map(|n| n.value);
        if let Some(nv) = next_value {
            let edge = nv - (nv - e.value).abs().max(1e-3) * 1e-3;
            if e.solid {
                stops.push(ColorStop {
                    value: edge,
                    color: e.c1,
                });
            } else if let Some(c2) = e.c2 {
                stops.push(ColorStop {
                    value: edge,
                    color: c2,
                });
            }
        }
    }
    stops.sort_by(|a, b| a.value.total_cmp(&b.value));
    if stops.len() < 2 {
        return Err("palette needs at least two colors".into());
    }

    Ok((
        kind,
        ColorTable {
            stops,
            interpolate: true,
            rf_color: rf.unwrap_or([119, 0, 125, 255]),
        },
    ))
}
