fn main() {
    let data = std::fs::read(std::env::args().nth(1).unwrap()).unwrap();
    let out = std::env::args().nth(2).unwrap();
    let t = std::time::Instant::now();
    let info = radar_core::api::volume3d_open(data, "REF".into(), 10.0).unwrap();
    println!("open: gpu={} ex={} top={} in {:?}", info.gpu, info.half_extent_m, info.top_m, t.elapsed());
    let t2 = std::time::Instant::now();
    let mut frame = None;
    for i in 0..10 {
        let f = radar_core::api::volume3d_render_fly(
            0.0, -1.6 * info.half_extent_m, 0.45 * info.top_m,
            i as f32, 8.0, vec![0.0, 0.0, 0.0, 1.0, 1.0, 1.0], 1000, 700,
        ).unwrap();
        frame = Some(f);
    }
    println!("10 frames in {:?} ({:?}/frame)", t2.elapsed(), t2.elapsed() / 10);
    let f = frame.unwrap();
    // encode png for inspection
    let file = std::fs::File::create(&out).unwrap();
    let mut enc = png::Encoder::new(std::io::BufWriter::new(file), f.width, f.height);
    enc.set_color(png::ColorType::Rgba);
    enc.set_depth(png::BitDepth::Eight);
    enc.write_header().unwrap().write_image_data(&f.rgba).unwrap();
    println!("wrote {out}");
}
