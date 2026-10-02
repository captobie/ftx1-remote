import AudioToolbox
import Combine
import CoreAudio
import Darwin
import Foundation
import os

/// Captures what the WebSDR window is playing, for the CW decoder's
/// "WebSDR" source, with a Core Audio process tap (macOS 14.2+) — so it
/// works for KiwiSDR, classic WebSDR and OpenWebRX alike without adding
/// anything to their pages.
///
/// A `WKWebView`'s audio doesn't play from this app's process but from
/// WebKit's helper processes (in practice `com.apple.WebKit.GPU`), one set
/// per app. They're found by asking each Core Audio process object's PID
/// who it's "responsible" to (the same attribution Activity Monitor uses)
/// and keeping the ones that point at us. That covers every web view in
/// the app, but the WebSDR window is the only one that plays audio.
///
/// The tap hears the page's *output*, so a muted page would silence
/// decoding too. Instead, while the tap runs, the WebSDR window's Mute is
/// applied here (`setMuted`, `muteBehavior = .muted`: the tap still gets
/// the audio, the speakers don't) and the page itself stays unmuted — see
/// `WebSDRAudioRouting`.
///
/// The first tap triggers macOS's "System Audio Recording" permission
/// prompt (`NSAudioCaptureUsageDescription`); if it's denied the tap runs
/// but delivers silence, which `Status.silent` reports (as it does for a
/// muted page — the two can't be told apart from the audio).
///
/// Everything mutable lives on `queue`; the callbacks hop to the main actor.
nonisolated final class WebSDRAudioTap: @unchecked Sendable {
    enum Status: Equatable {
        case stopped
        /// No WebKit process of ours has a Core Audio presence yet (the
        /// WebSDR window isn't connected).
        case waitingForWebSDR
        case capturing
        /// Tapping, but next to nothing for a while: the page is muted or
        /// stopped, or the System Audio Recording permission was denied.
        case silent
        case failed(String)
    }

    private let onSamples: @MainActor @Sendable ([Float], Double) -> Void
    private let onStatus: @MainActor @Sendable (Status) -> Void

    private let queue = DispatchQueue(label: "com.ftx1remote.websdr-audio-tap", qos: .userInitiated)
    private static let logger = Logger(subsystem: "com.ftx1remote.mac", category: "websdr-audio-tap")

    private var isActive = false
    private var isMuted = false
    private var tapDescription: CATapDescription?
    private var tappedProcesses: [AudioObjectID] = []
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private var watchdog: DispatchSourceTimer?
    private var status = Status.stopped

    // IOProc state (also only touched on `queue`, which the IOProc runs on).
    private var sampleRate = 48_000.0
    private var channelCount = 2
    private var isInterleaved = true
    private var pending: [Float] = []
    private var lastSoundAt = Date.distantPast
    private var startedAt = Date.distantPast

    /// Delivered in chunks of about this many frames (~43 ms at 48 kHz), so
    /// the main actor isn't hopped to for every small IOProc buffer.
    private static let chunkFrames = 2048
    /// Nothing above `silenceLevel` for this long means "silent".
    private static let silenceTimeout: TimeInterval = 3
    /// About -80 dBFS. A muted page doesn't deliver exact zeros, so
    /// "silent" means "below this", not "== 0".
    private static let silenceLevel: Float = 1e-4

    init(onSamples: @escaping @MainActor @Sendable ([Float], Double) -> Void,
         onStatus: @escaping @MainActor @Sendable (Status) -> Void) {
        self.onSamples = onSamples
        self.onStatus = onStatus
    }

    func start() {
        queue.async { [self] in
            guard !isActive else { return }
            isActive = true
            refresh()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 2, repeating: 2)
            timer.setEventHandler { [weak self] in self?.refresh() }
            timer.resume()
            watchdog = timer
        }
    }

    /// While stopping, a muted tap is kept a moment longer so the page has
    /// time to mute itself again before the speakers are released.
    func stop() {
        queue.async { [self] in
            guard isActive else { return }
            isActive = false
            watchdog?.cancel()
            watchdog = nil
            queue.asyncAfter(deadline: .now() + (isMuted ? 0.3 : 0)) { [self] in
                guard !isActive else { return }
                teardown()
                setStatus(.stopped)
            }
        }
    }

    /// Silences (or restores) the tapped audio on the speakers without
    /// affecting what the tap receives. Takes effect on the running tap, or
    /// on the next one built.
    func setMuted(_ muted: Bool) {
        queue.async { [self] in
            guard muted != isMuted else { return }
            isMuted = muted
            guard let tapDescription, tapID != kAudioObjectUnknown else { return }
            tapDescription.muteBehavior = muted ? .muted : .unmuted
            var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyDescription,
                                                     mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            var reference = tapDescription
            let status = withUnsafePointer(to: &reference) {
                AudioObjectSetPropertyData(tapID, &address, 0, nil,
                                           UInt32(MemoryLayout<CATapDescription>.size), $0)
            }
            if status == noErr {
                Self.logger.info("tap \(muted ? "muted" : "unmuted", privacy: .public)")
            } else {
                // Rebuild with the new mute instead.
                Self.logger.notice("couldn't change the tap's mute (OSStatus \(status)) — rebuilding it")
                teardown()
                refresh()
            }
        }
    }

    // MARK: - Tap lifecycle (on `queue`)

    /// (Re)builds the tap when the set of our WebKit processes changes —
    /// WebKit can relaunch its helpers — and updates the silence status.
    private func refresh() {
        guard isActive else { return }
        let processes = Self.ownWebKitAudioProcesses()
        if processes != tappedProcesses {
            teardown()
            tappedProcesses = processes
            if processes.isEmpty {
                setStatus(.waitingForWebSDR)
                return
            }
            do {
                try build(processes)
                Self.logger.info("tapping WebKit audio processes \(processes, privacy: .public) at \(self.sampleRate) Hz, \(self.channelCount) ch")
                setStatus(.capturing)
            } catch {
                Self.logger.error("process tap failed: \(error.localizedDescription, privacy: .public)")
                teardown()
                setStatus(.failed(error.localizedDescription))
                return
            }
        }
        guard ioProcID != nil else { return }
        let reference = max(lastSoundAt, startedAt)
        setStatus(Date().timeIntervalSince(reference) > Self.silenceTimeout ? .silent : .capturing)
    }

    private func build(_ processes: [AudioObjectID]) throws {
        let description = CATapDescription(stereoMixdownOfProcesses: processes)
        description.uuid = UUID()
        description.name = "FTX1Remote WebSDR"
        description.isPrivate = true
        description.muteBehavior = isMuted ? .muted : .unmuted
        tapDescription = description

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateProcessTap(description, &tap), "create the process tap")
        tapID = tap

        let format: AudioStreamBasicDescription = try Self.property(tap, kAudioTapPropertyFormat)
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32 else {
            throw TapError("unsupported tap format (\(format.mFormatID), flags \(format.mFormatFlags), \(format.mBitsPerChannel) bit)")
        }
        sampleRate = format.mSampleRate
        channelCount = max(Int(format.mChannelsPerFrame), 1)
        isInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0

        // The aggregate device is what actually runs the tap; its clock
        // comes from the system output device, as in Apple's sample.
        let outputDevice: AudioObjectID = try Self.property(AudioObjectID(kAudioObjectSystemObject),
                                                            kAudioHardwarePropertyDefaultSystemOutputDevice)
        let outputUID: CFString = try Self.property(outputDevice, kAudioDevicePropertyDeviceUID)
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "FTX1Remote WebSDR Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID as String,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID as String]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &device), "create the aggregate device")
        aggregateID = device

        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, device, queue) { [weak self] _, input, _, _, _ in
            self?.receive(input)
        }, "create the IOProc")
        ioProcID = procID
        pending.removeAll(keepingCapacity: true)
        startedAt = Date()
        lastSoundAt = .distantPast
        try check(AudioDeviceStart(device, procID), "start the tap")
    }

    private func teardown() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        tapDescription = nil
        tappedProcesses = []
        pending.removeAll()
    }

    // MARK: - Audio (IOProc, on `queue`)

    private func receive(_ input: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        guard let first = buffers.first, let firstData = first.mData else { return }
        var heardSound = false

        if isInterleaved {
            let channels = max(Int(first.mNumberChannels), 1)
            let frames = Int(first.mDataByteSize) / (MemoryLayout<Float>.size * channels)
            let samples = firstData.assumingMemoryBound(to: Float.self)
            let scale = 1 / Float(channels)
            for frame in 0..<frames {
                var sum: Float = 0
                for channel in 0..<channels { sum += samples[frame * channels + channel] }
                let sample = sum * scale
                if abs(sample) > Self.silenceLevel { heardSound = true }
                pending.append(sample)
            }
        } else {
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float>.size
            let scale = 1 / Float(buffers.count)
            let start = pending.count
            pending.append(contentsOf: repeatElement(0, count: frames))
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for frame in 0..<min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size) {
                    pending[start + frame] += data[frame] * scale
                }
            }
            heardSound = pending[start...].contains { abs($0) > Self.silenceLevel }
        }

        if heardSound { lastSoundAt = Date() }
        guard pending.count >= Self.chunkFrames else { return }
        let chunk = pending
        let rate = sampleRate
        pending.removeAll(keepingCapacity: true)
        let onSamples = self.onSamples
        Task { @MainActor in onSamples(chunk, rate) }
    }

    // MARK: - Helpers

    private func setStatus(_ new: Status) {
        guard new != status else { return }
        status = new
        let onStatus = self.onStatus
        Task { @MainActor in onStatus(new) }
    }

    private struct TapError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private func check(_ status: OSStatus, _ action: String) throws {
        guard status == noErr else { throw TapError("Couldn't \(action) (OSStatus \(status))") }
    }

    private static func property<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, value)
        guard status == noErr else { throw TapError("Couldn't read audio property \(selector) (OSStatus \(status))") }
        return value.move()
    }

    /// `responsibility_get_pid_responsible_for_pid`: not in the SDK headers,
    /// but long-standing libsystem API (Activity Monitor's attribution).
    private typealias ResponsibleForPID = @convention(c) (pid_t) -> pid_t
    private static let responsibleForPID: ResponsibleForPID? = {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(symbol, to: ResponsibleForPID.self)
    }()

    /// Core Audio process objects for WebKit helpers this app is
    /// responsible for, sorted so a changed set is easy to spot.
    private static func ownWebKitAudioProcesses() -> [AudioObjectID] {
        guard let responsibleForPID else { return [] }
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }

        let me = getpid()
        return objects.filter { object in
            guard let pid: pid_t = try? property(object, kAudioProcessPropertyPID), pid != me,
                  let bundleID: CFString = try? property(object, kAudioProcessPropertyBundleID),
                  (bundleID as String).hasPrefix("com.apple.WebKit") else { return false }
            return responsibleForPID(pid) == me
        }.sorted()
    }
}

/// Where the WebSDR window's Mute is applied: on the page (the normal case)
/// or, while the CW window is capturing the WebSDR's audio, on that capture
/// (`WebSDRAudioTap.setMuted`), since a muted page gives the decoder nothing
/// to decode. A plain `let` on `HubService`, shared by `WebSDRFollowModel`
/// (which sets `muteRequested` and mutes the page only while
/// `!captureActive`) and `CWReceiver` (which sets `captureActive` and mutes
/// its tap with `muteRequested`).
final class WebSDRAudioRouting: ObservableObject {
    /// The WebSDR window wants its audio silenced: its Mute, or Mute on TX
    /// while transmitting.
    @Published var muteRequested = false
    /// The CW window's WebSDR tap is attached to the WebSDR's audio.
    @Published var captureActive = false
}
