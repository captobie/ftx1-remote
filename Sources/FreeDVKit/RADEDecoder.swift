import CFTX1Rade

/// What the RADE receiver reports after a call to `RADEDecoder.process`.
public struct RADEStatus: Equatable, Sendable {
    /// In sync with a RADE V1 signal.
    public var sync: Bool
    /// Tuning error of the received signal, Hz (only meaningful in sync).
    public var frequencyOffsetHz: Float
    /// SNR in a 3 kHz bandwidth, dB (only meaningful in sync).
    public var snrDB: Float

    public init(sync: Bool = false, frequencyOffsetHz: Float = 0, snrDB: Float = 0) {
        self.sync = sync
        self.frequencyOffsetHz = frequencyOffsetHz
        self.snrDB = snrDB
    }
}

/// One end-of-over (the end of a transmission) seen by the receiver.
public struct RADEEndOfOver: Equatable, Sendable {
    /// Where it ended, in modem samples since the decoder was created.
    public var sampleTime: Int
    /// The sender's callsign, if it carried one whose CRC checked out.
    public var callsign: String?
}

/// FreeDV RADE V1 receiver: real 8 kHz audio in, 16 kHz speech out.
///
/// Wraps `Vendor/rade/FTX1Rade.xcframework` (rade_c + Opus's FARGAN +
/// freedv-backend's callsign decoder, built by `Scripts/build-rade.sh`).
/// Not thread-safe: use one instance from one serial queue.
public final class RADEDecoder {
    public static let modemSampleRate: Double = Double(FTX1_RADE_MODEM_RATE)
    public static let speechSampleRate: Double = Double(FTX1_RADE_SPEECH_RATE)

    /// The result of one `process` call.
    public struct Output: Sendable {
        /// Decoded speech at `speechSampleRate`, ±1 (empty when not in sync).
        public var speech: [Float]
        /// Status after the last block demodulated in this call.
        public var status: RADEStatus
        /// End-of-overs seen in this call, oldest first.
        public var endsOfOver: [RADEEndOfOver]
    }

    private let rx: OpaquePointer
    private var pending: [Float] = []
    private var speechBuffer: [Float]
    private var samplesConsumed = 0
    public private(set) var status = RADEStatus()

    /// nil only if the library couldn't allocate its state.
    public init?() {
        guard let rx = ftx1_rade_rx_open() else { return nil }
        self.rx = rx
        speechBuffer = [Float](repeating: 0, count: Int(ftx1_rade_rx_speech_max(rx)))
        pending.reserveCapacity(Int(ftx1_rade_rx_nin_max(rx)) * 2)
    }

    deinit {
        ftx1_rade_rx_close(rx)
    }

    /// rade_c's API version, for logging.
    public static var libraryVersion: Int { Int(ftx1_rade_rade_version()) }

    /// Feeds any number of real 8 kHz modem samples (full scale ±1). Samples
    /// left over until the demodulator's next block are kept for the next call.
    public func process(_ samples: [Float]) -> Output {
        pending.append(contentsOf: samples)
        var speech: [Float] = []
        var endsOfOver: [RADEEndOfOver] = []
        var consumed = 0
        var raw = ftx1_rade_rx_status()

        while true {
            let nin = Int(ftx1_rade_rx_nin(rx))
            guard pending.count - consumed >= nin else { break }
            let written = pending.withUnsafeBufferPointer { input in
                speechBuffer.withUnsafeMutableBufferPointer { output in
                    ftx1_rade_rx_process(rx, input.baseAddress! + consumed, output.baseAddress!, &raw)
                }
            }
            consumed += nin
            samplesConsumed += nin
            if written > 0 {
                speech.append(contentsOf: speechBuffer[0..<Int(written)])
            }
            status = RADEStatus(sync: raw.sync != 0, frequencyOffsetHz: raw.freq_offset_hz, snrDB: raw.snr_db)
            if raw.end_of_over != 0 {
                endsOfOver.append(RADEEndOfOver(
                    sampleTime: samplesConsumed,
                    callsign: raw.callsign_valid != 0 ? Self.string(from: raw.callsign) : nil))
            }
        }
        pending.removeFirst(consumed)
        return Output(speech: speech, status: status, endsOfOver: endsOfOver)
    }

    private static func string<T>(from tuple: T) -> String {
        withUnsafeBytes(of: tuple) { bytes in
            let chars = bytes.prefix { $0 != 0 }
            return String(decoding: chars, as: UTF8.self)
        }
    }
}
