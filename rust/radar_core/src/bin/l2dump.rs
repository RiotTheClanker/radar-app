//! Debug tool: decode a Level 2 volume, print a summary, optionally render
//! one moment to PNG.
//!
//! Usage: l2dump <archive2-file> [MOMENT [ELEV_INDEX [out.png]]]

use radar_core::level2;
use radar_core::level3::products::ProductKind;
use radar_core::render::{rasterize_sweep, ColorTable};

fn main() {
    let mut args = std::env::args().skip(1);
    let path = args.next().expect("usage: l2dump <file> [MOMENT [IDX [out.png]]]");
    let moment = args.next().unwrap_or_else(|| "REF".to_string());
    let idx: usize = args.next().map(|s| s.parse().unwrap()).unwrap_or(0);
    let out = args.next();

    let data = std::fs::read(&path).expect("read input");
    let vol = level2::parse(&data).expect("parse Level 2 volume");

    println!("site  : {} {:.4}, {:.4}", vol.icao, vol.site_lat, vol.site_lon);
    println!("vcp   : {}", vol.vcp);
    for m in ["REF", "VEL", "SW", "ZDR", "PHI", "RHO"] {
        let cuts = vol.cuts_for(m);
        if !cuts.is_empty() {
            let angles: Vec<String> =
                cuts.iter().map(|c| format!("{:.1}", c.elevation_deg)).collect();
            println!("{:4}  : {} cuts [{}]", m, cuts.len(), angles.join(", "));
        }
    }

    let sweep = vol.sweep(&moment, idx).expect("requested sweep");
    println!(
        "sweep : {} cut {} -> {:.1} deg, {} radials x {} gates ({} m), max raw {}",
        moment,
        idx,
        sweep.elevation_deg,
        sweep.radials.len(),
        sweep.nbins,
        sweep.gate_size_m,
        sweep.max_raw
    );

    if let Some(out_path) = out {
        let kind = match moment.as_str() {
            "VEL" => ProductKind::Velocity,
            "ZDR" => ProductKind::Zdr,
            "RHO" => ProductKind::CorrelationCoefficient,
            _ => ProductKind::Reflectivity,
        };
        let img = rasterize_sweep(&sweep, &ColorTable::default_for(kind), 1024).expect("raster");
        let file = std::fs::File::create(&out_path).expect("create png");
        let mut enc = png::Encoder::new(std::io::BufWriter::new(file), img.width, img.height);
        enc.set_color(png::ColorType::Rgba);
        enc.set_depth(png::BitDepth::Eight);
        let mut w = enc.write_header().expect("png header");
        w.write_image_data(&img.pixels).expect("png data");
        println!("wrote {out_path}");
    }
}
