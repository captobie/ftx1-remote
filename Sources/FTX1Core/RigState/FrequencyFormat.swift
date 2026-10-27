import Foundation

/// The one place frequencies are turned into text for display. Never
/// locale-based: Spanish and German use "," as the decimal separator and
/// "." for grouping, which would turn "14.074" MHz into "14,074" — so every
/// frequency goes through here, in ham-radio style whatever the language.
public enum FrequencyFormat {
    /// Dot-grouped Hz like the rig's own display: 147380000 → "147.380.000",
    /// 475000 → "475.000". Built from integer arithmetic, so it can't pick
    /// up a locale's separators or digits.
    public static func dotted(_ hz: Int) -> String {
        let sign = hz < 0 ? "-" : ""
        var rest = abs(hz)
        var groups: [String] = []
        repeat {
            let group = rest % 1000
            rest /= 1000
            groups.append(rest > 0 ? String(format: "%03d", group) : String(group))
        } while rest > 0
        return sign + groups.reversed().joined(separator: ".")
    }

    /// MHz with a fixed number of decimals and a "." decimal point:
    /// 14074000 → "14.0740" (4 digits). `String(format:)` without a locale
    /// always uses ".".
    public static func mhz(_ hz: Double, fractionDigits: Int) -> String {
        String(format: "%.*f", fractionDigits, hz / 1_000_000)
    }

    public static func mhz(_ hz: Int, fractionDigits: Int) -> String {
        mhz(Double(hz), fractionDigits: fractionDigits)
    }

    /// Format style for MHz text fields: "." decimal point and no grouping
    /// in every locale, for both display and parsing.
    public static func mhzField(fractionLength: ClosedRange<Int>) -> FloatingPointFormatStyle<Double> {
        FloatingPointFormatStyle<Double>(locale: Locale(identifier: "en_US_POSIX"))
            .precision(.fractionLength(fractionLength))
            .grouping(.never)
    }
}
