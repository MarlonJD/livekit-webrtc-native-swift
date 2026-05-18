import XCTest
@testable import LiveKitNative
@testable import LiveKitNativeProtocol
@testable import LiveKitNativeWebRTC

final class LiveKitDataPacketTests: XCTestCase {
    func testLocalDataPublishPlanBuildsReliableUserPacket() throws {
        let payload = Data("hello".utf8)
        let plan = try LocalDataPublishPlan(
            data: payload,
            options: DataPublishOptions(
                reliable: true,
                topic: "chat",
                destinationIdentities: ["alice"]
            ),
            participantSid: "PA_local",
            participantIdentity: "local"
        )
        let decoded = try Livekit_DataPacket(serializedBytes: plan.encodedPacket)

        XCTAssertEqual(plan.reliability, .reliable)
        XCTAssertEqual(plan.channelLabel, LiveKitSCTPDataChannelLabel.reliable)
        XCTAssertEqual(decoded.kind, .reliable)
        XCTAssertEqual(decoded.user.payload, payload)
        XCTAssertEqual(decoded.user.topic, "chat")
        XCTAssertEqual(decoded.destinationIdentities, ["alice"])
        XCTAssertEqual(decoded.participantSid, "PA_local")
        XCTAssertEqual(decoded.participantIdentity, "local")
    }

    func testLocalDataPublishPlanBuildsLossyUserPacket() throws {
        let plan = try LocalDataPublishPlan(
            data: Data([0x01, 0x02, 0x03]),
            options: DataPublishOptions(reliable: false)
        )
        let decoded = try Livekit_DataPacket(serializedBytes: plan.encodedPacket)

        XCTAssertEqual(plan.reliability, .lossy)
        XCTAssertEqual(plan.channelLabel, LiveKitSCTPDataChannelLabel.lossy)
        XCTAssertEqual(decoded.kind, .lossy)
        XCTAssertEqual(decoded.user.payload, Data([0x01, 0x02, 0x03]))
    }

    func testReceivedUserPacketMapping() throws {
        let packet = LiveKitDataPacketMapper.makeUserPacket(
            data: Data("hi".utf8),
            options: DataPublishOptions(reliable: false, topic: "presence"),
            participantSid: "PA_remote",
            participantIdentity: "remote"
        )
        let received = try LiveKitDataPacketMapper.decodeUserPacket(from: packet.serializedData())

        XCTAssertEqual(received.payload, Data("hi".utf8))
        XCTAssertEqual(received.topic, "presence")
        XCTAssertEqual(received.reliability, .lossy)
        XCTAssertEqual(received.participantSid, "PA_remote")
        XCTAssertEqual(received.participantIdentity, "remote")
    }

    func testLocalParticipantPublishDataStoresPublishPlan() async throws {
        let participant = LocalParticipant(sid: "PA_local", identity: "local")

        try await participant.publish(
            data: Data("hello".utf8),
            options: DataPublishOptions(reliable: true, topic: "chat")
        )

        XCTAssertEqual(participant.dataPublishPlans.count, 1)
        XCTAssertEqual(participant.dataPublishPlans[0].packet.user.payload, Data("hello".utf8))
        XCTAssertEqual(participant.dataPublishPlans[0].packet.user.topic, "chat")
        XCTAssertEqual(participant.dataPublishPlans[0].packet.participantSid, "PA_local")
        XCTAssertEqual(participant.dataPublishPlans[0].packet.participantIdentity, "local")
    }

    func testLocalDataChannelPublisherFlushesQueuedReliablePacketAfterAck() async throws {
        let transport = RecordingSCTPDataChannelPacketTransport()
        let publisher = LocalDataChannelPublisher(transport: transport)
        let plan = try LocalDataPublishPlan(
            data: Data("hello".utf8),
            options: DataPublishOptions(reliable: true, topic: "chat")
        )

        try await publisher.publish(plan)

        let reliableStreamID = await publisher.streamID(for: .reliable)
        let queuedCount = await publisher.pendingPlanCount
        XCTAssertEqual(queuedCount, 1)
        XCTAssertEqual(transport.sentPackets.count, 1)
        let openPacket = try XCTUnwrap(transport.sentPackets.first)
        XCTAssertEqual(openPacket.streamID, reliableStreamID)
        XCTAssertEqual(openPacket.ppid, .dataChannelControl)
        XCTAssertEqual(
            try SCTPDataChannelControlMessage(decoding: openPacket.payload),
            .open(SCTPDataChannelOpenMessage(reliability: .reliable, label: LiveKitSCTPDataChannelLabel.reliable))
        )

        try await publisher.acceptControlPacket(
            SCTPDataChannelPacket(
                streamID: reliableStreamID,
                ppid: .dataChannelControl,
                payload: SCTPDataChannelControlMessage.acknowledgement.encoded()
            )
        )

        let flushedCount = await publisher.pendingPlanCount
        XCTAssertEqual(flushedCount, 0)
        XCTAssertEqual(transport.sentPackets.count, 2)
        XCTAssertEqual(
            transport.sentPackets[1],
            SCTPDataChannelPacket(streamID: reliableStreamID, ppid: .binary, payload: plan.encodedPacket)
        )
    }

    func testLocalDataChannelPublisherFlushesQueuedReliablePacketWhenOptimisticallyOpened() async throws {
        let transport = RecordingSCTPDataChannelPacketTransport()
        let publisher = LocalDataChannelPublisher(
            transport: transport,
            optimisticallyOpenLocalChannels: true
        )
        let plan = try LocalDataPublishPlan(
            data: Data("hello".utf8),
            options: DataPublishOptions(reliable: true, topic: "chat")
        )

        try await publisher.publish(plan)

        let reliableStreamID = await publisher.streamID(for: .reliable)
        let queuedCount = await publisher.pendingPlanCount
        XCTAssertEqual(queuedCount, 0)
        XCTAssertEqual(transport.sentPackets.count, 2)
        XCTAssertEqual(transport.sentPackets[0].streamID, reliableStreamID)
        XCTAssertEqual(transport.sentPackets[0].ppid, .dataChannelControl)
        XCTAssertEqual(
            try SCTPDataChannelControlMessage(decoding: transport.sentPackets[0].payload),
            .open(SCTPDataChannelOpenMessage(reliability: .reliable, label: LiveKitSCTPDataChannelLabel.reliable))
        )
        XCTAssertEqual(
            transport.sentPackets[1],
            SCTPDataChannelPacket(streamID: reliableStreamID, ppid: .binary, payload: plan.encodedPacket)
        )
    }

    func testLocalDataChannelPublisherSendsImmediatelyWhenChannelIsOpen() async throws {
        let transport = RecordingSCTPDataChannelPacketTransport()
        let publisher = LocalDataChannelPublisher(transport: transport)
        let firstPlan = try LocalDataPublishPlan(data: Data([0x01]), options: DataPublishOptions(reliable: false))
        let secondPlan = try LocalDataPublishPlan(data: Data([0x02]), options: DataPublishOptions(reliable: false))

        try await publisher.publish(firstPlan)
        let lossyStreamID = await publisher.streamID(for: .lossy)
        try await publisher.acceptControlPacket(
            SCTPDataChannelPacket(
                streamID: lossyStreamID,
                ppid: .dataChannelControl,
                payload: SCTPDataChannelControlMessage.acknowledgement.encoded()
            )
        )
        try await publisher.publish(secondPlan)

        let queuedCount = await publisher.pendingPlanCount
        XCTAssertEqual(queuedCount, 0)
        XCTAssertEqual(transport.sentPackets.count, 3)
        XCTAssertEqual(transport.sentPackets[0].streamID, lossyStreamID)
        XCTAssertEqual(transport.sentPackets[0].ppid, .dataChannelControl)
        XCTAssertEqual(
            transport.sentPackets[1],
            SCTPDataChannelPacket(streamID: lossyStreamID, ppid: .binary, payload: firstPlan.encodedPacket)
        )
        XCTAssertEqual(
            transport.sentPackets[2],
            SCTPDataChannelPacket(streamID: lossyStreamID, ppid: .binary, payload: secondPlan.encodedPacket)
        )
    }

    func testLocalDataChannelPublisherUsesRemoteOpenedLiveKitStreamID() async throws {
        let transport = RecordingSCTPDataChannelPacketTransport()
        let publisher = LocalDataChannelPublisher(transport: transport)
        let localReliableStreamID = await publisher.streamID(for: .reliable)
        let remoteReliableStreamID = localReliableStreamID + 1
        let plan = try LocalDataPublishPlan(
            data: Data("hello".utf8),
            options: DataPublishOptions(reliable: true, topic: "chat")
        )

        try await publisher.acceptControlPacket(
            SCTPDataChannelPacket(
                streamID: remoteReliableStreamID,
                ppid: .dataChannelControl,
                payload: SCTPDataChannelControlMessage.open(
                    SCTPDataChannelOpenMessage(reliability: .reliable, label: LiveKitSCTPDataChannelLabel.reliable)
                ).encoded()
            )
        )
        try await publisher.publish(plan)

        XCTAssertEqual(transport.sentPackets.count, 2)
        XCTAssertEqual(
            transport.sentPackets[0],
            SCTPDataChannelPacket(
                streamID: remoteReliableStreamID,
                ppid: .dataChannelControl,
                payload: SCTPDataChannelControlMessage.acknowledgement.encoded()
            )
        )
        XCTAssertEqual(
            transport.sentPackets[1],
            SCTPDataChannelPacket(streamID: remoteReliableStreamID, ppid: .binary, payload: plan.encodedPacket)
        )
    }

    func testLocalDataChannelPublisherReopensChannelAfterRecoveryReset() async throws {
        let transport = RecordingSCTPDataChannelPacketTransport()
        let publisher = LocalDataChannelPublisher(transport: transport)
        let firstPlan = try LocalDataPublishPlan(data: Data([0x01]), options: DataPublishOptions(reliable: true))
        let secondPlan = try LocalDataPublishPlan(data: Data([0x02]), options: DataPublishOptions(reliable: true))

        try await publisher.publish(firstPlan)
        let reliableStreamID = await publisher.streamID(for: .reliable)
        try await publisher.acceptControlPacket(
            SCTPDataChannelPacket(
                streamID: reliableStreamID,
                ppid: .dataChannelControl,
                payload: SCTPDataChannelControlMessage.acknowledgement.encoded()
            )
        )

        await publisher.resetForRecovery()
        try await publisher.publish(secondPlan)

        XCTAssertEqual(transport.sentPackets.count, 3)
        XCTAssertEqual(transport.sentPackets[2].streamID, reliableStreamID)
        XCTAssertEqual(transport.sentPackets[2].ppid, .dataChannelControl)
        XCTAssertEqual(
            try SCTPDataChannelControlMessage(decoding: transport.sentPackets[2].payload),
            .open(SCTPDataChannelOpenMessage(reliability: .reliable, label: LiveKitSCTPDataChannelLabel.reliable))
        )

        try await publisher.acceptControlPacket(
            SCTPDataChannelPacket(
                streamID: reliableStreamID,
                ppid: .dataChannelControl,
                payload: SCTPDataChannelControlMessage.acknowledgement.encoded()
            )
        )

        XCTAssertEqual(transport.sentPackets.count, 4)
        XCTAssertEqual(
            transport.sentPackets[3],
            SCTPDataChannelPacket(streamID: reliableStreamID, ppid: .binary, payload: secondPlan.encodedPacket)
        )
    }

    func testLocalDataChannelPublisherUsesManagerStreamIDsWhenFlushing() async throws {
        let transport = RecordingSCTPDataChannelPacketTransport()
        let manager = SCTPDataChannelManager(firstLocalStreamID: 1)
        let publisher = LocalDataChannelPublisher(manager: manager, transport: transport)
        let plan = try LocalDataPublishPlan(data: Data([0x01]), options: DataPublishOptions(reliable: true))

        try await publisher.publish(plan)
        let reliableStreamID = await publisher.streamID(for: .reliable)
        try await publisher.acceptControlPacket(
            SCTPDataChannelPacket(
                streamID: reliableStreamID,
                ppid: .dataChannelControl,
                payload: SCTPDataChannelControlMessage.acknowledgement.encoded()
            )
        )

        XCTAssertEqual(reliableStreamID, 1)
        XCTAssertEqual(
            transport.sentPackets.last,
            SCTPDataChannelPacket(streamID: 1, ppid: .binary, payload: plan.encodedPacket)
        )
    }

    func testLocalDataChannelPublisherAcksRemoteOpenAndDecodesInboundPacket() async throws {
        let transport = RecordingSCTPDataChannelPacketTransport()
        let publisher = LocalDataChannelPublisher(transport: transport)
        let reliableStreamID = await publisher.streamID(for: .reliable)

        let openPacket = SCTPDataChannelPacket(
            streamID: reliableStreamID,
            ppid: .dataChannelControl,
            payload: SCTPDataChannelControlMessage.open(
                SCTPDataChannelOpenMessage(reliability: .reliable, label: LiveKitSCTPDataChannelLabel.reliable)
            ).encoded()
        )

        let controlResult = try await publisher.acceptInboundPacket(openPacket)
        XCTAssertNil(controlResult)
        XCTAssertEqual(
            transport.sentPackets,
            [SCTPDataChannelPacket(
                streamID: reliableStreamID,
                ppid: .dataChannelControl,
                payload: SCTPDataChannelControlMessage.acknowledgement.encoded()
            )]
        )

        let packet = LiveKitDataPacketMapper.makeUserPacket(
            data: Data("hi".utf8),
            options: DataPublishOptions(reliable: true, topic: "chat"),
            participantSid: "PA_remote",
            participantIdentity: "remote"
        )
        let received = try await publisher.acceptInboundPacket(
            SCTPDataChannelPacket(
                streamID: reliableStreamID,
                ppid: .binary,
                payload: try packet.serializedData()
            )
        )

        XCTAssertEqual(received?.payload, Data("hi".utf8))
        XCTAssertEqual(received?.topic, "chat")
        XCTAssertEqual(received?.reliability, .reliable)
        XCTAssertEqual(received?.participantSid, "PA_remote")
        XCTAssertEqual(received?.participantIdentity, "remote")
    }

    func testDataTrackSignalPlansBuildProtocolRequests() {
        let publishPlan = LocalDataTrackPublishPlan(pubHandle: 42, name: "telemetry")

        XCTAssertEqual(publishPlan.publishRequest.pubHandle, 42)
        XCTAssertEqual(publishPlan.publishRequest.name, "telemetry")
        XCTAssertEqual(publishPlan.publishRequest.encryption, .none)
        XCTAssertEqual(publishPlan.unpublishRequest.pubHandle, 42)

        let subscriptionPlan = DataSubscriptionUpdatePlan(trackSid: "TR_data", subscribe: true, targetFps: 30)

        XCTAssertEqual(subscriptionPlan.update.trackSid, "TR_data")
        XCTAssertTrue(subscriptionPlan.update.subscribe)
        XCTAssertEqual(subscriptionPlan.update.options.targetFps, 30)
    }
}
