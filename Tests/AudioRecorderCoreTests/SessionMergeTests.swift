import AVFoundation
import XCTest
@testable import AudioRecorderCore

/// Exercises the offline merge: two tracks captured at different sample rates,
/// from unrelated clocks, with different start times and lengths.
final class SessionMergeTests: XCTestCase {
    private var root: URL!
    private let ticksPerSecond = CaptureTrack.hostTicksPerSecond()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MergeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Writes a constant-amplitude stereo CAF and returns its file name.
    private func writeTone(
        name: String,
        amplitude: Float,
        seconds: Double,
        sampleRate: Double,
        finalize: Bool = true
    ) throws -> String {
        let writer = try CAFWriter(
            url: root.appendingPathComponent(name),
            sampleRate: sampleRate,
            channels: 2
        )
        let frames = Int(seconds * sampleRate)
        let chunk = 4096
        var buffer = [Float](repeating: amplitude, count: chunk * 2)
        var remaining = frames
        while remaining > 0 {
            let n = min(chunk, remaining)
            try buffer.withUnsafeBufferPointer {
                try writer.append($0.baseAddress!, frameCount: n)
            }
            remaining -= n
        }
        if finalize {
            try writer.finalize()
        } else {
            writer.sync()
        }
        return name
    }

    private func readOutput(_ url: URL) throws -> (AVAudioPCMBuffer, Double) {
        let file = try AVAudioFile(
            forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true
        )
        let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        )!
        try file.read(into: buffer)
        return (buffer, file.processingFormat.sampleRate)
    }

    /// Mean absolute amplitude of the left channel over a time window.
    private func meanAmplitude(
        _ buffer: AVAudioPCMBuffer, rate: Double, from: Double, to: Double
    ) -> Float {
        let data = buffer.floatChannelData![0]
        let start = Int(from * rate)
        let end = min(Int(to * rate), Int(buffer.frameLength))
        guard end > start else { return 0 }
        var sum: Float = 0
        for frame in start..<end {
            sum += abs(data[frame * 2])
        }
        return sum / Float(end - start)
    }

    /// A 24 kHz mic track and a 48 kHz system track must merge without
    /// downsampling the system audio and without desyncing.
    func testRateMismatchMergesAtHighestRate() throws {
        let micSegment = try writeTone(
            name: "mic_001.caf", amplitude: 0.25, seconds: 2.0, sampleRate: 24_000
        )
        let sysSegment = try writeTone(
            name: "system_001.caf", amplitude: 0.25, seconds: 2.0, sampleRate: 48_000
        )
        let anchor = UInt64(1_000 * ticksPerSecond)
        var manifest = SessionManifest(
            name: "mixed",
            micName: "Bluetooth Mic",
            tracks: [
                SessionManifest.Track(
                    label: "mic", sampleRate: 24_000, channels: 2,
                    anchorHostTime: anchor, hostTicksPerSecond: ticksPerSecond,
                    segments: [micSegment]
                ),
                SessionManifest.Track(
                    label: "system", sampleRate: 48_000, channels: 2,
                    anchorHostTime: anchor, hostTicksPerSecond: ticksPerSecond,
                    segments: [sysSegment]
                ),
            ]
        )
        manifest.status = .complete
        try manifest.save(to: root)

        let output = root.appendingPathComponent("out.m4a")
        try SessionEncoder.encode(sessionDirectory: root, manifest: manifest, outputURL: output)

        let (buffer, rate) = try readOutput(output)
        // Rendered at the higher rate: system audio is not degraded.
        XCTAssertEqual(rate, 48_000)
        // Duration follows the tracks (both 2 s), allowing for AAC padding.
        XCTAssertEqual(Double(buffer.frameLength) / rate, 2.0, accuracy: 0.1)
        // Both sources summed: 0.25 + 0.25.
        XCTAssertEqual(meanAmplitude(buffer, rate: rate, from: 0.5, to: 1.5), 0.5, accuracy: 0.05)
    }

    /// A track whose anchor is later must be offset by exactly that much, so
    /// the sources stay in sync instead of both starting at zero.
    func testLaterAnchorIsOffsetOnTheTimeline() throws {
        let micSegment = try writeTone(
            name: "mic_001.caf", amplitude: 0.25, seconds: 2.0, sampleRate: 48_000
        )
        let sysSegment = try writeTone(
            name: "system_001.caf", amplitude: 0.25, seconds: 1.0, sampleRate: 48_000
        )
        let base = UInt64(500 * ticksPerSecond)
        // System audio started one second after the mic.
        let systemAnchor = base + UInt64(1.0 * ticksPerSecond)
        var manifest = SessionManifest(
            name: "offset",
            micName: "Mic",
            tracks: [
                SessionManifest.Track(
                    label: "mic", sampleRate: 48_000, channels: 2,
                    anchorHostTime: base, hostTicksPerSecond: ticksPerSecond,
                    segments: [micSegment]
                ),
                SessionManifest.Track(
                    label: "system", sampleRate: 48_000, channels: 2,
                    anchorHostTime: systemAnchor, hostTicksPerSecond: ticksPerSecond,
                    segments: [sysSegment]
                ),
            ]
        )
        manifest.status = .complete
        try manifest.save(to: root)

        let output = root.appendingPathComponent("out.m4a")
        try SessionEncoder.encode(sessionDirectory: root, manifest: manifest, outputURL: output)

        let (buffer, rate) = try readOutput(output)
        // First second: mic only.
        XCTAssertEqual(meanAmplitude(buffer, rate: rate, from: 0.2, to: 0.8), 0.25, accuracy: 0.05)
        // Second second: mic plus system audio.
        XCTAssertEqual(meanAmplitude(buffer, rate: rate, from: 1.2, to: 1.8), 0.5, accuracy: 0.05)
    }

    /// Tracks of different lengths must merge up to the longest one.
    func testUnevenTrackLengthsMergeToLongest() throws {
        let micSegment = try writeTone(
            name: "mic_001.caf", amplitude: 0.3, seconds: 3.0, sampleRate: 48_000
        )
        let sysSegment = try writeTone(
            name: "system_001.caf", amplitude: 0.3, seconds: 1.0, sampleRate: 48_000
        )
        let anchor = UInt64(10 * ticksPerSecond)
        var manifest = SessionManifest(
            name: "uneven",
            micName: "Mic",
            tracks: [
                SessionManifest.Track(
                    label: "mic", sampleRate: 48_000, channels: 2,
                    anchorHostTime: anchor, hostTicksPerSecond: ticksPerSecond,
                    segments: [micSegment]
                ),
                SessionManifest.Track(
                    label: "system", sampleRate: 48_000, channels: 2,
                    anchorHostTime: anchor, hostTicksPerSecond: ticksPerSecond,
                    segments: [sysSegment]
                ),
            ]
        )
        manifest.status = .complete
        try manifest.save(to: root)

        let output = root.appendingPathComponent("out.m4a")
        try SessionEncoder.encode(sessionDirectory: root, manifest: manifest, outputURL: output)

        let (buffer, rate) = try readOutput(output)
        // Full length of the longer track is preserved.
        XCTAssertEqual(Double(buffer.frameLength) / rate, 3.0, accuracy: 0.15)
        // Overlap region has both; tail has only the mic.
        XCTAssertEqual(meanAmplitude(buffer, rate: rate, from: 0.2, to: 0.8), 0.6, accuracy: 0.06)
        XCTAssertEqual(meanAmplitude(buffer, rate: rate, from: 2.0, to: 2.8), 0.3, accuracy: 0.06)
    }

    /// Multiple segments per track are concatenated in manifest order.
    func testMultipleSegmentsAreConcatenated() throws {
        let first = try writeTone(
            name: "mic_001.caf", amplitude: 0.2, seconds: 1.0, sampleRate: 48_000
        )
        let second = try writeTone(
            name: "mic_002.caf", amplitude: 0.6, seconds: 1.0, sampleRate: 48_000
        )
        var manifest = SessionManifest(
            name: "segments",
            micName: "Mic",
            tracks: [
                SessionManifest.Track(
                    label: "mic", sampleRate: 48_000, channels: 2,
                    anchorHostTime: UInt64(ticksPerSecond),
                    hostTicksPerSecond: ticksPerSecond,
                    segments: [first, second]
                )
            ]
        )
        manifest.status = .complete
        try manifest.save(to: root)

        let output = root.appendingPathComponent("out.m4a")
        try SessionEncoder.encode(sessionDirectory: root, manifest: manifest, outputURL: output)

        let (buffer, rate) = try readOutput(output)
        XCTAssertEqual(Double(buffer.frameLength) / rate, 2.0, accuracy: 0.1)
        XCTAssertEqual(meanAmplitude(buffer, rate: rate, from: 0.2, to: 0.8), 0.2, accuracy: 0.05)
        XCTAssertEqual(meanAmplitude(buffer, rate: rate, from: 1.2, to: 1.8), 0.6, accuracy: 0.05)
    }
}
