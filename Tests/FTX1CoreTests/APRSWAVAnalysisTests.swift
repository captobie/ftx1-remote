import XCTest
@testable import FTX1Core

/// Runs the real decode pipeline against a real recorded WAV file instead
/// of a synthesized signal — for debugging an actual reception gap (e.g.
/// against direwolf) with real evidence rather than more guessing at
/// synthetic test conditions. Skipped unless `APRS_WAV_PATH` is set, so
/// this never affects a normal `swift test` run; point it at a captured
/// clip and run:
///
///   APRS_WAV_PATH=/path/to/capture.wav swift test --filter APRSWAVAnalysisTests
///
/// Prints `AX25FrameDecoder.Stats` (flags found vs. destuff/CRC/address
/// failures vs. frames actually decoded) plus every decoded station —
/// worth keeping around for any future real-audio debugging, not just
/// this investigation.
final class APRSWAVAnalysisTests: XCTestCase {
    func testAnalyzeRealCapture() throws {
        guard let path = ProcessInfo.processInfo.environment["APRS_WAV_PATH"] else {
            throw XCTSkip("Set APRS_WAV_PATH to a .wav file to run this analysis.")
        }
        let (samples, sampleRate) = try Self.loadWAV(path: path)
        print("Loaded \(samples.count) samples at \(sampleRate) Hz (\(Double(samples.count) / sampleRate) s)")

        // Same chunk size AudioCaptureEngine's real tap delivers, so this
        // matches production behavior (chunked, incremental) rather than
        // one giant contiguous call.
        let chunkSize = 2048
        var demod = AFSKDemodulator(sampleRate: sampleRate)
        var frameDecoder = AX25FrameDecoder()
        var allFrames: [AX25Frame] = []

        var index = 0
        while index < samples.count {
            let end = min(index + chunkSize, samples.count)
            let chunk = Array(samples[index..<end])
            let lineBits = demod.process(samples: chunk)
            allFrames.append(contentsOf: frameDecoder.process(bits: lineBits))
            index = end
        }

        let stats = frameDecoder.stats
        print("""
        --- AX25FrameDecoder.Stats ---
        flagsFound: \(stats.flagsFound)
        destuffFailures: \(stats.destuffFailures)
        tooShortFailures: \(stats.tooShortFailures)
        crcFailures: \(stats.crcFailures)
        addressParseFailures: \(stats.addressParseFailures)
        framesDecoded: \(stats.framesDecoded)
        -------------------------------
        """)

        for frame in allFrames {
            let packet = APRSPacket.parse(infoField: frame.info)
            print("Frame: \(frame.source.displayString) -> \(frame.destination.displayString) via \(frame.digipeaters.map(\.displayString).joined(separator: ",")): \(packet)")
        }

        XCTAssertTrue(true, "Diagnostic only — see console output above.")
    }

    /// Minimal WAV reader — 16-bit PCM or 32-bit float, mono or stereo
    /// (stereo is downmixed to the first channel; a real audio interface
    /// feeding a single receiver's discriminator output is normally
    /// captured as mono, but macOS recording tools often default to
    /// stereo regardless). Just enough to unblock this diagnostic — not
    /// meant to be a general-purpose WAV loader.
    private static func loadWAV(path: String) throws -> (samples: [Float], sampleRate: Double) {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        func u32(_ offset: Int) -> UInt32 {
            UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
        }
        func u16(_ offset: Int) -> UInt16 {
            UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        }
        precondition(data.count > 44, "file too short to be a WAV")
        precondition(String(decoding: data[0..<4], as: UTF8.self) == "RIFF", "not a RIFF file")
        precondition(String(decoding: data[8..<12], as: UTF8.self) == "WAVE", "not a WAVE file")

        var offset = 12
        var audioFormat: UInt16 = 1
        var channelCount: UInt16 = 1
        var sampleRate: Double = 44_100
        var bitsPerSample: UInt16 = 16
        var dataStart = 0
        var dataLength = 0

        while offset + 8 <= data.count {
            let chunkID = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
            let chunkSize = Int(u32(offset + 4))
            let chunkDataStart = offset + 8
            if chunkID == "fmt " {
                audioFormat = u16(chunkDataStart)
                channelCount = u16(chunkDataStart + 2)
                sampleRate = Double(u32(chunkDataStart + 4))
                bitsPerSample = u16(chunkDataStart + 14)
            } else if chunkID == "data" {
                dataStart = chunkDataStart
                dataLength = chunkSize
            }
            offset = chunkDataStart + chunkSize + (chunkSize % 2)
        }
        precondition(dataStart > 0, "no data chunk found")

        var samples: [Float] = []
        let bytesPerSample = Int(bitsPerSample) / 8
        let frameSize = bytesPerSample * Int(channelCount)
        let frameCount = dataLength / frameSize
        samples.reserveCapacity(frameCount)

        for i in 0..<frameCount {
            let frameStart = dataStart + i * frameSize
            let value: Float
            if audioFormat == 3, bitsPerSample == 32 {
                let bits = u32(frameStart)
                value = Float(bitPattern: bits)
            } else if bitsPerSample == 16 {
                let raw = Int16(bitPattern: u16(frameStart))
                value = Float(raw) / Float(Int16.max)
            } else if bitsPerSample == 32 {
                let raw = Int32(bitPattern: u32(frameStart))
                value = Float(raw) / Float(Int32.max)
            } else {
                preconditionFailure("unsupported bits-per-sample: \(bitsPerSample)")
            }
            samples.append(value)
        }
        return (samples, sampleRate)
    }
}
