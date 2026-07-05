import Foundation

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
        var binaryPath: String
        var modelNumber: Int
        var devicePath: String
        var baudRate: Int
        var host: String
        var port: UInt16
    }

    private(set) var state: State = .stopped
    private var process: Process?
    var onStateChange: ((State) -> Void)?

    /// Starts rigctld, first checking for — and clearing — a stale rigctld
    /// left over from a previous run. Xcode's Stop button often hard-kills
    /// the debuggee without running `applicationWillTerminate`, which can
    /// orphan the rigctld child we spawned; if that happens, the next start
    /// attempt would otherwise fail immediately because the old one is
    /// still holding the port.
    func start(with config: Configuration) async {
        guard process == nil else { return }
        setState(.starting)

        if let stalePID = await findRigctldListening(onPort: config.port) {
            await terminate(pid: stalePID)
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: config.binaryPath)
        proc.arguments = [
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
            "-o"
        ]
        proc.terminationHandler = { [weak self] terminatedProcess in
            Task { @MainActor in
                guard let self, self.process === terminatedProcess else { return }
                self.process = nil
                self.setState(.failed("rigctld exited unexpectedly (status \(terminatedProcess.terminationStatus))"))
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
