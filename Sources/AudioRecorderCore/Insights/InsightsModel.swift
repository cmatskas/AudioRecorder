import Foundation

/// Who said something. The mic track is the local user; the system-audio
/// track is everyone else (the far side of a call, a video, …). This gives
/// speaker attribution for free, without diarization.
public enum Speaker: String, Codable, Sendable {
    case me
    case them

    public var displayName: String {
        switch self {
        case .me: return "Me"
        case .them: return "Them"
        }
    }
}

/// One finalized piece of transcribed speech.
///
/// `startOffset`/`endOffset` are seconds from the start of the transcription
/// stream, as reported by the transcription service. They are optional because
/// transcripts written before offsets were captured decode without them —
/// Swift's synthesized decoder treats missing keys for optionals as nil.
/// Prefer them over `timestamp` for anything positional (subtitle export,
/// aligning with the audio): `timestamp` is wall-clock receipt time and drifts
/// with network latency.
public struct Utterance: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let speaker: Speaker
    public let text: String
    /// Wall-clock time the utterance was received.
    public let timestamp: Date
    /// Seconds from stream start to the beginning of this utterance.
    public let startOffset: TimeInterval?
    /// Seconds from stream start to the end of this utterance.
    public let endOffset: TimeInterval?

    public init(
        id: UUID = UUID(),
        speaker: Speaker,
        text: String,
        timestamp: Date,
        startOffset: TimeInterval? = nil,
        endOffset: TimeInterval? = nil
    ) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.timestamp = timestamp
        self.startOffset = startOffset
        self.endOffset = endOffset
    }
}

/// A follow-up question or observation suggested by the fast lane.
public struct Suggestion: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let text: String
    public let createdAt: Date

    public init(id: UUID = UUID(), text: String, createdAt: Date = Date()) {
        self.id = id
        self.text = text
        self.createdAt = createdAt
    }
}

/// Lifecycle of the live-insights pipeline. Note there is no state in which a
/// pipeline problem affects recording — the worst case is `degraded`.
public enum InsightsStatus: Equatable, Sendable {
    case idle
    /// Connecting to the transcription service.
    case starting
    /// Streaming and analyzing.
    case live
    /// User-requested pause: audio is not leaving the machine.
    case paused
    /// Something failed; insights are stalled but recording is unaffected.
    case degraded(String)
    case stopped
}

/// Observable state rendered by the insights window. Written only from the
/// main actor; the pipeline hops here to publish.
@MainActor
public final class InsightsModel: ObservableObject {
    @Published public var utterances: [Utterance] = []
    @Published public var suggestions: [Suggestion] = []
    @Published public var summary: String = ""
    @Published public var summaryUpdatedAt: Date?
    @Published public var status: InsightsStatus = .idle

    public init() {}

    public func reset() {
        utterances = []
        suggestions = []
        summary = ""
        summaryUpdatedAt = nil
        status = .idle
    }
}

/// A live-analysis pipeline attached to a recording session.
///
/// Implementations live outside AudioRecorderCore (the AWS one is in
/// AudioRecorderInsights) so the recording core carries no network code or
/// third-party dependencies.
public protocol InsightsPipeline: AnyObject, Sendable {
    /// Ring buffers to attach to the capture sources. Called once, before the
    /// recording session is created. Rates are the native track rates.
    @MainActor func makeExtraSinks(
        micRate: Double?,
        systemRate: Double?
    ) -> RecordingSession.ExtraSinks

    /// Begins streaming/analysis, persisting the transcript as described by
    /// `destinations`.
    @MainActor func start(destinations: TranscriptDestinations)

    /// Pause / resume streaming to the network (off-the-record moments).
    @MainActor func setPaused(_ paused: Bool)

    /// Stops the pipeline, flushes any pending transcript/insight state to
    /// disk, and releases network resources.
    @MainActor func finish() async
}

/// Where a recording's transcript is written.
public struct TranscriptDestinations: Sendable {
    /// Names artifacts copied into `exportRoots`.
    public var sessionName: String
    /// Session directory receiving the live append-only log (the backup
    /// destination's), alongside the audio masters.
    public var liveDirectory: URL?
    /// Folders receiving complete, session-named artifacts at finish, so the
    /// transcript lands beside the finished recording automatically.
    public var exportRoots: [URL]

    public init(sessionName: String, liveDirectory: URL?, exportRoots: [URL] = []) {
        self.sessionName = sessionName
        self.liveDirectory = liveDirectory
        self.exportRoots = exportRoots
    }
}

/// Constructs a pipeline for one recording. Injected into `AppState` by the
/// app target, which is the only place Core and the AWS implementation meet.
public typealias InsightsPipelineFactory =
    @MainActor (InsightsConfiguration, InsightsModel) -> InsightsPipeline

/// Validates credentials/region reachability ("Test connection"). Implemented
/// with STS in AudioRecorderInsights; returns a short identity description.
public protocol InsightsCredentialsValidating: Sendable {
    func validate(_ configuration: InsightsConfiguration) async throws -> String
}
