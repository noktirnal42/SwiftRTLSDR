// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRDecoders

/// The packaged schema with its deviations, and messages made of it.
enum ATNFixtures {
    static let schema = try! ATNSchema.make()

    static func header(id: Int, reference: Int? = nil, acknowledgement: String = "notRequired") -> ASN1Value {
        var fields = [ASN1Field(name: "messageIdNumber", value: .integer(id))]
        if let reference { fields.append(ASN1Field(name: "messageRefNumber", value: .integer(reference))) }
        fields.append(ASN1Field(name: "dateTime", value: .sequence([
            ASN1Field(name: "date", value: .sequence([ASN1Field(name: "year", value: .integer(2025)), ASN1Field(name: "month", value: .integer(10)),
                                                       ASN1Field(name: "day", value: .integer(7))])),
            ASN1Field(name: "timehhmmss", value: .sequence([
                ASN1Field(name: "hoursminutes", value: .sequence([ASN1Field(name: "hours", value: .integer(14)), ASN1Field(name: "minutes", value: .integer(5))])),
                ASN1Field(name: "seconds", value: .integer(33)),
            ])),
        ])))
        fields.append(ASN1Field(name: "logicalAck", value: .enumerated(name: acknowledgement, value: acknowledgement == "required" ? 0 : 1)))
        return .sequence(fields)
    }

    static func atcMessage(id: Int, reference: Int? = nil, elements: [ASN1Value]) -> ASN1Value {
        .sequence([ASN1Field(name: "header", value: header(id: id, reference: reference)),
                   ASN1Field(name: "messageData", value: .sequence([ASN1Field(name: "elementIds", value: .list(elements))]))])
    }

    /// A downlink asking to climb to a level in feet and giving free text.
    static var downlink: ASN1Value {
        atcMessage(id: 7, reference: 3, elements: [
            .choice(name: "dM9Level", .choice(name: "singleLevel", .choice(name: "levelFeet", .integer(4318)))),
            .choice(name: "dM67FreeText", .string("REQUEST DIRECT")),
        ])
    }

    static var uplink: ASN1Value { atcMessage(id: 12, elements: [.choice(name: "uM0NULL", .null), .choice(name: "uM3NULL", .null)]) }

    static func unwrapped(_ message: ASN1Value, uplink: Bool) throws -> [UInt8] {
        try ATNBuilder.fullyEncodedData(schema: schema, context: 3, ATNBuilder.protectedCPDLC(schema: schema, uplink: uplink, message: message))
    }

    /// The information field of an AVLC frame carrying `transport` in one X.25 data packet behind a compressed CLNP header.
    static func packet(_ transport: [UInt8], type: Int = 0, reference: Int = 5, sent: Int = 0) -> [UInt8] {
        X25Packet.data(channel: 1, sent: sent, received: 0, ATNBuilder.compressedCLNP(type: type, reference: reference, pduID: 1, transport))
    }

    static let aircraft: UInt32 = 0x4B1A2C, ground: UInt32 = 0x1A02A1
}

struct X25Tests {
    @Test func dataPacketsCarryTheirSequenceNumbersAndTheMoreBit() throws {
        let bytes = X25Packet.data(channel: 9, sent: 5, received: 3, more: true, [1, 2, 3])
        let packet = try #require(X25Packet(bytes))
        #expect(packet.logicalChannel == 9 && packet.userData == [1, 2, 3])
        #expect(packet.kind == .data(sent: 5, received: 3, more: true))
    }

    @Test func callPacketsCarryAddressesFacilitiesAndTheCompressionIdentifier() throws {
        let request = X25Packet.call(accepted: false, channel: 2, called: "4b1a2c", calling: "1a02a1", facilities: [0x42, 0x0A, 0x0A], compression: 1, [0x81, 0x00])
        let parsed = try #require(X25Packet(request))
        #expect(parsed.kind == .callRequest && parsed.called == "4b1a2c" && parsed.calling == "1a02a1")
        #expect(parsed.facilities == [0x42, 0x0A, 0x0A] && parsed.compression == 1 && parsed.userData == [0x81, 0x00])
        let accepted = try #require(X25Packet(X25Packet.call(accepted: true, channel: 2, called: "1a02a1", calling: "4b1a2c", compression: 0)))
        #expect(accepted.kind == .callAccepted && accepted.compression == 0 && accepted.userData.isEmpty)
        // An address of an odd number of digits packs into whole octets.
        let odd = try #require(X25Packet(X25Packet.call(accepted: false, channel: 1, called: "123", calling: "45678")))
        #expect(odd.called == "123" && odd.calling == "45678")
    }

    @Test func controlPacketsAreToldApart() throws {
        let clear = try #require(X25Packet([0x10, 1, 0x13, 0x09, 0x70]))
        #expect(clear.kind == .clearRequest && clear.cause == 0x09 && clear.diagnostic == 0x70)
        #expect(try #require(X25Packet([0x10, 1, 0x17])).kind == .clearConfirm)
        #expect(try #require(X25Packet([0x10, 1, 0x1B, 0x03])).kind == .resetRequest)
        #expect(try #require(X25Packet([0x10, 0, 0xFB, 0x07])).kind == .restartRequest)       // not a reset request, though it ends in 0x1B
        #expect(try #require(X25Packet([0x10, 0, 0xFF])).kind == .restartConfirm)
        #expect(try #require(X25Packet([0x10, 1, 0xA1])).kind == .receiveReady(received: 5))
        #expect(try #require(X25Packet([0x10, 1, 0x69])).kind == .reject(received: 3))
        #expect(try #require(X25Packet([0x10, 0, 0xF1, 0x20])).kind == .diagnostic)
    }

    @Test func otherInformationFieldsAreNotX25() {
        #expect(X25Packet([0xFF, 0xFF, 0x01, 0x02]) == nil)             // ACARS
        #expect(X25Packet([0x10, 1]) == nil && X25Packet([]) == nil)
        #expect(X25Packet([0x10, 1, 0x1D]) == nil)                      // a packet type that does not exist
        #expect(X25Packet([0x10, 1, 0x0B, 0x66, 0x12]) == nil)           // a call request cut off
    }
}

struct CLNPAndTransportTests {
    @Test func compressedHeadersGrowWithTheirFlags() throws {
        let plain = try #require(ATNDecoder.compressedCLNP(ATNBuilder.compressedCLNP(type: 0, priority: 3, flags: 0x10, reference: 0x45, [9])))
        #expect(plain.0.compressed && plain.0.priority == 3 && plain.0.flags == 0x10 && plain.0.localReference == 0x45 && plain.0.pduID == nil && plain.1 == [9])
        let extended = try #require(ATNDecoder.compressedCLNP(ATNBuilder.compressedCLNP(type: 1, reference: 0x1234, pduID: 0xBEEF, [9])))
        #expect(extended.0.localReference == 0x1234 && extended.0.pduID == 0xBEEF && extended.0.segmentationPermitted)
        let segment = try #require(ATNDecoder.compressedCLNP(ATNBuilder.compressedCLNP(type: 7, reference: 2, pduID: 7, offset: 10, total: 30, [1, 2, 3])))
        #expect(segment.0.offset == 10 && segment.0.totalLength == 30 && segment.0.moreSegments && segment.1 == [1, 2, 3])
        // A segment that would run past its own total length is not one.
        #expect(ATNDecoder.compressedCLNP(ATNBuilder.compressedCLNP(type: 6, reference: 2, pduID: 7, offset: 29, total: 30, [1, 2, 3])) == nil)
        #expect(ATNDecoder.compressedCLNP([0x00, 0x00, 0x00]) == nil)
    }

    @Test func fullHeadersGiveTheirAddressesAndSegmentationPart() throws {
        let destination: [UInt8] = [0x47, 0x00, 0x27, 0x81, 1, 2], source: [UInt8] = [0x47, 0x00, 0x27, 0x81, 3, 4]
        let plain = try #require(ATNDecoder.fullCLNP(ATNBuilder.fullCLNP(destination: destination, source: source, lifetime: 30, [7, 8])))
        #expect(!plain.0.compressed && plain.0.destination == destination && plain.0.source == source && plain.0.lifetimeSeconds == 15 && plain.1 == [7, 8])
        let segmented = try #require(ATNDecoder.fullCLNP(ATNBuilder.fullCLNP(destination: destination, source: source, segmentation: (id: 9, offset: 4, total: 10, more: true), [1])))
        #expect(segmented.0.pduID == 9 && segmented.0.offset == 4 && segmented.0.totalLength == 10 && segmented.0.moreSegments)
        #expect(ATNDecoder.fullCLNP([0x81, 9, 1]) == nil && ATNDecoder.fullCLNP([0x81, 255, 1, 0, 0x1C, 0, 0, 0, 0]) == nil)
    }

    @Test func transportPDUsOfEveryKind() throws {
        let data = try #require(ATNDecoder.cotp(ATNBuilder.cotpData(destinationReference: 0x1234, sequence: 5, endOfTSDU: true, [1, 2])))
        #expect(data.0.code == 0xF0 && data.0.destinationReference == 0x1234 && data.0.sequence == 5 && data.0.endOfTSDU && data.2 && data.1 == 5)
        let request = try #require(ATNDecoder.cotp(ATNBuilder.cotpConnect(confirm: false, destinationReference: 0, sourceReference: 7, parameters: [(0xC0, [0x0B]), (0xC3, [1, 2])], [0x55])))
        #expect(request.0.name == "Connect Request" && request.0.sourceReference == 7 && request.0.classOrReason == 4 && request.0.parameters.count == 2)
        #expect(request.0.parameters[1].code == 0xC3 && request.0.parameters[1].value == [1, 2] && request.2)
        let disconnect = try #require(ATNDecoder.cotp(ATNBuilder.cotpDisconnect(destinationReference: 3, sourceReference: 4, reason: 2)))
        #expect(disconnect.0.name == "Disconnect Request" && disconnect.0.classOrReason == 2)
        // An acknowledgement has no user data; a data TPDU in the extended format is told by an odd header length.
        let ack = try #require(ATNDecoder.cotp([0x04, 0x60, 0x00, 0x09, 0x45]))
        #expect(ack.0.name == "Data Ack" && ack.0.sequence == 0x45 && !ack.2)
        let extended = try #require(ATNDecoder.cotp([0x07, 0xF0, 0x00, 0x09, 0x80, 0x00, 0x00, 0x01, 0xAA]))
        #expect(extended.0.extended && extended.0.sequence == 1 && extended.0.endOfTSDU && extended.1 == 8)
        #expect(ATNDecoder.cotp([0x02, 0xF0]) == nil && ATNDecoder.cotp([0xFF, 0, 0, 0, 0]) == nil && ATNDecoder.cotp([0x03, 0x12, 0, 0, 0]) == nil)
    }
}

struct ATNStackTests {
    private let fixtures = ATNFixtures.self

    private func decoder() -> ATNDecoder { ATNDecoder(schema: ATNFixtures.schema) }

    private func decode(_ decoder: ATNDecoder, _ information: [UInt8], fromAircraft: Bool = true) -> ATNMessage? {
        decoder.decode(information: information, source: fromAircraft ? ATNFixtures.aircraft : ATNFixtures.ground,
                       destination: fromAircraft ? ATNFixtures.ground : ATNFixtures.aircraft, fromAircraft: fromAircraft)
    }

    @Test func aCPDLCDownlinkInDataReadsThroughEveryLayer() throws {
        let transport = ATNBuilder.cotpData(destinationReference: 40, sequence: 3, try fixtures.unwrapped(ATNFixtures.downlink, uplink: false))
        let message = try #require(decode(decoder(), fixtures.packet(transport)))
        #expect(message.x25?.kind == .data(sent: 0, received: 0, more: false) && message.clnp?.compressed == true)
        #expect(message.transport.first?.sequence == 3 && message.applicationType == .cpdlc && message.applicationPDU == "ATCDownlinkMessage")
        #expect(message.application == ATNFixtures.downlink)
    }

    @Test func anUplinkWithAFullHeaderAndAnAssociationRequestReads() throws {
        let pdu = try ATNBuilder.protectedCPDLC(schema: ATNFixtures.schema, uplink: true, message: ATNFixtures.uplink)
        let apdu = try ATNBuilder.associationRequest(schema: ATNFixtures.schema, qualifier: 22, userData: pdu)
        let transport = ATNBuilder.cotpConnect(confirm: false, destinationReference: 0, sourceReference: 9, ATNBuilder.shortSession(0xE8, apdu))
        let network = ATNBuilder.fullCLNP(destination: [0x47, 0, 0x27, 0x81, 1, 2], source: [0x47, 0, 0x27, 0x81, 3, 4], transport)
        let message = try #require(decode(decoder(), X25Packet.data(channel: 1, sent: 0, received: 0, network), fromAircraft: false))
        #expect(message.clnp?.compressed == false && message.session == "Short Connect")
        if case .choice("aarq", _)? = message.acse {} else { Issue.record("an association request, not \(String(describing: message.acse))") }
        #expect(message.application == ATNFixtures.uplink && message.applicationPDU == "ATCUplinkMessage")
    }

    @Test func contextManagementInAnAssociationRequestReads() throws {
        let logon = ASN1Value.choice(name: "cmLogonRequest", .sequence([
            ASN1Field(name: "aircraftFlightIdentification", value: .string("BAW123")),
            ASN1Field(name: "cMLongTSAP", value: .sequence([ASN1Field(name: "rDP", value: .octetString([1, 2, 3, 4, 5])),
                                                           ASN1Field(name: "shortTsap", value: .sequence([ASN1Field(name: "locSysNselTsel", value: .octetString(Array(repeating: 7, count: 10)))]))])),
            ASN1Field(name: "airportDeparture", value: .string("EGLL")),
        ]))
        let apdu = try ATNBuilder.associationRequest(schema: ATNFixtures.schema, qualifier: 1, userData: try ATNFixtures.schema.encode("CMAircraftMessage", logon))
        let transport = ATNBuilder.cotpConnect(confirm: false, destinationReference: 0, sourceReference: 77, ATNBuilder.shortSession(0xE8, apdu))
        let message = try #require(decode(decoder(), fixtures.packet(transport)))
        #expect(message.applicationType == .contextManagement && message.application == logon)
        let decoded = decoder()
        let text = decoded.lines(for: try #require(decode(decoded, fixtures.packet(transport)))).joined(separator: "\n")
        #expect(text.contains("CM downlink: logon request") && text.contains("BAW123") && text.contains("EGLL"))
    }

    @Test func anAbortInADisconnectRequestReads() throws {
        let reason = ASN1Value.choice(name: "abortProvider", .enumerated(name: "timer-expired", value: 0))
        let apdu = try ATNBuilder.abort(schema: ATNFixtures.schema, userData: try ATNFixtures.schema.encode("ProtectedAircraftPDUs", reason))
        let message = try #require(decode(decoder(), fixtures.packet(ATNBuilder.cotpDisconnect(destinationReference: 5, sourceReference: 6, reason: 0, apdu))))
        #expect(message.transport.first?.name == "Disconnect Request" && message.application == reason)
    }

    @Test func aPacketSplitInTwoIsJoinedBeforeItIsRead() throws {
        let transport = ATNBuilder.cotpData(destinationReference: 40, sequence: 3, try fixtures.unwrapped(ATNFixtures.downlink, uplink: false))
        let network = ATNBuilder.compressedCLNP(type: 0, reference: 5, transport)
        let cut = network.count / 2
        let decoder = decoder()
        let first = try #require(decode(decoder, X25Packet.data(channel: 1, sent: 0, received: 0, more: true, Array(network[..<cut]))))
        #expect(first.application == nil && first.note?.contains("more to come") == true)
        let second = try #require(decode(decoder, X25Packet.data(channel: 1, sent: 1, received: 0, Array(network[cut...]))))
        #expect(second.application == ATNFixtures.downlink)
    }

    @Test func clnpSegmentsAndTransportFragmentsAreJoinedToo() throws {
        let user = try fixtures.unwrapped(ATNFixtures.downlink, uplink: false)
        // Transport: two data TPDUs, the second with the end-of-TSDU bit.
        let half = user.count / 2
        let decoder = decoder()
        let one = try #require(decode(decoder, fixtures.packet(ATNBuilder.cotpData(destinationReference: 9, sequence: 0, endOfTSDU: false, Array(user[..<half])))))
        #expect(one.application == nil && one.note?.contains("more to come") == true)
        let two = try #require(decode(decoder, fixtures.packet(ATNBuilder.cotpData(destinationReference: 9, sequence: 1, endOfTSDU: true, Array(user[half...])), sent: 1)))
        #expect(two.application == ATNFixtures.downlink)
        // Network: the same TSDU in two CLNP segments, found by their offsets whichever comes first.
        let tpdu = ATNBuilder.cotpData(destinationReference: 11, sequence: 0, user)
        let cut = tpdu.count / 3
        let late = ATNBuilder.compressedCLNP(type: 0xA, reference: 3, pduID: 42, offset: cut, total: tpdu.count, Array(tpdu[cut...]))
        let early = ATNBuilder.compressedCLNP(type: 7, reference: 3, pduID: 42, offset: 0, total: tpdu.count, Array(tpdu[..<cut]))
        let segments = self.decoder()
        let a = try #require(decode(segments, X25Packet.data(channel: 1, sent: 0, received: 0, late)))
        #expect(a.application == nil && a.note?.contains("segment") == true)
        let b = try #require(decode(segments, X25Packet.data(channel: 1, sent: 1, received: 0, early)))
        #expect(b.application == ATNFixtures.downlink)
    }

    @Test func aConnectionRemembersWhichApplicationItIsFor() throws {
        // Find a context management message from the ground that also happens to read as a CPDLC PDU: without the connection
        // to tell them apart, a decoder takes it for CPDLC (as dumpvdl2 does).
        var values = ASN1RandomValues(schema: ATNFixtures.schema, seed: 3)
        values.useExtensions = false
        let bare = ATNDecoder(schema: ATNFixtures.schema)
        var found: (message: ASN1Value, bytes: [UInt8])?
        for _ in 0..<500 {
            let candidate = try values.value(try ATNFixtures.schema.type(named: "CMGroundMessage"))
            let bytes = try ATNFixtures.schema.encode("CMGroundMessage", candidate)
            let data = try ATNBuilder.fullyEncodedData(schema: ATNFixtures.schema, context: 3, bytes)
            let probe = try #require(decode(bare, fixtures.packet(ATNBuilder.cotpData(destinationReference: 1, sequence: 0, data)), fromAircraft: false))
            if probe.applicationType == .cpdlc { found = (candidate, data); break }
        }
        let ambiguous = try #require(found, "no ambiguous message in 500 tries")
        // The aircraft asks for context management (qualifier 1), the ground confirms, the data follows.
        let decoder = decoder()
        let logon = try ATNFixtures.schema.encode("CMAircraftMessage", .choice(name: "cmAbortReason", .enumerated(name: "undefined-error", value: 0)))
        let request = try ATNBuilder.associationRequest(schema: ATNFixtures.schema, qualifier: 1, userData: logon)
        _ = decode(decoder, fixtures.packet(ATNBuilder.cotpConnect(confirm: false, destinationReference: 0, sourceReference: 300, ATNBuilder.shortSession(0xE8, request))))
        _ = decode(decoder, fixtures.packet(ATNBuilder.cotpConnect(confirm: true, destinationReference: 300, sourceReference: 400)), fromAircraft: false)
        let data = try #require(decode(decoder, fixtures.packet(ATNBuilder.cotpData(destinationReference: 300, sequence: 0, ambiguous.bytes), sent: 1), fromAircraft: false))
        #expect(data.applicationType == .contextManagement && data.application == ambiguous.message)
        // After the disconnect the connection is forgotten.
        _ = decode(decoder, fixtures.packet(ATNBuilder.cotpDisconnect(destinationReference: 400, sourceReference: 300, reason: 0)))
        let after = try #require(decode(decoder, fixtures.packet(ATNBuilder.cotpData(destinationReference: 300, sequence: 0, ambiguous.bytes)), fromAircraft: false))
        #expect(after.applicationType == .cpdlc)
    }

    @Test func otherLayersAreNamedNotGuessed() throws {
        let decoder = decoder()
        // ES-IS, IDRP and an unknown protocol; a transport PDU that is not one; garbage inside a good frame.
        #expect(try #require(decode(decoder, X25Packet.data(channel: 1, sent: 0, received: 0, [0x82, 9, 1, 0, 4, 0, 60, 0, 0]))).esis?.name == "IS Hello")
        #expect(try #require(decode(decoder, X25Packet.data(channel: 1, sent: 0, received: 0, [0x85, 1, 2, 3]))).note?.contains("IDRP") == true)
        #expect(try #require(decode(decoder, X25Packet.data(channel: 1, sent: 0, received: 0, [0xE5, 1, 2, 3, 4]))).note?.contains("unknown protocol") == true)
        #expect(try #require(decode(decoder, fixtures.packet([0x03, 0x12, 0, 0, 0]))).note?.contains("transport") == true)
        let junk = try #require(decode(decoder, fixtures.packet(ATNBuilder.cotpData(destinationReference: 1, sequence: 0, [0x5A, 0x5A, 0x5A, 0x5A, 0x5A]))))
        #expect(junk.application == nil && !junk.undecoded.isEmpty)
        #expect(decode(decoder, [0xFF, 0xFF, 0x01, 0x00]) == nil)
    }

    @Test func randomBytesNeverTrapTheDecoder() {
        var generator = SplitMix64(state: 12)
        let decoder = decoder()
        for _ in 0..<3_000 {
            var bytes = (0..<Int.random(in: 0...120, using: &generator)).map { _ in UInt8.random(in: 0...255, using: &generator) }
            if bytes.count > 2 { bytes[0] = 0x10 | UInt8.random(in: 0...15, using: &generator) }          // look like X.25 more often
            _ = decode(decoder, bytes)
            _ = decode(decoder, bytes, fromAircraft: false)
        }
    }

    @Test func textIsTheElementsWordingAndItsParametersWithUnits() throws {
        let decoder = decoder()
        let transport = ATNBuilder.cotpData(destinationReference: 40, sequence: 3, try fixtures.unwrapped(ATNFixtures.downlink, uplink: false))
        let lines = decoder.lines(for: try #require(decode(decoder, fixtures.packet(transport))))
        let text = lines.joined(separator: "\n")
        #expect(text.contains("CPDLC downlink 7 (reply to 3)  2025-10-07 14:05:33Z"))
        #expect(text.contains("dM9 REQUEST CLIMB TO [level]: singleLevel: levelFeet: 43180 Feet"), "\(text)")      // 4318 × 10, from the schema's unit comment
        #expect(text.contains("dM67 [freetext]: \"REQUEST DIRECT\""))
        let uplink = decoder.text(of: ATNMessage(application: ATNFixtures.uplink, applicationPDU: "ATCUplinkMessage"))
        #expect(uplink.contains { $0.contains("uM0 UNABLE") } && uplink.contains { $0.contains("uM3 ROGER") })
    }

    @Test func jsonHasTheLayersAndTheMessage() throws {
        let decoder = decoder()
        let transport = ATNBuilder.cotpData(destinationReference: 40, sequence: 3, try fixtures.unwrapped(ATNFixtures.uplink, uplink: true))
        let message = try #require(decode(decoder, fixtures.packet(transport), fromAircraft: false))
        let object = try #require(JSONSerialization.jsonObject(with: Data(message.json(frequencyHz: 136_975_000).utf8)) as? [String: Any])
        #expect((object["x25"] as? [String: Any])?["channel"] as? Int == 1)
        #expect((object["clnp"] as? [String: Any])?["compressed"] as? Bool == true)
        #expect(((object["cotp"] as? [[String: Any]])?.first)?["dst_ref"] as? Int == 40)
        let cpdlc = try #require(object["cpdlc"] as? [String: Any])
        #expect(cpdlc["pdu"] as? String == "ATCUplinkMessage")
        #expect(object["freq"] as? Double == 136.975)
    }
}

extension ATNMessage {
    init(application: ASN1Value, applicationPDU: String) {
        self.init()
        self.application = application
        self.applicationPDU = applicationPDU
        applicationType = .cpdlc
    }
}
