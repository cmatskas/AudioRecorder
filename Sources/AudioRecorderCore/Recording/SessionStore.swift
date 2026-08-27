import Foundation

/// Owns one destination's session directory and its manifest.
///
/// Several `TrackWriter`s (one per capture source) write into the same
/// directory from their own threads, so all manifest mutations are serialised
/// here and persisted immediately — the manifest on disk always describes what
/// exists, which is what makes crash recovery possible.
public final class SessionStore: @unchecked Sendable {
    public let directory: URL
    private var manifest: SessionManifest
    private let lock = NSLock()

    public init(
        destinationRoot: URL,
        sessionName: String,
        micName: String?,
        tracks: [SessionManifest.Track]
    ) throws {
        directory = destinationRoot.appendingPathComponent(sessionName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        manifest = SessionManifest(name: sessionName, micName: micName, tracks: tracks)
        try manifest.save(to: directory)
    }

    public var currentManifest: SessionManifest {
        lock.lock()
        defer { lock.unlock() }
        return manifest
    }

    public func addSegment(_ name: String, toTrack label: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let index = manifest.tracks.firstIndex(where: { $0.label == label }) else { return }
        manifest.tracks[index].segments.append(name)
        try manifest.save(to: directory)
    }

    /// Records a track's host-time anchor once capture has actually started.
    public func setAnchor(_ hostTime: UInt64, ticksPerSecond: Double, forTrack label: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let index = manifest.tracks.firstIndex(where: { $0.label == label }) else { return }
        guard manifest.tracks[index].anchorHostTime != hostTime else { return }
        manifest.tracks[index].anchorHostTime = hostTime
        manifest.tracks[index].hostTicksPerSecond = ticksPerSecond
        try manifest.save(to: directory)
    }

    public func setStatus(_ status: SessionManifest.Status) throws {
        lock.lock()
        defer { lock.unlock() }
        manifest.status = status
        try manifest.save(to: directory)
    }
}
