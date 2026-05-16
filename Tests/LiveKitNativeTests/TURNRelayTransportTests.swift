import Foundation
import XCTest
@testable import LiveKitNativeWebRTC

final class TURNRelayTransportTests: XCTestCase {
    func testSendEncodesChannelDataFrameToDatagramTransport() async throws {
        let datagrams = FakeTURNRelayDatagramTransport()
        let binding = try channelBinding(channelNumber: 0x4000)
        let transport = try TURNRelayTransport(
            datagramTransport: datagrams,
            channelBindings: [binding]
        )
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])

        try await transport.send(payload, to: binding)

        let expected = try TURNChannelDataFrame(
            channelNumber: 0x4000,
            payload: payload
        ).encoded()
        let sentDatagrams = await datagrams.sentDatagramsSnapshot()
        XCTAssertEqual(sentDatagrams, [expected])
    }

    func testReceiveDecodesInboundChannelDataDatagram() async throws {
        let binding = try channelBinding(channelNumber: 0x4001)
        let datagrams = FakeTURNRelayDatagramTransport(
            incomingDatagrams: [
                try TURNChannelDataFrame(
                    channelNumber: binding.channelNumber,
                    payload: Data([0x01, 0x02, 0x03])
                ).encoded(),
            ]
        )
        let transport = try TURNRelayTransport(
            datagramTransport: datagrams,
            channelBindings: [binding]
        )

        let packet = try await transport.receive()

        XCTAssertEqual(
            packet,
            TURNRelayPacket(
                channelNumber: binding.channelNumber,
                peerAddress: binding.peerAddress,
                payload: Data([0x01, 0x02, 0x03])
            )
        )
    }

    func testSendRejectsUnboundChannelBinding() async throws {
        let datagrams = FakeTURNRelayDatagramTransport()
        let bound = try channelBinding(channelNumber: 0x4000)
        let unbound = try channelBinding(channelNumber: 0x4001)
        let transport = try TURNRelayTransport(
            datagramTransport: datagrams,
            channelBindings: [bound]
        )

        do {
            try await transport.send(Data([0x01]), to: unbound)
            XCTFail("Expected unbound channel failure.")
        } catch {
            XCTAssertEqual(error as? TURNRelayTransportError, .unboundChannelNumber(0x4001))
        }

        let sentDatagrams = await datagrams.sentDatagramsSnapshot()
        XCTAssertEqual(sentDatagrams, [])
    }

    func testStreamDecoderReturnsPartialInboundRemainder() throws {
        let binding = try channelBinding(channelNumber: 0x4002)
        let decoder = try TURNRelayInboundDecoder(channelBindings: [binding])
        let partial = Data([0x40, 0x02, 0x00, 0x04, 0xAA, 0xBB])

        let decoded = try decoder.decodeStream(partial)

        XCTAssertEqual(decoded.packets, [])
        XCTAssertEqual(decoded.remainder, partial)
    }

    func testReceiveWaitsAcrossPartialInboundDatagrams() async throws {
        let binding = try channelBinding(channelNumber: 0x4003)
        let encoded = try TURNChannelDataFrame(
            channelNumber: binding.channelNumber,
            payload: Data([0xCA, 0xFE, 0xBA, 0xBE])
        ).encoded()
        let splitIndex = encoded.index(encoded.startIndex, offsetBy: 5)
        let datagrams = FakeTURNRelayDatagramTransport(
            incomingDatagrams: [
                Data(encoded[..<splitIndex]),
                Data(encoded[splitIndex...]),
            ]
        )
        let transport = try TURNRelayTransport(
            datagramTransport: datagrams,
            channelBindings: [binding]
        )

        let packet = try await transport.receive()

        XCTAssertEqual(packet.channelNumber, binding.channelNumber)
        XCTAssertEqual(packet.peerAddress, binding.peerAddress)
        XCTAssertEqual(packet.payload, Data([0xCA, 0xFE, 0xBA, 0xBE]))
    }

    func testInvalidChannelPropagatesChannelDataError() throws {
        let decoder = try TURNRelayInboundDecoder(
            channelBindings: [channelBinding(channelNumber: 0x4000)]
        )

        XCTAssertThrowsError(
            try decoder.decodeDatagram(Data([0x3F, 0xFF, 0x00, 0x00]))
        ) { error in
            XCTAssertEqual(error as? TURNChannelDataError, .invalidChannelNumber(0x3FFF))
        }
    }

    func testInvalidLengthPropagatesChannelDataError() throws {
        let decoder = try TURNRelayInboundDecoder(
            channelBindings: [channelBinding(channelNumber: 0x4000)]
        )

        XCTAssertThrowsError(
            try decoder.decodeDatagram(Data([0x40, 0x00, 0x00, 0x04, 0xAA, 0xBB]))
        ) { error in
            XCTAssertEqual(
                error as? TURNChannelDataError,
                .invalidLength(declaredPayloadLength: 4, availableFrameBytes: 2)
            )
        }
    }

    func testUnboundInboundChannelPropagatesRelayError() throws {
        let decoder = try TURNRelayInboundDecoder(
            channelBindings: [channelBinding(channelNumber: 0x4000)]
        )
        let datagram = try TURNChannelDataFrame(
            channelNumber: 0x4001,
            payload: Data([0x01])
        ).encoded()

        XCTAssertThrowsError(try decoder.decodeDatagram(datagram)) { error in
            XCTAssertEqual(error as? TURNRelayTransportError, .unboundChannelNumber(0x4001))
        }
    }

    private func channelBinding(channelNumber: UInt16) throws -> TURNRelayChannelBinding {
        try TURNRelayChannelBinding(
            channelNumber: channelNumber,
            peerAddress: STUNMappedAddress(address: "203.0.113.9", port: 5_000)
        )
    }
}

private actor FakeTURNRelayDatagramTransport: MediaDatagramTransport {
    private var sentDatagrams: [Data]
    private var incomingDatagrams: [Data]

    init(sentDatagrams: [Data] = [], incomingDatagrams: [Data] = []) {
        self.sentDatagrams = sentDatagrams
        self.incomingDatagrams = incomingDatagrams
    }

    func sentDatagramsSnapshot() -> [Data] {
        sentDatagrams
    }

    func send(_ datagram: Data) async throws {
        sentDatagrams.append(datagram)
    }

    func receive() async throws -> Data {
        guard !incomingDatagrams.isEmpty else {
            throw FakeTURNRelayDatagramTransportError.empty
        }

        return incomingDatagrams.removeFirst()
    }
}

private enum FakeTURNRelayDatagramTransportError: Error {
    case empty
}
