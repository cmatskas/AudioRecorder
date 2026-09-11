import Foundation
import Synchronization

/// One capture source's delivery path: fans interleaved stereo frames out to
/// any attached ring buffers, and keeps the written frame count proportional to
/// wall-clock time.
///
/// Each track records the host time of its first frame (its *anchor*). On every
/// buffer it compares the expected frame position derived from the incoming
/// host timestamp against how many frames it has actually written; a shortfall
/// beyond `gapToleranceSeconds` means the device stalled (a Bluetooth dropout,
/// for example) and the missing span is filled with silence.
///
/// The effect is that frame N of a track always corresponds to
/// `anchorHostTime + N / sampleRate`, so two tracks recorded from unrelated
/// clocks can be aligned offline from their anchors alone — no cross-source
/// coordination happens on the real-time thread.
///
/// Muting substitutes silence for the incoming samples rather than dropping
/// them, for the same reason gaps are filled: the frame count must stay
/// proportional to wall-clock time or the offline merge would pull everything
/// after the muted span backwards in time.
public final class CaptureTrack: @unchecked Sendable {
    /// Stalls shorter than this are ignored as ordinary jitter.
    private static let gapToleranceSeconds = 0.02
    /// Never fill more than this in one go, to bound the damage from a wild
    /// timestamp.
    private static let maxGapFillSeconds = 2.0
    private static let silenceChunkFrames = 4096

    public let label: String
    public private(set) var sampleRate: Double
    /// Interleaved channel count (always 2: sources are normalised to stereo).
    public let channels = 2

    private var sinks: [RingBuffer] = []
    private let sinksLock: UnsafeMutablePointer<os_unfair_lock_s>

    private let anchor = Atomic<UInt64>(0)
    private let frames = Atomic<Int>(0)
    private let dropped = Atomic<Int>(0)
    private let gapFilled = Atomic<Int>(0)
    private let muted = Atomic<Bool>(false)
    private let mutedFrames = Atomic<Int>(0)

    private let silence: UnsafeMutablePointer<Float>
    private var hostTicksPerSecond: Double

    public init(label: String, sampleRate: Double) {
        self.label = label
        self.sampleRate = sampleRate
        sinksLock = UnsafeMutablePointer<os_unfair_lock_s>.allocate(capacity: 1)
        sinksLock.initialize(to: os_unfair_lock_s())
        silence = UnsafeMutablePointer<Float>.allocate(
            capacity: Self.silenceChunkFrames * 2
        )
        silence.initialize(repeating: 0, count: Self.silenceChunkFrames * 2)
        hostTicksPerSecond = CaptureTrack.hostTicksPerSecond()
    }

    deinit {
        silence.deallocate()
        sinksLock.deallocate()
    }

    /// Host clock ticks per second, from the mach timebase.
    public static func hostTicksPerSecond() -> Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        guard info.numer != 0, info.denom != 0 else { return 1_000_000_000 }
        return 1_000_000_000 * Double(info.denom) / Double(info.numer)
    }

    public func updateSampleRate(_ rate: Double) {
        sampleRate = rate
    }

    /// Host time of this track's first written frame (0 if it has not started).
    public var anchorHostTime: UInt64 { anchor.load(ordering: .acquiring) }
    public var framesWritten: Int { frames.load(ordering: .relaxed) }
    public var framesDropped: Int { dropped.load(ordering: .relaxed) }
    public var framesGapFilled: Int { gapFilled.load(ordering: .relaxed) }
    /// Frames written as silence because the source was muted.
    public var framesMuted: Int { mutedFrames.load(ordering: .relaxed) }

    /// Whether incoming audio is being replaced with silence.
    public var isMuted: Bool { muted.load(ordering: .acquiring) }

    /// Mutes or unmutes this source. Safe to call at any time, including
    /// mid-recording: the destinations, writers and timeline are unaffected,
    /// so only the audio content changes.
    public func setMuted(_ value: Bool) {
        muted.store(value, ordering: .releasing)
    }
    public var ticksPerSecond: Double { hostTicksPerSecond }

    /// Attaches destinations and resets the timeline. Passing an empty array
    /// detaches (recording stopped).
    public func setSinks(_ newSinks: [RingBuffer]) {
        os_unfair_lock_lock(sinksLock)
        sinks = newSinks
        os_unfair_lock_unlock(sinksLock)
        if !newSinks.isEmpty {
            anchor.store(0, ordering: .releasing)
            frames.store(0, ordering: .relaxed)
            dropped.store(0, ordering: .relaxed)
            gapFilled.store(0, ordering: .relaxed)
            mutedFrames.store(0, ordering: .relaxed)
        }
    }

    public var isAttached: Bool {
        os_unfair_lock_lock(sinksLock)
        defer { os_unfair_lock_unlock(sinksLock) }
        return !sinks.isEmpty
    }

    /// Real-time entry point: appends interleaved stereo frames captured at
    /// `hostTime`, inserting silence first if the device stalled.
    public func append(
        _ data: UnsafePointer<Float>,
        frameCount: Int,
        hostTime: UInt64
    ) {
        os_unfair_lock_lock(sinksLock)
        let hasSinks = !sinks.isEmpty
        os_unfair_lock_unlock(sinksLock)
        guard hasSinks, frameCount > 0 else { return }

        // Establish the anchor on the first buffer of a recording.
        var anchorTime = anchor.load(ordering: .acquiring)
        if anchorTime == 0 {
            anchorTime = hostTime == 0 ? mach_absolute_time() : hostTime
            anchor.store(anchorTime, ordering: .releasing)
        }

        // Fill any wall-clock gap so frame position stays proportional to time.
        if hostTime > anchorTime {
            let elapsedSeconds = Double(hostTime - anchorTime) / hostTicksPerSecond
            let expectedFrames = Int(elapsedSeconds * sampleRate)
            let written = frames.load(ordering: .relaxed)
            let gap = expectedFrames - written
            if Double(gap) > Self.gapToleranceSeconds * sampleRate {
                let capped = min(gap, Int(Self.maxGapFillSeconds * sampleRate))
                var remaining = capped
                while remaining > 0 {
                    let chunk = min(remaining, Self.silenceChunkFrames)
                    writeToSinks(silence, frameCount: chunk)
                    remaining -= chunk
                }
                _ = gapFilled.wrappingAdd(capped, ordering: .relaxed)
                _ = frames.wrappingAdd(capped, ordering: .relaxed)
            }
        }

        if muted.load(ordering: .acquiring) {
            writeSilence(frameCount: frameCount)
            _ = mutedFrames.wrappingAdd(frameCount, ordering: .relaxed)
        } else {
            writeToSinks(data, frameCount: frameCount)
        }
        _ = frames.wrappingAdd(frameCount, ordering: .relaxed)
    }

    /// Writes `frameCount` frames of silence, chunked to the preallocated
    /// buffer so the real-time path never allocates.
    @inline(__always)
    private func writeSilence(frameCount: Int) {
        var remaining = frameCount
        while remaining > 0 {
            let chunk = min(remaining, Self.silenceChunkFrames)
            writeToSinks(silence, frameCount: chunk)
            remaining -= chunk
        }
    }

    @inline(__always)
    private func writeToSinks(_ data: UnsafePointer<Float>, frameCount: Int) {
        let floats = frameCount * channels
        os_unfair_lock_lock(sinksLock)
        for sink in sinks {
            if !sink.write(data, count: floats) {
                _ = dropped.wrappingAdd(frameCount, ordering: .relaxed)
            }
        }
        os_unfair_lock_unlock(sinksLock)
    }
}
