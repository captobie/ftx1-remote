import FTX1Core
import FTX1Digi
import Foundation

/// The RTTY/PSK window's sender (`DigiSender`) on the Mac's own link:
/// keying through `send(_:)`, so the transmit gate, the memory-scan stop
/// and the unkey's audio tail apply as for any other PTT; audio through
/// `routeTXAudio`, the same path as an iPad's microphone.
extension HubService: DigiTransmitLink {
    func digiTransmitBlock(keyedBySender: Bool) -> String? {
        guard connectionState == .connected else { return String(localized: "digiLink.notConnected") }
        if let reason = transmitBlockReason { return reason }
        if !keyedBySender, rigState.ptt || rigState.moxEnabled == true {
            return String(localized: "digiLink.alreadyTransmitting")
        }
        // Only before keying: this walks Core Audio's device list, too
        // slow for the sender's 20 ms checks while transmitting.
        if !keyedBySender, RigctldSettings.activeConnectionMode == .local,
           AudioOutputDeviceLister.deviceID(forUID: TXAudioOutputSettings.deviceUID) == nil {
            return String(localized: "digiLink.noTransmitAudioOutput")
        }
        return nil
    }

    var digiTransmitMode: RigMode? {
        connectionState == .connected ? rigState.transmitMode : nil
    }

    var digiRigIsKeyed: Bool { rigState.ptt }

    func digiSetKeyed(_ keyed: Bool) {
        send(.setPTT(keyed))
    }

    func digiSendAudio(_ pcm: Data) {
        routeTXAudio(pcm)
    }

    /// The transmitting mode's MOD SOURCE (MODE DATA EX010413, MODE SSB
    /// EX010113), when it would send something other than this window's
    /// audio: MIC or Bluetooth. USB and AUTO pass. nil when fine or unknown.
    func digiModSourceWarning() async -> String? {
        guard let mode = digiTransmitMode else { return nil }
        let group: (p2: Int, name: String)
        switch mode {
        case .dataUSB: group = (4, "DATA")
        case .usb, .lsb: group = (1, "SSB")
        default: return nil
        }
        guard let value = await readMenuItem(p1: 1, p2: group.p2, p3: 13).flatMap(Int.init) else { return nil }
        let source: String
        switch value {
        case 0: source = "MIC"
        case 2: source = "Bluetooth"
        default: return nil
        }
        return String(localized: "digiLink.modSourceWarning \(group.name) \(source)")
    }
}
