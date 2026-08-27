import Foundation

/// Sidecar metadata written next to a recording session's audio segments.
/// A manifest whose status is still `.recording` at app launch marks a session
/// that was interrupted by a crash and can be recovered.
///
/// Version 2 stores each capture source as its own track, with its native
/// sample rate and a host-time anchor, so tracks recorded from unrelated clocks
/// can be aligned offline. Version 1 manifests (a single pre-merged stream) are
/// migrated on read and still recover.
public struct SessionManifest: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case recording
        case complete
        case discarded
    }

    /// One capture source's on-disk stream.
    public struct Track: Codable, Equatable, Sendable {
        /// Stable identifier: "mic", "system", or "merged" for migrated v1.
        public var label: String
        public var sampleRate: Double
        public var channels: Int
        /// Host time of this track's first frame; 0 if never started.
        public var anchorHostTime: UInt64
        /// Host clock ticks per second, for converting anchors to seconds.
        public var hostTicksPerSecond: Double
        /// Segment file names in recording order, relative to the session dir.
        public var segments: [String]

        public init(
            label: String,
            sampleRate: Double,
            channels: Int,
            anchorHostTime: UInt64 = 0,
            hostTicksPerSecond: Double,
            segments: [String] = []
        ) {
            self.label = label
            self.sampleRate = sampleRate
            self.channels = channels
            self.anchorHostTime = anchorHostTime
            self.hostTicksPerSecond = hostTicksPerSecond
            self.segments = segments
        }
    }

    public static let filename = "session.json"
    public static let currentVersion = 2

    public var version: Int
    public var name: String
    public var status: Status
    public var createdAt: Date
    public var micName: String?
    public var tracks: [Track]

    public init(name: String, micName: String?, tracks: [Track]) {
        self.version = Self.currentVersion
        self.name = name
        self.status = .recording
        self.createdAt = Date()
        self.micName = micName
        self.tracks = tracks
    }

    public func track(labeled label: String) -> Track? {
        tracks.first { $0.label == label }
    }

    /// The rate a merged render should target: the highest track rate.
    public var mergedSampleRate: Double {
        tracks.map(\.sampleRate).max() ?? 48_000
    }

    // MARK: - Persistence

    public static func load(from directory: URL) throws -> SessionManifest {
        let data = try Data(contentsOf: directory.appendingPathComponent(Self.filename))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SessionManifest.self, from: data)
    }

    public func save(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(self)
        try data.write(
            to: directory.appendingPathComponent(Self.filename),
            options: .atomic
        )
    }

    // MARK: - Codable with v1 migration

    private enum CodingKeys: String, CodingKey {
        case version, name, status, createdAt, micName, tracks
        // v1-only keys
        case sampleRate, channels, segments, systemAudio
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        name = try container.decode(String.self, forKey: .name)
        status = try container.decode(Status.self, forKey: .status)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        micName = try container.decodeIfPresent(String.self, forKey: .micName)

        if let tracks = try container.decodeIfPresent([Track].self, forKey: .tracks) {
            self.tracks = tracks
        } else {
            // Version 1: one pre-merged stream described at the top level.
            let rate = try container.decodeIfPresent(Double.self, forKey: .sampleRate) ?? 48_000
            let channels = try container.decodeIfPresent(Int.self, forKey: .channels) ?? 2
            let segments = try container.decodeIfPresent([String].self, forKey: .segments) ?? []
            self.tracks = [
                Track(
                    label: "merged",
                    sampleRate: rate,
                    channels: channels,
                    anchorHostTime: 0,
                    hostTicksPerSecond: CaptureTrack.hostTicksPerSecond(),
                    segments: segments
                )
            ]
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(version, forKey: .version)
        try container.encode(name, forKey: .name)
        try container.encode(status, forKey: .status)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encodeIfPresent(micName, forKey: .micName)
        try container.encode(tracks, forKey: .tracks)
    }
}
