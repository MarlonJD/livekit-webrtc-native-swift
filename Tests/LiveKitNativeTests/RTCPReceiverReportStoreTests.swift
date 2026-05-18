import Foundation
import XCTest
@testable import LiveKitNativeWebRTC

final class RTCPReceiverReportStoreTests: XCTestCase {
    func testBuildsReceiverReportWithLossJitterAndLastSenderReport() throws {
        let store = RTCPReceiverReportStore()
        let mediaSSRC: UInt32 = 0x0506_0708

        store.observe(
            RTPPacket(
                marker: false,
                payloadType: 102,
                sequenceNumber: 65_534,
                timestamp: 1_000,
                ssrc: mediaSSRC,
                payload: Data([0x01])
            ),
            arrivalRTPTime: 1_010
        )
        store.observe(
            RTPPacket(
                marker: false,
                payloadType: 102,
                sequenceNumber: 0,
                timestamp: 4_000,
                ssrc: mediaSSRC,
                payload: Data([0x02])
            ),
            arrivalRTPTime: 4_026
        )
        store.observe(
            .senderReport(
                RTCPSenderReport(
                    senderSSRC: mediaSSRC,
                    ntpTimestamp: 0x0123_4567_89AB_CDEF,
                    rtpTimestamp: 4_000,
                    packetCount: 2,
                    octetCount: 2
                )
            ),
            receivedAt: 10
        )

        let packet = try XCTUnwrap(store.receiverReportPacket(senderSSRC: 0x0102_0304, now: 10.5))
        guard case let .receiverReport(report) = packet else {
            return XCTFail("Expected receiver report.")
        }

        XCTAssertEqual(report.senderSSRC, 0x0102_0304)
        XCTAssertEqual(report.reports.count, 1)
        let receptionReport = try XCTUnwrap(report.reports.first)
        XCTAssertEqual(receptionReport.ssrc, mediaSSRC)
        XCTAssertEqual(receptionReport.highestSequenceNumber, 65_536)
        XCTAssertEqual(receptionReport.cumulativePacketsLost, 1)
        XCTAssertEqual(receptionReport.fractionLost, 85)
        XCTAssertEqual(receptionReport.jitter, 1)
        XCTAssertEqual(receptionReport.lastSenderReport, 0x4567_89AB)
        XCTAssertEqual(receptionReport.delaySinceLastSenderReport, 32_768)
    }

    func testReturnsNilBeforeAnyRTPPacketIsObserved() {
        let store = RTCPReceiverReportStore()

        XCTAssertNil(store.receiverReportPacket(senderSSRC: 0x0102_0304))
    }
}
