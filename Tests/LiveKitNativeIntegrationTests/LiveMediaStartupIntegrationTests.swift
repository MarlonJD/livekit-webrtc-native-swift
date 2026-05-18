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
        let subscriberRoom = liveMediaIntegrationRoom(liveKitURL: harness.liveKitURL)
        let publisherRoom = liveMediaIntegrationRoom(liveKitURL: harness.liveKitURL)
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
            assertDefaultOpenSSLLiveMediaStartup(
                startup,
                error: publisherRoom.lastPublisherMediaStartupError,
                role: "publisher"
            )

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
        let subscriberRoom = liveMediaIntegrationRoom(liveKitURL: harness.liveKitURL)
        let publisherRoom = liveMediaIntegrationRoom(liveKitURL: harness.liveKitURL)
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
            assertDefaultOpenSSLLiveMediaStartup(
                startup,
                error: subscriberRoom.lastSubscriberMediaStartupError,
                role: "subscriber"
            )

            await publisherRoom.disconnect()
            await subscriberRoom.disconnect()
        } catch {
            await publisherRoom.disconnect()
            await subscriberRoom.disconnect()
            throw error
        }
    }
}

private func assertDefaultOpenSSLLiveMediaStartup(
    _ startup: PeerConnectionMediaStartupResult,
    error: (any Error)?,
    role: String,
    file: StaticString = #filePath,
    line: UInt = #line
) {
    XCTAssertNil(error, "\(role) startup should not record an error.", file: file, line: line)
    XCTAssertEqual(startup.iceSummary.state, .connected, file: file, line: line)
    XCTAssertGreaterThan(
        startup.iceSummary.checkedPairCount,
        0,
        "\(role) startup should exercise ICE connectivity checks.",
        file: file,
        line: line
    )
    XCTAssertEqual(
        startup.iceSummary.selectedPair,
        Optional(startup.selectedCandidatePair),
        "\(role) startup should retain the selected ICE candidate pair.",
        file: file,
        line: line
    )
    XCTAssertNotNil(
        startup.mediaDataSession,
        "\(role) startup should use the default OpenSSL DTLS-SRTP media-data session.",
        file: file,
        line: line
    )
}

private func liveMediaIntegrationRoomOptions() -> RoomOptions {
    RoomOptions(
        defaultAutoSubscribe: false,
        defaultAdaptiveStream: true,
        defaultSubscriberAllowPause: true,
        defaultAutoSubscribeDataTrack: false
    )
}

private func liveMediaIntegrationRoom(liveKitURL: URL) -> Room {
    let subscriberIdentity = DTLSSRTPIdentity.generated()
    let publisherIdentity = DTLSSRTPIdentity.generated()
    let hostCandidateAddresses = liveMediaHostCandidateAddresses(for: liveKitURL)
    let bindAddress = liveMediaBindAddress(for: liveKitURL)
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
        subscriberMediaStartupConfiguration: .defaultLiveMediaData(
            hostCandidateAddresses: { hostCandidateAddresses },
            bindAddress: bindAddress,
            localCredentials: {
                subscriberPeerConnection.configuration.iceCredentials
            },
            identity: subscriberIdentity
        ),
        publisherMediaStartupConfiguration: .defaultLiveMediaData(
            hostCandidateAddresses: { hostCandidateAddresses },
            bindAddress: bindAddress,
            localCredentials: {
                publisherPeerConnection.configuration.iceCredentials
            },
            identity: publisherIdentity
        )
    )
}

private func liveMediaHostCandidateAddresses(for liveKitURL: URL) -> [ICEInterfaceAddress] {
    guard let host = liveKitURL.host?.lowercased(),
          ["localhost", "127.0.0.1"].contains(host)
    else {
        return ICEHostCandidateGatherer.localInterfaceAddresses()
    }

    return [
        ICEInterfaceAddress(name: "lo0", address: "127.0.0.1", localPreference: 101),
    ]
}

private func liveMediaBindAddress(for liveKitURL: URL) -> String {
    guard let host = liveKitURL.host?.lowercased(),
          ["localhost", "127.0.0.1"].contains(host)
    else {
        return "0.0.0.0"
    }

    return "127.0.0.1"
}
