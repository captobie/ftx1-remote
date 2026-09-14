import CFT8Lib

/// Namespace for the FT8Kit public API.
public enum FT8Kit {}

extension FT8Kit {
    /// The digital mode being decoded. `ft8_lib`'s vendored core already shares
    /// its LDPC(174,91) code between FT4 and FT8 — only slot/symbol timing and
    /// the sync pattern differ — so adding FT4 later is a matter of wiring this
    /// case through, not a decoder rewrite.
    public enum Mode {
        case ft8
        case ft4

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
