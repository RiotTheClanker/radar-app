fn main() {
    let data = std::fs::read(std::env::args().nth(1).unwrap()).unwrap();
    let out = std::env::args().nth(2).unwrap();
    let info = radar_core::api::volume3d_open(data, "REF".into(), 10.0, vec![]).unwrap();
    println!("gpu={} ex={} top={}", info.gpu, info.half_extent_m, info.top_m);
    let b = radar_core::api::volume3d_ground_bounds().unwrap();
    println!("ground bounds N{:.3} S{:.3} E{:.3} W{:.3}", b[0], b[1], b[2], b[3]);

    // Synthetic "basemap": green/grey checkerboard with a red north edge.
    let n = 512usize;
    let mut rgba = vec![0u8; n * n * 4];
    for y in 0..n {
        for x in 0..n {
            let o = (y * n + x) * 4;
            let c = if ((x / 32) + (y / 32)) % 2 == 0 { 60 } else { 100 };
            rgba[o] = c; rgba[o + 1] = c + 20; rgba[o + 2] = c; rgba[o + 3] = 255;
            if y < 8 { rgba[o] = 220; rgba[o + 1] = 40; rgba[o + 2] = 40; }
        }
    }
    radar_core::api::volume3d_set_ground(rgba, n as u32, n as u32).unwrap();

    let t = std::time::Instant::now();
    let f = radar_core::api::volume3d_render_fly(
        0.0, -1.7 * info.half_extent_m, 0.5 * info.top_m,
        0.0, -14.0, vec![0.0, 0.0, 0.0, 1.0, 1.0, 1.0], 1000, 700,
    ).unwrap();
    println!("frame in {:?}", t.elapsed());
    let file = std::fs::File::create(&out).unwrap();
    let mut enc = png::Encoder::new(std::io::BufWriter::new(file), f.width, f.height);
    enc.set_color(png::ColorType::Rgba);
    enc.set_depth(png::BitDepth::Eight);
    enc.write_header().unwrap().write_image_data(&f.rgba).unwrap();
    println!("wrote {out}");
}
