import Synchronization
import XCTest
@testable import AudioRecorderCore

final class InsightsTests: XCTestCase {
    // MARK: - TranscriptStore

    func testTranscriptStoreKeepsUtterancesSortedByTimestamp() {
        let store = TranscriptStore()
        let base = Date(timeIntervalSince1970: 1_000_000)
        // "Them" finalizes late relative to "Me": arrival order != time order.
        store.append(Utterance(speaker: .me, text: "second", timestamp: base.addingTimeInterval(10)))
        store.append(Utterance(speaker: .them, text: "first", timestamp: base))
        store.append(Utterance(speaker: .me, text: "third", timestamp: base.addingTimeInterval(20)))

        XCTAssertEqual(store.all.map(\.text), ["first", "second", "third"])
    }

    func testTranscriptWindowReturnsOnlyRecentUtterances() {
        let store = TranscriptStore()
        let now = Date()
        store.append(Utterance(speaker: .me, text: "old", timestamp: now.addingTimeInterval(-600)))
        store.append(Utterance(speaker: .them, text: "recent", timestamp: now.addingTimeInterval(-60)))
        store.append(Utterance(speaker: .me, text: "new", timestamp: now.addingTimeInterval(-5)))

        let window = store.window(minutes: 4, now: now)
        XCTAssertEqual(window.map(\.text), ["recent", "new"])
    }

    func testTranscriptWindowEmptyWhenEverythingIsOld() {
        let store = TranscriptStore()
        let now = Date()
        store.append(Utterance(speaker: .me, text: "old", timestamp: now.addingTimeInterval(-3600)))
        XCTAssertTrue(store.window(minutes: 1, now: now).isEmpty)
    }

    func testDialogueRendering() {
        let base = Date()
        let utterances = [
            Utterance(speaker: .me, text: "What's blocking it?", timestamp: base),
            Utterance(speaker: .them, text: "Mostly the auth part.", timestamp: base),
        ]
        XCTAssertEqual(
            TranscriptStore.dialogue(utterances),
            "Me: What's blocking it?\nThem: Mostly the auth part."
        )
    }

    // MARK: - AsyncDebouncer

    @MainActor
    func testDebouncerCoalescesBurstIntoSingleInvocation() async throws {
        var runs = 0
        let debouncer = AsyncDebouncer(interval: .milliseconds(80)) { runs += 1 }
        for _ in 0..<5 {
            debouncer.trigger()
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(runs, 1)

        debouncer.trigger()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(runs, 2)
    }

    @MainActor
    func testDebouncerCancelPreventsInvocation() async throws {
        var runs = 0
        let debouncer = AsyncDebouncer(interval: .milliseconds(50)) { runs += 1 }
        debouncer.trigger()
        debouncer.cancel()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(runs, 0)
    }

    // MARK: - Prompt parsing / assembly

    func testParseSuggestionsFromCleanJSON() {
        let response = #"["Ask about the timeline", "Probe the auth risk"]"#
        XCTAssertEqual(
            InsightPrompts.parseSuggestions(from: response),
            ["Ask about the timeline", "Probe the auth risk"]
        )
    }

    func testParseSuggestionsToleratesFencesAndProse() {
        let response = """
        Here are my suggestions:
        ```json
        ["One?", "Two?"]
        ```
        """
        XCTAssertEqual(InsightPrompts.parseSuggestions(from: response), ["One?", "Two?"])
    }

    func testParseSuggestionsDropsEmptyEntriesAndHandlesGarbage() {
        XCTAssertEqual(InsightPrompts.parseSuggestions(from: #"["ok", "  "]"#), ["ok"])
        XCTAssertEqual(InsightPrompts.parseSuggestions(from: "no json here"), [])
        XCTAssertEqual(InsightPrompts.parseSuggestions(from: ""), [])
    }

    func testFastPromptIncludesSummaryAndDialogue() {
        let prompt = InsightPrompts.fastUser(
            runningSummary: "They discussed the Q3 slip.",
            recentDialogue: "Me: why?\nThem: auth."
        )
        XCTAssertTrue(prompt.contains("They discussed the Q3 slip."))
        XCTAssertTrue(prompt.contains("Them: auth."))
    }

    func testFastPromptOmitsEmptySummaryBlock() {
        let prompt = InsightPrompts.fastUser(runningSummary: "", recentDialogue: "Me: hi")
        XCTAssertFalse(prompt.contains("Context so far"))
    }

    // MARK: - InsightEngine with a mock LLM

    private struct MockLLM: LLMClient {
        let handler: @Sendable (String, String, String) async throws -> String
        func complete(modelID: String, system: String, user: String) async throws -> String {
            try await handler(modelID, system, user)
        }
    }

    @MainActor
    func testEngineFastLaneProducesSuggestionsAfterDebounce() async throws {
        let model = InsightsModel()
        let llm = MockLLM { modelID, _, _ in
            // finish() legitimately runs a final deep pass; only the fast
            // lane should produce suggestions JSON.
            modelID == "fast-model" ? #"["Ask about the fallback plan"]"# : "final summary"
        }
        let engine = InsightEngine(
            transcript: TranscriptStore(),
            model: model,
            llm: llm,
            fastModelID: "fast-model",
            deepModelID: "deep-model",
            tuning: .init(fastDebounce: .milliseconds(40), deepInterval: .seconds(600)),
            sessionDirectory: nil
        )
        engine.start()
        engine.noteUtterance(Utterance(speaker: .them, text: "won't finish by Q3", timestamp: Date()))
        engine.noteUtterance(Utterance(speaker: .me, text: "what's blocking?", timestamp: Date()))

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(model.suggestions.map(\.text), ["Ask about the fallback plan"])
        XCTAssertEqual(model.utterances.count, 2)
        await engine.finish()
    }

    @MainActor
    func testEngineFinishRunsFinalDeepPass() async throws {
        let model = InsightsModel()
        let llm = MockLLM { modelID, _, _ in
            modelID == "deep-model" ? "Summary: they discussed Q3." : "[]"
        }
        let engine = InsightEngine(
            transcript: TranscriptStore(),
            model: model,
            llm: llm,
            fastModelID: "fast-model",
            deepModelID: "deep-model",
            tuning: .init(fastDebounce: .seconds(600), deepInterval: .seconds(600)),
            sessionDirectory: nil
        )
        engine.start()
        engine.noteUtterance(Utterance(speaker: .them, text: "Q3 will slip", timestamp: Date()))
        await engine.finish()

        XCTAssertEqual(model.summary, "Summary: they discussed Q3.")
        XCTAssertNotNil(model.summaryUpdatedAt)
    }

    @MainActor
    func testEngineDegradesAfterRepeatedFailuresAndRecovers() async throws {
        struct Boom: Error {}
        let failing = Mutex(true)
        let llm = MockLLM { _, _, _ in
            if failing.withLock({ $0 }) { throw Boom() }
            return #"["ok"]"#
        }
        let model = InsightsModel()
        model.status = .live
        let engine = InsightEngine(
            transcript: TranscriptStore(),
            model: model,
            llm: llm,
            fastModelID: "f",
            deepModelID: "d",
            tuning: .init(fastDebounce: .milliseconds(20), deepInterval: .seconds(600)),
            sessionDirectory: nil
        )
        engine.start()
        for index in 0..<3 {
            engine.noteUtterance(Utterance(speaker: .me, text: "u\(index)", timestamp: Date()))
            try await Task.sleep(for: .milliseconds(200))
        }
        guard case .degraded = model.status else {
            return XCTFail("expected degraded status, got \(model.status)")
        }

        failing.withLock { $0 = false }
        engine.noteUtterance(Utterance(speaker: .me, text: "again", timestamp: Date()))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.status, .live)
        await engine.finish()
    }

    // MARK: - Persistence round trip

    func testTranscriptAndInsightsFilesRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("insights-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let transcript = InsightsPersistence.TranscriptFile(
            utterances: [Utterance(speaker: .me, text: "hello", timestamp: Date())]
        )
        try InsightsPersistence.write(
            transcript,
            to: directory.appendingPathComponent(InsightsPersistence.transcriptFileName)
        )
        let insights = InsightsPersistence.InsightsFile(
            summary: "s",
            suggestions: [Suggestion(text: "q?")],
            updatedAt: Date()
        )
        try InsightsPersistence.write(
            insights,
            to: directory.appendingPathComponent(InsightsPersistence.insightsFileName)
        )

        let readTranscript = InsightsPersistence.readTranscript(in: directory)
        XCTAssertEqual(readTranscript?.utterances.first?.text, "hello")
        let readInsights = InsightsPersistence.readInsights(in: directory)
        XCTAssertEqual(readInsights?.summary, "s")
        XCTAssertEqual(readInsights?.suggestions.map(\.text), ["q?"])
    }

    // MARK: - AWS profile parsing

    func testStaticCredentialsParseUppercaseKeysLikeTheCLI() throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".aws"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: home) }
        // The style Isengard/console credential snippets produce.
        try """
        [default]
        AWS_ACCESS_KEY_ID = AKIAEXAMPLE
        AWS_SECRET_ACCESS_KEY = secret123
        AWS_SESSION_TOKEN = token456

        [lowercase]
        aws_access_key_id = AKIAOTHER
        aws_secret_access_key = other

        [sso-style]
        sso_start_url = https://example.awsapps.com/start
        """.write(
            to: home.appendingPathComponent(".aws/credentials"),
            atomically: true, encoding: .utf8
        )

        let upper = try XCTUnwrap(
            AWSProfileDiscovery.staticCredentials(forProfile: "default", home: home)
        )
        XCTAssertEqual(upper.accessKeyID, "AKIAEXAMPLE")
        XCTAssertEqual(upper.secretAccessKey, "secret123")
        XCTAssertEqual(upper.sessionToken, "token456")

        let lower = try XCTUnwrap(
            AWSProfileDiscovery.staticCredentials(forProfile: "lowercase", home: home)
        )
        XCTAssertEqual(lower.accessKeyID, "AKIAOTHER")
        XCTAssertNil(lower.sessionToken)

        // No inline keys → must return nil so the SDK chain handles it.
        XCTAssertNil(AWSProfileDiscovery.staticCredentials(forProfile: "sso-style", home: home))
        XCTAssertNil(AWSProfileDiscovery.staticCredentials(forProfile: "missing", home: home))
    }

    // MARK: - HistoryScanner

    func testHistoryScannerFindsCompleteSessionsNewestFirst() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // Complete session with audio + transcript.
        let older = try makeSession(named: "recording_a", in: root, status: .complete)
        FileManager.default.createFile(
            atPath: older.appendingPathComponent("recording_a.m4a").path, contents: Data()
        )
        try InsightsPersistence.write(
            InsightsPersistence.TranscriptFile(utterances: []),
            to: older.appendingPathComponent(InsightsPersistence.transcriptFileName)
        )
        // Newer complete session without audio or insights.
        let newer = try makeSession(
            named: "recording_b", in: root, status: .complete, ageOffset: 100
        )
        _ = newer
        // Interrupted session: recovery's business, not history's.
        _ = try makeSession(named: "recording_c", in: root, status: .recording, ageOffset: 200)
        // Stray non-session directory.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("not-a-session"), withIntermediateDirectories: true
        )

        let items = HistoryScanner.scan(root: root)
        XCTAssertEqual(items.map(\.name), ["recording_b", "recording_a"])

        let itemA = try XCTUnwrap(items.first { $0.name == "recording_a" })
        XCTAssertNotNil(itemA.audioURL)
        XCTAssertTrue(itemA.hasTranscript)
        XCTAssertFalse(itemA.hasInsights)

        let itemB = try XCTUnwrap(items.first { $0.name == "recording_b" })
        XCTAssertNil(itemB.audioURL)
        XCTAssertFalse(itemB.hasTranscript)
    }

    @discardableResult
    private func makeSession(
        named name: String,
        in root: URL,
        status: SessionManifest.Status,
        ageOffset: TimeInterval = 0
    ) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var manifest = SessionManifest(
            name: name,
            micName: "Test Mic",
            tracks: [
                .init(label: "mic", sampleRate: 48_000, channels: 2, hostTicksPerSecond: 1e9)
            ]
        )
        manifest.status = status
        manifest.createdAt = Date(timeIntervalSince1970: 1_000_000 + ageOffset)
        try manifest.save(to: directory)
        return directory
    }
}
