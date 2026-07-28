// Debug the GLM reader internals against h5py ground truth.
fn main() {
    let data = std::fs::read(std::env::args().nth(1).unwrap()).unwrap();
    radar_core::glm::debug_dump(&data);
}
