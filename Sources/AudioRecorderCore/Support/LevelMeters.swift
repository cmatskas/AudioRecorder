import Foundation
import Synchronization

/// Stereo RMS levels published from the real-time audio thread and read by the UI.
/// Each pair of Float levels is packed into a single UInt64 for atomic access.
public final class LevelMeters: @unchecked Sendable {
    private let micBits = Atomic<UInt64>(0)
    private let systemBits = Atomic<UInt64>(0)

    public init() {}

    @inline(__always)
    private static func pack(_ left: Float, _ right: Float) -> UInt64 {
        (UInt64(left.bitPattern) << 32) | UInt64(right.bitPattern)
    }

    @inline(__always)
    private static func unpack(_ bits: UInt64) -> (Float, Float) {
        (
            Float(bitPattern: UInt32(truncatingIfNeeded: bits >> 32)),
            Float(bitPattern: UInt32(truncatingIfNeeded: bits))
        )
    }

    func setMic(left: Float, right: Float) {
        micBits.store(Self.pack(left, right), ordering: .relaxed)
    }

    func setSystem(left: Float, right: Float) {
        systemBits.store(Self.pack(left, right), ordering: .relaxed)
    }

    /// RMS levels (0...1) for the microphone pair.
    public var mic: (left: Float, right: Float) {
        Self.unpack(micBits.load(ordering: .relaxed))
    }

    /// RMS levels (0...1) for the system audio pair.
    public var system: (left: Float, right: Float) {
        Self.unpack(systemBits.load(ordering: .relaxed))
    }

    public func reset() {
        micBits.store(0, ordering: .relaxed)
        systemBits.store(0, ordering: .relaxed)
    }
}
