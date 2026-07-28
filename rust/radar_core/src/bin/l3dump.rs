//! Debug tool: decode a Level 3 file, print a summary, optionally write a PNG.
//!
//! Usage: l3dump <level3-file> [out.png]

use radar_core::level3;
use radar_core::render::{rasterize_sweep, ColorTable};

fn main() {
    let mut args = std::env::args().skip(1);
    let path = args.next().expect("usage: l3dump <level3-file> [out.png]");
    let out = args.next();

    let data = std::fs::read(&path).expect("read input file");
    let file = level3::parse(&data).expect("parse Level 3 file");

    println!("product code : {}", file.product_code);
    if let Some(info) = file.info {
        println!("product      : {} ({})", info.name, info.unit);
    }
    println!("site         : {:.4}, {:.4} ({} ft)", file.site_lat, file.site_lon, file.site_height_ft);
    println!("vcp / mode   : {} / {}", file.vcp, file.op_mode);
    println!("elevation    : #{} {:.1} deg", file.elevation_number, file.elevation_angle_deg);
    println!("scan time    : {} (unix)", file.volume_scan_time);
    match &file.radial {
        Some(r) => {
            println!(
                "radials      : {} x {} bins, gate {} m, first bin {}",
                r.radials.len(),
                r.nbins,
                r.gate_size_m,
                r.first_bin
            );
            println!("max range    : {:.1} km", file.max_range_m() / 1000.0);
            // Value stats
            let mut n = 0u64;
            let mut max = f32::MIN;
            for rad in &r.radials {
                for &b in &rad.data {
                    if let level3::BinValue::Value(v) = r.decoder.decode(b as u16) {
                        n += 1;
                        if v > max {
                            max = v;
                        }
                    }
                }
            }
            println!("data bins    : {} valid, max value {:.1}", n, if n > 0 { max } else { 0.0 });
        }
        None => println!("radials      : none decoded"),
    }

    if let Some(out_path) = out {
        let kind = file
            .info
            .map(|i| i.kind)
            .unwrap_or(level3::products::ProductKind::Reflectivity);
        let table = ColorTable::default_for(kind);
        let sweep = file.to_sweep().expect("no radial data");
        let img = rasterize_sweep(&sweep, &table, 1024).expect("rasterize");
        write_png(&out_path, img.width, img.height, &img.pixels);
        println!(
            "wrote {} ({}x{}, bounds N{:.3} S{:.3} E{:.3} W{:.3})",
            out_path, img.width, img.height, img.north, img.south, img.east, img.west
        );
    }
}

fn write_png(path: &str, w: u32, h: u32, rgba: &[u8]) {
    let file = std::fs::File::create(path).expect("create png");
    let mut enc = png::Encoder::new(std::io::BufWriter::new(file), w, h);
    enc.set_color(png::ColorType::Rgba);
    enc.set_depth(png::BitDepth::Eight);
    let mut writer = enc.write_header().expect("png header");
    writer.write_image_data(rgba).expect("png data");
}
