//! Rasterization of radar data into georeferenced RGBA images.

pub mod color_table;
pub mod raster;
pub mod volume3d;

pub use color_table::ColorTable;
pub use raster::{rasterize_sweep, rasterize_sweep_view, sweep_bounds, GeoImage};
