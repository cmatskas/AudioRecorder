import XCTest
@testable import AudioRecorderCore
@testable import AudioRecorderInsights

final class TranscribeWebSocketTests: XCTestCase {
    /// Obviously synthetic signing inputs — SigV4 accepts any string, and
    /// real-looking key material has no place in a repository.
    private static let fakeCredentials = RawAWSCredentials(
        accessKeyID: "fake-access-key-for-tests",
        secretAccessKey: "fake-signing-material-for-tests",
        sessionToken: "fake/session+token"
    )

    // MARK: - CRC32

    func testCRC32KnownVectors() {
        // Standard check value for "123456789" (IEEE CRC-32).
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(CRC32.checksum(Data()), 0)
    }

    // MARK: - Event stream framing

    func testEventStreamRoundTrip() throws {
        let message = EventStreamCodec.Message(
            headers: [
                ":message-type": "event",
                ":event-type": "AudioEvent",
                ":content-type": "application/octet-stream",
            ],
            payload: Data([0x01, 0x02, 0x03, 0x04])
        )
        let decoded = try EventStreamCodec.decode(EventStreamCodec.encode(message))
        XCTAssertEqual(decoded, message)
    }

    func testEventStreamRoundTripWithEmptyPayload() throws {
        let frame = EventStreamCodec.encodeEndOfStream()
        let decoded = try EventStreamCodec.decode(frame)
        XCTAssertEqual(decoded.headers[":event-type"], "AudioEvent")
        XCTAssertTrue(decoded.payload.isEmpty)
    }

    func testDecodeRejectsCorruptedFrame() throws {
        var frame = EventStreamCodec.encodeAudioChunk(Data(repeating: 0xAB, count: 64))
        frame[frame.count - 10] ^= 0xFF  // flip a payload bit
        XCTAssertThrowsError(try EventStreamCodec.decode(frame)) { error in
            guard case EventStreamCodec.CodecError.checksumMismatch = error else {
                return XCTFail("expected checksumMismatch, got \(error)")
            }
        }
    }

    func testDecodeRejectsTruncatedFrame() {
        XCTAssertThrowsError(try EventStreamCodec.decode(Data([0, 0, 0])))
    }

    // MARK: - Presigner

    func testPresignedURLShape() throws {
        let url = TranscribePresigner.presignedURL(
            region: "us-east-1",
            credentials: Self.fakeCredentials,
            date: Date(timeIntervalSince1970: 1_726_000_000)
        )
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "wss")
        XCTAssertEqual(components.host, "transcribestreaming.us-east-1.amazonaws.com")
        XCTAssertEqual(components.port, 8443)
        XCTAssertEqual(components.path, "/stream-transcription-websocket")

        let query = Dictionary(
            uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }
        )
        XCTAssertEqual(query["X-Amz-Algorithm"], "AWS4-HMAC-SHA256")
        XCTAssertEqual(query["X-Amz-SignedHeaders"], "host")
        XCTAssertEqual(query["language-code"], "en-US")
        XCTAssertEqual(query["media-encoding"], "pcm")
        XCTAssertEqual(query["sample-rate"], "16000")
        XCTAssertEqual(query["X-Amz-Security-Token"], "fake/session+token")
        XCTAssertEqual(query["X-Amz-Signature"]?.count, 64)
        XCTAssertTrue(query["X-Amz-Credential"]?.hasSuffix("/us-east-1/transcribe/aws4_request") ?? false)
        // Deterministic inputs must produce a deterministic signature.
        let again = TranscribePresigner.presignedURL(
            region: "us-east-1",
            credentials: Self.fakeCredentials,
            date: Date(timeIntervalSince1970: 1_726_000_000)
        )
        XCTAssertEqual(url, again)
    }

    func testURIEncodeMatchesSigV4Rules() {
        XCTAssertEqual(TranscribePresigner.uriEncode("AKID/20260901/us-east-1"), "AKID%2F20260901%2Fus-east-1")
        XCTAssertEqual(TranscribePresigner.uriEncode("a+b c~d.e-f_g"), "a%2Bb%20c~d.e-f_g")
    }

    // MARK: - Transcript payload parsing

    func testFinalTranscriptsParsing() {
        let payload = Data("""
        {"Transcript":{"Results":[
            {"IsPartial":true,"Alternatives":[{"Transcript":"partial text"}]},
            {"IsPartial":false,"Alternatives":[{"Transcript":"final text"}]},
            {"IsPartial":false,"Alternatives":[{"Transcript":"   "}]},
            {"IsPartial":false,"Alternatives":[]}
        ]}}
        """.utf8)
        XCTAssertEqual(TranscribeStreamer.finalTranscripts(in: payload), ["final text"])
    }

    func testFinalTranscriptsHandlesEmptyAndGarbagePayloads() {
        XCTAssertEqual(TranscribeStreamer.finalTranscripts(in: Data("{}".utf8)), [])
        XCTAssertEqual(TranscribeStreamer.finalTranscripts(in: Data("garbage".utf8)), [])
    }
}
