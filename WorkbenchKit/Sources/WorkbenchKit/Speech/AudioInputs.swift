import CoreAudio
import Foundation

/// Audio input devices, and the choice of which one dictation listens to.
public struct AudioInput: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let uid: String
    public let name: String
    public let isBuiltIn: Bool
    /// Devices apps create for their own routing (Zoom, Teams, recorders); never a real microphone.
    public let isVirtual: Bool
}

public enum AudioInputs {
    public static let preferenceKey = "workbench.dictation.inputUID"

    public static func all() -> [AudioInput] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            guard inputChannels(id) > 0, let uid = string(id, kAudioDevicePropertyDeviceUID),
                  let name = string(id, kAudioObjectPropertyName) else { return nil }
            let transport = uint32(id, kAudioDevicePropertyTransportType)
            return AudioInput(id: id, uid: uid, name: name,
                              isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
                              isVirtual: transport == kAudioDeviceTransportTypeVirtual || transport == kAudioDeviceTransportTypeAggregate)
        }
    }

    public static func systemDefault() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id)
        return status == noErr && id != 0 ? id : nil
    }

    /// True when the MacBook lid is closed; the built-in microphone records silence then.
    public static func isLidClosed() -> Bool {
        let result = Shell.runSync("/usr/sbin/ioreg", ["-r", "-k", "AppleClamshellState", "-d", "4"])
        return result.output.contains("\"AppleClamshellState\" = Yes")
    }

    /// The device dictation should use: the saved choice if it's still connected, otherwise the system default,
    /// unless that is the built-in mic with the lid closed or a virtual device, in which case the first real,
    /// non-built-in microphone.
    public static func resolve(preferredUID: String?, inputs: [AudioInput] = all(), defaultID: AudioDeviceID? = systemDefault(),
                               lidClosed: Bool = isLidClosed()) -> AudioInput? {
        if let preferredUID, let chosen = inputs.first(where: { $0.uid == preferredUID }) { return chosen }
        let fallback = inputs.first { !$0.isVirtual && !$0.isBuiltIn } ?? inputs.first { !$0.isVirtual }
        guard let current = inputs.first(where: { $0.id == defaultID }) else { return fallback }
        if current.isVirtual || (current.isBuiltIn && lidClosed) { return fallback ?? current }
        return current
    }

    private static func inputChannels(_ id: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                 mScope: kAudioDevicePropertyScopeInput,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func uint32(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value)
        return value
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }
}
