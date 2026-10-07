# ASN.1 modules for the ATN

`atn-cpdlc.asn` (ICAO Doc 9705 CPDLC and the protected-mode CPDLC PDUs) and `atn-cm.asn` (Context Management) are copied unchanged
from the Wireshark project (https://github.com/wireshark/wireshark, `epan/dissectors/asn1/atn-cpdlc/` and `.../atn-cm/`,
GPL-2.0-or-later), which took them from ICAO Doc 9705 Sub-Volume IV. They are the schema `RTLSDRDecoders/ATN` decodes with.
`Tools/generate-asn1-modules.py` embeds them in `Sources/RTLSDRDecoders/ATN/ATNModules.swift`; run it after changing one.
