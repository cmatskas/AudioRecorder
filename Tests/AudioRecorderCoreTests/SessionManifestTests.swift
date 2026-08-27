import XCTest
@testable import AudioRecorderCore

final class SessionManifestTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ManifestTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testVersion2RoundTrip() throws {
        var manifest = SessionManifest(
            name: "session",
            micName: "Test Mic",
            tracks: [
                SessionManifest.Track(
                    label: "mic", sampleRate: 24_000, channels: 2,
                    anchorHostTime: 111_222_333, hostTicksPerSecond: 1_000_000_000,
                    segments: ["mic_001.caf"]
                ),
                SessionManifest.Track(
                    label: "system", sampleRate: 48_000, channels: 2,
                    anchorHostTime: 111_222_999, hostTicksPerSecond: 1_000_000_000,
                    segments: ["system_001.caf"]
                ),
            ]
        )
        // ISO8601 stores whole seconds; use one for exact equality.
        manifest.createdAt = Date(timeIntervalSince1970: 1_756_300_000)
        try manifest.save(to: root)

        let loaded = try SessionManifest.load(from: root)
        XCTAssertEqual(loaded, manifest)
        XCTAssertEqual(loaded.version, 2)
        XCTAssertEqual(loaded.tracks.count, 2)
        XCTAssertEqual(loaded.mergedSampleRate, 48_000)
        XCTAssertEqual(loaded.track(labeled: "mic")?.sampleRate, 24_000)
    }

    /// Version 1 manifests described a single pre-merged stream at the top
    /// level. They must still load and recover.
    func testVersion1Migration() throws {
        let v1 = """
        {
          "channels" : 4,
          "createdAt" : "2026-08-27T21:39:30Z",
          "micName" : "AirPods Pro",
          "name" : "recording_2026-08-27_14-39-30",
          "sampleRate" : 24000,
          "segments" : [ "segment_001.caf", "segment_002.caf" ],
          "status" : "complete",
          "systemAudio" : true,
          "version" : 1
        }
        """
        try v1.write(
            to: root.appendingPathComponent(SessionManifest.filename),
            atomically: true, encoding: .utf8
        )

        let loaded = try SessionManifest.load(from: root)
        XCTAssertEqual(loaded.version, 1)
        XCTAssertEqual(loaded.name, "recording_2026-08-27_14-39-30")
        XCTAssertEqual(loaded.status, .complete)
        XCTAssertEqual(loaded.micName, "AirPods Pro")
        // Collapsed into a single "merged" track preserving rate and channels.
        XCTAssertEqual(loaded.tracks.count, 1)
        let track = try XCTUnwrap(loaded.tracks.first)
        XCTAssertEqual(track.label, "merged")
        XCTAssertEqual(track.sampleRate, 24_000)
        XCTAssertEqual(track.channels, 4)
        XCTAssertEqual(track.segments, ["segment_001.caf", "segment_002.caf"])
        XCTAssertEqual(track.anchorHostTime, 0)
    }

    /// A migrated manifest re-saves in the v2 shape without losing anything.
    func testMigratedManifestSavesAsVersion2Shape() throws {
        let v1 = """
        {
          "channels" : 2, "createdAt" : "2026-08-27T21:39:30Z",
          "name" : "old", "sampleRate" : 44100,
          "segments" : [ "segment_001.caf" ], "status" : "recording", "version" : 1
        }
        """
        try v1.write(
            to: root.appendingPathComponent(SessionManifest.filename),
            atomically: true, encoding: .utf8
        )
        var loaded = try SessionManifest.load(from: root)
        loaded.status = .complete
        try loaded.save(to: root)

        let reloaded = try SessionManifest.load(from: root)
        XCTAssertEqual(reloaded.status, .complete)
        XCTAssertEqual(reloaded.tracks.count, 1)
        XCTAssertEqual(reloaded.tracks.first?.sampleRate, 44_100)
        XCTAssertEqual(reloaded.tracks.first?.segments, ["segment_001.caf"])
    }
}
