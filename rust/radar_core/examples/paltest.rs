fn main() {
    let txt = std::fs::read_to_string(std::env::args().nth(1).unwrap()).unwrap();
    let kind = radar_core::api::install_palette(txt).unwrap();
    println!("installed for: {kind}");
    let t = radar_core::render::ColorTable::default_for(
        radar_core::level3::products::ProductKind::Reflectivity);
    println!("stops: {} interpolate: {}", t.stops.len(), t.interpolate);
    for v in [10.0f32, 30.0, 50.0, 70.0] {
        println!("  {v:>5} dBZ -> {:?}", t.sample(v));
    }
}
