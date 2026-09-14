import XCTest
@testable import FT8Kit

/// Hard correctness gate for the vendored ft8_lib wrapper: feeds real
/// off-air FT8 captures (vendored from ft8_lib's own `test/wav/`, see
/// `Tests/FT8KitTests/Resources/` and the repo README's "Third-party code"
/// section) through `FT8Decoder` in exact `blockSize`-sized chunks — same
/// shape `monitor_process` requires in production — and checks every
/// expected message shows up in what we decode. Asserts expected ⊆ decoded
/// rather than exact-set equality: ft8_lib's own candidate count/order can
/// vary release to release, and this wrapper isn't trying to out-decode the
/// library it wraps.
///
/// The vendored `.txt` files alongside each WAV (ft8_lib's own truth data)
/// are NOT used directly as the expected set here: they include a couple of
/// weak-signal messages (e.g. "TK4LS YC1MRF 73" in 191111_110130) that
/// ft8_lib's own reference `decode_ft8` demo — built and run standalone from
/// the same upstream checkout, with default candidate-search parameters —
/// does not decode either. That's a real limitation of this library's
/// default sync/candidate search, not a bug in this Swift wrapper (the .txt
/// files were evidently produced by a different/more sensitive decoder,
/// e.g. WSJT-X, given they also carry a DXCC country annotation this
/// library never emits). `expectedMessages` below is exactly what the
/// reference C demo decodes from these same files, so this test validates
/// wrapper-fidelity to ft8_lib, not ft8_lib's own decode sensitivity.
final class FT8ReferenceVectorTests: XCTestCase {
    private static let fixtures: [(baseName: String, expectedMessages: Set<String>)] = [
        ("191111_110130", ["CQ R7IW LN35", "CQ DX R6WA LN32", "CQ TA6CQ KN70", "OH3NIV ZS6S -03"]),
        ("191111_110145", ["GJ0KYZ RK9AX MO05", "<...> RY8CAA"]),
        ("191111_110200", ["CQ DX R6WA LN32", "CQ TA6CQ KN70", "CQ R7IW LN35", "CQ LZ1JZ KN22"]),
    ]

    func testAllReferenceVectorsDecodeExpectedMessages() throws {
        for fixture in Self.fixtures {
            try assertReferenceVectorDecodes(fixture.baseName, expectedMessages: fixture.expectedMessages)
        }
    }

    private func assertReferenceVectorDecodes(_ baseName: String, expectedMessages: Set<String>) throws {
        guard let wavURL = Bundle.module.url(forResource: baseName, withExtension: "wav", subdirectory: "Resources") else {
            XCTFail("Missing fixture WAV for \(baseName)")
            return
        }

        let (samples, sampleRate) = try Self.loadWAV(url: wavURL)

        let decoder = FT8Decoder(sampleRate: sampleRate)
        var offset = 0
        while offset + decoder.blockSize <= samples.count {
            let block = Array(samples[offset..<(offset + decoder.blockSize)])
            decoder.process(block: block)
            offset += decoder.blockSize
        }

        let decodedTexts = Set(decoder.decode().map(\.text))

        for expected in expectedMessages {
            XCTAssertTrue(
                decodedTexts.contains(expected),
                "\(baseName): expected message \"\(expected)\" not found among decoded: \(decodedTexts.sorted())"
            )
        }
    }

    /// Minimal WAV reader — 16-bit PCM or 32-bit float, mono or stereo
    /// (stereo downmixed to the first channel). Same shape as
    /// `APRSWAVAnalysisTests.loadWAV` — not meant to be general-purpose.
    private static func loadWAV(url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let data = try Data(contentsOf: url)
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
        var sampleRate: Double = 12_000
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
                value = Float(bitPattern: u32(frameStart))
            } else if bitsPerSample == 16 {
                value = Float(Int16(bitPattern: u16(frameStart))) / Float(Int16.max)
            } else if bitsPerSample == 32 {
                value = Float(Int32(bitPattern: u32(frameStart))) / Float(Int32.max)
            } else {
                preconditionFailure("unsupported bits-per-sample: \(bitsPerSample)")
            }
            samples.append(value)
        }
        return (samples, sampleRate)
    }
}
