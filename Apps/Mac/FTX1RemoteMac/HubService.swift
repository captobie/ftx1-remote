import FTX1Core
import Foundation

/// The Mac hub: owns the `RigctldClient` connection and the `CommandQueue`
/// that serializes commands into it, and polls rigctld for state changes
/// (rigctld has no server-push of its own — this is the only way to notice
/// e.g. a PTT toggled from the radio's own front panel). The WebSocket
/// server that re-broadcasts this state to mobile clients doesn't exist
/// yet; that's the next seam to attach here.
@MainActor
final class HubService: ObservableObject {
    enum ConnectionState: Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    @Published private(set) var rigState = RigState()
    @Published private(set) var connectionState: ConnectionState = .disconnected

    private let rigctld: RigctldClient
    private let commandQueue: CommandQueue
    private var runLoopTask: Task<Void, Never>?

    private let pollInterval: Duration
    private let reconnectDelay: Duration

    init(
        rigctldHost: String = "127.0.0.1",
        rigctldPort: UInt16 = 4532,
        pollInterval: Duration = .milliseconds(500),
        reconnectDelay: Duration = .seconds(3)
    ) {
        let client = RigctldClient(host: rigctldHost, port: rigctldPort)
        self.rigctld = client
        self.commandQueue = CommandQueue(rigctld: client)
        self.pollInterval = pollInterval
        self.reconnectDelay = reconnectDelay
    }

    func start() {
        guard runLoopTask == nil else { return }
        runLoopTask = Task { await runConnectionLoop() }
    }

    func stop() {
        runLoopTask?.cancel()
        runLoopTask = nil
        connectionState = .disconnected
        Task { await rigctld.disconnect() }
    }

    func send(_ command: RigCommand) {
        Task { await commandQueue.enqueue(command) }
    }

    private func runConnectionLoop() async {
        while !Task.isCancelled {
            connectionState = .connecting
            do {
                try await rigctld.connect()
                connectionState = .connected
                try await pollLoop()
            } catch {
                connectionState = .failed(error.localizedDescription)
            }
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: reconnectDelay)
        }
    }

    private func pollLoop() async throws {
        while !Task.isCancelled {
            try await refreshState()
            try await Task.sleep(for: pollInterval)
        }
    }

    private func refreshState() async throws {
        let frequencyHz = try await rigctld.getFrequency()
        let (modeName, _) = try await rigctld.getMode()
        let ptt = try await rigctld.getPTT()
        let swr = try await rigctld.getLevel("SWR")
        let powerWatts = try await rigctld.getLevel("RFPOWER_METER_WATTS")

        rigState = RigState(
            frequencyHz: frequencyHz,
            mode: RigMode(rawValue: modeName) ?? .unknown,
            band: nil,
            powerWatts: powerWatts,
            swr: swr,
            ptt: ptt,
            lastUpdated: Date()
        )
    }
}
