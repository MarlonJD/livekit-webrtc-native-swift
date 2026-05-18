import Foundation
import XCTest
@testable import LiveKitNativeWebRTC

final class RTCPTests: XCTestCase {
    func testSenderReportRoundTripsWithReceptionReport() throws {
        let packet = RTCPPacket.senderReport(
            RTCPSenderReport(
                senderSSRC: 0x0102_0304,
                ntpTimestamp: 0x0102_0304_0506_0708,
                rtpTimestamp: 90_000,
                packetCount: 12,
                octetCount: 3_456,
                reports: [receptionReport(cumulativePacketsLost: -3)]
            )
        )

        let encoded = try packet.encoded()
        let decoded = try RTCPPacket(decoding: encoded)

        XCTAssertEqual(decoded, packet)
        XCTAssertEqual(encoded[0], 0x81)
        XCTAssertEqual(encoded[1], 200)
    }

    func testReceiverReportRoundTrips() throws {
        let packet = RTCPPacket.receiverReport(
            RTCPReceiverReport(
                senderSSRC: 0x1111_2222,
                reports: [receptionReport(cumulativePacketsLost: 7)]
            )
        )

        let decoded = try RTCPPacket(decoding: try packet.encoded())

        XCTAssertEqual(decoded, packet)
    }

    func testPictureLossIndicationRoundTrips() throws {
        let packet = RTCPPacket.pictureLossIndication(
            RTCPPictureLossIndication(senderSSRC: 0x0102_0304, mediaSSRC: 0x0506_0708)
        )
        let encoded = try packet.encoded()

        XCTAssertEqual(encoded[0], 0x81)
        XCTAssertEqual(encoded[1], 206)
        XCTAssertEqual(try RTCPPacket(decoding: encoded), packet)
    }

    func testTransportLayerNACKPacksAndRoundTripsBitmask() throws {
        let nack = RTCPTransportLayerNACK(
            senderSSRC: 0x0102_0304,
            mediaSSRC: 0x0506_0708,
            lostPacketIDs: [100, 101, 103, 120]
        )
        let packet = RTCPPacket.transportLayerNACK(nack)
        let encoded = try packet.encoded()

        XCTAssertEqual(encoded[0], 0x81)
        XCTAssertEqual(encoded[1], 205)
        XCTAssertEqual(try encoded.networkUInt16ForTest(at: 12), 100)
        XCTAssertEqual(try encoded.networkUInt16ForTest(at: 14), 0b0000_0000_0000_0101)
        XCTAssertEqual(try RTCPPacket(decoding: encoded), packet)
    }

    func testReceiverEstimatedMaximumBitrateRoundTrips() throws {
        let packet = RTCPPacket.receiverEstimatedMaximumBitrate(
            RTCPReceiverEstimatedMaximumBitrate(
                senderSSRC: 0x0102_0304,
                mediaSSRC: 0,
                bitrateBps: 1_000_000,
                ssrcs: [0x0506_0708, 0x1112_1314]
            )
        )
        let encoded = try packet.encoded()

        XCTAssertEqual(encoded[0], 0x8F)
        XCTAssertEqual(encoded[1], 206)
        XCTAssertEqual(try RTCPPacket(decoding: encoded), packet)
    }

    func testRejectsUnsupportedRTCPVersion() throws {
        var encoded = try RTCPPacket.pictureLossIndication(
            RTCPPictureLossIndication(senderSSRC: 1, mediaSSRC: 2)
        ).encoded()
        encoded[0] = 0x40

        XCTAssertThrowsError(try RTCPPacket(decoding: encoded)) { error in
            XCTAssertEqual(error as? RTCPError, .unsupportedVersion(1))
        }
    }

    func testRejectsInvalidRTCPPacketLength() throws {
        var encoded = try RTCPPacket.receiverReport(RTCPReceiverReport(senderSSRC: 1)).encoded()
        encoded.removeLast()

        XCTAssertThrowsError(try RTCPPacket(decoding: encoded)) { error in
            XCTAssertEqual(error as? RTCPError, .invalidLength)
        }
    }

    func testRejectsTooManyReceptionReports() {
        let reports = Array(repeating: receptionReport(cumulativePacketsLost: 0), count: 32)
        let packet = RTCPPacket.receiverReport(RTCPReceiverReport(senderSSRC: 1, reports: reports))

        XCTAssertThrowsError(try packet.encoded()) { error in
            XCTAssertEqual(error as? RTCPError, .reportCountExceedsLimit(32))
        }
    }

    private func receptionReport(cumulativePacketsLost: Int32) -> RTCPReceptionReport {
        RTCPReceptionReport(
            ssrc: 0xAABB_CCDD,
            fractionLost: 7,
            cumulativePacketsLost: cumulativePacketsLost,
            highestSequenceNumber: 0x0001_0002,
            jitter: 33,
            lastSenderReport: 44,
            delaySinceLastSenderReport: 55
        )
    }
}

private extension Data {
    func networkUInt16ForTest(at offset: Int) throws -> UInt16 {
        guard offset >= 0, offset + 2 <= count else {
            throw RTCPError.invalidLength
        }

        let first = index(startIndex, offsetBy: offset)
        let second = index(after: first)
        return UInt16(self[first]) << 8 | UInt16(self[second])
    }
}
