//! Renders the 3D view against a synthetic ridge to check the terrain
//! heightfield, with no radar file needed. Writes flat.png and terrain.png.
use radar_core::process::grid3d::Grid3D;
use radar_core::render::gpu3d::{FlyParams, GpuVolume};

fn main() {
    let nxy = 64;
    let nz = 32;
    let half_extent_m = 120_000.0f32;
    let top_m = 16_000.0f32;

    // A blob of "storm" floating off to one side.
    let mut data = vec![0u8; nxy * nxy * nz];
    for z in 6..14 {
        for y in 34..46 {
            for x in 34..46 {
                data[(z * nxy + y) * nxy + x] = 200;
            }
        }
    }
    let grid = Grid3D {
        nxy,
        nz,
        data,
        half_extent_m,
        top_m,
    };

    let mut pal = [[0u8; 4]; 256];
    for (i, p) in pal.iter_mut().enumerate().skip(2) {
        *p = [255, (i / 2) as u8, 40, 200];
    }

    let mut gpu = match GpuVolume::new(&grid, &pal, 4.0, false) {
        Ok(g) => g,
        Err(e) => {
            println!("NO GPU: {e}");
            return;
        }
    };

    // Flat grey basemap so the relief shading is what shows.
    let gw = 256u32;
    gpu.set_ground(&vec![120u8; (gw * gw * 4) as usize], gw, gw);

    let params = FlyParams {
        eye: [0.0, -1.7 * half_extent_m, 0.35 * top_m * 4.0],
        yaw_deg: 0.0,
        pitch_deg: -8.0,
        fov_deg: 55.0,
        clip_min: [0.0, 0.0, 0.0],
        clip_max: [1.0, 1.0, 1.0],
    };

    let write = |name: &str, px: &[u8], w: u32, h: u32| {
        let f = std::fs::File::create(name).unwrap();
        let mut e = png::Encoder::new(std::io::BufWriter::new(f), w, h);
        e.set_color(png::ColorType::Rgba);
        e.set_depth(png::BitDepth::Eight);
        e.write_header().unwrap().write_image_data(px).unwrap();
        println!("wrote {name}");
    };

    let (w, h) = (480u32, 320u32);
    let flat = gpu.render(&params, w, h).unwrap();
    write("flat.png", &flat, w, h);

    // A ridge running east-west, 3 km tall, plus a taller peak.
    let n = 256usize;
    let mut heights = vec![0f32; n * n];
    for ty in 0..n {
        for tx in 0..n {
            let fx = tx as f32 / n as f32 - 0.5;
            let fy = ty as f32 / n as f32 - 0.5;
            let ridge = 3000.0 * (-(fy * fy) / 0.005).exp();
            let peak =
                4500.0 * (-((fx + 0.2) * (fx + 0.2) + (fy - 0.1) * (fy - 0.1)) / 0.004).exp();
            heights[ty * n + tx] = ridge.max(peak);
        }
    }
    gpu.set_terrain(&heights, n as u32, n as u32);
    let terr = gpu.render(&params, w, h).unwrap();
    write("terrain.png", &terr, w, h);

    // And the cone of silence over the site.
    gpu.clear_terrain();
    gpu.set_beam_limits(19.5);
    gpu.set_show_cone(true);
    let cone = gpu.render(&params, w, h).unwrap();
    write("cone.png", &cone, w, h);

    // How different are they? If terrain did nothing this is ~0.
    let diff = flat
        .chunks(4)
        .zip(terr.chunks(4))
        .filter(|(a, b)| {
            (a[0] as i32 - b[0] as i32).abs()
                + (a[1] as i32 - b[1] as i32).abs()
                + (a[2] as i32 - b[2] as i32).abs()
                > 12
        })
        .count();
    let total = (w * h) as usize;
    println!(
        "pixels changed by terrain: {diff}/{total} ({:.1}%)",
        100.0 * diff as f32 / total as f32
    );
}
