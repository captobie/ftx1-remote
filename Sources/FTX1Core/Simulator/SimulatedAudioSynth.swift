import Foundation

/// The Demo Mode rig's USB audio, rendered from what each receiver is tuned
/// to (`SimulatedRig.audioSnapshot()`) and what's on the air
/// (`SimulatedWorld`), so tuning matters:
///  - below 30 MHz, band noise at about 0.02 RMS — like the real rig's,
///    enough to keep the default squelch shut, so SQL has to come down;
///  - the CW beacon near 14.047.5 MHz as a tone at the offset a real
///    receiver would give it: the CW pitch when tuned to it in CW, the beat
///    note in SSB, quieter outside a CW filter;
///  - on V/UHF FM, near silence without a carrier (the rig's unsquelched
///    USB audio), the repeater's CW ID and courtesy beep while it's up,
///    and APRS bursts on 144.390 (`aprsBurst`);
///  - almost nothing while transmitting.
/// L and R are the two physical receivers, so after a swap the audio stays
/// with the receiver, as on the real rig.
///
/// Not thread-safe: one instance per audio stream, called from its queue.
final class SimulatedAudioSynth: @unchecked Sendable {
    private let rig: SimulatedRig
    private let sampleRate: Double
    /// Rendered APRS burst `index` at `sampleRate`, or nil (no bursts).
    private let aprsBurst: ((Int) -> [Float])?
    private var left = ChannelState(seed: 0x1234_5678)
    private var right = ChannelState(seed: 0x8765_4321)
    private var cachedBurst: (index: Int, samples: [Float])?

    init(rig: SimulatedRig, sampleRate: Double = SimulatedAudioServer.sampleRate, aprsBurst: ((Int) -> [Float])? = nil) {
        self.rig = rig
        self.sampleRate = sampleRate
        self.aprsBurst = aprsBurst
    }

    /// Fills the next `left.count` samples of both channels.
    func render(left leftOut: inout [Float], right rightOut: inout [Float]) {
        let snapshot = rig.audioSnapshot()
        render(snapshot.left, transmitting: snapshot.transmitting, start: snapshot.elapsed, state: &left, into: &leftOut)
        render(snapshot.right, transmitting: snapshot.transmitting, start: snapshot.elapsed, state: &right, into: &rightOut)
    }

    private func render(_ receiver: SimulatedRig.ReceiverAudio, transmitting: Bool, start: Double, state: inout ChannelState, into out: inout [Float]) {
        let world = rig.world
        let mode = receiver.modeCode
        let fm = SimulatedWorld.isFMCode(mode)
        let hf = receiver.hz < 30_000_000

        // Noise floor by band and mode.
        var noiseRMS: Float = hf ? 0.02 : (fm ? 0.002 : 0.004)
        if transmitting || !receiver.receiving { noiseRMS = transmitting ? 0.0005 : 0 }

        // The beacon's tone, if this receiver can hear it.
        var beaconTone: Double?
        var beaconGain: Float = 0
        if !transmitting, receiver.receiving, abs(receiver.hz - SimulatedWorld.beaconHz) <= 3000 {
            let offset = Double(SimulatedWorld.beaconHz - receiver.hz)
            let pitch = Double(receiver.cwPitchHz)
            switch mode {
            case "3": beaconTone = pitch + offset          // CW-U
            case "7": beaconTone = pitch - offset          // CW-L
            case "2", "C", "9": beaconTone = offset        // USB, DATA-U, RTTY-U
            case "1", "8", "6": beaconTone = -offset       // LSB, DATA-L, RTTY-L
            default: beaconTone = nil
            }
            if let tone = beaconTone, tone > 150, tone < 3000 {
                // A CW filter (~500 Hz around the pitch) passes it; outside
                // it, only a little leaks through.
                let inCWFilter = abs(tone - pitch) <= 300
                beaconGain = ("37".contains(mode) && !inCWFilter) ? 0.02 : 0.12
            } else {
                beaconTone = nil
            }
        }

        // FM signals near this frequency.
        let onRepeater = fm && abs(receiver.hz - SimulatedWorld.repeaterHz) <= 7500 && receiver.receiving && !transmitting
        let onAPRS = fm && abs(receiver.hz - SimulatedWorld.aprsHz) <= 7500 && receiver.receiving && !transmitting

        let dt = 1 / sampleRate
        for index in out.indices {
            let t = start + Double(index) * dt
            var sample = noiseRMS == 0 ? 0 : state.noise() * noiseRMS

            if let tone = beaconTone {
                let envelope = Float(world.beacon.envelope(at: t))
                state.beaconPhase += 2 * .pi * tone * dt
                if envelope > 0 { sample += beaconGain * envelope * Float(sin(state.beaconPhase)) }
            }

            if onRepeater, let up = world.repeaterOffset(at: t) {
                // A carrier quiets the noise; then the ID and the beep.
                sample *= 0.2
                let id = Float(world.repeaterID.envelope(at: max(0, up - 0.6)))
                if up >= 0.6, id > 0 {
                    state.repeaterPhase += 2 * .pi * 900 * dt
                    sample += 0.25 * id * Float(sin(state.repeaterPhase))
                } else if up > SimulatedWorld.repeaterLength - 0.5, up < SimulatedWorld.repeaterLength - 0.2 {
                    state.repeaterPhase += 2 * .pi * 1200 * dt
                    sample += 0.2 * Float(sin(state.repeaterPhase))
                }
            }

            if onAPRS, let aprsBurst, let burst = world.aprsBurst(at: t) {
                let samples: [Float]
                if let cachedBurst, cachedBurst.index == burst.index {
                    samples = cachedBurst.samples
                } else {
                    samples = aprsBurst(burst.index)
                    cachedBurst = (burst.index, samples)
                }
                let position = Int(burst.offset * sampleRate)
                // The carrier quiets the noise for the whole burst.
                sample *= 0.2
                if position < samples.count { sample += samples[position] }
            }

            out[index] = sample
        }
        state.beaconPhase = state.beaconPhase.truncatingRemainder(dividingBy: 2 * .pi)
        state.repeaterPhase = state.repeaterPhase.truncatingRemainder(dividingBy: 2 * .pi)
    }
}

/// One channel's running state: band-limited noise and tone phases.
private struct ChannelState {
    var beaconPhase = 0.0
    var repeaterPhase = 0.0
    private var random: UInt64
    // ~300 Hz high-pass, two ~2.7 kHz low-pass poles at 44.1 kHz: the
    // rig's SSB passband, roughly.
    private var highPassIn: Float = 0
    private var highPassOut: Float = 0
    private var lowPass1: Float = 0
    private var lowPass2: Float = 0
    private static let highPassCoefficient: Float = 0.958
    private static let lowPassCoefficient: Float = 0.32
    /// Scales the filtered noise to 1 RMS (measured once).
    private static let normalization: Float = {
        var probe = ChannelState(seed: 42, normalization: 1)
        var sum: Float = 0
        let count = 44_100
        for _ in 0..<count {
            let value = probe.noise()
            sum += value * value
        }
        return 1 / (sum / Float(count)).squareRoot()
    }()
    private let scale: Float

    init(seed: UInt64) {
        self.init(seed: seed, normalization: Self.normalization)
    }

    private init(seed: UInt64, normalization: Float) {
        random = seed
        scale = normalization
    }

    /// Band-limited Gaussian-ish noise, 1 RMS.
    mutating func noise() -> Float {
        // Sum of four uniforms: close enough to Gaussian for band noise.
        var white: Float = 0
        for _ in 0..<4 {
            random ^= random << 13
            random ^= random >> 7
            random ^= random << 17
            white += Float(random >> 40) / Float(1 << 24) - 0.5
        }
        let highPassed = Self.highPassCoefficient * (highPassOut + white - highPassIn)
        highPassIn = white
        highPassOut = highPassed
        lowPass1 += Self.lowPassCoefficient * (highPassed - lowPass1)
        lowPass2 += Self.lowPassCoefficient * (lowPass1 - lowPass2)
        return lowPass2 * scale
    }
}
