import Foundation

/// The iPad's Demo Mode "Pi": a `SimulatedRig` behind the three services a
/// real Pi runs — rigctld, the receive audio stream and the transmit audio
/// sink — each on its own loopback port. `PiDirectViewModel` connects to
/// `start()`'s endpoint exactly as it would to the real Pi, so everything
/// downstream (the command queue, polling, filters, MENU grid, memory
/// list/scan, swap tracking, CW and APRS decoding, meters) runs for real.
/// Nothing in it reaches the network.
public final class DemoPi: @unchecked Sendable {
    public let rig: SimulatedRig
    private let rigctld: SimulatedRigctldServer
    private let audio: SimulatedAudioServer
    private let txAudio: SimulatedTXAudioServer

    public init() {
        let rig = SimulatedRig()
        self.rig = rig
        rigctld = SimulatedRigctldServer(rig: rig)
        let world = rig.world
        let synth = SimulatedAudioSynth(rig: rig) { index in
            APRSBurstEncoder.render(world.aprsPacket(forBurst: index), sampleRate: SimulatedAudioServer.sampleRate)
        }
        audio = SimulatedAudioServer { left, right in
            synth.render(left: &left, right: &right)
        }
        txAudio = SimulatedTXAudioServer(rig: rig)
    }

    /// Starts the three services; returns where to connect.
    public func start() async throws -> PiEndpoint {
        do {
            let rigctldPort = try await rigctld.start()
            let audioPort = try await audio.start()
            let txAudioPort = try await txAudio.start()
            return PiEndpoint(host: "127.0.0.1", rigctldPort: rigctldPort, audioPort: audioPort, txAudioPort: txAudioPort)
        } catch {
            stop()
            throw error
        }
    }

    public func stop() {
        rigctld.stop()
        audio.stop()
        txAudio.stop()
    }
}
