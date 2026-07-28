//! radar_core — the on-device weather radar engine.
//!
//! All decoding, processing, and rasterization of NEXRAD data happens here,
//! in native code, on the user's device. The Flutter app hands this crate raw
//! bytes fetched from NOAA open-data sources and gets back decoded products
//! and ready-to-display georeferenced RGBA images.

pub mod api;
pub mod error;
pub mod glm;
pub mod level2;
pub mod level3;
pub mod process;
pub mod render;
pub mod sweep;

pub use error::RadarError;
