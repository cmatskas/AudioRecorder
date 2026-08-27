import AVFoundation
import Foundation
import os

/// Renders a recorded session into a single AAC `.m4a`.
///
/// Tracks were captured independently, at their own native sample rates and
/// from unrelated hardware clocks. This is where they are brought together:
///
///  1. the output rate is the highest track rate, so no source is downsampled,
///  2. each track's start is derived from its host-time anchor, so a track that
///     began later is offset by exactly that much silence,
///  3. lower-rate tracks are resampled with mastering-quality filters,
///  4. tracks are summed with clipping protection and encoded.
///
/// Doing this offline (rather than on the audio thread) is what makes correct
/// alignment possible: every buffer's true position is known, nothing has to be
/// guessed at while frames are arriving, and a dropout on one source cannot
/// disturb another. The PCM masters are left untouched as the source of truth.
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

    private static let logger = Logger(
        subsystem: "dev.cmatskas.AudioRecorder", category: "encoder"
    )
    private static let blockFrames = 8192

    /// Encodes and returns the output URL.
    @discardableResult
    public static func encode(
        sessionDirectory: URL,
        manifest: SessionManifest,
        outputURL: URL
    ) throws -> URL {
        // Only tracks that actually have segments on disk participate.
        let tracks = manifest.tracks.filter { track in
            track.segments.contains { segment in
                FileManager.default.fileExists(
                    atPath: sessionDirectory.appendingPathComponent(segment).path
                )
            }
        }
        guard !tracks.isEmpty else { throw EncoderError.noSegments }

        let outputRate = tracks.map(\.sampleRate).max() ?? 48_000
        guard
            let workFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: outputRate,
                channels: 2,
                interleaved: true
            )
        else { throw EncoderError.formatError }

        // Align by host-time anchor: the earliest anchor is time zero, and each
        // track is delayed by its own offset from it. Anchors of 0 mean the
        // track never started (or came from a v1 manifest) and are treated as
        // starting at zero.
        let anchors = tracks.map(\.anchorHostTime).filter { $0 > 0 }
        let baseAnchor = anchors.min() ?? 0

        var readers: [TrackReader] = []
        for track in tracks {
            var leadingSilence = 0
            if track.anchorHostTime > 0, baseAnchor > 0, track.anchorHostTime > baseAnchor {
                let ticks = track.hostTicksPerSecond > 0
                    ? track.hostTicksPerSecond
                    : CaptureTrack.hostTicksPerSecond()
                let delaySeconds = Double(track.anchorHostTime - baseAnchor) / ticks
                leadingSilence = Int((delaySeconds * outputRate).rounded())
            }
            logger.info("encode track \(track.label, privacy: .public): rate=\(track.sampleRate, privacy: .public) segments=\(track.segments.count, privacy: .public) leadingSilenceFrames=\(leadingSilence, privacy: .public)")
            readers.append(
                try TrackReader(
                    track: track,
                    sessionDirectory: sessionDirectory,
                    outputFormat: workFormat,
                    leadingSilenceFrames: leadingSilence
                )
            )
        }

        try? FileManager.default.removeItem(at: outputURL)

        var outputSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: outputRate,
            AVNumberOfChannelsKey: 2,
        ]
        // AAC rejects an explicit high bitrate at unusually low sample rates.
        if outputRate >= 32_000 {
            outputSettings[AVEncoderBitRateKey] = 192_000
        }
        let outputFile = try AVAudioFile(
            forWriting: outputURL,
            settings: outputSettings,
            commonFormat: .pcmFormatFloat32,
            interleaved: true
        )

        guard
            let mixBuffer = AVAudioPCMBuffer(
                pcmFormat: workFormat, frameCapacity: AVAudioFrameCount(blockFrames)
            )
        else { throw EncoderError.formatError }

        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: blockFrames * 2)
        defer { scratch.deallocate() }

        var totalFrames = 0
        while true {
            guard let mix = mixBuffer.floatChannelData?[0] else { throw EncoderError.formatError }
            memset(mix, 0, blockFrames * 2 * MemoryLayout<Float>.size)

            var framesThisBlock = 0
            for reader in readers {
                let real = try reader.read(into: scratch, frames: blockFrames)
                guard real > 0 else { continue }
                framesThisBlock = max(framesThisBlock, real)
                // Sum into the mix.
                for index in 0..<(real * 2) {
                    mix[index] += scratch[index]
                }
            }
            if framesThisBlock == 0 { break }

            // Clipping protection: the sources are independent, so their sum
            // can exceed full scale.
            for index in 0..<(framesThisBlock * 2) {
                mix[index] = max(-1.0, min(1.0, mix[index]))
            }

            mixBuffer.frameLength = AVAudioFrameCount(framesThisBlock)
            try outputFile.write(from: mixBuffer)
            totalFrames += framesThisBlock

            if readers.allSatisfy(\.isExhausted) { break }
        }

        logger.info("encode complete: \(outputURL.lastPathComponent, privacy: .public) rate=\(outputRate, privacy: .public) frames=\(totalFrames, privacy: .public)")
        return outputURL
    }
}
