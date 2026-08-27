import AVFoundation
import Foundation

/// Reads one recorded track as a continuous stream at a target sample rate,
/// positioned on a shared timeline.
///
/// Pipeline per track:
///   segment files (native channels @ native rate)
///     -> fold to stereo (pairs summed, so a legacy 4-channel
///        [micL, micR, sysL, sysR] master folds to mic+system)
///     -> resample to the output rate when needed, offline, with
///        mastering-quality filters
///     -> leading silence, so a track that started later lands correctly
///
/// Reads past the end of the track return silence, letting the merge continue
/// until the longest track is exhausted.
final class TrackReader {
    private let segmentURLs: [URL]
    private let outputFormat: AVAudioFormat
    /// Native format of the segment files.
    private let fileFormat: AVAudioFormat
    /// Stereo at the native rate: the format handed to the converter.
    private let foldedFormat: AVAudioFormat
    private let converter: AVAudioConverter?

    private var segmentIndex = 0
    private var currentFile: AVAudioFile?
    private var fileBuffer: AVAudioPCMBuffer
    private var foldedBuffer: AVAudioPCMBuffer
    private var leadingSilenceRemaining: Int
    private var exhausted = false

    private static let readChunkFrames: AVAudioFrameCount = 8192

    init(
        track: SessionManifest.Track,
        sessionDirectory: URL,
        outputFormat: AVAudioFormat,
        leadingSilenceFrames: Int
    ) throws {
        segmentURLs = track.segments
            .map { sessionDirectory.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        self.outputFormat = outputFormat
        leadingSilenceRemaining = max(0, leadingSilenceFrames)

        // Trust the files over the manifest for format details.
        guard let first = segmentURLs.first else {
            throw SessionEncoder.EncoderError.noSegments
        }
        let probe = try AVAudioFile(
            forReading: first, commonFormat: .pcmFormatFloat32, interleaved: true
        )
        fileFormat = probe.processingFormat

        guard
            let folded = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: fileFormat.sampleRate,
                channels: 2,
                interleaved: true
            ),
            let fileBuf = AVAudioPCMBuffer(
                pcmFormat: fileFormat, frameCapacity: Self.readChunkFrames
            ),
            let foldedBuf = AVAudioPCMBuffer(
                pcmFormat: folded, frameCapacity: Self.readChunkFrames
            )
        else {
            throw SessionEncoder.EncoderError.formatError
        }
        foldedFormat = folded
        fileBuffer = fileBuf
        foldedBuffer = foldedBuf

        if folded.sampleRate != outputFormat.sampleRate {
            guard let converter = AVAudioConverter(from: folded, to: outputFormat) else {
                throw SessionEncoder.EncoderError.formatError
            }
            // This runs offline, so the extra cost of the best filters is
            // irrelevant and the artefacts avoided are not.
            converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
            converter.sampleRateConverterAlgorithm = AVSampleRateConverterAlgorithm_Mastering
            self.converter = converter
        } else {
            converter = nil
        }
    }

    /// True once the track's audio is finished (subsequent reads are silence).
    var isExhausted: Bool { exhausted && leadingSilenceRemaining == 0 }

    /// Fills `destination` with up to `frames` frames of interleaved stereo at
    /// the output rate, padding with silence where the track has nothing.
    /// Returns the number of frames that contained real audio.
    func read(into destination: UnsafeMutablePointer<Float>, frames: Int) throws -> Int {
        memset(destination, 0, frames * 2 * MemoryLayout<Float>.size)

        var offset = 0
        if leadingSilenceRemaining > 0 {
            let silent = min(frames, leadingSilenceRemaining)
            leadingSilenceRemaining -= silent
            offset = silent
            if silent == frames { return 0 }
        }

        var realFrames = 0
        while offset < frames {
            let wanted = AVAudioFrameCount(frames - offset)
            guard let chunk = try nextChunk(maxFrames: wanted) else {
                exhausted = true
                break
            }
            let chunkFrames = Int(chunk.frameLength)
            if chunkFrames == 0 { continue }
            guard let source = chunk.floatChannelData?[0] else { break }
            memcpy(
                destination + offset * 2,
                source,
                chunkFrames * 2 * MemoryLayout<Float>.size
            )
            offset += chunkFrames
            realFrames += chunkFrames
        }
        return realFrames
    }

    // MARK: - Source plumbing

    /// Returns the next stereo chunk at the output rate, or nil at end of track.
    private func nextChunk(maxFrames: AVAudioFrameCount) throws -> AVAudioPCMBuffer? {
        guard let converter else {
            return try readFolded(maxFrames: maxFrames)
        }

        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: maxFrames)
        else { throw SessionEncoder.EncoderError.formatError }

        var reachedEnd = false
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            do {
                if let folded = try self.readFolded() {
                    inputStatus.pointee = .haveData
                    return folded
                }
            } catch {
                // Treat a read failure as end of stream; the caller stops cleanly.
            }
            reachedEnd = true
            inputStatus.pointee = .endOfStream
            return nil
        }
        if let conversionError { throw conversionError }
        if status == .error { throw SessionEncoder.EncoderError.formatError }
        if output.frameLength == 0 && (reachedEnd || status == .endOfStream) { return nil }
        return output
    }

    /// Reads the next chunk from the segment sequence and folds it to stereo.
    private func readFolded(maxFrames: AVAudioFrameCount? = nil) throws -> AVAudioPCMBuffer? {
        guard let raw = try readSource(maxFrames: maxFrames) else { return nil }
        let frames = Int(raw.frameLength)
        let channels = Int(fileFormat.channelCount)
        guard
            let input = raw.floatChannelData?[0],
            let output = foldedBuffer.floatChannelData?[0]
        else { throw SessionEncoder.EncoderError.formatError }

        if channels == 2 {
            memcpy(output, input, frames * 2 * MemoryLayout<Float>.size)
        } else if channels == 1 {
            for frame in 0..<frames {
                let sample = input[frame]
                output[frame * 2] = sample
                output[frame * 2 + 1] = sample
            }
        } else {
            // Fold channel pairs: even channels to left, odd to right. A legacy
            // 4-channel [micL, micR, sysL, sysR] master becomes mic+system.
            for frame in 0..<frames {
                var left: Float = 0
                var right: Float = 0
                for channel in 0..<channels {
                    let sample = input[frame * channels + channel]
                    if channel % 2 == 0 { left += sample } else { right += sample }
                }
                output[frame * 2] = max(-1.0, min(1.0, left))
                output[frame * 2 + 1] = max(-1.0, min(1.0, right))
            }
        }
        foldedBuffer.frameLength = AVAudioFrameCount(frames)
        return foldedBuffer
    }

    /// Reads the next raw chunk from the segment sequence at native format.
    private func readSource(maxFrames: AVAudioFrameCount? = nil) throws -> AVAudioPCMBuffer? {
        while true {
            if currentFile == nil {
                guard segmentIndex < segmentURLs.count else { return nil }
                currentFile = try AVAudioFile(
                    forReading: segmentURLs[segmentIndex],
                    commonFormat: .pcmFormatFloat32,
                    interleaved: true
                )
                segmentIndex += 1
            }
            guard let file = currentFile else { return nil }

            // AVAudioFile.read(into:) throws when called exactly at EOF.
            if file.framePosition >= file.length {
                currentFile = nil
                continue
            }
            let capacity = maxFrames.map { min($0, Self.readChunkFrames) } ?? Self.readChunkFrames
            let remaining = AVAudioFrameCount(file.length - file.framePosition)
            try file.read(into: fileBuffer, frameCount: min(capacity, remaining))
            if fileBuffer.frameLength == 0 {
                currentFile = nil
                continue
            }
            return fileBuffer
        }
    }
}
