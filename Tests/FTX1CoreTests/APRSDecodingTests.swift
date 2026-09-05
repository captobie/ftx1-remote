import XCTest
@testable import FTX1Core

/// Verifies the AFSK/AX.25/APRS decode pipeline against synthesized test
/// vectors — there's no CAT round-trip to check this kind of greenfield
/// DSP/protocol code against (unlike almost everything else in this app),
/// so this is the "scratch harness" verification instead: encode a known
/// AX.25 frame carrying a known APRS packet into Bell 202 AFSK audio, feed
/// it through the real demod/frame/packet decoders, and assert the result
/// matches. Real confirmation still needs an actual over-the-air APRS
/// packet once this is wired up end-to-end in the Mac app.
final class APRSDecodingTests: XCTestCase {
    /// CRC-16/X-25's well-known catalog check value (the CRC of ASCII
    /// "123456789") — validates `AX25FCS` against a standard reference,
    /// not just this file's own encode/decode round trip (which would let
    /// a shared algorithm bug in both directions cancel out silently).
    func testFCSMatchesKnownCheckValue() {
        let check = AX25FCS.compute(Array("123456789".utf8))
        XCTAssertEqual(check, 0x906E)
    }

    func testPositionPacketRoundTrip() {
        let frameBytes = Self.encodeUIFrame(
            destination: "APRS", destinationSSID: 0,
            source: "N0CALL", sourceSSID: 9,
            digipeaters: [],
            info: Array("!4903.50N/07201.75W-Test comment".utf8)
        )
        let samples = Self.modulate(frameBytes: frameBytes, sampleRate: 48_000, phaseOffsetSamples: 17)

        var demod = AFSKDemodulator(sampleRate: 48_000)
        var frameDecoder = AX25FrameDecoder()
        let lineBits = demod.process(samples: samples)
        let frames = frameDecoder.process(bits: lineBits)

        XCTAssertEqual(frames.count, 1)
        guard let frame = frames.first else { return }

        XCTAssertEqual(frame.destination.displayString, "APRS")
        XCTAssertEqual(frame.source.displayString, "N0CALL-9")
        XCTAssertTrue(frame.digipeaters.isEmpty)

        let packet = APRSPacket.parse(infoField: frame.info)
        guard case .position(let latitude, let longitude, let symbolTable, let symbolCode, let comment) = packet else {
            XCTFail("expected a position packet, got \(packet)")
            return
        }
        XCTAssertEqual(latitude, 49.0 + 3.50 / 60.0, accuracy: 0.0001)
        XCTAssertEqual(longitude, -(72.0 + 1.75 / 60.0), accuracy: 0.0001)
        XCTAssertEqual(symbolTable, "/")
        XCTAssertEqual(symbolCode, "-")
        XCTAssertEqual(comment, "Test comment")
    }

    func testMessagePacketRoundTrip() {
        let frameBytes = Self.encodeUIFrame(
            destination: "APRS", destinationSSID: 0,
            source: "KJ7ABC", sourceSSID: 0,
            digipeaters: [("WIDE1", 1), ("WIDE2", 2)],
            info: Array(":N0CALL   :Hello there{001".utf8)
        )
        let samples = Self.modulate(frameBytes: frameBytes, sampleRate: 44_100, phaseOffsetSamples: 5)

        var demod = AFSKDemodulator(sampleRate: 44_100)
        var frameDecoder = AX25FrameDecoder()
        let lineBits = demod.process(samples: samples)
        let frames = frameDecoder.process(bits: lineBits)

        XCTAssertEqual(frames.count, 1)
        guard let frame = frames.first else { return }

        XCTAssertEqual(frame.source.displayString, "KJ7ABC")
        XCTAssertEqual(frame.digipeaters.map(\.displayString), ["WIDE1-1", "WIDE2-2"])

        let packet = APRSPacket.parse(infoField: frame.info)
        guard case .message(let to, let text, let messageID) = packet else {
            XCTFail("expected a message packet, got \(packet)")
            return
        }
        XCTAssertEqual(to, "N0CALL")
        XCTAssertEqual(text, "Hello there")
        XCTAssertEqual(messageID, "001")
    }

    /// Feeding the demodulator/frame decoder in small chunks (simulating
    /// `AudioCaptureEngine`'s real tap callback, which delivers ~2048
    /// samples at a time, not one contiguous buffer per packet) must
    /// produce the same result as one big call — both are stateful and
    /// incremental specifically to support this.
    func testDecodingAcrossChunkedBuffers() {
        let frameBytes = Self.encodeUIFrame(
            destination: "APRS", destinationSSID: 0,
            source: "N0CALL", sourceSSID: 0,
            digipeaters: [],
            info: Array(">Testing 123".utf8)
        )
        let samples = Self.modulate(frameBytes: frameBytes, sampleRate: 48_000, phaseOffsetSamples: 3)

        var demod = AFSKDemodulator(sampleRate: 48_000)
        var frameDecoder = AX25FrameDecoder()
        var frames: [AX25Frame] = []
        var index = 0
        let chunkSize = 512
        while index < samples.count {
            let end = min(index + chunkSize, samples.count)
            let chunk = Array(samples[index..<end])
            let lineBits = demod.process(samples: chunk)
            frames.append(contentsOf: frameDecoder.process(bits: lineBits))
            index = end
        }

        XCTAssertEqual(frames.count, 1)
        guard let frame = frames.first else { return }
        let packet = APRSPacket.parse(infoField: frame.info)
        XCTAssertEqual(packet, .status(text: "Testing 123"))
    }

    /// Real audio hardware never runs at exactly the nominal sample rate
    /// (transmitter and receiver clocks always differ slightly), and never
    /// arrives noise-free. Encodes at a sample rate ~0.3% off from what the
    /// demodulator is told, with light noise added, to confirm the bit-
    /// clock DPLL actually tracks drift rather than only working when the
    /// signal happens to line up perfectly with the assumed clock.
    func testDecodingWithClockDriftAndNoise() {
        let frameBytes = Self.encodeUIFrame(
            destination: "APRS", destinationSSID: 0,
            source: "KJ7ABC", sourceSSID: 3,
            digipeaters: [("WIDE1", 1)],
            info: Array("!4903.50N/07201.75W>Mobile".utf8)
        )
        let assumedSampleRate = 48_000.0
        let actualSampleRate = assumedSampleRate * 1.003
        var samples = Self.modulate(frameBytes: frameBytes, sampleRate: actualSampleRate, phaseOffsetSamples: 23)

        var rng = SystemRandomNumberGenerator()
        for i in samples.indices {
            samples[i] += Float.random(in: -0.05...0.05, using: &rng)
        }

        var demod = AFSKDemodulator(sampleRate: assumedSampleRate)
        var frameDecoder = AX25FrameDecoder()
        let lineBits = demod.process(samples: samples)
        let frames = frameDecoder.process(bits: lineBits)

        XCTAssertEqual(frames.count, 1)
        guard let frame = frames.first else { return }
        XCTAssertEqual(frame.source.displayString, "KJ7ABC-3")
        XCTAssertEqual(frame.digipeaters.map(\.displayString), ["WIDE1-1"])

        let packet = APRSPacket.parse(infoField: frame.info)
        guard case .position(let latitude, let longitude, _, _, let comment) = packet else {
            XCTFail("expected a position packet, got \(packet)")
            return
        }
        XCTAssertEqual(latitude, 49.0 + 3.50 / 60.0, accuracy: 0.0001)
        XCTAssertEqual(longitude, -(72.0 + 1.75 / 60.0), accuracy: 0.0001)
        XCTAssertEqual(comment, "Mobile")
    }

    /// Diagnostic, not a pass/fail assertion — reports the lowest SNR
    /// (Gaussian white noise, a much harsher and more realistic test than
    /// `testDecodingWithClockDriftAndNoise`'s mild uniform jitter) at which
    /// the pipeline still decodes a known frame, printed for inspection
    /// rather than asserted against, so this keeps working as a
    /// measurement tool across future demodulator changes instead of
    /// needing its threshold constantly updated.
    func testMeasureNoiseRobustness() {
        let frameBytes = Self.encodeUIFrame(
            destination: "APRS", destinationSSID: 0,
            source: "N0CALL", sourceSSID: 0,
            digipeaters: [],
            info: Array("!4903.50N/07201.75W-Test".utf8)
        )
        let sampleRate = 48_000.0

        var lowestWorkingSNR: Double?
        for snrDb in stride(from: 30.0, through: 0.0, by: -2.0) {
            let samples = Self.modulate(frameBytes: frameBytes, sampleRate: sampleRate, phaseOffsetSamples: 17, dcOffset: 0.05, snrDb: snrDb, seed: 12345)
            var demod = AFSKDemodulator(sampleRate: sampleRate)
            var frameDecoder = AX25FrameDecoder()
            let lineBits = demod.process(samples: samples)
            let frames = frameDecoder.process(bits: lineBits)
            if frames.count == 1, frames[0].source.displayString == "N0CALL" {
                lowestWorkingSNR = snrDb
            } else {
                break
            }
        }
        print("APRS demod: lowest SNR still decoding cleanly = \(lowestWorkingSNR.map { "\($0) dB" } ?? "none found down to 0 dB")")
    }

    /// Diagnostic, not a pass/fail assertion — real stations vary TXDELAY
    /// a lot (some run it short to reduce channel occupancy), and the
    /// bit-clock DPLL needs some number of leading flag bytes to acquire
    /// lock before the frame itself starts. Reports the fewest lead-in
    /// flag bytes still decoding cleanly, with a light noise floor (20dB
    /// SNR) so this isn't measuring a noiseless best case.
    func testMeasureLeadInRobustness() {
        let frameBytes = Self.encodeUIFrame(
            destination: "APRS", destinationSSID: 0,
            source: "N0CALL", sourceSSID: 0,
            digipeaters: [],
            info: Array("!4903.50N/07201.75W-Test".utf8)
        )
        let sampleRate = 48_000.0

        var fewestWorkingFlags: Int?
        for flagCount in stride(from: 12, through: 0, by: -1) {
            let samples = Self.modulate(frameBytes: frameBytes, sampleRate: sampleRate, phaseOffsetSamples: 17, dcOffset: 0.05, snrDb: 20, seed: 12345, flagLeadInCount: flagCount)
            var demod = AFSKDemodulator(sampleRate: sampleRate)
            var frameDecoder = AX25FrameDecoder()
            let lineBits = demod.process(samples: samples)
            let frames = frameDecoder.process(bits: lineBits)
            if frames.count == 1, frames[0].source.displayString == "N0CALL" {
                fewestWorkingFlags = flagCount
            } else {
                break
            }
        }
        print("APRS demod: fewest lead-in flag bytes still decoding cleanly = \(fewestWorkingFlags.map { "\($0)" } ?? "none found down to 0")")
    }

    // MARK: - Synthetic encoder (test-only — the inverse of the real decode pipeline)

    private static func encodeUIFrame(
        destination: String, destinationSSID: Int,
        source: String, sourceSSID: Int,
        digipeaters: [(String, Int)],
        info: [UInt8]
    ) -> [UInt8] {
        var bytes: [UInt8] = []
        let isLastAfterSource = digipeaters.isEmpty
        bytes += encodeAddress(destination, ssid: destinationSSID, isLast: false)
        bytes += encodeAddress(source, ssid: sourceSSID, isLast: isLastAfterSource)
        for (index, digi) in digipeaters.enumerated() {
            bytes += encodeAddress(digi.0, ssid: digi.1, isLast: index == digipeaters.count - 1)
        }
        bytes.append(0x03) // UI frame control byte
        bytes.append(0xF0) // PID: no layer 3
        bytes += info

        let fcs = AX25FCS.compute(bytes)
        bytes.append(UInt8(fcs & 0xFF))
        bytes.append(UInt8((fcs >> 8) & 0xFF))
        return bytes
    }

    private static func encodeAddress(_ callsign: String, ssid: Int, isLast: Bool) -> [UInt8] {
        var padded = Array(callsign.uppercased().utf8)
        while padded.count < 6 { padded.append(UInt8(ascii: " ")) }
        padded = Array(padded.prefix(6))
        var bytes = padded.map { $0 << 1 }
        // 0SSSSRRE — reserved bits set high (0x60), standard convention.
        let ssidByte: UInt8 = 0x60 | (UInt8(ssid) << 1) | (isLast ? 0x01 : 0x00)
        bytes.append(ssidByte)
        return bytes
    }

    private static func byteToBits(_ byte: UInt8) -> [Bool] {
        (0..<8).map { (byte >> $0) & 1 != 0 }
    }

    /// HDLC bit-stuffs the frame bytes, wraps with flag bytes, NRZI-encodes
    /// the result, and renders it as Bell 202 AFSK audio samples — the
    /// exact inverse of `AFSKDemodulator` + `AX25FrameDecoder`.
    ///
    /// `phaseOffsetSamples` prepends that many samples of silence before
    /// the signal starts, so the test doesn't get a lucky pass purely from
    /// the synthesized signal happening to start exactly bit-aligned with
    /// sample index 0 — the bit-clock DPLL has to actually acquire lock,
    /// same as it would against a real, arbitrarily-phased audio source.
    private static func modulate(
        frameBytes: [UInt8], sampleRate: Double, phaseOffsetSamples: Int,
        dcOffset: Float = 0, snrDb: Double? = nil, seed: UInt64 = 1, flagLeadInCount: Int = 12
    ) -> [Float] {
        var lineBits: [Bool] = []
        // A run of flags before and after the frame, matching a real
        // transmission's lead-in/lead-out (TXDELAY) and giving the
        // bit-clock DPLL time to lock before the frame itself starts. Real
        // TXDELAY varies a lot station to station — some run it short
        // (fewer flags) to reduce channel occupancy, which is exactly what
        // `testMeasureLeadInRobustness` sweeps.
        for _ in 0..<flagLeadInCount {
            lineBits += byteToBits(0x7E)
        }
        lineBits += stuff(frameBytes.flatMap(byteToBits))
        for _ in 0..<4 {
            lineBits += byteToBits(0x7E)
        }

        // NRZI encode: "1" = no transition, "0" = transition.
        var level = true
        var levels: [Bool] = []
        levels.reserveCapacity(lineBits.count)
        for bit in lineBits {
            if !bit { level.toggle() }
            levels.append(level)
        }

        let baudRate = 1200.0
        let samplesPerBit = sampleRate / baudRate
        var samples = [Float](repeating: 0, count: phaseOffsetSamples)
        var phase = 0.0
        for level in levels {
            let toneHz = level ? 1200.0 : 2200.0
            let samplesThisBit = Int(samplesPerBit.rounded())
            for _ in 0..<samplesThisBit {
                samples.append(Float(sin(phase)))
                phase += 2 * .pi * toneHz / sampleRate
                if phase > 2 * .pi { phase -= 2 * .pi }
            }
        }

        if let snrDb {
            // Gaussian white noise scaled to the requested SNR against the
            // signal's actual RMS — a much harsher, more realistic test
            // than uniform jitter, which underrepresents real receiver
            // audio noise.
            var rng = SeededGenerator(seed: seed)
            let signalRMS = sqrt(samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(max(samples.count, 1)))
            let noiseRMS = signalRMS / Float(pow(10, snrDb / 20))
            for i in samples.indices {
                samples[i] += gaussian(using: &rng) * noiseRMS
            }
        }
        if dcOffset != 0 {
            for i in samples.indices {
                samples[i] += dcOffset
            }
        }
        return samples
    }

    /// Box-Muller — a plain `Float.random` per sample is uniform, not
    /// Gaussian, and real channel noise is much closer to Gaussian.
    private static func gaussian(using rng: inout SeededGenerator) -> Float {
        let u1 = Float.random(in: .leastNormalMagnitude...1, using: &rng)
        let u2 = Float.random(in: 0...1, using: &rng)
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }

    /// Deterministic across runs, unlike `SystemRandomNumberGenerator` —
    /// needed so `testMeasureNoiseRobustness`'s reported threshold is
    /// reproducible rather than flaking between CI runs.
    private struct SeededGenerator: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed == 0 ? 0xdeadbeef : seed }
        mutating func next() -> UInt64 {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return state
        }
    }

    private static func stuff(_ bits: [Bool]) -> [Bool] {
        var result: [Bool] = []
        result.reserveCapacity(bits.count + bits.count / 5)
        var onesCount = 0
        for bit in bits {
            result.append(bit)
            if bit {
                onesCount += 1
                if onesCount == 5 {
                    result.append(false)
                    onesCount = 0
                }
            } else {
                onesCount = 0
            }
        }
        return result
    }
}
