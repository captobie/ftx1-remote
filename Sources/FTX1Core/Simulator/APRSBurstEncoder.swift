import Foundation

/// One APRS packet as the Demo Mode rig hears it on 144.390 MHz.
struct SimulatedAPRSPacket: Sendable {
    var source: String
    var sourceSSID: Int
    /// The APRS info field, e.g. "!4142.50N/07243.20W>comment".
    var info: String
}

/// Encodes an APRS packet the way a TNC sends it — an AX.25 UI frame
/// (destination APZFTX, path WIDE1-1, FCS), HDLC bit stuffing between flag
/// runs, NRZI, and Bell 202 AFSK at 1200 baud (mark 1200 Hz, space
/// 2200 Hz, continuous phase) — for the Demo Mode audio. The inverse of
/// `AFSKDemodulator` + `AX25FrameDecoder` + `APRSPacket`, which decode it
/// in the app exactly as they decode the real thing.
enum APRSBurstEncoder {
    /// AFSK level on the FM audio: loud, as a real packet is.
    static let amplitude: Float = 0.3
    /// TXDELAY: ~0.2 s of flags for the receiver's bit clock to lock.
    static let leadFlags = 30
    static let tailFlags = 4

    /// The frame's bytes, FCS included (no flags).
    static func frame(_ packet: SimulatedAPRSPacket) -> [UInt8] {
        var bytes = address("APZFTX", ssid: 0, last: false)
        bytes += address(packet.source, ssid: packet.sourceSSID, last: false)
        bytes += address("WIDE1", ssid: 1, last: true)
        bytes += [0x03, 0xF0] // UI frame, no layer 3
        bytes += Array(packet.info.utf8)
        let fcs = AX25FCS.compute(bytes)
        bytes += [UInt8(fcs & 0xFF), UInt8(fcs >> 8)]
        return bytes
    }

    /// Line bits, LSB first: flags, the bit-stuffed frame, flags.
    static func lineBits(_ packet: SimulatedAPRSPacket) -> [Bool] {
        let flag = bits(of: 0x7E)
        var bits: [Bool] = []
        for _ in 0..<leadFlags { bits += flag }
        var ones = 0
        for bit in frame(packet).flatMap(Self.bits(of:)) {
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

    /// The burst's audio at `sampleRate`.
    static func render(_ packet: SimulatedAPRSPacket, sampleRate: Double) -> [Float] {
        let samplesPerBit = sampleRate / 1200
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(lineBits(packet).count) * samplesPerBit) + 1)
        // NRZI: a 0 is a change of tone, a 1 none.
        var mark = true
        var phase = 0.0
        var bitEnd = 0.0
        var index = 0
        for bit in lineBits(packet) {
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

    private static func address(_ callsign: String, ssid: Int, last: Bool) -> [UInt8] {
        var characters = Array(callsign.uppercased().utf8.prefix(6))
        while characters.count < 6 { characters.append(UInt8(ascii: " ")) }
        return characters.map { $0 << 1 } + [0x60 | UInt8(ssid & 0x0F) << 1 | (last ? 1 : 0)]
    }

    private static func bits(of byte: UInt8) -> [Bool] {
        (0..<8).map { byte >> $0 & 1 == 1 }
    }
}

extension SimulatedWorld {
    /// What the demo's APRS bursts carry, in turn: stations with positions
    /// around Newington, CT (grid FN31, the demo's own), a status, messages
    /// — one addressed to DEMO, the demo's own call — and a bulletin. All
    /// "DEMO" calls: none belongs to a real station.
    static let aprsPackets: [SimulatedAPRSPacket] = [
        SimulatedAPRSPacket(source: "DEMO", sourceSSID: 9, info: "!4142.50N/07243.20W>Demo mobile, 45 mph"),
        SimulatedAPRSPacket(source: "DEMO", sourceSSID: 1, info: "=4145.80N/07240.10W-Demo home station"),
        SimulatedAPRSPacket(source: "DEMO", sourceSSID: 1, info: ":DEMO     :Hello from the FTX1 Remote demo{01"),
        SimulatedAPRSPacket(source: "DEMO", sourceSSID: 10, info: "!4139.25N/07248.75W#Demo digipeater"),
        SimulatedAPRSPacket(source: "DEMO", sourceSSID: 7, info: "!4147.10N/07235.60W[Demo hiker on the ridge"),
        SimulatedAPRSPacket(source: "DEMO", sourceSSID: 5, info: ">Demo Mode status: all systems nominal"),
        SimulatedAPRSPacket(source: "DEMO", sourceSSID: 9, info: ":DEMO-1   :Meet you on the repeater{02"),
        SimulatedAPRSPacket(source: "DEMO", sourceSSID: 10, info: ":BLN1     :Demo net tonight 8 PM on 146.940"),
        SimulatedAPRSPacket(source: "DEMO", sourceSSID: 9, info: "!4143.90N/07241.05W>Demo mobile, parked"),
    ]

    func aprsPacket(forBurst index: Int) -> SimulatedAPRSPacket {
        Self.aprsPackets[index % Self.aprsPackets.count]
    }
}
