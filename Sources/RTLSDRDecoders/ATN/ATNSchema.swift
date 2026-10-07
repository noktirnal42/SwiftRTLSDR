// SPDX-License-Identifier: GPL-2.0-or-later
//
// The ATN's ASN.1 schema as this package decodes it: the modules of Tools/asn1 and the few places where live traffic (as
// dumpvdl2 decodes it, by asn1c from ICAO's text) does not follow them. Written for this package.
import Foundation

public enum ATNSchema {
    /// The packaged modules with two deviations from Wireshark's copy applied, both found by decoding random messages with
    /// dumpvdl2 (which decodes live traffic) and this package and comparing:
    ///
    /// * `TrafficType` has no `noneSpecified (0)`; its first value is `oppositeDirection` ("DUE TO [traffic type] TRAFFIC").
    ///   Wireshark's copy has the extra value, which shifts the others.
    /// * `LevelSpeed` has one `speed`, a `Speed` ("AT AND MAINTAIN [level] AT [speed]"), not the two of `SpeedSpeed`.
    public static func make() throws -> ASN1Schema {
        var schema = try ASN1Schema(modules: ATNModules.all)
        let traffic = ["oppositeDirection", "sameDirection", "converging", "crossing", "diverging"]
        schema.replace(type: "PMCPDLCMessageSetVersion1.TrafficType", with: .enumerated(ASN1Enumerated(
            root: traffic.enumerated().map { (name: $0.element, value: $0.offset) }, additions: [], extensible: true)))
        try schema.replaceComponent(of: "PMCPDLCMessageSetVersion1.LevelSpeed", named: "speed", with: .reference("PMCPDLCMessageSetVersion1.Speed"))
        return schema
    }
}
