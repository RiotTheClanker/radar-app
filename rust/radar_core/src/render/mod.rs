//! Rasterization of radar data into georeferenced RGBA images.

pub mod color_table;
pub mod raster;
pub mod gpu3d;
pub mod volume3d;

pub use color_table::ColorTable;
pub use raster::{
    colorize, latlon_raw_view, rasterize_lambert_view, rasterize_latlon_view, rasterize_sweep,
    rasterize_sweep_view,
    sweep_bounds, sweep_raw_view, GeoImage,
};
