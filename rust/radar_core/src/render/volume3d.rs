//! CPU raymarched 3D view of a reflectivity volume grid.
//!
//! Emission-absorption volume rendering with the reflectivity palette and an
//! orbiting perspective camera. Fast enough in release mode to re-render on
//! gesture end: drag to orbit, no GPU dependencies.

use crate::process::grid3d::Grid3D;
use crate::render::ColorTable;

pub struct Volume3DImage {
    pub width: u32,
    pub height: u32,
    pub rgba: Vec<u8>,
}

/// Render the grid from an orbit camera.
/// yaw: degrees around the vertical axis; pitch: degrees above the horizon;
/// zoom: 1.0 frames the whole volume; dbz_min: hide echoes below this.
#[allow(clippy::too_many_arguments)]
pub fn render_volume(
    grid: &Grid3D,
    yaw_deg: f32,
    pitch_deg: f32,
    zoom: f32,
    dbz_min: f32,
    width: u32,
    height: u32,
    z_exaggeration: f32,
) -> Volume3DImage {
    let w = width as usize;
    let h = height as usize;
    let mut rgba = vec![0u8; w * h * 4];

    // World units: meters; grid centered at origin, z in [0, top*exag].
    let ex = grid.half_extent_m;
    let top = grid.top_m * z_exaggeration;
    let center = [0.0f32, 0.0, top * 0.5];

    let yaw = yaw_deg.to_radians();
    let pitch = pitch_deg.to_radians().clamp(0.05, 1.55);
    let dist = 2.6 * ex / zoom.clamp(0.3, 8.0);
    let eye = [
        center[0] + dist * pitch.cos() * yaw.sin(),
        center[1] - dist * pitch.cos() * yaw.cos(),
        center[2] + dist * pitch.sin(),
    ];

    // Camera basis (look-at center, z-up).
    let fwd = norm([center[0] - eye[0], center[1] - eye[1], center[2] - eye[2]]);
    let right = norm(cross(fwd, [0.0, 0.0, 1.0]));
    let up = cross(right, fwd);
    let fov = 40f32.to_radians();
    let plane_h = 2.0 * (fov * 0.5).tan();
    let plane_w = plane_h * w as f32 / h as f32;

    // Transfer LUT: raw byte -> premultiplied color + per-meter opacity.
    let table = ColorTable::reflectivity_default();
    let mut lut = [([0f32; 3], 0f32); 256];
    for raw in 0..256 {
        let dbz = (raw as f32 - 66.0) / 2.0;
        if raw >= 2 && dbz >= dbz_min {
            let c = table.sample(dbz);
            // Stronger echoes are markedly more opaque.
            let o = ((dbz - dbz_min) / 25.0).clamp(0.04, 1.4);
            lut[raw as usize] = ([c[0] as f32, c[1] as f32, c[2] as f32], o);
        }
    }

    let step = (2.0 * ex / grid.nxy as f32).max(top / grid.nz as f32) * 0.55;
    let inv_vox_xy = grid.nxy as f32 / (2.0 * ex);
    let inv_vox_z = grid.nz as f32 / top;

    for py in 0..h {
        for px in 0..w {
            let u = (px as f32 + 0.5) / w as f32 - 0.5;
            let v = 0.5 - (py as f32 + 0.5) / h as f32;
            let dir = norm([
                fwd[0] + right[0] * u * plane_w + up[0] * v * plane_h,
                fwd[1] + right[1] * u * plane_w + up[1] * v * plane_h,
                fwd[2] + right[2] * u * plane_w + up[2] * v * plane_h,
            ]);

            // Ray / box intersection ([-ex,ex]² × [0,top]).
            let (t0, t1) = match ray_box(eye, dir, ex, top) {
                Some(t) => t,
                None => continue,
            };

            let mut acc = [0f32; 3];
            let mut alpha = 0f32;
            let mut t = t0.max(0.0);
            while t < t1 && alpha < 0.97 {
                let x = eye[0] + dir[0] * t;
                let y = eye[1] + dir[1] * t;
                let z = eye[2] + dir[2] * t;
                // Trilinear sample: smooth, cloud-like instead of voxel grain.
                let fx = (x + ex) * inv_vox_xy - 0.5;
                let fy = (y + ex) * inv_vox_xy - 0.5;
                let fz = z * inv_vox_z - 0.5;
                let raw = trilinear(grid, fx, fy, fz);
                if raw > 1.5 {
                    let (color, opacity) = lut[raw as usize];
                    if opacity > 0.0 {
                        let a = (opacity * step / 2000.0).min(0.9) * (1.0 - alpha);
                        acc[0] += color[0] * a;
                        acc[1] += color[1] * a;
                        acc[2] += color[2] * a;
                        alpha += a;
                    }
                }
                t += step;
            }

            if alpha > 0.01 {
                let o = (py * w + px) * 4;
                rgba[o] = acc[0].min(255.0) as u8;
                rgba[o + 1] = acc[1].min(255.0) as u8;
                rgba[o + 2] = acc[2].min(255.0) as u8;
                rgba[o + 3] = (alpha * 255.0).min(255.0) as u8;
            }
        }
    }

    Volume3DImage {
        width,
        height,
        rgba,
    }
}

/// Trilinearly interpolated grid sample (0 outside).
#[inline]
fn trilinear(grid: &Grid3D, fx: f32, fy: f32, fz: f32) -> f32 {
    let x0 = fx.floor();
    let y0 = fy.floor();
    let z0 = fz.floor();
    let tx = fx - x0;
    let ty = fy - y0;
    let tz = fz - z0;
    let mut acc = 0.0f32;
    for (dz, wz) in [(0isize, 1.0 - tz), (1, tz)] {
        for (dy, wy) in [(0isize, 1.0 - ty), (1, ty)] {
            for (dx, wx) in [(0isize, 1.0 - tx), (1, tx)] {
                let w = wx * wy * wz;
                if w <= 0.0 {
                    continue;
                }
                let gx = x0 as isize + dx;
                let gy = y0 as isize + dy;
                let gz = z0 as isize + dz;
                if gx >= 0
                    && gy >= 0
                    && gz >= 0
                    && (gx as usize) < grid.nxy
                    && (gy as usize) < grid.nxy
                    && (gz as usize) < grid.nz
                {
                    acc += w * grid.at(gx as usize, gy as usize, gz as usize) as f32;
                }
            }
        }
    }
    acc
}

fn norm(v: [f32; 3]) -> [f32; 3] {
    let l = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt().max(1e-6);
    [v[0] / l, v[1] / l, v[2] / l]
}

fn cross(a: [f32; 3], b: [f32; 3]) -> [f32; 3] {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}

fn ray_box(eye: [f32; 3], dir: [f32; 3], ex: f32, top: f32) -> Option<(f32, f32)> {
    let mut t0 = f32::MIN;
    let mut t1 = f32::MAX;
    let mins = [-ex, -ex, 0.0];
    let maxs = [ex, ex, top];
    for i in 0..3 {
        if dir[i].abs() < 1e-8 {
            if eye[i] < mins[i] || eye[i] > maxs[i] {
                return None;
            }
            continue;
        }
        let inv = 1.0 / dir[i];
        let (a, b) = ((mins[i] - eye[i]) * inv, (maxs[i] - eye[i]) * inv);
        t0 = t0.max(a.min(b));
        t1 = t1.min(a.max(b));
    }
    if t1 <= t0.max(0.0) {
        None
    } else {
        Some((t0, t1))
    }
}
