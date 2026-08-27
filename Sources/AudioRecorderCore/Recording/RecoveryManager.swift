import Foundation

/// Finds and recovers recording sessions that were interrupted by a crash.
///
/// A session directory whose manifest is still `.recording` at launch was
/// never finalized. Because segments are CAF files with valid-to-EOF data
/// chunks, all captured audio is readable as-is — recovery just runs the
/// normal encode step over the existing segments.
public enum RecoveryManager {
    public struct RecoveryItem: Identifiable, Sendable {
        public var id: String { directory.path }
        public let directory: URL
        public let manifest: SessionManifest

        /// Approximate recorded duration, derived from segment sizes on disk.
        public var estimatedDuration: TimeInterval {
            let bytesPerFrame = Double(manifest.channels * 2)
            var totalBytes = 0.0
            for segment in manifest.segments {
                let url = directory.appendingPathComponent(segment)
                if let size = try? FileManager.default
                    .attributesOfItem(atPath: url.path)[.size] as? Int {
                    totalBytes += Double(max(0, size - 4096))  // minus approx header
                }
            }
            return totalBytes / (bytesPerFrame * manifest.sampleRate)
        }
    }

    /// Scans a destination root for interrupted sessions.
    public static func scan(root: URL) -> [RecoveryItem] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        ) else { return [] }

        var items: [RecoveryItem] = []
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let manifest = try? SessionManifest.load(from: entry),
                  manifest.status == .recording
            else { continue }
            items.append(RecoveryItem(directory: entry, manifest: manifest))
        }
        return items.sorted { $0.manifest.createdAt < $1.manifest.createdAt }
    }

    /// Encodes an interrupted session to `.m4a` and marks it complete.
    /// Returns the encoded file URL.
    @discardableResult
    public static func recover(_ item: RecoveryItem) throws -> URL {
        let outputURL = item.directory.appendingPathComponent("\(item.manifest.name).m4a")
        try SessionEncoder.encode(
            sessionDirectory: item.directory,
            manifest: item.manifest,
            outputURL: outputURL
        )
        var manifest = item.manifest
        manifest.status = .complete
        try manifest.save(to: item.directory)
        return outputURL
    }

    /// Marks an interrupted session as discarded (audio files are kept).
    public static func discard(_ item: RecoveryItem) throws {
        var manifest = item.manifest
        manifest.status = .discarded
        try manifest.save(to: item.directory)
    }
}
