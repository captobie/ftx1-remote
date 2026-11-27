import CFTX1Rade

/// FreeDV RADE V1 transmitter: 16 kHz speech in, real 8 kHz modem audio out
/// (the real part, as an SSB transmitter sends it), at the modem's nominal
/// amplitude 1.0 — the FreeDV app sends that at half of full scale
/// (`nominalOutputScale`).
///
/// One instance per over: feed speech with `process`, end with `finish`
/// (the last frame and the end-of-over carrying the callsign). Not
/// thread-safe: use it from one serial queue (`@unchecked Sendable` only so
/// it can be handed to that queue).
public final class RADEEncoder: @unchecked Sendable {
    public static let speechSampleRate = RADEDecoder.speechSampleRate
    public static let modemSampleRate = RADEDecoder.modemSampleRate
    /// The FreeDV app's output scale for nominal amplitude 1.0: 16383 of
    /// 32767, leaving 6 dB for the OFDM peaks.
    public static let nominalOutputScale: Float = 16383.0 / 32767.0
    /// freedv-backend's RADETransmitStep sends 200 ms of silence after the
    /// end-of-over before the transmitter drops.
    public static let tailSilenceSeconds = 0.2

    private let tx: OpaquePointer
    private let frameLength = Int(FTX1_RADE_TX_SPEECH_FRAME)
    private var pending: [Float] = []
    private var modemBuffer: [Float]
    private var finishBuffer: [Float]
    private var finished = false

    /// nil only if the library couldn't allocate its state.
    public init?() {
        guard let tx = ftx1_rade_tx_open() else { return nil }
        self.tx = tx
        modemBuffer = [Float](repeating: 0, count: Int(ftx1_rade_tx_modem_max(tx)))
        finishBuffer = [Float](repeating: 0, count: Int(ftx1_rade_tx_finish_max(tx)))
    }

    deinit {
        ftx1_rade_tx_close(tx)
    }

    /// Feeds any amount of 16 kHz speech (±1). Returns the modem audio that
    /// became ready: a 120 ms frame (960 samples) per 120 ms of speech.
    public func process(_ speech: [Float]) -> [Float] {
        guard !finished else { return [] }
        pending.append(contentsOf: speech)
        var modem: [Float] = []
        var consumed = 0
        while pending.count - consumed >= frameLength {
            let written = pending.withUnsafeBufferPointer { input in
                modemBuffer.withUnsafeMutableBufferPointer { output in
                    ftx1_rade_tx_process(tx, input.baseAddress! + consumed, output.baseAddress!)
                }
            }
            consumed += frameLength
            if written > 0 { modem.append(contentsOf: modemBuffer[0..<Int(written)]) }
        }
        pending.removeFirst(consumed)
        return modem
    }

    /// Ends the over: the speech still buffered (zero-padded to a frame),
    /// then the end-of-over with `callsign` (first 8 characters, uppercased;
    /// nil or empty sends none). Later calls return nothing.
    public func finish(callsign: String?) -> [Float] {
        guard !finished else { return [] }
        // A partial 10 ms frame still waiting is padded with silence.
        var head: [Float] = []
        if !pending.isEmpty {
            let padded = pending + [Float](repeating: 0, count: frameLength - pending.count)
            pending = []
            head = process(padded)
        }
        finished = true
        return head + finishFrames(callsign: callsign)
    }

    private func finishFrames(callsign: String?) -> [Float] {
        let call = callsign.map { String($0.uppercased().prefix(Int(FTX1_RADE_CALLSIGN_MAX))) } ?? ""
        let written = call.withCString { pointer in
            finishBuffer.withUnsafeMutableBufferPointer { output in
                ftx1_rade_tx_finish(tx, call.isEmpty ? nil : pointer, output.baseAddress!)
            }
        }
        return Array(finishBuffer[0..<Int(written)])
    }
}
