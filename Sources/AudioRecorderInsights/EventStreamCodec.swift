import Foundation

/// Encoder/decoder for the AWS event stream binary framing
/// (`application/vnd.amazon.eventstream`) used by Transcribe's WebSocket API.
///
/// Frame layout:
/// ```
/// [4B total length][4B headers length][4B prelude CRC]
/// [headers][payload][4B message CRC]
/// ```
/// Headers are `[1B name len][name][1B type][2B value len][value]`; only the
/// string type (7) is used by this protocol.
enum EventStreamCodec {
    struct Message: Equatable {
        var headers: [String: String]
        var payload: Data
    }

    enum CodecError: LocalizedError {
        case truncated
        case checksumMismatch
        case unsupportedHeaderType(UInt8)

        var errorDescription: String? {
            switch self {
            case .truncated: return "Event stream frame is truncated"
            case .checksumMismatch: return "Event stream frame failed CRC check"
            case let .unsupportedHeaderType(type):
                return "Unsupported event stream header type \(type)"
            }
        }
    }

    // MARK: - Encode

    static func encode(_ message: Message) -> Data {
        var headerData = Data()
        for (name, value) in message.headers.sorted(by: { $0.key < $1.key }) {
            let nameBytes = Data(name.utf8)
            let valueBytes = Data(value.utf8)
            headerData.append(UInt8(nameBytes.count))
            headerData.append(nameBytes)
            headerData.append(7)  // string type
            headerData.append(contentsOf: UInt16(valueBytes.count).bigEndianBytes)
            headerData.append(valueBytes)
        }

        let totalLength = 12 + headerData.count + message.payload.count + 4
        var frame = Data(capacity: totalLength)
        frame.append(contentsOf: UInt32(totalLength).bigEndianBytes)
        frame.append(contentsOf: UInt32(headerData.count).bigEndianBytes)
        frame.append(contentsOf: CRC32.checksum(frame).bigEndianBytes)
        frame.append(headerData)
        frame.append(message.payload)
        frame.append(contentsOf: CRC32.checksum(frame).bigEndianBytes)
        return frame
    }

    /// Wraps one PCM chunk as an AudioEvent frame.
    static func encodeAudioChunk(_ pcm: Data) -> Data {
        encode(
            Message(
                headers: [
                    ":message-type": "event",
                    ":event-type": "AudioEvent",
                    ":content-type": "application/octet-stream",
                ],
                payload: pcm
            )
        )
    }

    /// An empty AudioEvent, which tells Transcribe the audio is finished.
    static func encodeEndOfStream() -> Data {
        encodeAudioChunk(Data())
    }

    // MARK: - Decode

    static func decode(_ frame: Data) throws -> Message {
        let data = Data(frame)  // rebase indices
        guard data.count >= 16 else { throw CodecError.truncated }
        let totalLength = Int(UInt32(bigEndianBytes: data, at: 0))
        let headersLength = Int(UInt32(bigEndianBytes: data, at: 4))
        let preludeCRC = UInt32(bigEndianBytes: data, at: 8)
        guard data.count >= totalLength,
              totalLength >= 16 + headersLength else { throw CodecError.truncated }
        guard CRC32.checksum(data.prefix(8)) == preludeCRC else {
            throw CodecError.checksumMismatch
        }
        let messageCRC = UInt32(bigEndianBytes: data, at: totalLength - 4)
        guard CRC32.checksum(data.prefix(totalLength - 4)) == messageCRC else {
            throw CodecError.checksumMismatch
        }

        var headers: [String: String] = [:]
        var offset = 12
        let headersEnd = 12 + headersLength
        while offset < headersEnd {
            let nameLength = Int(data[offset]); offset += 1
            guard offset + nameLength <= headersEnd else { throw CodecError.truncated }
            let name = String(decoding: data[offset..<offset + nameLength], as: UTF8.self)
            offset += nameLength
            let type = data[offset]; offset += 1
            guard type == 7 else { throw CodecError.unsupportedHeaderType(type) }
            guard offset + 2 <= headersEnd else { throw CodecError.truncated }
            let valueLength = Int(UInt16(bigEndianBytes: data, at: offset)); offset += 2
            guard offset + valueLength <= headersEnd else { throw CodecError.truncated }
            headers[name] = String(
                decoding: data[offset..<offset + valueLength], as: UTF8.self
            )
            offset += valueLength
        }

        let payload = data.subdata(in: headersEnd..<(totalLength - 4))
        return Message(headers: headers, payload: payload)
    }
}

/// Standard CRC-32 (IEEE 802.3, the zlib polynomial), which the event stream
/// protocol mandates.
enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index -> UInt32 in
        var crc = UInt32(index)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        return crc ^ 0xFFFF_FFFF
    }
}

// MARK: - Big-endian helpers

extension UInt32 {
    var bigEndianBytes: [UInt8] {
        [UInt8(self >> 24 & 0xFF), UInt8(self >> 16 & 0xFF), UInt8(self >> 8 & 0xFF), UInt8(self & 0xFF)]
    }

    init(bigEndianBytes data: Data, at offset: Int) {
        let base = data.startIndex + offset
        self = UInt32(data[base]) << 24 | UInt32(data[base + 1]) << 16
            | UInt32(data[base + 2]) << 8 | UInt32(data[base + 3])
    }
}

extension UInt16 {
    var bigEndianBytes: [UInt8] {
        [UInt8(self >> 8 & 0xFF), UInt8(self & 0xFF)]
    }

    init(bigEndianBytes data: Data, at offset: Int) {
        let base = data.startIndex + offset
        self = UInt16(data[base]) << 8 | UInt16(data[base + 1])
    }
}
