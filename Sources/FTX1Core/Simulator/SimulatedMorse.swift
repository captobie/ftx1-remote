import Foundation

/// Morse timing for the Demo Mode simulator (`SimulatedRig`): the CW
/// beacon's keying and the keyer memory's transmit time. PARIS timing — a
/// dit is 1.2/wpm s, a dah 3 units, 1 unit between elements, 3 between
/// characters, 7 between words — the same rule `CWSender.duration(of:wpm:)`
/// (FTX1CW) uses, so the sender's finish detection sees the length it
/// expects.
public enum SimulatedMorse {
    static let table: [Character: String] = [
        "A": ".-", "B": "-...", "C": "-.-.", "D": "-..", "E": ".", "F": "..-.", "G": "--.",
        "H": "....", "I": "..", "J": ".---", "K": "-.-", "L": ".-..", "M": "--", "N": "-.",
        "O": "---", "P": ".--.", "Q": "--.-", "R": ".-.", "S": "...", "T": "-", "U": "..-",
        "V": "...-", "W": ".--", "X": "-..-", "Y": "-.--", "Z": "--..",
        "0": "-----", "1": ".----", "2": "..---", "3": "...--", "4": "....-",
        "5": ".....", "6": "-....", "7": "--...", "8": "---..", "9": "----.",
        "/": "-..-.", "?": "..--..", ",": "--..--", ".": ".-.-.-", "=": "-...-",
        "+": ".-.-.", "-": "-....-", "(": "-.--.", ")": "-.--.-", "@": ".--.-.", ":": "---...",
    ]

    /// Key-down/key-up runs in units, starting with key down: `[on, off,
    /// on, off, ...]`. Unknown characters are skipped.
    static func units(of text: String) -> [Int] {
        var runs: [Int] = []
        func append(on: Bool, _ count: Int) {
            // Runs alternate on/off, starting on.
            if runs.count % 2 == (on ? 0 : 1) {
                runs.append(count)
            } else if !runs.isEmpty {
                runs[runs.count - 1] += count
            }
        }
        for (wordIndex, word) in text.uppercased().split(separator: " ").enumerated() {
            if wordIndex > 0, !runs.isEmpty { append(on: false, 7) }
            var first = true
            for character in word {
                guard let pattern = table[character] else { continue }
                if !first { append(on: false, 3) }
                first = false
                for (index, element) in pattern.enumerated() {
                    if index > 0 { append(on: false, 1) }
                    append(on: true, element == "-" ? 3 : 1)
                }
            }
        }
        return runs
    }

    /// Keying time of `text` at `wpm`, in seconds.
    public static func duration(of text: String, wpm: Int) -> TimeInterval {
        Double(units(of: text).reduce(0, +)) * 1.2 / Double(max(wpm, 1))
    }
}

/// A looping Morse transmission: `text` at `wpm`, then `gap` seconds of
/// silence, forever — the beacon's and the repeater ID's keying, as a pure
/// function of time so the audio and the S-meter agree.
struct MorseLoop: Sendable {
    /// Key-down intervals within one period, in seconds from its start.
    private let keyDown: [ClosedRange<Double>]
    let period: Double
    let unit: Double

    init(text: String, wpm: Int, gap: Double) {
        unit = 1.2 / Double(wpm)
        var intervals: [ClosedRange<Double>] = []
        var time = 0.0
        for (index, run) in SimulatedMorse.units(of: text).enumerated() {
            let length = Double(run) * unit
            if index % 2 == 0 { intervals.append(time...(time + length)) }
            time += length
        }
        keyDown = intervals
        period = time + gap
    }

    /// The key-down interval `t` falls in (seconds into the period), if any.
    func keyInterval(at t: Double) -> ClosedRange<Double>? {
        let phase = t.truncatingRemainder(dividingBy: period)
        guard phase >= 0 else { return nil }
        // Binary search: the intervals are sorted and disjoint.
        var low = 0
        var high = keyDown.count - 1
        while low <= high {
            let mid = (low + high) / 2
            let interval = keyDown[mid]
            if phase < interval.lowerBound {
                high = mid - 1
            } else if phase > interval.upperBound {
                low = mid + 1
            } else {
                return interval
            }
        }
        return nil
    }

    /// 0...1 key envelope at `t`, with `rise` seconds of raised-cosine
    /// shaping at each edge so the tone has no clicks.
    func envelope(at t: Double, rise: Double = 0.005) -> Double {
        let phase = t.truncatingRemainder(dividingBy: period)
        guard let interval = keyInterval(at: t) else { return 0 }
        let fromStart = phase - interval.lowerBound
        let toEnd = interval.upperBound - phase
        let edge = min(fromStart, toEnd)
        guard edge < rise else { return 1 }
        return 0.5 - 0.5 * cos(.pi * edge / rise)
    }

    /// Whether the transmission is running at `t` (not in the gap) — for
    /// the S-meter, which hangs across the short key-up gaps.
    func isSending(at t: Double) -> Bool {
        let phase = t.truncatingRemainder(dividingBy: period)
        return phase <= (keyDown.last?.upperBound ?? 0)
    }
}
