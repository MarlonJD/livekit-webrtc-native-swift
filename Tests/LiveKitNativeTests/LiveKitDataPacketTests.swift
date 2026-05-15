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
        XCTAssertEqual(plan.sctpPacket.streamID, LocalDataPublishPlan.reliableStreamID)
        XCTAssertEqual(plan.sctpPacket.ppid, .binary)
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
        let decoded = try Livekit_DataPacket(serializedBytes: plan.sctpPacket.payload)

        XCTAssertEqual(plan.reliability, .lossy)
        XCTAssertEqual(plan.channelLabel, LiveKitSCTPDataChannelLabel.lossy)
        XCTAssertEqual(plan.sctpPacket.streamID, LocalDataPublishPlan.lossyStreamID)
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
