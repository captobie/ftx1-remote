import FTX1Core
import Foundation
import os

/// Spawns and kills the `rigctld` daemon itself — this is the piece of the
/// old `rigctld_control.py` setup (see repo root CLAUDE.md) that this app
/// replaces. `RigctldClient`/`HubService` only ever talk to rigctld over
/// TCP once it's up; this is what actually brings it up.
///
/// Not an `ObservableObject` — reports state via `onStateChange` instead,
/// so `HubService` can fold it into its own `@Published` state rather than
/// exposing a second observable object to the UI.
@MainActor
final class RigctldProcessController {
    enum State: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    struct Configuration {
        /// Resolved to a path (`RigctldBinary.resolve`) only when a new
        /// rigctld actually has to be started, not when one is adopted.
        var binary: RigctldBinary.Choice
        var modelNumber: Int
        var devicePath: String
        var baudRate: Int
        var host: String
        var port: UInt16
        /// Empty means "not configured" — no `-p`/`-P` args are passed, and
        /// rigctld keys PTT via a CAT command over `devicePath` as before.
        var pttPort: String = ""
    }

    private(set) var state: State = .stopped
    private var process: Process?
    var onStateChange: ((State) -> Void)?
    /// Which rigctld this start launched and why (nil when one was
    /// adopted instead), for Settings' version box.
    var onBinaryResolved: ((RigctldBinary.Resolution?) -> Void)?

    private static let logger = Logger(subsystem: "com.ftx1remote.mac", category: "connection")

    /// Starts rigctld, first checking whether one is already listening on
    /// the configured port. If so, it's probed for liveness (`isHealthy`)
    /// rather than killed outright: another client (e.g. WSJT-X) may be
    /// mid-session with it, and killing-by-name unconditionally used to cut
    /// that connection out from under it on every FTX1Remote launch. A
    /// responsive instance is adopted — `process` stays nil, so `stop()`
    /// later won't touch it either, leaving it running for whoever else is
    /// using it. Only an unresponsive one is treated as stale and cleared:
    /// Xcode's Stop button often hard-kills the debuggee without running
    /// `applicationWillTerminate`, which can orphan the rigctld child we
    /// spawned, and the next start attempt would otherwise fail immediately
    /// because the dead one is still holding the port.
    ///
    /// A responsive one started for a different rig (its `\dump_caps`
    /// model isn't `config.modelNumber`) is neither adopted nor killed: the
    /// start fails with a message naming it, rather than silently
    /// controlling the wrong radio. Callers check `state` before
    /// connecting.
    func start(with config: Configuration) async {
        guard process == nil else { return }
        setState(.starting)

        if let existingPID = await findRigctldListening(onPort: config.port) {
            switch await probeExisting(host: config.host, port: config.port, model: config.modelNumber) {
            case .otherRig(let model):
                Self.logger.error("Not adopting the rigctld on port \(config.port) (pid \(existingPID)): it's for \(model.displayName, privacy: .public), not model \(config.modelNumber)")
                onBinaryResolved?(nil)
                setState(.failed(String(localized: "rigctldProcessController.theRigctldAlreadyRunning \(config.port) \(model.displayName) \(RigctldBinary.rigName(config.modelNumber))")))
                return
            case .responsive:
                Self.logger.notice("Adopted the rigctld already listening on port \(config.port) (pid \(existingPID))")
                onBinaryResolved?(nil)
                setState(.running)
                return
            case .unresponsive:
                await terminate(pid: existingPID)
            }
        }

        let resolution = await RigctldBinary.resolve(config.binary, model: config.modelNumber)
        Self.logger.notice("rigctld: \(resolution.summary, privacy: .public)\(resolution.warning.map { " Warning: " + $0 } ?? "", privacy: .public)")
        onBinaryResolved?(resolution)
        guard let binaryPath = resolution.path else {
            setState(.failed(resolution.summary))
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        var arguments = [
            "-m", "\(config.modelNumber)",
            "-r", config.devicePath,
            "-s", "\(config.baudRate)",
            "-t", "\(config.port)",
            // rigctld defaults to binding via IPv6 ("Using IPV6" in its own
            // startup log) when no listen address is given, which doesn't
            // necessarily accept the IPv4 127.0.0.1 connections
            // RigctldClient makes — pin it explicitly so both sides agree.
            "-T", config.host,
            // Without -o, get/set commands silently default to "current
            // VFO" and ignore any VFO argument passed alongside them —
            // discovered when a targeted secondary-VFO frequency read
            // came back identical to the primary VFO's. With -o, every
            // command requires an explicit VFO argument (RigctldClient
            // passes "currVFO" for the main state, and "Main"/"Sub" for
            // the secondary-VFO read), and targeted reads actually work.
            "-o",
            // hamlib's own per-command serial timeout/retry (defaults:
            // timeout=1000ms, retry=3 — confirmed via `rigctld -L`). Every
            // *real* reply from this rig arrives in ~50ms, but a raw CAT
            // command that genuinely gets no reply at all (e.g. the menu
            // buttons' Set commands — the CAT manual documents an Answer
            // only for Read, not Set) makes hamlib retry the full timeout
            // 1+retry times before giving up — up to ~4s, held under
            // rigctld's single global command lock the whole time, so it
            // blocks every other pending command too. Shrinking both here
            // makes that "no reply" case fail fast without affecting any
            // command that actually gets a real, fast reply.
            "-C", "timeout=300,retry=0"
        ]
        if !config.pttPort.isEmpty {
            // "RIG" (hamlib's CAT-command PTT type) is a best guess for
            // this rig's setup, not confirmed against the hardware yet —
            // if PTT doesn't actually key with this configured, the port
            // likely needs RTS/DTR line toggling instead (-P RTS / -P DTR).
            arguments += ["-p", config.pttPort, "-P", "RIG"]
        }
        proc.arguments = arguments
        proc.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor in
                guard let self, self.process === terminatedProcess else { return }
                self.process = nil
                self.setState(.failed(String(localized: "rigctldProcessController.rigctldExitedUnexpectedlyStatus \(terminatedProcess.terminationStatus)")))
            }
        }

        do {
            try proc.run()
            process = proc
            setState(.running)
        } catch {
            setState(.failed(error.localizedDescription))
        }
    }

    func stop() {
        guard let process else {
            setState(.stopped)
            return
        }
        process.terminationHandler = nil
        process.terminate()
        self.process = nil
        setState(.stopped)
    }

    private func setState(_ newState: State) {
        state = newState
        onStateChange?(newState)
    }

    private enum ExistingRigctld {
        /// Started for the configured model and answering, rig included.
        case responsive
        /// Answering, but started for another rig — never adopted, and
        /// never killed either (another program is likely using it).
        case otherRig(RigctldRigModel)
        /// Not answering `\dump_caps`, or (same model) the rig itself not
        /// answering through it: stale, safe to replace.
        case unresponsive
    }

    /// Probes a rigctld already listening on `host`/`port`, so `start()`
    /// can adopt it instead of assuming "listening on the port" alone means
    /// "safe to reuse". `\dump_caps` comes first: rigctld answers it
    /// without talking to the rig, so it shows the process is alive and
    /// which model it was started for. Only then the rig link (a raw "FA"
    /// read) — which only a Yaesu answers, so checking it first would make
    /// e.g. WSJT-X's rigctld for an Icom look stale and get killed. The
    /// device and baud rate it uses can't be asked for.
    private func probeExisting(host: String, port: UInt16, model: Int) async -> ExistingRigctld {
        // Its own connection: readRigModel stops reading partway through
        // the ~2300-line reply and disconnects.
        let capsClient = RigctldClient(host: host, port: port)
        do {
            try await capsClient.connect(timeout: .milliseconds(500))
            if let running = try await capsClient.readRigModel(), running.number != model {
                return .otherRig(running)
            }
        } catch {
            await capsClient.disconnect()
            return .unresponsive
        }
        let client = RigctldClient(host: host, port: port)
        do {
            try await client.connect(timeout: .milliseconds(500))
            _ = try await client.getFrequency()
            await client.disconnect()
            return .responsive
        } catch {
            await client.disconnect()
            return .unresponsive
        }
    }

    /// Looks for a process already listening on `port`. Only reports one
    /// whose command name is actually "rigctld" — never touches some other,
    /// unrelated process that happens to be using the port.
    private func findRigctldListening(onPort port: UInt16) async -> Int32? {
        let listenerOutput = await runAndCapture("/usr/sbin/lsof", ["-t", "-i", "tcp:\(port)", "-sTCP:LISTEN"])
        let pids = listenerOutput.split(separator: "\n").compactMap { Int32($0) }
        for pid in pids {
            let comm = await runAndCapture("/bin/ps", ["-p", "\(pid)", "-o", "comm="])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if (comm as NSString).lastPathComponent == "rigctld" {
                return pid
            }
        }
        return nil
    }

    /// SIGTERMs the stale process and waits (briefly, polling) for it to
    /// actually exit before we try to bind the same port ourselves.
    private func terminate(pid: Int32) async {
        _ = await runAndCapture("/bin/kill", ["\(pid)"])
        for _ in 0..<10 {
            let stillRunning = await runAndCapture("/bin/ps", ["-p", "\(pid)", "-o", "pid="])
            if stillRunning.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func runAndCapture(_ path: String, _ arguments: [String]) async -> String {
        await withCheckedContinuation { continuation in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: path)
            proc.arguments = arguments
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            proc.terminationHandler = { _ in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
            }
            do {
                try proc.run()
            } catch {
                continuation.resume(returning: "")
            }
        }
    }
}
