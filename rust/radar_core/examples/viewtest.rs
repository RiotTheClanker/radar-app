//! Render a zoomed viewport box to check sharpness of the view renderer.
//! Usage: cargo run --example viewtest -- <l3-file> <out.png> [n s e w]

fn main() {
    let mut args = std::env::args().skip(1);
    let path = args.next().expect("input file");
    let out = args.next().expect("output png");
    let n: f64 = args.next().map(|s| s.parse().unwrap()).unwrap_or(36.6);
    let s: f64 = args.next().map(|s| s.parse().unwrap()).unwrap_or(35.6);
    let e: f64 = args.next().map(|s| s.parse().unwrap()).unwrap_or(-96.6);
    let w: f64 = args.next().map(|s| s.parse().unwrap()).unwrap_or(-97.9);

    let data = std::fs::read(&path).expect("read");
    let frame =
        radar_core::api::render_level3_view(data, n, s, e, w, 1400, 1100).expect("render view");
    std::fs::write(&out, &frame.png).expect("write png");
    println!(
        "wrote {} ({}x{}) box N{n} S{s} E{e} W{w}",
        out, frame.width, frame.height
    );
}
