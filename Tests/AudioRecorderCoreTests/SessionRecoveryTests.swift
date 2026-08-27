import AVFoundation
import XCTest
@testable import AudioRecorderCore

final class SessionRecoveryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SessionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testManifestRoundTrip() throws {
        var manifest = SessionManifest(
            name: "test_session",
            sampleRate: 48_000,
            channels: 4,
            micName: "Test Mic",
            systemAudio: true
        )
        // ISO8601 stores whole seconds; use a whole-second date for exact equality.
        manifest.createdAt = Date(timeIntervalSince1970: 1_756_300_000)
        manifest.segments = ["segment_001.caf"]
        try manifest.save(to: root)
        let loaded = try SessionManifest.load(from: root)
        XCTAssertEqual(loaded, manifest)
        XCTAssertEqual(loaded.status, .recording)
    }

    func testSessionWriterProducesSegmentsAndManifest() throws {
        let writer = try SessionWriter(
            destinationRoot: root,
            sessionName: "session_a",
            sampleRate: 1000,
            channels: 2,
            micName: nil,
            systemAudio: true,
            segmentDuration: 1,  // 1000 frames per segment: forces rolling
            syncInterval: 0.5
        )
        let chunk = [Float](repeating: 0.25, count: 500 * 2)
        // 2500 frames -> segments of 1000/1000/500.
        for _ in 0..<5 {
            try chunk.withUnsafeBufferPointer { buffer in
                try writer.append(buffer.baseAddress!, frameCount: 500)
            }
        }
        try writer.finish()

        let manifest = try SessionManifest.load(from: writer.sessionDirectory)
        XCTAssertEqual(manifest.status, .complete)
        XCTAssertEqual(manifest.segments.count, 3)
        for segment in manifest.segments {
            let url = writer.sessionDirectory.appendingPathComponent(segment)
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
            XCTAssertGreaterThan(file.length, 0)
        }
    }

    func testRecoveryScanFindsInterruptedSessionsOnly() throws {
        // Interrupted session: manifest left in .recording state with one segment.
        let crashedDir = root.appendingPathComponent("crashed_session")
        try FileManager.default.createDirectory(at: crashedDir, withIntermediateDirectories: true)
        var crashed = SessionManifest(
            name: "crashed_session",
            sampleRate: 44_100,
            channels: 2,
            micName: nil,
            systemAudio: true
        )
        crashed.segments = ["segment_001.caf"]
        try crashed.save(to: crashedDir)
        let caf = try CAFWriter(
            url: crashedDir.appendingPathComponent("segment_001.caf"),
            sampleRate: 44_100,
            channels: 2
        )
        let tone = [Float](repeating: 0.5, count: 44_100 * 2)
        try tone.withUnsafeBufferPointer { buffer in
            try caf.append(buffer.baseAddress!, frameCount: 44_100)
        }
        caf.sync()  // crash: no finalize

        // Completed session: should not be picked up.
        let completeDir = root.appendingPathComponent("complete_session")
        try FileManager.default.createDirectory(at: completeDir, withIntermediateDirectories: true)
        var complete = SessionManifest(
            name: "complete_session",
            sampleRate: 44_100,
            channels: 2,
            micName: nil,
            systemAudio: true
        )
        complete.status = .complete
        try complete.save(to: completeDir)

        let items = RecoveryManager.scan(root: root)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items.first?.manifest.name, "crashed_session")
        XCTAssertEqual(items.first!.estimatedDuration, 1.0, accuracy: 0.5)

        // Recover: encodes an .m4a and marks complete.
        let output = try RecoveryManager.recover(items.first!)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        let encoded = try AVAudioFile(forReading: output)
        XCTAssertGreaterThan(encoded.length, 0)

        XCTAssertTrue(RecoveryManager.scan(root: root).isEmpty)
    }

    func testEncoderMixes4ChannelsToStereo() throws {
        let sessionDir = root.appendingPathComponent("mix_session")
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)
        var manifest = SessionManifest(
            name: "mix_session",
            sampleRate: 44_100,
            channels: 4,
            micName: "mic",
            systemAudio: true
        )
        manifest.segments = ["segment_001.caf"]

        let caf = try CAFWriter(
            url: sessionDir.appendingPathComponent("segment_001.caf"),
            sampleRate: 44_100,
            channels: 4
        )
        // mic pair at 0.25, system pair at 0.25: mix should be ~0.5.
        let frameCount = 44_100
        var frames = [Float](repeating: 0, count: frameCount * 4)
        for i in 0..<(frameCount * 4) { frames[i] = 0.25 }
        try frames.withUnsafeBufferPointer { buffer in
            try caf.append(buffer.baseAddress!, frameCount: frameCount)
        }
        try caf.finalize()
        try manifest.save(to: sessionDir)

        let output = sessionDir.appendingPathComponent("out.m4a")
        try SessionEncoder.encode(sessionDirectory: sessionDir, manifest: manifest, outputURL: output)

        let encoded = try AVAudioFile(forReading: output, commonFormat: .pcmFormatFloat32, interleaved: true)
        XCTAssertEqual(encoded.processingFormat.channelCount, 2)
        let buffer = AVAudioPCMBuffer(
            pcmFormat: encoded.processingFormat,
            frameCapacity: AVAudioFrameCount(encoded.length)
        )!
        try encoded.read(into: buffer)
        // AAC is lossy and adds priming; check mid-file average amplitude.
        let data = buffer.floatChannelData![0]
        let mid = Int(buffer.frameLength) / 2
        var sum: Float = 0
        for i in (mid - 100)..<(mid + 100) { sum += abs(data[i * 2]) }
        XCTAssertEqual(sum / 200, 0.5, accuracy: 0.05)
    }
}
