import CFT8Lib
import Foundation

/// Wraps one `ft8_lib` `monitor_t` — the accumulating STFT waterfall for a
/// single message slot — plus candidate search and LDPC decode. One instance
/// covers one slot: call `process(block:)` for every `blockSize`-sized chunk
/// of audio in the slot, then `decode()` once the slot is complete, then
/// `reset()` before the next slot.
///
/// Not thread-safe by itself — callers (`FT8DecodeCoordinator`) are
/// responsible for confining use to a single serial queue, same as
/// `APRSDecoder`.
public final class FT8Decoder {
    private var monitor = monitor_t()
    private let mode: FT8Kit.Mode

    /// Exact number of samples `process(block:)` requires per call.
    public let blockSize: Int

    /// - Parameters:
    ///   - sampleRate: Must match the audio actually fed in (12000 Hz for the
    ///     reference vectors this was validated against).
    ///   - mode: `.ft8` or `.ft4`.
    ///   - freqMinHz/freqMaxHz: Analysis passband within the audio, matching
    ///     ft8_lib's own demo defaults (200–3000 Hz covers the whole
    ///     standard FT8 sub-band audio passband).
    ///   - timeOversample/freqOversample: STFT subdivision — higher costs
    ///     more CPU/memory for finer sync localization; 2/2 matches
    ///     ft8_lib's own demo defaults.
    public init(
        sampleRate: Double,
        mode: FT8Kit.Mode = .ft8,
        freqMinHz: Float = 200,
        freqMaxHz: Float = 3000,
        timeOversample: Int32 = 2,
        freqOversample: Int32 = 2
    ) {
        self.mode = mode
        self.blockSize = mode.blockSize(sampleRate: sampleRate)
        var cfg = monitor_config_t(
            f_min: freqMinHz,
            f_max: freqMaxHz,
            sample_rate: Int32(sampleRate),
            time_osr: timeOversample,
            freq_osr: freqOversample,
            protocol: mode.protocolValue
        )
        monitor_init(&monitor, &cfg)
    }

    deinit {
        monitor_free(&monitor)
    }

    /// Discards accumulated waterfall data to start a fresh slot.
    public func reset() {
        monitor_reset(&monitor)
    }

    /// Feeds exactly one block of audio (`blockSize` samples) into the
    /// accumulating waterfall for the current slot.
    public func process(block: [Float]) {
        precondition(
            block.count == blockSize,
            "FT8Decoder.process(block:) requires exactly \(blockSize) samples, got \(block.count)"
        )
        block.withUnsafeBufferPointer { buffer in
            monitor_process(&monitor, buffer.baseAddress)
        }
    }

    /// Searches the accumulated slot for sync candidates and attempts to
    /// LDPC-decode + unpack each one, deduplicating messages that multiple
    /// candidates resolve to the same payload (mirrors ft8_lib's own demo
    /// decode loop, including its duplicate-suppression behavior).
    public func decode(
        minScore: Int32 = 10,
        maxCandidates: Int32 = 140,
        ldpcIterations: Int32 = 25
    ) -> [FT8Kit.RawMessage] {
        var candidates = [ftx_candidate_t](repeating: ftx_candidate_t(), count: Int(maxCandidates))
        let numCandidates = withUnsafePointer(to: monitor.wf) { waterfall in
            ftx_find_candidates(waterfall, maxCandidates, &candidates, minScore)
        }
        guard numCandidates > 0 else { return [] }

        var seenPayloads = Set<[UInt8]>()
        var results: [FT8Kit.RawMessage] = []
        results.reserveCapacity(Int(numCandidates))

        for index in 0..<Int(numCandidates) {
            let candidate = candidates[index]
            var message = ftx_message_t()
            var status = ftx_decode_status_t()

            let decoded = withUnsafePointer(to: monitor.wf) { waterfall in
                withUnsafePointer(to: candidate) { candidatePointer in
                    ftx_decode_candidate(waterfall, candidatePointer, ldpcIterations, &message, &status)
                }
            }
            guard decoded else { continue }

            let payloadBytes = withUnsafeBytes(of: message.payload) { Array($0) }
            guard seenPayloads.insert(payloadBytes).inserted else { continue }

            guard let text = decodedText(for: message) else { continue }

            let freqHz = (Double(monitor.min_bin) + Double(candidate.freq_offset)
                + Double(candidate.freq_sub) / Double(monitor.wf.freq_osr)) / Double(monitor.symbol_period)
            let timeSec = (Double(candidate.time_offset)
                + Double(candidate.time_sub) / Double(monitor.wf.time_osr)) * Double(monitor.symbol_period)

            results.append(
                FT8Kit.RawMessage(
                    text: text.text,
                    fields: text.fields,
                    frequencyOffsetHz: freqHz,
                    dtSeconds: timeSec,
                    score: Int(candidate.score),
                    ldpcErrors: Int(status.ldpc_errors)
                )
            )
        }
        return results
    }

    /// Unpacks a decoded `ftx_message_t` into its text and classified fields.
    private func decodedText(for message: ftx_message_t) -> (text: String, fields: [FT8Kit.MessageField])? {
        var mutableMessage = message
        var textBuffer = [CChar](repeating: 0, count: Int(FTX_MAX_MESSAGE_LENGTH))
        var offsets = ftx_message_offsets_t()

        let rc = withUnsafePointer(to: &mutableMessage) { messagePointer in
            ftx_message_decode(messagePointer, &FT8CallsignHashStub.interface, &textBuffer, &offsets)
        }
        guard rc == FTX_MESSAGE_RC_OK else { return nil }

        let text = String(cString: textBuffer)
        let types = [offsets.types.0, offsets.types.1, offsets.types.2]
        let starts = [offsets.offsets.0, offsets.offsets.1, offsets.offsets.2]

        var fields: [FT8Kit.MessageField] = []
        let characters = Array(text)
        for i in 0..<3 {
            guard starts[i] >= 0 else { break }
            let start = Int(starts[i])
            let end = (i + 1 < 3 && starts[i + 1] >= 0) ? Int(starts[i + 1]) : characters.count
            guard start < end, end <= characters.count else { continue }
            let slice = String(characters[start..<end]).trimmingCharacters(in: .whitespaces)
            guard !slice.isEmpty else { continue }
            fields.append(FT8Kit.MessageField(kind: FT8Kit.FieldKind(types[i]), text: slice))
        }
        return (text, fields)
    }
}
