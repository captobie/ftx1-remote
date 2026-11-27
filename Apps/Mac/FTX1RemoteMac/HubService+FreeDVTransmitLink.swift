import FTX1Core
import FTX1Digi
import FreeDVKit
import Foundation

/// Tools → FreeDV's sender on the Mac's own link: keying through
/// `send(_:)` (transmit gate, License guardrail, memory-scan stop), audio
/// through `routeTXAudio` like the RTTY/PSK sender's.
extension HubService: FreeDVTransmitLink {
    func freeDVTransmitBlock(keyedBySender: Bool) -> String? {
        guard connectionState == .connected else { return String(localized: "digiLink.notConnected") }
        if let reason = transmitBlockReason { return reason }
        // The band's sideband (freedv.org: LSB below 10 MHz, USB above).
        let expected = FreeDVSideband(frequencyHz: rigState.transmitFrequencyHz)
        guard let mode = rigState.transmitMode, expected.suitableModes.contains(mode) else {
            let wanted = expected == .lower ? "LSB" : "USB / DATA-U"
            return String(localized: "freeDVLink.wrongMode \(rigState.transmitMode?.displayName ?? "—") \(wanted)")
        }
        guard !keyedBySender else { return nil }
        if rigState.ptt || rigState.moxEnabled == true || digiSender.isTransmitting || tuneTone.isTuning
            || aprsTransmitter.isTransmitting {
            return String(localized: "digiLink.alreadyTransmitting")
        }
        // Only before keying: these walk Core Audio's device list.
        if RigctldSettings.activeConnectionMode == .local {
            if AudioOutputDeviceLister.deviceID(forUID: TXAudioOutputSettings.deviceUID) == nil {
                return String(localized: "digiLink.noTransmitAudioOutput")
            }
            let mic = FreeDVMicrophoneSettings.deviceUID
            if !mic.isEmpty, mic == AudioInputSettings.deviceUID {
                return String(localized: "freeDVLink.micIsRigInput")
            }
        }
        return nil
    }

    var freeDVRigIsKeyed: Bool { rigState.ptt }

    func freeDVSetKeyed(_ keyed: Bool) {
        send(.setPTT(keyed))
    }

    func freeDVSendAudio(_ pcm: Data) {
        routeTXAudio(pcm)
    }
}
