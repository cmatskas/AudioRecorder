import AVFoundation
import Foundation

/// Reads the beginning of a finished recording as the PCM shape transcription
/// wants: 16 kHz, mono, signed 16-bit little-endian, in uniform chunks.
///
/// Only the head of the recording is read. A conversation establishes its topic
/// in its first minutes, and naming is the only consumer here — so bounding the
/// window bounds both the wait and, for the cloud backend, the bill.
///
/// Chunk size and pacing follow Amazon Transcribe's streaming guidance (uniform
/// 50–200 ms chunks, a stream kept close to real time). `pacing` exists for that
/// reason and is irrelevant to the on-device path, which reads the file whole.
public enum AudioFileChunker {
    /// Matches `AnalysisFeed.outputSampleRate`: the rate the live path already
    /// streams, so both backends see identical audio.
    public static let outputSampleRate = 16_000.0
    /// 100 ms per chunk — the middle of the recommended range.
    public static let chunkFrames = 1_600
    public static var chunkBytes: Int { chunkFrames * MemoryLayout<Int16>.size }

    public enum Pacing: Sendable {
        /// As fast as the file can be read: for local consumers.
        case unpaced
        /// One chunk per chunk-duration of wall clock.
        case realTime
        /// A fixed multiple of real time (4 means four seconds of audio per
        /// second of wall clock).
        case multiple(Double)

        func delay(forChunkFrames frames: Int) -> Duration? {
            let seconds = Double(frames) / outputSampleRate
            switch self {
            case .unpaced:
                return nil
            case .realTime:
                return .seconds(seconds)
            case let .multiple(factor):
                guard factor > 0, factor.isFinite else { return nil }
                return .seconds(seconds / factor)
            }
        }
    }

    public enum ChunkerError: LocalizedError {
        case unreadable(String)
        case unsupportedFormat

        public var errorDescription: String? {
            switch self {
            case let .unreadable(reason): return "Could not read the recording: \(reason)"
            case .unsupportedFormat: return "The recording's audio format cannot be converted."
            }
        }
    }

    /// Head of `url`, converted and cut into chunks. The stream finishes at
        /// `maxDuration` or end of file, whichever comes first, and honours
    /// cancellation between chunks.
    public static func chunks(
        of url: URL,
        maxDuration: TimeInterval,
        pacing: Pacing = .unpaced
    ) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            let work = Task.detached(priority: .utility) {
                do {
                    try await produce(
                        url: url,
                        maxDuration: maxDuration,
                        pacing: pacing,
                        continuation: continuation
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in work.cancel() }
        }
    }

    private static func produce(
        url: URL,
        maxDuration: TimeInterval,
        pacing: Pacing,
        continuation: AsyncThrowingStream<Data, Error>.Continuation
    ) async throws {
        let reader = try Reader(url: url, maxDuration: maxDuration)
        var pending = Data()
        pending.reserveCapacity(chunkBytes * 2)

        while true {
            try Task.checkCancellation()
            guard let converted = try reader.nextConvertedBlock() else { break }
            pending.append(converted)
            while pending.count >= chunkBytes {
                let chunk = pending.prefix(chunkBytes)
                pending.removeFirst(chunkBytes)
                continuation.yield(Data(chunk))
                if let delay = pacing.delay(forChunkFrames: chunkFrames) {
                    try await Task.sleep(for: delay)
                }
                try Task.checkCancellation()
            }
        }
        // Tail: a partial final chunk is still speech worth transcribing.
        if !pending.isEmpty {
            continuation.yield(pending)
        }
    }

    // MARK: - Head file

    public struct HeadFile: Sendable {
        public let url: URL
        /// True when `url` is a temporary trim that the caller must delete.
        public let isTemporary: Bool
    }

    /// A file containing at most `maxDuration` of `url`, for consumers that take
    /// a URL rather than a chunk stream (Apple's speech recognizers).
    ///
    /// Short recordings are passed through untouched — no copy, nothing to clean
    /// up. Longer ones are trimmed into a 16 kHz mono WAV in the temporary
    /// directory, which the caller deletes.
    public static func head(of url: URL, maxDuration: TimeInterval) throws -> HeadFile {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            throw ChunkerError.unreadable(error.localizedDescription)
        }
        let duration = Double(file.length) / file.processingFormat.sampleRate
        if duration <= maxDuration {
            return HeadFile(url: url, isTemporary: false)
        }

        let reader = try Reader(url: url, maxDuration: maxDuration)
        let target = FileManager.default.temporaryDirectory
            .appendingPathComponent("naming-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: outputSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        // `commonFormat`/`interleaved` must match the buffers being written:
        // AVAudioFile only accepts buffers in its *processing* format, which
        // defaults to deinterleaved float and would reject 16-bit ones.
        let output = try AVAudioFile(
            forWriting: target,
            settings: settings,
            commonFormat: .pcmFormatInt16,
            interleaved: true
        )

        while let block = try reader.nextConvertedBuffer() {
            try output.write(from: block)
        }
        return HeadFile(url: target, isTemporary: true)
    }

    // MARK: - Reading and conversion

    /// Pulls float frames from the source file and hands back 16 kHz mono Int16.
    /// A class because `AVAudioConverter`'s input block is called back into.
    private final class Reader {
        private let file: AVAudioFile
        private let converter: AVAudioConverter
        private let outputFormat: AVAudioFormat
        private let readBuffer: AVAudioPCMBuffer
        private let outputBuffer: AVAudioPCMBuffer
        private let sourceFrameLimit: AVAudioFramePosition
        private var framesRead: AVAudioFramePosition = 0
        private var reachedEnd = false

        init(url: URL, maxDuration: TimeInterval) throws {
            do {
                file = try AVAudioFile(forReading: url)
            } catch {
                throw ChunkerError.unreadable(error.localizedDescription)
            }
            let inputFormat = file.processingFormat
            guard
                let outputFormat = AVAudioFormat(
                    commonFormat: .pcmFormatInt16,
                    sampleRate: AudioFileChunker.outputSampleRate,
                    channels: 1,
                    interleaved: true
                ),
                let converter = AVAudioConverter(from: inputFormat, to: outputFormat),
                let readBuffer = AVAudioPCMBuffer(
                    pcmFormat: inputFormat, frameCapacity: 16_384
                ),
                let outputBuffer = AVAudioPCMBuffer(
                    pcmFormat: outputFormat, frameCapacity: 16_384
                )
            else { throw ChunkerError.unsupportedFormat }
            self.outputFormat = outputFormat
            self.converter = converter
            self.readBuffer = readBuffer
            self.outputBuffer = outputBuffer
            sourceFrameLimit = min(
                file.length,
                AVAudioFramePosition(max(0, maxDuration) * inputFormat.sampleRate)
            )
        }

        /// Next converted buffer, or nil at the end of the window.
        func nextConvertedBuffer() throws -> AVAudioPCMBuffer? {
            while true {
                if reachedEnd { return nil }
                outputBuffer.frameLength = 0
                var conversionError: NSError?
                var suppliedInput = false

                let status = converter.convert(to: outputBuffer, error: &conversionError) {
                    [weak self] _, outStatus in
                    guard let self else {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    let remaining = self.sourceFrameLimit - self.framesRead
                    guard remaining > 0 else {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    let wanted = AVAudioFrameCount(
                        min(remaining, AVAudioFramePosition(self.readBuffer.frameCapacity))
                    )
                    do {
                        try self.file.read(into: self.readBuffer, frameCount: wanted)
                    } catch {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    guard self.readBuffer.frameLength > 0 else {
                        outStatus.pointee = .endOfStream
                        return nil
                    }
                    self.framesRead += AVAudioFramePosition(self.readBuffer.frameLength)
                    suppliedInput = true
                    outStatus.pointee = .haveData
                    return self.readBuffer
                }

                if let conversionError {
                    throw ChunkerError.unreadable(conversionError.localizedDescription)
                }
                if status == .error {
                    throw ChunkerError.unsupportedFormat
                }
                if status == .endOfStream {
                    reachedEnd = true
                }
                if outputBuffer.frameLength > 0 {
                    return outputBuffer
                }
                if status == .endOfStream || (!suppliedInput && status == .inputRanDry) {
                    return nil
                }
            }
        }

        /// Next converted block as raw bytes, or nil at the end of the window.
        func nextConvertedBlock() throws -> Data? {
            guard let buffer = try nextConvertedBuffer(),
                  let channel = buffer.int16ChannelData
            else { return nil }
            return Data(
                bytes: channel[0],
                count: Int(buffer.frameLength) * MemoryLayout<Int16>.size
            )
        }
    }
}
