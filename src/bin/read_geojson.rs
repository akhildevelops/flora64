use geojson::{FeatureCollection, GeoJson};
use serde_json;
use std::{
    fs::OpenOptions,
    io::{BufReader, BufWriter, Read, stdout},
    path::PathBuf,
    str::FromStr,
};

pub fn main() {
    let mut args = std::env::args();
    _ = args.next();
    let mut fc = FeatureCollection::default();
    while let Some(file_path) = args.next() {
        let path = PathBuf::from_str(&file_path).unwrap();
        let file = OpenOptions::new().read(true).open(path).unwrap();
        let mut buffer = vec![];
        _ = BufReader::new(file).read_to_end(&mut buffer);
        let _b: &[u8] = buffer.as_ref();
        let _content = unsafe { str::from_utf8_unchecked(_b) };
        let gj = GeoJson::from_str(_content).unwrap();
        match gj {
            GeoJson::FeatureCollection(_fc) => {
                fc.features.extend_from_slice(&_fc.features);
            }
            _ => panic!(),
        }
    }
    let all_geojson = OpenOptions::new()
        .create(true)
        .write(true)
        .open("./all.geojson")
        .unwrap();

    let bw = BufWriter::new(all_geojson);
    serde_json::to_writer(bw, &fc).unwrap();
}
