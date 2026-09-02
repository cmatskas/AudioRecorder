import AudioRecorderCore
import Foundation

/// The AWS implementation of `InsightsPipeline`: audio taps → Transcribe
/// streaming → transcript store → two-tier Bedrock analysis → observable model.
///
/// Failure posture mirrors the recorder's lane isolation: any AWS problem
/// degrades or stops *this* pipeline and is reported on the model; the
/// recording session never observes it.
public final class AWSInsightsPipeline: InsightsPipeline, @unchecked Sendable {
    private let configuration: InsightsConfiguration
    private let model: InsightsModel
    private let transcript = TranscriptStore()

    private var feeds: [AnalysisFeed] = []
    private var engine: InsightEngine?
    private var streamTasks: [Task<Void, Never>] = []

    @MainActor
    public init(configuration: InsightsConfiguration, model: InsightsModel) {
        self.configuration = configuration
        self.model = model
    }

    // MARK: - InsightsPipeline

    @MainActor
    public func makeExtraSinks(
        micRate: Double?,
        systemRate: Double?
    ) -> RecordingSession.ExtraSinks {
        var sinks = RecordingSession.ExtraSinks()
        if let micRate {
            let feed = AnalysisFeed(speaker: .me, sourceRate: micRate)
            feeds.append(feed)
            sinks.mic = [feed.ring]
        }
        if let systemRate {
            let feed = AnalysisFeed(speaker: .them, sourceRate: systemRate)
            feeds.append(feed)
            sinks.system = [feed.ring]
        }
        return sinks
    }

    @MainActor
    public func start(destinations: TranscriptDestinations) {
        guard !feeds.isEmpty else {
            model.status = .degraded("No audio sources available for analysis.")
            return
        }
        model.reset()
        model.status = .starting

        for feed in feeds {
            feed.start()
        }

        // The Bedrock client is constructed lazily on first use, so the
        // engine exists before the first utterance and "Live" is gated only
        // on transcription actually connecting.
        let engine = InsightEngine(
            transcript: transcript,
            model: model,
            llm: LazyBedrockClient(configuration: configuration),
            fastModelID: configuration.fastModelID,
            deepModelID: configuration.deepModelID,
            recorder: TranscriptRecorder(
                sessionName: destinations.sessionName,
                liveDirectory: destinations.liveDirectory,
                exportRoots: destinations.exportRoots
            )
        )
        engine.start()
        self.engine = engine
        startStreamers(engine: engine)
    }

    @MainActor
    private func startStreamers(engine: InsightEngine) {
        for feed in feeds {
            let streamer = TranscribeStreamer(
                speaker: feed.speaker, configuration: configuration
            )
            let task = Task { [weak self, model] in
                do {
                    try await streamer.run(
                        chunks: feed.chunks,
                        onConnected: {
                            Task { @MainActor in
                                if model.status == .starting {
                                    model.status = .live
                                }
                            }
                        },
                        onUtterance: { utterance in
                            Task { @MainActor [weak self] in
                                self?.engine?.noteUtterance(utterance)
                            }
                        }
                    )
                } catch is CancellationError {
                    // Shutting down.
                } catch {
                    await MainActor.run {
                        // One stream failing degrades insights; the other
                        // stream and the recording continue.
                        if case .degraded = model.status { return }
                        model.status = .degraded(
                            "Transcription for \(streamer.speaker.displayName) stopped (\(error.localizedDescription)). Recording is unaffected."
                        )
                    }
                }
            }
            streamTasks.append(task)
        }
        _ = engine  // retained by self.engine
    }

    @MainActor
    public func setPaused(_ paused: Bool) {
        for feed in feeds {
            feed.setPaused(paused)
        }
        switch (paused, model.status) {
        case (true, .live):
            model.status = .paused
        case (false, .paused):
            model.status = .live
        default:
            break
        }
    }

    @MainActor
    public func finish() async {
        // Ask the feeds to wind down; their chunk streams finish once drained,
        // which ends the Transcribe input streams, which ends the result
        // streams the tasks are consuming.
        for feed in feeds {
            feed.finish()
        }
        let feedsCopy = feeds
        await Task.detached(priority: .userInitiated) {
            for feed in feedsCopy {
                feed.waitUntilDrained()
            }
        }.value

        // Give in-flight final results a moment, then cut the streams off.
        let tasks = streamTasks
        streamTasks = []
        let grace = Task {
            try? await Task.sleep(for: .seconds(5))
            for task in tasks { task.cancel() }
        }
        for task in tasks {
            await task.value
        }
        grace.cancel()

        await engine?.finish()
        engine = nil
        feeds = []
        if model.status != .idle {
            model.status = .stopped
        }
    }
}
