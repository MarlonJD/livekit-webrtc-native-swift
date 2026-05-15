import Foundation
import XCTest
@testable import LiveKitNativeWebRTC

final class SecureMediaTransportTests: XCTestCase {
    func testSendsProtectedRTPDatagramAndPeerReceivesPlainRTP() async throws {
        let clientDatagrams = MockMediaDatagramTransport()
        let serverDatagrams = MockMediaDatagramTransport()
        let client = try DTLSSRTPMediaTransport(
            packetProtectionContext: packetProtectionContext(role: .client),
            datagramTransport: clientDatagrams
        )
        let server = try DTLSSRTPMediaTransport(
            packetProtectionContext: packetProtectionContext(role: .server),
            datagramTransport: serverDatagrams
        )
        let packet = rtp(sequenceNumber: 17, payload: Data((0..<48).map(UInt8.init)))

        try await client.sendRTP(packet)
        let sentDatagrams = await clientDatagrams.sentDatagramsSnapshot()
        let protected = try XCTUnwrap(sentDatagrams.first)
        await serverDatagrams.enqueue(protected)

        let received = try await server.receive()

        XCTAssertNotEqual(protected, packet.encoded())
        XCTAssertEqual(protected.count, packet.encoded().count + SRTPProtectedPacket.defaultAuthenticationTagLength)
        XCTAssertEqual(received, .rtp(packet))
    }

    func testSendsProtectedRTCPDatagramAndPeerReceivesPlainRTCP() async throws {
        let clientDatagrams = MockMediaDatagramTransport()
        let serverDatagrams = MockMediaDatagramTransport()
        let client = try DTLSSRTPMediaTransport(
            packetProtectionContext: packetProtectionContext(role: .client),
            datagramTransport: clientDatagrams
        )
        let server = try DTLSSRTPMediaTransport(
            packetProtectionContext: packetProtectionContext(role: .server),
            datagramTransport: serverDatagrams
        )
        let packet = rtcp()

        try await client.sendRTCP(packet)
        let sentDatagrams = await clientDatagrams.sentDatagramsSnapshot()
        let protected = try XCTUnwrap(sentDatagrams.first)
        let encodedSRTCP = try SRTCPPacket(decoding: protected)
        await serverDatagrams.enqueue(protected)

        let received = try await server.receive()

        XCTAssertTrue(encodedSRTCP.index.isEncrypted)
        XCTAssertEqual(encodedSRTCP.authenticationTag.count, SRTCPPacket.defaultAuthenticationTagLength)
        XCTAssertEqual(received, .rtcp(packet))
    }

    func testIncomingRTPReplayIsRejected() async throws {
        let clientDatagrams = MockMediaDatagramTransport()
        let serverDatagrams = MockMediaDatagramTransport()
        let client = try DTLSSRTPMediaTransport(
            packetProtectionContext: packetProtectionContext(role: .client),
            datagramTransport: clientDatagrams
        )
        let server = try DTLSSRTPMediaTransport(
            packetProtectionContext: packetProtectionContext(role: .server),
            datagramTransport: serverDatagrams
        )

        try await client.sendRTP(rtp(sequenceNumber: 33, payload: Data([0x01])))
        let sentDatagrams = await clientDatagrams.sentDatagramsSnapshot()
        let protected = try XCTUnwrap(sentDatagrams.first)
        await serverDatagrams.enqueue(protected)
        await serverDatagrams.enqueue(protected)

        _ = try await server.receive()
        do {
            _ = try await server.receive()
            XCTFail("Expected replay rejection")
        } catch {
            XCTAssertEqual(error as? SRTPError, .replayedPacket)
        }
    }

    func testRTPRolloverCounterIsTrackedAcrossTransportBoundary() async throws {
        let clientDatagrams = MockMediaDatagramTransport()
        let serverDatagrams = MockMediaDatagramTransport()
        let client = try DTLSSRTPMediaTransport(
            packetProtectionContext: packetProtectionContext(role: .client),
            datagramTransport: clientDatagrams
        )
        let server = try DTLSSRTPMediaTransport(
            packetProtectionContext: packetProtectionContext(role: .server),
            datagramTransport: serverDatagrams
        )
        let beforeWrap = rtp(sequenceNumber: UInt16.max, payload: Data([0xAA]))
        let afterWrap = rtp(sequenceNumber: 0, payload: Data([0xBB]))

        try await client.sendRTP(beforeWrap)
        try await client.sendRTP(afterWrap)
        let protected = await clientDatagrams.sentDatagramsSnapshot()
        XCTAssertEqual(protected.count, 2)
        await serverDatagrams.enqueue(protected[0])
        await serverDatagrams.enqueue(protected[1])

        let firstReceived = try await server.receive()
        let secondReceived = try await server.receive()
        XCTAssertEqual(firstReceived, .rtp(beforeWrap))
        XCTAssertEqual(secondReceived, .rtp(afterWrap))
    }

    func testRejectsTooShortIncomingDatagram() async throws {
        let datagrams = MockMediaDatagramTransport()
        let transport = try DTLSSRTPMediaTransport(
            packetProtectionContext: packetProtectionContext(role: .server),
            datagramTransport: datagrams
        )
        await datagrams.enqueue(Data([0x80]))

        do {
            _ = try await transport.receive()
            XCTFail("Expected short datagram rejection")
        } catch {
            XCTAssertEqual(error as? SecureMediaTransportError, .packetTooShort)
        }
    }

    private func packetProtectionContext(role: DTLSSRTPRole) throws -> DTLSSRTPPacketProtectionContext {
        try DTLSSRTPPacketProtectionContext(
            keyMaterial: DTLSSRTPKeyMaterial(
                exportedKeyingMaterial: Data((0..<SRTPProtectionProfile.aes128CMHMACSHA180.exporterByteCount).map(UInt8.init))
            ),
            role: role
        )
    }

    private func rtp(sequenceNumber: UInt16, payload: Data) -> RTPPacket {
        RTPPacket(
            marker: true,
            payloadType: 102,
            sequenceNumber: sequenceNumber,
            timestamp: 90_000,
            ssrc: 0x1122_3344,
            payload: payload
        )
    }

    private func rtcp() -> RTCPPacket {
        .pictureLossIndication(
            RTCPPictureLossIndication(
                senderSSRC: 0x0102_0304,
                mediaSSRC: 0x0506_0708
            )
        )
    }
}

private actor MockMediaDatagramTransport: MediaDatagramTransport {
    private(set) var sentDatagrams: [Data]
    private var incomingDatagrams: [Data]

    init(sentDatagrams: [Data] = [], incomingDatagrams: [Data] = []) {
        self.sentDatagrams = sentDatagrams
        self.incomingDatagrams = incomingDatagrams
    }

    func enqueue(_ datagram: Data) {
        incomingDatagrams.append(datagram)
    }

    func sentDatagramsSnapshot() -> [Data] {
        sentDatagrams
    }

    func send(_ datagram: Data) async throws {
        sentDatagrams.append(datagram)
    }

    func receive() async throws -> Data {
        guard !incomingDatagrams.isEmpty else {
            throw MockMediaDatagramTransportError.empty
        }

        return incomingDatagrams.removeFirst()
    }
}

private enum MockMediaDatagramTransportError: Error {
    case empty
}
