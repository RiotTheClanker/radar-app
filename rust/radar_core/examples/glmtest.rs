fn main() {
    let path = std::env::args().nth(1).expect("file");
    let data = std::fs::read(&path).expect("read");
    let f = radar_core::glm::parse(&data).expect("parse GLM");
    println!("timestamp: {} flashes: {}", f.timestamp, f.lats.len());
    for i in 0..f.lats.len().min(5) {
        println!("  {:.4}, {:.4}", f.lats[i], f.lons[i]);
    }
}
