import Foundation

/// Owns transcript persistence for one recording.
///
/// Two jobs, deliberately separated:
///
///  - **Live**: every finalized utterance is appended to `transcript.jsonl`
///    and `transcript.txt` in the session directory, so a crash costs at most
///    the last few seconds and no button ever needs pressing.
///  - **At finish**: complete artifacts are written — a `transcript.json`
///    snapshot and `insights.json` beside the audio masters, plus
///    session-named copies in the user's chosen folder next to the `.m4a`.
///
/// Unlike audio, the transcript is not written live to both destinations: it is
/// small enough that copying it at finish is instant, and the live copy in the
/// always-on backup folder already bounds crash loss. A failure writing to the
/// user's folder is reported as a warning and never affects the backup copy.
public final class TranscriptRecorder: @unchecked Sendable {
    public let sessionName: String
    private let liveDirectory: URL?
    private let exportRoots: [URL]
    private let log: TranscriptLog?
    private let warningsLock = NSLock()
    private var warningsStorage: [String] = []

    public var warnings: [String] {
        warningsLock.lock()
        defer { warningsLock.unlock() }
        return warningsStorage
    }

    /// - Parameters:
    ///   - sessionName: names the artifacts copied into `exportRoots`.
    ///   - liveDirectory: session directory receiving the append-only log,
    ///     normally the backup destination's.
    ///   - exportRoots: folders receiving complete, session-named artifacts at
    ///     finish (normally the user's chosen folder).
    public init(sessionName: String, liveDirectory: URL?, exportRoots: [URL]) {
        self.sessionName = sessionName
        self.liveDirectory = liveDirectory
        self.exportRoots = exportRoots
        if let liveDirectory {
            do {
                log = try TranscriptLog(directory: liveDirectory)
            } catch {
                log = nil
                warningsStorage.append(
                    "Could not start the transcript log: \(error.localizedDescription)"
                )
            }
        } else {
            log = nil
        }
    }

    /// Appends one utterance to the live log. Failures are recorded once and
    /// never surfaced to the recording path.
    public func append(_ utterance: Utterance) {
        guard let log else { return }
        do {
            try log.append(utterance)
        } catch {
            noteWarning("Could not write to the transcript log: \(error.localizedDescription)")
        }
    }

    /// Writes the complete artifacts and closes the live log.
    public func finish(
        utterances: [Utterance],
        summary: String,
        suggestions: [Suggestion],
        updatedAt: Date
    ) {
        log?.close()

        let transcript = InsightsPersistence.TranscriptFile(utterances: utterances)
        let insights = InsightsPersistence.InsightsFile(
            summary: summary, suggestions: suggestions, updatedAt: updatedAt
        )

        if let liveDirectory {
            write(
                transcript,
                to: liveDirectory.appendingPathComponent(InsightsPersistence.transcriptFileName)
            )
            write(
                insights,
                to: liveDirectory.appendingPathComponent(InsightsPersistence.insightsFileName)
            )
        }

        guard !utterances.isEmpty else { return }
        // The user's folder receives ready-to-read artifacts named after the
        // recording, so the transcript sits beside its .m4a without the user
        // having to export anything.
        let content = TranscriptExporter.Content(
            title: sessionName,
            recordedAt: utterances.first?.timestamp,
            utterances: utterances,
            summary: summary,
            suggestions: suggestions
        )
        let text = TranscriptExporter.export(
            content, format: .plainText, options: TranscriptExporter.Options()
        )
        for root in exportRoots {
            writeText(
                text, to: root.appendingPathComponent("\(sessionName).transcript.txt")
            )
            write(
                transcript,
                to: root.appendingPathComponent("\(sessionName).transcript.json")
            )
        }
    }

    // MARK: - Writing

    private func write<T: Encodable>(_ value: T, to url: URL) {
        do {
            try InsightsPersistence.write(value, to: url)
        } catch {
            noteWarning(
                "Could not write \(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    private func writeText(_ text: String, to url: URL) {
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch {
            noteWarning(
                "Could not write \(url.lastPathComponent): \(error.localizedDescription)"
            )
        }
    }

    private func noteWarning(_ message: String) {
        warningsLock.lock()
        defer { warningsLock.unlock() }
        guard !warningsStorage.contains(message) else { return }
        warningsStorage.append(message)
    }
}
