import Foundation

/// Owns one destination's on-disk representation of a recording session:
/// a directory containing CAF segments plus a `session.json` manifest.
///
/// Durability policy:
///  - audio is appended continuously (never buffered in memory beyond the ring),
///  - `F_FULLFSYNC` every `syncInterval` seconds bounds power-loss data loss,
///  - segments roll every `segmentDuration` seconds so all but the live
///    segment are fully finalized files,
///  - the manifest records each segment the moment it is opened, so recovery
///    always knows what exists.
public final class SessionWriter {
    public let sessionDirectory: URL
    public let sampleRate: Double
    public let channels: Int

    /// Roll to a new segment every 10 minutes.
    private let segmentFrames: Int
    /// Force data to media every 5 seconds.
    private let syncFrames: Int

    private var manifest: SessionManifest
    private var currentSegment: CAFWriter?
    private var segmentIndex = 0
    private var framesInSegment = 0
    private var framesSinceSync = 0

    public init(
        destinationRoot: URL,
        sessionName: String,
        sampleRate: Double,
        channels: Int,
        micName: String?,
        systemAudio: Bool,
        segmentDuration: TimeInterval = 600,
        syncInterval: TimeInterval = 5
    ) throws {
        sessionDirectory = destinationRoot.appendingPathComponent(sessionName, isDirectory: true)
        self.sampleRate = sampleRate
        self.channels = channels
        segmentFrames = max(1, Int(segmentDuration * sampleRate))
        syncFrames = max(1, Int(syncInterval * sampleRate))

        try FileManager.default.createDirectory(
            at: sessionDirectory,
            withIntermediateDirectories: true
        )
        manifest = SessionManifest(
            name: sessionName,
            sampleRate: sampleRate,
            channels: channels,
            micName: micName,
            systemAudio: systemAudio
        )
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

    /// Finalizes the live segment and marks the session complete.
    public func finish() throws {
        try currentSegment?.finalize()
        currentSegment = nil
        manifest.status = .complete
        try manifest.save(to: sessionDirectory)
    }

    public var currentManifest: SessionManifest { manifest }

    // MARK: - Segments

    private func openNextSegment() throws {
        segmentIndex += 1
        let name = String(format: "segment_%03d.caf", segmentIndex)
        currentSegment = try CAFWriter(
            url: sessionDirectory.appendingPathComponent(name),
            sampleRate: sampleRate,
            channels: channels
        )
        framesInSegment = 0
        framesSinceSync = 0
        manifest.segments.append(name)
        try manifest.save(to: sessionDirectory)
    }

    private func rollSegment() throws {
        try currentSegment?.finalize()
        currentSegment = nil
        try openNextSegment()
    }
}
