import Foundation
import Network

/// `Pi/ftx1-audiostream.py`'s side of the receive audio link: interleaved
/// stereo Int16LE at 44.1 kHz, L = the MAIN receiver and R = SUB (as the
/// rig's USB audio carries them), paced in real time. Like the Pi script it
/// serves one client at a time; a second waits until the first leaves.
public final class SimulatedAudioServer: @unchecked Sendable {
    public static let sampleRate = 44_100.0
    /// 20 ms per write.
    private static let framesPerChunk = 882

    /// Fills `left`/`right` (same length) with the next samples, -1...1.
    public typealias Renderer = @Sendable (_ left: inout [Float], _ right: inout [Float]) -> Void

    private let render: Renderer
    private var listener: LoopbackListener?
    private var timer: DispatchSourceTimer?
    private var client: NWConnection?
    private var waiting: [NWConnection] = []
    private var startedAt: TimeInterval = 0
    private var framesSent = 0
    private var left = [Float]()
    private var right = [Float]()

    public init(render: @escaping Renderer) {
        self.render = render
    }

    public func start() async throws -> UInt16 {
        let listener = try LoopbackListener(label: "audio") { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        return try await listener.start()
    }

    public func stop() {
        guard let queue = listener?.queue else { return }
        queue.sync {
            timer?.cancel()
            timer = nil
            client?.cancel()
            client = nil
            waiting.forEach { $0.cancel() }
            waiting = []
        }
        listener?.stop()
        listener = nil
    }

    /// On the listener's queue.
    private func accept(_ connection: NWConnection) {
        guard let queue = listener?.queue else { return connection.cancel() }
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed, .cancelled: self.dropped(connection)
            default: break
            }
        }
        connection.start(queue: queue)
        // Notice the client closing its end.
        watchForClose(connection)
        if client == nil {
            begin(connection)
        } else {
            waiting.append(connection)
        }
    }

    private func watchForClose(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self, weak connection] _, _, isComplete, error in
            guard let self, let connection else { return }
            if isComplete || error != nil {
                connection.cancel()
            } else {
                self.watchForClose(connection)
            }
        }
    }

    private func dropped(_ connection: NWConnection) {
        waiting.removeAll { $0 === connection }
        guard client === connection else { return }
        client = nil
        timer?.cancel()
        timer = nil
        if !waiting.isEmpty { begin(waiting.removeFirst()) }
    }

    private func begin(_ connection: NWConnection) {
        guard let queue = listener?.queue else { return }
        client = connection
        startedAt = ProcessInfo.processInfo.systemUptime
        framesSent = 0
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.pump() }
        self.timer = timer
        timer.resume()
    }

    /// Sends whatever real time says is due — paced by the clock, not the
    /// timer, so a late tick doesn't make the stream drift.
    private func pump() {
        guard let client else { return }
        let due = Int((ProcessInfo.processInfo.systemUptime - startedAt) * Self.sampleRate) - framesSent
        // A long stall (app in the background): skip ahead rather than burst.
        if due > Int(Self.sampleRate) {
            framesSent += due - Self.framesPerChunk
        }
        var remaining = min(due, Int(Self.sampleRate))
        while remaining >= Self.framesPerChunk {
            let count = Self.framesPerChunk
            if left.count != count {
                left = [Float](repeating: 0, count: count)
                right = [Float](repeating: 0, count: count)
            }
            render(&left, &right)
            var data = Data(count: count * 4)
            data.withUnsafeMutableBytes { raw in
                let out = raw.bindMemory(to: Int16.self)
                for index in 0..<count {
                    out[index * 2] = Self.int16(left[index]).littleEndian
                    out[index * 2 + 1] = Self.int16(right[index]).littleEndian
                }
            }
            client.send(content: data, completion: .contentProcessed { _ in })
            framesSent += count
            remaining -= count
        }
    }

    private static func int16(_ sample: Float) -> Int16 {
        Int16(max(-1, min(1, sample)) * 32767)
    }
}

/// `Pi/ftx1-txaudio.py`'s side of the transmit link: takes the 8 kHz mono
/// Int16LE the iPad sends while keyed and plays it nowhere — it only tells
/// the rig how loud it was, so the PO meter moves in SSB.
public final class SimulatedTXAudioServer: @unchecked Sendable {
    private let rig: SimulatedRig
    private var listener: LoopbackListener?

    public init(rig: SimulatedRig) {
        self.rig = rig
    }

    public func start() async throws -> UInt16 {
        let listener = try LoopbackListener(label: "txaudio") { [weak self] connection in
            self?.accept(connection)
        }
        self.listener = listener
        return try await listener.start()
    }

    public func stop() {
        listener?.stop()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        guard let queue = listener?.queue else { return connection.cancel() }
        connection.start(queue: queue)
        receive(connection)
    }

    private func receive(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return connection.cancel() }
            if let data, data.count >= 2 {
                var sum = 0.0
                let count = data.count / 2
                data.withUnsafeBytes { raw in
                    for index in 0..<count {
                        let sample = Double(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: index * 2, as: Int16.self))) / 32768
                        sum += sample * sample
                    }
                }
                self.rig.reportTXAudio(rms: (sum / Double(count)).squareRoot())
            }
            if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection)
            }
        }
    }
}
