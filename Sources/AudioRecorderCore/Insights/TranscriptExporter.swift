import Foundation

/// Renders a transcript into a shareable document. Pure formatting — no file
/// system, no UI — so every format and option combination is unit testable.
public enum TranscriptExporter {
    public enum Format: String, CaseIterable, Identifiable, Sendable {
        case plainText
        case markdown
        case csv
        case subRip
        case webVTT
        case json

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .plainText: return "Plain text"
            case .markdown: return "Markdown"
            case .csv: return "CSV"
            case .subRip: return "SubRip (.srt)"
            case .webVTT: return "WebVTT (.vtt)"
            case .json: return "JSON"
            }
        }

        public var fileExtension: String {
            switch self {
            case .plainText: return "txt"
            case .markdown: return "md"
            case .csv: return "csv"
            case .subRip: return "srt"
            case .webVTT: return "vtt"
            case .json: return "json"
            }
        }

        /// Subtitle formats carry timings inherently, so the timestamp toggle
        /// does not apply to them.
        public var honoursTimestampOption: Bool {
            switch self {
            case .plainText, .markdown, .csv, .json: return true
            case .subRip, .webVTT: return false
            }
        }

        /// Formats that can carry the summary and suggested follow-ups.
        public var supportsInsights: Bool {
            switch self {
            case .plainText, .markdown, .json: return true
            case .csv, .subRip, .webVTT: return false
            }
        }

        /// Subtitle formats need positional timings; without them the output
        /// would be meaningless.
        public var requiresOffsets: Bool {
            switch self {
            case .subRip, .webVTT: return true
            default: return false
            }
        }
    }

    public struct Options: Equatable, Sendable {
        public var includeSpeakers: Bool
        public var includeTimestamps: Bool
        public var includeSummary: Bool
        public var includeSuggestions: Bool

        public init(
            includeSpeakers: Bool = true,
            includeTimestamps: Bool = true,
            includeSummary: Bool = true,
            includeSuggestions: Bool = true
        ) {
            self.includeSpeakers = includeSpeakers
            self.includeTimestamps = includeTimestamps
            self.includeSummary = includeSummary
            self.includeSuggestions = includeSuggestions
        }
    }

    public struct Content: Sendable {
        public var title: String
        public var recordedAt: Date?
        public var utterances: [Utterance]
        public var summary: String
        public var suggestions: [Suggestion]

        public init(
            title: String,
            recordedAt: Date? = nil,
            utterances: [Utterance],
            summary: String = "",
            suggestions: [Suggestion] = []
        ) {
            self.title = title
            self.recordedAt = recordedAt
            self.utterances = utterances
            self.summary = summary
            self.suggestions = suggestions
        }
    }

    public static func export(
        _ content: Content,
        format: Format,
        options: Options
    ) -> String {
        switch format {
        case .plainText: return plainText(content, options)
        case .markdown: return markdown(content, options)
        case .csv: return csv(content, options)
        case .subRip: return subRip(content)
        case .webVTT: return webVTT(content)
        case .json: return json(content, options)
        }
    }

    /// Suggested file name, without a directory.
    public static func suggestedFileName(for title: String, format: Format) -> String {
        let safe = title.isEmpty ? "transcript" : title
        return "\(safe).\(format.fileExtension)"
    }

    // MARK: - Formats

    private static func plainText(_ content: Content, _ options: Options) -> String {
        var lines: [String] = []
        lines.append(content.title)
        if let recordedAt = content.recordedAt {
            lines.append(recordedAt.formatted(date: .long, time: .shortened))
        }
        lines.append("")

        if options.includeSummary, !content.summary.isEmpty {
            lines.append("SUMMARY")
            lines.append(content.summary)
            lines.append("")
        }
        if options.includeSuggestions, !content.suggestions.isEmpty {
            lines.append("SUGGESTED FOLLOW-UPS")
            lines.append(contentsOf: content.suggestions.map { "- \($0.text)" })
            lines.append("")
        }
        if options.includeSummary || options.includeSuggestions {
            lines.append("TRANSCRIPT")
        }
        for utterance in content.utterances {
            lines.append(line(for: utterance, options: options))
        }
        return lines.joined(separator: "\n").appending("\n")
    }

    private static func markdown(_ content: Content, _ options: Options) -> String {
        var lines: [String] = ["# \(content.title)"]
        if let recordedAt = content.recordedAt {
            lines.append("")
            lines.append("_\(recordedAt.formatted(date: .long, time: .shortened))_")
        }
        if options.includeSummary, !content.summary.isEmpty {
            lines.append("")
            lines.append("## Summary")
            lines.append("")
            lines.append(content.summary)
        }
        if options.includeSuggestions, !content.suggestions.isEmpty {
            lines.append("")
            lines.append("## Suggested follow-ups")
            lines.append("")
            lines.append(contentsOf: content.suggestions.map { "- \($0.text)" })
        }
        lines.append("")
        lines.append("## Transcript")
        lines.append("")
        for utterance in content.utterances {
            var parts: [String] = []
            if options.includeTimestamps, let stamp = timestampLabel(utterance) {
                parts.append("`\(stamp)`")
            }
            if options.includeSpeakers {
                parts.append("**\(utterance.speaker.displayName):**")
            }
            parts.append(utterance.text)
            lines.append(parts.joined(separator: " "))
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func csv(_ content: Content, _ options: Options) -> String {
        var header: [String] = []
        if options.includeTimestamps {
            header.append(contentsOf: ["start", "end"])
        }
        if options.includeSpeakers {
            header.append("speaker")
        }
        header.append("text")

        var rows = [header.joined(separator: ",")]
        for utterance in content.utterances {
            var fields: [String] = []
            if options.includeTimestamps {
                fields.append(utterance.startOffset.map { String(format: "%.3f", $0) } ?? "")
                fields.append(utterance.endOffset.map { String(format: "%.3f", $0) } ?? "")
            }
            if options.includeSpeakers {
                fields.append(utterance.speaker.displayName)
            }
            fields.append(utterance.text)
            rows.append(fields.map(escapeCSV).joined(separator: ","))
        }
        return rows.joined(separator: "\n").appending("\n")
    }

    private static func escapeCSV(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") else {
            return field
        }
        return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func subRip(_ content: Content) -> String {
        var blocks: [String] = []
        for (index, cue) in cues(content).enumerated() {
            blocks.append(
                """
                \(index + 1)
                \(subRipTime(cue.start)) --> \(subRipTime(cue.end))
                \(cue.text)
                """
            )
        }
        return blocks.joined(separator: "\n\n").appending("\n")
    }

    private static func webVTT(_ content: Content) -> String {
        var blocks: [String] = ["WEBVTT"]
        for cue in cues(content) {
            blocks.append(
                """
                \(webVTTTime(cue.start)) --> \(webVTTTime(cue.end))
                \(cue.text)
                """
            )
        }
        return blocks.joined(separator: "\n\n").appending("\n")
    }

    private static func json(_ content: Content, _ options: Options) -> String {
        struct Payload: Encodable {
            var title: String
            var recordedAt: Date?
            var summary: String?
            var suggestions: [String]?
            var utterances: [Entry]

            struct Entry: Encodable {
                var speaker: String?
                var start: TimeInterval?
                var end: TimeInterval?
                var timestamp: Date?
                var text: String
            }
        }

        let payload = Payload(
            title: content.title,
            recordedAt: content.recordedAt,
            summary: options.includeSummary && !content.summary.isEmpty ? content.summary : nil,
            suggestions: options.includeSuggestions && !content.suggestions.isEmpty
                ? content.suggestions.map(\.text) : nil,
            utterances: content.utterances.map { utterance in
                Payload.Entry(
                    speaker: options.includeSpeakers ? utterance.speaker.rawValue : nil,
                    start: options.includeTimestamps ? utterance.startOffset : nil,
                    end: options.includeTimestamps ? utterance.endOffset : nil,
                    timestamp: options.includeTimestamps ? utterance.timestamp : nil,
                    text: utterance.text
                )
            }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text.appending("\n")
    }

    // MARK: - Helpers

    private struct Cue {
        var start: TimeInterval
        var end: TimeInterval
        var text: String
    }

    /// Subtitle cues, using each utterance's offsets. Utterances without a
    /// start offset are skipped: a subtitle without a position is not useful.
    private static func cues(_ content: Content) -> [Cue] {
        let withOffsets = content.utterances.filter { $0.startOffset != nil }
        return withOffsets.enumerated().compactMap { index, utterance in
            guard let start = utterance.startOffset else { return nil }
            // Fall back to the next cue's start, then a two-second default.
            let nextStart = index + 1 < withOffsets.count
                ? withOffsets[index + 1].startOffset : nil
            let end = utterance.endOffset ?? nextStart ?? (start + 2)
            return Cue(
                start: start,
                end: max(end, start + 0.5),
                text: "\(utterance.speaker.displayName): \(utterance.text)"
            )
        }
    }

    private static func line(for utterance: Utterance, options: Options) -> String {
        var parts: [String] = []
        if options.includeTimestamps, let stamp = timestampLabel(utterance) {
            parts.append("[\(stamp)]")
        }
        if options.includeSpeakers {
            parts.append("\(utterance.speaker.displayName):")
        }
        parts.append(utterance.text)
        return parts.joined(separator: " ")
    }

    /// Prefers the audio-relative offset; falls back to wall-clock time of day
    /// for transcripts recorded before offsets were captured.
    private static func timestampLabel(_ utterance: Utterance) -> String? {
        if let start = utterance.startOffset {
            return clockTime(start)
        }
        return utterance.timestamp.formatted(date: .omitted, time: .standard)
    }

    static func clockTime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    static func subRipTime(_ seconds: TimeInterval) -> String {
        let milliseconds = Int(((seconds - seconds.rounded(.down)) * 1000).rounded())
        return "\(clockTime(seconds)),\(String(format: "%03d", milliseconds))"
    }

    static func webVTTTime(_ seconds: TimeInterval) -> String {
        let milliseconds = Int(((seconds - seconds.rounded(.down)) * 1000).rounded())
        return "\(clockTime(seconds)).\(String(format: "%03d", milliseconds))"
    }
}
