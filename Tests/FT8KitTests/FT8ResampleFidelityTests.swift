import AVFoundation
import XCTest
@testable import FT8Kit

/// Validates the resample-then-chunk approach the live Mac app path uses
/// (`FT8Resampler` + `FT8DecodeCoordinator`, both in the Mac app's Xcode
/// target — this SPM package has no way to import or unit-test that target
/// directly, so this reimplements the same small amount of logic inline to
/// exercise it here instead) — resample 44100 Hz down to 12000 Hz with a
/// reused `AVAudioConverter`, called repeatedly on small chunks the way
/// live audio actually arrives, not once on the whole signal, then feed the
/// result through `FT8Decoder` in exact `blockSize` blocks. Confirms this
/// still decodes the same message set as the pristine 12000 Hz reference
/// vector, i.e. streaming resampling in small chunks doesn't measurably
/// hurt decodability.
final class FT8ResampleFidelityTests: XCTestCase {
    func testStreamingResampleFrom44100StillDecodes() throws {
        guard let wavURL = Bundle.module.url(forResource: "191111_110130", withExtension: "wav", subdirectory: "Resources") else {
            XCTFail("Missing fixture WAV")
            return
        }
        let (referenceSamples, referenceSampleRate) = try Self.loadWAV(url: wavURL)
        XCTAssertEqual(referenceSampleRate, 12000, accuracy: 1, "fixture is expected to already be 12000 Hz")

        // Upsample the pristine 12000 Hz reference to 44100 Hz once, up
        // front — simulates "what AudioCaptureEngine would have captured,"
        // not part of the thing under test.
        let upsampled = try Self.resampleWholeSignal(referenceSamples, from: referenceSampleRate, to: 44100)

        // Now resample back down to 12000 Hz the way the live path actually
        // does it: one long-lived AVAudioConverter, fed small chunks
        // (AudioCaptureEngine's real 2048-sample delivery size) one call at
        // a time, accumulated into exact FT8Decoder.blockSize blocks.
        let targetSampleRate = 12000.0
        let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetSampleRate, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)!

        let decoder = FT8Decoder(sampleRate: targetSampleRate)
        var pending: [Float] = []

        let chunkSize = 2048
        var offset = 0
        while offset < upsampled.count {
            let end = min(offset + chunkSize, upsampled.count)
            let chunk = Array(upsampled[offset..<end])
            offset = end

            let resampledChunk = Self.streamingResample(chunk, sourceFormat: sourceFormat, targetFormat: targetFormat, converter: converter)
            pending.append(contentsOf: resampledChunk)

            while pending.count >= decoder.blockSize {
                let block = Array(pending.prefix(decoder.blockSize))
                pending.removeFirst(decoder.blockSize)
                decoder.process(block: block)
            }
        }

        let decodedTexts = Set(decoder.decode().map(\.text))
        let expected: Set<String> = ["CQ R7IW LN35", "CQ DX R6WA LN32", "CQ TA6CQ KN70", "OH3NIV ZS6S -03"]
        for message in expected {
            XCTAssertTrue(
                decodedTexts.contains(message),
                "streaming 44100->12000 resample lost \"\(message)\" — decoded: \(decodedTexts.sorted())"
            )
        }
    }

    private static func streamingResample(_ samples: [Float], sourceFormat: AVAudioFormat, targetFormat: AVAudioFormat, converter: AVAudioConverter) -> [Float] {
        guard !samples.isEmpty, let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return [] }
        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            inputBuffer.floatChannelData?[0].update(from: pointer.baseAddress!, count: samples.count)
        }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputCapacity = AVAudioFrameCount((Double(samples.count) * ratio).rounded(.up)) + 16
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else { return [] }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        guard status != .error, let channelData = outputBuffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }

    /// One-shot (non-streaming) resample, used only to prepare the 44100 Hz
    /// input fixture — not the thing under test.
    private static func resampleWholeSignal(_ samples: [Float], from sourceRate: Double, to targetRate: Double) throws -> [Float] {
        let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 1, interleaved: false)!
        let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: sourceFormat, to: targetFormat)!

        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count)) else {
            throw XCTSkip("could not allocate input buffer")
        }
        inputBuffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            inputBuffer.floatChannelData?[0].update(from: pointer.baseAddress!, count: samples.count)
        }

        let ratio = targetRate / sourceRate
        let outputCapacity = AVAudioFrameCount((Double(samples.count) * ratio).rounded(.up)) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            throw XCTSkip("could not allocate output buffer")
        }

        var suppliedInput = false
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, inputStatus in
            if suppliedInput {
                inputStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            inputStatus.pointee = .haveData
            return inputBuffer
        }
        guard status != .error, let channelData = outputBuffer.floatChannelData else {
            throw XCTSkip("conversion failed: \(String(describing: conversionError))")
        }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }

    /// Same minimal WAV reader as `FT8ReferenceVectorTests`.
    private static func loadWAV(url: URL) throws -> (samples: [Float], sampleRate: Double) {
        let data = try Data(contentsOf: url)
        func u32(_ offset: Int) -> UInt32 {
            UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8) | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
        }
        func u16(_ offset: Int) -> UInt16 {
            UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
        }
        precondition(data.count > 44, "file too short to be a WAV")
        var offset = 12
        var sampleRate: Double = 12_000
        var bitsPerSample: UInt16 = 16
        var dataStart = 0
        var dataLength = 0
        while offset + 8 <= data.count {
            let chunkID = String(decoding: data[offset..<(offset + 4)], as: UTF8.self)
            let chunkSize = Int(u32(offset + 4))
            let chunkDataStart = offset + 8
            if chunkID == "fmt " {
                sampleRate = Double(u32(chunkDataStart + 4))
                bitsPerSample = u16(chunkDataStart + 14)
            } else if chunkID == "data" {
                dataStart = chunkDataStart
                dataLength = chunkSize
            }
            offset = chunkDataStart + chunkSize + (chunkSize % 2)
        }
        precondition(dataStart > 0, "no data chunk found")
        let bytesPerSample = Int(bitsPerSample) / 8
        let frameCount = dataLength / bytesPerSample
        var samples: [Float] = []
        samples.reserveCapacity(frameCount)
        for i in 0..<frameCount {
            let raw = Int16(bitPattern: u16(dataStart + i * bytesPerSample))
            samples.append(Float(raw) / Float(Int16.max))
        }
        return (samples, sampleRate)
    }
}
