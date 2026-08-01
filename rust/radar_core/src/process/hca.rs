//! Hydrometeor classification from the dual-polarisation moments.
//!
//! A fuzzy-logic classifier in the shape of the operational NEXRAD HCA
//! (Park et al., 2009), reduced to what this app already decodes: horizontal
//! reflectivity, differential reflectivity, and correlation coefficient.
//!
//! Each class carries a trapezoidal membership function per variable. A voxel
//! scores against every class, the scores are weighted and summed, and the
//! best one wins. That is deliberately soft: the boundaries between, say,
//! graupel and a rain/hail mix are not sharp in nature either, and a scheme
//! of hard thresholds would flip between classes on noise.
//!
//! What is missing relative to the operational algorithm, and why it matters:
//!
//!   * **KDP** — specific differential phase, the derivative of PHIDP along
//!     the ray. It is the strongest discriminator for heavy rain (it responds
//!     to liquid water content and is immune to attenuation and calibration).
//!     Without it, heavy rain and rain/hail lean harder on Z and ZDR than an
//!     operational classifier would.
//!   * **Texture fields** — SD(Z) and SD(PHIDP), the local standard
//!     deviations, which is how the real algorithm separates ground clutter
//!     and biological scatterers from weather. Correlation coefficient plus a
//!     height band above ground stands in for them, which turns out to be
//!     enough for insects and not enough for clutter: measured against the
//!     NWS, biological returns match 86% of the time and clutter 11%.
//!
//! Scored against the NWS's own classification at the four tilts it
//! publishes (see [`crate::process::hca_grade`]): 78% agreement on a
//! clear-air night volume at LBB, 91% on a held-out TLX volume. The held-out
//! score being the higher of the two is the evidence that the membership
//! functions are not merely fitted to one night.
//!
//! So: useful for reading storm structure, not a substitute for the
//! operational product.

use crate::process::grid3d::Grid3D;

/// Classes, in palette-index order. `None` is the empty voxel, so the value
/// stored in a grid is `class as u8`, and 0 keeps its usual "nothing here"
/// meaning.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
#[repr(u8)]
pub enum Class {
    None = 0,
    GroundClutter = 1,
    Biological = 2,
    IceCrystals = 3,
    DrySnow = 4,
    WetSnow = 5,
    Graupel = 6,
    LightRain = 7,
    HeavyRain = 8,
    BigDrops = 9,
    HailRain = 10,
}

impl Class {
    pub const ALL: [Class; 10] = [
        Class::GroundClutter,
        Class::Biological,
        Class::IceCrystals,
        Class::DrySnow,
        Class::WetSnow,
        Class::Graupel,
        Class::LightRain,
        Class::HeavyRain,
        Class::BigDrops,
        Class::HailRain,
    ];

    pub fn label(self) -> &'static str {
        match self {
            Class::None => "",
            Class::GroundClutter => "Ground clutter",
            Class::Biological => "Biological",
            Class::IceCrystals => "Ice crystals",
            Class::DrySnow => "Dry snow",
            Class::WetSnow => "Wet snow",
            Class::Graupel => "Graupel",
            Class::LightRain => "Rain",
            Class::HeavyRain => "Heavy rain",
            Class::BigDrops => "Big drops",
            Class::HailRain => "Hail / rain",
        }
    }

    /// RGB for the 3D palette and the legend.
    pub fn color(self) -> [u8; 3] {
        match self {
            Class::None => [0, 0, 0],
            Class::GroundClutter => [120, 120, 120],
            Class::Biological => [150, 110, 180],
            Class::IceCrystals => [180, 230, 255],
            Class::DrySnow => [110, 190, 255],
            Class::WetSnow => [70, 120, 220],
            Class::Graupel => [255, 190, 90],
            Class::LightRain => [60, 200, 90],
            Class::HeavyRain => [20, 130, 50],
            Class::BigDrops => [230, 230, 70],
            Class::HailRain => [230, 60, 60],
        }
    }
}

/// Trapezoid: 0 below `a`, rising to 1 at `b`, 1 until `c`, falling to 0 at
/// `d`. Degenerate edges (a == b) give a step, which is what the open-ended
/// classes want.
fn trap(x: f32, a: f32, b: f32, c: f32, d: f32) -> f32 {
    if x <= a || x >= d {
        0.0
    } else if x < b {
        (x - a) / (b - a).max(1e-6)
    } else if x <= c {
        1.0
    } else {
        (d - x) / (d - c).max(1e-6)
    }
}

/// Membership limits for one class: (Z, ZDR, RHO) trapezoids plus the height
/// band relative to the melting level, in metres (negative is below).
struct Mbf {
    z: [f32; 4],
    zdr: [f32; 4],
    rho: [f32; 4],
    /// Height band relative to the melting level, metres, negative below.
    dh: [f32; 4],
    /// Height band above ground instead, for the classes that are not
    /// hydrometeors. Clutter and insects care where the ground is, not where
    /// the freezing level is: tying them to the melting level put biological
    /// returns out of reach on any night with a high freezing level, and the
    /// classifier called two thirds of a clear-air volume rain.
    agl: Option<[f32; 4]>,
}

/// Z carries the most information about amount, ZDR about shape, RHO about
/// how mixed the scatterers are. Height is a gate rather than evidence, so it
/// multiplies rather than joining the weighted sum.
const W_Z: f32 = 1.0;
const W_ZDR: f32 = 0.8;
const W_RHO: f32 = 1.4;

fn mbf(c: Class) -> Mbf {
    match c {
        // Low RHO, no height, near the ground. Real clutter also has a rough
        // PHIDP texture, which we cannot see.
        Class::GroundClutter => Mbf {
            // Clutter is a strong return from a stationary hard target: high
            // Z, ZDR near zero or negative, and the worst correlation
            // coefficient of anything on the scope. The loose bands this had
            // before overlapped biological returns almost entirely, and the
            // classifier called 46000 insect gates clutter.
            z: [20.0, 30.0, 70.0, 80.0],
            zdr: [-6.0, -4.0, 1.5, 3.0],
            rho: [0.20, 0.35, 0.75, 0.85],
            dh: [-9000.0, -9000.0, 9000.0, 9000.0],
            agl: Some([0.0, 0.0, 300.0, 900.0]),
        },
        // Birds and insects: weak, very high ZDR, poor RHO.
        Class::Biological => Mbf {
            z: [0.0, 5.0, 25.0, 35.0],
            zdr: [1.0, 3.0, 8.0, 12.0],
            rho: [0.30, 0.50, 0.83, 0.90],
            dh: [-9000.0, -9000.0, 9000.0, 9000.0],
            // Insects and birds fill the boundary layer and thin out above
            // it; nothing about that follows the freezing level.
            agl: Some([0.0, 0.0, 2500.0, 4500.0]),
        },
        Class::IceCrystals => Mbf {
            z: [-10.0, -5.0, 20.0, 28.0],
            zdr: [0.3, 0.8, 3.5, 5.0],
            rho: [0.95, 0.98, 1.0, 1.0],
            
            dh: [200.0, 800.0, 9000.0, 9000.0],
            agl: None,
        },
        Class::DrySnow => Mbf {
            z: [-5.0, 5.0, 30.0, 38.0],
            zdr: [-0.5, -0.1, 0.6, 1.2],
            rho: [0.95, 0.97, 1.0, 1.0],
            
            dh: [200.0, 700.0, 9000.0, 9000.0],
            agl: None,
        },
        // The bright band: melting aggregates look big and wet, so ZDR jumps
        // and RHO dips. Tightly tied to the melting level.
        Class::WetSnow => Mbf {
            z: [20.0, 27.0, 45.0, 52.0],
            zdr: [0.5, 1.0, 3.0, 4.5],
            rho: [0.80, 0.86, 0.95, 0.975],
            
            dh: [-900.0, -400.0, 400.0, 900.0],
            agl: None,
        },
        // Rimed ice: strong return but nearly spherical, so ZDR near zero.
        Class::Graupel => Mbf {
            z: [25.0, 33.0, 52.0, 58.0],
            zdr: [-0.5, -0.1, 1.0, 1.8],
            rho: [0.94, 0.97, 1.0, 1.0],
            
            dh: [-2500.0, -1000.0, 5000.0, 8000.0],
            agl: None,
        },
        Class::LightRain => Mbf {
            z: [5.0, 12.0, 40.0, 47.0],
            zdr: [0.1, 0.3, 1.8, 2.8],
            rho: [0.95, 0.97, 1.0, 1.0],
            
            dh: [-9000.0, -9000.0, -300.0, 300.0],
            agl: None,
        },
        Class::HeavyRain => Mbf {
            z: [40.0, 45.0, 55.0, 62.0],
            zdr: [0.5, 1.0, 3.0, 4.5],
            rho: [0.93, 0.96, 1.0, 1.0],
            
            dh: [-9000.0, -9000.0, -300.0, 300.0],
            agl: None,
        },
        // Large oblate drops: modest Z for a very large ZDR.
        Class::BigDrops => Mbf {
            z: [18.0, 25.0, 45.0, 52.0],
            zdr: [2.2, 3.0, 5.5, 7.0],
            rho: [0.92, 0.95, 1.0, 1.0],
            
            dh: [-9000.0, -9000.0, -300.0, 300.0],
            agl: None,
        },
        // Hail tumbles, so it has no preferred orientation: ZDR collapses
        // toward zero while Z stays very high. Mixed phase drops RHO.
        Class::HailRain => Mbf {
            z: [48.0, 55.0, 75.0, 80.0],
            zdr: [-1.5, -0.5, 1.2, 2.5],
            rho: [0.85, 0.90, 0.97, 1.0],
            
            dh: [-9000.0, -9000.0, 2000.0, 4500.0],
            agl: None,
        },
        Class::None => Mbf {
            z: [0.0; 4],
            zdr: [0.0; 4],
            rho: [0.0; 4],
            dh: [0.0; 4],
            agl: None,
        },
    }
}

/// Classify one voxel.
///
/// `dh_m` is height above the melting level; `h_m` is height above the radar.
/// Most classes gate on the first, clutter and biological on the second.
/// Returns [`Class::None`]
/// when nothing scores meaningfully, which keeps voxels of noise out of the
/// render rather than forcing them into the nearest class.
pub fn classify(z_dbz: f32, zdr_db: f32, rho: f32, dh_m: f32, h_m: f32) -> Class {
    let mut best = Class::None;
    let mut best_score = 0.18; // floor: below this, call it unclassified
    for c in Class::ALL {
        let m = mbf(c);
        let gate = match m.agl {
            Some(a) => trap(h_m, a[0], a[1], a[2], a[3]),
            None => trap(dh_m, m.dh[0], m.dh[1], m.dh[2], m.dh[3]),
        };
        if gate <= 0.0 {
            continue;
        }
        let s = (W_Z * trap(z_dbz, m.z[0], m.z[1], m.z[2], m.z[3])
            + W_ZDR * trap(zdr_db, m.zdr[0], m.zdr[1], m.zdr[2], m.zdr[3])
            + W_RHO * trap(rho, m.rho[0], m.rho[1], m.rho[2], m.rho[3]))
            / (W_Z + W_ZDR + W_RHO)
            * gate;
        if s > best_score {
            best_score = s;
            best = c;
        }
    }
    best
}

/// Fallback melting level when the volume shows no bright band, in metres.
/// Roughly a warm-season mid-latitude value; wrong in winter, but a wrong
/// melting level only shifts the ice/liquid boundary, it does not invent
/// echoes.
pub const DEFAULT_MELTING_LEVEL_M: f32 = 3200.0;

/// The melting level is never this low in any situation this classifier is
/// useful for, and below it the correlation-coefficient dip is far more
/// likely to be insects than melting snow.
pub const MIN_MELTING_LEVEL_M: f32 = 1000.0;

/// Find the melting level from the volume itself.
///
/// Melting aggregates are wet, large and irregular, so the layer shows up as
/// a dip in correlation coefficient. For each height we take the mean RHO
/// over voxels with enough reflectivity to be weather, and look for the dip.
///
/// Two conditions keep it from finding a dip that is not a bright band, both
/// learned from real data rather than reasoned out. Overnight the boundary
/// layer fills with insects and birds, whose correlation coefficient is far
/// worse than any melting snow, and a plain minimum locks onto them: on a
/// LBB volume at 3am local this returned 200 m, put the melting level at the
/// ground, and made the classifier call the entire volume ice.
///
///   * The candidate must be above [`MIN_MELTING_LEVEL_M`]. Biological
///     returns hug the ground; a real melting layer does not.
///   * It must be a genuine local minimum, cleaner above *and* below. A bug
///     layer sits at the bottom of a profile that only improves with height,
///     so it never satisfies this.
///
/// Returns [`DEFAULT_MELTING_LEVEL_M`] when nothing convincing is found,
/// which is the honest answer for a volume of dry snow, of pure warm rain, or
/// of insects.
pub fn detect_melting_level(
    z: &Grid3D,
    rho: &Grid3D,
    dec_z: impl Fn(u8) -> f32,
    dec_rho: impl Fn(u8) -> f32,
) -> f32 {
    let dz = z.top_m / z.nz as f32;
    let per = z.nxy * z.nxy;

    // Mean RHO per level, over voxels bright enough to be weather.
    let mut prof: Vec<Option<f32>> = Vec::with_capacity(z.nz);
    for gz in 0..z.nz {
        let (mut sum, mut n) = (0.0f64, 0u32);
        for i in gz * per..(gz + 1) * per {
            if z.data[i] == 0 || rho.data[i] == 0 || dec_z(z.data[i]) < 20.0 {
                continue;
            }
            sum += dec_rho(rho.data[i]) as f64;
            n += 1;
        }
        // Too few samples at this height to trust the mean.
        prof.push((n >= 64).then(|| (sum / n as f64) as f32));
    }

    let mut best_h = DEFAULT_MELTING_LEVEL_M;
    let mut best_rho = 0.97; // must dip below this to count at all
    for gz in 1..z.nz.saturating_sub(1) {
        let h = (gz as f32 + 0.5) * dz;
        if h < MIN_MELTING_LEVEL_M {
            continue;
        }
        let (Some(mean), Some(below), Some(above)) = (prof[gz], prof[gz - 1], prof[gz + 1])
        else {
            continue;
        };
        // A bright band is a layer, not a floor: cleaner on both sides.
        if mean >= below || mean >= above {
            continue;
        }
        if mean < best_rho {
            best_rho = mean;
            best_h = h;
        }
    }
    best_h
}

/// Combine three gridded moments into a grid of class ids.
///
/// The three grids must share a lattice — build them with the same
/// dimensions and extents. A voxel is classified only where all three
/// moments have data; dual-pol classification from one moment is guesswork,
/// so partial coverage stays empty.
///
/// `decode` turns a stored byte back into physical units, matching the
/// `GridEncode` each grid was built with.
pub fn build_grid_hca(
    z: &Grid3D,
    zdr: &Grid3D,
    rho: &Grid3D,
    dec_z: impl Fn(u8) -> f32,
    dec_zdr: impl Fn(u8) -> f32,
    dec_rho: impl Fn(u8) -> f32,
    melting_level_m: f32,
) -> Grid3D {
    let n = z.data.len();
    debug_assert_eq!(n, zdr.data.len());
    debug_assert_eq!(n, rho.data.len());
    let dz = z.top_m / z.nz as f32;
    let mut data = vec![0u8; n];
    for i in 0..n {
        let (rz, rzdr, rrho) = (z.data[i], zdr.data[i], rho.data[i]);
        if rz == 0 || rzdr == 0 || rrho == 0 {
            continue;
        }
        let gz = i / (z.nxy * z.nxy);
        let h = (gz as f32 + 0.5) * dz;
        let c = classify(
            dec_z(rz),
            dec_zdr(rzdr),
            dec_rho(rrho),
            h - melting_level_m,
            h,
        );
        data[i] = c as u8;
    }
    Grid3D {
        nxy: z.nxy,
        nz: z.nz,
        data,
        half_extent_m: z.half_extent_m,
        top_m: z.top_m,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // Textbook signatures, each the case the corresponding class exists to
    // catch. Values are the middles of the published dual-pol ranges, not
    // numbers reverse-engineered from this implementation.
    #[test]
    fn recognises_the_classic_signatures() {
        // Heavy rain: high Z, moderately oblate drops, clean RHO, below melt.
        assert_eq!(classify(50.0, 1.8, 0.99, -2000.0, 1200.0), Class::HeavyRain);
        // Hail mixed with rain: very high Z, ZDR collapsed by tumbling.
        assert_eq!(classify(62.0, 0.2, 0.93, -1500.0, 1700.0), Class::HailRain);
        // Dry snow above the melting level.
        assert_eq!(classify(20.0, 0.2, 0.99, 2500.0, 5700.0), Class::DrySnow);
        // Bright band: ZDR up, RHO down, right at the melting level.
        assert_eq!(classify(35.0, 2.0, 0.90, 0.0, 3200.0), Class::WetSnow);
        // Insects: weak, hugely oblate, incoherent, near the ground.
        assert_eq!(classify(15.0, 6.0, 0.65, -3500.0, 200.0), Class::Biological);
        // Graupel: strong but spherical, well above the melting level.
        assert_eq!(classify(45.0, 0.3, 0.99, 1500.0, 4700.0), Class::Graupel);
        // Big drops: modest Z for a very large ZDR.
        assert_eq!(classify(32.0, 4.2, 0.98, -1000.0, 2200.0), Class::BigDrops);
    }

    #[test]
    fn height_separates_otherwise_identical_returns() {
        // The same moments mean different things at different heights: this
        // is why the melting level is an input and not a constant.
        let (z, zdr, rho) = (22.0, 0.3, 0.99);
        assert_eq!(classify(z, zdr, rho, -3000.0, 200.0), Class::LightRain);
        assert_eq!(classify(z, zdr, rho, 3000.0, 6200.0), Class::DrySnow);
    }

    #[test]
    fn noise_stays_unclassified() {
        // Nothing coherent: no class should claim it.
        assert_eq!(classify(-20.0, 9.0, 0.35, 6000.0, 9200.0), Class::None);
    }

    /// A volume with a deliberate RHO dip one level up, and enough samples
    /// there to be believed.
    fn banded_volume(dip_level: usize) -> (Grid3D, Grid3D) {
        let (nxy, nz) = (16, 10);
        let z = Grid3D {
            nxy,
            nz,
            data: vec![200u8; nxy * nxy * nz],
            half_extent_m: 10_000.0,
            top_m: 10_000.0,
        };
        let mut rho_data = vec![250u8; nxy * nxy * nz];
        let per = nxy * nxy;
        for i in dip_level * per..(dip_level + 1) * per {
            rho_data[i] = 100;
        }
        let rho = Grid3D {
            data: rho_data,
            ..z.clone()
        };
        (z, rho)
    }

    #[test]
    fn finds_the_bright_band() {
        let (z, rho) = banded_volume(4);
        let h = detect_melting_level(&z, &rho, |_| 40.0, |r| if r > 200 { 0.99 } else { 0.88 });
        // Level 4 of 10 across 10 km, sampled at the centre of the cell.
        assert_eq!(h, 4500.0);
    }

    #[test]
    fn no_bright_band_falls_back_rather_than_guessing() {
        // Uniformly clean RHO: nothing is melting, so there is no layer to
        // find and picking the least-clean height would be noise-chasing.
        let (z, rho) = banded_volume(4);
        let h = detect_melting_level(&z, &rho, |_| 40.0, |_| 0.995);
        assert_eq!(h, DEFAULT_MELTING_LEVEL_M);
    }

    #[test]
    fn a_night_time_bug_layer_is_not_a_bright_band() {
        // The case that made this guard necessary. Overnight the boundary
        // layer fills with insects, whose correlation coefficient is worse
        // than any melting snow, and the profile simply improves with height.
        // Taking the plain minimum put the melting level at 200 m and made
        // the classifier call an entire LBB volume ice.
        let (nxy, nz) = (16, 10);
        let z = Grid3D {
            nxy,
            nz,
            data: vec![200u8; nxy * nxy * nz],
            half_extent_m: 10_000.0,
            top_m: 10_000.0,
        };
        // RHO climbs monotonically away from the ground: no layer, just bugs.
        let mut data = vec![0u8; nxy * nxy * nz];
        for gz in 0..nz {
            let frac = gz as f32 / (nz - 1) as f32;
            let rho = 0.55 + 0.44 * frac;
            for i in gz * nxy * nxy..(gz + 1) * nxy * nxy {
                data[i] = (rho * 200.0 - 35.0) as u8;
            }
        }
        let rho = Grid3D { data, ..z.clone() };

        let h = detect_melting_level(&z, &rho, |_| 40.0, |raw| (raw as f32 + 35.0) / 200.0);
        assert_eq!(
            h, DEFAULT_MELTING_LEVEL_M,
            "a monotonic profile has no bright band; got {h} m"
        );
    }

    #[test]
    fn a_dip_below_the_floor_is_ignored() {
        // Even a genuine local minimum is not a melting level if it is at the
        // ground.
        let (nxy, nz) = (16, 20);
        let z = Grid3D {
            nxy,
            nz,
            data: vec![200u8; nxy * nxy * nz],
            half_extent_m: 10_000.0,
            top_m: 20_000.0, // 1 km levels
        };
        let mut data = vec![250u8; nxy * nxy * nz];
        // Dip at level 0, i.e. 500 m, under the 1000 m floor.
        for i in 0..nxy * nxy {
            data[i] = 100;
        }
        let rho = Grid3D { data, ..z.clone() };
        let h = detect_melting_level(&z, &rho, |_| 40.0, |r| if r > 200 { 0.99 } else { 0.88 });
        assert_eq!(h, DEFAULT_MELTING_LEVEL_M);
    }

    #[test]
    fn a_voxel_needs_all_three_moments() {
        let mk = |v: u8| Grid3D {
            nxy: 2,
            nz: 1,
            data: vec![v, v, v, 0], // last voxel missing in whichever grid
            half_extent_m: 1000.0,
            top_m: 1000.0,
        };
        let z = mk(200);
        let zdr = Grid3D {
            data: vec![100, 100, 0, 100],
            ..mk(100)
        };
        let rho = mk(250);
        let out = build_grid_hca(
            &z,
            &zdr,
            &rho,
            |_| 50.0,
            |_| 1.8,
            |_| 0.99,
            5000.0,
        );
        assert_ne!(out.data[0], 0, "all three present, should classify");
        assert_eq!(out.data[2], 0, "ZDR missing here, must stay empty");
        assert_eq!(out.data[3], 0, "Z missing here, must stay empty");
    }
}
