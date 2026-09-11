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

    // MARK: - Mute

    /// Muting must substitute silence rather than drop frames: dropping would
    /// shorten the track and pull everything after the muted span backwards in
    /// the merged timeline.
    func testMutedAppendWritesSilenceButKeepsTheTimeline() {
        let (track, ring) = makeTrack()
        let tone = [Float](repeating: 0.5, count: 512 * 2)
        let second = ticks(1) + UInt64(512.0 / rate * ticksPerSecond)

        tone.withUnsafeBufferPointer {
            track.append($0.baseAddress!, frameCount: 512, hostTime: ticks(1))
        }
        track.setMuted(true)
        tone.withUnsafeBufferPointer {
            track.append($0.baseAddress!, frameCount: 512, hostTime: second)
        }

        XCTAssertEqual(track.framesWritten, 1024, "muted frames must still be written")
        XCTAssertEqual(track.framesMuted, 512)

        var output = [Float](repeating: -1, count: 1024 * 2)
        let read = output.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, maxCount: $0.count)
        }
        XCTAssertEqual(read, 1024 * 2)
        XCTAssertTrue(
            output[0..<(512 * 2)].allSatisfy { $0 == 0.5 }, "first buffer should be audible"
        )
        XCTAssertTrue(
            output[(512 * 2)...].allSatisfy { $0 == 0 }, "muted buffer should be silence"
        )
    }

    func testUnmutingRestoresAudio() {
        let (track, ring) = makeTrack()
        let tone = [Float](repeating: 0.25, count: 256 * 2)
        let second = ticks(1) + UInt64(256.0 / rate * ticksPerSecond)

        track.setMuted(true)
        tone.withUnsafeBufferPointer {
            track.append($0.baseAddress!, frameCount: 256, hostTime: ticks(1))
        }
        track.setMuted(false)
        tone.withUnsafeBufferPointer {
            track.append($0.baseAddress!, frameCount: 256, hostTime: second)
        }

        XCTAssertEqual(track.framesMuted, 256, "only the muted span should be counted")
        var output = [Float](repeating: -1, count: 512 * 2)
        _ = output.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, maxCount: $0.count)
        }
        XCTAssertTrue(output[0..<(256 * 2)].allSatisfy { $0 == 0 })
        XCTAssertTrue(output[(256 * 2)...].allSatisfy { $0 == 0.25 })
    }

    func testMuteStateIsReadableAndSurvivesSinkChanges() {
        let track = CaptureTrack(label: "test", sampleRate: rate)
        XCTAssertFalse(track.isMuted)
        track.setMuted(true)
        XCTAssertTrue(track.isMuted)
        // Attaching sinks resets counters but must not silently unmute.
        track.setSinks([RingBuffer(capacityFloats: 1024)])
        XCTAssertTrue(track.isMuted)
        XCTAssertEqual(track.framesMuted, 0, "counters reset for the new recording")
    }

    /// A muted span longer than the internal silence chunk must still be
    /// written in full.
    func testLongMutedSpanIsWrittenInFull() {
        let frames = 10_000
        let track = CaptureTrack(label: "test", sampleRate: rate)
        let ring = RingBuffer(capacityFloats: frames * 2 * 2)
        track.setSinks([ring])
        track.setMuted(true)

        let tone = [Float](repeating: 0.9, count: frames * 2)
        tone.withUnsafeBufferPointer {
            track.append($0.baseAddress!, frameCount: frames, hostTime: ticks(1))
        }

        XCTAssertEqual(track.framesMuted, frames)
        var output = [Float](repeating: -1, count: frames * 2)
        let read = output.withUnsafeMutableBufferPointer {
            ring.read(into: $0.baseAddress!, maxCount: $0.count)
        }
        XCTAssertEqual(read, frames * 2)
        XCTAssertTrue(output.allSatisfy { $0 == 0 })
    }
}
