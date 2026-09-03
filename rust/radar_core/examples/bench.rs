//! Where the engine actually spends its time.
//!
//!   cargo run --release --example bench
//!
//! Needs `tools/fetch_testdata.sh` to have run. Release only — a debug build
//! measures the absence of optimisation, not the code.
//!
//! Exists so optimisation targets are chosen by measurement. Every path here
//! is one the app runs while somebody is watching a storm.

use std::time::Instant;

fn read(name: &str) -> Option<Vec<u8>> {
    let path = format!(
        "{}/../../tools/testdata/{}",
        env!("CARGO_MANIFEST_DIR"),
        name
    );
    std::fs::read(path).ok()
}

/// Median of a few runs. The mean is at the mercy of one unlucky scheduling
/// hiccup, and these are short enough for that to dominate.
fn time<T>(label: &str, runs: usize, mut f: impl FnMut() -> T) {
    let mut times = Vec::with_capacity(runs);
    for _ in 0..runs {
        let t = Instant::now();
        std::hint::black_box(f());
        times.push(t.elapsed());
    }
    times.sort();
    println!("  {label:<44} {:>9.2?}", times[times.len() / 2]);
}

fn main() {
    let l2 = read("latest_l2_kicx");
    let n0b = read("latest_N0B");
    let cape = read("hrrr_cape.grib2");

    if let Some(d) = n0b.as_ref() {
        println!("Level 3 ({} KB)", d.len() / 1024);
        time("parse", 20, || radar_core::level3::parse(d).unwrap());
        let file = radar_core::level3::parse(d).unwrap();
        let sweep = file.to_sweep().unwrap();
        let table = radar_core::render::ColorTable::reflectivity_default();
        time("rasterize_sweep 1024px", 10, || {
            radar_core::render::rasterize_sweep(&sweep, &table, 1024)
        });
        time("render_level3_view 1600x900", 10, || {
            radar_core::api::render_level3_view(
                d.clone(),
                36.5,
                34.0,
                -96.0,
                -99.0,
                1600,
                900,
            )
        });
        time("full render_level3_frame 1024px", 10, || {
            radar_core::api::render_level3_frame(d.clone(), 1024)
        });
    }

    if let Some(d) = l2.as_ref() {
        println!("\nLevel 2 ({} MB)", d.len() / 1024 / 1024);
        time("parse (whole volume)", 5, || {
            radar_core::level2::parse(d).unwrap()
        });
        let vol = radar_core::level2::parse(d).unwrap();
        println!("    cuts: {}", vol.all_sweeps("REF").len());
        // The realistic sequence: render the frame, then read a value off it,
        // then open the cursor on it. All three used to parse from scratch.
        time("view + sample + cursor open (same frame)", 5, || {
            let _ = radar_core::api::render_level2_view(
                d.clone(), "REF".into(), 0, 38.5, 36.5, -111.5, -114.0, 800, 600,
            );
            let _ = radar_core::api::sample_level2(d.clone(), "REF".into(), 0, 37.6, -112.9);
            let _ = radar_core::api::inspect_open_level2(d.clone(), "REF".into(), 0);
        });
        time("render_level2_view REF 1600x900", 5, || {
            radar_core::api::render_level2_view(
                d.clone(),
                "REF".into(),
                0,
                38.5,
                36.5,
                -111.5,
                -114.0,
                1600,
                900,
            )
        });
        let cuts = vol.all_sweeps("REF");
        time("build_grid 384x384x40", 3, || {
            radar_core::process::grid3d::build_grid(&cuts, 384, 40, 120_000.0, 16_000.0)
        });
        time("build_hca_grid", 3, || {
            radar_core::api::build_hca_grid(&vol)
        });
    }

    if let Some(d) = cape.as_ref() {
        println!("\nHRRR CAPE ({} KB)", d.len() / 1024);
        time("grib2 parse", 10, || radar_core::grib2::parse(d).unwrap());
        time("render_cape_view 1200x800", 10, || {
            radar_core::api::render_cape_view(d.clone(), 43.0, 26.0, -90.0, -106.0, 1200, 800)
        });
    }
}
