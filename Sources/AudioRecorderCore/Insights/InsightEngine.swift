import Foundation

/// Minimal text-completion interface the engine needs. The AWS implementation
/// (Bedrock Converse) lives in AudioRecorderInsights; tests use a mock.
public protocol LLMClient: Sendable {
    func complete(modelID: String, system: String, user: String) async throws -> String
}

/// Prompt construction and response parsing, kept pure for testability.
public enum InsightPrompts {
    public static let fastSystem = """
        You are a silent meeting copilot. You listen to a live conversation \
        between "Me" (the app's user) and "Them" (the other participants). \
        Your only job is to suggest follow-up questions Me should ask next.

        Rules:
        - Suggest 1 to 3 questions, each under 20 words.
        - Base them only on what was actually said, favoring the most recent turns.
        - Prefer questions that surface risks, unstated assumptions, or missing specifics.
        - Respond with ONLY a JSON array of strings. No prose, no markdown fences.
        """

    public static let deepSystem = """
        You are a silent meeting analyst reviewing a live conversation between \
        "Me" (the app's user) and "Them" (the other participants).

        Produce a concise briefing with these sections (omit any that are empty):
        Summary: 2-4 sentences on where the conversation stands.
        Open questions: unresolved points Me should not let drop.
        Action items: commitments made, with owner if stated.

        Plain text only. Be specific; quote numbers and names when given.
        """

    public static func fastUser(runningSummary: String, recentDialogue: String) -> String {
        var parts: [String] = []
        if !runningSummary.isEmpty {
            parts.append("Context so far:\n\(runningSummary)")
        }
        parts.append("Recent conversation:\n\(recentDialogue)")
        parts.append("Suggest follow-up questions for Me.")
        return parts.joined(separator: "\n\n")
    }

    public static func deepUser(previousSummary: String, dialogue: String) -> String {
        var parts: [String] = []
        if !previousSummary.isEmpty {
            parts.append("Your previous briefing:\n\(previousSummary)")
        }
        parts.append("Conversation since the start (or the recent window):\n\(dialogue)")
        parts.append("Write the updated briefing.")
        return parts.joined(separator: "\n\n")
    }

    /// Extracts a JSON string array from a model response, tolerating stray
    /// prose or markdown fences around it.
    public static func parseSuggestions(from response: String) -> [String] {
        guard
            let start = response.firstIndex(of: "["),
            let end = response.lastIndex(of: "]"),
            start < end
        else { return [] }
        let json = String(response[start...end])
        guard
            let data = json.data(using: .utf8),
            let array = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return array
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

/// Two-tier analysis loop over a live transcript:
///
///  - **Fast lane**: debounced ~3 s after the latest final utterance, a small
///    model proposes follow-up questions from the recent window.
///  - **Deep lane**: every ~2 min, a strong model rewrites the running
///    briefing (summary / open questions / action items), which is fed back
///    into both lanes as context.
///
/// Both lanes persist their state into the session directory after each pass,
/// so a crash loses at most one cycle — matching the audio path's posture.
@MainActor
public final class InsightEngine {
    public struct Tuning: Sendable {
        public var fastDebounce: Duration
        public var deepInterval: Duration
        public var fastWindowMinutes: Double
        public var deepWindowMinutes: Double

        public init(
            fastDebounce: Duration = .seconds(3),
            deepInterval: Duration = .seconds(120),
            fastWindowMinutes: Double = 4,
            deepWindowMinutes: Double = 30
        ) {
            self.fastDebounce = fastDebounce
            self.deepInterval = deepInterval
            self.fastWindowMinutes = fastWindowMinutes
            self.deepWindowMinutes = deepWindowMinutes
        }
    }

    private let transcript: TranscriptStore
    private let model: InsightsModel
    private let llm: LLMClient
    private let fastModelID: String
    private let deepModelID: String
    private let tuning: Tuning
    private let sessionDirectory: URL?

    private var fastDebouncer: AsyncDebouncer?
    private var deepTask: Task<Void, Never>?
    private var utterancesAtLastDeepPass = 0
    private var consecutiveFailures = 0

    public init(
        transcript: TranscriptStore,
        model: InsightsModel,
        llm: LLMClient,
        fastModelID: String,
        deepModelID: String,
        tuning: Tuning = Tuning(),
        sessionDirectory: URL?
    ) {
        self.transcript = transcript
        self.model = model
        self.llm = llm
        self.fastModelID = fastModelID
        self.deepModelID = deepModelID
        self.tuning = tuning
        self.sessionDirectory = sessionDirectory
    }

    public func start() {
        fastDebouncer = AsyncDebouncer(interval: tuning.fastDebounce) { [weak self] in
            await self?.runFastPass()
        }
        deepTask = Task { [weak self, interval = tuning.deepInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                await self?.runDeepPass()
            }
        }
    }

    /// Feed point: called for every finalized utterance.
    public func noteUtterance(_ utterance: Utterance) {
        transcript.append(utterance)
        model.utterances = transcript.all
        persistTranscript()
        fastDebouncer?.trigger()
    }

    /// Stops timers and pending work without running a final pass. Used when
    /// tearing down without needing a closing summary.
    public func cancelPendingWork() {
        fastDebouncer?.cancel()
        deepTask?.cancel()
        deepTask = nil
    }

    /// Final flush: one last deep pass over the whole conversation, then stop.
    public func finish() async {
        fastDebouncer?.cancel()
        deepTask?.cancel()
        deepTask = nil
        if !transcript.isEmpty {
            await runDeepPass(force: true)
        }
        persistTranscript()
        persistInsights()
    }

    // MARK: - Lanes

    private func runFastPass() async {
        let recent = transcript.window(minutes: tuning.fastWindowMinutes)
        guard !recent.isEmpty else { return }
        let user = InsightPrompts.fastUser(
            runningSummary: model.summary,
            recentDialogue: TranscriptStore.dialogue(recent)
        )
        do {
            let response = try await llm.complete(
                modelID: fastModelID, system: InsightPrompts.fastSystem, user: user
            )
            let parsed = InsightPrompts.parseSuggestions(from: response)
            noteSuccess()
            guard !parsed.isEmpty else { return }
            model.suggestions = parsed.map { Suggestion(text: $0) }
            persistInsights()
        } catch {
            noteFailure(error, lane: "suggestions")
        }
    }

    private func runDeepPass(force: Bool = false) async {
        let count = transcript.count
        guard force || count > utterancesAtLastDeepPass else { return }
        let window = transcript.window(minutes: tuning.deepWindowMinutes)
        guard !window.isEmpty else { return }
        utterancesAtLastDeepPass = count
        let user = InsightPrompts.deepUser(
            previousSummary: model.summary,
            dialogue: TranscriptStore.dialogue(window)
        )
        do {
            let response = try await llm.complete(
                modelID: deepModelID, system: InsightPrompts.deepSystem, user: user
            )
            let summary = response.trimmingCharacters(in: .whitespacesAndNewlines)
            noteSuccess()
            guard !summary.isEmpty else { return }
            model.summary = summary
            model.summaryUpdatedAt = Date()
            persistInsights()
        } catch {
            noteFailure(error, lane: "summary")
        }
    }

    // MARK: - Health

    private func noteSuccess() {
        consecutiveFailures = 0
        if case .degraded = model.status {
            model.status = .live
        }
    }

    /// A single failed call is retried implicitly by the next cycle; only
    /// repeated failures are surfaced, and only as degradation — recording is
    /// never affected.
    private func noteFailure(_ error: Error, lane: String) {
        consecutiveFailures += 1
        if consecutiveFailures >= 3, model.status == .live {
            model.status = .degraded(
                "The \(lane) service is unreachable (\(error.localizedDescription)). Recording is unaffected."
            )
        }
    }

    // MARK: - Persistence

    private func persistTranscript() {
        guard let directory = sessionDirectory else { return }
        let file = InsightsPersistence.TranscriptFile(utterances: transcript.all)
        let url = directory.appendingPathComponent(InsightsPersistence.transcriptFileName)
        Task.detached(priority: .utility) {
            try? InsightsPersistence.write(file, to: url)
        }
    }

    private func persistInsights() {
        guard let directory = sessionDirectory else { return }
        let file = InsightsPersistence.InsightsFile(
            summary: model.summary,
            suggestions: model.suggestions,
            updatedAt: model.summaryUpdatedAt ?? Date()
        )
        let url = directory.appendingPathComponent(InsightsPersistence.insightsFileName)
        Task.detached(priority: .utility) {
            try? InsightsPersistence.write(file, to: url)
        }
    }
}
