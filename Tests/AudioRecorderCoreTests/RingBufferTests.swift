import XCTest
@testable import AudioRecorderCore

final class RingBufferTests: XCTestCase {
    func testWriteReadRoundTrip() {
        let ring = RingBuffer(capacityFloats: 1024)
        let input: [Float] = (0..<512).map { Float($0) }
        input.withUnsafeBufferPointer { buffer in
            XCTAssertTrue(ring.write(buffer.baseAddress!, count: buffer.count))
        }
        XCTAssertEqual(ring.availableToRead, 512)

        var output = [Float](repeating: -1, count: 512)
        let read = output.withUnsafeMutableBufferPointer { buffer in
            ring.read(into: buffer.baseAddress!, maxCount: buffer.count)
        }
        XCTAssertEqual(read, 512)
        XCTAssertEqual(output, input)
        XCTAssertEqual(ring.availableToRead, 0)
    }

    func testWraparound() {
        let ring = RingBuffer(capacityFloats: 100)
        var scratch = [Float](repeating: 0, count: 100)

        // Fill and drain repeatedly with a size that does not divide capacity,
        // forcing the copy to wrap.
        var expectedNext: Float = 0
        var writeNext: Float = 0
        for _ in 0..<50 {
            let chunk: [Float] = (0..<33).map { _ in
                defer { writeNext += 1 }
                return writeNext
            }
            chunk.withUnsafeBufferPointer { buffer in
                XCTAssertTrue(ring.write(buffer.baseAddress!, count: buffer.count))
            }
            let read = scratch.withUnsafeMutableBufferPointer { buffer in
                ring.read(into: buffer.baseAddress!, maxCount: 33)
            }
            XCTAssertEqual(read, 33)
            for i in 0..<33 {
                XCTAssertEqual(scratch[i], expectedNext)
                expectedNext += 1
            }
        }
    }

    func testOverflowDropsAndCounts() {
        let ring = RingBuffer(capacityFloats: 64)
        let big = [Float](repeating: 1, count: 65)
        let ok = big.withUnsafeBufferPointer { buffer in
            ring.write(buffer.baseAddress!, count: buffer.count)
        }
        XCTAssertFalse(ok)
        XCTAssertEqual(ring.dropped, 65)
        XCTAssertEqual(ring.availableToRead, 0)

        // Exactly capacity fits.
        let fit = [Float](repeating: 2, count: 64)
        let ok2 = fit.withUnsafeBufferPointer { buffer in
            ring.write(buffer.baseAddress!, count: buffer.count)
        }
        XCTAssertTrue(ok2)
        XCTAssertEqual(ring.availableToRead, 64)
    }

    func testReadFromEmptyReturnsZero() {
        let ring = RingBuffer(capacityFloats: 16)
        var out = [Float](repeating: 0, count: 16)
        let read = out.withUnsafeMutableBufferPointer { buffer in
            ring.read(into: buffer.baseAddress!, maxCount: 16)
        }
        XCTAssertEqual(read, 0)
    }
}
