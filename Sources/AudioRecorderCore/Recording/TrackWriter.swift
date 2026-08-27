import Foundation

/// Writes one capture source's CAF segments into a session directory.
///
/// Durability policy (unchanged from the single-stream design, now applied per
/// source): audio is appended continuously, `F_FULLFSYNC` runs every
/// `syncInterval` seconds to bound loss on power failure, segments roll every
/// `segmentDuration` seconds so all but the live segment are complete files,
/// and each segment is registered with the session store the moment it is
/// opened so recovery always knows what exists.
public final class TrackWriter {
    public let label: String
    public let sampleRate: Double
    public let channels: Int

    private let store: SessionStore
    private let segmentFrames: Int
    private let syncFrames: Int

    private var currentSegment: CAFWriter?
    private var segmentIndex = 0
    private var framesInSegment = 0
    private var framesSinceSync = 0

    public init(
        store: SessionStore,
        label: String,
        sampleRate: Double,
        channels: Int = 2,
        segmentDuration: TimeInterval = 600,
        syncInterval: TimeInterval = 5
    ) throws {
        self.store = store
        self.label = label
        self.sampleRate = sampleRate
        self.channels = channels
        segmentFrames = max(1, Int(segmentDuration * sampleRate))
        syncFrames = max(1, Int(syncInterval * sampleRate))
        try openNextSegment()
    }

    /// Appends interleaved Float32 frames, rolling segments and syncing as needed.
    public func append(_ interleaved: UnsafePointer<Float>, frameCount: Int) throws {
        if framesInSegment >= segmentFrames {
            try rollSegment()
        }
        guard let segment = currentSegment else { return }
        try segment.append(interleaved, frameCount: frameCount)
        framesInSegment += frameCount
        framesSinceSync += frameCount
        if framesSinceSync >= syncFrames {
            segment.sync()
            framesSinceSync = 0
        }
    }

    /// Finalizes the live segment. The session status is owned by the store.
    public func finish() throws {
        try currentSegment?.finalize()
        currentSegment = nil
    }

    // MARK: - Segments

    private func openNextSegment() throws {
        segmentIndex += 1
        let name = String(format: "%@_%03d.caf", label, segmentIndex)
        currentSegment = try CAFWriter(
            url: store.directory.appendingPathComponent(name),
            sampleRate: sampleRate,
            channels: channels
        )
        framesInSegment = 0
        framesSinceSync = 0
        try store.addSegment(name, toTrack: label)
    }

    private func rollSegment() throws {
        try currentSegment?.finalize()
        currentSegment = nil
        try openNextSegment()
    }
}
