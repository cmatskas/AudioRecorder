import Foundation

/// Renames a finished recording: the merged `.m4a` in every destination, the
/// transcript artifacts beside it, and the display name in the manifest.
///
/// One operation serves both callers — the automatic namer and the in-app rename
/// field — so there is a single place where "what a recording is called" is
/// defined. Renaming in Finder cannot do this: `HistoryScanner` finds a
/// session's audio as `<manifest.name>.m4a`, so a file renamed behind the app's
/// back disappears from History.
///
/// The session directory itself is deliberately **not** renamed. It keeps its
/// `recording_<timestamp>` name as a stable identity: it is the key History
/// items are identified by, the directory a live transcript log was opened in,
/// and the reason two recordings can never collide on disk.
///
/// Write order is chosen so an interruption cannot strand the audio:
/// the canonical `.m4a` moves first, the manifest is rewritten second (rolled
/// back if it fails), and the user-folder copies move last as best effort.
public enum SessionRenamer {
    /// Upper bound for a hand-typed name. Generated names get a much tighter
    /// budget (`RecordingTitler.maxLength`); this one only has to keep names
    /// sane and displayable.
    public static let manualNameLimit = 50

    public struct Request: Sendable {
        /// Session directory holding `session.json` and the canonical `.m4a`.
        public var sessionDirectory: URL
        /// The user's chosen folder, which holds a flat copy of the `.m4a` and
        /// the transcript exports. Nil when they never chose one.
        public var userDestinationRoot: URL?
        public var newName: String

        public init(sessionDirectory: URL, userDestinationRoot: URL?, newName: String) {
            self.sessionDirectory = sessionDirectory
            self.userDestinationRoot = userDestinationRoot
            self.newName = newName
        }
    }

    public struct Outcome: Sendable {
        /// The name actually applied, which may carry a disambiguating suffix.
        public var name: String
        public var backupAudioURL: URL?
        public var userAudioURL: URL?
        /// Non-fatal problems: a sidecar that could not be moved, say. The
        /// recording itself is consistent whenever `rename` returns.
        public var warnings: [String]
    }

    public enum RenameError: LocalizedError, Equatable {
        case invalidName(String)
        case nameTaken(String)
        case audioMoveFailed(String)
        case manifestWriteFailed(String)

        public var errorDescription: String? {
            switch self {
            case let .invalidName(reason): return reason
            case let .nameTaken(name): return "“\(name)” already exists. Choose another name."
            case let .audioMoveFailed(reason): return "Could not rename the recording: \(reason)"
            case let .manifestWriteFailed(reason):
                return "Could not update the recording's details: \(reason). The name was left unchanged."
            }
        }
    }

    // MARK: - Validation

    /// Checks a hand-typed name without touching the disk, so the UI can
    /// disable Save and explain why.
    ///
    /// Deliberately more permissive than `RecordingTitler.sanitize`: a user who
    /// types "Sync w/ Dana (draft)" should be told about the slash, not silently
    /// given something else.
    public static func validate(
        _ name: String, limit: Int = manualNameLimit
    ) -> Result<String, RenameError> {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return .failure(.invalidName("Enter a name."))
        }
        if trimmed.count > limit {
            return .failure(.invalidName("Use \(limit) characters or fewer."))
        }
        if trimmed.contains("/") || trimmed.contains(":") {
            return .failure(.invalidName("A name cannot contain “/” or “:”."))
        }
        if trimmed.hasPrefix(".") {
            return .failure(.invalidName("A name cannot start with a dot."))
        }
        if trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            return .failure(.invalidName("A name cannot contain control characters."))
        }
        return .success(trimmed)
    }

    // MARK: - Renaming

    /// - Parameters:
    ///   - allowSuffix: when true (automatic naming) a collision is resolved by
    ///     appending a number; when false (a person typing) it is reported, so
    ///     nobody is silently given a name they did not ask for.
    ///   - limit: length budget for the resulting name.
    @discardableResult
    public static func rename(
        _ request: Request,
        allowSuffix: Bool,
        limit: Int = manualNameLimit
    ) throws -> Outcome {
        let requested: String
        switch validate(request.newName, limit: limit) {
        case let .success(name): requested = name
        case let .failure(error): throw error
        }

        var manifest: SessionManifest
        do {
            manifest = try SessionManifest.load(from: request.sessionDirectory)
        } catch {
            throw RenameError.invalidName(
                "This recording has no session details on disk, so it cannot be renamed."
            )
        }

        let fileManager = FileManager.default
        let oldName = manifest.name
        let oldBackupAudio = request.sessionDirectory.appendingPathComponent("\(oldName).m4a")
        let oldUserAudio = request.userDestinationRoot?.appendingPathComponent("\(oldName).m4a")

        // Renaming to the current name is a no-op, not an error: auto-naming can
        // legitimately land on it, and the UI should not punish a stray Return.
        if requested == oldName {
            return Outcome(
                name: oldName,
                backupAudioURL: fileManager.fileExists(atPath: oldBackupAudio.path)
                    ? oldBackupAudio : nil,
                userAudioURL: oldUserAudio.flatMap {
                    fileManager.fileExists(atPath: $0.path) ? $0 : nil
                },
                warnings: []
            )
        }

        let searchRoots = [request.sessionDirectory, request.userDestinationRoot].compactMap { $0 }
        let finalName: String
        if isFree(requested, in: searchRoots) {
            finalName = requested
        } else if allowSuffix, let suffixed = firstFreeSuffixedName(
            base: requested, in: searchRoots, limit: limit
        ) {
            finalName = suffixed
        } else {
            throw RenameError.nameTaken(requested)
        }

        var warnings: [String] = []

        // 1. The canonical copy. If it fails, nothing else is touched.
        var newBackupAudio: URL?
        let backupTarget = request.sessionDirectory.appendingPathComponent("\(finalName).m4a")
        if fileManager.fileExists(atPath: oldBackupAudio.path) {
            do {
                try fileManager.moveItem(at: oldBackupAudio, to: backupTarget)
                newBackupAudio = backupTarget
            } catch {
                throw RenameError.audioMoveFailed(error.localizedDescription)
            }
        }

        // 2. The manifest, which is what makes the new name the recording's name.
        manifest.name = finalName
        do {
            try manifest.save(to: request.sessionDirectory)
        } catch {
            if let moved = newBackupAudio {
                try? fileManager.moveItem(at: moved, to: oldBackupAudio)
            }
            throw RenameError.manifestWriteFailed(error.localizedDescription)
        }

        // 3. The user's folder: best effort. The recording is already consistent.
        var newUserAudio: URL?
        if let root = request.userDestinationRoot {
            let audioSource = root.appendingPathComponent("\(oldName).m4a")
            let audioTarget = root.appendingPathComponent("\(finalName).m4a")
            if fileManager.fileExists(atPath: audioSource.path) {
                do {
                    try fileManager.moveItem(at: audioSource, to: audioTarget)
                    newUserAudio = audioTarget
                } catch {
                    warnings.append(
                        "Could not rename the copy in your folder: \(error.localizedDescription)"
                    )
                }
            }
            for suffix in [".transcript.txt", ".transcript.json"] {
                let source = root.appendingPathComponent("\(oldName)\(suffix)")
                guard fileManager.fileExists(atPath: source.path) else { continue }
                let target = root.appendingPathComponent("\(finalName)\(suffix)")
                do {
                    try fileManager.moveItem(at: source, to: target)
                } catch {
                    warnings.append(
                        "Could not rename \(source.lastPathComponent): \(error.localizedDescription)"
                    )
                }
            }
        }

        return Outcome(
            name: finalName,
            backupAudioURL: newBackupAudio,
            userAudioURL: newUserAudio,
            warnings: warnings
        )
    }

    // MARK: - Collisions

    private static func isFree(_ name: String, in roots: [URL]) -> Bool {
        let fileManager = FileManager.default
        for root in roots {
            let audio = root.appendingPathComponent("\(name).m4a")
            if fileManager.fileExists(atPath: audio.path) { return false }
        }
        return true
    }

    /// `Pricing Call` → `Pricing Call 2`, shortening the base as needed so the
    /// numbered name still fits the budget.
    private static func firstFreeSuffixedName(
        base: String, in roots: [URL], limit: Int
    ) -> String? {
        for number in 2...99 {
            let suffix = " \(number)"
            let room = limit - suffix.count
            guard room > 0 else { return nil }
            let trimmedBase = base.count > room
                ? String(base.prefix(room)).trimmingCharacters(in: CharacterSet(charactersIn: " -"))
                : base
            guard !trimmedBase.isEmpty else { return nil }
            let candidate = trimmedBase + suffix
            if isFree(candidate, in: roots) { return candidate }
        }
        return nil
    }
}
