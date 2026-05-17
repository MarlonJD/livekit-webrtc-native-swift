import Foundation
@testable import LiveKitNativeWebRTC
import XCTest

final class RTPJitterBufferTests: XCTestCase {
    func testInOrderPacketsReleaseImmediately() {
        var jitterBuffer = RTPJitterBuffer(maxBufferedPackets: 8)

        let firstResult = jitterBuffer.insert(packet(sequenceNumber: 10))
        let secondResult = jitterBuffer.insert(packet(sequenceNumber: 11))
        let thirdResult = jitterBuffer.insert(packet(sequenceNumber: 12))

        XCTAssertEqual(sequenceNumbers(firstResult.releasedPackets), [10])
        XCTAssertEqual(sequenceNumbers(secondResult.releasedPackets), [11])
        XCTAssertEqual(sequenceNumbers(thirdResult.releasedPackets), [12])
        XCTAssertTrue(firstResult.droppedSequenceNumbers.isEmpty)
        XCTAssertTrue(secondResult.droppedSequenceNumbers.isEmpty)
        XCTAssertTrue(thirdResult.droppedSequenceNumbers.isEmpty)
    }

    func testOutOfOrderPacketsReleaseWhenGapFills() {
        var jitterBuffer = RTPJitterBuffer(maxBufferedPackets: 8)

        XCTAssertEqual(sequenceNumbers(jitterBuffer.insert(packet(sequenceNumber: 10)).releasedPackets), [10])
        XCTAssertTrue(jitterBuffer.insert(packet(sequenceNumber: 12)).releasedPackets.isEmpty)

        let result = jitterBuffer.insert(packet(sequenceNumber: 11))

        XCTAssertEqual(sequenceNumbers(result.releasedPackets), [11, 12])
        XCTAssertTrue(result.missingSequenceNumbers.isEmpty)
    }

    func testSequenceNumberWrapReordersAcrossBoundary() {
        var jitterBuffer = RTPJitterBuffer(maxBufferedPackets: 8)

        XCTAssertEqual(sequenceNumbers(jitterBuffer.insert(packet(sequenceNumber: 65_534)).releasedPackets), [65_534])
        XCTAssertTrue(jitterBuffer.insert(packet(sequenceNumber: 0)).releasedPackets.isEmpty)

        let result = jitterBuffer.insert(packet(sequenceNumber: 65_535))

        XCTAssertEqual(sequenceNumbers(result.releasedPackets), [65_535, 0])
    }

    func testDuplicateAndOldPacketsDropDeterministically() {
        var jitterBuffer = RTPJitterBuffer(maxBufferedPackets: 8)

        XCTAssertEqual(sequenceNumbers(jitterBuffer.insert(packet(sequenceNumber: 10)).releasedPackets), [10])

        let oldResult = jitterBuffer.insert(packet(sequenceNumber: 10))
        XCTAssertTrue(oldResult.releasedPackets.isEmpty)
        XCTAssertEqual(oldResult.droppedSequenceNumbers, [10])

        XCTAssertTrue(jitterBuffer.insert(packet(sequenceNumber: 12)).releasedPackets.isEmpty)

        let duplicateResult = jitterBuffer.insert(packet(sequenceNumber: 12))
        XCTAssertTrue(duplicateResult.releasedPackets.isEmpty)
        XCTAssertEqual(duplicateResult.droppedSequenceNumbers, [12])
    }

    func testBoundedGapSkipReportsMissingSequenceNumbers() {
        var jitterBuffer = RTPJitterBuffer(maxBufferedPackets: 2)

        XCTAssertEqual(sequenceNumbers(jitterBuffer.insert(packet(sequenceNumber: 100)).releasedPackets), [100])
        XCTAssertTrue(jitterBuffer.insert(packet(sequenceNumber: 103)).releasedPackets.isEmpty)
        XCTAssertTrue(jitterBuffer.insert(packet(sequenceNumber: 104)).releasedPackets.isEmpty)

        let result = jitterBuffer.insert(packet(sequenceNumber: 105))

        XCTAssertEqual(result.missingSequenceNumbers, [101, 102])
        XCTAssertEqual(sequenceNumbers(result.releasedPackets), [103, 104, 105])
        XCTAssertTrue(result.droppedSequenceNumbers.isEmpty)
    }

    func testFlushReleasesBufferedPacketsInSequenceOrder() {
        var jitterBuffer = RTPJitterBuffer(maxBufferedPackets: 8)

        XCTAssertEqual(sequenceNumbers(jitterBuffer.insert(packet(sequenceNumber: 10)).releasedPackets), [10])
        XCTAssertTrue(jitterBuffer.insert(packet(sequenceNumber: 14)).releasedPackets.isEmpty)
        XCTAssertTrue(jitterBuffer.insert(packet(sequenceNumber: 12)).releasedPackets.isEmpty)
        XCTAssertTrue(jitterBuffer.insert(packet(sequenceNumber: 13)).releasedPackets.isEmpty)

        let flushedPackets = jitterBuffer.flush()

        XCTAssertEqual(sequenceNumbers(flushedPackets), [12, 13, 14])
        XCTAssertTrue(jitterBuffer.flush().isEmpty)
    }

    private func packet(sequenceNumber: UInt16) -> RTPPacket {
        RTPPacket(
            marker: false,
            payloadType: 111,
            sequenceNumber: sequenceNumber,
            timestamp: UInt32(sequenceNumber),
            ssrc: 0x0102_0304,
            payload: Data([UInt8(truncatingIfNeeded: sequenceNumber)])
        )
    }

    private func sequenceNumbers(_ packets: [RTPPacket]) -> [UInt16] {
        packets.map { $0.sequenceNumber }
    }
}
