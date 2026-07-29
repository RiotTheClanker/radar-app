//! Color tables mapping physical values to display colors.
//!
//! Tables are breakpoint lists; sampling either steps or linearly
//! interpolates between breakpoints. `.pal` import will build on
//! this same structure later.

use crate::level3::{BinValue, ValueDecoder};
use crate::level3::products::ProductKind;

#[derive(Debug, Clone, Copy)]
pub struct ColorStop {
    pub value: f32,
    pub color: [u8; 4],
}

#[derive(Debug, Clone)]
pub struct ColorTable {
    pub stops: Vec<ColorStop>,
    pub interpolate: bool,
    /// Color for range-folded bins (classic purple).
    pub rf_color: [u8; 4],
}

impl ColorTable {
    pub fn sample(&self, v: f32) -> [u8; 4] {
        let stops = &self.stops;
        if stops.is_empty() {
            return [0, 0, 0, 0];
        }
        if v < stops[0].value {
            return [0, 0, 0, 0]; // below scale: transparent
        }
        if v >= stops[stops.len() - 1].value {
            return stops[stops.len() - 1].color;
        }
        let idx = stops.partition_point(|s| s.value <= v) - 1;
        if !self.interpolate {
            return stops[idx].color;
        }
        let a = &stops[idx];
        let b = &stops[idx + 1];
        let t = (v - a.value) / (b.value - a.value);
        let mut out = [0u8; 4];
        for i in 0..4 {
            out[i] = (a.color[i] as f32 + t * (b.color[i] as f32 - a.color[i] as f32)) as u8;
        }
        out
    }

    /// Precompute a raw-value -> RGBA lookup table for one product's decoder.
    /// `n` is the LUT size: 256 for 8-bit data, up to 65536 for 16-bit.
    pub fn build_lut(&self, decoder: &ValueDecoder, n: usize) -> Vec<[u8; 4]> {
        (0..n)
            .map(|raw| match decoder.decode(raw as u16) {
                BinValue::NoData => [0, 0, 0, 0],
                BinValue::RangeFolded => self.rf_color,
                BinValue::Value(v) => self.sample(v),
            })
            .collect()
    }

    /// Pick a sensible default table for a product kind. A user-imported
    /// imported `.pal` table for that kind wins over the built-in palette.
    pub fn default_for(kind: ProductKind) -> ColorTable {
        if let Some(custom) = crate::palette::custom_for(kind) {
            return custom;
        }
        match kind {
            ProductKind::Velocity => ColorTable::velocity_default(),
            ProductKind::CorrelationCoefficient => ColorTable::cc_default(),
            ProductKind::Zdr => ColorTable::zdr_default(),
            ProductKind::Kdp => ColorTable::kdp_default(),
            ProductKind::HydroClass => ColorTable::hydro_class_default(),
            ProductKind::Precipitation => ColorTable::precip_default(),
            ProductKind::Vil => ColorTable::vil_default(),
            ProductKind::EchoTops => ColorTable::echo_tops_default(),
            ProductKind::Rotation => ColorTable::rotation_default(),
            _ => ColorTable::reflectivity_default(),
        }
    }

    /// Classic NWS reflectivity palette (dBZ), smoothly interpolated.
    pub fn reflectivity_default() -> ColorTable {
        let stops = vec![
            (5.0, [4, 233, 231]),
            (10.0, [1, 159, 244]),
            (15.0, [3, 0, 244]),
            (20.0, [2, 253, 2]),
            (25.0, [1, 197, 1]),
            (30.0, [0, 142, 0]),
            (35.0, [253, 248, 2]),
            (40.0, [229, 188, 0]),
            (45.0, [253, 149, 0]),
            (50.0, [253, 0, 0]),
            (55.0, [212, 0, 0]),
            (60.0, [188, 0, 0]),
            (65.0, [248, 0, 253]),
            (70.0, [152, 84, 198]),
            (75.0, [253, 253, 253]),
        ];
        ColorTable {
            stops: opaque(stops),
            interpolate: true,
            rf_color: [119, 0, 125, 255],
        }
    }

    /// Base velocity palette (m/s): green inbound, red outbound.
    pub fn velocity_default() -> ColorTable {
        let stops = vec![
            (-64.0, [144, 255, 220]),
            (-32.0, [0, 224, 96]),
            (-10.0, [0, 128, 32]),
            (-1.0, [88, 110, 88]),
            (0.0, [118, 118, 118]),
            (1.0, [110, 88, 88]),
            (10.0, [128, 0, 32]),
            (32.0, [224, 0, 64]),
            (64.0, [255, 144, 200]),
        ];
        ColorTable {
            stops: opaque(stops),
            interpolate: true,
            rf_color: [119, 0, 125, 255],
        }
    }

    /// Correlation coefficient (unitless 0.2–1.05).
    pub fn cc_default() -> ColorTable {
        let stops = vec![
            (0.20, [0, 0, 0]),
            (0.45, [110, 60, 160]),
            (0.65, [40, 60, 220]),
            (0.80, [0, 200, 255]),
            (0.90, [0, 220, 0]),
            (0.95, [255, 255, 0]),
            (0.98, [255, 120, 0]),
            (1.00, [255, 0, 0]),
            (1.05, [255, 255, 255]),
        ];
        ColorTable {
            stops: opaque(stops),
            interpolate: true,
            rf_color: [119, 0, 125, 255],
        }
    }

    /// Differential reflectivity (dB).
    pub fn zdr_default() -> ColorTable {
        let stops = vec![
            (-4.0, [40, 40, 40]),
            (-2.0, [130, 130, 130]),
            (0.0, [200, 200, 200]),
            (0.5, [0, 150, 255]),
            (1.0, [0, 220, 100]),
            (2.0, [255, 255, 0]),
            (3.0, [255, 140, 0]),
            (4.0, [255, 0, 0]),
            (6.0, [255, 0, 255]),
            (8.0, [255, 255, 255]),
        ];
        ColorTable {
            stops: opaque(stops),
            interpolate: true,
            rf_color: [119, 0, 125, 255],
        }
    }

    /// Specific differential phase (deg/km).
    pub fn kdp_default() -> ColorTable {
        let stops = vec![
            (-2.0, [80, 80, 80]),
            (0.0, [170, 170, 170]),
            (0.5, [0, 180, 0]),
            (1.0, [255, 255, 0]),
            (2.0, [255, 150, 0]),
            (3.0, [255, 0, 0]),
            (5.0, [255, 0, 255]),
            (7.0, [255, 255, 255]),
        ];
        ColorTable {
            stops: opaque(stops),
            interpolate: true,
            rf_color: [119, 0, 125, 255],
        }
    }

    /// Hydrometeor classification — categorical (class codes in steps of 10).
    pub fn hydro_class_default() -> ColorTable {
        let stops = vec![
            (10.0, [156, 128, 100]),  // biological
            (20.0, [95, 95, 95]),     // ground clutter / AP
            (30.0, [255, 200, 255]),  // ice crystals
            (40.0, [150, 180, 255]),  // dry snow
            (50.0, [70, 110, 255]),   // wet snow
            (60.0, [0, 190, 0]),      // light/moderate rain
            (70.0, [0, 120, 0]),      // heavy rain
            (80.0, [230, 200, 0]),    // big drops
            (90.0, [255, 140, 0]),    // graupel
            (100.0, [230, 0, 0]),     // hail (possibly with rain)
            (140.0, [150, 0, 200]),   // unknown
        ];
        ColorTable {
            stops: opaque(stops),
            interpolate: false,
            rf_color: [119, 0, 125, 255],
        }
    }

    /// Azimuthal shear (m/s per km). Weak shear fades to transparent so only
    /// genuine rotation couplets stand out.
    pub fn rotation_default() -> ColorTable {
        let stops = vec![
            ColorStop { value: -30.0, color: [0, 60, 255, 255] },
            ColorStop { value: -15.0, color: [0, 180, 255, 220] },
            ColorStop { value: -5.0, color: [0, 0, 0, 0] },
            ColorStop { value: 5.0, color: [0, 0, 0, 0] },
            ColorStop { value: 15.0, color: [255, 220, 0, 220] },
            ColorStop { value: 25.0, color: [255, 80, 0, 255] },
            ColorStop { value: 35.0, color: [255, 0, 255, 255] },
        ];
        ColorTable {
            stops,
            interpolate: true,
            rf_color: [119, 0, 125, 255],
        }
    }

    /// Vertically integrated liquid (kg/m²).
    pub fn vil_default() -> ColorTable {
        let stops = vec![
            (0.5, [70, 70, 70]),
            (5.0, [0, 180, 220]),
            (10.0, [0, 100, 255]),
            (20.0, [0, 200, 0]),
            (30.0, [255, 255, 0]),
            (40.0, [255, 150, 0]),
            (50.0, [255, 0, 0]),
            (60.0, [255, 0, 255]),
            (70.0, [255, 255, 255]),
        ];
        ColorTable {
            stops: opaque(stops),
            interpolate: true,
            rf_color: [119, 0, 125, 255],
        }
    }

    /// Echo tops (kft).
    pub fn echo_tops_default() -> ColorTable {
        let stops = vec![
            (5.0, [40, 60, 120]),
            (15.0, [0, 120, 255]),
            (25.0, [0, 220, 180]),
            (35.0, [80, 230, 0]),
            (45.0, [255, 255, 0]),
            (55.0, [255, 120, 0]),
            (65.0, [255, 0, 60]),
            (75.0, [255, 255, 255]),
        ];
        ColorTable {
            stops: opaque(stops),
            interpolate: true,
            rf_color: [119, 0, 125, 255],
        }
    }

    /// Storm-total / accumulation precipitation (inches).
    pub fn precip_default() -> ColorTable {
        let stops = vec![
            (0.01, [60, 60, 60]),
            (0.1, [0, 120, 200]),
            (0.25, [0, 200, 255]),
            (0.5, [0, 190, 0]),
            (1.0, [255, 255, 0]),
            (2.0, [255, 150, 0]),
            (3.0, [255, 0, 0]),
            (5.0, [200, 0, 120]),
            (8.0, [255, 255, 255]),
        ];
        ColorTable {
            stops: opaque(stops),
            interpolate: true,
            rf_color: [119, 0, 125, 255],
        }
    }
}

fn opaque(stops: Vec<(f32, [u8; 3])>) -> Vec<ColorStop> {
    stops
        .into_iter()
        .map(|(value, c)| ColorStop {
            value,
            color: [c[0], c[1], c[2], 255],
        })
        .collect()
}
