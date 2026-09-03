//! GPU volume raymarcher (wgpu, headless).
//!
//! The 3D grid is uploaded once as an `r8unorm` 3D texture (hardware
//! trilinear filtering gives the smooth cloud look for free); each frame is
//! a fullscreen-triangle fragment raymarch with clip planes, rendered
//! offscreen and read back as RGBA bytes. Fast enough for a free-fly camera.

use crate::process::grid3d::Grid3D;

const SHADER: &str = r#"
struct U {
    eye: vec4f,
    fwd: vec4f,
    right: vec4f,
    up: vec4f,
    // p0: plane_w, plane_h, ex, top
    p0: vec4f,
    // p1: step, alpha_scale, width, height
    p1: vec4f,
    cmin: vec4f,
    cmax: vec4f,
    // g0.x: 1 when a basemap ground texture is bound
    // g0.y: 1 when a terrain heightfield is bound
    // g0.z: tallest terrain height in meters, before exaggeration
    // g0.w: vertical exaggeration, matching the volume's
    g0: vec4f,
    // g1.x: 1 when the cone of silence should be drawn
    // g1.y: highest elevation the volume scanned, radians
    g1: vec4f,
};

@group(0) @binding(0) var<uniform> u: U;
@group(0) @binding(1) var vol: texture_3d<f32>;
@group(0) @binding(2) var vol_samp: sampler;
@group(0) @binding(3) var pal: texture_2d<f32>;
@group(0) @binding(4) var pal_samp: sampler;
@group(0) @binding(5) var ground: texture_2d<f32>;
@group(0) @binding(6) var terrain: texture_2d<f32>;

/// Ground-plane texture coordinates for a world xy.
fn ground_uv(p: vec2f, ex: f32) -> vec2f {
    return vec2f((p.x + ex) / (2.0 * ex), 1.0 - (p.y + ex) / (2.0 * ex));
}

/// Terrain height at a world xy, exaggerated to match the volume's z axis.
fn terrain_h(p: vec2f, ex: f32, zex: f32) -> f32 {
    return textureSampleLevel(terrain, pal_samp, ground_uv(p, ex), 0.0).r * zex;
}

@vertex
fn vs(@builtin(vertex_index) vi: u32) -> @builtin(position) vec4f {
    // Fullscreen triangle
    let x = f32(i32(vi & 1u) * 4 - 1);
    let y = f32(i32(vi >> 1u) * 4 - 1);
    return vec4f(x, y, 0.0, 1.0);
}

fn ray_box(eye: vec3f, dir: vec3f, bmin: vec3f, bmax: vec3f) -> vec2f {
    let inv = 1.0 / dir;
    let a = (bmin - eye) * inv;
    let b = (bmax - eye) * inv;
    let tmin = min(a, b);
    let tmax = max(a, b);
    let t0 = max(max(tmin.x, tmin.y), tmin.z);
    let t1 = min(min(tmax.x, tmax.y), tmax.z);
    return vec2f(t0, t1);
}

@fragment
fn fs(@builtin(position) pos: vec4f) -> @location(0) vec4f {
    let res = u.p1.zw;
    let uvx = pos.x / res.x - 0.5;
    let uvy = 0.5 - pos.y / res.y;
    let dir = normalize(u.fwd.xyz + u.right.xyz * uvx * u.p0.x + u.up.xyz * uvy * u.p0.y);

    let ex = u.p0.z;
    let top = u.p0.w;

    // Basemap on the ground, so you can tell where you are. Sampled
    // independently of the clip box; the volume composites over it.
    var ground_col = vec4f(0.0);
    // Distance to the ground, so the volume can stop at a hill in front of
    // it rather than being drawn straight through.
    var ground_t = -1.0;
    if (u.g0.y > 0.5) {
        // Terrain on: march the heightfield until the ray drops under the
        // surface, then bisect the crossing so ridgelines stay crisp.
        let zex = u.g0.w;
        let maxh = u.g0.z * zex;
        let bb = ray_box(u.eye.xyz, dir,
                         vec3f(-ex, -ex, -1.0e7), vec3f(ex, ex, maxh + 1.0));
        var t0 = max(bb.x, 0.0);
        let tend = bb.y;
        if (tend > t0) {
            let tstep = (2.0 * ex) / 256.0;
            var prev_t = t0;
            let p0 = u.eye.xyz + dir * t0;
            var prev_d = p0.z - terrain_h(p0.xy, ex, zex);
            // Starting underground counts as an immediate hit.
            var hit_t = select(-1.0, t0, prev_d < 0.0);
            if (hit_t < 0.0) {
                var tt = t0 + tstep;
                for (var i = 0; i < 260; i++) {
                    if (tt > tend) { break; }
                    let p = u.eye.xyz + dir * tt;
                    let d = p.z - terrain_h(p.xy, ex, zex);
                    if (d < 0.0) {
                        var a = prev_t;
                        var b = tt;
                        for (var k = 0; k < 8; k++) {
                            let m = 0.5 * (a + b);
                            let pm = u.eye.xyz + dir * m;
                            if (pm.z - terrain_h(pm.xy, ex, zex) < 0.0) {
                                b = m;
                            } else {
                                a = m;
                            }
                        }
                        hit_t = b;
                        break;
                    }
                    prev_d = d;
                    prev_t = tt;
                    tt += tstep;
                }
            }
            if (hit_t >= 0.0) {
                let hp = u.eye.xyz + dir * hit_t;
                var col = textureSampleLevel(ground, pal_samp,
                                             ground_uv(hp.xy, ex), 0.0);
                if (u.g0.x < 0.5) { col = vec4f(0.34, 0.35, 0.33, 1.0); }
                // Relief from the height gradient, so the shape reads even
                // where the basemap is flat in color.
                let e = (2.0 * ex) / 256.0;
                let hx = terrain_h(hp.xy + vec2f(e, 0.0), ex, zex)
                       - terrain_h(hp.xy - vec2f(e, 0.0), ex, zex);
                let hy = terrain_h(hp.xy + vec2f(0.0, e), ex, zex)
                       - terrain_h(hp.xy - vec2f(0.0, e), ex, zex);
                let n = normalize(vec3f(-hx / (2.0 * e), -hy / (2.0 * e), 1.0));
                let sun = normalize(vec3f(-0.45, -0.6, 0.66));
                let shade = clamp(0.55 + 0.75 * max(dot(n, sun), 0.0), 0.45, 1.4);
                ground_col = vec4f(col.rgb * shade, max(col.a, 0.85));
                ground_t = hit_t;
            }
        }
    } else if (u.g0.x > 0.5 && dir.z < -0.00001) {
        let tg = -u.eye.z / dir.z;
        if (tg > 0.0) {
            let gp = u.eye.xyz + dir * tg;
            if (abs(gp.x) <= ex && abs(gp.y) <= ex) {
                ground_col = textureSampleLevel(ground, pal_samp,
                                                ground_uv(gp.xy, ex), 0.0);
                ground_t = tg;
            }
        }
    }
    // Clip planes are normalized [0,1] fractions of the volume box.
    let bmin = vec3f(-ex, -ex, 0.0) + u.cmin.xyz * vec3f(2.0 * ex, 2.0 * ex, top);
    let bmax = vec3f(-ex, -ex, 0.0) + u.cmax.xyz * vec3f(2.0 * ex, 2.0 * ex, top);

    let hit = ray_box(u.eye.xyz, dir, bmin, bmax);
    var t = max(hit.x, 0.0);
    // Stop at the ground: storm behind a ridge should be hidden by it.
    var t1 = hit.y;
    if (ground_t >= 0.0) { t1 = min(t1, ground_t); }

    var acc = vec3f(0.0);
    var alpha = 0.0;
    let step = u.p1.x;
    let alpha_scale = u.p1.y;

    for (var i = 0; i < 1200; i++) {
        if (t1 <= t) { break; }
        if (t >= t1 || alpha >= 0.97) { break; }
        let p = u.eye.xyz + dir * t;
        let tc = vec3f((p.x + ex) / (2.0 * ex), (p.y + ex) / (2.0 * ex), p.z / top);
        // .r is the palette index, .g is coverage: 1 where the radar
        // actually sampled, 0 where it did not. They have to be filtered
        // separately. Interpolating the index alone across the edge of the
        // data sweeps it through the whole palette, and for the fields whose
        // zero sits mid-table that invents readings -- half way from 0 m/s
        // (index 128) to empty (index 0) is index 64, a fully opaque -32 m/s
        // that nothing measured. Reflectivity escapes it only because its
        // low indices are transparent anyway.
        //
        // The index is dilated one voxel into empty space when uploaded, so
        // it stays put across the boundary and coverage alone fades out.
        let s = textureSampleLevel(vol, vol_samp, tc, 0.0);
        let cov = s.g;
        if (cov > 0.004) {
            let c = textureSampleLevel(pal, pal_samp,
                vec2f(s.r * 0.99609375 + 0.001953125, 0.5), 0.0);
            if (c.a > 0.0) {
                let a = min(c.a * cov * alpha_scale * step, 0.9) * (1.0 - alpha);
                acc += c.rgb * a;
                alpha += a;
            }
        }
        // The cone of silence: the radar cannot tilt past its top cut, so
        // nothing above that angle is ever sampled. Fill it with a thin haze
        // so the shape of what the radar cannot see is visible. Heights are
        // exaggerated in world space, so undo that before taking the angle.
        if (u.g1.x > 0.5) {
            let gr = length(p.xy);
            let real_z = p.z / max(u.g0.w, 0.001);
            if (gr > 1.0 && atan2(real_z, gr) > u.g1.y) {
                let ca = min(0.000016 * step, 0.02) * (1.0 - alpha);
                acc += vec3f(0.38, 0.74, 0.95) * ca;
                alpha += ca;
            }
        }
        t += step;
    }

    // Composite the basemap underneath whatever the volume left translucent.
    let ga = ground_col.a * (1.0 - alpha);
    return vec4f(acc + ground_col.rgb * ga, alpha + ga);
}
"#;

/// Interleave the grid into (index, coverage) pairs for an `Rg8Unorm`
/// texture, dilating the index one voxel into empty space.
///
/// The hardware filters the two channels independently, which is the point:
/// coverage carries "did the radar see anything here", so the index no longer
/// has to encode absence by being zero. Without the dilation the index would
/// still slide toward 0 across the boundary even though coverage fades it
/// out, and a partly-faded false colour is still a false colour.
///
/// One voxel is enough — trilinear filtering never reaches past immediate
/// neighbours, so beyond the dilated shell coverage is 0 on both sides of
/// every interpolation and nothing is drawn.
fn pack_coverage(grid: &Grid3D) -> Vec<u8> {
    let (nxy, nz) = (grid.nxy, grid.nz);
    let mut out = vec![0u8; nxy * nxy * nz * 2];
    let at = |x: usize, y: usize, z: usize| grid.data[(z * nxy + y) * nxy + x];
    for z in 0..nz {
        for y in 0..nxy {
            for x in 0..nxy {
                let i = (z * nxy + y) * nxy + x;
                let v = grid.data[i];
                if v != 0 {
                    out[i * 2] = v;
                    out[i * 2 + 1] = 255;
                    continue;
                }
                // Empty: borrow a neighbour's index so the value field stays
                // flat across the edge. Coverage stays 0, so this voxel
                // contributes nothing itself.
                // All 26 neighbours, not just the 6 faces: trilinear
                // filtering interpolates over the 8 corners of a cell, so a
                // diagonal neighbour is just as able to drag the index down
                // as an adjacent one.
                let mut sum = 0u32;
                let mut n = 0u32;
                for dz in -1i32..=1 {
                    for dy in -1i32..=1 {
                        for dx in -1i32..=1 {
                            let (sx, sy, sz) =
                                (x as i32 + dx, y as i32 + dy, z as i32 + dz);
                            if sx < 0
                                || sy < 0
                                || sz < 0
                                || sx >= nxy as i32
                                || sy >= nxy as i32
                                || sz >= nz as i32
                            {
                                continue;
                            }
                            let vv = at(sx as usize, sy as usize, sz as usize);
                            if vv != 0 {
                                sum += vv as u32;
                                n += 1;
                            }
                        }
                    }
                }
                out[i * 2] = if n > 0 { (sum / n) as u8 } else { 0 };
            }
        }
    }
    out
}

pub struct GpuVolume {
    device: wgpu::Device,
    queue: wgpu::Queue,
    pipeline: wgpu::RenderPipeline,
    bind_layout: wgpu::BindGroupLayout,
    vol_view: wgpu::TextureView,
    vol_samp: wgpu::Sampler,
    pal_tex: wgpu::Texture,
    pal_view: wgpu::TextureView,
    pal_samp: wgpu::Sampler,
    uniforms: wgpu::Buffer,
    ground_view: wgpu::TextureView,
    has_ground: bool,
    terrain_view: wgpu::TextureView,
    has_terrain: bool,
    /// Tallest terrain height in meters, before exaggeration. Bounds the
    /// heightfield march so rays above every hill exit straight away.
    terrain_max_m: f32,
    z_exaggeration: f32,
    /// Highest elevation the volume scanned, degrees. Everything above this
    /// angle is the cone of silence.
    el_max_deg: f32,
    show_cone: bool,
    pub ex: f32,
    pub top: f32,
}

/// Free-fly camera + render parameters.
pub struct FlyParams {
    pub eye: [f32; 3],
    pub yaw_deg: f32,
    pub pitch_deg: f32,
    pub fov_deg: f32,
    /// Clip fractions of the box, [0,1] per axis.
    pub clip_min: [f32; 3],
    pub clip_max: [f32; 3],
}

impl GpuVolume {
    /// `categorical` marks a field whose values are class ids rather than a
    /// measurement. Those must not be filtered: half way between class 3 and
    /// class 7 is class 5, a different thing entirely, so they sample
    /// nearest-neighbour and show voxel edges.
    pub fn new(
        grid: &Grid3D,
        palette: &[[u8; 4]; 256],
        z_exaggeration: f32,
        categorical: bool,
    ) -> Result<Self, String> {
        let instance = wgpu::Instance::default();
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            ..Default::default()
        }))
        .map_err(|e| format!("no GPU adapter: {e}"))?;
        let (device, queue) =
            pollster::block_on(adapter.request_device(&wgpu::DeviceDescriptor::default()))
                .map_err(|e| format!("no GPU device: {e}"))?;

        // Volume texture
        let size = wgpu::Extent3d {
            width: grid.nxy as u32,
            height: grid.nxy as u32,
            depth_or_array_layers: grid.nz as u32,
        };
        let vol_tex = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("volume"),
            size,
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D3,
            format: wgpu::TextureFormat::Rg8Unorm,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });
        queue.write_texture(
            wgpu::TexelCopyTextureInfo {
                texture: &vol_tex,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            &pack_coverage(grid),
            wgpu::TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(grid.nxy as u32 * 2),
                rows_per_image: Some(grid.nxy as u32),
            },
            size,
        );
        let vol_view = vol_tex.create_view(&wgpu::TextureViewDescriptor::default());
        let vol_filter = if categorical {
            wgpu::FilterMode::Nearest
        } else {
            wgpu::FilterMode::Linear
        };
        let vol_samp = device.create_sampler(&wgpu::SamplerDescriptor {
            mag_filter: vol_filter,
            min_filter: vol_filter,
            address_mode_u: wgpu::AddressMode::ClampToEdge,
            address_mode_v: wgpu::AddressMode::ClampToEdge,
            address_mode_w: wgpu::AddressMode::ClampToEdge,
            ..Default::default()
        });

        // Palette texture (256x1)
        let pal_tex = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("palette"),
            size: wgpu::Extent3d {
                width: 256,
                height: 1,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8Unorm,
            usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
            view_formats: &[],
        });
        let pal_view = pal_tex.create_view(&wgpu::TextureViewDescriptor::default());
        let pal_samp = device.create_sampler(&wgpu::SamplerDescriptor {
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });

        let uniforms = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("uniforms"),
            size: 160,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("raymarch"),
            source: wgpu::ShaderSource::Wgsl(SHADER.into()),
        });

        let bind_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: None,
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: true },
                        view_dimension: wgpu::TextureViewDimension::D3,
                        multisampled: false,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 2,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 3,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: true },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 4,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 5,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: true },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 6,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: true },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
            ],
        });
        let layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: None,
            bind_group_layouts: &[Some(&bind_layout)],
            immediate_size: 0,
        });
        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("raymarch"),
            layout: Some(&layout),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vs"),
                buffers: &[],
                compilation_options: Default::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some("fs"),
                targets: &[Some(wgpu::ColorTargetState {
                    format: wgpu::TextureFormat::Rgba8Unorm,
                    blend: None,
                    write_mask: wgpu::ColorWrites::ALL,
                })],
                compilation_options: Default::default(),
            }),
            primitive: wgpu::PrimitiveState::default(),
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview_mask: None,
            cache: None,
        });

        let ground_view = make_ground_texture(&device, &queue, &[0, 0, 0, 0], 1, 1);
        let terrain_view = make_terrain_texture(&device, &queue, &[0.0], 1, 1);

        let s = Self {
            device,
            queue,
            pipeline,
            bind_layout,
            vol_view,
            vol_samp,
            pal_tex,
            pal_view,
            pal_samp,
            uniforms,
            ground_view,
            has_ground: false,
            terrain_view,
            has_terrain: false,
            terrain_max_m: 0.0,
            z_exaggeration,
            el_max_deg: 19.5,
            show_cone: false,
            ex: grid.half_extent_m,
            top: grid.top_m * z_exaggeration,
        };
        s.update_palette(palette);
        Ok(s)
    }

    pub fn update_palette(&self, palette: &[[u8; 4]; 256]) {
        let flat: Vec<u8> = palette.iter().flatten().copied().collect();
        self.queue.write_texture(
            wgpu::TexelCopyTextureInfo {
                texture: &self.pal_tex,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            &flat,
            wgpu::TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(1024),
                rows_per_image: Some(1),
            },
            wgpu::Extent3d {
                width: 256,
                height: 1,
                depth_or_array_layers: 1,
            },
        );
    }

    /// Upload a basemap image to drape on the ground plane. The image must
    /// cover exactly the volume's horizontal extent, north-up.
    pub fn set_ground(&mut self, rgba: &[u8], width: u32, height: u32) {
        if width == 0 || height == 0 || rgba.len() < (width * height * 4) as usize {
            return;
        }
        self.ground_view = make_ground_texture(&self.device, &self.queue, rgba, width, height);
        self.has_ground = true;
    }

    /// Upload a terrain heightfield covering the same extent as the ground
    /// image, north-up, heights in meters above sea level. Replaces the flat
    /// ground plane with a surface the ray actually collides with.
    /// Install a heightfield. `heights` are metres above **sea level**;
    /// `datum_m` is the height above sea level that the volume's z=0 sits at
    /// — the radar antenna — and is subtracted so the ground and the echoes
    /// end up on one axis.
    ///
    /// Without that subtraction the terrain floated above the storm by the
    /// radar's own altitude, times the vertical exaggeration: 3278 m at
    /// KICX Cedar City, which at 4x buried the volume under 13 km of
    /// mountain. Invisible in Florida, which is why it survived so long.
    pub fn set_terrain(&mut self, heights: &[f32], width: u32, height: u32, datum_m: f32) {
        if width == 0 || height == 0 || heights.len() < (width * height) as usize {
            return;
        }
        let rebased = rebase_to_datum(heights, datum_m);
        self.terrain_max_m = terrain_ceiling(&rebased);
        self.terrain_view =
            make_terrain_texture(&self.device, &self.queue, &rebased, width, height);
        self.has_terrain = true;
    }

    /// Tell the renderer where the scanned cone ends, so it can draw what
    /// lies above it.
    pub fn set_beam_limits(&mut self, el_max_deg: f32) {
        self.el_max_deg = el_max_deg;
    }

    /// Draw the cone of silence as a translucent haze.
    pub fn set_show_cone(&mut self, show: bool) {
        self.show_cone = show;
    }

    /// Go back to the flat ground plane.
    pub fn clear_terrain(&mut self) {
        self.has_terrain = false;
        self.terrain_max_m = 0.0;
    }

    pub fn render(&self, p: &FlyParams, width: u32, height: u32) -> Result<Vec<u8>, String> {
        let yaw = p.yaw_deg.to_radians();
        let pitch = p.pitch_deg.to_radians().clamp(-1.55, 1.55);
        let fwd = [
            pitch.cos() * yaw.sin(),
            pitch.cos() * yaw.cos(),
            pitch.sin(),
        ];
        let right = {
            let r = [fwd[1], -fwd[0], 0.0f32];
            let l = (r[0] * r[0] + r[1] * r[1]).sqrt().max(1e-5);
            [r[0] / l, r[1] / l, 0.0]
        };
        let up = [
            right[1] * fwd[2] - right[2] * fwd[1],
            right[2] * fwd[0] - right[0] * fwd[2],
            right[0] * fwd[1] - right[1] * fwd[0],
        ];
        let plane_h = 2.0 * (p.fov_deg.to_radians() * 0.5).tan();
        let plane_w = plane_h * width as f32 / height as f32;
        let step = (2.0 * self.ex / 384.0).max(self.top / 40.0) * 0.55;

        let mut u = [0f32; 40];
        u[0..3].copy_from_slice(&p.eye);
        u[4..7].copy_from_slice(&fwd);
        u[8..11].copy_from_slice(&right);
        u[12..15].copy_from_slice(&up);
        u[16] = plane_w;
        u[17] = plane_h;
        u[18] = self.ex;
        u[19] = self.top;
        u[20] = step;
        u[21] = 1.0 / 2000.0; // alpha scale per meter
        u[22] = width as f32;
        u[23] = height as f32;
        u[24..27].copy_from_slice(&p.clip_min);
        u[28..31].copy_from_slice(&p.clip_max);
        u[32] = if self.has_ground { 1.0 } else { 0.0 };
        u[33] = if self.has_terrain { 1.0 } else { 0.0 };
        u[34] = self.terrain_max_m;
        u[35] = self.z_exaggeration;
        u[36] = if self.show_cone { 1.0 } else { 0.0 };
        u[37] = self.el_max_deg.to_radians();
        self.queue
            .write_buffer(&self.uniforms, 0, bytemuck::cast_slice(&u));

        let bind = self.device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: None,
            layout: &self.bind_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: self.uniforms.as_entire_binding(),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::TextureView(&self.vol_view),
                },
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: wgpu::BindingResource::Sampler(&self.vol_samp),
                },
                wgpu::BindGroupEntry {
                    binding: 3,
                    resource: wgpu::BindingResource::TextureView(&self.pal_view),
                },
                wgpu::BindGroupEntry {
                    binding: 4,
                    resource: wgpu::BindingResource::Sampler(&self.pal_samp),
                },
                wgpu::BindGroupEntry {
                    binding: 5,
                    resource: wgpu::BindingResource::TextureView(&self.ground_view),
                },
                wgpu::BindGroupEntry {
                    binding: 6,
                    resource: wgpu::BindingResource::TextureView(&self.terrain_view),
                },
            ],
        });

        let target = self.device.create_texture(&wgpu::TextureDescriptor {
            label: Some("target"),
            size: wgpu::Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: wgpu::TextureFormat::Rgba8Unorm,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
            view_formats: &[],
        });
        let tview = target.create_view(&wgpu::TextureViewDescriptor::default());

        let row_bytes = (width * 4).next_multiple_of(256);
        let readback = self.device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("readback"),
            size: (row_bytes * height) as u64,
            usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
            mapped_at_creation: false,
        });

        let mut enc = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor { label: None });
        {
            let mut pass = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: None,
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &tview,
                    resolve_target: None,
                    depth_slice: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color::TRANSPARENT),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });
            pass.set_pipeline(&self.pipeline);
            pass.set_bind_group(0, &bind, &[]);
            pass.draw(0..3, 0..1);
        }
        enc.copy_texture_to_buffer(
            wgpu::TexelCopyTextureInfo {
                texture: &target,
                mip_level: 0,
                origin: wgpu::Origin3d::ZERO,
                aspect: wgpu::TextureAspect::All,
            },
            wgpu::TexelCopyBufferInfo {
                buffer: &readback,
                layout: wgpu::TexelCopyBufferLayout {
                    offset: 0,
                    bytes_per_row: Some(row_bytes),
                    rows_per_image: Some(height),
                },
            },
            wgpu::Extent3d {
                width,
                height,
                depth_or_array_layers: 1,
            },
        );
        self.queue.submit([enc.finish()]);

        let slice = readback.slice(..);
        let (tx, rx) = std::sync::mpsc::channel();
        slice.map_async(wgpu::MapMode::Read, move |r| {
            let _ = tx.send(r);
        });
        self.device
            .poll(wgpu::PollType::wait_indefinitely())
            .map_err(|e| format!("gpu poll: {e:?}"))?;
        rx.recv()
            .map_err(|_| "gpu readback channel".to_string())?
            .map_err(|e| format!("gpu map: {e:?}"))?;

        let data = slice.get_mapped_range().map_err(|e| format!("gpu range: {e:?}"))?;
        let mut out = Vec::with_capacity((width * height * 4) as usize);
        for row in 0..height {
            let start = (row * row_bytes) as usize;
            out.extend_from_slice(&data[start..start + (width * 4) as usize]);
        }
        drop(data);
        readback.unmap();
        Ok(out)
    }
}

/// Single-channel float texture of heights in meters.
/// Shift a sea-level heightfield onto the volume's datum.
///
/// Ground below the radar is legitimately negative — at KICX the valleys sit
/// over a kilometre under the antenna. Nothing downstream minds: the terrain
/// texture is `R16Float`, which is signed, and the height march's bounding
/// box is unbounded downward. Shifting toward zero even buys back a little
/// half-float precision, since f16 steps 2 m at 3 km and 1 m at 1.5 km.
///
/// Kept a free function so it can be tested without a graphics adapter —
/// CI has none, so anything reachable only through [`GpuVolume`] is untested
/// there.
fn rebase_to_datum(heights: &[f32], datum_m: f32) -> Vec<f32> {
    heights.iter().map(|&h| h - datum_m).collect()
}

/// The highest point in a rebased heightfield, used for the march's upper
/// bound.
///
/// A true maximum rather than one floored at zero. A radar standing above
/// everything around it has no ground at or above its own height, and
/// clamping that case to 0 only oversizes the box — harmless, but it hides
/// what the number means.
fn terrain_ceiling(rebased: &[f32]) -> f32 {
    rebased.iter().copied().fold(f32::MIN, f32::max)
}

fn make_terrain_texture(
    device: &wgpu::Device,
    queue: &wgpu::Queue,
    heights: &[f32],
    width: u32,
    height: u32,
) -> wgpu::TextureView {
    let size = wgpu::Extent3d {
        width,
        height,
        depth_or_array_layers: 1,
    };
    let halves: Vec<u16> = heights
        .iter()
        .map(|&h| half::f16::from_f32(h).to_bits())
        .collect();
    let tex = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("terrain"),
        size,
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        // r16float rather than r32float: 32-bit float textures are only
        // filterable behind an optional feature that plenty of mobile GPUs
        // do not have, and half precision is still ~4 m at 4 km, far finer
        // than the ~1 km spacing of the heightfield itself.
        format: wgpu::TextureFormat::R16Float,
        usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
        view_formats: &[],
    });
    queue.write_texture(
        wgpu::TexelCopyTextureInfo {
            texture: &tex,
            mip_level: 0,
            origin: wgpu::Origin3d::ZERO,
            aspect: wgpu::TextureAspect::All,
        },
        bytemuck::cast_slice(&halves),
        wgpu::TexelCopyBufferLayout {
            offset: 0,
            bytes_per_row: Some(width * 2),
            rows_per_image: Some(height),
        },
        size,
    );
    tex.create_view(&wgpu::TextureViewDescriptor::default())
}

fn make_ground_texture(
    device: &wgpu::Device,
    queue: &wgpu::Queue,
    rgba: &[u8],
    width: u32,
    height: u32,
) -> wgpu::TextureView {
    let size = wgpu::Extent3d {
        width,
        height,
        depth_or_array_layers: 1,
    };
    let tex = device.create_texture(&wgpu::TextureDescriptor {
        label: Some("ground"),
        size,
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: wgpu::TextureFormat::Rgba8Unorm,
        usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
        view_formats: &[],
    });
    queue.write_texture(
        wgpu::TexelCopyTextureInfo {
            texture: &tex,
            mip_level: 0,
            origin: wgpu::Origin3d::ZERO,
            aspect: wgpu::TextureAspect::All,
        },
        rgba,
        wgpu::TexelCopyBufferLayout {
            offset: 0,
            bytes_per_row: Some(width * 4),
            rows_per_image: Some(height),
        },
        size,
    );
    tex.create_view(&wgpu::TextureViewDescriptor::default())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn slab_grid(nxy: usize, nz: usize, fill: u8) -> Grid3D {
        let mut data = vec![0u8; nxy * nxy * nz];
        for z in 4..10 {
            for y in 10..22 {
                for x in 10..22 {
                    data[(z * nxy + y) * nxy + x] = fill;
                }
            }
        }
        Grid3D {
            nxy,
            nz,
            data,
            half_extent_m: 120_000.0,
            top_m: 16_000.0,
        }
    }

    #[test]
    fn coverage_marks_absence_and_dilates_the_index() {
        let nxy = 8;
        let nz = 4;
        let mut data = vec![0u8; nxy * nxy * nz];
        let i = (1 * nxy + 4) * nxy + 4; // one lit voxel, well inside
        data[i] = 200;
        let grid = Grid3D {
            nxy,
            nz,
            data,
            half_extent_m: 1000.0,
            top_m: 1000.0,
        };
        let packed = pack_coverage(&grid);

        // The voxel itself: its own index, fully covered.
        assert_eq!((packed[i * 2], packed[i * 2 + 1]), (200, 255));

        // Its neighbour: index borrowed so the value field is flat across
        // the boundary, but coverage 0 so it draws nothing on its own.
        let n = (1 * nxy + 4) * nxy + 5;
        assert_eq!((packed[n * 2], packed[n * 2 + 1]), (200, 0));

        // Two voxels out is beyond anything trilinear filtering can reach.
        let far = (1 * nxy + 4) * nxy + 6;
        assert_eq!((packed[far * 2], packed[far * 2 + 1]), (0, 0));
    }

    /// Issue #9. The volume holds palette *indices*, and the sampler filters
    /// them. Where data meets empty space the index used to slide from the
    /// real value down to 0, straight through the middle of the table.
    ///
    /// Here the only real data is index 128 and the palette makes 128
    /// invisible — as a velocity palette does, since 0 m/s is below any
    /// useful threshold. Indices between are bright red. So every red pixel
    /// is a reading nothing measured, and the correct output is an empty
    /// frame. Before the fix this drew a red shell around the slab.
    #[test]
    fn no_false_colour_where_data_meets_empty_space() {
        let grid = slab_grid(32, 16, 128);
        let mut pal = [[0u8; 4]; 256];
        for p in pal.iter_mut().take(120).skip(20) {
            *p = [255, 0, 0, 255];
        }
        pal[128] = [0, 0, 0, 0];

        let Ok(mut gpu) = GpuVolume::new(&grid, &pal, 4.0, false) else {
            eprintln!("no graphics adapter; skipping");
            return;
        };
        let params = FlyParams {
            eye: [0.0, -204_000.0, 22_400.0],
            yaw_deg: 0.0,
            pitch_deg: -8.0,
            fov_deg: 55.0,
            clip_min: [0.0, 0.0, 0.0],
            clip_max: [1.0, 1.0, 1.0],
        };
        let (w, h) = (240u32, 160u32);
        let px = gpu.render(&params, w, h).unwrap();

        let bogus = px
            .chunks(4)
            .filter(|p| p[3] > 8 && p[0] as i32 - p[2] as i32 > 40)
            .count();
        assert_eq!(
            bogus, 0,
            "{bogus} pixels of invented colour at the edge of the data"
        );
    }

    /// The datum fix (#56): terrain arrives above sea level, the volume's z
    /// is above the antenna, and the two used to be plotted on one axis
    /// without reconciling them.
    ///
    /// These run without a graphics adapter, unlike the render tests below,
    /// because CI has none — and this is the arithmetic that was actually
    /// wrong.
    #[test]
    fn terrain_is_shifted_onto_the_radar_datum() {
        // KICX Cedar City: antenna 3278 m, a 3500 m ridge nearby, and a
        // valley floor at 1500 m — over a kilometre below the radar.
        let alt = 3278.0;
        let out = rebase_to_datum(&[3278.0, 3500.0, 1500.0], alt);
        assert_eq!(out[0], 0.0, "ground at the radar sits at the radar");
        assert_eq!(out[1], 222.0, "a ridge above the radar stays above it");
        assert_eq!(out[2], -1778.0, "a valley below the radar goes negative");
    }

    /// The bug in one assertion: at a high site the old behaviour put the
    /// ground kilometres above where the echoes are.
    #[test]
    fn a_high_site_no_longer_floats_its_terrain() {
        let ground_asl = 3244.0;
        let alt = 3278.0;
        let unshifted = terrain_ceiling(&[ground_asl]);
        let shifted = terrain_ceiling(&rebase_to_datum(&[ground_asl], alt));
        assert!(
            unshifted > 3000.0,
            "unshifted, the ground reads 3.2 km up the volume: {unshifted}"
        );
        assert!(
            shifted.abs() < 50.0,
            "shifted, it sits at the radar's feet: {shifted}"
        );
    }

    /// A sea-level radar is the case where the bug was invisible, so it is
    /// also the case that must not change.
    #[test]
    fn a_sea_level_site_is_barely_touched() {
        let out = rebase_to_datum(&[0.0, 120.0], 26.0); // KBYX Key West
        assert_eq!(out, vec![-26.0, 94.0]);
    }

    /// The ceiling is a real maximum, not one clamped at zero: a radar on a
    /// peak has no ground level with it.
    #[test]
    fn the_ceiling_can_sit_below_the_radar() {
        let ceiling = terrain_ceiling(&rebase_to_datum(&[1500.0, 1800.0], 3278.0));
        assert_eq!(ceiling, -1478.0);
    }

    /// Flat ground vs. a ridge, through the real shader.
    ///
    /// Needs a working graphics adapter, so this is a no-op on a machine
    /// without one — including CI, which has no GPU and no software driver.
    /// Locally, `mesa-vulkan-drivers` provides one.
    #[test]
    fn terrain_changes_what_is_drawn() {
        let nxy = 32;
        let nz = 16;
        let grid = Grid3D {
            nxy,
            nz,
            data: vec![0u8; nxy * nxy * nz],
            half_extent_m: 120_000.0,
            top_m: 16_000.0,
        };
        let pal = [[0u8; 4]; 256];
        let Ok(mut gpu) = GpuVolume::new(&grid, &pal, 4.0, false) else {
            eprintln!("no graphics adapter; skipping");
            return;
        };
        gpu.set_ground(&vec![120u8; 64 * 64 * 4], 64, 64);

        let params = FlyParams {
            eye: [0.0, -200_000.0, 22_000.0],
            yaw_deg: 0.0,
            pitch_deg: -8.0,
            fov_deg: 55.0,
            clip_min: [0.0, 0.0, 0.0],
            clip_max: [1.0, 1.0, 1.0],
        };
        let (w, h) = (160u32, 120u32);
        let flat = gpu.render(&params, w, h).unwrap();

        // A 3 km ridge across the middle.
        let n = 64usize;
        let mut heights = vec![0f32; n * n];
        for ty in 0..n {
            for tx in 0..n {
                let fy = ty as f32 / n as f32 - 0.5;
                heights[ty * n + tx] = 3000.0 * (-(fy * fy) / 0.01).exp();
            }
        }
        // Synthetic heights already measured from the radar, so no shift.
        gpu.set_terrain(&heights, n as u32, n as u32, 0.0);
        let hilly = gpu.render(&params, w, h).unwrap();

        let changed = flat
            .chunks(4)
            .zip(hilly.chunks(4))
            .filter(|(a, b)| a[0].abs_diff(b[0]) as u32 > 4)
            .count();
        assert!(
            changed > (w * h) as usize / 20,
            "a 3 km ridge should visibly change the frame, only {changed} pixels moved",
        );

        // And turning it off puts the flat plane back.
        gpu.clear_terrain();
        let again = gpu.render(&params, w, h).unwrap();
        assert_eq!(flat, again, "clear_terrain must restore the flat ground");
    }

    /// The cone of silence haze, through the real shader. Same adapter
    /// caveat as above: a no-op where there is no GPU.
    #[test]
    fn the_cone_of_silence_stands_on_the_radar() {
        let nxy = 32;
        let nz = 16;
        let grid = Grid3D {
            nxy,
            nz,
            data: vec![0u8; nxy * nxy * nz],
            half_extent_m: 120_000.0,
            top_m: 16_000.0,
        };
        let Ok(mut gpu) = GpuVolume::new(&grid, &[[0u8; 4]; 256], 4.0, false) else {
            eprintln!("no graphics adapter; skipping");
            return;
        };
        let params = FlyParams {
            eye: [0.0, -200_000.0, 22_000.0],
            yaw_deg: 0.0,
            pitch_deg: -2.0,
            fov_deg: 55.0,
            clip_min: [0.0, 0.0, 0.0],
            clip_max: [1.0, 1.0, 1.0],
        };
        let (w, h) = (160u32, 120u32);
        let off = gpu.render(&params, w, h).unwrap();

        gpu.set_beam_limits(19.5);
        gpu.set_show_cone(true);
        let on = gpu.render(&params, w, h).unwrap();
        assert_ne!(off, on, "the cone should be visible once switched on");

        // It stands over the radar, so the middle of the frame gains far more
        // haze than the edges — the wrong way round would mean the angle test
        // is inverted and it is the scanned region being shaded instead.
        let lit = |x0: u32, x1: u32| -> u32 {
            let mut sum = 0u32;
            for y in 0..h / 2 {
                for x in x0..x1 {
                    let i = ((y * w + x) * 4) as usize;
                    sum += (on[i + 2] as i32 - off[i + 2] as i32).max(0) as u32;
                }
            }
            sum
        };
        let middle = lit(w / 2 - 12, w / 2 + 12);
        let edge = lit(0, 24);
        assert!(
            middle > edge * 4,
            "the cone belongs over the radar: middle {middle} vs edge {edge}",
        );
    }
}
