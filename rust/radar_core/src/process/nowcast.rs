//! On-device nowcasting: estimate how the echo field is moving between two
//! consecutive frames, then extrapolate it forward.
//!
//! This is the "future radar" that paid apps compute server-side and put
//! behind a subscription. The method is classic cross-correlation tracking
//! (a.k.a. TREC): match the recent frame against the previous one to get a
//! displacement field, then advect. Nothing here needs a network.

/// Downsample a raw-value grid by `f` using max pooling (keeps cores).
fn pool(src: &[u8], w: usize, h: usize, f: usize) -> (Vec<u8>, usize, usize) {
    let ow = w.div_ceil(f);
    let oh = h.div_ceil(f);
    let mut out = vec![0u8; ow * oh];
    for y in 0..h {
        let oy = y / f;
        for x in 0..w {
            let v = src[y * w + x];
            if v > 1 {
                let o = oy * ow + x / f;
                if v > out[o] {
                    out[o] = v;
                }
            }
        }
    }
    (out, ow, oh)
}

/// Sum of absolute differences between `b` and `a` shifted by (dx, dy),
/// counted only where both frames have data. Returns None when the overlap
/// is too small to be meaningful.
fn sad(a: &[u8], b: &[u8], w: usize, h: usize, dx: i32, dy: i32) -> Option<f64> {
    let mut sum = 0f64;
    let mut n = 0usize;
    for y in 0..h {
        let sy = y as i32 - dy;
        if sy < 0 || sy >= h as i32 {
            continue;
        }
        for x in 0..w {
            let sx = x as i32 - dx;
            if sx < 0 || sx >= w as i32 {
                continue;
            }
            let bv = b[y * w + x];
            let av = a[sy as usize * w + sx as usize];
            if bv <= 1 && av <= 1 {
                continue;
            }
            sum += (bv as f64 - av as f64).abs();
            n += 1;
        }
    }
    if n < (w * h) / 20 {
        return None;
    }
    Some(sum / n as f64)
}

/// Estimate the pixel displacement from frame `a` to frame `b`.
///
/// Coarse-to-fine search: a strided pass over a wide window, then a
/// single-pixel refinement around the winner. Returned in *full-resolution*
/// pixels of the input grids.
pub fn estimate_motion(a: &[u8], b: &[u8], w: usize, h: usize) -> (f32, f32) {
    // Work at 1/4 scale: motion of weather over a scan interval is many
    // pixels, and this keeps the search cheap.
    let f = 4usize;
    let (pa, pw, ph) = pool(a, w, h, f);
    let (pb, _, _) = pool(b, w, h, f);
    if pw < 8 || ph < 8 {
        return (0.0, 0.0);
    }

    let max_shift = (pw.min(ph) / 4).clamp(4, 24) as i32;
    let mut best = (0i32, 0i32);
    let mut best_score = f64::MAX;

    let mut step = 3i32;
    let mut center = (0i32, 0i32);
    while step >= 1 {
        let range = if step == 3 { max_shift } else { step * 3 };
        let mut local_best = (center.0, center.1);
        let mut local_score = f64::MAX;
        let mut dy = center.1 - range;
        while dy <= center.1 + range {
            let mut dx = center.0 - range;
            while dx <= center.0 + range {
                if let Some(s) = sad(&pa, &pb, pw, ph, dx, dy) {
                    if s < local_score {
                        local_score = s;
                        local_best = (dx, dy);
                    }
                }
                dx += step;
            }
            dy += step;
        }
        if local_score < best_score {
            best_score = local_score;
            best = local_best;
        }
        center = best;
        step -= 2;
    }

    ((best.0 * f as i32) as f32, (best.1 * f as i32) as f32)
}

/// Shift a raw-value grid by (dx, dy) pixels, sampling backwards so the
/// output stays gap-free. Out-of-range samples become "no data".
pub fn advect(src: &[u8], w: usize, h: usize, dx: f32, dy: f32) -> Vec<u8> {
    let mut out = vec![0u8; w * h];
    let rdx = dx.round() as i32;
    let rdy = dy.round() as i32;
    for y in 0..h {
        let sy = y as i32 - rdy;
        if sy < 0 || sy >= h as i32 {
            continue;
        }
        for x in 0..w {
            let sx = x as i32 - rdx;
            if sx < 0 || sx >= w as i32 {
                continue;
            }
            out[y * w + x] = src[sy as usize * w + sx as usize];
        }
    }
    out
}
