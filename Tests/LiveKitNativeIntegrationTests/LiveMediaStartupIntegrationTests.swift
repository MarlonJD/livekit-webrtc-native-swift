import Foundation
import XCTest
@testable import LiveKitNative
@testable import LiveKitNativeWebRTC

final class LiveMediaStartupIntegrationTests: XCTestCase {
    func testPublisherDefaultOpenSSLDTLSSRTPMediaStartupAndH264Send() async throws {
        let harness = try LiveKitIntegrationHarness.load()
        let roomName = harness.roomName(suffix: "publisher-media")
        let subscriberIdentity = "swift-native-pub-media-sub"
        let publisherIdentity = "swift-native-pub-media-pub"
        let subscriberRoom = liveMediaIntegrationRoom()
        let publisherRoom = liveMediaIntegrationRoom()
        let subscriberEvents = LiveKitIntegrationEventRecorder()
        subscriberRoom.delegate = subscriberEvents

        do {
            try await harness.connect(subscriberRoom, identity: subscriberIdentity, roomName: roomName)
            try await harness.connect(publisherRoom, identity: publisherIdentity, roomName: roomName)
            _ = try await subscriberEvents.waitForParticipantConnected(identity: publisherIdentity)

            let track = LocalVideoTrack(name: "camera")
            let publication = try await withLiveKitIntegrationTimeout(seconds: 20) {
                try await publisherRoom.localParticipant.publish(videoTrack: track)
            }

            XCTAssertFalse(publication.sid.isEmpty)
            XCTAssertEqual(publication.name, "camera")
            XCTAssertEqual(publication.kind, .video)

            let startup = try await harness.waitForPublisherMediaStartup(
                publisherRoom,
                timeoutSeconds: 30
            )
            XCTAssertEqual(startup.iceSummary.state, .connected)
            XCTAssertNil(publisherRoom.lastPublisherMediaStartupError)

            let packets = try await withLiveKitIntegrationTimeout(seconds: 10) {
                try await publisherRoom.sendPublisherVideo(
                    H264EncodedFrame(
                        nalUnits: [Data([0x65, 0x88, 0x84, 0x21])],
                        rtpTimestamp: 90_000,
                        isKeyFrame: true
                    ),
                    sid: publication.sid
                )
            }

            XCTAssertFalse(packets.isEmpty)

            await publisherRoom.disconnect()
            await subscriberRoom.disconnect()
        } catch {
            await publisherRoom.disconnect()
            await subscriberRoom.disconnect()
            throw error
        }
    }

    func testSubscriberDefaultOpenSSLDTLSSRTPMediaStartupAfterRemoteVideoPublish() async throws {
        let harness = try LiveKitIntegrationHarness.load()
        let roomName = harness.roomName(suffix: "subscriber-media")
        let subscriberIdentity = "swift-native-sub-media-sub"
        let publisherIdentity = "swift-native-sub-media-pub"
        let subscriberRoom = liveMediaIntegrationRoom()
        let publisherRoom = liveMediaIntegrationRoom()
        let subscriberEvents = LiveKitIntegrationEventRecorder()
        subscriberRoom.delegate = subscriberEvents

        do {
            try await harness.connect(subscriberRoom, identity: subscriberIdentity, roomName: roomName)
            try await harness.connect(publisherRoom, identity: publisherIdentity, roomName: roomName)
            _ = try await subscriberEvents.waitForParticipantConnected(identity: publisherIdentity)

            let track = LocalVideoTrack(name: "camera")
            let publication = try await withLiveKitIntegrationTimeout(seconds: 20) {
                try await publisherRoom.localParticipant.publish(videoTrack: track)
            }

            XCTAssertFalse(publication.sid.isEmpty)
            _ = try await subscriberEvents.waitForTrackSubscribedOrRemoteVideoPublication(
                publisherIdentity: publisherIdentity,
                trackSID: publication.sid,
                timeoutSeconds: 20
            )
            try await subscriberRoom.updateSubscription(trackSIDs: [publication.sid], subscribe: true)

            let startup = try await harness.waitForSubscriberMediaStartup(
                subscriberRoom,
                timeoutSeconds: 30
            )
            XCTAssertEqual(startup.iceSummary.state, .connected)
            XCTAssertNil(subscriberRoom.lastSubscriberMediaStartupError)

            await publisherRoom.disconnect()
            await subscriberRoom.disconnect()
        } catch {
            await publisherRoom.disconnect()
            await subscriberRoom.disconnect()
            throw error
        }
    }
}

private func liveMediaIntegrationRoomOptions() -> RoomOptions {
    RoomOptions(
        defaultAutoSubscribe: false,
        defaultAdaptiveStream: true,
        defaultSubscriberAllowPause: true,
        defaultAutoSubscribeDataTrack: false
    )
}

private func liveMediaIntegrationRoom() -> Room {
    let subscriberIdentity = DTLSSRTPIdentity.generated()
    let publisherIdentity = DTLSSRTPIdentity.generated()
    let subscriberPeerConnection = PeerConnectionCoordinator(
        configuration: NativeWebRTCConfiguration(
            role: .subscriber,
            dtlsIdentity: subscriberIdentity
        )
    )
    let publisherPeerConnection = PeerConnectionCoordinator(
        configuration: NativeWebRTCConfiguration(
            role: .publisher,
            dtlsIdentity: publisherIdentity
        )
    )

    return Room(
        options: liveMediaIntegrationRoomOptions(),
        signalConnection: SignalConnection(),
        subscriberPeerConnection: subscriberPeerConnection,
        publisherPeerConnection: publisherPeerConnection,
        subscriberMediaStartupConfiguration: .defaultLive(
            localCredentials: {
                subscriberPeerConnection.configuration.iceCredentials
            },
            handshaker: OpenSSLDTLSSRTPHandshaker(identity: subscriberIdentity)
        ),
        publisherMediaStartupConfiguration: .defaultLive(
            localCredentials: {
                publisherPeerConnection.configuration.iceCredentials
            },
            handshaker: OpenSSLDTLSSRTPHandshaker(identity: publisherIdentity)
        )
    )
}
