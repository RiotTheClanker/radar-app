use thiserror::Error;

#[derive(Error, Debug)]
pub enum RadarError {
    #[error("file too short: needed {needed} bytes at offset {offset}, have {len}")]
    Truncated {
        needed: usize,
        offset: usize,
        len: usize,
    },
    #[error("could not locate Level 3 message header (not a NIDS file?)")]
    NoHeader,
    #[error("unsupported product code {0}")]
    UnsupportedProduct(i16),
    #[error("no radial data packet found in symbology block")]
    NoRadialData,
    #[error("decompression failed: {0}")]
    Decompress(String),
}

pub type Result<T> = std::result::Result<T, RadarError>;
