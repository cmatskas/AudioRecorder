import Foundation

/// Writes Core Audio Format (CAF) files with crash-safety as the primary goal.
///
/// The file is written through a raw file descriptor so every `append` reaches
/// the kernel immediately, and `sync()` forces data to physical media with
/// `F_FULLFSYNC`. The CAF data chunk size is written as -1 ("data continues to
/// end of file"), which the format defines as valid — a file interrupted by a
/// crash or power loss is readable up to the last synced byte with no repair.
/// `finalize()` patches the real size in for well-formedness on clean close.
///
/// Audio is stored as interleaved 16-bit little-endian PCM. Input is
/// interleaved Float32 (the capture engine's native format).
public final class CAFWriter {
    public enum WriterError: LocalizedError {
        case openFailed(String, Int32)
        case writeFailed(Int32)
        case closed

        public var errorDescription: String? {
            switch self {
            case let .openFailed(path, err):
                return "Could not create \(path): \(String(cString: strerror(err)))"
            case let .writeFailed(err):
                return "Audio write failed: \(String(cString: strerror(err)))"
            case .closed:
                return "Writer is closed"
            }
        }
    }

    public let url: URL
    public let sampleRate: Double
    public let channels: Int
    public private(set) var framesWritten = 0

    private var fd: Int32 = -1
    /// Byte offset of the data chunk's mChunkSize field (Int64, big-endian).
    private var dataChunkSizeOffset = 0
    /// Bytes of chunk payload written so far (starts at 4 for mEditCount).
    private var dataChunkPayloadBytes: Int64 = 4
    private var conversionBuffer: [Int16] = []

    public init(url: URL, sampleRate: Double, channels: Int) throws {
        self.url = url
        self.sampleRate = sampleRate
        self.channels = channels

        fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard fd >= 0 else {
            throw WriterError.openFailed(url.path, errno)
        }

        var header = Data()
        // File header: 'caff', version 1, flags 0.
        header.append(fourCC("caff"))
        header.append(bigEndian(UInt16(1)))
        header.append(bigEndian(UInt16(0)))

        // Audio Description chunk.
        header.append(fourCC("desc"))
        header.append(bigEndian(Int64(32)))
        header.append(bigEndian(sampleRate.bitPattern))          // mSampleRate (Float64 BE)
        header.append(fourCC("lpcm"))                            // mFormatID
        header.append(bigEndian(UInt32(2)))                      // mFormatFlags: little-endian int
        header.append(bigEndian(UInt32(2 * channels)))           // mBytesPerPacket
        header.append(bigEndian(UInt32(1)))                      // mFramesPerPacket
        header.append(bigEndian(UInt32(channels)))               // mChannelsPerFrame
        header.append(bigEndian(UInt32(16)))                     // mBitsPerChannel

        // Data chunk: size -1 = "valid to end of file" (the crash-safety property).
        header.append(fourCC("data"))
        dataChunkSizeOffset = header.count
        header.append(bigEndian(Int64(-1)))
        header.append(bigEndian(UInt32(0)))                      // mEditCount

        try header.withUnsafeBytes { raw in
            try writeAll(raw.baseAddress!, count: raw.count)
        }
    }

    deinit {
        // Deliberately does NOT patch the size field: if the writer is torn
        // down without finalize() (crash path), the file stays -1/valid-to-EOF.
        if fd >= 0 {
            close(fd)
        }
    }

    /// Appends interleaved Float32 frames, converting to Int16 PCM.
    public func append(_ interleaved: UnsafePointer<Float>, frameCount: Int) throws {
        guard fd >= 0 else { throw WriterError.closed }
        guard frameCount > 0 else { return }
        let sampleCount = frameCount * channels
        if conversionBuffer.count < sampleCount {
            conversionBuffer = [Int16](repeating: 0, count: sampleCount)
        }
        conversionBuffer.withUnsafeMutableBufferPointer { out in
            for i in 0..<sampleCount {
                let clamped = max(-1.0, min(1.0, interleaved[i]))
                out[i] = Int16(clamped * 32767.0)
            }
        }
        let byteCount = sampleCount * MemoryLayout<Int16>.size
        try conversionBuffer.withUnsafeBytes { raw in
            try writeAll(raw.baseAddress!, count: byteCount)
        }
        dataChunkPayloadBytes += Int64(byteCount)
        framesWritten += frameCount
    }

    /// Forces all written data to physical media. Bounds worst-case loss on
    /// power failure to the interval between calls.
    public func sync() {
        guard fd >= 0 else { return }
        if fcntl(fd, F_FULLFSYNC) != 0 {
            fsync(fd)
        }
    }

    /// Patches the real data chunk size, syncs and closes. After this the file
    /// is a fully well-formed CAF.
    public func finalize() throws {
        guard fd >= 0 else { return }
        let sizeField = bigEndian(dataChunkPayloadBytes)
        _ = sizeField.withUnsafeBytes { raw in
            pwrite(fd, raw.baseAddress, raw.count, off_t(dataChunkSizeOffset))
        }
        sync()
        close(fd)
        fd = -1
    }

    // MARK: - Helpers

    private func writeAll(_ pointer: UnsafeRawPointer, count: Int) throws {
        var written = 0
        while written < count {
            let n = write(fd, pointer + written, count - written)
            if n < 0 {
                if errno == EINTR { continue }
                throw WriterError.writeFailed(errno)
            }
            written += n
        }
    }

    private func fourCC(_ code: String) -> Data {
        Data(code.utf8)
    }

    private func bigEndian<T: FixedWidthInteger>(_ value: T) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }
}
