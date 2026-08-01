//! Score our hydrometeor classification against the NWS's.
//!   cargo run --release --example hcagrade -- VOLUME.ar2v N0H N1H ...
use radar_core::process::hca::Class;
use radar_core::process::hca_grade::{grade_sweep, Confusion};

fn main() {
    let mut args = std::env::args().skip(1);
    let vol_path = args.next().expect("usage: hcagrade VOLUME L3_HCA...");
    let l3_paths: Vec<String> = args.collect();
    if l3_paths.is_empty() {
        eprintln!("give at least one Level 3 HCA file");
        std::process::exit(2);
    }

    let data = std::fs::read(&vol_path).unwrap();
    let vol = radar_core::level2::parse(&data).expect("level 2 parse");
    let ours = radar_core::api::build_hca_grid(&vol).expect("our classification");
    {
        // What did the bright-band detector decide? A wrong melting level
        // moves the whole ice/liquid boundary, so it is the first thing to
        // check when the classes disagree systematically.
        use radar_core::process::grid3d::{build_grid_encoded, GridEncode, ENCODE_DBZ};
        let rho_enc = GridEncode { scale: 200.0, offset: -35.0, min_show: 0.2, no_echo: 1.0 };
        let z = build_grid_encoded(&vol.all_sweeps("REF"), 384, 40, 120_000.0, 16_000.0, ENCODE_DBZ);
        let r = build_grid_encoded(&vol.all_sweeps("RHO"), 384, 40, 120_000.0, 16_000.0, rho_enc);
        if let (Some(z), Some(r)) = (z, r) {
            let m = radar_core::process::hca::detect_melting_level(
                &z, &r,
                |raw| (raw as f32 - ENCODE_DBZ.offset) / ENCODE_DBZ.scale,
                |raw| (raw as f32 - rho_enc.offset) / rho_enc.scale,
            );
            println!("detected melting level: {m:.0} m");
        }
    }
    println!(
        "ours: {}x{}x{} voxels, {} classified",
        ours.nxy,
        ours.nxy,
        ours.nz,
        ours.data.iter().filter(|&&v| v != 0).count()
    );

    let mut c = Confusion::default();
    for p in &l3_paths {
        let d = std::fs::read(p).unwrap();
        let f = radar_core::level3::parse(&d).expect("level 3 parse");
        let Some(s) = f.to_sweep() else {
            eprintln!("{p}: no radial data");
            continue;
        };
        println!("  {p}  elev {:.1} deg", s.elevation_deg);
        grade_sweep(&ours, &s, &mut c);
    }

    println!();
    println!("gates the NWS classified and we could compare: {}", c.compared());
    println!("  outside our volume: {}", c.out_of_volume);
    println!("  we left empty:      {}", c.ours_empty);
    if c.compared() == 0 {
        println!("nothing overlapped; no score");
        return;
    }
    println!();
    println!("agreement: {:.1}%", 100.0 * c.agreement());
    println!();
    println!("worst disagreements (ours -> theirs):");
    for (a, b, n) in c.worst(10) {
        println!(
            "  {:>14} -> {:<14} {:>7}  ({:.1}%)",
            a.label(),
            b.label(),
            n,
            100.0 * n as f32 / c.compared() as f32
        );
    }
    println!();
    println!("per class, how often we agreed when the NWS said it:");
    for t in Class::ALL {
        let total: u32 = (0..11).map(|i| c.counts[i][t as usize]).sum();
        if total == 0 {
            continue;
        }
        let hit = c.counts[t as usize][t as usize];
        println!(
            "  {:>14} {:>7} gates, {:.1}% matched",
            t.label(),
            total,
            100.0 * hit as f32 / total as f32
        );
    }
}
