import Foundation

/// Decides what a finished recording should be called.
///
/// Three sources of text, in order of preference:
///
///  1. the Live Insights transcript, if there was one — already on disk, free;
///  2. otherwise a transcription of the recording's opening minutes, from
///     whichever `NamingTranscriber` the user selected;
///  3. nothing, in which case the recording keeps its timestamp name.
///
/// The title itself comes from one model call, falling back to a local
/// keyword heuristic when the call fails or no credentials are configured.
///
/// Nothing here throws and nothing here is required to succeed: naming is a
/// convenience layered on top of a recording that is already safely on disk.
public struct RecordingNamer: Sendable {
    public struct Inputs: Sendable {
        /// The finished merged recording, used only if a transcript is needed.
        public var audioURL: URL?
        /// Transcript text from Live Insights; empty when it was off.
        public var liveTranscript: String
        /// Closing briefing from the deep lane, if any.
        public var summary: String

        public init(audioURL: URL?, liveTranscript: String = "", summary: String = "") {
            self.audioURL = audioURL
            self.liveTranscript = liveTranscript
            self.summary = summary
        }
    }

    /// Used only when there is no live transcript. Nil means "no post-recording
    /// transcription", which is how the feature stays off for users who want it off.
    public var transcriber: (any NamingTranscriber)?
    /// Nil when no model credentials are configured; the heuristic covers it.
    public var llm: (any LLMClient)?
    /// The model asked for a title. Up to two calls are made: one to name the
    /// recording, and one more only if the answer overshoots the length budget.
    public var titleModelID: String?
    /// How much of the recording's opening may be transcribed.
    public var maxTranscriptionDuration: TimeInterval
    /// Hard ceiling on the whole operation, so a wedged backend cannot leave the
    /// UI saying "Naming…" forever.
    public var budget: Duration

    public init(
        transcriber: (any NamingTranscriber)? = nil,
        llm: (any LLMClient)? = nil,
        titleModelID: String? = nil,
        maxTranscriptionDuration: TimeInterval = 180,
        budget: Duration = .seconds(120)
    ) {
        self.transcriber = transcriber
        self.llm = llm
        self.titleModelID = titleModelID
        self.maxTranscriptionDuration = maxTranscriptionDuration
        self.budget = budget
    }

    /// A name for this recording, or nil if one cannot be produced.
    public func proposeName(_ inputs: Inputs) async -> String? {
        await withBudget(budget) {
            guard let transcript = await self.transcriptText(for: inputs) else { return nil }
            guard !Task.isCancelled else { return nil }
            // When the summary *is* the text, don't send it to the model twice.
            let summary = transcript == inputs.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                ? ""
                : inputs.summary
            if let title = await self.modelTitle(transcript: transcript, summary: summary) {
                return title
            }
            return RecordingTitler.heuristicTitle(from: transcript)
        }
    }

    // MARK: - Steps

    private func transcriptText(for inputs: Inputs) async -> String? {
        let live = inputs.liveTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !live.isEmpty { return live }
        if let transcriber, let audioURL = inputs.audioURL {
            do {
                let text = try await transcriber.transcribe(
                    audioURL: audioURL, maxDuration: maxTranscriptionDuration
                )
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            } catch {
                // Silent by design: fall through to whatever else we have.
            }
        }
        // Last resort: the closing briefing. Less material than a transcript,
        // but a summary describes the conversation well enough to name it, and
        // any name beats a timestamp.
        let summary = inputs.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        return summary.isEmpty ? nil : summary
    }

    private func modelTitle(transcript: String, summary: String) async -> String? {
        guard let llm, let titleModelID else { return nil }
        guard let first = try? await llm.complete(
            modelID: titleModelID,
            system: RecordingTitler.system,
            user: RecordingTitler.user(summary: summary, transcript: transcript)
        ) else { return nil }

        let candidate = RecordingTitler.candidate(in: first)
        if let candidate, RecordingTitler.fits(candidate) {
            return candidate
        }

        // The answer is too long. Models are poor at counting characters but
        // good at shortening something concrete, so quote it back once rather
        // than cutting it ourselves — cutting is what produced names like
        // "Impact of".
        if let rejected = candidate, !Task.isCancelled {
            if let second = try? await llm.complete(
                modelID: titleModelID,
                system: RecordingTitler.system,
                user: RecordingTitler.retryUser(
                    summary: summary, transcript: transcript, previous: rejected
                )
            ), let retried = RecordingTitler.parse(second) {
                return retried
            }
        }
        // Both attempts overshot: shorten by dropping words.
        return RecordingTitler.parse(first)
    }

    // MARK: - Budget

    /// Runs `operation`, abandoning it if it outlives `duration`.
    private func withBudget(
        _ duration: Duration,
        operation: @escaping @Sendable () async -> String?
    ) async -> String? {
        await withTaskGroup(of: String?.self) { group in
            group.addTask { await operation() }
            group.addTask {
                try? await Task.sleep(for: duration)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
