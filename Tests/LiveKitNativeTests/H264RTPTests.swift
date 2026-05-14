import Foundation
import XCTest
@testable import LiveKitNativeWebRTC

final class H264RTPTests: XCTestCase {
    func testPacketizesAndDepacketizesSingleNALUnit() throws {
        let nalUnit = Data([0x65, 0x88, 0x84, 0x21])
        let packetizer = H264RTPPacketizer(payloadType: 102, mtu: 1_200)
        let packets = try packetizer.packetize(
            nalUnits: [nalUnit],
            timestamp: 9_000,
            ssrc: 0x0102_0304,
            startingSequenceNumber: 12
        )

        XCTAssertEqual(packets.count, 1)
        XCTAssertEqual(packets[0].marker, true)
        XCTAssertEqual(packets[0].sequenceNumber, 12)
        XCTAssertEqual(packets[0].payload, nalUnit)

        let depacketizer = H264RTPDepacketizer()
        XCTAssertEqual(try depacketizer.append(packets[0]), [nalUnit])
    }

    func testPacketizesAndDepacketizesFUAFragments() throws {
        let nalUnit = Data([0x65] + Array(1...24))
        let packetizer = H264RTPPacketizer(payloadType: 102, mtu: 20)
        let packets = try packetizer.packetize(
            nalUnits: [nalUnit],
            timestamp: 90_000,
            ssrc: 0x0A0B_0C0D,
            startingSequenceNumber: 65_530
        )

        XCTAssertGreaterThan(packets.count, 1)
        XCTAssertEqual(packets.first?.payload.first, 0x7C)
        XCTAssertEqual(packets.first?.payload.dropFirst().first.map { $0 & 0x80 }, 0x80)
        XCTAssertEqual(packets.last?.payload.dropFirst().first.map { $0 & 0x40 }, 0x40)
        XCTAssertEqual(packets.last?.marker, true)

        let depacketizer = H264RTPDepacketizer()
        var output: [Data] = []
        for packet in packets {
            output.append(contentsOf: try depacketizer.append(packet))
        }

        XCTAssertEqual(output, [nalUnit])
    }

    func testBuildsAndDepacketizesSTAPAParameterSets() throws {
        let sps = Data([0x67, 0x42, 0x00, 0x1F])
        let pps = Data([0x68, 0xCE, 0x06, 0xE2])
        let payload = try H264RTPPacketizer.makeSTAPA(nalUnits: [sps, pps])
        let packet = RTPPacket(
            marker: false,
            payloadType: 102,
            sequenceNumber: 77,
            timestamp: 1_000,
            ssrc: 42,
            payload: payload
        )

        XCTAssertEqual(payload.first.map { $0 & 0x1F }, H264NALUnitType.stapA.rawValue)
        XCTAssertEqual(try H264RTPDepacketizer().append(packet), [sps, pps])
    }

    func testDetectsMissingFUAStart() {
        let packet = RTPPacket(
            marker: false,
            payloadType: 102,
            sequenceNumber: 1,
            timestamp: 1,
            ssrc: 1,
            payload: Data([0x7C, 0x05, 0xAA])
        )

        XCTAssertThrowsError(try H264RTPDepacketizer().append(packet)) { error in
            XCTAssertEqual(error as? H264RTPError, .missingFragmentStart)
        }
    }
}
