import CFT8Lib

extension FT8Kit {
    /// Swift-friendly mirror of `ftx_field_t` (message.h) — what kind of
    /// token a slice of the decoded text represents.
    public enum FieldKind {
        case unknown
        case none
        case token          // RRR, RR73, 73, DE, QRZ, CQ, ...
        case tokenWithArg   // CQ nnn, CQ abcd
        case call
        case grid
        case rst

        init(_ raw: ftx_field_t) {
            switch raw {
            case FTX_FIELD_NONE: self = .none
            case FTX_FIELD_TOKEN: self = .token
            case FTX_FIELD_TOKEN_WITH_ARG: self = .tokenWithArg
            case FTX_FIELD_CALL: self = .call
            case FTX_FIELD_GRID: self = .grid
            case FTX_FIELD_RST: self = .rst
            default: self = .unknown
            }
        }
    }

    /// One space-separated token of a decoded message, classified by kind
    /// (e.g. distinguishing a callsign from a grid square from a report).
    public struct MessageField {
        public let kind: FieldKind
        public let text: String
    }

    /// Result of successfully decoding one FT8/FT4 candidate — a thin,
    /// faithful mirror of ft8_lib's own output, not yet mapped to this app's
    /// `FT8Spot` model (that mapping, including SNR-approximation caveats and
    /// PSK-Reporter-shaped fields, lives at the app layer).
    public struct RawMessage {
        /// Full decoded message text, e.g. "CQ TA6CQ KN70".
        public let text: String
        /// Classified space-separated tokens of `text`, in order.
        public let fields: [MessageField]
        public let frequencyOffsetHz: Double
        public let dtSeconds: Double
        /// Sync-candidate score (higher = more confident sync); not a calibrated SNR.
        public let score: Int
        public let ldpcErrors: Int
    }
}
