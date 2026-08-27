import Foundation
import Synchronization

/// A lock-free single-producer / single-consumer ring buffer of Float samples.
///
/// The producer is the real-time audio IOProc; the consumer is a writer thread.
/// `write` never blocks: if there is not enough free space the data is dropped
/// and counted, which keeps the audio thread real-time safe.
public final class RingBuffer: @unchecked Sendable {
    private let capacity: Int
    private let storage: UnsafeMutablePointer<Float>
    /// Total floats ever written (monotonically increasing).
    private let head = Atomic<Int>(0)
    /// Total floats ever read (monotonically increasing).
    private let tail = Atomic<Int>(0)
    private let droppedFloats = Atomic<Int>(0)

    public init(capacityFloats: Int) {
        precondition(capacityFloats > 0)
        capacity = capacityFloats
        storage = UnsafeMutablePointer<Float>.allocate(capacity: capacityFloats)
        storage.initialize(repeating: 0, count: capacityFloats)
    }

    deinit {
        storage.deallocate()
    }

    /// Number of floats available to read.
    public var availableToRead: Int {
        head.load(ordering: .acquiring) - tail.load(ordering: .acquiring)
    }

    /// Total floats dropped due to overflow.
    public var dropped: Int {
        droppedFloats.load(ordering: .relaxed)
    }

    /// Producer side. Returns false (and drops the data) if there is not enough room.
    @discardableResult
    public func write(_ data: UnsafePointer<Float>, count: Int) -> Bool {
        guard count > 0 else { return true }
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        let free = capacity - (h - t)
        guard count <= free else {
            _ = droppedFloats.wrappingAdd(count, ordering: .relaxed)
            return false
        }
        let index = h % capacity
        let firstPart = min(count, capacity - index)
        memcpy(storage + index, data, firstPart * MemoryLayout<Float>.size)
        if count > firstPart {
            memcpy(storage, data + firstPart, (count - firstPart) * MemoryLayout<Float>.size)
        }
        head.store(h + count, ordering: .releasing)
        return true
    }

    /// Consumer side. Reads up to `maxCount` floats; returns the number read.
    public func read(into out: UnsafeMutablePointer<Float>, maxCount: Int) -> Int {
        guard maxCount > 0 else { return 0 }
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        let available = h - t
        let n = min(available, maxCount)
        guard n > 0 else { return 0 }
        let index = t % capacity
        let firstPart = min(n, capacity - index)
        memcpy(out, storage + index, firstPart * MemoryLayout<Float>.size)
        if n > firstPart {
            memcpy(out + firstPart, storage, (n - firstPart) * MemoryLayout<Float>.size)
        }
        tail.store(t + n, ordering: .releasing)
        return n
    }
}
