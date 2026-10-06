import Foundation

/// One programmed memory channel, as read with the FTX-1's raw "MR"
/// (MEMORY CHANNEL READ) and "MT" (MEMORY CHANNEL TAG) commands — the
/// rows of the Mac's memory list window. A blank channel answers "MR" with
/// "?;" (hardware-checked 2026-10-06), so it never becomes an entry.
public struct MemoryChannelEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: Int { channel }

    /// `RigState.memoryChannelRange`.
    public let channel: Int
    public let frequencyHz: Int
    /// The raw "MR" P6 mode character (the same codes as "MD"). Kept raw
    /// rather than as a `RigMode` because a memory can hold modes `RigMode`
    /// has no case for (CW-L, FM-N, ...), which the list still names.
    public let modeCode: String
    /// "MR" P8: 0 OFF, 1 CTCSS ENC/DEC, 2 CTCSS ENC, 3 DCS, 4 PR FREQ,
    /// 5 REV TONE.
    public let toneMode: Int
    /// "MR" P10: 0 simplex, 1 plus shift, 2 minus shift.
    public let shift: Int
    /// From "MT", trimmed; nil when the channel has no tag.
    public var tag: String?

    public init(channel: Int, frequencyHz: Int, modeCode: String, toneMode: Int, shift: Int, tag: String?) {
        self.channel = channel
        self.frequencyHz = frequencyHz
        self.modeCode = modeCode
        self.toneMode = toneMode
        self.shift = shift
        self.tag = tag
    }

    /// Parses an "MR" answer, e.g. "MR00001431075000+000000H10000;":
    /// P1 channel (5), P2 frequency in Hz (9), P3 clarifier sign + offset
    /// (5), P4 RX CLAR, P5 TX CLAR, P6 mode, P7 VFO/memory type, P8 tone
    /// mode, P9 "00" (2), P10 shift — 27 characters after "MR". Nil for
    /// "?;" (blank channel) or anything else that doesn't fit.
    public init?(mrReply reply: String, tag: String? = nil) {
        guard reply.hasPrefix("MR") else { return nil }
        var body = Array(reply.dropFirst(2))
        if body.last == ";" { body.removeLast() }
        guard body.count == 27,
              let channel = Int(String(body[0..<5])),
              let hz = Int(String(body[5..<14])),
              let toneMode = body[23].wholeNumberValue,
              let shift = body[26].wholeNumberValue else { return nil }
        self.init(channel: channel, frequencyHz: hz, modeCode: String(body[21]), toneMode: toneMode, shift: shift, tag: tag)
    }

    /// The mode's name as the CAT manual's OPERATING MODE table spells it,
    /// or the raw code if it isn't in that table.
    public var modeName: String {
        switch modeCode {
        case "1": "LSB"
        case "2": "USB"
        case "3": "CW-U"
        case "4": "FM"
        case "5": "AM"
        case "6": "RTTY-L"
        case "7": "CW-L"
        case "8": "DATA-L"
        case "9": "RTTY-U"
        case "A": "DATA-FM"
        case "B": "FM-N"
        case "C": "DATA-U"
        case "D": "AM-N"
        case "E": "PSK"
        case "F": "DATA-FM-N"
        case "H": "C4FM-DN"
        case "I": "C4FM-VW"
        default: modeCode
        }
    }

    /// Short tone label for the list, empty when off.
    public var toneName: String {
        switch toneMode {
        case 1: "TSQL"
        case 2: "TONE"
        case 3: "DCS"
        case 4: "PR FREQ"
        case 5: "REV TONE"
        default: ""
        }
    }

    /// "+"/"−" for a repeater shift, empty for simplex.
    public var shiftName: String {
        switch shift {
        case 1: "+"
        case 2: "−"
        default: ""
        }
    }
}
