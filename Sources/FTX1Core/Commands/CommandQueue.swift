import Foundation

/// Serializes RigCommands into rigctld calls, one at a time.
///
/// rigctld handles one request/response cycle at a time over its TCP
/// connection — this queue exists so that, e.g., a fast VFO drag on the
/// Mac UI or a burst of commands from a mobile client can't interleave
/// or race against each other. Runs only on the Mac hub.
public actor CommandQueue {
    private let rigctld: RigctldClient
    private var isProcessing = false
    private var pending: [RigCommand] = []

    /// Called after each command completes, with the freshest rig state
    /// (however the caller chooses to derive it — e.g. by re-querying
    /// rigctld or applying the command optimistically). Wiring this up
    /// to a broadcast-to-WebSocket-clients step happens at the app layer.
    public var onCommandApplied: (@Sendable (RigCommand) -> Void)?

    public init(rigctld: RigctldClient) {
        self.rigctld = rigctld
    }

    public func setOnCommandApplied(_ handler: @escaping @Sendable (RigCommand) -> Void) {
        onCommandApplied = handler
    }

    public func enqueue(_ command: RigCommand) {
        pending.append(command)
        if !isProcessing {
            Task { await drain() }
        }
    }

    private func drain() async {
        isProcessing = true
        while !pending.isEmpty {
            let command = pending.removeFirst()
            do {
                try await apply(command)
                onCommandApplied?(command)
            } catch {
                // TODO: surface command failures to the app layer (e.g. via
                // a dedicated error callback) rather than dropping silently.
            }
        }
        isProcessing = false
    }

    /// rigctld runs with `-o` (see `RigctldProcessController`), which
    /// requires every set command to name an explicit VFO rather than
    /// defaulting to the active one — "currVFO" is rigctld's keyword for
    /// that default, kept here to match `RigctldClient`'s get-side calls.
    private static let currentVFOArg = "currVFO"

    private func apply(_ command: RigCommand) async throws {
        switch command {
        case .setFrequency(let hz):
            _ = try await rigctld.send("F \(Self.currentVFOArg) \(hz)")
        case .setMode(let mode):
            _ = try await rigctld.send("M \(Self.currentVFOArg) \(mode.rawValue) 0")
        case .setPTT(let on):
            _ = try await rigctld.send("T \(Self.currentVFOArg) \(on ? 1 : 0)")
        case .setBand(let band):
            // rigctld doesn't have a direct "set band" verb — this typically
            // maps to a frequency jump to the band's default segment.
            // Placeholder until the Mac app defines a band->frequency table.
            _ = try await rigctld.send("# set_band \(band)")
        case .setPowerLevel(let level):
            _ = try await rigctld.send("L \(Self.currentVFOArg) RFPOWER \(String(format: "%.3f", level))")
        }
    }
}
