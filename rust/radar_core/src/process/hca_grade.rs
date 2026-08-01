//! Score our hydrometeor classification against the NWS's.
//!
//! Ours runs on a Level 2 volume, so it sees every elevation cut — about
//! fourteen — and can resolve vertical structure the published product
//! cannot. The NWS's runs on the same radar with KDP and the texture fields
//! we do not have, and publishes only four tilts. Neither is strictly better,
//! which is why ours is kept and this exists: at the four tilts where both
//! have an opinion, how often do they agree, and where they disagree, how?
//!
//! A confusion matrix answers the second question, and that is the useful
//! one. The two gaps documented in [`crate::process::hca`] predict specific
//! confusions: no KDP should show up as heavy rain and hail bleeding into
//! each other, and no texture fields as clutter and biological returns being
//! called weather.

use crate::process::grid3d::Grid3D;
use crate::process::hca::Class;
use crate::sweep::Sweep;

/// Map an NWS hydrometeor class code onto ours.
///
/// The codes are the stops in `ColorTable::hydro_class_default`, and every
/// one has a counterpart here bar "unknown", which is the algorithm declining
/// to answer rather than a category of precipitation.
pub fn class_from_nws(code: f32) -> Option<Class> {
    Some(match code.round() as i32 {
        10 => Class::Biological,
        20 => Class::GroundClutter,
        30 => Class::IceCrystals,
        40 => Class::DrySnow,
        50 => Class::WetSnow,
        60 => Class::LightRain,
        70 => Class::HeavyRain,
        80 => Class::BigDrops,
        90 => Class::Graupel,
        100 => Class::HailRain,
        // 0 is below threshold, 140 is unknown, 120 is range folded.
        _ => return None,
    })
}

/// Counts of what we said against what the NWS said.
#[derive(Default, Clone)]
pub struct Confusion {
    /// `counts[ours][theirs]`, indexed by `Class as usize`.
    pub counts: [[u32; 11]; 11],
    /// Gates the NWS classified that fell outside our volume, or that we left
    /// empty. Tracked separately: a disagreement and a non-answer are
    /// different failures and averaging them together hides both.
    pub ours_empty: u32,
    pub out_of_volume: u32,
}

impl Confusion {
    pub fn compared(&self) -> u32 {
        self.counts.iter().flatten().sum()
    }

    pub fn agreed(&self) -> u32 {
        (0..11).map(|i| self.counts[i][i]).sum()
    }

    pub fn agreement(&self) -> f32 {
        let n = self.compared();
        if n == 0 {
            0.0
        } else {
            self.agreed() as f32 / n as f32
        }
    }

    /// Disagreements, worst first, as (ours, theirs, count).
    pub fn worst(&self, n: usize) -> Vec<(Class, Class, u32)> {
        let mut v = Vec::new();
        for (i, row) in self.counts.iter().enumerate() {
            for (j, &c) in row.iter().enumerate() {
                if i != j && c > 0 {
                    if let (Some(a), Some(b)) = (from_index(i), from_index(j)) {
                        v.push((a, b, c));
                    }
                }
            }
        }
        v.sort_by(|a, b| b.2.cmp(&a.2));
        v.truncate(n);
        v
    }
}

fn from_index(i: usize) -> Option<Class> {
    Class::ALL.into_iter().find(|c| *c as usize == i)
}

/// Compare our gridded classification against one Level 3 HCA sweep.
///
/// For each gate the NWS classified, find where it sits in our volume and see
/// what we said there. Gates are sampled at their own position rather than
/// resampling either field, so neither side is smoothed into agreement.
pub fn grade_sweep(
    ours: &Grid3D,
    theirs: &Sweep,
    into: &mut Confusion,
) {
    let vox = 2.0 * ours.half_extent_m / ours.nxy as f32;
    let dz = ours.top_m / ours.nz as f32;
    let cos_el = (theirs.elevation_deg as f64).to_radians().cos();

    for rad in &theirs.radials {
        let az = (rad.start_az_deg as f64 + rad.delta_az_deg as f64 * 0.5).to_radians();
        let (sin_az, cos_az) = (az.sin(), az.cos());
        for bin in 0..theirs.nbins as usize {
            let Some(raw) = rad.data.get(bin) else {
                continue;
            };
            let crate::level3::BinValue::Value(code) = theirs.decoder.decode(raw) else {
                continue;
            };
            let Some(nws) = class_from_nws(code) else {
                continue;
            };

            let slant = theirs.first_gate_m as f64 + bin as f64 * theirs.gate_size_m as f64;
            let ground = slant * cos_el;
            // Same axes as the gridder: x east, y north.
            let x = ground * sin_az;
            let y = ground * cos_az;
            let h = theirs.beam_height_m(slant);

            let gx = ((x as f32 + ours.half_extent_m) / vox).floor();
            let gy = ((y as f32 + ours.half_extent_m) / vox).floor();
            let gz = (h as f32 / dz).floor();
            if gx < 0.0
                || gy < 0.0
                || gz < 0.0
                || gx >= ours.nxy as f32
                || gy >= ours.nxy as f32
                || gz >= ours.nz as f32
            {
                into.out_of_volume += 1;
                continue;
            }
            let v = ours.at(gx as usize, gy as usize, gz as usize);
            if v == 0 {
                into.ours_empty += 1;
                continue;
            }
            let Some(mine) = from_index(v as usize) else {
                into.ours_empty += 1;
                continue;
            };
            into.counts[mine as usize][nws as usize] += 1;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_nws_codes_map_onto_our_classes() {
        // These are the stops in hydro_class_default, so a change to either
        // side without the other shows up here.
        assert_eq!(class_from_nws(60.0), Some(Class::LightRain));
        assert_eq!(class_from_nws(100.0), Some(Class::HailRain));
        assert_eq!(class_from_nws(20.0), Some(Class::GroundClutter));
        // Not a hydrometeor: the algorithm declining to answer.
        assert_eq!(class_from_nws(140.0), None);
        assert_eq!(class_from_nws(0.0), None);
    }

    #[test]
    fn agreement_and_confusion_are_counted_separately() {
        let mut c = Confusion::default();
        c.counts[Class::HeavyRain as usize][Class::HeavyRain as usize] = 80;
        c.counts[Class::HeavyRain as usize][Class::HailRain as usize] = 15;
        c.counts[Class::GroundClutter as usize][Class::LightRain as usize] = 5;
        assert_eq!(c.compared(), 100);
        assert_eq!(c.agreed(), 80);
        assert!((c.agreement() - 0.8).abs() < 1e-6);

        let worst = c.worst(2);
        assert_eq!(worst[0], (Class::HeavyRain, Class::HailRain, 15));
        assert_eq!(worst[1], (Class::GroundClutter, Class::LightRain, 5));
    }

    #[test]
    fn an_empty_comparison_does_not_claim_perfect_agreement() {
        // Zero of zero is not 100%: reporting it as such would make a broken
        // run look like a flawless one.
        let c = Confusion::default();
        assert_eq!(c.compared(), 0);
        assert_eq!(c.agreement(), 0.0);
    }
}
