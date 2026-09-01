import Synchronization
import XCTest
@testable import AudioRecorderCore
@testable import AudioRecorderInsights

/// Live end-to-end checks against real AWS. Skipped unless
/// `AUDIORECORDER_LIVE_AWS=1` is set, so CI and ordinary `swift test` runs
/// stay offline and free.
///
///     AUDIORECORDER_LIVE_AWS=1 swift test --filter LiveAWSIntegrationTests
///
/// Override the profile/region with `AUDIORECORDER_AWS_PROFILE` and
/// `AUDIORECORDER_AWS_REGION`.
final class LiveAWSIntegrationTests: XCTestCase {
    private var configuration: InsightsConfiguration!

    override func setUpWithError() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["AUDIORECORDER_LIVE_AWS"] == "1",
            "Set AUDIORECORDER_LIVE_AWS=1 to run live AWS integration tests"
        )
        let environment = ProcessInfo.processInfo.environment
        configuration = InsightsConfiguration(
            credentialSource: .profile(
                name: environment["AUDIORECORDER_AWS_PROFILE"] ?? "default"
            ),
            region: environment["AUDIORECORDER_AWS_REGION"] ?? "us-east-1"
        )
    }

    func testCredentialsResolveAndValidate() async throws {
        let identity = try await STSCredentialsValidator().validate(configuration)
        XCTAssertTrue(identity.contains("account"), "unexpected identity: \(identity)")
    }

    /// Both configured models must be reachable and invocable — the check that
    /// was missing when insights first shipped.
    func testConfiguredBedrockModelsAreInvocable() async throws {
        let llm = try await BedrockLLMClient(configuration: configuration)
        for modelID in [configuration.fastModelID, configuration.deepModelID] {
            let response = try await llm.complete(
                modelID: modelID,
                system: "You are a test probe. Follow the instruction exactly.",
                user: "Reply with exactly: ok"
            )
            XCTAssertTrue(
                response.lowercased().contains("ok"),
                "\(modelID) returned unexpected response: \(response)"
            )
        }
    }

    /// The regression that made insights appear only after stopping: transcript
    /// results must arrive *while* audio is still streaming.
    func testTranscriptionArrivesWhileAudioIsStillStreaming() async throws {
        let pcm = try Self.synthesizeSpeechPCM(
            "The quick brown fox jumps over the lazy dog. "
                + "After a short pause, the fox continued along the river bank, "
                + "looking for the next interesting thing to do."
        )

        let audioFinished = Mutex<Date?>(nil)
        let firstUtterance = Mutex<Date?>(nil)
        let texts = Mutex<[String]>([])

        let (chunks, continuation) = AsyncStream.makeStream(of: Data.self)
        let feeder = Task {
            let chunkBytes = 3200  // 100 ms at 16 kHz mono Int16
            var offset = 0
            while offset < pcm.count {
                let end = min(offset + chunkBytes, pcm.count)
                continuation.yield(pcm.subdata(in: offset..<end))
                offset = end
                try? await Task.sleep(for: .milliseconds(100))
            }
            audioFinished.withLock { $0 = Date() }
            // Trailing silence so Transcribe finalizes the last utterance.
            for _ in 0..<15 {
                continuation.yield(Data(count: chunkBytes))
                try? await Task.sleep(for: .milliseconds(100))
            }
            continuation.finish()
        }
        defer { feeder.cancel() }

        let streamer = TranscribeStreamer(speaker: .me, configuration: configuration)
        try await streamer.run(chunks: chunks) { utterance in
            firstUtterance.withLock { if $0 == nil { $0 = Date() } }
            texts.withLock { $0.append(utterance.text) }
        }

        let received = texts.withLock { $0 }
        XCTAssertFalse(received.isEmpty, "stream produced no utterances")
        let first = try XCTUnwrap(firstUtterance.withLock { $0 })
        let finished = try XCTUnwrap(audioFinished.withLock { $0 })
        XCTAssertLessThan(
            first, finished,
            "transcription was buffered until end of audio (first utterance at \(first), audio ended \(finished))"
        )
        XCTAssertTrue(
            received.joined(separator: " ").lowercased().contains("fox"),
            "unexpected transcript: \(received)"
        )
    }

    /// End-to-end through the pipeline the app actually uses: audio pushed
    /// into the capture sinks must surface on `InsightsModel` *while* audio is
    /// still flowing. This covers the whole chain except CoreAudio and
    /// SwiftUI — AnalysisFeed resampling, WebSocket transport, transcript
    /// store, and model publishing.
    @MainActor
    func testPipelineSurfacesUtterancesOnModelDuringRecording() async throws {
        let pcm16k = try Self.synthesizeSpeechPCM(
            "The quick brown fox jumps over the lazy dog. "
                + "Later the very same fox wandered back along the river bank."
        )
        // The pipeline expects interleaved stereo Float32 at the track rate;
        // feed 16 kHz so no rate conversion is needed beyond channel mixing.
        let model = InsightsModel()
        let pipeline = AWSInsightsPipeline(configuration: configuration, model: model)
        let sinks = pipeline.makeExtraSinks(micRate: 16_000, systemRate: nil)
        let ring = try XCTUnwrap(sinks.mic.first)
        pipeline.start(sessionDirectory: nil)

        // Push 100 ms of stereo float frames at a time, paced in real time.
        let framesPerChunk = 1_600
        var sampleIndex = 0
        let totalSamples = pcm16k.count / 2
        var utterancesWhileStreaming: [Utterance] = []
        while sampleIndex < totalSamples {
            let end = min(sampleIndex + framesPerChunk, totalSamples)
            var interleaved = [Float]()
            interleaved.reserveCapacity((end - sampleIndex) * 2)
            for index in sampleIndex..<end {
                let byte = index * 2
                let sample = Int16(
                    littleEndian: pcm16k.withUnsafeBytes {
                        $0.loadUnaligned(fromByteOffset: byte, as: Int16.self)
                    }
                )
                let value = Float(sample) / 32_768
                interleaved.append(value)
                interleaved.append(value)
            }
            interleaved.withUnsafeBufferPointer {
                _ = ring.write($0.baseAddress!, count: $0.count)
            }
            sampleIndex = end
            try await Task.sleep(for: .milliseconds(100))
            if !model.utterances.isEmpty, utterancesWhileStreaming.isEmpty {
                utterancesWhileStreaming = model.utterances
            }
        }

        XCTAssertFalse(
            utterancesWhileStreaming.isEmpty,
            "no utterances reached InsightsModel while audio was still streaming — insights would only appear after stopping"
        )
        await pipeline.finish()
    }

    /// 16 kHz mono Int16 PCM via /usr/bin/say — the pipeline's wire format.
    private static func synthesizeSpeechPCM(_ text: String) throws -> Data {
        let wavURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = [
            "-o", wavURL.path, "--data-format=LEI16@16000", "--file-format=WAVE", text,
        ]
        try say.run()
        say.waitUntilExit()
        // Rebased via Data(...): dropFirst leaves startIndex offset, which
        // would break the zero-based chunk loop above.
        return Data(try Data(contentsOf: wavURL).dropFirst(44))
    }
}
