import Foundation

/// What the Demo Mode rig "hears": a few fixed signals, each a pure
/// function of time (seconds since the simulator started), so the audio
/// stream, the S-meters and the memory scan's busy check all agree.
///
/// - A CW beacon on 14.047.5 MHz sending practice text (`beacon`).
/// - A 2 m repeater on 146.940 MHz that comes up for a few seconds every
///   45 s with a CW ID and a courtesy beep — what makes the memory scan
///   pause.
/// - APRS packets on 144.390 MHz every 20–40 s (`aprsBursts`), rendered as
///   Bell 202 AFSK by `APRSBurstEncoder`.
/// - HF band noise below 30 MHz; V/UHF FM is quiet without a carrier, like
///   the real rig's unsquelched USB audio (S-meter exactly S0).
struct SimulatedWorld: Sendable {
    static let beaconHz = 14_047_500
    static let repeaterHz = 146_940_000
    static let aprsHz = 144_390_000

    /// Practice text, as W1AW sends it: long enough to show the decoder
    /// working, short enough to loop.
    static let beaconText = "VVV VVV CQ CQ DE DEMO DEMO = THIS IS THE FTX1 REMOTE DEMO MODE CW BEACON = THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG 1234567890 = DE DEMO AR"
    let beacon = MorseLoop(text: SimulatedWorld.beaconText, wpm: 18, gap: 4)

    /// The repeater keys up `repeaterLength` s every `repeaterPeriod` s,
    /// from `repeaterFirst` s on.
    static let repeaterFirst = 12.0
    static let repeaterPeriod = 45.0
    static let repeaterLength = 8.0
    /// Its ID, starting 0.6 s into each key-up (one pass: the gap is longer
    /// than the window).
    let repeaterID = MorseLoop(text: "DE DEMO/R", wpm: 20, gap: 60)

    /// Start times of the APRS bursts, ascending; `aprsBurstLength` s each.
    let aprsBurstStarts: [Double]
    static let aprsBurstLength = 1.2

    init() {
        // Deterministic 20–40 s spacing, the first one soon after start so
        // the lists fill quickly. ~28 h of bursts.
        var starts: [Double] = []
        var time = 6.0
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for _ in 0..<4000 {
            starts.append(time)
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            time += 20 + Double(state % 2001) / 100
        }
        aprsBurstStarts = starts
    }

    /// The burst playing at `t`: its index and how far into it `t` is.
    func aprsBurst(at t: Double) -> (index: Int, offset: Double)? {
        var low = 0
        var high = aprsBurstStarts.count - 1
        var found: Int?
        while low <= high {
            let mid = (low + high) / 2
            if aprsBurstStarts[mid] <= t {
                found = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        guard let found else { return nil }
        let offset = t - aprsBurstStarts[found]
        return offset < Self.aprsBurstLength ? (found, offset) : nil
    }

    /// Seconds into the current repeater key-up, if it's up at `t`.
    func repeaterOffset(at t: Double) -> Double? {
        guard t >= Self.repeaterFirst else { return nil }
        let phase = (t - Self.repeaterFirst).truncatingRemainder(dividingBy: Self.repeaterPeriod)
        return phase < Self.repeaterLength ? phase : nil
    }

    /// What a receiver tuned to `hz` in `modeCode` (the "MD" P2 code)
    /// gets at `t`.
    func reception(hz: Int, modeCode: Character, at t: Double) -> SimulatedReception {
        var reception = SimulatedReception(strengthDb: hz < 30_000_000 ? -36 : -54, busy: false)
        if abs(hz - Self.beaconHz) <= 2500, beacon.isSending(at: t) {
            // S8; HF channels never count as busy (the scan only stops on
            // FM carriers, see `SimulatedRig`).
            reception.strengthDb = -6
        }
        let fm = Self.isFMCode(modeCode)
        if abs(hz - Self.repeaterHz) <= 7500, repeaterOffset(at: t) != nil {
            reception.strengthDb = 20
            reception.busy = fm
        }
        if abs(hz - Self.aprsHz) <= 7500, aprsBurst(at: t) != nil {
            reception.strengthDb = 10
            reception.busy = fm
        }
        return reception
    }

    /// FM, DATA-FM, FM-N, DATA-FM-N, C4FM-DN/VW.
    static func isFMCode(_ code: Character) -> Bool {
        "4ABFHI".contains(code)
    }
}

struct SimulatedReception: Equatable {
    /// dB relative to S9 (hamlib "STRENGTH"): -54 is S0.
    var strengthDb: Double
    /// A carrier the memory scan stops on.
    var busy: Bool
}
