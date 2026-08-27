import AVFoundation
import XCTest
@testable import AudioRecorderCore

final class CAFWriterTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CAFWriterTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func sineFrames(frames: Int, channels: Int, sampleRate: Double) -> [Float] {
        var data = [Float](repeating: 0, count: frames * channels)
        for frame in 0..<frames {
            let sample = Float(sin(2.0 * .pi * 440.0 * Double(frame) / sampleRate)) * 0.5
            for channel in 0..<channels {
                data[frame * channels + channel] = sample
            }
        }
        return data
    }

    func testFinalizedFileRoundTrip() throws {
        let url = tempDir.appendingPathComponent("finalized.caf")
        let writer = try CAFWriter(url: url, sampleRate: 48_000, channels: 2)
        let input = sineFrames(frames: 4800, channels: 2, sampleRate: 48_000)
        try input.withUnsafeBufferPointer { buffer in
            try writer.append(buffer.baseAddress!, frameCount: 4800)
        }
        try writer.finalize()

        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
        XCTAssertEqual(file.fileFormat.channelCount, 2)
        XCTAssertEqual(file.fileFormat.sampleRate, 48_000)
        XCTAssertEqual(file.length, 4800)

        let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: 4800
        )!
        try file.read(into: buffer)
        XCTAssertEqual(Int(buffer.frameLength), 4800)
        let data = buffer.floatChannelData![0]
        // Compare a few samples with int16 quantization tolerance.
        for index in [0, 100, 2400, 9598] {
            XCTAssertEqual(data[index], input[index], accuracy: 2.0 / 32767.0)
        }
    }

    func testUnfinalizedFileIsReadableAfterSimulatedCrash() throws {
        let url = tempDir.appendingPathComponent("crashed.caf")
        var writer: CAFWriter? = try CAFWriter(url: url, sampleRate: 44_100, channels: 4)
        let frames = 44_100  // 1 second
        let input = sineFrames(frames: frames, channels: 4, sampleRate: 44_100)
        try input.withUnsafeBufferPointer { buffer in
            try writer!.append(buffer.baseAddress!, frameCount: frames)
        }
        writer!.sync()
        // Simulate a crash: the writer is torn down without finalize(),
        // leaving the data chunk size field at -1.
        writer = nil

        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: true)
        XCTAssertEqual(file.fileFormat.channelCount, 4)
        XCTAssertEqual(file.fileFormat.sampleRate, 44_100)
        XCTAssertEqual(file.length, AVAudioFramePosition(frames))

        let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(frames)
        )!
        try file.read(into: buffer)
        XCTAssertEqual(Int(buffer.frameLength), frames)
        let data = buffer.floatChannelData![0]
        XCTAssertEqual(data[400], input[400], accuracy: 2.0 / 32767.0)
    }

    func testAppendAfterFinalizeThrows() throws {
        let url = tempDir.appendingPathComponent("closed.caf")
        let writer = try CAFWriter(url: url, sampleRate: 48_000, channels: 2)
        try writer.finalize()
        let silence = [Float](repeating: 0, count: 128)
        XCTAssertThrowsError(
            try silence.withUnsafeBufferPointer { buffer in
                try writer.append(buffer.baseAddress!, frameCount: 64)
            }
        )
    }
}
