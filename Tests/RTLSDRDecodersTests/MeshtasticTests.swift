// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation
import Testing
@testable import RTLSDRDecoders

struct AESTests {
    @Test func blocksMatchFIPS197AppendixC() throws {
        let plain = bytes(hex: "00112233445566778899aabbccddeeff")
        let cases = [("000102030405060708090a0b0c0d0e0f", "69c4e0d86a7b0430d8cdb78070b4c55a"),
                     ("000102030405060708090a0b0c0d0e0f1011121314151617", "dda97ca4864cdfe06eaf70a0ec0d7191"),
                     ("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", "8ea2b7ca516745bfeafc49904b496089")]
        for (key, cipher) in cases {
            let aes = try #require(AES(key: bytes(hex: key)))
            #expect(aes.encrypt(plain) == bytes(hex: cipher))
        }
        #expect(AES(key: [UInt8](repeating: 0, count: 15)) == nil)
    }

    @Test func counterModeMatchesSP80038A() throws {
        // F.5.1 (AES-128) and F.5.5 (AES-256), the first two blocks: the counter's carry stays in the last bytes.
        let iv = bytes(hex: "f0f1f2f3f4f5f6f7f8f9fafbfcfdfeff")
        let plain = bytes(hex: "6bc1bee22e409f96e93d7e117393172aae2d8a571e03ac9c9eb76fac45af8e51")
        let aes128 = try #require(AES(key: bytes(hex: "2b7e151628aed2a6abf7158809cf4f3c")))
        #expect(aes128.ctr(plain, iv: iv) == bytes(hex: "874d6191b620e3261bef6864990db6ce9806f66b7970fdff8617187bb9fffdff"))
        let aes256 = try #require(AES(key: bytes(hex: "603deb1015ca71be2b73aef0857d77811f352c073b6108d72d9810a30914dff4")))
        let cipher = aes256.ctr(plain, iv: iv)
        #expect(cipher == bytes(hex: "601ec313775789a5b7a7f504bbf3d228f443e3ca4d62b59aca84e990cacaf5c5"))
        #expect(aes256.ctr(cipher, iv: iv) == plain)
        #expect(aes128.ctr(Array(plain.prefix(5)), iv: iv) == bytes(hex: "874d6191b6"))      // a part block
    }
}

struct ProtobufTests {
    @Test func readsEveryWireType() throws {
        // 1: varint 150; 2: "testing"; 3: fixed32; 4: fixed64; 5: int32 −2 (ten bytes); 6: sint32 −3 (zigzag 5).
        let message = try #require(ProtobufMessage(bytes(hex: "089601" + "120774657374696e67" + "1d78563412"
                                                          + "210807060504030201" + "28feffffffffffffffff01" + "3005")))
        #expect(message.unsigned(1) == 150)
        #expect(message.string(2) == "testing")
        #expect(message.unsigned(3) == 0x1234_5678)
        #expect(message.unsigned(4) == 0x0102_0304_0506_0708)
        #expect(message.signed(5) == -2)
        #expect(message.zigzag(6) == -3)
        #expect(message.fields.count == 6)
    }

    @Test func refusesBrokenMessages() {
        #expect(ProtobufMessage(bytes(hex: "1205616263")) == nil)       // length past the end
        #expect(ProtobufMessage(bytes(hex: "0896")) == nil)             // unfinished varint
        #expect(ProtobufMessage(bytes(hex: "1b")) == nil)               // a group (wire type 3)
        #expect(ProtobufMessage(bytes(hex: "0001")) == nil)             // field number 0
        #expect(ProtobufMessage([])?.fields.isEmpty == true)            // empty is a valid message
    }
}

struct MeshtasticChannelTests {
    @Test func theDefaultChannelHashesTo8() {
        let channel = MeshtasticChannel.primary(.longFast)
        #expect(channel.key == Meshtastic.defaultKey)
        #expect(channel.hash == 8)
    }

    @Test func shortKeysExpandAsTheFirmwareDoes() {
        #expect(MeshtasticChannel(name: "x", psk: [0]).key.isEmpty)
        #expect(MeshtasticChannel(name: "x", psk: [3]).key == Array(Meshtastic.defaultKey.prefix(15)) + [0x03])
        #expect(MeshtasticChannel(name: "x", psk: [1, 2, 3]).key == [1, 2, 3] + [UInt8](repeating: 0, count: 13))
        #expect(MeshtasticChannel(name: "x", psk: [UInt8](repeating: 7, count: 20)).key.count == 32)
    }

    @Test func frequencySlotsFollowTheChannelName() throws {
        let us = try #require(MeshtasticRegion.named("us"))
        let bw = MeshtasticPreset.longFast.modulation.bandwidth
        #expect(us.slotCount(bandwidth: bw) == 104)
        #expect(Meshtastic.djb2("LongFast") == 130_429_955)
        #expect(us.defaultSlot(channelName: "LongFast", bandwidth: bw) == 19)
        #expect(abs(us.frequency(slot: 19, bandwidth: bw) - 906.875e6) < 1)
        let eu868 = try #require(MeshtasticRegion.named("EU_868"))
        #expect(abs(eu868.frequency(slot: eu868.defaultSlot(channelName: "LongFast", bandwidth: bw), bandwidth: bw) - 869.525e6) < 1)
        let eu433 = try #require(MeshtasticRegion.named("EU_433"))
        #expect(abs(eu433.frequency(slot: eu433.defaultSlot(channelName: "LongFast", bandwidth: bw), bandwidth: bw) - 433.875e6) < 1)
        // A region with a fixed default slot ignores the name.
        let narrow = try #require(MeshtasticRegion.named("EU_N_868"))
        #expect(narrow.defaultSlot(channelName: "anything", bandwidth: 62_500) == 0)
    }

    @Test func presetsHaveTheirModulations() throws {
        #expect(MeshtasticPreset(name: "LONG_FAST") == .longFast)
        #expect(MeshtasticPreset(name: "longmoderate") == .longModerate)
        #expect(MeshtasticPreset(name: "nope") == nil)
        let slow = MeshtasticPreset.longSlow.parameters
        #expect(slow.spreadingFactor == 12 && slow.bandwidth == 125_000 && slow.codingRate == 4 && slow.lowDataRate)
        #expect(slow.syncWord == 0x2b && slow.preambleLength == 16)
        #expect(!MeshtasticPreset.longFast.parameters.lowDataRate)
        #expect(MeshtasticPreset.longModerate.parameters.lowDataRate)        // 16.4 ms symbols
    }
}

/// Packets built by Tools/meshtastic-vectors.py (protobuf by hand, OpenSSL's AES).
private func packets() throws -> [String: (channel: String, key: String, frame: [UInt8])] {
    var result: [String: (String, String, [UInt8])] = [:]
    for fields in try resourceLines("meshtastic-packets") { result[fields[0]] = (fields[1], fields[2], bytes(hex: fields[3])) }
    return result
}

private func decoder() throws -> MeshtasticDecoder {
    let secret = try #require(try packets()["private"])
    let key = try #require(Data(base64Encoded: secret.key))
    return MeshtasticDecoder(channels: [.primary(.longFast), MeshtasticChannel(name: secret.channel, psk: [UInt8](key))])
}

struct MeshtasticPacketTests {
    private func decode(_ name: String) throws -> MeshtasticPacket {
        let frame = try #require(try packets()[name]).frame
        return try #require(try decoder().decode(frame))
    }

    @Test func textMessage() throws {
        let packet = try decode("text")
        #expect(packet.status == .decoded && packet.channel == "LongFast")
        #expect(packet.header.from == 0x1234_5678 && packet.header.isBroadcast && packet.header.id == 0xdead_beef)
        #expect(packet.header.hopLimit == 3 && packet.header.hopStart == 3 && !packet.header.wantAck)
        guard case .text(let text)? = packet.data?.content else { Issue.record("not text"); return }
        #expect(text == "Hello from the mesh")
        #expect(packet.line.hasPrefix("!12345678 → ^all  id deadbeef  hops 3/3  [LongFast]  TEXT  \"Hello from the mesh\""))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(packet.json().utf8)) as? [String: Any])
        #expect(json["text"] as? String == "Hello from the mesh" && json["from"] as? String == "!12345678")
        #expect(json["port"] as? String == "TEXT" && json["status"] as? String == "decoded")
    }

    @Test func position() throws {
        let packet = try decode("position")
        guard case .position(let p)? = packet.data?.content else { Issue.record("not a position"); return }
        let latitude = try #require(p.latitude), longitude = try #require(p.longitude)
        #expect(abs(latitude - 37.7749) < 1e-9 && abs(longitude + 122.4194) < 1e-9)
        #expect(p.altitude == 15 && p.time == 1_700_000_000 && p.satellites == 9 && p.precisionBits == 32)
        #expect(packet.header.hopLimit == 2)
        #expect(packet.line.hasSuffix("POSITION  37.77490, -122.41940  15 m  9 sats  2023-11-14 22:13:20Z"))
    }

    @Test func nodeInfo() throws {
        let packet = try decode("nodeinfo")
        guard case .nodeInfo(let user)? = packet.data?.content else { Issue.record("not node info"); return }
        #expect(user.id == "!12345678" && user.longName == "Swift Node" && user.shortName == "SWFT")
        #expect(user.hardwareModel == 43 && user.role == 2 && user.publicKey == Array(0..<32))
        #expect(packet.data?.wantResponse == true)
        #expect(packet.line.hasSuffix("NODEINFO  \"Swift Node\" (SWFT) !12345678  hw 43  ROUTER  public key"))
    }

    @Test func telemetry() throws {
        let device = try decode("device")
        guard case .telemetry(let d)? = device.data?.content else { Issue.record("not telemetry"); return }
        #expect(d.kind == "device" && d.batteryLevel == 87 && d.voltage == 4.05 && d.channelUtilization == 12.5)
        #expect(d.airUtilTx == 1.25 && d.uptime == 3600 && d.time == 1_700_000_100)
        let environment = try decode("environment")
        guard case .telemetry(let e)? = environment.data?.content else { Issue.record("not telemetry"); return }
        #expect(e.kind == "environment" && e.temperature == 21.5 && e.relativeHumidity == 45 && e.barometricPressure == 1013.25)
        #expect(environment.line.hasSuffix("TELEMETRY  environment  21.5 °C  45 %RH  1013.2 hPa"))
    }

    @Test func routingTracerouteAndNeighbours() throws {
        let trace = try decode("traceroute")
        guard case .traceroute(let route, let back)? = trace.data?.content else { Issue.record("not a traceroute"); return }
        #expect(route == [0x1111_1111, 0x2222_2222] && back == [0x3333_3333])
        #expect(trace.data?.requestID == 0x99 && trace.header.to == 0x0a0b_0c0d && trace.header.hopStart == 7)
        let neighbors = try decode("neighbors")
        guard case .neighborInfo(let node, let list)? = neighbors.data?.content else { Issue.record("not neighbour info"); return }
        #expect(node == 0x1234_5678 && list.map(\.node) == [0x0a0b_0c0d, 0x0102_0304] && list.map(\.snr) == [6.25, -3.5])
        let ack = try decode("ack")
        guard case .routing(let error)? = ack.data?.content else { Issue.record("not routing"); return }
        #expect(error == nil && ack.data?.requestID == 0x105 && ack.line.hasSuffix("ROUTING (request 00000105)  ack"))
    }

    @Test func aPrivateChannelWithAnAES256Key() throws {
        let packet = try decode("private")
        #expect(packet.status == .decoded && packet.channel == "Secret" && packet.header.wantAck)
        guard case .text(let text)? = packet.data?.content else { Issue.record("not text"); return }
        #expect(text == "AES-256 channel")
    }

    @Test func packetsNobodyHereCanRead() throws {
        let direct = try decode("direct")
        #expect(direct.status == .publicKey && direct.data == nil && direct.encrypted.count == 40)
        let unknown = try decode("unknown")
        #expect(unknown.status == .unknownChannel && unknown.data == nil)
        #expect(unknown.line.contains("unknown channel 0x"))
        // The right hash with the wrong key gives no message either.
        var forged = try #require(try packets()["unknown"]).frame
        forged[13] = MeshtasticChannel.primary(.longFast).hash
        #expect(try decoder().decode(forged)?.status == .unknownChannel)
        #expect(try decoder().decode(Array(forged.prefix(15))) == nil)
    }
}

/// I/Q at `rate` for LoRa frames: ideal chirps (each starting at phase 0, as gr-lora_sdr makes them), a carrier
/// offset with the matching transmitter clock error, and complex Gaussian noise for `snr` dB in the LoRa bandwidth.
func loraModulate(_ frames: [[Int]], _ p: LoRaParameters, rate: Double, rf: Double, ppm: Double, snr: Double,
                      gapSymbols: Double = 12, seed: UInt64 = 1) -> [Float] {
    let n = Double(p.chips), d = ppm * 1e-6, cfo = rf * d
    // Chirp ids in order, with down-chirps marked by nil; each frame is preamble, sync word, 2.25 down-chirps, data.
    var plan: [(start: Double, id: Int?, length: Double)] = []
    var chip = gapSymbols * n
    let (sync0, sync1) = p.syncSymbols
    for frame in frames {
        for id in [Int](repeating: 0, count: p.preambleLength) + [sync0, sync1] { plan.append((chip, id, n)); chip += n }
        for length in [n, n, n / 4] { plan.append((chip, nil, length)); chip += length }
        for id in frame { plan.append((chip, id, n)); chip += n }
        chip += gapSymbols * n
    }
    let total = Int(chip / p.bandwidth * rate / (1 + d))
    var state = seed, output = [Float](repeating: 0, count: 2 * total)
    func uniform() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return (Double(state >> 11) + 0.5) / Double(1 << 53)
    }
    let sigma = (pow(10, -snr / 10) * rate / p.bandwidth / 2).squareRoot()
    var segment = 0
    for k in 0..<total {
        let time = Double(k) / rate
        let c = time * p.bandwidth * (1 + d)                 // the transmitter's chip clock
        while segment + 1 < plan.count && plan[segment + 1].start <= c { segment += 1 }
        var i = 0.0, q = 0.0
        if let s = plan.isEmpty ? nil : plan[segment], c >= s.start && c < s.start + s.length {
            let t = c - s.start
            var phase: Double
            if let id = s.id {
                let fold = t >= n - Double(id) ? 1.5 : 0.5
                phase = 2 * Double.pi * (t * t / (2 * n) + (Double(id) / n - fold) * t)
            } else {
                phase = -2 * Double.pi * (t * t / (2 * n) - 0.5 * t)
            }
            phase += 2 * Double.pi * cfo * time
            i = cos(phase); q = sin(phase)
        }
        let r = (-2 * log(uniform())).squareRoot(), a = 2 * Double.pi * uniform()
        output[2 * k] = Float(i + sigma * r * cos(a))
        output[2 * k + 1] = Float(q + sigma * r * sin(a))
    }
    return output
}

struct LoRaReceiverTests {
    private func modulate(_ frames: [[Int]], _ p: LoRaParameters, rate: Double, rf: Double, ppm: Double, snr: Double,
                          gapSymbols: Double = 12, seed: UInt64 = 1) -> [Float] {
        loraModulate(frames, p, rate: rate, rf: rf, ppm: ppm, snr: snr, gapSymbols: gapSymbols, seed: seed)
    }

    @Test func meshtasticFramesThroughTheReceiver() throws {
        // ShortFast (SF7, 250 kHz) at 1 MS/s, a transmitter 15 ppm fast on 906.875 MHz (+13.6 kHz), SNR 0 dB.
        let p = MeshtasticPreset.shortFast.parameters
        let all = try packets()
        let sent = [try #require(all["text"]).frame, try #require(all["position"]).frame, try #require(all["private"]).frame]
        let iq = modulate(sent.map { LoRaCoding.encode($0, p) }, p, rate: 1e6, rf: 906.875e6, ppm: 15, snr: 0)
        // As complex floats and as a dongle's bytes, in odd-sized blocks that split samples between I and Q.
        let floats = LoRaReceiver(parameters: p, sampleRate: 1e6, centerFrequencyHz: 906.875e6)
        let bytes = LoRaReceiver(parameters: p, sampleRate: 1e6, centerFrequencyHz: 906.875e6)
        let u8 = iq.map { UInt8(max(0, min(255, ($0 * 13 + 127.5).rounded()))) }
        var fromFloats: [LoRaFrame] = [], fromBytes: [LoRaFrame] = []
        var index = 0
        while index < iq.count {
            let end = min(iq.count, index + 37_123)
            fromFloats += floats.process(complex: Array(iq[index..<end]))
            fromBytes += bytes.process(iq: Array(u8[index..<end]))
            index = end
        }
        for frames in [fromFloats, fromBytes] {
            #expect(frames.map(\.payload) == sent)
            #expect(frames.allSatisfy { $0.crcValid == true && abs($0.carrierOffsetHz - 13_603) < 60 && abs($0.snrDB) < 2 })
        }
        let decoder = try decoder()
        let texts = fromBytes.compactMap { decoder.decode($0.payload)?.data?.content.summary }
        #expect(texts.count == 3 && texts[0] == "\"Hello from the mesh\"" && texts[2] == "\"AES-256 channel\"")
    }

    @Test func noiseAloneGivesNoFrames() {
        let p = MeshtasticPreset.shortFast.parameters
        let iq = modulate([], p, rate: 1e6, rf: 906.875e6, ppm: 0, snr: 0, gapSymbols: 600, seed: 9)
        let receiver = LoRaReceiver(parameters: p, sampleRate: 1e6)
        #expect(receiver.process(complex: iq).isEmpty)
    }
}
