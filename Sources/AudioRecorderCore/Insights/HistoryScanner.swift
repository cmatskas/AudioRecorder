import Foundation

/// One past recording, discovered from the backup folder's session
/// directories. Read-only: History never mutates session contents.
public struct HistoryItem: Identifiable, Equatable, Sendable {
    public let id: String
    public let directory: URL
    public let name: String
    public let createdAt: Date
    public let micName: String?
    /// The finished merged recording, if encoding completed.
    public let audioURL: URL?
    public let hasTranscript: Bool
    public let hasInsights: Bool

    public init(
        directory: URL,
        name: String,
        createdAt: Date,
        micName: String?,
        audioURL: URL?,
        hasTranscript: Bool,
        hasInsights: Bool
    ) {
        id = directory.path
        self.directory = directory
        self.name = name
        self.createdAt = createdAt
        self.micName = micName
        self.audioURL = audioURL
        self.hasTranscript = hasTranscript
        self.hasInsights = hasInsights
    }
}

public enum HistoryScanner {
    /// Completed sessions under `root`, newest first. Interrupted sessions are
    /// excluded — they belong to the recovery flow, not history.
    public static func scan(root: URL) -> [HistoryItem] {
        let fileManager = FileManager.default
        guard
            let entries = try? fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles
            )
        else { return [] }

        var items: [HistoryItem] = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let manifest = try? SessionManifest.load(from: entry),
                  manifest.status == .complete
            else { continue }

            let audio = entry.appendingPathComponent("\(manifest.name).m4a")
            let transcript = entry.appendingPathComponent(InsightsPersistence.transcriptFileName)
            let insights = entry.appendingPathComponent(InsightsPersistence.insightsFileName)
            items.append(
                HistoryItem(
                    directory: entry,
                    name: manifest.name,
                    createdAt: manifest.createdAt,
                    micName: manifest.micName,
                    audioURL: fileManager.fileExists(atPath: audio.path) ? audio : nil,
                    hasTranscript: fileManager.fileExists(atPath: transcript.path),
                    hasInsights: fileManager.fileExists(atPath: insights.path)
                )
            )
        }
        return items.sorted { $0.createdAt > $1.createdAt }
    }
}
