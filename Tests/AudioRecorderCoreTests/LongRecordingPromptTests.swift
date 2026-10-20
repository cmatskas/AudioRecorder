import XCTest
@testable import AudioRecorderCore

/// The check-in decides whether hours of audio keep being written, so each rule
/// gets its own test: ask on time, stop on silence, stop on "No", keep going on
/// "Yes", and ask again every interval after that.
///
/// Timings are milliseconds rather than hours, and assertions only depend on
/// `Task.sleep` lasting *at least* as long as asked — the direction the platform
/// guarantees, and the lesson from the flaky debouncer test.
@MainActor
final class LongRecordingPromptTests: XCTestCase {
    private func tuning(
        firstCheckIn: TimeInterval = 0.15,
        repeatInterval: TimeInterval = 0.15,
        responseWindow: TimeInterval = 0.3
    ) -> LongRecordingPrompt.Tuning {
        LongRecordingPrompt.Tuning(
            firstCheckIn: firstCheckIn,
            repeatInterval: repeatInterval,
            responseWindow: responseWindow
        )
    }

    /// Counters shared with @MainActor closures; the whole test is main-actor.
    private final class Log {
        var asks = 0
        var stops = 0
        var reasons: [LongRecordingPrompt.StopReason] = []
    }

    private func start(
        _ prompt: LongRecordingPrompt,
        startedAt: Date = Date(),
        log: Log
    ) {
        prompt.start(
            startedAt: startedAt,
            ask: { log.asks += 1 },
            stop: { reason in
                log.stops += 1
                log.reasons.append(reason)
            }
        )
    }

    // MARK: - Asking

    func testAsksAfterTheFirstInterval() async throws {
        let prompt = LongRecordingPrompt(tuning: tuning(responseWindow: 5))
        let log = Log()
        start(prompt, log: log)

        XCTAssertEqual(log.asks, 0, "must not ask immediately")
        XCTAssertFalse(prompt.isAsking)

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(log.asks, 1)
        XCTAssertTrue(prompt.isAsking)
        XCTAssertEqual(log.stops, 0, "still inside the response window")
        prompt.cancel()
    }

    /// The deadline comes from when the recording started, so a recording
    /// already past the threshold is asked about at once rather than two more
    /// hours later.
    func testDeadlineIsMeasuredFromTheRecordingStart() async throws {
        let prompt = LongRecordingPrompt(tuning: tuning(firstCheckIn: 3600, responseWindow: 5))
        let log = Log()
        // Started 90 minutes into a two-hour threshold: due in 30 minutes'
        // worth of test time — here, immediately.
        start(prompt, startedAt: Date().addingTimeInterval(-5_400), log: log)

        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(log.asks, 1)
        prompt.cancel()
    }

    func testResponseDeadlineIsPublishedForTheCountdown() async throws {
        let prompt = LongRecordingPrompt(tuning: tuning(responseWindow: 5))
        let log = Log()
        start(prompt, log: log)
        XCTAssertNil(prompt.responseDeadline)

        try await Task.sleep(for: .milliseconds(400))
        let deadline = try XCTUnwrap(prompt.responseDeadline)
        XCTAssertGreaterThan(deadline, Date())
        XCTAssertLessThanOrEqual(deadline.timeIntervalSinceNow, 5)
        prompt.cancel()
    }

    // MARK: - Failing closed

    /// The rule that matters most: no answer ends the recording.
    func testSilenceStopsTheRecording() async throws {
        let prompt = LongRecordingPrompt(tuning: tuning())
        let log = Log()
        start(prompt, log: log)

        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(log.asks, 1)
        XCTAssertEqual(log.stops, 1)
        XCTAssertEqual(log.reasons, [.unanswered], "silence is not a decline")
        XCTAssertFalse(prompt.isAsking)
        XCTAssertNil(prompt.responseDeadline)
    }

    /// Nothing more is asked once the recording has been stopped.
    func testNoFurtherQuestionsAfterStopping() async throws {
        let prompt = LongRecordingPrompt(tuning: tuning())
        let log = Log()
        start(prompt, log: log)

        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(log.stops, 1)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(log.asks, 1, "asked again after stopping")
        XCTAssertEqual(log.stops, 1, "stopped twice")
    }

    func testDecliningStopsTheRecordingImmediately() async throws {
        let prompt = LongRecordingPrompt(tuning: tuning(responseWindow: 30))
        let log = Log()
        start(prompt, log: log)

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(prompt.isAsking)
        prompt.decline()

        XCTAssertEqual(log.stops, 1, "No must stop without waiting for the window")
        XCTAssertEqual(log.reasons, [.declined], "an explicit No must be reported as such")
        XCTAssertFalse(prompt.isAsking)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(log.asks, 1)
        XCTAssertEqual(log.stops, 1)
    }

    // MARK: - Continuing

    func testConfirmingKeepsRecordingAndAsksAgainLater() async throws {
        let prompt = LongRecordingPrompt(tuning: tuning(repeatInterval: 0.2, responseWindow: 30))
        let log = Log()
        start(prompt, log: log)

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(log.asks, 1)
        prompt.confirmContinue()
        XCTAssertFalse(prompt.isAsking)
        XCTAssertNil(prompt.responseDeadline)
        XCTAssertEqual(log.stops, 0, "Yes must not stop the recording")

        // The next check-in follows the repeat interval, not the first one.
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertGreaterThanOrEqual(log.asks, 2)
        XCTAssertEqual(log.stops, 0)
        prompt.cancel()
    }

    /// "Yes" is not a one-time reprieve: the question returns every interval.
    func testAsksRepeatedlyWhileConfirmed() async throws {
        let prompt = LongRecordingPrompt(tuning: tuning(repeatInterval: 0.15, responseWindow: 30))
        let log = Log()
        start(prompt, log: log)

        for expected in 1...3 {
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertGreaterThanOrEqual(log.asks, expected)
            XCTAssertTrue(prompt.isAsking, "expected question \(expected)")
            prompt.confirmContinue()
        }
        XCTAssertEqual(log.stops, 0)
        prompt.cancel()
    }

    // MARK: - Cancellation

    /// Stopping a recording by hand must not leave a question waiting to stop
    /// the *next* one.
    func testCancelEndsTheWatch() async throws {
        let prompt = LongRecordingPrompt(tuning: tuning())
        let log = Log()
        start(prompt, log: log)
        prompt.cancel()

        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(log.asks, 0)
        XCTAssertEqual(log.stops, 0)
    }

    func testCancelWhileAskingDoesNotStopTheRecording() async throws {
        let prompt = LongRecordingPrompt(tuning: tuning(responseWindow: 0.5))
        let log = Log()
        start(prompt, log: log)

        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(prompt.isAsking)
        prompt.cancel()

        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(log.stops, 0, "cancel is not an answer")
        XCTAssertFalse(prompt.isAsking)
    }

    /// Restarting for a new recording resets the clock.
    func testStartingAgainReplacesTheEarlierWatch() async throws {
        let prompt = LongRecordingPrompt(tuning: tuning(firstCheckIn: 0.2, responseWindow: 30))
        let log = Log()
        start(prompt, log: log)
        start(prompt, log: log)

        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(log.asks, 1, "the replaced watch also asked")
        prompt.cancel()
    }

    // MARK: - Defaults

    /// The shipping numbers, as specified: two hours, then hourly, 30 seconds.
    func testDefaultTuningMatchesTheSpecifiedBehaviour() {
        let tuning = LongRecordingPrompt.Tuning()
        XCTAssertEqual(tuning.firstCheckIn, 2 * 60 * 60)
        XCTAssertEqual(tuning.repeatInterval, 60 * 60)
        XCTAssertEqual(tuning.responseWindow, 30)
    }

    /// Overrides exist so the two-hour path can be tried in minutes; absent or
    /// nonsensical values must leave the shipping behaviour alone.
    func testResolvedTuningAppliesOnlyPositiveOverrides() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "LongRecordingPromptTests"))
        defaults.removePersistentDomain(forName: "LongRecordingPromptTests")

        let untouched = LongRecordingPrompt.Tuning.resolved(from: defaults)
        XCTAssertEqual(untouched.firstCheckIn, 2 * 60 * 60)
        XCTAssertEqual(untouched.repeatInterval, 60 * 60)
        XCTAssertEqual(untouched.responseWindow, 30)

        defaults.set(2, forKey: "longRecordingCheckInMinutes")
        defaults.set(1, forKey: "longRecordingRepeatMinutes")
        defaults.set(15, forKey: "longRecordingResponseSeconds")
        let overridden = LongRecordingPrompt.Tuning.resolved(from: defaults)
        XCTAssertEqual(overridden.firstCheckIn, 120)
        XCTAssertEqual(overridden.repeatInterval, 60)
        XCTAssertEqual(overridden.responseWindow, 15)

        defaults.set(0, forKey: "longRecordingCheckInMinutes")
        defaults.set(-5, forKey: "longRecordingRepeatMinutes")
        let ignored = LongRecordingPrompt.Tuning.resolved(from: defaults)
        XCTAssertEqual(ignored.firstCheckIn, 2 * 60 * 60)
        XCTAssertEqual(ignored.repeatInterval, 60 * 60)
        XCTAssertEqual(ignored.responseWindow, 15)

        defaults.removePersistentDomain(forName: "LongRecordingPromptTests")
    }

    func testAnsweringBeforeBeingAskedDoesNothing() async throws {
        let prompt = LongRecordingPrompt(tuning: tuning(firstCheckIn: 5))
        let log = Log()
        start(prompt, log: log)

        prompt.confirmContinue()
        prompt.decline()
        XCTAssertEqual(log.stops, 0, "an answer to a question never asked")
        XCTAssertEqual(log.asks, 0)
        prompt.cancel()
    }
}
