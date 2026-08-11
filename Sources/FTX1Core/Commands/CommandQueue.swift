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
            // rigctld has no "set band" verb, so this is normally translated
            // into a .setFrequency by HubService (see its send(_:)) before
            // it ever reaches this queue — this case only exists because
            // RigCommand's switch must stay exhaustive. If it does arrive
            // here unresolved, there's no meaningful rigctld call to make.
            _ = band
        case .setPowerLevel(let level):
            _ = try await rigctld.send("L \(Self.currentVFOArg) RFPOWER \(String(format: "%.3f", level))")
        case .setBreakIn(let on):
            try await rigctld.setRawBool("BI", on)
        case .setKeyer(let on):
            try await rigctld.setRawBool("KR", on)
        case .setCWSpeed(let wpm):
            try await rigctld.setRawInt("KS", wpm, digits: 3)
        case .setCWPitch(let hz):
            // The FTX-1's "KP" CAT command encodes pitch as steps of 10Hz
            // above a 300Hz floor (00-75), not Hz directly — see the CAT
            // Operation Reference Manual and RigState.cwPitchHz.
            try await rigctld.setRawInt("KP", (hz - 300) / 10, digits: 2)
        case .setBreakInDelay(let ms):
            // The FTX-1's "SD" CAT command encodes delay as a non-linear
            // 00-33 code, not milliseconds directly — see BreakInDelay.
            guard let code = BreakInDelay.code(forMilliseconds: ms) else { return }
            try await rigctld.setRawInt("SD", code, digits: 2)
        case .setCWSpot(let on):
            try await rigctld.setRawBool("CS", on)
        case .triggerZeroIn:
            // "ZI" takes a Main/Sub selector (0/1), not an on/off state,
            // and documents no reply — always targets Main, matching every
            // other raw menu command's single-VFO-focus assumption.
            try await rigctld.sendRawFireAndForget("ZI0")
        case .setMoniLevel(let level):
            // "ML" carries both MONI on/off and MONI level under the same
            // mnemonic, distinguished by a P1 sub-selector baked into the
            // command text itself ("ML0..." for on/off, "ML1..." for
            // level) — see RigState.moniLevel.
            try await rigctld.setRawInt("ML1", level, digits: 3)
        case .selectCWMessageChannel(let channel):
            // "LM" (LOAD MESSAGE) packs channel-select and record start/
            // stop under one mnemonic via a P1 sub-selector, just like "ML"
            // does for MONI on/off vs level — P1=0 is the message-select
            // branch, whose P2 is which channel (1-5) becomes "active" for
            // setCWMessageRecording and the rig's own MESSAGE button.
            try await rigctld.setRawInt("LM0", channel, digits: 1)
        case .setCWMessageRecording(let on):
            // P1=1 is "LM"'s record branch — starts/stops recording into
            // whichever channel selectCWMessageChannel last selected.
            try await rigctld.setRawBool("LM1", on)
        case .playCWMessage(let channel):
            // "KY" (CW KEYING MEMORY PLAY) P1 fixed to 1 (CW MESSAGE
            // Memory, as opposed to 0 for CW TEXT Memory, which this app
            // doesn't expose) — P2 is 0 to stop or 1-5 to start playing
            // that channel.
            try await rigctld.setRawInt("KY1", channel, digits: 1)
        }
    }
}
