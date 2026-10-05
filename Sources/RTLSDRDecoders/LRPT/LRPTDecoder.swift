// SPDX-License-Identifier: GPL-2.0-or-later
//
// The LRPT receive chain after demodulation: soft symbols → frames → packets → MSU-MR images, with the counters a
// display needs. See PROVENANCE.md.

/// Decodes Meteor-M LRPT from soft QPSK symbols (signed bytes, I then Q) into frames, packets and images.
public final class LRPTDecoder {
    public struct Statistics: Sendable {
        public var frames = 0
        public var validFrames = 0
        public var correctedSymbols = 0
        public var packets = 0
        public var imagePackets = 0
        /// The latest frame's Viterbi figure (lower is better; ~1100 per byte decodes) and marker agreement (of 64).
        public var viterbiMetric = 0
        public var markerScore = 0
        /// Frames per spacecraft ID seen, and the latest frame counter.
        public var spacecraft: [Int: Int] = [:]
        public var lastCounter = 0
        public var packetsPerAPID: [Int: Int] = [:]
    }

    public let mode: LRPT.Mode
    public let frames: LRPTFrameDecoder
    public let assembler = LRPTPacketAssembler()
    public let imager = MSUMRImager()
    public private(set) var statistics = Statistics()
    /// Called with every frame (valid or not) and every packet, for displays and recorders.
    public var onFrame: ((LRPTFrame) -> Void)?
    public var onPacket: ((LRPTPacket) -> Void)?

    public init(mode: LRPT.Mode) {
        self.mode = mode
        frames = LRPTFrameDecoder(mode: mode)
    }

    public func process(soft: [Int8]) {
        for frame in frames.process(soft) { handle(frame) }
    }

    public func flush() {
        for frame in frames.flush() { handle(frame) }
    }

    private func handle(_ frame: LRPTFrame) {
        statistics.frames += 1
        statistics.viterbiMetric = frame.viterbiMetric
        statistics.markerScore = frame.markerScore
        onFrame?(frame)
        guard let corrected = frame.corrected else {
            assembler.reset()                          // as meteor_decode: a lost frame breaks the packet in progress
            return
        }
        statistics.validFrames += 1
        statistics.correctedSymbols += corrected
        statistics.spacecraft[frame.spacecraftID, default: 0] += 1
        statistics.lastCounter = frame.counter
        for packet in assembler.packets(in: frame.bytes) {
            statistics.packets += 1
            statistics.packetsPerAPID[packet.apid, default: 0] += 1
            onPacket?(packet)
            if imager.add(packet) != nil { statistics.imagePackets += 1 }
        }
    }
}
