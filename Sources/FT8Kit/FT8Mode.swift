import CFT8Lib

/// Namespace for the FT8Kit public API.
public enum FT8Kit {}

extension FT8Kit {
    /// The digital mode being decoded. `ft8_lib`'s vendored core shares its
    /// LDPC(174,91) code between FT4 and FT8 — only slot/symbol timing and
    /// the sync pattern differ.
    public enum Mode: Sendable {
        case ft8
        case ft4

        /// "FT8"/"FT4" — the ADIF/PSK Reporter mode name.
        public var name: String {
            switch self {
            case .ft8: return "FT8"
            case .ft4: return "FT4"
            }
        }

        var protocolValue: ftx_protocol_t {
            switch self {
            case .ft8: return FTX_PROTOCOL_FT8
            case .ft4: return FTX_PROTOCOL_FT4
            }
        }

        public var slotTimeSeconds: Double {
            switch self {
            case .ft8: return Double(FT8_SLOT_TIME)
            case .ft4: return Double(FT4_SLOT_TIME)
            }
        }

        public var symbolPeriodSeconds: Double {
            switch self {
            case .ft8: return Double(FT8_SYMBOL_PERIOD)
            case .ft4: return Double(FT4_SYMBOL_PERIOD)
            }
        }

        /// Number of samples `FT8Decoder.process(block:)` expects per call at the given sample rate.
        public func blockSize(sampleRate: Double) -> Int {
            Int((sampleRate * symbolPeriodSeconds).rounded())
        }
    }
}
