//! GRIB2 model-field decoding, against a real HRRR CAPE message.
//!
//! Run `tools/fetch_testdata.sh` first; skipped when the file is absent so a
//! fresh checkout and CI still pass.
//!
//! The expected values below came from an independent reference decode of the
//! same message, written separately from this implementation. Complex packing
//! has enough moving parts — group widths, group lengths, second-order
//! differencing, sign-magnitude scale factors — that "it produced numbers"
//! proves very little on its own.

use radar_core::grib2;

fn cape() -> Option<Vec<u8>> {
    let path = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../tools/testdata/hrrr_cape.grib2"
    );
    std::fs::read(path).ok()
}

#[test]
fn decodes_the_grid_definition() {
    let Some(data) = cape() else {
        eprintln!("testdata missing, skipping (run tools/fetch_testdata.sh)");
        return;
    };
    let f = grib2::parse(&data).expect("parse");
    assert_eq!(f.grid.nx, 1799, "HRRR CONUS is 1799 wide");
    assert_eq!(f.grid.ny, 1059, "and 1059 tall");
    assert_eq!(f.grid.dx, 3000.0, "3 km spacing");
    assert_eq!(f.grid.dy, 3000.0);
    assert_eq!(f.values.len(), 1799 * 1059);
}

/// The projection, checked at the corners the grid definition names and at
/// one interior point. Getting the cone constant or the anchor wrong moves
/// the whole field without changing any value in it, which is the kind of
/// bug that looks fine until it is laid over a map.
#[test]
fn the_projection_lands_on_the_grid_corners() {
    let Some(data) = cape() else { return };
    let f = grib2::parse(&data).expect("parse");

    // The first grid point, as section 3 states it, must be grid (0, 0).
    let (gi, gj) = f.grid.to_grid(21.138123, 237.280472 - 360.0);
    assert!(gi.abs() < 0.01, "first point i = {gi}");
    assert!(gj.abs() < 0.01, "first point j = {gj}");

    // HRRR's published north-east corner is the far end of the grid.
    let (gi, gj) = f.grid.to_grid(47.84372, -60.91719);
    assert!((gi - 1798.0).abs() < 0.5, "NE corner i = {gi}");
    assert!((gj - 1058.0).abs() < 0.5, "NE corner j = {gj}");

    // Somewhere off the grid entirely must not resolve to an index.
    assert!(f.grid.index(-5.0, 10.0).is_none());
    assert!(f.grid.index(10.0, 1e9).is_none());
    let (gi, gj) = f.grid.to_grid(51.5, -0.12); // London
    assert!(f.grid.index(gi, gj).is_none(), "London is not in CONUS");
}

/// Values, against the independent reference decode.
#[test]
fn unpacks_the_same_values_as_the_reference() {
    let Some(data) = cape() else { return };
    let f = grib2::parse(&data).expect("parse");
    let v = &f.values;

    for (i, want) in [
        (0usize, 160.0f32),
        (1, 160.0),
        (2, 160.0),
        (1000, 3190.0),
        (500_000, 2640.0),
        (1_905_140, 0.0),
    ] {
        assert!(
            (v[i] - want).abs() < 0.01,
            "values[{i}] = {}, reference says {want}",
            v[i]
        );
    }

    let min = v.iter().copied().fold(f32::MAX, f32::min);
    let max = v.iter().copied().fold(f32::MIN, f32::max);
    assert_eq!(min, 0.0, "CAPE does not go negative");
    assert!((max - 5440.0).abs() < 0.01, "max {max}, reference says 5440");

    let sum: f64 = v.iter().map(|&x| x as f64).sum();
    assert!(
        (sum - 1_443_624_570.0).abs() < 1000.0,
        "sum {sum} drifted from the reference"
    );
}

/// A scrambled unpack still produces numbers in the right range — it just
/// puts them in the wrong places. Real CAPE is a smooth field, so neighbours
/// agree far more closely than distant points do, and that is what a
/// group-length or differencing bug would destroy.
#[test]
fn the_field_is_spatially_coherent() {
    let Some(data) = cape() else { return };
    let f = grib2::parse(&data).expect("parse");
    let v = &f.values;

    let mut adjacent = 0.0f64;
    let mut distant = 0.0f64;
    let n = 20_000;
    // A fixed stride rather than a random sample, so a failure is the same
    // failure every time.
    for k in 0..n {
        let i = (k * 71) % (v.len() - 1);
        adjacent += (v[i] - v[i + 1]).abs() as f64;
        let j = (i + v.len() / 3) % v.len();
        distant += (v[i] - v[j]).abs() as f64;
    }
    let ratio = adjacent / distant;
    assert!(
        ratio < 0.2,
        "neighbours differ by {:.0} and distant points by {:.0} (ratio {ratio:.3}) \
         — that is noise, not a weather field",
        adjacent / n as f64,
        distant / n as f64
    );
}

/// Physical sanity: in early September the Gulf coast is far more unstable
/// than the Canadian border. Row 0 is the south edge, because the scanning
/// mode says rows run south to north — reading that flag backwards would
/// flip the field top to bottom and pass every test above.
#[test]
fn the_field_is_the_right_way_up() {
    let Some(data) = cape() else { return };
    let f = grib2::parse(&data).expect("parse");
    let nx = f.grid.nx;
    let row = |j: usize| -> f64 {
        let r = &f.values[j * nx..(j + 1) * nx];
        r.iter().map(|&x| x as f64).sum::<f64>() / nx as f64
    };
    let south = row(0);
    let north = row(f.grid.ny - 1);
    assert!(
        south > north * 5.0,
        "south edge mean {south:.0} J/kg vs north edge {north:.0} — \
         the field looks upside down"
    );
}

#[test]
fn junk_is_refused_rather_than_guessed_at() {
    assert!(grib2::parse(b"not a grib file at all").is_err());
    assert!(grib2::parse(b"GRIB\x00\x00\x00\x01").is_err(), "edition 1");
    let Some(data) = cape() else { return };
    assert!(
        grib2::parse(&data[..data.len() / 2]).is_err(),
        "a truncated message must fail rather than return half a field"
    );
}
