import Foundation

/// Append-only transcript writer: one JSON object per line in
/// `transcript.jsonl`, plus a human-readable `transcript.txt` with speaker
/// prefixes.
///
/// Append-only for the same reason the audio segments are CAF with an
/// open-ended data chunk: a process killed mid-write leaves a file that is
/// readable up to the last complete line, with no repair step. Rewriting a
/// whole JSON document on every utterance would instead be O(n²) I/O over a
/// long meeting and would put the entire transcript at risk on each write.
///
/// Thread-safe; `append` may be called from any thread.
public final class TranscriptLog: @unchecked Sendable {
    public static let jsonlFileName = "transcript.jsonl"
    public static let textFileName = "transcript.txt"

    /// Bound on data loss if the machine dies: flush to stable storage at most
    /// this far behind the newest utterance.
    private static let syncInterval: TimeInterval = 5

    public let directory: URL
    private let jsonlHandle: FileHandle
    private let textHandle: FileHandle
    private let encoder: JSONEncoder
    private let lock = NSLock()
    private var lastSync = Date.distantPast
    private var closed = false

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        jsonlHandle = try Self.openForAppending(
            directory.appendingPathComponent(Self.jsonlFileName)
        )
        textHandle = try Self.openForAppending(
            directory.appendingPathComponent(Self.textFileName)
        )
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]  // never .prettyPrinted: one line per record
    }

    private static func openForAppending(_ url: URL) throws -> FileHandle {
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data().write(to: url, options: .atomic)
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        return handle
    }

    public func append(_ utterance: Utterance) throws {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }

        var line = try encoder.encode(utterance)
        line.append(0x0A)  // newline
        try jsonlHandle.write(contentsOf: line)

        let text = "\(utterance.speaker.displayName): \(utterance.text)\n"
        try textHandle.write(contentsOf: Data(text.utf8))

        if Date().timeIntervalSince(lastSync) >= Self.syncInterval {
            syncLocked()
        }
    }

    /// Flushes to stable storage. `F_FULLFSYNC` (not `fsync`) because on macOS
    /// only the former guarantees the drive has actually written the data.
    private func syncLocked() {
        fcntl(jsonlHandle.fileDescriptor, F_FULLFSYNC)
        fcntl(textHandle.fileDescriptor, F_FULLFSYNC)
        lastSync = Date()
    }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        syncLocked()
        try? jsonlHandle.close()
        try? textHandle.close()
        closed = true
    }

    deinit {
        close()
    }

    // MARK: - Reading

    /// Reads utterances from a JSONL transcript, skipping any trailing partial
    /// line left by a crash mid-write. Returns nil if there is no JSONL file.
    public static func readUtterances(in directory: URL) -> [Utterance]? {
        let url = directory.appendingPathComponent(jsonlFileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var utterances: [Utterance] = []
        for line in data.split(separator: 0x0A) {
            guard !line.isEmpty else { continue }
            // A torn final line simply fails to decode and is dropped.
            if let utterance = try? decoder.decode(Utterance.self, from: Data(line)) {
                utterances.append(utterance)
            }
        }
        return utterances
    }
}
