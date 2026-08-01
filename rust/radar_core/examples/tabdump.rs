//! Dump the Tabular Alphanumeric Block of a Level 3 product.
//!   cargo run --example tabdump -- FILE
fn main() {
    let path = std::env::args().nth(1).expect("usage: tabdump FILE");
    let data = std::fs::read(&path).unwrap();
    let f = radar_core::level3::parse(&data).unwrap();
    println!("product {} elev {:.1}", f.product_code, f.elevation_angle_deg);
    match f.tabular {
        Some(t) => println!("--- tabular ({} bytes) ---\n{t}", t.len()),
        None => println!("(no tabular block)"),
    }
}
