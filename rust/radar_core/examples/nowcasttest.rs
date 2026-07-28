fn main() {
    let a = std::fs::read("../../tools/testdata/nc_1").unwrap();
    let b = std::fs::read("../../tools/testdata/nc_2").unwrap();
    let dir = std::env::args().nth(1).unwrap();
    // KBUF area
    let (n, s, e, w) = (44.2, 41.8, -77.0, -80.4);
    for m in [0.0f32, 30.0, 60.0] {
        let t = std::time::Instant::now();
        let f = radar_core::api::nowcast_view(
            a.clone(), b.clone(), "L3".into(), m, n, s, e, w, 900, 700,
        ).unwrap();
        println!("+{m:>3} min: {} ts={} in {:?}", f.product_name, f.timestamp, t.elapsed());
        std::fs::write(format!("{dir}/nowcast_{}.png", m as i32), &f.png).unwrap();
    }
}
