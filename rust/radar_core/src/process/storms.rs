//! Storm cell identification and tracking.
//!
//! The nowcast next door advects the whole echo field by one displacement
//! vector, which is right for "where will this rain be". It cannot answer
//! "which storm is that, and where is *it* going", because it has no notion
//! of a storm as an object. This does.
//!
//! Shaped after SCIT (Johnson et al., 1998): threshold the reflectivity
//! field, take connected regions above it as candidate cells, reduce each to
//! a reflectivity-weighted centroid, then match centroids between consecutive
//! volumes to get motion.
//!
//! Two departures from the operational algorithm, both deliberate:
//!
//!   * SCIT segments at seven reflectivity thresholds and builds vertically
//!     integrated components, which lets it split a line into distinct cores.
//!     This works one threshold on a 2D field, so a squall line comes out as
//!     one long cell rather than several. Better suited to discrete cells
//!     than to linear convection.
//!   * SCIT's tracker uses cost minimisation over all pairings with a
//!     first-guess motion. This matches greedily by nearest centroid within a
//!     speed gate, which is equivalent when cells are well separated and can
//!     mispair when two cells pass close together.

/// A region of high reflectivity in one volume.
#[derive(Clone, Debug, PartialEq)]
pub struct Cell {
    pub lat: f64,
    pub lon: f64,
    /// Peak reflectivity anywhere in the cell.
    pub max_dbz: f32,
    pub area_km2: f32,
}

/// A cell that has been matched to one in the previous volume, so it has
/// motion. `speed_ms`/`bearing_deg` are zero when `tracked` is false — a cell
/// seen for the first time has no history to derive motion from, and
/// inventing one would put a confident arrow on a storm we know nothing
/// about.
#[derive(Clone, Debug, PartialEq)]
pub struct TrackedCell {
    pub cell: Cell,
    pub tracked: bool,
    pub speed_ms: f32,
    /// Direction of travel, degrees clockwise from north (the way it is
    /// heading, not the way it came from).
    pub bearing_deg: f32,
}

const KM_PER_DEG_LAT: f64 = 111.32;

fn km_per_deg_lon(lat: f64) -> f64 {
    KM_PER_DEG_LAT * lat.to_radians().cos().abs().max(1e-6)
}

/// Ground distance in km between two points, flat-earth on a local tangent.
/// At storm-tracking scales (tens of km over minutes) the great-circle
/// correction is far below the centroid noise.
fn dist_km(alat: f64, alon: f64, blat: f64, blon: f64) -> f64 {
    let mlat = 0.5 * (alat + blat);
    let dy = (blat - alat) * KM_PER_DEG_LAT;
    let dx = (blon - alon) * km_per_deg_lon(mlat);
    (dx * dx + dy * dy).sqrt()
}

/// Find storm cells in one rasterised reflectivity field.
///
/// `raw` is row-major, `width` by `height`, spanning the given bounds with
/// north at row 0. `decode` turns a raw byte into dBZ, or `None` where there
/// is no data.
///
/// Regions smaller than `min_area_km2` are dropped: at long range a couple of
/// bright gates is speckle, not a storm, and letting those through fills the
/// tracker with cells that vanish next scan.
pub fn find_cells(
    raw: &[u8],
    width: usize,
    height: usize,
    north: f64,
    south: f64,
    east: f64,
    west: f64,
    decode: impl Fn(u8) -> Option<f32>,
    threshold_dbz: f32,
    min_area_km2: f32,
) -> Vec<Cell> {
    if width == 0 || height == 0 || raw.len() < width * height {
        return Vec::new();
    }
    let dlat = (north - south) / height as f64;
    let dlon = (east - west) / width as f64;
    let lat_of = |y: usize| north - (y as f64 + 0.5) * dlat;
    let lon_of = |x: usize| west + (x as f64 + 0.5) * dlon;

    // Decode once; the flood fill visits each pixel repeatedly otherwise.
    let mut dbz = vec![f32::NAN; width * height];
    for (i, &r) in raw.iter().take(width * height).enumerate() {
        if let Some(v) = decode(r) {
            dbz[i] = v;
        }
    }

    let mut seen = vec![false; width * height];
    let mut cells = Vec::new();
    let mut stack: Vec<usize> = Vec::new();

    for start in 0..width * height {
        if seen[start] || !(dbz[start] >= threshold_dbz) {
            continue;
        }
        // Flood fill this region, 8-connected so diagonal touches count as
        // one storm rather than two.
        seen[start] = true;
        stack.push(start);
        let (mut wsum, mut wlat, mut wlon) = (0.0f64, 0.0f64, 0.0f64);
        let mut peak = f32::MIN;
        let mut area = 0.0f64;
        while let Some(i) = stack.pop() {
            let (x, y) = (i % width, i / width);
            let v = dbz[i];
            peak = peak.max(v);
            // Weight by dBZ above the threshold, so the centroid sits on the
            // core rather than in the middle of the region's outline.
            let wt = (v - threshold_dbz).max(0.1) as f64;
            wsum += wt;
            wlat += wt * lat_of(y);
            wlon += wt * lon_of(x);
            area += dlat * KM_PER_DEG_LAT * dlon * km_per_deg_lon(lat_of(y));
            for dy in -1i32..=1 {
                for dx in -1i32..=1 {
                    let (nx, ny) = (x as i32 + dx, y as i32 + dy);
                    if nx < 0 || ny < 0 || nx >= width as i32 || ny >= height as i32 {
                        continue;
                    }
                    let j = ny as usize * width + nx as usize;
                    if !seen[j] && dbz[j] >= threshold_dbz {
                        seen[j] = true;
                        stack.push(j);
                    }
                }
            }
        }
        if area as f32 >= min_area_km2 && wsum > 0.0 {
            cells.push(Cell {
                lat: wlat / wsum,
                lon: wlon / wsum,
                max_dbz: peak,
                area_km2: area as f32,
            });
        }
    }
    // Strongest first: the list is used to label a map, and the storm that
    // matters should be the one that survives crowding.
    cells.sort_by(|a, b| b.max_dbz.total_cmp(&a.max_dbz));
    cells
}

/// Match cells between two volumes and derive motion.
///
/// `dt_s` is the time between them. `max_speed_ms` gates the search: nothing
/// on radar moves at 60 m/s, and without a gate a cell that dissipated will
/// be paired with an unrelated one on the far side of the county.
pub fn track(
    prev: &[Cell],
    now: &[Cell],
    dt_s: f32,
    max_speed_ms: f32,
) -> Vec<TrackedCell> {
    let max_km = (max_speed_ms * dt_s / 1000.0).max(0.0) as f64;
    let mut taken = vec![false; prev.len()];
    let mut out = Vec::with_capacity(now.len());

    for c in now {
        let mut best: Option<(usize, f64)> = None;
        for (i, p) in prev.iter().enumerate() {
            if taken[i] {
                continue;
            }
            let d = dist_km(p.lat, p.lon, c.lat, c.lon);
            if d > max_km {
                continue;
            }
            if best.is_none_or(|(_, bd)| d < bd) {
                best = Some((i, d));
            }
        }
        match best {
            Some((i, _)) if dt_s > 0.0 => {
                taken[i] = true;
                let p = &prev[i];
                let mlat = 0.5 * (p.lat + c.lat);
                let dy = (c.lat - p.lat) * KM_PER_DEG_LAT;
                let dx = (c.lon - p.lon) * km_per_deg_lon(mlat);
                let d_km = (dx * dx + dy * dy).sqrt();
                let mut brg = dx.atan2(dy).to_degrees();
                if brg < 0.0 {
                    brg += 360.0;
                }
                out.push(TrackedCell {
                    cell: c.clone(),
                    tracked: true,
                    speed_ms: (d_km * 1000.0 / dt_s as f64) as f32,
                    bearing_deg: brg as f32,
                });
            }
            _ => out.push(TrackedCell {
                cell: c.clone(),
                tracked: false,
                speed_ms: 0.0,
                bearing_deg: 0.0,
            }),
        }
    }
    out
}

/// Where a tracked cell will be after `minutes`, if it keeps going as it is.
///
/// Returns `None` for an untracked cell rather than its current position: a
/// projection nobody can make is not the same as one that says "here".
pub fn project(c: &TrackedCell, minutes: f32) -> Option<(f64, f64)> {
    if !c.tracked {
        return None;
    }
    let d_km = c.speed_ms as f64 * minutes as f64 * 60.0 / 1000.0;
    let brg = (c.bearing_deg as f64).to_radians();
    let lat = c.cell.lat + d_km * brg.cos() / KM_PER_DEG_LAT;
    let lon = c.cell.lon + d_km * brg.sin() / km_per_deg_lon(0.5 * (c.cell.lat + lat));
    Some((lat, lon))
}

#[cfg(test)]
mod tests {
    use super::*;

    const N: f64 = 36.0;
    const S: f64 = 35.0;
    const E: f64 = -97.0;
    const W: f64 = -98.0;
    const WD: usize = 100;
    const HT: usize = 100;

    /// Raw byte 0 is no-data; otherwise dBZ = raw - 100, so 150 is 50 dBZ.
    fn dec(r: u8) -> Option<f32> {
        if r == 0 {
            None
        } else {
            Some(r as f32 - 100.0)
        }
    }

    fn blob(raw: &mut [u8], cx: usize, cy: usize, r: i32, val: u8) {
        for dy in -r..=r {
            for dx in -r..=r {
                if dx * dx + dy * dy > r * r {
                    continue;
                }
                let (x, y) = (cx as i32 + dx, cy as i32 + dy);
                if x >= 0 && y >= 0 && (x as usize) < WD && (y as usize) < HT {
                    raw[y as usize * WD + x as usize] = val;
                }
            }
        }
    }

    fn cells_of(raw: &[u8], min_area: f32) -> Vec<Cell> {
        find_cells(raw, WD, HT, N, S, E, W, dec, 40.0, min_area)
    }

    #[test]
    fn separate_storms_come_out_separate() {
        let mut raw = vec![0u8; WD * HT];
        blob(&mut raw, 25, 25, 6, 155); // 55 dBZ
        blob(&mut raw, 75, 70, 5, 145); // 45 dBZ
        let cells = cells_of(&raw, 1.0);
        assert_eq!(cells.len(), 2);
        // Sorted by intensity, so the 55 dBZ core leads.
        assert_eq!(cells[0].max_dbz, 55.0);
        assert_eq!(cells[1].max_dbz, 45.0);
        // Centroid lands on the blob it came from, within a pixel or so.
        assert!((cells[0].lat - (N - 25.5 * 0.01)).abs() < 0.02);
        assert!((cells[0].lon - (W + 25.5 * 0.01)).abs() < 0.02);
    }

    #[test]
    fn touching_blobs_are_one_storm() {
        // Diagonally adjacent: 8-connectivity has to join them, or a single
        // storm gets counted twice and tracked as two.
        let mut raw = vec![0u8; WD * HT];
        blob(&mut raw, 40, 40, 4, 150);
        blob(&mut raw, 44, 44, 4, 150);
        assert_eq!(cells_of(&raw, 1.0).len(), 1);
    }

    #[test]
    fn speckle_is_dropped() {
        let mut raw = vec![0u8; WD * HT];
        blob(&mut raw, 50, 50, 8, 150); // a real storm
        raw[10 * WD + 10] = 150; // one hot pixel
        raw[80 * WD + 90] = 150; // another
        let cells = cells_of(&raw, 20.0);
        assert_eq!(cells.len(), 1, "single pixels are not storms");
    }

    #[test]
    fn below_threshold_is_not_a_cell() {
        let mut raw = vec![0u8; WD * HT];
        blob(&mut raw, 50, 50, 8, 135); // 35 dBZ, under the 40 threshold
        assert!(cells_of(&raw, 1.0).is_empty());
    }

    #[test]
    fn motion_comes_out_of_the_displacement() {
        // Same storm, moved due east by 10 pixels in 300 s. At this latitude
        // 0.01 deg lon is about 0.9 km, so 10 px is ~9 km in 5 minutes.
        let mut a = vec![0u8; WD * HT];
        blob(&mut a, 40, 50, 6, 150);
        let mut b = vec![0u8; WD * HT];
        blob(&mut b, 50, 50, 6, 150);

        let t = track(&cells_of(&a, 1.0), &cells_of(&b, 1.0), 300.0, 60.0);
        assert_eq!(t.len(), 1);
        assert!(t[0].tracked);
        // Due east is a bearing of 90.
        assert!(
            (t[0].bearing_deg - 90.0).abs() < 2.0,
            "bearing {} should be east",
            t[0].bearing_deg
        );
        let expect = 10.0 * 0.01 * km_per_deg_lon(35.5) * 1000.0 / 300.0;
        assert!(
            (t[0].speed_ms - expect as f32).abs() < 1.0,
            "speed {} should be about {expect}",
            t[0].speed_ms
        );
    }

    #[test]
    fn a_new_storm_gets_no_invented_motion() {
        let a: Vec<Cell> = Vec::new();
        let mut b = vec![0u8; WD * HT];
        blob(&mut b, 50, 50, 6, 150);
        let t = track(&a, &cells_of(&b, 1.0), 300.0, 60.0);
        assert_eq!(t.len(), 1);
        assert!(!t[0].tracked);
        assert_eq!(t[0].speed_ms, 0.0);
        assert_eq!(project(&t[0], 30.0), None);
    }

    #[test]
    fn the_speed_gate_refuses_impossible_pairings() {
        // Storm at one corner dies; an unrelated one appears at the other.
        // Pairing them would imply a wildly impossible speed.
        let mut a = vec![0u8; WD * HT];
        blob(&mut a, 10, 10, 5, 150);
        let mut b = vec![0u8; WD * HT];
        blob(&mut b, 90, 90, 5, 150);
        let t = track(&cells_of(&a, 1.0), &cells_of(&b, 1.0), 300.0, 30.0);
        assert!(!t[0].tracked, "should not pair across the whole domain");
    }

    #[test]
    fn projection_runs_along_the_track() {
        let c = TrackedCell {
            cell: Cell {
                lat: 35.5,
                lon: -97.5,
                max_dbz: 55.0,
                area_km2: 50.0,
            },
            tracked: true,
            speed_ms: 20.0,
            bearing_deg: 90.0, // due east
        };
        let (lat, lon) = project(&c, 30.0).unwrap();
        // 20 m/s for 30 min is 36 km, all of it eastward.
        assert!((lat - 35.5).abs() < 1e-6, "due east should not change lat");
        let moved = dist_km(35.5, -97.5, lat, lon);
        assert!((moved - 36.0).abs() < 0.5, "moved {moved} km, expected 36");
        assert!(lon > -97.5, "east is increasing longitude");
    }
}
