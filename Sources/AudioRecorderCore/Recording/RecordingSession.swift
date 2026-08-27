import Foundation
import Synchronization

/// Coordinates one recording: captures from a `CaptureEngine` and writes to
/// one or two destinations (the always-on backup, plus an optional
/// user-chosen destination), each with its own ring buffer and writer thread
/// so a slow or failing destination can never stall the other — or the
/// audio thread.
public final class RecordingSession: @unchecked Sendable {
    public struct Result: Sendable {
        public let backupM4A: URL?
        public let userM4A: URL?
        public let sessionDirectory: URL
        public let framesDropped: Int
        public let warnings: [String]
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

    private final class Destination {
        let label: String
        let root: URL
        let ring: RingBuffer
        let writer: SessionWriter
        let done = DispatchSemaphore(value: 0)
        var thread: Thread?
        let failure = Mutex<String?>(nil)
        /// Whether this is the user-selected destination (cleaned up after encode).
        let isUserDestination: Bool

        init(label: String, root: URL, ring: RingBuffer, writer: SessionWriter, isUserDestination: Bool) {
            self.label = label
            self.root = root
            self.ring = ring
            self.writer = writer
            self.isUserDestination = isUserDestination
        }
    }

    public let sessionName: String
    private let engine: CaptureEngine
    private let channels: Int
    private var destinations: [Destination] = []
    private let stopRequested = Atomic<Bool>(false)
    private var started = false

    /// Ring capacity: 30 seconds of headroom per destination.
    private static let ringSeconds = 30.0

    public init(
        engine: CaptureEngine,
        backupRoot: URL,
        userDestinationRoot: URL?,
        micName: String?,
        systemAudio: Bool
    ) throws {
        self.engine = engine
        self.channels = engine.outputChannels

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        sessionName = "recording_\(formatter.string(from: Date()))"

        let ringCapacity = Int(Self.ringSeconds * engine.sampleRate) * channels

        func makeDestination(label: String, root: URL, isUser: Bool) throws -> Destination {
            Destination(
                label: label,
                root: root,
                ring: RingBuffer(capacityFloats: ringCapacity),
                writer: try SessionWriter(
                    destinationRoot: root,
                    sessionName: sessionName,
                    sampleRate: engine.sampleRate,
                    channels: channels,
                    micName: micName,
                    systemAudio: systemAudio
                ),
                isUserDestination: isUser
            )
        }

        destinations.append(try makeDestination(label: "backup", root: backupRoot, isUser: false))
        if let userRoot = userDestinationRoot,
           userRoot.standardizedFileURL != backupRoot.standardizedFileURL {
            do {
                destinations.append(
                    try makeDestination(label: "primary", root: userRoot, isUser: true)
                )
            } catch {
                // The backup destination alone is enough to record; surface later.
                initWarnings.append(
                    "Could not write to the chosen destination (\(error.localizedDescription)). Recording to backup only."
                )
            }
        }
    }

    private var initWarnings: [String] = []

    // MARK: - Lifecycle

    public func start() {
        guard !started else { return }
        started = true

        for index in destinations.indices {
            let destination = destinations[index]
            let ring = destination.ring
            let writer = destination.writer
            let done = destination.done
            let channelCount = channels

            let thread = Thread { [self] in
                let chunkFrames = 16384
                let capacityFloats = chunkFrames * channelCount
                let buffer = UnsafeMutablePointer<Float>.allocate(capacity: capacityFloats)
                defer { buffer.deallocate() }

                var failed = false
                while true {
                    let floats = ring.read(into: buffer, maxCount: capacityFloats)
                    if floats > 0 {
                        if !failed {
                            do {
                                try writer.append(buffer, frameCount: floats / channelCount)
                            } catch {
                                failed = true
                                destination.failure.withLock { $0 = error.localizedDescription }
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
                        try writer.finish()
                    } catch {
                        destination.failure.withLock { $0 = error.localizedDescription }
                    }
                }
                done.signal()
            }
            thread.name = "SessionWriter-\(destination.label)"
            thread.qualityOfService = .userInitiated
            thread.start()
            destinations[index].thread = thread
        }

        engine.setSinks(destinations.map(\.ring))
    }

    /// Stops capture, drains and finalizes all destinations, encodes the final
    /// `.m4a`, and copies it to the user destination. Blocking; call off-main.
    public func stopAndFinalize() throws -> Result {
        engine.setSinks([])
        stopRequested.store(true, ordering: .releasing)
        for destination in destinations {
            destination.done.wait()
        }

        var warnings = initWarnings
        var healthy: [Destination] = []
        for destination in destinations {
            if let reason = destination.failure.withLock({ $0 }) {
                warnings.append("Destination '\(destination.label)' failed: \(reason)")
            } else {
                healthy.append(destination)
            }
        }
        guard let canonical = healthy.first else {
            throw SessionError.allWritersFailed(warnings)
        }

        // Encode once from the first healthy destination's PCM masters.
        let manifest = canonical.writer.currentManifest
        let m4aName = "\(sessionName).m4a"
        let encodedURL = canonical.writer.sessionDirectory.appendingPathComponent(m4aName)
        try SessionEncoder.encode(
            sessionDirectory: canonical.writer.sessionDirectory,
            manifest: manifest,
            outputURL: encodedURL
        )

        var backupM4A: URL?
        var userM4A: URL?
        for destination in healthy {
            if destination.isUserDestination {
                // User side gets the .m4a at the root of their chosen folder;
                // its live PCM copy is then redundant and removed.
                let target = destination.root.appendingPathComponent(m4aName)
                do {
                    try? FileManager.default.removeItem(at: target)
                    try FileManager.default.copyItem(at: encodedURL, to: target)
                    userM4A = target
                    if destination.writer.sessionDirectory != canonical.writer.sessionDirectory {
                        try? FileManager.default.removeItem(at: destination.writer.sessionDirectory)
                    }
                } catch {
                    warnings.append("Could not copy recording to destination: \(error.localizedDescription)")
                }
            } else {
                backupM4A = encodedURL
            }
        }
        // If the backup writer failed but the user one survived, the encode
        // lives in the user session directory.
        if backupM4A == nil && userM4A == nil {
            userM4A = encodedURL
        }

        let dropped = engine.framesDropped
        if dropped > 0 {
            warnings.append("\(dropped) audio frames were dropped (destination too slow)")
        }

        return Result(
            backupM4A: backupM4A,
            userM4A: userM4A,
            sessionDirectory: canonical.writer.sessionDirectory,
            framesDropped: dropped,
            warnings: warnings
        )
    }
}
