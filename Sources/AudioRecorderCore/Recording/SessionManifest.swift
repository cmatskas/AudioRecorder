import Foundation

/// Sidecar metadata written next to a recording session's audio segments.
/// A manifest whose status is still `.recording` at app launch marks a
/// session that was interrupted by a crash and can be recovered.
public struct SessionManifest: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case recording
        case complete
        case discarded
    }

    public static let filename = "session.json"

    public var version: Int
    public var name: String
    public var status: Status
    public var sampleRate: Double
    public var channels: Int
    public var micName: String?
    public var systemAudio: Bool
    public var createdAt: Date
    /// Segment file names in recording order, relative to the session directory.
    public var segments: [String]

    public init(
        name: String,
        sampleRate: Double,
        channels: Int,
        micName: String?,
        systemAudio: Bool
    ) {
        self.version = 1
        self.name = name
        self.status = .recording
        self.sampleRate = sampleRate
        self.channels = channels
        self.micName = micName
        self.systemAudio = systemAudio
        self.createdAt = Date()
        self.segments = []
    }

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
}
