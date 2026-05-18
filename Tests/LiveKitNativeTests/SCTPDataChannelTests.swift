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

    func testPacketEnvelopeCodecRoundTripsStreamPPIDAndPayload() throws {
        let codec = SCTPDataChannelPacketEnvelopeCodec()
        let packet = SCTPDataChannelPacket(
            streamID: 3,
            ppid: .binary,
            payload: Data([0x01, 0x02, 0x03])
        )

        let encoded = codec.encode(packet)
        let decoded = try codec.decode(encoded)

        XCTAssertEqual(decoded, packet)
    }

    func testPacketEnvelopeCodecRejectsTruncatedEnvelope() {
        XCTAssertThrowsError(try SCTPDataChannelPacketEnvelopeCodec().decode(Data([0x00, 0x01]))) { error in
            XCTAssertEqual(error as? SCTPDataChannelError, .truncatedPacketEnvelope)
        }
    }

    func testFragmenterSplitsAndReassemblesDataChannelPacket() throws {
        let packet = SCTPDataChannelPacket(
            streamID: 4,
            ppid: .binary,
            payload: Data(0..<10)
        )
        var fragmenter = SCTPDataChannelFragmenter(maxFragmentPayloadSize: 4, firstMessageID: 42)
        let fragments = try fragmenter.fragment(packet)

        XCTAssertEqual(fragments.map(\.messageID), [42, 42, 42])
        XCTAssertEqual(fragments.map(\.fragmentIndex), [0, 1, 2])
        XCTAssertEqual(fragments.map(\.fragmentCount), [3, 3, 3])
        XCTAssertEqual(fragments.map(\.payload), [
            Data([0, 1, 2, 3]),
            Data([4, 5, 6, 7]),
            Data([8, 9]),
        ])

        var reassembler = SCTPDataChannelReassembler()
        XCTAssertNil(try reassembler.append(fragments[1]))
        XCTAssertNil(try reassembler.append(fragments[0]))
        let reassembled = try reassembler.append(fragments[2])

        XCTAssertEqual(reassembled, packet)
        XCTAssertEqual(reassembler.pendingMessageCount, 0)
    }

    func testFragmentEnvelopeRejectsDuplicateFragments() throws {
        let packet = SCTPDataChannelPacket(
            streamID: 4,
            ppid: .binary,
            payload: Data([1, 2, 3, 4])
        )
        var fragmenter = SCTPDataChannelFragmenter(maxFragmentPayloadSize: 2, firstMessageID: 7)
        let fragments = try fragmenter.fragment(packet)
        var reassembler = SCTPDataChannelReassembler()

        XCTAssertNil(try reassembler.append(fragments[0]))
        XCTAssertThrowsError(try reassembler.append(fragments[0])) { error in
            XCTAssertEqual(
                error as? SCTPDataChannelError,
                .duplicateFragment(messageID: 7, fragmentIndex: 0)
            )
        }
    }

    func testRetransmissionQueueSchedulesDueFragmentsAndDropsAcknowledgedOnes() throws {
        let packet = SCTPDataChannelPacket(
            streamID: 4,
            ppid: .binary,
            payload: Data(0..<6)
        )
        var fragmenter = SCTPDataChannelFragmenter(maxFragmentPayloadSize: 3, firstMessageID: 9)
        let fragments = try fragmenter.fragment(packet)
        let policy = SCTPDataChannelRetransmissionPolicy(
            initialDelaySeconds: 0.25,
            maxAttempts: 2
        )
        var queue = SCTPDataChannelRetransmissionQueue()

        queue.enqueue(fragments, at: 10)
        queue.markAcknowledged(messageID: 9, fragmentIndex: 0)

        let firstDue = try queue.dueFragments(at: 10, policy: policy)
        XCTAssertEqual(firstDue.map(\.envelope.fragmentIndex), [1])
        XCTAssertEqual(firstDue.map(\.attempt), [1])
        XCTAssertEqual(firstDue.map(\.nextTransmitAt), [10.25])

        XCTAssertEqual(try queue.dueFragments(at: 10.24, policy: policy), [])

        let secondDue = try queue.dueFragments(at: 10.25, policy: policy)
        XCTAssertEqual(secondDue.map(\.envelope.fragmentIndex), [1])
        XCTAssertEqual(secondDue.map(\.attempt), [2])
        XCTAssertEqual(secondDue.map(\.nextTransmitAt), [10.75])

        XCTAssertThrowsError(try queue.dueFragments(at: 10.75, policy: policy)) { error in
            XCTAssertEqual(
                error as? SCTPDataChannelError,
                .retransmissionAttemptsExhausted(messageID: 9, fragmentIndex: 1)
            )
        }
    }
}
