fn main() {
    let data = std::fs::read(std::env::args().nth(1).unwrap()).unwrap();
    let out = std::env::args().nth(2).unwrap();
    let t = std::time::Instant::now();
    let g = radar_core::mrms::parse(&data, 3).unwrap();
    println!("grid {}x{} N{:.2} S{:.2} E{:.2} W{:.2} ts={} in {:?}",
        g.nx, g.ny, g.north, g.south, g.east, g.west, g.timestamp, t.elapsed());
    let n = g.data.iter().filter(|&&v| v > 0).count();
    let mx = g.data.iter().copied().max().unwrap_or(0);
    println!("non-empty cells: {} max dBZ {:.1}", n, (mx as f32 - 66.0) / 2.0);
    let f = radar_core::api::render_mrms_view(data, 50.0, 24.0, -66.0, -125.0, 1400, 900).unwrap();
    std::fs::write(&out, &f.png).unwrap();
    println!("wrote {out}");
}
