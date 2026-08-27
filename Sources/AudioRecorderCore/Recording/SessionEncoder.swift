import AVFoundation
import Foundation

/// Encodes a recorded session (ordered CAF segments) into a single AAC `.m4a`.
///
/// 4-channel sessions (mic pair + system pair) are mixed down to stereo with
/// clipping protection; 2-channel sessions pass through. The PCM CAF masters
/// are left untouched — they remain the lossless source of truth.
public enum SessionEncoder {
    public enum EncoderError: LocalizedError {
        case noSegments
        case formatError

        public var errorDescription: String? {
            switch self {
            case .noSegments: return "The session contains no audio segments"
            case .formatError: return "Could not create audio processing buffers"
            }
        }
    }

    /// Encodes and returns the output URL.
    @discardableResult
    public static func encode(
        sessionDirectory: URL,
        manifest: SessionManifest,
        outputURL: URL
    ) throws -> URL {
        let segmentURLs = manifest.segments
            .map { sessionDirectory.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !segmentURLs.isEmpty else { throw EncoderError.noSegments }

        try? FileManager.default.removeItem(at: outputURL)

        var outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: manifest.sampleRate,
            AVNumberOfChannelsKey: 2,
        ]
        // 192 kbps stereo for normal rates; let the encoder pick for
        // unusual/low sample rates where that bitrate is invalid.
        if manifest.sampleRate >= 32_000 {
            outputSettings[AVEncoderBitRateKey] = 192_000
        }

        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: outputSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: true
        )

        guard
            let stereoFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: manifest.sampleRate,
                channels: 2,
                interleaved: true
            ),
            let outputBuffer = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: 32_768)
        else { throw EncoderError.formatError }

        for segmentURL in segmentURLs {
            let inputFile = try AVAudioFile(
                forReading: segmentURL,
                commonFormat: .pcmFormatFloat32,
                interleaved: true
            )
            let inputChannels = Int(inputFile.processingFormat.channelCount)
            guard
                let inputBuffer = AVAudioPCMBuffer(
                    pcmFormat: inputFile.processingFormat,
                    frameCapacity: 32_768
                )
            else { throw EncoderError.formatError }

            // Note: AVAudioFile.read(into:) throws when called exactly at EOF,
            // so the loop is bounded by frame position instead.
            while inputFile.framePosition < inputFile.length {
                try inputFile.read(into: inputBuffer)
                let frames = Int(inputBuffer.frameLength)
                if frames == 0 { break }

                guard
                    let inData = inputBuffer.floatChannelData?[0],
                    let outData = outputBuffer.floatChannelData?[0]
                else { throw EncoderError.formatError }

                if inputChannels >= 4 {
                    // Mix mic pair + system pair down to stereo with clamping.
                    for frame in 0..<frames {
                        let micL = inData[frame * inputChannels]
                        let micR = inData[frame * inputChannels + 1]
                        let sysL = inData[frame * inputChannels + 2]
                        let sysR = inData[frame * inputChannels + 3]
                        outData[frame * 2] = max(-1.0, min(1.0, micL + sysL))
                        outData[frame * 2 + 1] = max(-1.0, min(1.0, micR + sysR))
                    }
                } else if inputChannels == 2 {
                    memcpy(outData, inData, frames * 2 * MemoryLayout<Float>.size)
                } else {
                    for frame in 0..<frames {
                        let sample = inData[frame]
                        outData[frame * 2] = sample
                        outData[frame * 2 + 1] = sample
                    }
                }
                outputBuffer.frameLength = AVAudioFrameCount(frames)
                try outputFile.write(from: outputBuffer)
            }
        }
        return outputURL
    }
}
