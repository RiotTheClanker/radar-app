//! Build a Cartesian 3D reflectivity grid from a volume scan's cuts.

use crate::sweep::Sweep;

pub struct Grid3D {
    /// x (east), y (north) voxels per side; z levels.
    pub nxy: usize,
    pub nz: usize,
    /// dBZ per voxel encoded raw = dBZ*2+66 (0 = no data), index [z][y][x].
    pub data: Vec<u8>,
    /// Horizontal half-extent from the radar, meters.
    pub half_extent_m: f32,
    /// Vertical extent (0..top), meters.
    pub top_m: f32,
}

impl Grid3D {
    #[inline]
    pub fn at(&self, x: usize, y: usize, z: usize) -> u8 {
        self.data[(z * self.nxy + y) * self.nxy + x]
    }
}

/// How physical values are packed into grid bytes: raw = v*scale + offset.
#[derive(Clone, Copy)]
pub struct GridEncode {
    pub scale: f32,
    pub offset: f32,
    /// Values below this are treated as empty air.
    pub min_show: f32,
    /// Value that "no echo" fades toward (e.g. -33 dBZ, 0 m/s).
    pub no_echo: f32,
}

pub const ENCODE_DBZ: GridEncode = GridEncode {
    scale: 2.0,
    offset: 66.0,
    min_show: -30.0,
    no_echo: -33.0,
};

/// Sample every REF cut into a regular grid. Between cut beam heights the
/// reflectivity is linearly interpolated; above/below the scanned cone it
/// fades out quickly.
pub fn build_grid(cuts: &[Sweep], nxy: usize, nz: usize, half_extent_m: f32, top_m: f32) -> Option<Grid3D> {
    build_grid_encoded(cuts, nxy, nz, half_extent_m, top_m, ENCODE_DBZ)
}

/// Grid build with an explicit value encoding (velocity, ZDR, CC, ...).
pub fn build_grid_encoded(
    cuts: &[Sweep],
    nxy: usize,
    nz: usize,
    half_extent_m: f32,
    top_m: f32,
    enc: GridEncode,
) -> Option<Grid3D> {
    if cuts.is_empty() {
        return None;
    }
    let mut data = vec![0u8; nxy * nxy * nz];

    // Azimuth LUTs (0.5° slots) per cut.
    let luts: Vec<Vec<i32>> = cuts
        .iter()
        .map(|c| {
            let mut lut = vec![-1i32; 720];
            for (i, r) in c.radials.iter().enumerate() {
                let start = (r.start_az_deg * 2.0).round() as i32;
                let steps = (r.delta_az_deg * 2.0).round().max(1.0) as i32;
                for s in 0..steps {
                    lut[(((start + s) % 720 + 720) % 720) as usize] = i as i32;
                }
            }
            lut
        })
        .collect();
    let cos_el: Vec<f64> = cuts
        .iter()
        .map(|c| (c.elevation_deg as f64).to_radians().cos())
        .collect();

    let vox = 2.0 * half_extent_m / nxy as f32;
    let dz = top_m / nz as f32;

    for gy in 0..nxy {
        let y = (gy as f32 + 0.5) * vox - half_extent_m; // north+
        for gx in 0..nxy {
            let x = (gx as f32 + 0.5) * vox - half_extent_m; // east+
            let ground = (x * x + y * y).sqrt() as f64;
            if ground < 500.0 {
                continue; // cone of silence right over the radar
            }
            let az = (x as f64).atan2(y as f64).to_degrees();
            let slot = (((az * 2.0).round() as i32) % 720 + 720) % 720;

            // Column: (height m, dBZ) per cut at this ground position.
            let mut col: Vec<(f32, f32)> = Vec::with_capacity(cuts.len());
            for (k, cut) in cuts.iter().enumerate() {
                let ridx = luts[k][slot as usize];
                if ridx < 0 {
                    continue;
                }
                let slant = ground / cos_el[k];
                let gi = ((slant - cut.first_gate_m as f64) / cut.gate_size_m as f64) as i64;
                if gi < 0 {
                    continue;
                }
                let Some(raw) = cut.radials[ridx as usize].data.get(gi as usize) else {
                    continue;
                };
                if raw <= 1 {
                    // keep explicit "no echo" so interpolation can fade
                    col.push((cut.beam_height_m(slant) as f32, enc.no_echo));
                    continue;
                }
                if let crate::level3::BinValue::Value(dbz) = cut.decoder.decode(raw) {
                    col.push((cut.beam_height_m(slant) as f32, dbz));
                }
            }
            if col.is_empty() {
                continue;
            }
            col.sort_by(|a, b| a.0.total_cmp(&b.0));

            for gz in 0..nz {
                let h = (gz as f32 + 0.5) * dz;
                // Find bracketing cuts.
                let dbz = match col.iter().position(|&(ch, _)| ch >= h) {
                    Some(0) => {
                        // Below the lowest beam: extend it down to the ground.
                        col[0].1
                    }
                    Some(i) => {
                        let (h0, v0) = col[i - 1];
                        let (h1, v1) = col[i];
                        let t = ((h - h0) / (h1 - h0).max(1.0)).clamp(0.0, 1.0);
                        v0 + (v1 - v0) * t
                    }
                    None => {
                        // Above the highest beam: fade out over ~1.5 km.
                        let (ht, vt) = *col.last().unwrap();
                        let fade = 1.0 - ((h - ht) / 1500.0).clamp(0.0, 1.0);
                        if fade <= 0.0 {
                            continue;
                        }
                        vt * fade + enc.no_echo * (1.0 - fade)
                    }
                };
                if dbz > enc.min_show {
                    data[(gz * nxy + gy) * nxy + gx] =
                        ((dbz * enc.scale + enc.offset).round()).clamp(2.0, 255.0) as u8;
                }
            }
        }
    }

    // Light separable box blur (horizontal only, radius 1) knocks down radial
    // speckle so the trilinear render reads as cloud masses, not static.
    // Empty voxels (0) adopt the center value so edges don't smear toward
    // zero — critical for center-offset encodings like velocity.
    let nb = |v: u8, c: u8| if v == 0 { c as u16 } else { v as u16 };
    let mut blurred = data.clone();
    for z in 0..nz {
        for y in 0..nxy {
            for x in 1..nxy - 1 {
                let i = (z * nxy + y) * nxy + x;
                let c = data[i];
                if c == 0 {
                    continue;
                }
                blurred[i] = ((nb(data[i - 1], c) + 2 * c as u16 + nb(data[i + 1], c)) / 4) as u8;
            }
        }
    }
    for z in 0..nz {
        for x in 0..nxy {
            for y in 1..nxy - 1 {
                let i = (z * nxy + y) * nxy + x;
                let c = blurred[i];
                if c == 0 {
                    continue;
                }
                let up = (z * nxy + y - 1) * nxy + x;
                let dn = (z * nxy + y + 1) * nxy + x;
                data[i] = ((nb(blurred[up], c) + 2 * c as u16 + nb(blurred[dn], c)) / 4) as u8;
            }
        }
    }

    Some(Grid3D {
        nxy,
        nz,
        data,
        half_extent_m,
        top_m,
    })
}
