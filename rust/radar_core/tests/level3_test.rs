//! Decoder regression tests against a real Level 3 file.
//!
//! Run `tools/fetch_testdata.sh` first to download sample data; tests are
//! skipped (pass trivially) when the file is absent so plain `cargo test`
//! works in a fresh checkout.

use radar_core::level3;
use radar_core::render::{rasterize_radials, ColorTable};

fn testdata() -> Option<Vec<u8>> {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../tools/testdata/latest_N0B"
    );
    std::fs::read(path).ok()
}

#[test]
fn parses_live_n0b() {
    let Some(data) = testdata() else {
        eprintln!("testdata missing, skipping (run tools/fetch_testdata.sh)");
        return;
    };
    let f = level3::parse(&data).expect("parse");
    assert_eq!(f.product_code, 153);
    // KTLX
    assert!((f.site_lat - 35.333).abs() < 0.01, "lat {}", f.site_lat);
    assert!((f.site_lon + 97.278).abs() < 0.01, "lon {}", f.site_lon);
    let r = f.radial.as_ref().expect("radial data");
    assert_eq!(r.nbins, 1840);
    assert_eq!(r.radials.len(), 720);
    assert_eq!(r.gate_size_m, 250.0);
    // Super-res reflectivity decodes to sane dBZ
    let mut max = f32::MIN;
    for rad in &r.radials {
        for &b in &rad.data {
            if let level3::BinValue::Value(v) = r.decoder.decode(b) {
                assert!((-35.0..=95.0).contains(&v), "dBZ out of range: {v}");
                max = max.max(v);
            }
        }
    }
    assert!(max > -32.0);
}

#[test]
fn rasterizes_n0b() {
    let Some(data) = testdata() else {
        return;
    };
    let f = level3::parse(&data).expect("parse");
    let img = rasterize_radials(&f, &ColorTable::reflectivity_default(), 256).expect("raster");
    assert_eq!(img.width, 256);
    assert!(img.north > f.site_lat && img.south < f.site_lat);
    assert!(img.pixels.iter().skip(3).step_by(4).any(|&a| a > 0), "image is fully transparent");
}
