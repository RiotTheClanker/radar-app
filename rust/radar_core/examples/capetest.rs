//! Render the HRRR CAPE field over the southern plains, as a PNG.
//!
//!   cargo run --example capetest
//!
//! Needs tools/testdata/hrrr_cape.grib2 — run tools/fetch_testdata.sh.

use radar_core::api;

fn main() {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../tools/testdata/hrrr_cape.grib2"
    );
    let Ok(data) = std::fs::read(path) else {
        eprintln!("no testdata; run tools/fetch_testdata.sh");
        return;
    };

    // Roughly Texas up to Nebraska, which is where the instability is on a
    // September afternoon.
    let frame = api::render_cape_view(data, 43.0, 26.0, -90.0, -106.0, 800, 800)
        .expect("render");
    println!(
        "{} — {} — run {} — {}x{}",
        frame.product_name, frame.unit, frame.timestamp, frame.width, frame.height
    );
    println!(
        "bounds N{:.2} S{:.2} E{:.2} W{:.2}",
        frame.north, frame.south, frame.east, frame.west
    );
    std::fs::write("cape.png", &frame.png).unwrap();
    println!("wrote cape.png ({} bytes)", frame.png.len());
}
