import Accelerate
import Combine
import Foundation

/// The Filter Function Display's spectrum on the iPad, computed from the
/// 8 kHz Int16 mono receive audio it already gets (the Mac's relay, or the
/// Pi-direct downsampler) — no waterfall or oscilloscope. 8 kHz covers
/// exactly the display's 0–4 kHz span, and a 512-point FFT gives 15.6 Hz
/// bins, about the Mac's resolution (21.5 Hz at 44.1 kHz / 2048).
///
/// Each chunk is appended to the last `fft.size` samples and the FFT runs
/// over those, so the display updates once per chunk (~21 a second from
/// the relay) whatever the chunk length. Only the selected filter side's
/// audio is used; a side switch starts over (buffer, auto-gain, spectrum).
/// Feed it before any mute/squelch/transmit check, or muting a side would
/// blank its display.
///
/// Its own `ObservableObject`, observed only by the display, so the
/// per-chunk publish never re-renders the rest of the screen (the
/// `ScopeFrameStore` rule, repo CLAUDE.md). Does nothing while
/// `isEnabled` is false (the display isn't on screen).
@MainActor
public final class FilterSpectrumStore: ObservableObject {
    @Published public private(set) var spectrum: [Float] = []

    public var isEnabled = false {
        didSet { if !isEnabled { reset() } }
    }

    /// The receiver whose audio is analyzed — `RigState.activeFilterSide`.
    public var selectedSide: FilterSide = .main {
        didSet { if selectedSide != oldValue { reset() } }
    }

    private let fft = SpectrumFFT(size: 512)
    private let sampleRate = AudioStreamFormat.sampleRate
    private var gain = SpectrumAutoGain()
    private var history: [Float] = []

    public init() {}

    /// One chunk of `side`'s 8 kHz Int16 little-endian mono PCM.
    public func ingest(pcm: Data, side: FilterSide) {
        guard isEnabled, side == selectedSide else { return }
        let count = pcm.count / MemoryLayout<Int16>.size
        guard count > 0 else { return }

        var samples = [Float](repeating: 0, count: count)
        pcm.withUnsafeBytes { raw in
            let ints = raw.bindMemory(to: Int16.self)
            vDSP_vflt16(ints.baseAddress!, 1, &samples, 1, vDSP_Length(count))
        }
        var scale = 1 / Float(Int16.max)
        vDSP_vsmul(samples, 1, &scale, &samples, 1, vDSP_Length(count))

        history.append(contentsOf: samples)
        if history.count > fft.size {
            history.removeFirst(history.count - fft.size)
        }
        // Wait for a full block rather than zero-pad the first ~64 ms.
        guard history.count == fft.size else { return }

        let db = fft.powerDb(history)
        let window = gain.update(db: db)
        spectrum = FilterSpectrum.normalized(db: db, floorDb: window.floorDb, ceilingDb: window.ceilingDb, binHz: fft.binHz(sampleRate: sampleRate))
    }

    /// Clears the buffer, auto-gain and spectrum (disconnect, side switch,
    /// display gone).
    public func reset() {
        history.removeAll(keepingCapacity: true)
        gain = SpectrumAutoGain()
        if !spectrum.isEmpty { spectrum = [] }
    }
}
