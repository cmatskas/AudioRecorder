import AWSTranscribeStreaming
import AudioRecorderCore
import Foundation

/// Streams one source's 16 kHz PCM chunks to Amazon Transcribe and emits
/// finalized utterances. One instance per source, so "Me" and "Them" are
/// separate streams — speaker attribution comes from the audio topology, not
/// from diarization.
struct TranscribeStreamer {
    let speaker: Speaker
    let configuration: InsightsConfiguration

    /// Runs until `chunks` finishes (feed drained) or the service errors.
    /// Emits each finalized utterance via `onUtterance`.
    func run(
        chunks: AsyncStream<Data>,
        onUtterance: @escaping @Sendable (Utterance) -> Void
    ) async throws {
        let config = try await TranscribeStreamingClient.TranscribeStreamingClientConfiguration(
            awsCredentialIdentityResolver: AWSCredentials.resolver(for: configuration),
            region: configuration.region
        )
        let client = TranscribeStreamingClient(config: config)

        let audioStream = AsyncThrowingStream<
            TranscribeStreamingClientTypes.AudioStream, Error
        > { continuation in
            let task = Task {
                for await chunk in chunks {
                    continuation.yield(
                        .audioevent(
                            TranscribeStreamingClientTypes.AudioEvent(audioChunk: chunk)
                        )
                    )
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        let input = StartStreamTranscriptionInput(
            audioStream: audioStream,
            enablePartialResultsStabilization: true,
            languageCode: .enUs,
            mediaEncoding: .pcm,
            mediaSampleRateHertz: Int(AnalysisFeed.outputSampleRate),
            partialResultsStability: .high
        )

        let output = try await client.startStreamTranscription(input: input)
        guard let events = output.transcriptResultStream else { return }

        for try await event in events {
            guard case let .transcriptevent(transcriptEvent) = event else { continue }
            for result in transcriptEvent.transcript?.results ?? [] {
                guard !result.isPartial,
                      let text = result.alternatives?.first?.transcript,
                      !text.trimmingCharacters(in: .whitespaces).isEmpty
                else { continue }
                onUtterance(Utterance(speaker: speaker, text: text, timestamp: Date()))
            }
        }
    }
}
