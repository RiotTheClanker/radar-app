fn main() {
    let data = std::fs::read(std::env::args().nth(1).unwrap()).unwrap();
    let out_dir = std::env::args().nth(2).unwrap();
    for m in ["CREF", "VIL", "ET", "SRM"] {
        match radar_core::api::render_level2_frame(data.clone(), m.to_string(), 0, 1024) {
            Ok(f) => {
                let path = format!("{out_dir}/l2_{m}.png");
                std::fs::write(&path, &f.png).unwrap();
                println!("{m}: ok, {} ({} elev {:.1})", f.product_name, path, f.elevation_deg);
            }
            Err(e) => println!("{m}: ERROR {e}"),
        }
    }
}
