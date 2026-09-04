import AVFoundation
import XCTest
@testable import AudioRecorderCore
@testable import AudioRecorderInsights

/// Covers the parts of the naming replay that do not need AWS: which audio is
/// sent, how results are assembled, and the retry that drops to real-time pacing
/// when the service objects. Live coverage lives in `LiveAWSIntegrationTests`.
final class AWSFileTranscriberTests: XCTestCase {
    private var root: URL!

    private static let configuration = InsightsConfiguration(
        credentialSource: .profile(name: "does-not-matter"), region: "us-east-1"
    )

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileTranscriberTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeToneFile(seconds: Double) throws -> URL {
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)
        )
        let url = root.appendingPathComponent("tone.caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * 44_100)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<2 {
            for frame in 0..<Int(frames) {
                data[channel][frame] = 0.2 * sinf(2 * .pi * 440 * Float(frame) / 44_100)
            }
        }
        try file.write(from: buffer)
        return url
    }

    private final class Recorder: @unchecked Sendable {
        private var chunkCounts: [Int] = []
        private var attempts = 0
        private let lock = NSLock()

        func noteAttempt() {
            lock.lock()
            attempts += 1
            lock.unlock()
        }

        func note(chunks: Int) {
            lock.lock()
            chunkCounts.append(chunks)
            lock.unlock()
        }

        var attemptCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return attempts
        }

        var counts: [Int] {
            lock.lock()
            defer { lock.unlock() }
            return chunkCounts
        }
    }

    private struct ServiceError: Error {}

    func testJoinsFinalUtterancesIntoOneTranscript() async throws {
        let url = try makeToneFile(seconds: 1)
        let recorder = Recorder()
        let transcriber = AWSFileTranscriber(
            configuration: Self.configuration
        ) { chunks, _, onUtterance in
            recorder.noteAttempt()
            var count = 0
            for await _ in chunks { count += 1 }
            recorder.note(chunks: count)
            onUtterance(Utterance(speaker: .them, text: "we discussed pricing", timestamp: Date()))
            onUtterance(Utterance(speaker: .them, text: "and the budget", timestamp: Date()))
        }

        let text = try await transcriber.transcribe(audioURL: url, maxDuration: 1)
        XCTAssertEqual(text, "we discussed pricing and the budget")
        XCTAssertEqual(recorder.attemptCount, 1)
        // 1 second of 16 kHz mono in 100 ms chunks.
        XCTAssertTrue(
            (9...11).contains(recorder.counts.first ?? 0),
            "unexpected chunk count \(recorder.counts)"
        )
    }

    func testWindowLimitsHowMuchAudioIsSent() async throws {
        let url = try makeToneFile(seconds: 3)
        let recorder = Recorder()
        let transcriber = AWSFileTranscriber(
            configuration: Self.configuration
        ) { chunks, _, onUtterance in
            var count = 0
            for await _ in chunks { count += 1 }
            recorder.note(chunks: count)
            onUtterance(Utterance(speaker: .them, text: "hello", timestamp: Date()))
        }

        _ = try await transcriber.transcribe(audioURL: url, maxDuration: 1)
        XCTAssertTrue(
            (9...11).contains(recorder.counts.first ?? 0),
            "the window should cap what is sent, got \(recorder.counts)"
        )
    }

    /// AWS asks that a stream stay near real time. If it objects anyway, the run
    /// is retried once at real-time pacing rather than abandoned.
    func testServiceFailureRetriesOnceInRealTime() async throws {
        let url = try makeToneFile(seconds: 0.4)
        let recorder = Recorder()
        let transcriber = AWSFileTranscriber(
            configuration: Self.configuration
        ) { chunks, _, onUtterance in
            recorder.noteAttempt()
            for await _ in chunks {}
            if recorder.attemptCount == 1 {
                throw ServiceError()
            }
            onUtterance(Utterance(speaker: .them, text: "second try", timestamp: Date()))
        }

        let text = try await transcriber.transcribe(audioURL: url, maxDuration: 0.4)
        XCTAssertEqual(text, "second try")
        XCTAssertEqual(recorder.attemptCount, 2)
    }

    func testBothAttemptsFailingThrows() async throws {
        let url = try makeToneFile(seconds: 0.3)
        let recorder = Recorder()
        let transcriber = AWSFileTranscriber(
            configuration: Self.configuration
        ) { chunks, _, _ in
            recorder.noteAttempt()
            for await _ in chunks {}
            throw ServiceError()
        }

        do {
            _ = try await transcriber.transcribe(audioURL: url, maxDuration: 0.3)
            XCTFail("expected the second failure to propagate")
        } catch {
            XCTAssertEqual(recorder.attemptCount, 2)
        }
    }

    func testSilentWindowYieldsEmptyTextRatherThanAnError() async throws {
        let url = try makeToneFile(seconds: 0.3)
        let transcriber = AWSFileTranscriber(
            configuration: Self.configuration
        ) { chunks, _, _ in
            for await _ in chunks {}
        }
        let text = try await transcriber.transcribe(audioURL: url, maxDuration: 0.3)
        XCTAssertTrue(text.isEmpty)
    }
}
