import FTX1Core
import Foundation
import os

/// Runs the AFSK → AX.25 → APRS decode pipeline (see
/// `Sources/FTX1Core/APRS`) against raw audio sample chunks —
/// `AudioCaptureEngine`'s tap output, forwarded here only when
/// `HubService` determines the gate (APRS enabled + VFO within
/// `APRSSettings.toleranceHz` of the configured frequency) is open. Owns a
/// private serial queue for the actual DSP/parsing work: CPU-bound, and
/// doesn't belong on the real-time Core Audio thread the samples arrive
/// from, or on the main actor.
final class APRSDecoder {
    /// Always invoked on the main actor — same contract as
    /// `AudioCaptureEngine.onNewFrame` — since `HubService` assigns
    /// straight into `APRSStore`'s `@Published` state from inside these.
    /// `latitude`/`longitude`/`symbolTable`/`symbolCode`/`comment` are all
    /// optional because a status report or a bare "heard" (no parseable
    /// payload) only has some of these, and `APRSStore.recordStation`
    /// leaves anything `nil` unchanged rather than clearing it.
    var onStation: ((_ callsign: String, _ latitude: Double?, _ longitude: Double?, _ symbolTable: String?, _ symbolCode: String?, _ comment: String?) -> Void)?
    var onMessage: ((_ from: String, _ to: String, _ text: String, _ messageID: String?) -> Void)?

    private let queue = DispatchQueue(label: "com.ftx1remote.aprs-decoder")
    private var demodulator: AFSKDemodulator?
    private var demodulatorSampleRate: Double?
    private var frameDecoder = AX25FrameDecoder()

    /// Temporary diagnostic instrumentation — see the "possibly only while
    /// the S.LIST window is open" investigation. Confirms the pipeline is
    /// actually still processing audio (vs. stalled, e.g. by App Nap
    /// delaying the queue hops this relies on) independent of whether any
    /// window that would show the result is even open. Cheap (one log
    /// call every ~5s of audio, not per-buffer) — worth leaving in past
    /// this investigation rather than ripping out, since "is audio still
    /// reaching the decoder" is a reasonable first question for any future
    /// APRS reception report too.
    private let logger = Logger(subsystem: "com.ftx1remote.mac", category: "aprs-decoder")
    private var samplesSinceHeartbeat = 0
    private var heartbeatThreshold: Int?

    /// Cheap from the caller's side — copies the array reference into the
    /// closure and returns immediately; the DSP work happens on `queue`.
    func process(samples: [Float], sampleRate: Double) {
        queue.async { [weak self] in
            self?.processOnQueue(samples: samples, sampleRate: sampleRate)
        }
    }

    private func processOnQueue(samples: [Float], sampleRate: Double) {
        // A tolerance, not strict equality — many audio interfaces
        // (especially USB Audio Class devices with adaptive clocking)
        // report a sample rate that wobbles fractionally buffer to
        // buffer even though nothing about the actual device format
        // changed. Strict `!=` here was resetting the demodulator/frame
        // decoder on nearly every buffer in that case, discarding the
        // bit-clock PLL's lock and any in-progress frame — only a packet
        // short enough to complete inside one un-reset window could ever
        // survive, which is consistent with "decoded exactly one
        // station." 0.5 Hz comfortably clears normal device jitter while
        // still catching a real device/format change (typically a jump
        // of thousands of Hz, e.g. 44100 <-> 48000).
        if demodulatorSampleRate == nil || abs(demodulatorSampleRate! - sampleRate) > 0.5 {
            let previous = demodulatorSampleRate
            // The input device (or its native format) changed — the
            // demodulator's tone detector and bit-clock PLL are both
            // tuned to a specific sample rate, so this can't just keep
            // running; a fresh decoder mid-packet would produce garbage
            // either way.
            demodulator = AFSKDemodulator(sampleRate: sampleRate)
            frameDecoder = AX25FrameDecoder()
            demodulatorSampleRate = sampleRate
            heartbeatThreshold = Int(sampleRate * 5)
            let previousDescription = previous.map { String(format: "%.3f", $0) } ?? "none"
            logger.debug("(re)initialized demodulator: \(previousDescription, privacy: .public) -> \(sampleRate, format: .fixed(precision: 3)) Hz")
        }

        guard let lineBits = demodulator?.process(samples: samples) else { return }
        let frames = frameDecoder.process(bits: lineBits)
        for frame in frames {
            logger.info("frame decoded from \(frame.source.displayString, privacy: .public)")
            handle(frame: frame)
        }

        // Logged with cumulative frameDecoder.stats, not just "still
        // alive" — tells apart "no signal reaching this at all" (flagsFound
        // stays ~0) from "signal's reaching it but corrupt" (flagsFound
        // climbs, crcFailures/destuffFailures climb with it, framesDecoded
        // doesn't) — two very different problems. See the "decoded one
        // station, direwolf decoded seven" investigation.
        samplesSinceHeartbeat += samples.count
        if let heartbeatThreshold, samplesSinceHeartbeat >= heartbeatThreshold {
            samplesSinceHeartbeat = 0
            let stats = frameDecoder.stats
            logger.debug("heartbeat — flags:\(stats.flagsFound) destuffFail:\(stats.destuffFailures) tooShort:\(stats.tooShortFailures) crcFail:\(stats.crcFailures) addrFail:\(stats.addressParseFailures) decoded:\(stats.framesDecoded)")
        }
    }

    private func handle(frame: AX25Frame) {
        let source = frame.source.displayString
        let packet = APRSPacket.parse(infoField: frame.info)

        let station: (Double?, Double?, String?, String?, String?)
        switch packet {
        case .position(let latitude, let longitude, let symbolTable, let symbolCode, let comment):
            station = (latitude, longitude, symbolTable, symbolCode, comment)
        case .status(let text):
            station = (nil, nil, nil, nil, text)
        case .message, .other:
            station = (nil, nil, nil, nil, nil)
        }

        DispatchQueue.main.async { [onStation, onMessage] in
            onStation?(source, station.0, station.1, station.2, station.3, station.4)
            if case .message(let to, let text, let messageID) = packet {
                onMessage?(source, to, text, messageID)
            }
        }
    }
}
