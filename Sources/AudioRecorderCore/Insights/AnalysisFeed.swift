import AVFoundation
import Foundation
import Synchronization

/// Consumes one source's analysis ring buffer and produces 16 kHz mono
/// Int16 PCM chunks — the wire format streaming transcription expects.
///
/// Runs on its own thread, exactly like a recording lane: if this consumer
/// stalls or dies, its ring simply overflows and drops *its own* data. The
/// recording lanes are untouched.
///
/// While paused, the ring is still drained (so it cannot back up) but the
/// converted output is discarded — nothing leaves the machine.
public final class AnalysisFeed: @unchecked Sendable {
    public let speaker: Speaker
    public let ring: RingBuffer

    /// Converted PCM chunks (16 kHz, mono, Int16 little-endian). Finishes
    /// after `finish()` once the ring has been fully drained.
    public let chunks: AsyncStream<Data>

    public static let outputSampleRate = 16_000.0

    private let continuation: AsyncStream<Data>.Continuation
    private let sourceRate: Double
    private let stopRequested = Atomic<Bool>(false)
    private let paused = Atomic<Bool>(false)
    private let done = DispatchSemaphore(value: 0)
    private var thread: Thread?

    /// - Parameters:
    ///   - speaker: which side of the conversation this source is.
    ///   - sourceRate: native rate of the capture track (interleaved stereo).
    ///   - bufferSeconds: ring headroom; overflow drops analysis audio only.
    public init(speaker: Speaker, sourceRate: Double, bufferSeconds: Double = 30) {
        self.speaker = speaker
        self.sourceRate = sourceRate
        ring = RingBuffer(capacityFloats: Int(bufferSeconds * sourceRate) * 2)
        (chunks, continuation) = AsyncStream.makeStream(of: Data.self)
    }

    public func start() {
        guard thread == nil else { return }
        let thread = Thread { [self] in drain() }
        thread.name = "AnalysisFeed-\(speaker.rawValue)"
        thread.qualityOfService = .utility
        thread.start()
        self.thread = thread
    }

    public func setPaused(_ value: Bool) {
        paused.store(value, ordering: .releasing)
    }

    /// Requests shutdown; the chunk stream finishes once the ring is drained.
    public func finish() {
        stopRequested.store(true, ordering: .releasing)
    }

    /// Blocks until the drain thread has exited. Call off the main thread.
    public func waitUntilDrained() {
        guard thread != nil else {
            continuation.finish()
            return
        }
        done.wait()
    }

    // MARK: - Drain thread

    private func drain() {
        defer {
            continuation.finish()
            done.signal()
        }

        guard
            let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: sourceRate,
                channels: 2,
                interleaved: true
            ),
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatInt16,
                sampleRate: Self.outputSampleRate,
                channels: 1,
                interleaved: true
            ),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { return }

        let chunkFrames = 4800  // ~100 ms at 48 kHz per read
        guard
            let inputBuffer = AVAudioPCMBuffer(
                pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(chunkFrames)
            ),
            let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: outputFormat, frameCapacity: 8192
            )
        else { return }

        while true {
            let floats = readIntoBuffer(inputBuffer, maxFrames: chunkFrames)
            if floats == 0 {
                if stopRequested.load(ordering: .acquiring) { break }
                usleep(20_000)
                continue
            }
            convertAndEmit(inputBuffer, converter: converter, outputBuffer: outputBuffer)
        }
    }

    private func readIntoBuffer(_ buffer: AVAudioPCMBuffer, maxFrames: Int) -> Int {
        guard let channelData = buffer.floatChannelData else { return 0 }
        // Interleaved format: channelData[0] is the interleaved plane.
        let floats = ring.read(into: channelData[0], maxCount: maxFrames * 2)
        let frames = floats / 2
        buffer.frameLength = AVAudioFrameCount(frames)
        return floats
    }

    private func convertAndEmit(
        _ inputBuffer: AVAudioPCMBuffer,
        converter: AVAudioConverter,
        outputBuffer: AVAudioPCMBuffer
    ) {
        var pending: AVAudioPCMBuffer? = inputBuffer
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if let buffer = pending {
                pending = nil
                outStatus.pointee = .haveData
                return buffer
            }
            outStatus.pointee = .noDataNow
            return nil
        }

        while true {
            outputBuffer.frameLength = 0
            var error: NSError?
            let status = converter.convert(
                to: outputBuffer, error: &error, withInputFrom: inputBlock
            )
            if status == .error || error != nil { return }

            let frames = Int(outputBuffer.frameLength)
            if frames > 0, !paused.load(ordering: .acquiring),
               let int16Data = outputBuffer.int16ChannelData {
                let data = Data(
                    bytes: int16Data[0], count: frames * MemoryLayout<Int16>.size
                )
                continuation.yield(data)
            }
            // Once the single pending buffer is consumed the converter will
            // report it ran dry; go read more from the ring.
            if status == .inputRanDry || status == .endOfStream || frames == 0 {
                return
            }
        }
    }
}
