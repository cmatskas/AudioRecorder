import CoreAudio
import Foundation

/// An audio input device as shown in the UI.
public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    public let id: AudioObjectID
    public let uid: String
    public let name: String
    /// Total input channel count of the device (not clamped).
    public let channels: Int

    public var displayName: String {
        "\(name) (\(channels == 1 ? "Mono" : "\(min(channels, 2)) ch"))"
    }
}

public enum AudioDeviceList {
    /// All devices that have at least one input channel.
    public static func inputDevices() -> [AudioInputDevice] {
        guard let ids = try? caGetDeviceIDs() else { return [] }
        var devices: [AudioInputDevice] = []
        for id in ids {
            let channels = caGetInputChannelCount(id)
            guard channels > 0 else { continue }
            guard
                let uid = try? caGetString(id, kAudioDevicePropertyDeviceUID, what: "device UID"),
                let name = try? caGetString(id, kAudioObjectPropertyName, what: "device name")
            else { continue }
            // Skip private aggregates created by this app.
            if uid.hasPrefix("audio-recorder-capture") { continue }
            devices.append(AudioInputDevice(id: id, uid: uid, name: name, channels: channels))
        }
        return devices
    }

    /// Resolves a device by UID (device IDs are not stable across
    /// configuration changes; UIDs are).
    public static func deviceID(forUID uid: String) -> AudioObjectID? {
        guard let ids = try? caGetDeviceIDs() else { return nil }
        for id in ids {
            if let candidate = try? caGetString(id, kAudioDevicePropertyDeviceUID, what: "device UID"),
               candidate == uid {
                return id
            }
        }
        return nil
    }

    /// The system default input device, if any.
    public static func defaultInputDeviceID() -> AudioObjectID? {
        let id = try? caGetValue(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultInputDevice,
            initial: AudioObjectID(kAudioObjectUnknown),
            what: "default input device"
        )
        guard let id, id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// The built-in output device (speakers), if present. Preferred as the
    /// aggregate clock source: always available, cycles steadily, and has no
    /// input streams that would complicate the channel layout or activate a
    /// Bluetooth microphone.
    public static func builtInOutputDeviceID() -> AudioObjectID? {
        guard let ids = try? caGetDeviceIDs() else { return nil }
        for id in ids {
            let transport = (try? caGetValue(
                id, kAudioDevicePropertyTransportType,
                initial: UInt32(0), what: "transport type"
            )) ?? 0
            guard transport == kAudioDeviceTransportTypeBuiltIn else { continue }
            let outputChannels = (try? caGetStreamChannelCounts(id, scope: kAudioDevicePropertyScopeOutput))?
                .reduce(0, +) ?? 0
            if outputChannels > 0 { return id }
        }
        return nil
    }

    /// The system default output device, if any.
    public static func defaultOutputDeviceID() -> AudioObjectID? {
        let id = try? caGetValue(
            AudioObjectID(kAudioObjectSystemObject),
            kAudioHardwarePropertyDefaultOutputDevice,
            initial: AudioObjectID(kAudioObjectUnknown),
            what: "default output device"
        )
        guard let id, id != kAudioObjectUnknown else { return nil }
        return id
    }

    /// Registers a listener invoked on the main queue whenever the device list changes.
    /// Returns a token closure that removes the listener when called.
    public static func observeDeviceListChanges(_ onChange: @escaping () -> Void) -> () -> Void {
        var address = caAddress(kAudioHardwarePropertyDevices)
        let systemID = AudioObjectID(kAudioObjectSystemObject)
        let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
        AudioObjectAddPropertyListenerBlock(systemID, &address, DispatchQueue.main, block)
        return {
            var addr = caAddress(kAudioHardwarePropertyDevices)
            AudioObjectRemovePropertyListenerBlock(systemID, &addr, DispatchQueue.main, block)
        }
    }
}
