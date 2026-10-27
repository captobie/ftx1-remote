import Foundation

/// Which `rigctld` executable Local mode launches, and how that choice is
/// turned into a path (see repo root CLAUDE.md, "Bundled rigctld").
///
/// The app ships its own static Hamlib build in `Contents/Helpers/rigctld`
/// as a fallback: the FTX-1 (model 1051) first appears in Hamlib 4.7, and
/// an older installed rigctld just exits at once when started with it.
/// Automatic prefers a suitable installed copy (it may be newer, e.g. a
/// Homebrew upgrade with backend fixes) and falls back to the built-in one.
///
/// Everything here is `nonisolated`: the probes run external processes and
/// must stay off the main actor.
nonisolated enum RigctldBinary {
    enum Choice: Equatable, Hashable, Sendable {
        /// The first installed copy in `searchPaths` that's new enough and
        /// knows the model, else the built-in one.
        case automatic
        case builtIn
        /// Used as is, even if too old (with a warning in Settings).
        case path(String)

        fileprivate var storedValue: String {
            switch self {
            case .automatic: "automatic"
            case .builtIn: "builtin"
            case .path(let path): path
            }
        }

        fileprivate init(storedValue: String) {
            switch storedValue {
            case "", "automatic": self = .automatic
            case "builtin": self = .builtIn
            default: self = .path(storedValue)
            }
        }
    }

    /// Where Homebrew (Apple silicon, Intel) and MacPorts install rigctld,
    /// in the order Automatic tries them.
    static let standardSearchPaths = [
        "/opt/homebrew/bin/rigctld",
        "/usr/local/bin/rigctld",
        "/opt/local/bin/rigctld",
    ]

    /// `standardSearchPaths`, or in Debug builds the `rigctld.
    /// searchPathsOverride` defaults array if set — for testing the
    /// fallback without uninstalling Hamlib, e.g.
    /// `defaults write com.ftx1remote.FTX1RemoteMac rigctld.searchPathsOverride -array /tmp/fake/rigctld`.
    static var searchPaths: [String] {
        #if DEBUG
        if let override = UserDefaults.standard.stringArray(forKey: "rigctld.searchPathsOverride") {
            return override
        }
        #endif
        return standardSearchPaths
    }

    /// The oldest Hamlib with the FTX-1 backend.
    static let minimumVersion = HamlibVersion(major: 4, minor: 7, patch: 0)

    static var builtInPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/rigctld").path
    }

    // MARK: - Persisted choice

    static let choiceKey = "rigctld.binaryChoice"

    /// Before Automatic existed, `RigctldSettings.binaryPathKey` held a
    /// plain path (default /opt/homebrew/bin/rigctld). On first read a
    /// standard Homebrew path there becomes Automatic; a path the user
    /// chose themselves stays as `.path`. A separate key, so that picking
    /// /opt/homebrew/bin/rigctld explicitly later isn't migrated again.
    static var choice: Choice {
        get {
            if let stored = UserDefaults.standard.string(forKey: choiceKey) {
                return Choice(storedValue: stored)
            }
            guard let legacy = UserDefaults.standard.string(forKey: RigctldSettings.binaryPathKey),
                  !["/opt/homebrew/bin/rigctld", "/usr/local/bin/rigctld"].contains(legacy) else {
                return .automatic
            }
            return .path(legacy)
        }
        set { UserDefaults.standard.set(newValue.storedValue, forKey: choiceKey) }
    }

    // MARK: - Probing

    struct Probe: Equatable, Sendable {
        var path: String
        /// The line `--version` printed, without the "rigctld " prefix,
        /// e.g. "Hamlib 4.7.2 2026-06-21T13:07:37Z SHA=40f63488f 64-bit".
        var versionLine: String?
        var version: HamlibVersion?
        /// Whether `rigctld -l` lists the model; nil if `-l` didn't run.
        var listsModel: Bool?

        var shortVersion: String { version.map { "Hamlib \($0)" } ?? String(localized: "rigctldBinary.unknownVersion") }

        func isSuitable(for model: Int) -> Bool {
            guard let version, version >= RigctldBinary.minimumVersion else { return false }
            return listsModel == true
        }

        /// Why this copy can't drive the rig, or nil if it can.
        func problem(for model: Int) -> String? {
            guard versionLine != nil else { return String(localized: "rigctldBinary.didntAnswerVersion \(path)") }
            guard let version else { return String(localized: "rigctldBinary.reportedNoHamlibVersion \(path)") }
            if version < RigctldBinary.minimumVersion {
                return String(localized: "rigctldBinary.isTooOldFor \(path) \(version) \(RigctldBinary.rigName(model))")
            }
            if listsModel != true {
                return String(localized: "rigctldBinary.doesntList \(path) \(version) \(RigctldBinary.rigName(model))")
            }
            return nil
        }
    }

    static func rigName(_ model: Int) -> String {
        model == 1051 ? String(localized: "rigctldBinary.theFtx1") : String(localized: "rigctldBinary.model \(model)")
    }

    /// Runs `--version` and `-l` on `path`, each capped at a few seconds
    /// so a binary that hangs can't stall the connect.
    static func probe(_ path: String, model: Int) async -> Probe {
        var result = Probe(path: path)
        guard let versionOutput = await run(path, ["--version"], timeout: .seconds(3)) else { return result }
        let line = versionOutput.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        result.versionLine = line.hasPrefix("rigctld ") ? String(line.dropFirst("rigctld ".count)) : line
        result.version = HamlibVersion(parsing: line)
        if let list = await run(path, ["-l"], timeout: .seconds(5)) {
            result.listsModel = list.split(whereSeparator: \.isNewline).contains {
                $0.split(separator: " ", omittingEmptySubsequences: true).first == "\(model)"[...]
            }
        }
        return result
    }

    // MARK: - Resolution

    struct Resolution: Equatable, Sendable {
        /// What to launch; nil when nothing usable was found (only if the
        /// built-in copy is missing from the bundle).
        var path: String?
        var isBuiltIn: Bool
        /// One sentence for Settings and the log, e.g. "Using built-in
        /// Hamlib 4.7.2 — /opt/homebrew/bin/rigctld is 4.5.5, too old for
        /// the FTX-1."
        var summary: String
        /// Set when an explicitly chosen copy looks unable to drive the rig.
        var warning: String?
    }

    static func resolve(_ choice: Choice, model: Int) async -> Resolution {
        switch choice {
        case .automatic:
            var rejected: [String] = []
            for path in searchPaths where FileManager.default.isExecutableFile(atPath: path) {
                let probe = await probe(path, model: model)
                if probe.isSuitable(for: model) {
                    let skipped = rejected.isEmpty ? "" : " — " + rejected.joined(separator: "; ")
                    return Resolution(path: path, isBuiltIn: false,
                                      summary: String(localized: "rigctldBinary.usingInstalled \(path) \(probe.shortVersion) \(skipped)"))
                }
                rejected.append(probe.problem(for: model) ?? String(localized: "rigctldBinary.isUnusable \(path)"))
            }
            let because = rejected.isEmpty ? String(localized: "rigctldBinary.noInstalledRigctldFound") : rejected.joined(separator: "; ")
            return await builtIn(reason: because)
        case .builtIn:
            return await builtIn(reason: "chosen in Settings")
        case .path(let path):
            guard FileManager.default.isExecutableFile(atPath: path) else {
                return Resolution(path: path, isBuiltIn: false,
                                  summary: String(localized: "rigctldBinary.usingChosenInSettings \(path)"),
                                  warning: String(localized: "rigctldBinary.noRigctldAtThis"))
            }
            let probe = await probe(path, model: model)
            return Resolution(path: path, isBuiltIn: false,
                              summary: String(localized: "rigctldBinary.usingXXChosen \(path) \(probe.shortVersion)"),
                              warning: probe.problem(for: model).map { String(localized: "rigctldBinary.automaticWouldUseA \($0)") })
        }
    }

    private static func builtIn(reason: String) async -> Resolution {
        let path = builtInPath
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return Resolution(path: nil, isBuiltIn: true,
                              summary: String(localized: "rigctldBinary.noUsableRigctldThe \(reason)"),
                              warning: String(localized: "rigctldBinary.reinstallFTX1RemoteOrInstall"))
        }
        let version = await builtInVersion()
        return Resolution(path: path, isBuiltIn: true,
                          summary: String(localized: "rigctldBinary.usingBuiltIn \(version.map { "Hamlib \($0)" } ?? "rigctld") \(reason)"))
    }

    /// The bundled copy's version, read once per launch.
    static func builtInVersion() async -> HamlibVersion? {
        await BuiltInVersionCache.shared.value
    }

    private actor BuiltInVersionCache {
        static let shared = BuiltInVersionCache()
        private var cached: HamlibVersion??
        var value: HamlibVersion? {
            get async {
                if let cached { return cached }
                let output = await RigctldBinary.run(RigctldBinary.builtInPath, ["--version"], timeout: .seconds(3))
                let version = output.flatMap(HamlibVersion.init(parsing:))
                cached = .some(version)
                return version
            }
        }
    }

    /// Runs `path` and returns its stdout+stderr, or nil if it couldn't be
    /// started, exited non-zero, or was still running after `timeout`.
    static func run(_ path: String, _ arguments: [String], timeout: Duration) async -> String? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: path)
                proc.arguments = arguments
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe
                proc.standardInput = FileHandle.nullDevice
                do {
                    try proc.run()
                } catch {
                    continuation.resume(returning: nil)
                    return
                }
                let timedOut = LockedFlag()
                let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                    if proc.isRunning {
                        timedOut.set()
                        proc.terminate()
                    }
                }
                // Read to EOF before waiting: `-l` prints ~50 KB, more than
                // a pipe buffer holds.
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                guard !timedOut.isSet, proc.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: String(decoding: data, as: UTF8.self))
            }
        }
    }

    private final class LockedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.withLock { value } }
        func set() { lock.withLock { value = true } }
    }
}

/// A Hamlib release number, parsed out of e.g. "rigctld Hamlib 4.7.2 …" or
/// "Hamlib 4.6.5". A missing patch number reads as 0.
nonisolated struct HamlibVersion: Comparable, CustomStringConvertible, Sendable {
    var major: Int
    var minor: Int
    var patch: Int

    init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    init?(parsing text: String) {
        guard let match = text.firstMatch(of: /Hamlib\s+(\d+)\.(\d+)(?:\.(\d+))?/),
              let major = Int(match.1), let minor = Int(match.2) else { return nil }
        self.init(major: major, minor: minor, patch: match.3.flatMap { Int($0) } ?? 0)
    }

    var description: String { "\(major).\(minor).\(patch)" }

    static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}
