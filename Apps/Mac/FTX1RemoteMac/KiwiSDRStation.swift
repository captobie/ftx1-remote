import Foundation

/// One public KiwiSDR from the directory (`KiwiSDRDirectory`). Built from
/// one entry of `rx.linkfanel.net/kiwisdr_com.js`, where every value is a
/// string (checked against a live copy, 2026-09-24: 862 entries, no
/// non-string values).
nonisolated struct KiwiSDRStation: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let location: String
    let url: URL
    let latitude: Double?
    let longitude: Double?
    let grid: String
    let users: Int
    let usersMax: Int
    /// The listing's first "snr" figure (all-band; the second is HF-only).
    let snr: Int?
    let antenna: String
    /// Receive ranges in *displayed* Hz — they already include the Kiwi's
    /// `freq_offset`, so a converter-fed Kiwi (e.g. airband at 110–142 MHz)
    /// shows its real range, which is also what `?f=` expects.
    let bands: [ClosedRange<Int>]

    var isFull: Bool { usersMax > 0 && users >= usersMax }

    /// What goes in the WebSDR window's host field: the URL minus an
    /// `http://` scheme (kept for https, which `KiwiSDRURLBuilder` honors).
    var hostPort: String {
        let s = url.absoluteString
        let trimmed = s.hasPrefix("http://") ? String(s.dropFirst("http://".count)) : s
        return trimmed.hasSuffix("/") ? String(trimmed.dropLast()) : trimmed
    }

    func covers(frequencyHz: Int) -> Bool {
        bands.contains { $0.contains(frequencyHz) }
    }

    var bandsDescription: String {
        bands.map { KiwiSDRStation.describe($0) }.joined(separator: ", ")
    }

    /// "0–30 MHz", "1.8–30 MHz", or "10 kHz–30 MHz" for a nonzero lower
    /// bound below 1 MHz (which "0.0–30 MHz" would misrepresent).
    static func describe(_ range: ClosedRange<Int>) -> String {
        func mhz(_ hz: Int) -> String {
            let v = Double(hz) / 1_000_000
            return v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
        }
        let low = range.lowerBound
        if low > 0, low < 1_000_000 {
            return "\(low / 1000) kHz–\(mhz(range.upperBound)) MHz"
        }
        return "\(mhz(low))–\(mhz(range.upperBound)) MHz"
    }

    /// nil for entries missing a usable URL or marked offline.
    init?(entry: [String: String]) {
        guard entry["offline"] != "yes",
              let id = entry["id"], !id.isEmpty,
              let urlString = entry["url"], let url = URL(string: urlString), url.host != nil
        else { return nil }
        self.id = id
        self.url = url
        name = entry["name"] ?? urlString
        location = entry["loc"] ?? ""
        grid = entry["grid"] ?? ""
        users = Int(entry["users"] ?? "") ?? 0
        usersMax = Int(entry["users_max"] ?? "") ?? 0
        snr = (entry["snr"] ?? "").split(separator: ",").first.flatMap { Int($0) }
        antenna = entry["antenna"] ?? ""
        bands = KiwiSDRStation.parseBands(entry["bands"] ?? "")

        // "(43.057154, 141.776868)"
        let numbers = (entry["gps"] ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "() "))
            .split(separator: ",")
            .compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        if numbers.count == 2 {
            latitude = numbers[0]
            longitude = numbers[1]
        } else {
            latitude = nil
            longitude = nil
        }
    }

    /// "0-30000000" or "lo-hi,lo-hi". Falls back to KiwiSDR's standard
    /// 0–30 MHz if the field is missing or unparseable.
    static func parseBands(_ raw: String) -> [ClosedRange<Int>] {
        let ranges: [ClosedRange<Int>] = raw.split(separator: ",").compactMap { part in
            let ends = part.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard ends.count == 2, ends[0] <= ends[1] else { return nil }
            return ends[0]...ends[1]
        }
        return ranges.isEmpty ? KiwiSDRURLBuilder.defaultBands : ranges
    }
}

/// Maidenhead locator → coordinates and great-circle distance, for sorting
/// the directory by distance from `StationSettings.gridSquare`.
nonisolated enum Maidenhead {
    /// Center of a 4- or 6-character locator, or nil if malformed.
    static func coordinates(of locator: String) -> (latitude: Double, longitude: Double)? {
        let chars = Array(locator.uppercased())
        guard chars.count >= 4,
              let f0 = chars[0].asciiValue, let f1 = chars[1].asciiValue,
              (65...82).contains(f0), (65...82).contains(f1),
              let s0 = chars[2].wholeNumberValue, let s1 = chars[3].wholeNumberValue
        else { return nil }
        var lon = Double(f0 - 65) * 20 - 180 + Double(s0) * 2
        var lat = Double(f1 - 65) * 10 - 90 + Double(s1)
        if chars.count >= 6,
           let t0 = chars[4].asciiValue, let t1 = chars[5].asciiValue,
           (65...88).contains(t0), (65...88).contains(t1) {
            lon += Double(t0 - 65) * (2.0 / 24) + (1.0 / 24)
            lat += Double(t1 - 65) * (1.0 / 24) + (0.5 / 24)
        } else {
            lon += 1
            lat += 0.5
        }
        return (lat, lon)
    }

    static func distanceKm(from a: (latitude: Double, longitude: Double),
                           to b: (latitude: Double, longitude: Double)) -> Double {
        let r = 6371.0
        let dLat = (b.latitude - a.latitude) * .pi / 180
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2)
            + cos(a.latitude * .pi / 180) * cos(b.latitude * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(h)))
    }
}
