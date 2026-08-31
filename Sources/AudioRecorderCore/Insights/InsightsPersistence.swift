import Foundation

/// On-disk artifacts written into a session directory next to the audio
/// masters. Written by the insights pipeline, read back by the History view —
/// which is why the formats live in Core rather than the AWS target.
public enum InsightsPersistence {
    public static let transcriptFileName = "transcript.json"
    public static let insightsFileName = "insights.json"

    public struct TranscriptFile: Codable, Equatable, Sendable {
        public var version: Int
        public var utterances: [Utterance]

        public init(version: Int = 1, utterances: [Utterance]) {
            self.version = version
            self.utterances = utterances
        }
    }

    public struct InsightsFile: Codable, Equatable, Sendable {
        public var version: Int
        public var summary: String
        public var suggestions: [Suggestion]
        public var updatedAt: Date

        public init(
            version: Int = 1,
            summary: String,
            suggestions: [Suggestion],
            updatedAt: Date
        ) {
            self.version = version
            self.summary = summary
            self.suggestions = suggestions
            self.updatedAt = updatedAt
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Atomic write so a crash mid-write cannot corrupt an existing file —
    /// the same posture the audio path takes.
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder().encode(value)
        try data.write(to: url, options: .atomic)
    }

    public static func readTranscript(in directory: URL) -> TranscriptFile? {
        read(directory.appendingPathComponent(transcriptFileName))
    }

    public static func readInsights(in directory: URL) -> InsightsFile? {
        read(directory.appendingPathComponent(insightsFileName))
    }

    private static func read<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder().decode(T.self, from: data)
    }
}
