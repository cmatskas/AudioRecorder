import AVFoundation
import XCTest
@testable import AudioRecorderCore

final class SessionRecoveryTests: XCTestCase {
    private var root: URL!
    private let ticksPerSecond = CaptureTrack.hostTicksPerSecond()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RecoveryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// The store plus per-source writers must produce one segment set per
    /// source, all registered in a single manifest.
    func testStoreAndTrackWritersProduceSegmentsAndManifest() throws {
        let store = try SessionStore(
            destinationRoot: root,
            sessionName: "session_a",
            micName: "Mic",
            tracks: [
                SessionManifest.Track(
                    label: "mic", sampleRate: 1000, channels: 2,
                    hostTicksPerSecond: ticksPerSecond
                ),
                SessionManifest.Track(
                    label: "system", sampleRate: 1000, channels: 2,
                    hostTicksPerSecond: ticksPerSecond
                ),
            ]
        )
        // 1 s segments at 1 kHz, so 2.5 s of audio rolls into 3 segments.
        let micWriter = try TrackWriter(
            store: store, label: "mic", sampleRate: 1000,
            segmentDuration: 1, syncInterval: 0.5
        )
        let sysWriter = try TrackWriter(
            store: store, label: "system", sampleRate: 1000,
            segmentDuration: 1, syncInterval: 0.5
        )
        let chunk = [Float](repeating: 0.25, count: 500 * 2)
        for _ in 0..<5 {
            try chunk.withUnsafeBufferPointer {
                try micWriter.append($0.baseAddress!, frameCount: 500)
            }
        }
        // The system source stalls early, as it would with no audio playing.
        try chunk.withUnsafeBufferPointer {
            try sysWriter.append($0.baseAddress!, frameCount: 500)
        }
        try micWriter.finish()
        try sysWriter.finish()
        try store.setStatus(.complete)

        let manifest = try SessionManifest.load(from: store.directory)
        XCTAssertEqual(manifest.status, .complete)
        XCTAssertEqual(manifest.tracks.count, 2)
        XCTAssertEqual(manifest.track(labeled: "mic")?.segments.count, 3)
        XCTAssertEqual(manifest.track(labeled: "system")?.segments.count, 1)

        for track in manifest.tracks {
            for segment in track.segments {
                let url = store.directory.appendingPathComponent(segment)
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), segment)
                let file = try AVAudioFile(
                    forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true
                )
                XCTAssertGreaterThan(file.length, 0, segment)
                XCTAssertEqual(file.processingFormat.channelCount, 2)
            }
        }
    }

    func testRecoveryScanIgnoresCompletedSessions() throws {
        let completeDir = root.appendingPathComponent("complete_session")
        try FileManager.default.createDirectory(at: completeDir, withIntermediateDirectories: true)
        var complete = SessionManifest(
            name: "complete_session", micName: nil,
            tracks: [
                SessionManifest.Track(
                    label: "mic", sampleRate: 48_000, channels: 2,
                    hostTicksPerSecond: ticksPerSecond
                )
            ]
        )
        complete.status = .complete
        try complete.save(to: completeDir)

        XCTAssertTrue(RecoveryManager.scan(root: root).isEmpty)
    }

    /// The crash case: two tracks of different lengths, neither finalized,
    /// manifest still marked `recording`. All captured audio must survive and
    /// recover into a correctly aligned render.
    func testRecoversInterruptedSessionWithUnevenStreams() throws {
        let dir = root.appendingPathComponent("crashed_session")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Mic: 2 s. System: 1 s. Both abandoned without finalize().
        func writeUnfinalized(_ name: String, seconds: Double, amplitude: Float) throws {
            let writer = try CAFWriter(
                url: dir.appendingPathComponent(name), sampleRate: 48_000, channels: 2
            )
            let frames = Int(seconds * 48_000)
            var buffer = [Float](repeating: amplitude, count: 4096 * 2)
            var remaining = frames
            while remaining > 0 {
                let n = min(4096, remaining)
                try buffer.withUnsafeBufferPointer {
                    try writer.append($0.baseAddress!, frameCount: n)
                }
                remaining -= n
            }
            writer.sync()  // crash: no finalize
        }
        try writeUnfinalized("mic_001.caf", seconds: 2.0, amplitude: 0.3)
        try writeUnfinalized("system_001.caf", seconds: 1.0, amplitude: 0.3)

        let anchor = UInt64(42 * ticksPerSecond)
        let manifest = SessionManifest(
            name: "crashed_session",
            micName: "Mic",
            tracks: [
                SessionManifest.Track(
                    label: "mic", sampleRate: 48_000, channels: 2,
                    anchorHostTime: anchor, hostTicksPerSecond: ticksPerSecond,
                    segments: ["mic_001.caf"]
                ),
                SessionManifest.Track(
                    label: "system", sampleRate: 48_000, channels: 2,
                    anchorHostTime: anchor, hostTicksPerSecond: ticksPerSecond,
                    segments: ["system_001.caf"]
                ),
            ]
        )
        try manifest.save(to: dir)

        let items = RecoveryManager.scan(root: root)
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item.manifest.name, "crashed_session")
        // Duration comes from the longest track.
        XCTAssertEqual(item.estimatedDuration, 2.0, accuracy: 0.2)

        let output = try RecoveryManager.recover(item)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))

        let file = try AVAudioFile(
            forReading: output, commonFormat: .pcmFormatFloat32, interleaved: true
        )
        XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 2.0, accuracy: 0.15)

        // Recovered sessions are marked complete and no longer offered.
        XCTAssertTrue(RecoveryManager.scan(root: root).isEmpty)
    }

    /// A v1 session (single pre-merged stream) must still recover.
    func testRecoversVersion1Session() throws {
        let dir = root.appendingPathComponent("v1_session")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let writer = try CAFWriter(
            url: dir.appendingPathComponent("segment_001.caf"), sampleRate: 48_000, channels: 4
        )
        var buffer = [Float](repeating: 0.2, count: 4096 * 4)
        var remaining = 48_000
        while remaining > 0 {
            let n = min(4096, remaining)
            try buffer.withUnsafeBufferPointer {
                try writer.append($0.baseAddress!, frameCount: n)
            }
            remaining -= n
        }
        writer.sync()

        let v1 = """
        {
          "channels" : 4, "createdAt" : "2026-08-27T21:39:30Z",
          "micName" : "AirPods", "name" : "v1_session", "sampleRate" : 48000,
          "segments" : [ "segment_001.caf" ], "status" : "recording",
          "systemAudio" : true, "version" : 1
        }
        """
        try v1.write(
            to: dir.appendingPathComponent(SessionManifest.filename),
            atomically: true, encoding: .utf8
        )

        let items = RecoveryManager.scan(root: root)
        XCTAssertEqual(items.count, 1)
        let output = try RecoveryManager.recover(try XCTUnwrap(items.first))
        let file = try AVAudioFile(forReading: output)
        XCTAssertGreaterThan(file.length, 0)
        XCTAssertTrue(RecoveryManager.scan(root: root).isEmpty)
    }
}
