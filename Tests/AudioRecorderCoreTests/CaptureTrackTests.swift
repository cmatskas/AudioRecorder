import XCTest
@testable import AudioRecorderCore

/// Verifies that a track keeps its written frame count proportional to
/// wall-clock time, which is what makes offline alignment possible.
final class CaptureTrackTests: XCTestCase {
    private let rate: Double = 48_000
    private var ticksPerSecond: Double = 0

    override func setUp() {
        ticksPerSecond = CaptureTrack.hostTicksPerSecond()
    }

    private func ticks(_ seconds: Double) -> UInt64 {
        UInt64(seconds * ticksPerSecond)
    }

    private func makeTrack() -> (CaptureTrack, RingBuffer) {
        let track = CaptureTrack(label: "test", sampleRate: rate)
        let ring = RingBuffer(capacityFloats: Int(rate) * 2 * 10)
        track.setSinks([ring])
        return (track, ring)
    }

    func testIgnoresBuffersWhenNotRecording() {
        let track = CaptureTrack(label: "test", sampleRate: rate)
        let tone = [Float](repeating: 0.5, count: 512 * 2)
        tone.withUnsafeBufferPointer {
            track.append($0.baseAddress!, frameCount: 512, hostTime: ticks(1))
        }
        XCTAssertEqual(track.framesWritten, 0)
        XCTAssertEqual(track.anchorHostTime, 0)
    }

    func testAnchorIsSetFromFirstBuffer() {
        let (track, ring) = makeTrack()
        let start = ticks(100)
        let tone = [Float](repeating: 0.5, count: 512 * 2)
        tone.withUnsafeBufferPointer {
            track.append($0.baseAddress!, frameCount: 512, hostTime: start)
        }
        XCTAssertEqual(track.anchorHostTime, start)
        XCTAssertEqual(track.framesWritten, 512)
        XCTAssertEqual(ring.availableToRead, 512 * 2)
        XCTAssertEqual(track.framesGapFilled, 0)
    }

    /// Small timing jitter must not trigger gap filling.
    func testSmallJitterDoesNotInsertSilence() {
        let (track, _) = makeTrack()
        let tone = [Float](repeating: 0.5, count: 512 * 2)
        let start = ticks(10)
        tone.withUnsafeBufferPointer {
            track.append($0.baseAddress!, frameCount: 512, hostTime: start)
        }
        // Next buffer arrives 5 ms late — well under the 20 ms tolerance.
        let jittered = start + ticks(512 / rate + 0.005)
        tone.withUnsafeBufferPointer {
            track.append($0.baseAddress!, frameCount: 512, hostTime: jittered)
        }
        XCTAssertEqual(track.framesGapFilled, 0)
        XCTAssertEqual(track.framesWritten, 1024)
    }

    /// A device stall (Bluetooth dropout) is covered with silence so that frame
    /// position stays proportional to elapsed time.
    func testDropoutIsFilledWithSilence() throws {
        let (track, ring) = makeTrack()
        let tone = [Float](repeating: 0.5, count: 512 * 2)
        let start = ticks(10)
        tone.withUnsafeBufferPointer {
            track.append($0.baseAddress!, frameCount: 512, hostTime: start)
        }

        // Next buffer arrives 500 ms late: a real dropout.
        let gapSeconds = 0.5
        let late = start + ticks(512 / rate + gapSeconds)
        tone.withUnsafeBufferPointer {
            track.append($0.baseAddress!, frameCount: 512, hostTime: late)
        }

        let expectedFill = Int(gapSeconds * rate)
        XCTAssertEqual(Double(track.framesGapFilled), Double(expectedFill), accuracy: rate * 0.01)
        XCTAssertEqual(track.framesWritten, 1024 + track.framesGapFilled)

        // Verify the shape on the wire: tone, then silence, then tone.
        var out = [Float](repeating: -1, count: ring.availableToRead)
        let read = out.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, maxCount: $0.count)
        }
        XCTAssertEqual(read, out.count)
        XCTAssertEqual(out[0], 0.5, accuracy: 0.0001)                    // first tone
        XCTAssertEqual(out[512 * 2 + 100], 0.0, accuracy: 0.0001)        // inside the fill
        XCTAssertEqual(out[read - 2], 0.5, accuracy: 0.0001)             // tone resumes
    }

    /// A wild timestamp must not be able to inject unbounded silence.
    func testGapFillIsBounded() {
        let (track, _) = makeTrack()
        let tone = [Float](repeating: 0.5, count: 512 * 2)
        let start = ticks(10)
        tone.withUnsafeBufferPointer {
            track.append($0.baseAddress!, frameCount: 512, hostTime: start)
        }
        // Claim an hour has passed.
        tone.withUnsafeBufferPointer {
            track.append($0.baseAddress!, frameCount: 512, hostTime: start + ticks(3600))
        }
        // Capped at the 2 second maximum.
        XCTAssertLessThanOrEqual(track.framesGapFilled, Int(2.0 * rate) + 1)
    }

    func testSinkReattachResetsTimeline() {
        let (track, _) = makeTrack()
        let tone = [Float](repeating: 0.5, count: 512 * 2)
        tone.withUnsafeBufferPointer {
            track.append($0.baseAddress!, frameCount: 512, hostTime: ticks(10))
        }
        XCTAssertEqual(track.framesWritten, 512)

        let fresh = RingBuffer(capacityFloats: 4096)
        track.setSinks([fresh])
        XCTAssertEqual(track.framesWritten, 0)
        XCTAssertEqual(track.anchorHostTime, 0)
    }
}
