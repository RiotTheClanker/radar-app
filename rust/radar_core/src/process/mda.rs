//! NOAA's mesocyclone detections, from the Level 3 MD product (code 141).
//!
//! The Mesocyclone Detection Algorithm finds rotation by looking for velocity
//! couplets that persist through depth and time — not from a single tilt, and
//! not from a single volume. Writing that here would mean reimplementing it
//! against the same data the NWS already ran it on, so this reads the answer.
//!
//! The table lives in the Tabular Alphanumeric Block:
//!
//! ```text
//!  CIRC  AZRAN   SR STM |-LOW LEVEL-|  |--DEPTH--|  |-MAX RV-| TVS  MOTION   MSI
//!   ID   deg/nm     ID  RV   DV  BASE  kft STMREL%  kft    kts     deg/kts
//!
//!   22  226/ 24  5L A9  17   15  < 2   >10   27       7     38  N  025/  8  2902
//! ```
//!
//! Two fields make this worth more than a dot on a map. `STM ID` is the same
//! cell id the storm tracks carry, so a circulation can be tied to the storm
//! it belongs to. And `TVS` says whether the tornado vortex signature
//! algorithm fired on this circulation, which is the question #26 was really
//! asking.
//!
//! Fields are read from both ends rather than by fixed column: the middle of
//! the row varies (`< 2`, `>10`, blanks where a value is missing) while the
//! identity at the front and the motion and strength index at the back are
//! dependable.

use crate::process::sti::squash;

/// One circulation.
#[derive(Clone, Debug, PartialEq)]
pub struct Mesocyclone {
    /// Circulation id, unique within the volume.
    pub id: String,
    pub lat: f64,
    pub lon: f64,
    /// Strength rank, 1–9 with a trailing L for low-topped, as printed.
    /// Higher is stronger; the NWS treats 5 and above as significant.
    pub rank: String,
    /// The storm cell this belongs to, matching the id in the storm tracks.
    /// Empty when the algorithm did not associate one.
    pub storm_id: String,
    /// Peak rotational velocity, knots.
    pub max_rv_kt: f32,
    /// The tornado vortex signature algorithm fired on this circulation.
    pub tvs: bool,
    /// Mesocyclone Strength Index. Roughly, how much rotation over how much
    /// depth; the NWS uses it to rank circulations against each other.
    pub msi: Option<i32>,
    /// Degrees true it is heading toward, and speed in knots.
    pub motion: Option<(f32, f32)>,
}

const NM_PER_DEG_LAT: f64 = 60.0;

fn az_ran_to_latlon(site_lat: f64, site_lon: f64, az_deg: f64, ran_nm: f64) -> (f64, f64) {
    let a = az_deg.to_radians();
    let lat = site_lat + ran_nm * a.cos() / NM_PER_DEG_LAT;
    let coslat = (0.5 * (site_lat + lat)).to_radians().cos().abs().max(1e-6);
    (lat, site_lon + ran_nm * a.sin() / (NM_PER_DEG_LAT * coslat))
}

fn pair(s: &str) -> Option<(f32, f32)> {
    let (a, b) = s.split_once('/')?;
    Some((a.trim().parse().ok()?, b.trim().parse().ok()?))
}

/// Read the circulation table out of an MD tabular block.
pub fn parse(tabular: &str, site_lat: f64, site_lon: f64) -> Vec<Mesocyclone> {
    let mut out = Vec::new();
    for line in tabular.lines() {
        let line = squash(line);
        let f: Vec<&str> = line.split_whitespace().collect();
        if f.len() < 8 {
            continue;
        }
        // Front: id, position, rank, storm id.
        if f[0].parse::<u32>().is_err() {
            continue;
        }
        let Some((az, ran)) = pair(f[1]) else {
            continue;
        };
        if !(0.0..=360.0).contains(&az) || !(0.0..=500.0).contains(&ran) {
            continue;
        }
        let (lat, lon) = az_ran_to_latlon(site_lat, site_lon, az as f64, ran as f64);

        // Back: MSI, motion, TVS flag, and the peak rotational velocity that
        // sits just before the flag.
        let msi = f[f.len() - 1].parse::<i32>().ok();
        let motion = pair(f[f.len() - 2]);
        let tvs_at = f.len() - 3;
        let tvs = match f[tvs_at] {
            "Y" => true,
            "N" => false,
            // Row does not end the way we expect; take the identity only
            // rather than guess at the numbers.
            _ => {
                out.push(Mesocyclone {
                    id: f[0].to_string(),
                    lat,
                    lon,
                    rank: f[2].to_string(),
                    storm_id: f.get(3).map_or(String::new(), |s| s.to_string()),
                    max_rv_kt: 0.0,
                    tvs: false,
                    msi: None,
                    motion: None,
                });
                continue;
            }
        };
        let max_rv_kt = f
            .get(tvs_at - 1)
            .and_then(|s| s.parse::<f32>().ok())
            .unwrap_or(0.0);

        out.push(Mesocyclone {
            id: f[0].to_string(),
            lat,
            lon,
            rank: f[2].to_string(),
            storm_id: f[3].to_string(),
            max_rv_kt,
            tvs,
            msi,
            motion,
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    // Lifted verbatim from LBB_NMD_2026_08_01_03_32_47.
    const REAL: &str = "\
                        MESOCYCLONE DETECTION ALGORITHM
     RADAR ID: 398     DATE: 08/01/2026   TIME: 03:32:47   Avg dir/spd: 023/  3

 CIRC  AZRAN   SR STM |-LOW LEVEL-|  |--DEPTH--|  |-MAX RV-| TVS  MOTION   MSI
  ID   deg/nm     ID  RV   DV  BASE  kft STMREL%  kft    kts     deg/kts

  22  226/ 24  5L A9  17   15  < 2   >10   27       7     38  N  025/  8  2902
";

    // LBB
    const LAT: f64 = 33.654;
    const LON: f64 = -101.814;

    #[test]
    fn reads_the_real_product() {
        let m = parse(REAL, LAT, LON);
        assert_eq!(m.len(), 1, "header rows must not become circulations");
        let c = &m[0];
        assert_eq!(c.id, "22");
        assert_eq!(c.rank, "5L");
        assert_eq!(c.storm_id, "A9", "must tie back to the storm cell");
        assert_eq!(c.max_rv_kt, 38.0);
        assert!(!c.tvs);
        assert_eq!(c.msi, Some(2902));
        assert_eq!(c.motion, Some((25.0, 8.0)));

        // 226 degrees at 24 NM: southwest of the radar.
        assert!(c.lat < LAT, "should be south of the site");
        assert!(c.lon < LON, "should be west of the site");
    }

    #[test]
    fn a_tvs_flag_is_read() {
        // The whole point of #26: this is how the product says a tornado
        // vortex signature was detected on a circulation.
        let txt = "  22  226/ 24  8  A9  30   28  < 1   >12   40      5     72  Y  025/  8  6100\n";
        let m = parse(txt, LAT, LON);
        assert_eq!(m.len(), 1);
        assert!(m[0].tvs);
        assert_eq!(m[0].max_rv_kt, 72.0);
    }

    #[test]
    fn the_header_and_the_date_line_are_not_circulations() {
        // "Avg dir/spd: 023/  3" holds a slash pair and would parse as a
        // position if rows were taken on faith.
        let txt = "\
                        MESOCYCLONE DETECTION ALGORITHM
     RADAR ID: 398     DATE: 08/01/2026   TIME: 03:32:47   Avg dir/spd: 023/  3
 CIRC  AZRAN   SR STM |-LOW LEVEL-|  |--DEPTH--|  |-MAX RV-| TVS  MOTION   MSI
";
        assert!(parse(txt, LAT, LON).is_empty());
    }

    #[test]
    fn an_empty_product_yields_nothing() {
        // On a quiet night MD is a 150-byte shell with no tabular block at
        // all, so this is what the caller sees.
        assert!(parse("", LAT, LON).is_empty());
    }
}
