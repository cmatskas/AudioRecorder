import XCTest
@testable import AudioRecorderCore

final class RecordingNamerTests: XCTestCase {
    // MARK: - Doubles

    private struct StubTranscriber: NamingTranscriber {
        let handler: @Sendable (URL, TimeInterval) async throws -> String

        func transcribe(audioURL: URL, maxDuration: TimeInterval) async throws -> String {
            try await handler(audioURL, maxDuration)
        }
    }

    private struct MockLLM: LLMClient {
        let handler: @Sendable (String, String, String) async throws -> String

        func complete(modelID: String, system: String, user: String) async throws -> String {
            try await handler(modelID, system, user)
        }
    }

    private struct Boom: Error {}

    private final class Counter: @unchecked Sendable {
        private var value = 0
        private let lock = NSLock()

        func increment() {
            lock.lock()
            value += 1
            lock.unlock()
        }

        var count: Int {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private static let audioURL = URL(fileURLWithPath: "/tmp/does-not-need-to-exist.m4a")

    private static let dialogue = """
    Me: where did we land on pricing for the new tier?
    Them: pricing is close, but the budget for onboarding is the open question.
    Me: so pricing is agreed and budget is outstanding?
    """

    private var audioURL: URL { Self.audioURL }
    private var dialogue: String { Self.dialogue }

    // MARK: - Source of text

    /// A Live Insights transcript is already on disk and already paid for, so it
    /// must be preferred over transcribing the file again.
    func testLiveTranscriptSkipsTranscription() async {
        let calls = Counter()
        let namer = RecordingNamer(
            transcriber: StubTranscriber { _, _ in
                calls.increment()
                return "should not be used"
            },
            llm: MockLLM { _, _, _ in "Pricing Call" },
            titleModelID: "fast"
        )
        let name = await namer.proposeName(
            .init(audioURL: audioURL, liveTranscript: dialogue, summary: "")
        )

        XCTAssertEqual(name, "Pricing Call")
        XCTAssertEqual(calls.count, 0)
    }

    func testTranscribesWhenThereIsNoLiveTranscript() async {
        let namer = RecordingNamer(
            transcriber: StubTranscriber { _, window in
                XCTAssertEqual(window, 90)
                return Self.dialogue
            },
            llm: MockLLM { _, _, _ in "Vendor Demo" },
            titleModelID: "fast",
            maxTranscriptionDuration: 90
        )
        let name = await namer.proposeName(.init(audioURL: audioURL))
        XCTAssertEqual(name, "Vendor Demo")
    }

    func testNoTranscriberAndNoTranscriptYieldsNoName() async {
        let namer = RecordingNamer(llm: MockLLM { _, _, _ in "Nope" }, titleModelID: "deep")
        let name = await namer.proposeName(.init(audioURL: audioURL))
        XCTAssertNil(name)
    }

    /// A closing briefing describes the conversation well enough to name it, so a
    /// summary with no transcript is still worth a name rather than a timestamp.
    func testSummaryAloneCanNameTheRecording() async {
        let namer = RecordingNamer(
            llm: MockLLM { _, _, user in
                XCTAssertTrue(user.contains("childhood labels"))
                // The summary is the only text, so it must not be sent twice.
                XCTAssertFalse(user.contains("Summary of the conversation"))
                return "Broken Brain"
            },
            titleModelID: "deep"
        )
        let name = await namer.proposeName(
            .init(
                audioURL: nil,
                liveTranscript: "",
                summary: "A story about childhood labels and a boy called the boy with the broken brain."
            )
        )
        XCTAssertEqual(name, "Broken Brain")
    }

    /// The transcript is richer than the summary, so it wins when both exist —
    /// and then the summary is worth sending as context.
    func testTranscriptWinsOverSummaryWhenBothExist() async {
        let namer = RecordingNamer(
            llm: MockLLM { _, _, user in
                XCTAssertTrue(user.contains("Summary of the conversation"))
                XCTAssertTrue(user.contains("where did we land on pricing"))
                return "Pricing Plan"
            },
            titleModelID: "deep"
        )
        let name = await namer.proposeName(
            .init(audioURL: audioURL, liveTranscript: dialogue, summary: "They agreed on pricing.")
        )
        XCTAssertEqual(name, "Pricing Plan")
    }

    /// A failing transcriber must not throw away a usable summary.
    func testSummaryIsUsedWhenTranscriptionFails() async {
        let namer = RecordingNamer(
            transcriber: StubTranscriber { _, _ in throw Boom() },
            llm: MockLLM { _, _, _ in "Broken Brain" },
            titleModelID: "deep"
        )
        let name = await namer.proposeName(
            .init(audioURL: audioURL, liveTranscript: "", summary: "A story about broken brains.")
        )
        XCTAssertEqual(name, "Broken Brain")
    }

    func testFailingTranscriberYieldsNoName() async {
        let namer = RecordingNamer(
            transcriber: StubTranscriber { _, _ in throw Boom() },
            llm: MockLLM { _, _, _ in "Unused" },
            titleModelID: "fast"
        )
        let name = await namer.proposeName(.init(audioURL: audioURL))
        XCTAssertNil(name)
    }

    /// Silence at the start of a recording is not a failure, but it is not a name
    /// either.
    func testEmptyTranscriptYieldsNoName() async {
        let namer = RecordingNamer(
            transcriber: StubTranscriber { _, _ in "   " },
            llm: MockLLM { _, _, _ in "Unused" },
            titleModelID: "fast"
        )
        let name = await namer.proposeName(.init(audioURL: audioURL))
        XCTAssertNil(name)
    }

    // MARK: - Title

    func testModelResponseIsShortenedWhenNeeded() async {
        let namer = RecordingNamer(
            llm: MockLLM { _, _, _ in "\"Quarterly Budget Review\"" },
            titleModelID: "deep"
        )
        let name = await namer.proposeName(
            .init(audioURL: audioURL, liveTranscript: dialogue)
        )
        XCTAssertNotNil(name)
        XCTAssertLessThanOrEqual(name?.count ?? 99, RecordingTitler.maxLength)
    }

    /// The regression that prompted this: `nova-lite` answered "Impact of
    /// Childhood Labels" and the name became "Impact of". A too-long answer now
    /// earns one retry, and the retry's answer is used.
    func testOverLongAnswerIsRetriedOnce() async {
        let calls = Counter()
        let namer = RecordingNamer(
            llm: MockLLM { _, _, user in
                calls.increment()
                if user.contains("was 26 characters") {
                    XCTAssertTrue(user.contains("\"Impact of Childhood Labels\""))
                    return "Broken Brain"
                }
                return "Impact of Childhood Labels"
            },
            titleModelID: "deep"
        )
        let name = await namer.proposeName(
            .init(audioURL: audioURL, liveTranscript: dialogue)
        )
        XCTAssertEqual(name, "Broken Brain")
        XCTAssertEqual(calls.count, 2)
    }

    /// A short answer must not spend a second call.
    func testAnswerWithinBudgetIsUsedWithoutRetry() async {
        let calls = Counter()
        let namer = RecordingNamer(
            llm: MockLLM { _, _, _ in
                calls.increment()
                return "Broken Brain"
            },
            titleModelID: "deep"
        )
        let name = await namer.proposeName(
            .init(audioURL: audioURL, liveTranscript: dialogue)
        )
        XCTAssertEqual(name, "Broken Brain")
        XCTAssertEqual(calls.count, 1)
    }

    /// Both attempts overshooting is the `nova-lite` case: shorten by dropping
    /// words rather than giving up or emitting a fragment.
    func testBothAttemptsOverLongFallsBackToShortening() async {
        let namer = RecordingNamer(
            llm: MockLLM { _, _, user in
                user.contains("too long") ? "Jim's Broken Brain" : "Impact of Childhood Labels"
            },
            titleModelID: "deep"
        )
        let name = await namer.proposeName(
            .init(audioURL: audioURL, liveTranscript: dialogue)
        )
        XCTAssertEqual(name, "Broken Brain")
    }

    func testSummaryIsIncludedInThePrompt() async {
        let namer = RecordingNamer(
            llm: MockLLM { _, _, user in
                XCTAssertTrue(user.contains("They agreed on pricing"))
                return "Pricing"
            },
            titleModelID: "fast"
        )
        let name = await namer.proposeName(
            .init(
                audioURL: audioURL,
                liveTranscript: dialogue,
                summary: "They agreed on pricing."
            )
        )
        XCTAssertEqual(name, "Pricing")
    }

    /// An unreachable or unconfigured model must not cost the user their name.
    func testFailingModelFallsBackToHeuristic() async {
        let namer = RecordingNamer(
            llm: MockLLM { _, _, _ in throw Boom() },
            titleModelID: "fast"
        )
        let name = await namer.proposeName(
            .init(audioURL: audioURL, liveTranscript: dialogue)
        )
        XCTAssertEqual(name, RecordingTitler.heuristicTitle(from: dialogue))
        XCTAssertNotNil(name)
    }

    func testNoModelConfiguredUsesHeuristic() async {
        let namer = RecordingNamer()
        let name = await namer.proposeName(
            .init(audioURL: audioURL, liveTranscript: dialogue)
        )
        XCTAssertEqual(name, RecordingTitler.heuristicTitle(from: dialogue))
    }

    func testUnusableModelResponseFallsBackToHeuristic() async {
        let namer = RecordingNamer(llm: MockLLM { _, _, _ in "!!!" }, titleModelID: "fast")
        let name = await namer.proposeName(
            .init(audioURL: audioURL, liveTranscript: dialogue)
        )
        XCTAssertEqual(name, RecordingTitler.heuristicTitle(from: dialogue))
    }

    // MARK: - Budget and cancellation

    /// A wedged backend must not leave the UI saying "Naming…" forever.
    func testBudgetAbandonsASlowBackend() async {
        let namer = RecordingNamer(
            transcriber: StubTranscriber { _, _ in
                try await Task.sleep(for: .seconds(30))
                return "too late"
            },
            llm: MockLLM { _, _, _ in "Unused" },
            titleModelID: "fast",
            budget: .milliseconds(150)
        )
        let start = ContinuousClock.now
        let name = await namer.proposeName(.init(audioURL: audioURL))
        XCTAssertNil(name)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(5))
    }

    /// Starting another recording cancels naming; it must return promptly.
    func testCancellationEndsNamingPromptly() async {
        let namer = RecordingNamer(
            transcriber: StubTranscriber { _, _ in
                try await Task.sleep(for: .seconds(30))
                return "too late"
            },
            llm: MockLLM { _, _, _ in "Unused" },
            titleModelID: "fast"
        )
        let task = Task { await namer.proposeName(.init(audioURL: audioURL)) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let name = await task.value
        XCTAssertNil(name)
    }
}
