import Foundation

/// Builds what a TNC sends for one APRS packet: an AX.25 UI frame
/// (addresses, control 0x03, PID 0xF0, info, FCS), HDLC flags with bit
/// stuffing, NRZI, and Bell 202 AFSK at 1200 baud (mark 1200 Hz, space
/// 2200 Hz, continuous phase). The inverse of `AFSKDemodulator` +
/// `AX25FrameDecoder`; used by the Mac's APRS transmitter and the Demo Mode
/// simulator (`APRSBurstEncoder`).
public enum AX25Encoder {
    /// An address as typed: "N0CALL", "N0CALL-9", "WIDE2-1". nil when the
    /// callsign is empty, longer than 6 characters, not letters/digits, or
    /// the SSID isn't 0–15.
    public static func address(_ text: String) -> (callsign: String, ssid: Int)? {
        let parts = text.trimmingCharacters(in: .whitespaces).uppercased().split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2 else { return nil }
        let callsign = String(parts[0])
        guard (1...6).contains(callsign.count),
              callsign.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        var ssid = 0
        if parts.count == 2 {
            guard let value = Int(parts[1]), (0...15).contains(value) else { return nil }
            ssid = value
        }
        return (callsign, ssid)
    }

    /// A digipeater path as typed ("WIDE1-1,WIDE2-1"); empty text = no
    /// path. nil when an entry isn't a valid address or there are more
    /// than 8.
    public static func path(_ text: String) -> [(callsign: String, ssid: Int)]? {
        let entries = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard entries.count <= 8 else { return nil }
        var result: [(callsign: String, ssid: Int)] = []
        for entry in entries {
            guard let parsed = address(entry) else { return nil }
            result.append(parsed)
        }
        return result
    }

    /// The frame's bytes, FCS included (no flags).
    public static func frame(destination: (callsign: String, ssid: Int),
                             source: (callsign: String, ssid: Int),
                             path: [(callsign: String, ssid: Int)],
                             info: [UInt8]) -> [UInt8] {
        var bytes = encodeAddress(destination.callsign, ssid: destination.ssid, last: false)
        bytes += encodeAddress(source.callsign, ssid: source.ssid, last: path.isEmpty)
        for (index, hop) in path.enumerated() {
            bytes += encodeAddress(hop.callsign, ssid: hop.ssid, last: index == path.count - 1)
        }
        bytes += [0x03, 0xF0] // UI frame, no layer 3
        bytes += info
        let fcs = AX25FCS.compute(bytes)
        bytes += [UInt8(fcs & 0xFF), UInt8(fcs >> 8)]
        return bytes
    }

    /// Line bits, LSB first: `leadFlags` flags, the bit-stuffed frame,
    /// `tailFlags` flags.
    public static func lineBits(frame: [UInt8], leadFlags: Int, tailFlags: Int) -> [Bool] {
        let flag = bits(of: 0x7E)
        var bits: [Bool] = []
        bits.reserveCapacity((leadFlags + tailFlags) * 8 + frame.count * 10)
        for _ in 0..<leadFlags { bits += flag }
        var ones = 0
        for bit in frame.flatMap(Self.bits(of:)) {
            bits.append(bit)
            ones = bit ? ones + 1 : 0
            if ones == 5 {
                bits.append(false)
                ones = 0
            }
        }
        for _ in 0..<tailFlags { bits += flag }
        return bits
    }

    /// Bell 202 audio for the line bits at `sampleRate` (NRZI: a 0 is a
    /// change of tone, a 1 none; starts on mark).
    public static func afsk(lineBits: [Bool], sampleRate: Double, amplitude: Float) -> [Float] {
        let samplesPerBit = sampleRate / 1200
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(lineBits.count) * samplesPerBit) + 1)
        var mark = true
        var phase = 0.0
        var bitEnd = 0.0
        var index = 0
        for bit in lineBits {
            if !bit { mark.toggle() }
            let step = 2 * Double.pi * (mark ? 1200 : 2200) / sampleRate
            bitEnd += samplesPerBit
            while Double(index) < bitEnd {
                samples.append(amplitude * Float(sin(phase)))
                phase += step
                index += 1
            }
            phase = phase.truncatingRemainder(dividingBy: 2 * .pi)
        }
        return samples
    }

    /// Flags for `seconds` of preamble (TXDELAY) at 1200 baud, at least 2.
    public static func flags(forSeconds seconds: Double) -> Int {
        max(2, Int((seconds * 1200 / 8).rounded(.up)))
    }

    private static func encodeAddress(_ callsign: String, ssid: Int, last: Bool) -> [UInt8] {
        var characters = Array(callsign.uppercased().utf8.prefix(6))
        while characters.count < 6 { characters.append(UInt8(ascii: " ")) }
        return characters.map { $0 << 1 } + [0x60 | UInt8(ssid & 0x0F) << 1 | (last ? 1 : 0)]
    }

    private static func bits(of byte: UInt8) -> [Bool] {
        (0..<8).map { byte >> $0 & 1 == 1 }
    }
}
