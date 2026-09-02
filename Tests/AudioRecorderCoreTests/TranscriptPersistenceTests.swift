import XCTest
@testable import AudioRecorderCore

final class TranscriptPersistenceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcript-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeUtterances() -> [Utterance] {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        return [
            Utterance(
                speaker: .them, text: "The migration won't finish by Q3.",
                timestamp: base, startOffset: 1.5, endOffset: 4.25
            ),
            Utterance(
                speaker: .me, text: "What's blocking it?",
                timestamp: base.addingTimeInterval(5), startOffset: 5, endOffset: 6.5
            ),
        ]
    }

    // MARK: - Append-only log

    func testLogWritesJSONLAndPrefixedText() throws {
        let log = try TranscriptLog(directory: directory)
        for utterance in makeUtterances() {
            try log.append(utterance)
        }
        log.close()

        let jsonl = try String(
            contentsOf: directory.appendingPathComponent(TranscriptLog.jsonlFileName),
            encoding: .utf8
        )
        let lines = jsonl.split(separator: "\n")
        XCTAssertEqual(lines.count, 2, "one JSON object per line")
        for line in lines {
            XCTAssertFalse(line.contains("\n"), "records must be single-line")
        }

        let text = try String(
            contentsOf: directory.appendingPathComponent(TranscriptLog.textFileName),
            encoding: .utf8
        )
        XCTAssertEqual(
            text,
            "Them: The migration won't finish by Q3.\nMe: What's blocking it?\n"
        )
    }

    func testLogRoundTripPreservesSpeakerAndOffsets() throws {
        let original = makeUtterances()
        let log = try TranscriptLog(directory: directory)
        for utterance in original { try log.append(utterance) }
        log.close()

        let read = try XCTUnwrap(TranscriptLog.readUtterances(in: directory))
        XCTAssertEqual(read, original)
        XCTAssertEqual(read.first?.startOffset, 1.5)
        XCTAssertEqual(read.first?.endOffset, 4.25)
        XCTAssertEqual(read.first?.speaker, .them)
    }

    /// The crash case: a process killed mid-write leaves a partial final line.
    /// Everything before it must still be readable, with no repair step.
    func testTornFinalLineIsSkippedAndEarlierRecordsSurvive() throws {
        let log = try TranscriptLog(directory: directory)
        for utterance in makeUtterances() { try log.append(utterance) }
        log.close()

        let url = directory.appendingPathComponent(TranscriptLog.jsonlFileName)
        var raw = try String(contentsOf: url, encoding: .utf8)
        raw += #"{"id":"E621E1F8-C36C-495A-93FC-0C247A3E6E5F","speaker":"me","te"#
        try raw.write(to: url, atomically: true, encoding: .utf8)

        let read = try XCTUnwrap(TranscriptLog.readUtterances(in: directory))
        XCTAssertEqual(read.count, 2, "torn line dropped, complete records kept")
        XCTAssertEqual(read.last?.text, "What's blocking it?")
    }

    func testAppendingReopensExistingLogWithoutTruncating() throws {
        let first = try TranscriptLog(directory: directory)
        try first.append(makeUtterances()[0])
        first.close()

        let second = try TranscriptLog(directory: directory)
        try second.append(makeUtterances()[1])
        second.close()

        XCTAssertEqual(TranscriptLog.readUtterances(in: directory)?.count, 2)
    }

    func testReadUtterancesReturnsNilWithoutLog() {
        XCTAssertNil(TranscriptLog.readUtterances(in: directory))
    }

    // MARK: - Reader preference

    func testReaderPrefersJSONLOverSnapshot() throws {
        // Snapshot with one utterance (as if written before a crash) …
        try InsightsPersistence.write(
            InsightsPersistence.TranscriptFile(utterances: [makeUtterances()[0]]),
            to: directory.appendingPathComponent(InsightsPersistence.transcriptFileName)
        )
        // … and a log containing both.
        let log = try TranscriptLog(directory: directory)
        for utterance in makeUtterances() { try log.append(utterance) }
        log.close()

        XCTAssertEqual(InsightsPersistence.readUtterances(in: directory).count, 2)
    }

    func testReaderFallsBackToSnapshotWhenNoLogExists() throws {
        try InsightsPersistence.write(
            InsightsPersistence.TranscriptFile(utterances: makeUtterances()),
            to: directory.appendingPathComponent(InsightsPersistence.transcriptFileName)
        )
        XCTAssertEqual(InsightsPersistence.readUtterances(in: directory).count, 2)
    }

    /// Transcripts written before offsets existed must still decode.
    func testLegacyTranscriptWithoutOffsetsDecodes() throws {
        let legacy = """
        {
          "version": 1,
          "utterances": [
            {
              "id": "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
              "speaker": "me",
              "text": "hello from an older build",
              "timestamp": "2026-01-01T10:00:00Z"
            }
          ]
        }
        """
        try legacy.write(
            to: directory.appendingPathComponent(InsightsPersistence.transcriptFileName),
            atomically: true, encoding: .utf8
        )
        let utterances = InsightsPersistence.readUtterances(in: directory)
        XCTAssertEqual(utterances.count, 1)
        XCTAssertNil(utterances.first?.startOffset)
        XCTAssertEqual(utterances.first?.text, "hello from an older build")
    }

    // MARK: - TranscriptRecorder

    func testRecorderWritesLiveLogAndUserFolderArtifacts() throws {
        let userRoot = directory.appendingPathComponent("user", isDirectory: true)
        let session = directory.appendingPathComponent("session", isDirectory: true)
        try FileManager.default.createDirectory(at: userRoot, withIntermediateDirectories: true)

        let recorder = TranscriptRecorder(
            sessionName: "recording_test", liveDirectory: session, exportRoots: [userRoot]
        )
        for utterance in makeUtterances() { recorder.append(utterance) }
        recorder.finish(
            utterances: makeUtterances(),
            summary: "They discussed the Q3 slip.",
            suggestions: [Suggestion(text: "Ask about the fallback plan")],
            updatedAt: Date()
        )

        // Live log plus snapshot in the session directory.
        XCTAssertEqual(TranscriptLog.readUtterances(in: session)?.count, 2)
        XCTAssertNotNil(InsightsPersistence.readTranscript(in: session))
        XCTAssertEqual(
            InsightsPersistence.readInsights(in: session)?.summary,
            "They discussed the Q3 slip."
        )

        // Session-named artifacts beside the recording in the user's folder.
        let text = try String(
            contentsOf: userRoot.appendingPathComponent("recording_test.transcript.txt"),
            encoding: .utf8
        )
        XCTAssertTrue(text.contains("Them: The migration won't finish by Q3."))
        XCTAssertTrue(text.contains("They discussed the Q3 slip."))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: userRoot.appendingPathComponent("recording_test.transcript.json").path
            )
        )
        XCTAssertTrue(recorder.warnings.isEmpty, "unexpected warnings: \(recorder.warnings)")
    }

    func testRecorderReportsWarningForUnwritableUserFolderButKeepsLiveLog() throws {
        let session = directory.appendingPathComponent("session", isDirectory: true)
        let recorder = TranscriptRecorder(
            sessionName: "recording_test",
            liveDirectory: session,
            exportRoots: [URL(fileURLWithPath: "/does/not/exist")]
        )
        recorder.append(makeUtterances()[0])
        recorder.finish(
            utterances: makeUtterances(), summary: "", suggestions: [], updatedAt: Date()
        )

        XCTAssertEqual(TranscriptLog.readUtterances(in: session)?.count, 1)
        XCTAssertFalse(recorder.warnings.isEmpty, "should warn about the unwritable folder")
    }

    func testRecorderWithoutDestinationsIsHarmless() {
        let recorder = TranscriptRecorder(
            sessionName: "x", liveDirectory: nil, exportRoots: []
        )
        recorder.append(makeUtterances()[0])
        recorder.finish(
            utterances: makeUtterances(), summary: "", suggestions: [], updatedAt: Date()
        )
        XCTAssertTrue(recorder.warnings.isEmpty)
    }
}
