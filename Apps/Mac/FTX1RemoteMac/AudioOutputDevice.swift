import CoreAudio
import Foundation

/// One Core Audio device with at least one output channel, for the Settings
/// window's Audio tab — the output-side counterpart to `AudioInputDevice`.
struct AudioOutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioOutputDeviceLister {
    /// Resolves a persisted `AudioOutputSettings.deviceUID` back to a live
    /// `AudioDeviceID` for `AudioPlaybackEngine` to open. `nil` (empty UID,
    /// or a UID that no longer matches a connected device) means "use the
    /// system default output" — the caller decides what that means, this
    /// just does the lookup.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        availableOutputDevices().first { $0.uid == uid }?.id
    }

    /// Queries Core Audio's device registry directly, same as
    /// `AudioInputDeviceLister.availableInputDevices()`.
    static func availableOutputDevices() -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var propertySize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize) == noErr else {
            return []
        }
        let count = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &propertySize, &deviceIDs) == noErr else {
            return []
        }

        return deviceIDs.compactMap { deviceID in
            guard outputChannelCount(for: deviceID) > 0,
                  let uid = stringProperty(deviceID, selector: kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(deviceID, selector: kAudioObjectPropertyName)
            else { return nil }
            return AudioOutputDevice(id: deviceID, uid: uid, name: name)
        }
    }

    /// Sums channel counts across the device's output-scope stream buffers;
    /// zero means the device is input-only (e.g. a capture-only USB mic).
    private static func outputChannelCount(for deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var propertySize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &propertySize) == noErr, propertySize > 0 else {
            return 0
        }
        let bufferListPointer = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(propertySize))
        defer { bufferListPointer.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, bufferListPointer) == noErr else {
            return 0
        }
        return UnsafeMutableAudioBufferListPointer(bufferListPointer).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var propertySize = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, $0)
        }
        guard status == noErr, let value else { return nil }
        return value as String
    }
}
