//! Level 3 product code metadata.

#[derive(Debug, Clone, Copy, PartialEq)]
pub enum ProductKind {
    Reflectivity,
    Velocity,
    SpectrumWidth,
    Zdr,
    CorrelationCoefficient,
    Kdp,
    HydroClass,
    Precipitation,
    Vil,
    EchoTops,
    Rotation,
    Other,
}

#[derive(Debug, Clone)]
pub struct ProductInfo {
    pub code: i16,
    pub abbr: &'static str,
    pub name: &'static str,
    pub kind: ProductKind,
    pub gate_size_m: f32,
    pub range_km: f32,
    pub unit: &'static str,
}

macro_rules! product {
    ($code:expr, $abbr:expr, $name:expr, $kind:expr, $gate:expr, $range:expr, $unit:expr) => {
        ProductInfo {
            code: $code,
            abbr: $abbr,
            name: $name,
            kind: $kind,
            gate_size_m: $gate,
            range_km: $range,
            unit: $unit,
        }
    };
}

pub static PRODUCTS: &[ProductInfo] = &[
    product!(94, "N_Q", "Base Reflectivity (legacy digital)", ProductKind::Reflectivity, 1000.0, 460.0, "dBZ"),
    product!(99, "N_U", "Base Velocity (legacy digital)", ProductKind::Velocity, 250.0, 300.0, "kt"),
    product!(153, "N_B", "Super-Res Base Reflectivity", ProductKind::Reflectivity, 250.0, 460.0, "dBZ"),
    product!(154, "N_G", "Super-Res Base Velocity", ProductKind::Velocity, 250.0, 300.0, "kt"),
    product!(155, "N_S", "Super-Res Spectrum Width", ProductKind::SpectrumWidth, 250.0, 300.0, "kt"),
    product!(159, "N_X", "Differential Reflectivity", ProductKind::Zdr, 250.0, 300.0, "dB"),
    product!(161, "N_C", "Correlation Coefficient", ProductKind::CorrelationCoefficient, 250.0, 300.0, ""),
    product!(163, "N_K", "Specific Differential Phase", ProductKind::Kdp, 250.0, 300.0, "deg/km"),
    product!(165, "N_H", "Hydrometeor Classification", ProductKind::HydroClass, 250.0, 300.0, ""),
    product!(170, "DAA", "Digital Accumulation Array", ProductKind::Precipitation, 250.0, 230.0, "in"),
    product!(172, "DTA", "Storm Total Accumulation", ProductKind::Precipitation, 250.0, 230.0, "in"),
];

pub fn product_info(code: i16) -> Option<&'static ProductInfo> {
    PRODUCTS.iter().find(|p| p.code == code)
}
