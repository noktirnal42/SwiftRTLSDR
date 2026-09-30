# Decoder test data

| File | What it is | Where it came from |
|---|---|---|
| `modes-surveillance-vectors.txt` | DF4/DF5 replies and their decoded altitude / squawk | Built by `Tools/generate-modes-vectors.py`, decoded by pyModeS 3.6.0 |
| `cpr-vectors.txt` | Airborne CPR pairs and local fixes with their positions | pyModeS 3.6.0 on random inputs |
| `uat-reed-solomon-vectors.txt` | Clean and corrupted codewords for the three UAT codes, and what Phil Karn's decoder made of them | `Tools/generate-uat-rs-vectors.py` (reedsolo for parity, Karn's decoder from dump978's `fec/`) |
| `dump978-sample-data.txt` | 1143 real UAT frames (439 downlink, 704 uplink), after error correction, in dump978's text format | `sample-data.txt.gz` from dump978 by Oliver Jowett (GPL-2.0-or-later), https://github.com/mutability/dump978 |
| `dump978-sample-fields.txt` | The fields dump978's own decoder extracts from each of those frames | `Tools/uat-oracle-fields.c`, built against dump978's `uat_decode.c` |
| `dump978-sample-nexrad.txt` | The NEXRAD blocks in those frames | dump978's `extract_nexrad` |
| `ism-code-vectors.txt` | Bit buffers (rtl_433's `{bits}hex` notation) that the ISM decoders were given while decoding real recordings, and rtl_433 25.02's JSON for each (`rtl_433 -y`, without the time field) | `Tools/generate-ism-vectors.py` on the recordings of https://github.com/merbanan/rtl_433_tests (not included: that repository has no licence) |
| `lrpt-scene.cadu` | Six Meteor-M LRPT transfer frames carrying 16 lines of a synthetic three-channel scene, MSU-MR compressed | `Tools/lrpt-encode.py lrpt-scene.cadu --lines 16 --seed 21` (written for this package; reedsolo for parity) |
| `lrpt-scene-blocks.txt` | Mean and standard deviation of every 8×8 block of that scene's source images | The same run's `--scene-out` images |
