import XCTest
@testable import AudioRecorderCore

final class TranscriptExporterTests: XCTestCase {
    private let recordedAt = Date(timeIntervalSince1970: 1_700_000_000)

    private var content: TranscriptExporter.Content {
        TranscriptExporter.Content(
            title: "recording_2026-09-01",
            recordedAt: recordedAt,
            utterances: [
                Utterance(
                    speaker: .them, text: "The migration won't finish by Q3.",
                    timestamp: recordedAt, startOffset: 65.5, endOffset: 68.25
                ),
                Utterance(
                    speaker: .me, text: "What's blocking it?",
                    timestamp: recordedAt.addingTimeInterval(5),
                    startOffset: 70, endOffset: 71.5
                ),
            ],
            summary: "Timeline slip discussed.",
            suggestions: [Suggestion(text: "Ask which auth flows are affected")]
        )
    }

    private func export(
        _ format: TranscriptExporter.Format,
        _ options: TranscriptExporter.Options = .init()
    ) -> String {
        TranscriptExporter.export(content, format: format, options: options)
    }

    // MARK: - Speaker / timestamp toggles

    func testPlainTextIncludesSpeakersAndTimestamps() {
        let output = export(.plainText)
        XCTAssertTrue(output.contains("[00:01:05] Them: The migration won't finish by Q3."), output)
        XCTAssertTrue(output.contains("[00:01:10] Me: What's blocking it?"), output)
    }

    func testPlainTextCanStripSpeakers() {
        let output = export(.plainText, .init(includeSpeakers: false))
        XCTAssertFalse(output.contains("Them:"))
        XCTAssertFalse(output.contains("Me:"))
        XCTAssertTrue(output.contains("[00:01:05] The migration won't finish by Q3."), output)
    }

    func testPlainTextCanStripTimestamps() {
        let output = export(.plainText, .init(includeTimestamps: false))
        XCTAssertFalse(output.contains("[00:01:05]"))
        XCTAssertTrue(output.contains("Them: The migration won't finish by Q3."), output)
    }

    func testPlainTextCanStripBoth() {
        let output = export(
            .plainText, .init(includeSpeakers: false, includeTimestamps: false)
        )
        XCTAssertTrue(output.contains("The migration won't finish by Q3.\nWhat's blocking it?"), output)
    }

    // MARK: - Summary / follow-up toggles

    func testInsightsIncludedWhenRequested() {
        let output = export(.plainText)
        XCTAssertTrue(output.contains("SUMMARY"))
        XCTAssertTrue(output.contains("Timeline slip discussed."))
        XCTAssertTrue(output.contains("SUGGESTED FOLLOW-UPS"))
        XCTAssertTrue(output.contains("Ask which auth flows are affected"))
    }

    func testInsightsExcludedWhenNotRequested() {
        let output = export(
            .plainText, .init(includeSummary: false, includeSuggestions: false)
        )
        XCTAssertFalse(output.contains("SUMMARY"))
        XCTAssertFalse(output.contains("Timeline slip discussed."))
        XCTAssertFalse(output.contains("Ask which auth flows"))
        XCTAssertTrue(output.contains("Them: The migration won't finish by Q3."))
    }

    func testSummaryAndSuggestionsToggleIndependently() {
        let summaryOnly = export(.markdown, .init(includeSuggestions: false))
        XCTAssertTrue(summaryOnly.contains("## Summary"))
        XCTAssertFalse(summaryOnly.contains("## Suggested follow-ups"))

        let suggestionsOnly = export(.markdown, .init(includeSummary: false))
        XCTAssertFalse(suggestionsOnly.contains("## Summary"))
        XCTAssertTrue(suggestionsOnly.contains("## Suggested follow-ups"))
    }

    // MARK: - Markdown

    func testMarkdownStructure() {
        let output = export(.markdown)
        XCTAssertTrue(output.hasPrefix("# recording_2026-09-01"))
        XCTAssertTrue(output.contains("## Transcript"))
        XCTAssertTrue(output.contains("`00:01:05` **Them:** The migration won't finish by Q3."), output)
    }

    // MARK: - CSV

    func testCSVHeaderFollowsOptionsAndEscapesFields() {
        let output = export(.csv)
        let lines = output.split(separator: "\n")
        XCTAssertEqual(lines.first, "start,end,speaker,text")
        // Text containing a comma must be quoted.
        XCTAssertTrue(lines[1].contains("65.500,68.250,Them,"), String(lines[1]))

        let stripped = export(.csv, .init(includeSpeakers: false, includeTimestamps: false))
        XCTAssertEqual(stripped.split(separator: "\n").first, "text")
    }

    func testCSVQuotesEmbeddedCommasAndQuotes() {
        let tricky = TranscriptExporter.Content(
            title: "t",
            utterances: [
                Utterance(
                    speaker: .me, text: #"He said "yes", then left"#,
                    timestamp: recordedAt, startOffset: 1, endOffset: 2
                )
            ]
        )
        let output = TranscriptExporter.export(tricky, format: .csv, options: .init())
        XCTAssertTrue(output.contains(#""He said ""yes"", then left""#), output)
    }

    // MARK: - Subtitles

    func testSubRipFormatting() {
        let output = export(.subRip)
        XCTAssertTrue(output.hasPrefix("1\n00:01:05,500 --> 00:01:08,250\nThem:"), output)
        XCTAssertTrue(output.contains("2\n00:01:10,000 --> 00:01:11,500\nMe:"), output)
    }

    func testWebVTTFormatting() {
        let output = export(.webVTT)
        XCTAssertTrue(output.hasPrefix("WEBVTT\n\n"))
        XCTAssertTrue(output.contains("00:01:05.500 --> 00:01:08.250"), output)
    }

    /// Subtitles need positions; utterances without offsets are skipped rather
    /// than emitted at a fabricated time.
    func testSubtitlesSkipUtterancesWithoutOffsets() {
        let noOffsets = TranscriptExporter.Content(
            title: "t",
            utterances: [
                Utterance(speaker: .me, text: "no timing", timestamp: recordedAt)
            ]
        )
        let output = TranscriptExporter.export(noOffsets, format: .subRip, options: .init())
        XCTAssertEqual(output.trimmingCharacters(in: .whitespacesAndNewlines), "")
    }

    func testMissingEndOffsetFallsBackToNextCueStart() {
        let content = TranscriptExporter.Content(
            title: "t",
            utterances: [
                Utterance(
                    speaker: .me, text: "first", timestamp: recordedAt,
                    startOffset: 10, endOffset: nil
                ),
                Utterance(
                    speaker: .them, text: "second", timestamp: recordedAt,
                    startOffset: 14, endOffset: 15
                ),
            ]
        )
        let output = TranscriptExporter.export(content, format: .subRip, options: .init())
        XCTAssertTrue(output.contains("00:00:10,000 --> 00:00:14,000"), output)
    }

    // MARK: - JSON

    func testJSONHonoursOptions() throws {
        let full = export(.json)
        XCTAssertTrue(full.contains("\"speaker\" : \"them\""), full)
        XCTAssertTrue(full.contains("\"summary\""))

        let stripped = export(
            .json,
            .init(
                includeSpeakers: false, includeTimestamps: false,
                includeSummary: false, includeSuggestions: false
            )
        )
        XCTAssertFalse(stripped.contains("\"speaker\""))
        XCTAssertFalse(stripped.contains("\"start\""))
        XCTAssertFalse(stripped.contains("\"summary\""))
        XCTAssertTrue(stripped.contains("\"text\""))
    }

    // MARK: - Format metadata and helpers

    func testFormatCapabilities() {
        XCTAssertFalse(TranscriptExporter.Format.subRip.honoursTimestampOption)
        XCTAssertTrue(TranscriptExporter.Format.subRip.requiresOffsets)
        XCTAssertFalse(TranscriptExporter.Format.csv.supportsInsights)
        XCTAssertTrue(TranscriptExporter.Format.markdown.supportsInsights)
    }

    func testSuggestedFileNames() {
        XCTAssertEqual(
            TranscriptExporter.suggestedFileName(for: "meeting", format: .markdown),
            "meeting.md"
        )
        XCTAssertEqual(
            TranscriptExporter.suggestedFileName(for: "", format: .subRip),
            "transcript.srt"
        )
    }

    func testTimeFormattingHelpers() {
        XCTAssertEqual(TranscriptExporter.clockTime(3725), "01:02:05")
        XCTAssertEqual(TranscriptExporter.subRipTime(65.5), "00:01:05,500")
        XCTAssertEqual(TranscriptExporter.webVTTTime(65.5), "00:01:05.500")
    }

    func testEmptyTranscriptProducesNoCrash() {
        let empty = TranscriptExporter.Content(title: "empty", utterances: [])
        for format in TranscriptExporter.Format.allCases {
            let output = TranscriptExporter.export(empty, format: format, options: .init())
            XCTAssertNotNil(output)
        }
    }

    /// Old transcripts have no offsets; plain text should still carry a
    /// timestamp, falling back to wall-clock time of day.
    func testTimestampFallsBackToWallClockWithoutOffsets() {
        let legacy = TranscriptExporter.Content(
            title: "t",
            utterances: [
                Utterance(speaker: .me, text: "hello", timestamp: recordedAt)
            ]
        )
        let output = TranscriptExporter.export(legacy, format: .plainText, options: .init())
        XCTAssertTrue(output.contains("Me: hello"))
        XCTAssertTrue(output.contains("["), "expected a timestamp prefix: \(output)")
    }
}
