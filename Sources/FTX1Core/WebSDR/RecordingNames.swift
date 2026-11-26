import Foundation

/// The one naming scheme for every recording the apps make: "Recording
/// 2026-09-24 07.47.30 14.074.000 USB.wav" — the Mac's rig recordings
/// (`AudioRecorder`) and the KiwiSDR/WebSDR/MyKiwiSDR files, whose label
/// ends in the source's name. Shared so the WebSDR page's recorder
/// (`SDRPageBridge`) can live in FTX1Core.
public enum RecordingNames {
    public static func url(label: String, date: Date, in directory: URL) -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let sanitizedLabel = label.replacingOccurrences(of: "/", with: "-")
        let base = sanitizedLabel.isEmpty
            ? "Recording \(formatter.string(from: date))"
            : "Recording \(formatter.string(from: date)) \(sanitizedLabel)"
        return directory.appendingPathComponent(base).appendingPathExtension("wav")
    }

    /// "147.380.000 FM" — dot-grouped like the VFO boxes, so a file name
    /// reads the way the rig's own display does.
    public static func label(frequencyHz: Int, mode: RigMode) -> String {
        label(frequencyHz: frequencyHz, modeName: mode.displayName)
    }

    public static func label(frequencyHz: Int, modeName: String) -> String {
        let frequency = FrequencyFormat.dotted(frequencyHz)
        return modeName.isEmpty ? frequency : "\(frequency) \(modeName)"
    }
}
