import Foundation
import Synchronization

/// Coordinates one recording: captures from a `CaptureEngine` and writes every
/// source to every destination.
///
/// The layout is destinations × sources. Each pair gets its own ring buffer and
/// its own writer thread, so nothing is coupled:
///
///  - a slow or failing destination cannot stall the other destination,
///  - a stalling source (a Bluetooth dropout, say) cannot stall the other
///    source, and cannot stall the audio thread,
///  - the always-on backup destination survives failures of the user-chosen one.
///
/// Sources are written as separate PCM masters at their native rates and merged
/// offline in `SessionEncoder`, which is also the path crash recovery uses.
public final class RecordingSession: @unchecked Sendable {
    public struct Result: Sendable {
        public let backupM4A: URL?
        public let userM4A: URL?
        public let sessionDirectory: URL
        public let framesDropped: Int
        public let framesGapFilled: Int
        public let warnings: [String]
    }

    /// Additional ring buffers attached to the capture sources alongside the
    /// recording lanes — used by optional consumers such as live analysis.
    /// They receive the same interleaved stereo frames as the writers but are
    /// otherwise invisible to the session: a slow or abandoned extra sink
    /// drops its own data and can never stall recording.
    public struct ExtraSinks: Sendable {
        public var mic: [RingBuffer]
        public var system: [RingBuffer]

        public init(mic: [RingBuffer] = [], system: [RingBuffer] = []) {
            self.mic = mic
            self.system = system
        }
    }

    public enum SessionError: LocalizedError {
        case allWritersFailed([String])

        public var errorDescription: String? {
            switch self {
            case let .allWritersFailed(reasons):
                return "All destinations failed: \(reasons.joined(separator: "; "))"
            }
        }
    }

    /// One source's pipeline into one destination.
    private final class Lane {
        let sourceLabel: String
        let ring: RingBuffer
        let writer: TrackWriter
        let done = DispatchSemaphore(value: 0)
        let failure = Mutex<String?>(nil)

        init(sourceLabel: String, ring: RingBuffer, writer: TrackWriter) {
            self.sourceLabel = sourceLabel
            self.ring = ring
            self.writer = writer
        }
    }

    private final class Destination {
        let label: String
        let root: URL
        let store: SessionStore
        let isUserDestination: Bool
        var lanes: [Lane] = []

        init(label: String, root: URL, store: SessionStore, isUserDestination: Bool) {
            self.label = label
            self.root = root
            self.store = store
            self.isUserDestination = isUserDestination
        }
    }

    public let sessionName: String
    private let engine: CaptureEngine
    private let tracks: [CaptureTrack]
    private var destinations: [Destination] = []
    private let extraSinks: ExtraSinks
    private let stopRequested = Atomic<Bool>(false)
    private var started = false
    private var initWarnings: [String] = []

    /// Ring capacity per lane: 30 seconds of headroom.
    private static let ringSeconds = 30.0

    /// Directory of the backup destination's live session — where optional
    /// side artifacts (transcripts, insights) should be persisted.
    public var backupSessionDirectory: URL? {
        destinations.first(where: { !$0.isUserDestination })?.store.directory
    }

    public init(
        engine: CaptureEngine,
        backupRoot: URL,
        userDestinationRoot: URL?,
        micName: String?,
        extraSinks: ExtraSinks = ExtraSinks()
    ) throws {
        self.engine = engine
        self.extraSinks = extraSinks
        tracks = [engine.micTrack, engine.systemTrack].compactMap { $0 }
        guard !tracks.isEmpty else {
            throw CoreAudioError.osStatus(-1, "starting recording: no active sources")
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        sessionName = "recording_\(formatter.string(from: Date()))"

        let manifestTracks = tracks.map { track in
            SessionManifest.Track(
                label: track.label,
                sampleRate: track.sampleRate,
                channels: track.channels,
                hostTicksPerSecond: track.ticksPerSecond
            )
        }

        func makeDestination(label: String, root: URL, isUser: Bool) throws -> Destination {
            let store = try SessionStore(
                destinationRoot: root,
                sessionName: sessionName,
                micName: micName,
                tracks: manifestTracks
            )
            let destination = Destination(
                label: label, root: root, store: store, isUserDestination: isUser
            )
            for track in tracks {
                let capacity = Int(Self.ringSeconds * track.sampleRate) * track.channels
                destination.lanes.append(
                    Lane(
                        sourceLabel: track.label,
                        ring: RingBuffer(capacityFloats: capacity),
                        writer: try TrackWriter(
                            store: store,
                            label: track.label,
                            sampleRate: track.sampleRate,
                            channels: track.channels
                        )
                    )
                )
            }
            return destination
        }

        destinations.append(try makeDestination(label: "backup", root: backupRoot, isUser: false))
        if let userRoot = userDestinationRoot,
           userRoot.standardizedFileURL != backupRoot.standardizedFileURL {
            do {
                destinations.append(
                    try makeDestination(label: "primary", root: userRoot, isUser: true)
                )
            } catch {
                initWarnings.append(
                    "Could not write to the chosen destination (\(error.localizedDescription)). Recording to backup only."
                )
            }
        }
    }

    // MARK: - Lifecycle

    public func start() {
        guard !started else { return }
        started = true

        for destination in destinations {
            for lane in destination.lanes {
                let thread = Thread { [self] in
                    drain(lane: lane, channels: 2)
                }
                thread.name = "TrackWriter-\(destination.label)-\(lane.sourceLabel)"
                thread.qualityOfService = .userInitiated
                thread.start()
            }
        }

        // Attach each source to the matching lane in every destination, plus
        // any extra (analysis) sinks.
        engine.setSinks(
            mic: rings(forSource: "mic") + extraSinks.mic,
            system: rings(forSource: "system") + extraSinks.system
        )
    }

    private func rings(forSource label: String) -> [RingBuffer] {
        destinations.flatMap { destination in
            destination.lanes.filter { $0.sourceLabel == label }.map(\.ring)
        }
    }

    private func drain(lane: Lane, channels: Int) {
        let chunkFrames = 16384
        let capacityFloats = chunkFrames * channels
        let buffer = UnsafeMutablePointer<Float>.allocate(capacity: capacityFloats)
        defer { buffer.deallocate() }

        var failed = false
        while true {
            let floats = lane.ring.read(into: buffer, maxCount: capacityFloats)
            if floats > 0 {
                if !failed {
                    do {
                        try lane.writer.append(buffer, frameCount: floats / channels)
                    } catch {
                        failed = true
                        lane.failure.withLock { $0 = error.localizedDescription }
                    }
                }
            } else if stopRequested.load(ordering: .acquiring) {
                break
            } else {
                usleep(10_000)
            }
        }
        if !failed {
            do {
                try lane.writer.finish()
            } catch {
                lane.failure.withLock { $0 = error.localizedDescription }
            }
        }
        lane.done.signal()
    }

    /// Stops capture, drains and finalizes every lane, records the host-time
    /// anchors, renders the merged `.m4a`, and copies it to the user
    /// destination. Blocking; call off the main thread.
    public func stopAndFinalize() throws -> Result {
        engine.setSinks(mic: [], system: [])
        stopRequested.store(true, ordering: .releasing)
        for destination in destinations {
            for lane in destination.lanes {
                lane.done.wait()
            }
        }

        var warnings = initWarnings

        // Persist anchors so the offline merge can align the tracks.
        for destination in destinations {
            for track in tracks {
                do {
                    try destination.store.setAnchor(
                        track.anchorHostTime,
                        ticksPerSecond: track.ticksPerSecond,
                        forTrack: track.label
                    )
                } catch {
                    warnings.append(
                        "Could not record timing anchor for \(track.label): \(error.localizedDescription)"
                    )
                }
            }
        }

        // A destination is healthy if at least one of its lanes wrote cleanly.
        var healthy: [Destination] = []
        for destination in destinations {
            let failures = destination.lanes.compactMap { lane in
                lane.failure.withLock { $0 }.map { "\(lane.sourceLabel): \($0)" }
            }
            if failures.count == destination.lanes.count {
                warnings.append(
                    "Destination '\(destination.label)' failed: \(failures.joined(separator: "; "))"
                )
            } else {
                if !failures.isEmpty {
                    warnings.append(
                        "Destination '\(destination.label)' partially failed: \(failures.joined(separator: "; "))"
                    )
                }
                healthy.append(destination)
            }
        }
        guard let canonical = healthy.first else {
            throw SessionError.allWritersFailed(warnings)
        }

        for destination in healthy {
            try? destination.store.setStatus(.complete)
        }

        // Encode once from the canonical destination's PCM masters.
        let m4aName = "\(sessionName).m4a"
        let encodedURL = canonical.store.directory.appendingPathComponent(m4aName)
        try SessionEncoder.encode(
            sessionDirectory: canonical.store.directory,
            manifest: canonical.store.currentManifest,
            outputURL: encodedURL
        )

        var backupM4A: URL?
        var userM4A: URL?
        for destination in healthy {
            if destination.isUserDestination {
                // The user destination receives the finished .m4a at the root of
                // their chosen folder; its live PCM copy is then redundant.
                let target = destination.root.appendingPathComponent(m4aName)
                do {
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.copyItem(at: encodedURL, to: target)
                    userM4A = target
                    if destination.store.directory != canonical.store.directory {
                        try? FileManager.default.removeItem(at: destination.store.directory)
                    }
                } catch {
                    warnings.append(
                        "Could not copy recording to destination: \(error.localizedDescription)"
                    )
                }
            } else {
                backupM4A = encodedURL
            }
        }
        if backupM4A == nil && userM4A == nil {
            userM4A = encodedURL
        }

        let dropped = engine.framesDropped
        if dropped > 0 {
            warnings.append("\(dropped) audio frames were dropped (destination too slow)")
        }
        let gapFilled = engine.framesGapFilled
        if gapFilled > 0 {
            warnings.append(
                "\(gapFilled) frames of silence were inserted to cover device dropouts"
            )
        }

        return Result(
            backupM4A: backupM4A,
            userM4A: userM4A,
            sessionDirectory: canonical.store.directory,
            framesDropped: dropped,
            framesGapFilled: gapFilled,
            warnings: warnings
        )
    }
}
