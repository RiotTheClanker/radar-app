//! NOAA's storm tracks, read out of the Level 3 STI product (code 58).
//!
//! The NWS runs SCIT operationally across seven reflectivity thresholds with
//! full vertical integration, and publishes the result. That is a better
//! answer than anything derivable from a single 2D threshold on device, and
//! it comes with a forecast error estimate we could not produce at all.
//!
//! The numbers live in the Tabular Alphanumeric Block as fixed-column text:
//!
//! ```text
//!  STORM    CURRENT POSITION              FORECAST POSITIONS               ERROR
//!   ID     AZRAN     MOVEMENT    15 MIN    30 MIN    45 MIN    60 MIN    FCST/MEAN
//!         (DEG/NM)  (DEG/KTS)   (DEG/NM)  (DEG/NM)  (DEG/NM)  (DEG/NM)     (NM)
//!
//!   O8     188/ 73   315/ 22     185/ 77   182/ 80   179/ 84   176/ 88    0.5/ 0.5
//! ```
//!
//! Parsing is by `deg/range` pair rather than by column, because the columns
//! shift as fields widen and a cell with no movement solution prints `NEW`
//! where the numbers would be.

/// A storm cell as the NWS sees it.
#[derive(Clone, Debug, PartialEq)]
pub struct StiCell {
    /// Two-character NWS cell id, e.g. "O8". Stable between volumes, which
    /// is what makes it worth surfacing.
    pub id: String,
    pub lat: f64,
    pub lon: f64,
    /// None when the cell has no movement solution yet.
    pub movement: Option<StiMovement>,
    pub forecast: Vec<StiForecast>,
    /// Forecast and mean track error in nautical miles, when given.
    pub error_fcst_nm: Option<f32>,
    pub error_mean_nm: Option<f32>,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct StiMovement {
    /// Degrees true the storm is coming *from*, as the product quotes it.
    ///
    /// This is the meteorological convention, the same one used for wind, and
    /// it is the opposite of what you draw an arrow with. The forecast
    /// positions in the same row are what settles it: a cell quoted at 315
    /// steps south and east across its four forecasts, so 315 is the source
    /// direction and the storm is heading 135.
    pub from_deg: f32,
    pub speed_kt: f32,
}

impl StiMovement {
    /// Degrees true the storm is heading toward — what an arrow points along.
    pub fn heading_deg(self) -> f32 {
        (self.from_deg + 180.0).rem_euclid(360.0)
    }
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct StiForecast {
    pub minutes: f32,
    pub lat: f64,
    pub lon: f64,
}

const NM_PER_DEG_LAT: f64 = 60.0;

/// Azimuth (degrees true) and range (nautical miles) from the radar, to
/// lat/lon. Flat-earth on a local tangent: within 250 NM the error is far
/// below the quarter-degree azimuth the product is quantised to.
fn az_ran_to_latlon(site_lat: f64, site_lon: f64, az_deg: f64, ran_nm: f64) -> (f64, f64) {
    let a = az_deg.to_radians();
    let dlat = ran_nm * a.cos() / NM_PER_DEG_LAT;
    let lat = site_lat + dlat;
    let coslat = (0.5 * (site_lat + lat)).to_radians().cos().abs().max(1e-6);
    let dlon = ran_nm * a.sin() / (NM_PER_DEG_LAT * coslat);
    (lat, site_lon + dlon)
}

/// The product right-aligns each half of a pair, so `188/ 73` arrives with a
/// space inside it and splitting the line on whitespace would tear it in two.
/// Drop spaces that directly follow a slash, and the fields line up.
fn squash(line: &str) -> String {
    let mut out = String::with_capacity(line.len());
    let mut after_slash = false;
    for c in line.chars() {
        if after_slash && c == ' ' {
            continue;
        }
        after_slash = c == '/';
        out.push(c);
    }
    out
}

/// Split a `123/ 45` pair. Returns None for `NEW`, `///` and anything else
/// that is not two numbers.
fn pair(s: &str) -> Option<(f32, f32)> {
    let (a, b) = s.split_once('/')?;
    Some((a.trim().parse().ok()?, b.trim().parse().ok()?))
}

/// Read the storm table out of an STI tabular block.
pub fn parse(tabular: &str, site_lat: f64, site_lon: f64) -> Vec<StiCell> {
    let mut out = Vec::new();
    for line in tabular.lines() {
        let line = squash(line);
        let f: Vec<&str> = line.split_whitespace().collect();
        // A data row is an id then at least a position and a movement column.
        // Header rows fail the pair test on the very first field, so there is
        // no need to hunt for where the table starts.
        if f.len() < 3 {
            continue;
        }
        let id = f[0];
        if id.len() > 3 || id.chars().any(|c| !c.is_ascii_alphanumeric()) {
            continue;
        }
        let Some((az, ran)) = pair(f[1]) else {
            continue;
        };
        // Guard against a stray line that happens to hold a slash pair.
        if !(0.0..=360.0).contains(&az) || !(0.0..=500.0).contains(&ran) {
            continue;
        }
        let (lat, lon) = az_ran_to_latlon(site_lat, site_lon, az as f64, ran as f64);

        let movement = pair(f[2]).map(|(b, s)| StiMovement {
            from_deg: b,
            speed_kt: s,
        });

        // Forecast columns follow, in 15-minute steps. A cell without a
        // movement solution prints no forecast, and a young cell may give
        // fewer than four.
        let mut forecast = Vec::new();
        for (n, fld) in f.iter().skip(3).take(4).enumerate() {
            if let Some((faz, fran)) = pair(fld) {
                if !(0.0..=360.0).contains(&faz) || !(0.0..=500.0).contains(&fran) {
                    continue;
                }
                let (flat, flon) =
                    az_ran_to_latlon(site_lat, site_lon, faz as f64, fran as f64);
                forecast.push(StiForecast {
                    minutes: (n as f32 + 1.0) * 15.0,
                    lat: flat,
                    lon: flon,
                });
            }
        }

        // The error column is the last field, and is a decimal pair rather
        // than a bearing/range one.
        let (error_fcst_nm, error_mean_nm) = f
            .last()
            .and_then(|s| pair(s))
            .map_or((None, None), |(a, b)| (Some(a), Some(b)));

        out.push(StiCell {
            id: id.to_string(),
            lat,
            lon,
            movement,
            forecast,
            error_fcst_nm,
            error_mean_nm,
        });
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    // Lifted verbatim from TLX_NST_2026_08_01_02_27_10.
    const REAL: &str = "\
                            STORM POSITION/FORECAST
     RADAR ID   1  DATE/TIME 08:01:26/02:27:10   NUMBER OF STORM CELLS   1

                   AVG SPEED 22 KTS    AVG DIRECTION 315 DEG

 STORM    CURRENT POSITION              FORECAST POSITIONS               ERROR
  ID     AZRAN     MOVEMENT    15 MIN    30 MIN    45 MIN    60 MIN    FCST/MEAN
        (DEG/NM)  (DEG/KTS)   (DEG/NM)  (DEG/NM)  (DEG/NM)  (DEG/NM)     (NM)

  O8     188/ 73   315/ 22     185/ 77   182/ 80   179/ 84   176/ 88    0.5/ 0.5
";

    // TLX
    const LAT: f64 = 35.333;
    const LON: f64 = -97.278;

    #[test]
    fn reads_the_real_product() {
        let cells = parse(REAL, LAT, LON);
        assert_eq!(cells.len(), 1, "header rows must not become cells");
        let c = &cells[0];
        assert_eq!(c.id, "O8");

        // 188 degrees at 73 NM: nearly due south, so well below the radar.
        assert!(c.lat < LAT - 1.0, "lat {} should be south of the site", c.lat);
        assert!((c.lon - LON).abs() < 0.3, "188 deg is close to due south");

        let m = c.movement.unwrap();
        assert_eq!(m.from_deg, 315.0);
        assert_eq!(m.speed_kt, 22.0);
        // From the northwest means heading southeast.
        assert_eq!(m.heading_deg(), 135.0);

        assert_eq!(c.forecast.len(), 4);
        assert_eq!(c.forecast[0].minutes, 15.0);
        assert_eq!(c.forecast[3].minutes, 60.0);
        // Coming from the northwest, so each step lands south and east of
        // the last. This is the check that caught the convention.
        for w in c.forecast.windows(2) {
            assert!(w[1].lat < w[0].lat, "should track south");
            assert!(w[1].lon > w[0].lon, "should track east");
        }
        // And the whole track agrees with the quoted heading.
        let first = &c.forecast[0];
        let last = &c.forecast[3];
        assert!(last.lat < first.lat && last.lon > first.lon);
        assert_eq!(c.error_fcst_nm, Some(0.5));
    }

    #[test]
    fn a_cell_with_no_solution_yet_has_no_movement() {
        // The product prints NEW where the movement pair would be.
        let txt = "  R3     201/ 45   NEW\n";
        let cells = parse(txt, LAT, LON);
        assert_eq!(cells.len(), 1);
        assert_eq!(cells[0].movement, None);
        assert!(cells[0].forecast.is_empty());
    }

    #[test]
    fn adaptation_data_is_not_mistaken_for_storms() {
        // The page that follows the table is full of numbers and would
        // happily parse as cells if rows were taken on faith.
        let txt = "\
              STORM CELL TRACKING/FORECAST ADAPTATION DATA

    327   (DEG) DEFAULT (DIRECTION)      2.5   (M/S) THRESH (MINIMUM SPEED)
   20.4   (KTS) DEFAULT (SPEED)           20    (KM) ALLOWABLE ERROR
     20   (MIN) TIME (MAXIMUM)            15   (MIN) FORECAST INTERVAL
";
        assert!(parse(txt, LAT, LON).is_empty());
    }

    #[test]
    fn nonsense_bearings_are_rejected() {
        // A slash pair that is not an az/ran, e.g. the date/time line.
        let txt = "  XX     999/ 73   315/ 22\n";
        assert!(parse(txt, LAT, LON).is_empty());
    }
}
