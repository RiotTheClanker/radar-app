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
    g0: vec4f,
};

@group(0) @binding(0) var<uniform> u: U;
@group(0) @binding(1) var vol: texture_3d<f32>;
@group(0) @binding(2) var vol_samp: sampler;
@group(0) @binding(3) var pal: texture_2d<f32>;
@group(0) @binding(4) var pal_samp: sampler;
@group(0) @binding(5) var ground: texture_2d<f32>;

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

    // Basemap on the z=0 plane, so you can tell where you are. Sampled
    // independently of the clip box; the volume composites over it.
    var ground_col = vec4f(0.0);
    if (u.g0.x > 0.5 && dir.z < -0.00001) {
        let tg = -u.eye.z / dir.z;
        if (tg > 0.0) {
            let gp = u.eye.xyz + dir * tg;
            if (abs(gp.x) <= ex && abs(gp.y) <= ex) {
                let guv = vec2f((gp.x + ex) / (2.0 * ex),
                                1.0 - (gp.y + ex) / (2.0 * ex));
                ground_col = textureSampleLevel(ground, pal_samp, guv, 0.0);
            }
        }
    }
    // Clip planes are normalized [0,1] fractions of the volume box.
    let bmin = vec3f(-ex, -ex, 0.0) + u.cmin.xyz * vec3f(2.0 * ex, 2.0 * ex, top);
    let bmax = vec3f(-ex, -ex, 0.0) + u.cmax.xyz * vec3f(2.0 * ex, 2.0 * ex, top);

    let hit = ray_box(u.eye.xyz, dir, bmin, bmax);
    var t = max(hit.x, 0.0);
    let t1 = hit.y;

    var acc = vec3f(0.0);
    var alpha = 0.0;
    let step = u.p1.x;
    let alpha_scale = u.p1.y;

    for (var i = 0; i < 1200; i++) {
        if (t1 <= t) { break; }
        if (t >= t1 || alpha >= 0.97) { break; }
        let p = u.eye.xyz + dir * t;
        let tc = vec3f((p.x + ex) / (2.0 * ex), (p.y + ex) / (2.0 * ex), p.z / top);
        let raw = textureSampleLevel(vol, vol_samp, tc, 0.0).r;
        let c = textureSampleLevel(pal, pal_samp, vec2f(raw * 0.99609375 + 0.001953125, 0.5), 0.0);
        if (c.a > 0.0) {
            let a = min(c.a * alpha_scale * step, 0.9) * (1.0 - alpha);
            acc += c.rgb * a;
            alpha += a;
        }
        t += step;
    }

    // Composite the basemap underneath whatever the volume left translucent.
    let ga = ground_col.a * (1.0 - alpha);
    return vec4f(acc + ground_col.rgb * ga, alpha + ga);
}
"#;

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
    pub fn new(grid: &Grid3D, palette: &[[u8; 4]; 256], z_exaggeration: f32) -> Result<Self, String> {
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
            format: wgpu::TextureFormat::R8Unorm,
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
            &grid.data,
            wgpu::TexelCopyBufferLayout {
                offset: 0,
                bytes_per_row: Some(grid.nxy as u32),
                rows_per_image: Some(grid.nxy as u32),
            },
            size,
        );
        let vol_view = vol_tex.create_view(&wgpu::TextureViewDescriptor::default());
        let vol_samp = device.create_sampler(&wgpu::SamplerDescriptor {
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
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
