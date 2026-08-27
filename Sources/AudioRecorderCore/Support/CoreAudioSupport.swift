import CoreAudio
import Foundation

/// Errors thrown by Core Audio interactions.
public enum CoreAudioError: LocalizedError {
    case osStatus(OSStatus, String)

    public var errorDescription: String? {
        switch self {
        case let .osStatus(status, what):
            return "Core Audio error \(status) while \(what)"
        }
    }
}

/// Throws if a Core Audio call did not succeed.
@inline(__always)
func caCheck(_ status: OSStatus, _ what: String) throws {
    guard status == noErr else { throw CoreAudioError.osStatus(status, what) }
}

@inline(__always)
func caAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
}

/// Reads a fixed-size property value.
func caGetValue<T>(
    _ objectID: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
    initial: T,
    what: String
) throws -> T {
    var address = caAddress(selector, scope: scope)
    var size = UInt32(MemoryLayout<T>.size)
    var value = initial
    try withUnsafeMutablePointer(to: &value) { pointer in
        try caCheck(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer),
            what
        )
    }
    return value
}

/// Reads a CFString property (e.g. device name / UID).
func caGetString(
    _ objectID: AudioObjectID,
    _ selector: AudioObjectPropertySelector,
    what: String
) throws -> String {
    var address = caAddress(selector)
    var size = UInt32(MemoryLayout<CFString?>.size)
    var value: CFString?
    try withUnsafeMutablePointer(to: &value) { ptr in
        try caCheck(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, ptr),
            what
        )
    }
    guard let result = value else {
        throw CoreAudioError.osStatus(-1, "\(what): nil string")
    }
    return result as String
}

/// Reads the list of all audio device IDs in the system.
func caGetDeviceIDs() throws -> [AudioObjectID] {
    var address = caAddress(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    let systemID = AudioObjectID(kAudioObjectSystemObject)
    try caCheck(
        AudioObjectGetPropertyDataSize(systemID, &address, 0, nil, &size),
        "getting device list size"
    )
    let count = Int(size) / MemoryLayout<AudioObjectID>.size
    var ids = [AudioObjectID](repeating: 0, count: count)
    try caCheck(
        AudioObjectGetPropertyData(systemID, &address, 0, nil, &size, &ids),
        "getting device list"
    )
    return ids
}

/// Returns the channel count of each stream (in order) for the given scope.
/// The order matches the buffer order delivered to an IOProc.
func caGetStreamChannelCounts(
    _ objectID: AudioObjectID,
    scope: AudioObjectPropertyScope
) throws -> [Int] {
    var address = caAddress(kAudioDevicePropertyStreamConfiguration, scope: scope)
    var size: UInt32 = 0
    try caCheck(
        AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size),
        "getting stream configuration size"
    )
    guard size > 0 else { return [] }
    let raw = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size),
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { raw.deallocate() }
    try caCheck(
        AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, raw),
        "getting stream configuration"
    )
    let abl = UnsafeMutableAudioBufferListPointer(
        raw.assumingMemoryBound(to: AudioBufferList.self)
    )
    return abl.map { Int($0.mNumberChannels) }
}

/// Total input channel count for a device.
func caGetInputChannelCount(_ objectID: AudioObjectID) -> Int {
    let counts = (try? caGetStreamChannelCounts(objectID, scope: kAudioDevicePropertyScopeInput)) ?? []
    return counts.reduce(0, +)
}
