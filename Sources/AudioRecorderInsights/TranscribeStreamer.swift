import AudioRecorderCore
import Foundation
import os

/// Streams one source's 16 kHz PCM chunks to Amazon Transcribe and emits
/// finalized utterances **live**.
///
/// Transport is Transcribe's WebSocket API (presigned URL, event-stream
/// frames over `URLSessionWebSocketTask`) rather than the AWS SDK's HTTP/2
/// bidirectional stream: the SDK path buffers transcript events until the
/// request body ends, which turned "live" insights into
/// "everything-appears-at-stop". WebSockets are genuinely full-duplex, so
/// results arrive while audio is still flowing.
struct TranscribeStreamer {
    let speaker: Speaker
    let configuration: InsightsConfiguration

    enum StreamError: LocalizedError {
        case serviceException(String)

        var errorDescription: String? {
            switch self {
            case let .serviceException(message): return message
            }
        }
    }

    private static let logger = Logger(
        subsystem: "dev.cmatskas.AudioRecorder", category: "transcribe"
    )

    /// Runs until `chunks` finishes (feed drained) or the service errors.
    /// `onConnected` fires once the WebSocket is established; `onUtterance`
    /// fires for every finalized result.
    func run(
        chunks: AsyncStream<Data>,
        onConnected: @escaping @Sendable () -> Void = {},
        onUtterance: @escaping @Sendable (Utterance) -> Void
    ) async throws {
        let credentials = try await AWSCredentials.rawCredentials(for: configuration)
        let url = TranscribePresigner.presignedURL(
            region: configuration.region,
            credentials: credentials,
            parameters: .init(sampleRate: Int(AnalysisFeed.outputSampleRate))
        )

        let task = URLSession.shared.webSocketTask(with: url)
        task.maximumMessageSize = 4 * 1024 * 1024
        task.resume()

        // Sender: audio chunks as AudioEvent frames, then an empty frame as
        // end-of-stream so Transcribe finalizes and closes.
        let sender = Task {
            var connectedReported = false
            for await chunk in chunks {
                guard !Task.isCancelled else { return }
                do {
                    try await task.send(.data(EventStreamCodec.encodeAudioChunk(chunk)))
                    if !connectedReported {
                        connectedReported = true
                        Self.logger.info("\(speaker.rawValue, privacy: .public): stream connected")
                        onConnected()
                    }
                } catch {
                    Self.logger.error("\(speaker.rawValue, privacy: .public): send failed: \(error.localizedDescription, privacy: .public)")
                    return  // Receiver will surface the connection error.
                }
            }
            try? await task.send(.data(EventStreamCodec.encodeEndOfStream()))
            Self.logger.info("\(speaker.rawValue, privacy: .public): end of audio sent")
        }
        defer {
            sender.cancel()
            task.cancel(with: .normalClosure, reason: nil)
        }

        // Receiver: decode frames as they arrive. Loop ends when the server
        // closes the socket (receive throws after our end-of-stream).
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                if task.closeCode == .normalClosure || sender.isCancelled {
                    break  // Graceful end after end-of-stream.
                }
                await sender.value  // If the feed already finished, treat teardown races as graceful.
                if task.closeCode != .invalid { break }
                throw error
            }
            guard case let .data(frameData) = message else { continue }
            let frame = try EventStreamCodec.decode(frameData)

            switch frame.headers[":message-type"] {
            case "event" where frame.headers[":event-type"] == "TranscriptEvent":
                for result in Self.finalResults(in: frame.payload) {
                    onUtterance(
                        Utterance(
                            speaker: speaker,
                            text: result.text,
                            timestamp: Date(),
                            startOffset: result.start,
                            endOffset: result.end
                        )
                    )
                }
            case "exception":
                let detail = (try? JSONDecoder().decode(ExceptionPayload.self, from: frame.payload))?.message
                    ?? frame.headers[":exception-type"] ?? "unknown Transcribe error"
                throw StreamError.serviceException(detail)
            default:
                continue
            }
        }
    }

    // MARK: - Payload parsing

    private struct TranscriptPayload: Decodable {
        struct Transcript: Decodable {
            let results: [Result]?
            enum CodingKeys: String, CodingKey { case results = "Results" }
        }
        struct Result: Decodable {
            let isPartial: Bool
            let alternatives: [Alternative]?
            /// Seconds from stream start; used for positional timestamps and
            /// subtitle export.
            let startTime: Double?
            let endTime: Double?
            enum CodingKeys: String, CodingKey {
                case isPartial = "IsPartial"
                case alternatives = "Alternatives"
                case startTime = "StartTime"
                case endTime = "EndTime"
            }
        }
        struct Alternative: Decodable {
            let transcript: String?
            enum CodingKeys: String, CodingKey { case transcript = "Transcript" }
        }
        let transcript: Transcript?
        enum CodingKeys: String, CodingKey { case transcript = "Transcript" }
    }

    private struct ExceptionPayload: Decodable {
        let message: String?
        enum CodingKeys: String, CodingKey { case message = "Message" }
    }

    struct FinalResult: Equatable {
        var text: String
        var start: TimeInterval?
        var end: TimeInterval?
    }

    static func finalResults(in payload: Data) -> [FinalResult] {
        guard let decoded = try? JSONDecoder().decode(TranscriptPayload.self, from: payload) else {
            return []
        }
        return (decoded.transcript?.results ?? [])
            .filter { !$0.isPartial }
            .compactMap { result in
                guard
                    let text = result.alternatives?.first?.transcript?
                        .trimmingCharacters(in: .whitespaces),
                    !text.isEmpty
                else { return nil }
                return FinalResult(text: text, start: result.startTime, end: result.endTime)
            }
    }

    /// Text of the finalized results, for tests and logging.
    static func finalTranscripts(in payload: Data) -> [String] {
        finalResults(in: payload).map(\.text)
    }
}
