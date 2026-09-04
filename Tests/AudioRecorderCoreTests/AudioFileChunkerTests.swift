import AVFoundation
import XCTest
@testable import AudioRecorderCore

final class AudioFileChunkerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChunkerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    /// A tone rather than silence: silence is a legitimate "no speech" case and
    /// makes conversion bugs invisible.
    private func makeToneFile(
        seconds: Double,
        sampleRate: Double = 44_100,
        channels: AVAudioChannelCount = 2
    ) throws -> URL {
        let format = try XCTUnwrap(
            AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)
        )
        let url = root.appendingPathComponent("tone-\(UUID().uuidString).caf")
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(seconds * sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(channels) {
            for frame in 0..<Int(frames) {
                data[channel][frame] = 0.25 * sinf(
                    2 * .pi * 440 * Float(frame) / Float(sampleRate)
                )
            }
        }
        try file.write(from: buffer)
        return url
    }

    private func collect(
        _ url: URL, maxDuration: TimeInterval, pacing: AudioFileChunker.Pacing = .unpaced
    ) async throws -> [Data] {
        var chunks: [Data] = []
        for try await chunk in AudioFileChunker.chunks(
            of: url, maxDuration: maxDuration, pacing: pacing
        ) {
            chunks.append(chunk)
        }
        return chunks
    }

    private func seconds(ofPCM chunks: [Data]) -> Double {
        let bytes = chunks.reduce(0) { $0 + $1.count }
        return Double(bytes) / (AudioFileChunker.outputSampleRate * 2)
    }

    // MARK: - Chunking

    func testChunksAreUniformAndSixteenKilohertzMono() async throws {
        let url = try makeToneFile(seconds: 2)
        let chunks = try await collect(url, maxDuration: 10)

        XCTAssertFalse(chunks.isEmpty)
        // Every chunk but the tail is exactly 100 ms, per Transcribe's guidance
        // that chunks be uniform and 50–200 ms.
        for chunk in chunks.dropLast() {
            XCTAssertEqual(chunk.count, AudioFileChunker.chunkBytes)
        }
        XCTAssertLessThanOrEqual(chunks.last?.count ?? 0, AudioFileChunker.chunkBytes)
        // Chunks are little-endian Int16 pairs, so an even byte count matters.
        XCTAssertTrue(chunks.allSatisfy { $0.count % 2 == 0 })
        XCTAssertEqual(seconds(ofPCM: chunks), 2, accuracy: 0.1)
    }

    func testWindowBoundsHowMuchIsRead() async throws {
        let url = try makeToneFile(seconds: 4)
        let chunks = try await collect(url, maxDuration: 1)
        XCTAssertEqual(seconds(ofPCM: chunks), 1, accuracy: 0.15)
    }

    func testMonoSourceIsSupported() async throws {
        let url = try makeToneFile(seconds: 1, sampleRate: 16_000, channels: 1)
        let chunks = try await collect(url, maxDuration: 10)
        XCTAssertEqual(seconds(ofPCM: chunks), 1, accuracy: 0.1)
    }

    func testUnreadableFileThrows() async throws {
        let missing = root.appendingPathComponent("nope.m4a")
        do {
            _ = try await collect(missing, maxDuration: 5)
            XCTFail("expected an error for a file that does not exist")
        } catch {
            // Expected.
        }
    }

    // MARK: - Pacing

    /// Pacing exists so a replay does not fire-hose the service. Asserting only
    /// a lower bound keeps this robust on a loaded CI runner.
    func testRealTimePacingSlowsDeliveryDown() async throws {
        let url = try makeToneFile(seconds: 1)
        let start = ContinuousClock.now
        _ = try await collect(url, maxDuration: 0.5, pacing: .realTime)
        let elapsed = ContinuousClock.now - start
        XCTAssertGreaterThan(elapsed, .milliseconds(300))
    }

    func testMultiplePacingIsFasterThanRealTime() async throws {
        let url = try makeToneFile(seconds: 1)
        let start = ContinuousClock.now
        _ = try await collect(url, maxDuration: 1, pacing: .multiple(4))
        let elapsed = ContinuousClock.now - start
        XCTAssertLessThan(elapsed, .milliseconds(900))
    }

    // MARK: - Head file

    func testHeadPassesShortFilesThroughUntouched() throws {
        let url = try makeToneFile(seconds: 1)
        let head = try AudioFileChunker.head(of: url, maxDuration: 60)
        XCTAssertEqual(head.url, url)
        XCTAssertFalse(head.isTemporary)
    }

    func testHeadTrimsLongFilesIntoATemporaryCopy() throws {
        let url = try makeToneFile(seconds: 3)
        let head = try AudioFileChunker.head(of: url, maxDuration: 1)
        defer { if head.isTemporary { try? FileManager.default.removeItem(at: head.url) } }

        XCTAssertTrue(head.isTemporary)
        XCTAssertNotEqual(head.url, url)
        let trimmed = try AVAudioFile(forReading: head.url)
        let duration = Double(trimmed.length) / trimmed.processingFormat.sampleRate
        XCTAssertEqual(duration, 1, accuracy: 0.15)
        XCTAssertEqual(trimmed.processingFormat.channelCount, 1)
    }
}
