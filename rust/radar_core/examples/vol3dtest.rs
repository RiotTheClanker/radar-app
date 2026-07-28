fn main() {
    let data = std::fs::read(std::env::args().nth(1).unwrap()).unwrap();
    let out = std::env::args().nth(2).unwrap();
    let t = std::time::Instant::now();
    let f = radar_core::api::render_volume3d(data, 35.0, 28.0, 1.4, 5.0, 900, 650).unwrap();
    println!("rendered {}x{} in {:?}", f.width, f.height, t.elapsed());
    std::fs::write(&out, &f.png).unwrap();
}
