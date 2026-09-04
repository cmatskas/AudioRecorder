import AudioRecorderCore
import Foundation
import os

/// Transcribes the opening of a finished recording with Amazon Transcribe, for
/// naming only.
///
/// It replays the file through the same streaming WebSocket path live insights
/// use, rather than the batch API. Batch would mean an S3 bucket, an upload of
/// the whole recording, `s3:PutObject` and `transcribe:StartTranscriptionJob`
/// permissions, job polling and cleanup. Replay needs none of that: the
/// credentials, the presigner and the event-stream codec already exist, and the
/// service supports streaming pre-recorded media.
///
/// Audio is paced rather than fire-hosed — AWS asks that a stream stay close to
/// real time — and only the head of the recording is sent, so a naming run is
/// bounded in both time and cost. If the service objects to the pace, the run is
/// retried once in real time.
public struct AWSFileTranscriber: NamingTranscriber {
    /// How much faster than real time to replay. Four is a compromise: a
    /// 3-minute window lands in about 45 seconds without racing the service.
    public static let defaultSpeedUp = 4.0

    private let configuration: InsightsConfiguration
    private let speedUp: Double
    private let runStream: @Sendable (
        AsyncStream<Data>, InsightsConfiguration, @escaping @Sendable (Utterance) -> Void
    ) async throws -> Void

    private static let logger = Logger(
        subsystem: "dev.cmatskas.AudioRecorder", category: "naming"
    )

    public init(configuration: InsightsConfiguration, speedUp: Double = defaultSpeedUp) {
        self.init(configuration: configuration, speedUp: speedUp) { chunks, config, onUtterance in
            let streamer = TranscribeStreamer(speaker: .them, configuration: config)
            try await streamer.run(chunks: chunks, onUtterance: onUtterance)
        }
    }

    /// Seam for tests: lets the streaming step be stubbed so pacing and retry
    /// behaviour can be exercised without the network.
    init(
        configuration: InsightsConfiguration,
        speedUp: Double = defaultSpeedUp,
        runStream: @escaping @Sendable (
            AsyncStream<Data>, InsightsConfiguration, @escaping @Sendable (Utterance) -> Void
        ) async throws -> Void
    ) {
        self.configuration = configuration
        self.speedUp = speedUp
        self.runStream = runStream
    }

    public func transcribe(audioURL: URL, maxDuration: TimeInterval) async throws -> String {
        do {
            return try await run(
                audioURL: audioURL,
                maxDuration: maxDuration,
                pacing: .multiple(speedUp)
            )
        } catch {
            Self.logger.info(
                "naming stream failed at \(speedUp, privacy: .public)x, retrying in real time: \(error.localizedDescription, privacy: .public)"
            )
            try Task.checkCancellation()
            return try await run(
                audioURL: audioURL,
                maxDuration: maxDuration,
                pacing: .realTime
            )
        }
    }

    // MARK: - One pass

    private func run(
        audioURL: URL,
        maxDuration: TimeInterval,
        pacing: AudioFileChunker.Pacing
    ) async throws -> String {
        // The streamer consumes a non-throwing AsyncStream, so file read errors
        // are surfaced by ending the stream and rethrown after the run.
        let readFailure = FailureBox()
        let (chunks, continuation) = AsyncStream.makeStream(of: Data.self)
        let feeder = Task.detached(priority: .utility) {
            do {
                for try await chunk in AudioFileChunker.chunks(
                    of: audioURL, maxDuration: maxDuration, pacing: pacing
                ) {
                    continuation.yield(chunk)
                }
            } catch is CancellationError {
                // Shutting down.
            } catch {
                readFailure.set(error)
            }
            continuation.finish()
        }
        defer { feeder.cancel() }

        let collected = TextBox()
        do {
            try await runStream(chunks, configuration) { utterance in
                collected.append(utterance.text)
            }
        } catch {
            continuation.finish()
            throw error
        }
        if let failure = readFailure.value {
            throw failure
        }
        return collected.joined()
    }
}

/// Thread-safe accumulators: utterances arrive on the streamer's callback while
/// the caller awaits the run.
private final class TextBox: @unchecked Sendable {
    private var pieces: [String] = []
    private let lock = NSLock()

    func append(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        pieces.append(text)
    }

    func joined() -> String {
        lock.lock()
        defer { lock.unlock() }
        return pieces.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private final class FailureBox: @unchecked Sendable {
    private var stored: Error?
    private let lock = NSLock()

    var value: Error? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func set(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        if stored == nil { stored = error }
    }
}
