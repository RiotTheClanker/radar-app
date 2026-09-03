//! Decoder regression tests against a real Level 2 volume.
//!
//! Run `tools/fetch_testdata.sh` first; tests are skipped (pass trivially)
//! when the file is absent so plain `cargo test` works in a fresh checkout
//! and in CI, which does not fetch data.

use radar_core::level2;

/// KICX Cedar City, Utah — chosen because it is the highest NEXRAD in the
/// network, which makes it the site where the antenna altitude matters most
/// and the one where getting it wrong is most obvious.
fn kicx() -> Option<Vec<u8>> {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../tools/testdata/latest_l2_kicx"
    );
    std::fs::read(path).ok()
}

/// The antenna altitude is read out of the volume's own site block rather
/// than looked up in a table, so this is the test that the two shorts are
/// where the ICD says they are.
///
/// The 3D view plots echo heights, which are measured from the antenna,
/// against terrain measured from sea level. Reconciling them needs this
/// number, and a wrong one is worse than none: it would move the ground by
/// however far off it was, times the vertical exaggeration.
#[test]
fn reads_the_antenna_altitude() {
    let Some(data) = kicx() else {
        eprintln!("testdata missing, skipping (run tools/fetch_testdata.sh)");
        return;
    };
    let vol = level2::parse(&data).expect("parse");
    assert_eq!(vol.icao, "KICX");

    // NCEI puts KICX at 10757 ft = 3279 m. The volume reports site height and
    // feedhorn height separately (3244 + 34), and the sum should land on the
    // independent figure to within a few metres. A band rather than an exact
    // value because the two sources round differently, but tight enough that
    // reading the wrong field could not pass.
    assert!(
        (3250.0..3310.0).contains(&vol.antenna_alt_m),
        "antenna altitude {} m is not near the published 3279 m — the site \
         block offsets are wrong",
        vol.antenna_alt_m
    );

    // Sanity that we are reading the same block that carries the position,
    // since that is what anchors the offsets either side of it.
    assert!((37.0..38.2).contains(&vol.site_lat), "lat {}", vol.site_lat);
    assert!(
        (-113.4..-112.3).contains(&vol.site_lon),
        "lon {}",
        vol.site_lon
    );
}

/// A volume with no site block must not silently claim sea level, because a
/// zero here is indistinguishable from a radar that really is at sea level.
/// It is the documented fallback, so this pins it rather than leaving it to
/// be discovered.
#[test]
fn a_volume_without_a_site_block_reports_zero() {
    let mut header = b"AR2V0006.001".to_vec();
    header.extend_from_slice(&[0u8; 8]);
    header.extend_from_slice(b"KXXX");
    let vol = level2::parse(&header);
    // Either it refuses the truncated file or it parses with the documented
    // 0.0 default; both are honest, and neither may invent an altitude.
    if let Ok(v) = vol {
        assert_eq!(v.antenna_alt_m, 0.0);
    }
}

/// Records are decompressed across threads, and a volume is keyed by
/// elevation, so a batch folded back in the wrong order would quietly
/// reshuffle the cuts.
///
/// These checksums were taken from a single-threaded decode of this same
/// file and match the parallel one exactly. They are not magic numbers: any
/// change to them means the bytes coming out of the decoder moved.
#[test]
fn parallel_decompression_gives_the_sequential_answer() {
    let Some(data) = kicx() else {
        eprintln!("testdata missing, skipping (run tools/fetch_testdata.sh)");
        return;
    };
    let vol = level2::parse(&data).expect("parse");

    fn checksum(sweeps: &[radar_core::sweep::Sweep]) -> f64 {
        sweeps
            .iter()
            .map(|s| {
                s.radials
                    .iter()
                    .map(|r| match &r.data {
                        radar_core::sweep::GateData::U8(v) => {
                            v.iter().map(|&x| x as f64).sum::<f64>()
                        }
                        radar_core::sweep::GateData::U16(v) => {
                            v.iter().map(|&x| x as f64).sum::<f64>()
                        }
                    })
                    .sum::<f64>()
            })
            .sum()
    }

    for (moment, cuts, want) in [
        ("REF", 14usize, 53_280_262.0f64),
        ("VEL", 10, 44_078_543.0),
        ("ZDR", 10, 223_754_704.0),
        ("RHO", 10, 115_554_244.0),
    ] {
        let sweeps = vol.all_sweeps(moment);
        assert_eq!(sweeps.len(), cuts, "{moment} cut count");
        assert_eq!(checksum(&sweeps), want, "{moment} gate data changed");
        // Cuts are returned lowest first; a reordered fold shows up here too.
        let mut sorted = sweeps.iter().map(|s| s.elevation_deg).collect::<Vec<_>>();
        sorted.sort_by(|a, b| a.total_cmp(b));
        assert_eq!(
            sweeps.iter().map(|s| s.elevation_deg).collect::<Vec<_>>(),
            sorted,
            "{moment} cuts came back out of order"
        );
    }
}

