import FTX1Core
import FTX1Digi
import Foundation

/// The APRS transmitter (`APRSTransmitter`) on the Mac's own link: the
/// receiver on the APRS frequency through `APRSTransmitPlanner` (which
/// judges the transmit gate for that side), keying and the TX side as one
/// ordered task (`keyForAPRS`), audio
/// through `routeTXAudio`, the same path as the RTTY/PSK window's.
extension HubService: APRSTransmitLink {
    func aprsPlanTransmit() -> APRSTransmitDecision {
        guard connectionState == .connected else { return .blocked(String(localized: "digiLink.notConnected")) }
        if rigState.ptt || rigState.moxEnabled == true || digiSender.isTransmitting || tuneTone.isTuning {
            return .blocked(String(localized: "digiLink.alreadyTransmitting"))
        }
        if RigctldSettings.activeConnectionMode == .local,
           AudioOutputDeviceLister.deviceID(forUID: TXAudioOutputSettings.deviceUID) == nil {
            return .blocked(String(localized: "digiLink.noTransmitAudioOutput"))
        }
        return APRSTransmitPlanner.plan(state: rigState, transmitEnabled: transmitEnabled, privileges: activePrivileges,
                                        aprsHz: APRSSettings.frequencyHz, toleranceHz: APRSSettings.toleranceHz)
    }

    /// Judged as if `side` transmits: right after keying the rig may still
    /// report the old TX side (the "FT" switch lands a poll later), and
    /// `transmitBlockReason` would judge that one — it stopped every packet
    /// that needed the switch (2026-11-11, MAIN on 14.093 USB).
    func aprsTransmitBlock(side: FilterSide) -> String? {
        guard connectionState == .connected else { return String(localized: "digiLink.notConnected") }
        var transmitting = rigState
        transmitting.txSide = side
        return TransmitGate.blockReason(transmitEnabled: transmitEnabled, state: transmitting, privileges: activePrivileges)
    }

    func aprsKey(switchTo side: FilterSide?) {
        keyForAPRS(switchTo: side)
    }

    func aprsUnkey(restoreSide: FilterSide?) {
        unkeyForAPRS(restoreSide: restoreSide)
    }

    func aprsSendAudio(_ pcm: Data) {
        routeTXAudio(pcm)
    }

    func aprsChannelBusy(side: FilterSide, within seconds: TimeInterval) -> Bool {
        aprsDecoderHeardActivity(side: side, within: seconds)
    }
}
