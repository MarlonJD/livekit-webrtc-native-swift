import XCTest
@testable import LiveKitNativeWebRTC

final class SCTPDataChannelTests: XCTestCase {
    func testReliableOpenMessageRoundTrips() throws {
        let message = SCTPDataChannelControlMessage.open(
            SCTPDataChannelOpenMessage(reliability: .reliable, label: LiveKitSCTPDataChannelLabel.reliable)
        )
        let encoded = message.encoded()
        let decoded = try SCTPDataChannelControlMessage(decoding: encoded)

        XCTAssertEqual(encoded.first, 0x03)
        XCTAssertEqual(encoded[encoded.index(encoded.startIndex, offsetBy: 1)], 0x00)
        XCTAssertEqual(decoded, message)
    }

    func testLossyOpenMessageUsesUnorderedPartialReliableChannelType() throws {
        let message = SCTPDataChannelControlMessage.open(
            SCTPDataChannelOpenMessage(reliability: .lossy, label: LiveKitSCTPDataChannelLabel.lossy)
        )
        let encoded = message.encoded()
        let decoded = try SCTPDataChannelControlMessage(decoding: encoded)

        XCTAssertEqual(encoded[encoded.index(encoded.startIndex, offsetBy: 1)], 0x81)
        XCTAssertEqual(decoded, message)
    }

    func testAcknowledgementOpensChannel() throws {
        let channel = SCTPDataChannel(streamID: 0, label: LiveKitSCTPDataChannelLabel.reliable, reliability: .reliable)
        XCTAssertEqual(channel.state, .connecting)

        let ack = SCTPDataChannelControlMessage.acknowledgement
        XCTAssertEqual(try SCTPDataChannelControlMessage(decoding: ack.encoded()), .acknowledgement)

        channel.acceptAcknowledgement()

        XCTAssertEqual(channel.state, .open)
    }

    func testManagerRoutesLiveKitReliableAndLossyChannels() throws {
        let manager = SCTPDataChannelManager()
        let reliable = manager.ensureLiveKitChannel(for: .reliable)
        let lossy = manager.ensureLiveKitChannel(for: .lossy)

        XCTAssertEqual(reliable.streamID, 0)
        XCTAssertEqual(reliable.label, LiveKitSCTPDataChannelLabel.reliable)
        XCTAssertEqual(lossy.streamID, 2)
        XCTAssertEqual(lossy.label, LiveKitSCTPDataChannelLabel.lossy)

        try manager.acceptControlPacket(SCTPDataChannelPacket(
            streamID: reliable.streamID,
            ppid: .dataChannelControl,
            payload: SCTPDataChannelControlMessage.acknowledgement.encoded()
        ))
        let packet = try manager.makeBinaryPacket(label: LiveKitSCTPDataChannelLabel.reliable, payload: Data([0x01, 0x02]))

        XCTAssertEqual(packet.streamID, 0)
        XCTAssertEqual(packet.ppid, .binary)
        XCTAssertEqual(packet.payload, Data([0x01, 0x02]))
    }

    func testManagerRejectsSendBeforeChannelOpen() throws {
        let manager = SCTPDataChannelManager()
        _ = manager.ensureLiveKitChannel(for: .reliable)

        XCTAssertThrowsError(
            try manager.makeBinaryPacket(label: LiveKitSCTPDataChannelLabel.reliable, payload: Data([0x01]))
        ) { error in
            XCTAssertEqual(error as? SCTPDataChannelError, .channelNotOpen(0))
        }
    }
}
