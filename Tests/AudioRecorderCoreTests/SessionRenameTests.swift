import XCTest
@testable import AudioRecorderCore

/// Renaming touches real files in two places plus a manifest, and the whole
/// point is that they never disagree — so these tests work on disk.
final class SessionRenameTests: XCTestCase {
    private var root: URL!
    private var sessionDirectory: URL!
    private var userRoot: URL!

    private let originalName = "recording_2026-09-03_19-45-58"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RenameTests-\(UUID().uuidString)")
        sessionDirectory = root.appendingPathComponent("backup/\(originalName)", isDirectory: true)
        userRoot = root.appendingPathComponent("user", isDirectory: true)
        try FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userRoot, withIntermediateDirectories: true)
        try makeSession()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    private func makeSession(withUserArtifacts: Bool = true) throws {
        let manifest = SessionManifest(
            name: originalName,
            micName: "Test Mic",
            tracks: [
                SessionManifest.Track(
                    label: "mic", sampleRate: 48_000, channels: 2,
                    hostTicksPerSecond: 1_000_000_000, segments: ["mic_001.caf"]
                )
            ]
        )
        var complete = manifest
        complete.status = .complete
        try complete.save(to: sessionDirectory)
        try write("audio", to: sessionDirectory.appendingPathComponent("\(originalName).m4a"))
        try write("pcm", to: sessionDirectory.appendingPathComponent("mic_001.caf"))
        if withUserArtifacts {
            try write("audio", to: userRoot.appendingPathComponent("\(originalName).m4a"))
            try write("text", to: userRoot.appendingPathComponent("\(originalName).transcript.txt"))
            try write("{}", to: userRoot.appendingPathComponent("\(originalName).transcript.json"))
        }
    }

    private func write(_ contents: String, to url: URL) throws {
        try Data(contents.utf8).write(to: url, options: .atomic)
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    private func request(_ newName: String) -> SessionRenamer.Request {
        SessionRenamer.Request(
            sessionDirectory: sessionDirectory,
            userDestinationRoot: userRoot,
            newName: newName
        )
    }

    // MARK: - Happy path

    func testRenameMovesAudioAndUpdatesManifest() throws {
        let outcome = try SessionRenamer.rename(request("Pricing Call"), allowSuffix: false)

        XCTAssertEqual(outcome.name, "Pricing Call")
        XCTAssertTrue(outcome.warnings.isEmpty)
        XCTAssertTrue(exists(sessionDirectory.appendingPathComponent("Pricing Call.m4a")))
        XCTAssertFalse(exists(sessionDirectory.appendingPathComponent("\(originalName).m4a")))

        let manifest = try SessionManifest.load(from: sessionDirectory)
        XCTAssertEqual(manifest.name, "Pricing Call")
        // Chronological identity is kept, and so is the directory itself.
        XCTAssertEqual(manifest.originalName, originalName)
        XCTAssertEqual(sessionDirectory.lastPathComponent, originalName)
        // PCM masters are never renamed.
        XCTAssertTrue(exists(sessionDirectory.appendingPathComponent("mic_001.caf")))
    }

    func testRenameMovesUserFolderCopyAndTranscripts() throws {
        let outcome = try SessionRenamer.rename(request("Vendor Demo"), allowSuffix: false)

        XCTAssertEqual(outcome.userAudioURL, userRoot.appendingPathComponent("Vendor Demo.m4a"))
        XCTAssertTrue(exists(userRoot.appendingPathComponent("Vendor Demo.m4a")))
        XCTAssertTrue(exists(userRoot.appendingPathComponent("Vendor Demo.transcript.txt")))
        XCTAssertTrue(exists(userRoot.appendingPathComponent("Vendor Demo.transcript.json")))
        XCTAssertFalse(exists(userRoot.appendingPathComponent("\(originalName).m4a")))
    }

    /// Live Insights off means no transcript exports. Their absence is normal,
    /// not a problem to report.
    func testMissingSidecarsProduceNoWarnings() throws {
        try FileManager.default.removeItem(
            at: userRoot.appendingPathComponent("\(originalName).transcript.txt")
        )
        try FileManager.default.removeItem(
            at: userRoot.appendingPathComponent("\(originalName).transcript.json")
        )
        let outcome = try SessionRenamer.rename(request("Standup"), allowSuffix: false)
        XCTAssertTrue(outcome.warnings.isEmpty)
    }

    func testRenamingToTheSameNameIsANoOp() throws {
        let outcome = try SessionRenamer.rename(request(originalName), allowSuffix: false)
        XCTAssertEqual(outcome.name, originalName)
        XCTAssertTrue(exists(sessionDirectory.appendingPathComponent("\(originalName).m4a")))
    }

    /// A session whose encode never produced an `.m4a` can still be renamed.
    func testRenameWorksWithoutMergedAudio() throws {
        try FileManager.default.removeItem(
            at: sessionDirectory.appendingPathComponent("\(originalName).m4a")
        )
        try FileManager.default.removeItem(at: userRoot.appendingPathComponent("\(originalName).m4a"))
        let outcome = try SessionRenamer.rename(request("Recovered"), allowSuffix: false)
        XCTAssertNil(outcome.backupAudioURL)
        XCTAssertEqual(try SessionManifest.load(from: sessionDirectory).name, "Recovered")
    }

    // MARK: - Collisions

    func testAutomaticNamingDisambiguatesWithinBudget() throws {
        try write("other", to: userRoot.appendingPathComponent("Pricing Call.m4a"))

        let outcome = try SessionRenamer.rename(
            request("Pricing Call"), allowSuffix: true, limit: RecordingTitler.maxLength
        )
        XCTAssertEqual(outcome.name, "Pricing Call 2")
        XCTAssertLessThanOrEqual(outcome.name.count, RecordingTitler.maxLength)
        XCTAssertTrue(exists(sessionDirectory.appendingPathComponent("Pricing Call 2.m4a")))
    }

    /// A base name with no room for a suffix is shortened to make room, rather
    /// than blowing the budget.
    func testLongNameCollisionShortensBaseToFitSuffix() throws {
        try write("other", to: userRoot.appendingPathComponent("Quarterly Rev.m4a"))
        let outcome = try SessionRenamer.rename(
            request("Quarterly Rev"), allowSuffix: true, limit: RecordingTitler.maxLength
        )
        XCTAssertEqual(outcome.name, "Quarterly Re 2")
        XCTAssertLessThanOrEqual(outcome.name.count, RecordingTitler.maxLength)
    }

    func testShortNameCollisionKeepsWholeBase() throws {
        try write("other", to: userRoot.appendingPathComponent("Sync.m4a"))
        let outcome = try SessionRenamer.rename(
            request("Sync"), allowSuffix: true, limit: RecordingTitler.maxLength
        )
        XCTAssertEqual(outcome.name, "Sync 2")
    }

    func testManualRenameReportsConflictAndChangesNothing() throws {
        try write("other", to: userRoot.appendingPathComponent("Taken.m4a"))

        XCTAssertThrowsError(try SessionRenamer.rename(request("Taken"), allowSuffix: false)) { error in
            XCTAssertEqual(error as? SessionRenamer.RenameError, .nameTaken("Taken"))
        }
        XCTAssertTrue(exists(sessionDirectory.appendingPathComponent("\(originalName).m4a")))
        XCTAssertEqual(try SessionManifest.load(from: sessionDirectory).name, originalName)
    }

    // MARK: - Validation

    func testInvalidNamesAreRejectedAndNothingChanges() throws {
        let rejected = ["", "   ", "a/b", "10:30", ".hidden", String(repeating: "x", count: 51)]
        for name in rejected {
            XCTAssertThrowsError(
                try SessionRenamer.rename(request(name), allowSuffix: false),
                "expected \"\(name)\" to be rejected"
            )
        }
        XCTAssertTrue(exists(sessionDirectory.appendingPathComponent("\(originalName).m4a")))
        XCTAssertEqual(try SessionManifest.load(from: sessionDirectory).name, originalName)
    }

    func testValidateExplainsWhy() {
        XCTAssertNotNil(failureMessage(for: ""))
        XCTAssertEqual(failureMessage(for: "a/b"), "A name cannot contain “/” or “:”.")
        XCTAssertEqual(failureMessage(for: ".x"), "A name cannot start with a dot.")
        XCTAssertEqual(
            failureMessage(for: String(repeating: "x", count: 51)),
            "Use 50 characters or fewer."
        )
        XCTAssertNil(failureMessage(for: "Perfectly fine name"))
    }

    private func failureMessage(for name: String) -> String? {
        switch SessionRenamer.validate(name) {
        case .success: return nil
        case let .failure(error): return error.errorDescription
        }
    }

    func testRenameWithoutManifestFails() throws {
        try FileManager.default.removeItem(
            at: sessionDirectory.appendingPathComponent(SessionManifest.filename)
        )
        XCTAssertThrowsError(try SessionRenamer.rename(request("Nope"), allowSuffix: false))
    }

    // MARK: - Partial failure

    /// A read-only user folder must not stop the recording being renamed: the
    /// canonical copy and the manifest still agree, and the failure is a warning.
    func testUnwritableUserFolderYieldsWarningWithConsistentBackup() throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500], ofItemAtPath: userRoot.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: userRoot.path
            )
        }

        let outcome = try SessionRenamer.rename(request("Locked Out"), allowSuffix: false)
        XCTAssertFalse(outcome.warnings.isEmpty)
        XCTAssertTrue(exists(sessionDirectory.appendingPathComponent("Locked Out.m4a")))
        XCTAssertEqual(try SessionManifest.load(from: sessionDirectory).name, "Locked Out")
    }

    // MARK: - History

    /// The reason renaming goes through this type at all: History finds audio by
    /// the manifest's name.
    func testHistoryFindsRenamedRecording() throws {
        try SessionRenamer.rename(request("Board Review"), allowSuffix: false)

        let items = HistoryScanner.scan(root: sessionDirectory.deletingLastPathComponent())
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.name, "Board Review")
        XCTAssertEqual(items.first?.audioURL?.lastPathComponent, "Board Review.m4a")
    }
}
