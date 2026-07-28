//! Rasterization of radar data into georeferenced RGBA images.

pub mod color_table;
pub mod raster;

pub use color_table::ColorTable;
pub use raster::{rasterize_radials, GeoImage};
