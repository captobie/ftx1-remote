import AVFoundation
import Accelerate
import FTX1Core

/// The keyboard modes Tools → RTTY/PSK decodes.
public enum DigiMode: String, CaseIterable, Sendable {
    case rtty
    case bpsk31
    case bpsk63

    /// Radio terms, not translated.
    public var title: String {
        switch self {
        case .rtty: "RTTY"
        case .bpsk31: "BPSK31"
        case .bpsk63: "BPSK63"
        }
    }

    public var isPSK: Bool { self != .rtty }

    var pskBaud: Double {
        self == .bpsk63 ? 62.5 : 31.25
    }

    /// Roughly how wide the signal is, for the tuning strip's marker.
    public func bandwidthHz(rtty: RTTYSettings) -> Double {
        switch self {
        case .rtty: rtty.shiftHz + rtty.baud
        case .bpsk31: 62.5
        case .bpsk63: 125
        }
    }
}

/// What one `DigiDecoder.process` call produced.
public struct DigiDecoderOutput: Sendable {
    public var text: String
    /// A new tuning-strip row (0…1 over `DigiDecoder.stripSpanHz`), about
    /// ten a second.
    public var spectrumRow: [Float]?
    /// The decoder's audio frequency after AFC.
    public var centerHz: Double
    public var quality: Float
}

/// Resample → demodulate → spectrum, for one mode and settings at a time.
/// Not thread-safe: `DigiReceiver` makes it on the main actor and from then
/// on uses it only on its one serial queue (hence `@unchecked Sendable`).
public final class DigiDecoder: @unchecked Sendable {
    public static let sampleRate: Double = 8000
    /// The tuning strip shows 0 … this.
    public static let stripSpanHz: Double = 3000
    static let fftSize = 2048
    /// A spectrum row every 800 samples (0.1 s).
    static let rowHop = 800

    public let mode: DigiMode
    public let rttySettings: RTTYSettings

    private let resampler = DigiResampler(targetRate: DigiDecoder.sampleRate)
    private var rtty: RTTYDemodulator?
    private var psk: PSKDemodulator?

    private let fft = SpectrumFFT(size: DigiDecoder.fftSize)
    private var autoGain = SpectrumAutoGain()
    private var history = [Float](repeating: 0, count: DigiDecoder.fftSize)
    private var samplesSinceRow = 0

    public init(mode: DigiMode, rttySettings: RTTYSettings, centerHz: Double, afc: Bool, squelch: Float) {
        self.mode = mode
        self.rttySettings = rttySettings
        switch mode {
        case .rtty:
            let demodulator = RTTYDemodulator(settings: rttySettings, centerHz: centerHz)
            demodulator.afcEnabled = afc
            rtty = demodulator
        case .bpsk31, .bpsk63:
            let demodulator = PSKDemodulator(baud: mode.pskBaud, centerHz: centerHz)
            demodulator.afcEnabled = afc
            demodulator.squelch = squelch
            psk = demodulator
        }
        rttySquelch = squelch
    }

    /// RTTY prints only above this quality too (noise otherwise prints a
    /// stream of random letters).
    private var rttySquelch: Float

    public var centerHz: Double { rtty?.centerHz ?? psk?.centerHz ?? 0 }
    public var quality: Float { rtty?.quality ?? psk?.quality ?? 0 }

    public func setCenter(_ hz: Double) {
        rtty?.setCenter(hz)
        psk?.setCenter(hz)
    }

    public func setAFC(_ on: Bool) {
        rtty?.afcEnabled = on
        psk?.afcEnabled = on
    }

    public func setSquelch(_ value: Float) {
        rttySquelch = value
        psk?.squelch = value
    }

    /// Drops filter and framing state (after a pause or a source switch).
    public func reset() {
        rtty?.reset()
        psk?.reset()
        resampler.reset()
    }

    /// `samples` at any rate; resampled to 8 kHz here.
    public func process(samples: [Float], sampleRate: Double) -> DigiDecoderOutput {
        let audio = sampleRate == Self.sampleRate ? samples : resampler.convert(samples, sourceRate: sampleRate)
        return process8k(audio)
    }

    func process8k(_ audio: [Float]) -> DigiDecoderOutput {
        var text = ""
        if let rtty {
            let decoded = rtty.process(audio)
            if rtty.quality >= rttySquelch { text = decoded }
        } else if let psk {
            text = psk.process(audio)
        }
        return DigiDecoderOutput(text: text, spectrumRow: spectrum(audio), centerHz: centerHz, quality: quality)
    }

    private func spectrum(_ audio: [Float]) -> [Float]? {
        guard !audio.isEmpty else { return nil }
        if audio.count >= history.count {
            history = Array(audio.suffix(history.count))
        } else {
            history.removeFirst(audio.count)
            history.append(contentsOf: audio)
        }
        samplesSinceRow += audio.count
        guard samplesSinceRow >= Self.rowHop else { return nil }
        samplesSinceRow = 0
        let db = fft.powerDb(history)
        let binHz = fft.binHz(sampleRate: Self.sampleRate)
        let bins = min(db.count, Int(Self.stripSpanHz / binHz))
        let shown = Array(db.prefix(bins))
        let window = autoGain.update(db: shown)
        return FilterSpectrum.normalized(db: shown, floorDb: window.floorDb, ceilingDb: window.ceilingDb, binHz: binHz)
    }
}

/// Streaming resampler to mono `targetRate`, one long-lived
/// `AVAudioConverter` so its filter state carries across chunks (the same
/// as the Mac's `FT8Resampler`).
final class DigiResampler {
    private var converter: AVAudioConverter?
    private var sourceFormat: AVAudioFormat?
    private let targetFormat: AVAudioFormat
    private let targetRate: Double

    init(targetRate: Double) {
        self.targetRate = targetRate
        targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: targetRate, channels: 1, interleaved: false)!
    }

    func convert(_ samples: [Float], sourceRate: Double) -> [Float] {
        guard !samples.isEmpty, sourceRate > 0 else { return [] }
        if sourceFormat?.sampleRate != sourceRate {
            guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 1, interleaved: false)
            else { return [] }
            sourceFormat = format
            converter = AVAudioConverter(from: format, to: targetFormat)
        }
        guard let converter, let sourceFormat,
              let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return [] }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { pointer in
            input.floatChannelData?[0].update(from: pointer.baseAddress!, count: samples.count)
        }
        let capacity = AVAudioFrameCount((Double(samples.count) * targetRate / sourceRate).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return [] }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return input
        }
        guard status != .error, let data = output.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }

    func reset() {
        converter?.reset()
    }
}
