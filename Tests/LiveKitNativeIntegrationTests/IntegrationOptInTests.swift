import Foundation
import XCTest
@testable import LiveKitNative
@testable import LiveKitNativeWebRTC

final class IntegrationOptInTests: XCTestCase {
    func testIntegrationSuiteIsOptIn() throws {
        let harness = try LiveKitIntegrationHarness.load()

        XCTAssertFalse(harness.roomPrefix.isEmpty)
    }

    func testHarnessRequiresConfigurationAfterOptIn() {
        XCTAssertThrowsError(
            try LiveKitIntegrationHarness.load(environment: [
                LiveKitIntegrationHarness.runIntegrationKey: "1",
            ])
        ) { error in
            XCTAssertTrue(
                String(describing: error).contains(LiveKitIntegrationHarness.liveKitURLKey)
            )
        }
    }

    func testHarnessBuildsRoomScopedLiveKitToken() throws {
        let harness = try LiveKitIntegrationHarness.load(
            environment: [
                LiveKitIntegrationHarness.runIntegrationKey: "1",
                LiveKitIntegrationHarness.liveKitURLKey: "ws://127.0.0.1:7880",
                LiveKitIntegrationHarness.apiKeyKey: "devkey",
                LiveKitIntegrationHarness.apiSecretKey: "secret",
            ],
            now: Date(timeIntervalSince1970: 1_700_000_000),
            uuid: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        )

        let token = try harness.token(
            identity: "swift-native-a",
            roomName: "integration-room",
            ttlSeconds: 60
        )
        let parts = token.split(separator: ".").map(String.init)

        XCTAssertEqual(parts.count, 3)

        let payloadData = try XCTUnwrap(Data(base64URLEncoded: parts[1]))
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: payloadData) as? [String: Any]
        )
        let video = try XCTUnwrap(payload["video"] as? [String: Any])

        XCTAssertEqual(payload["iss"] as? String, "devkey")
        XCTAssertEqual(payload["sub"] as? String, "swift-native-a")
        XCTAssertEqual(video["room"] as? String, "integration-room")
        XCTAssertEqual(video["roomJoin"] as? Bool, true)
        XCTAssertEqual(video["canPublish"] as? Bool, true)
        XCTAssertEqual(video["canSubscribe"] as? Bool, true)
        XCTAssertEqual(video["canPublishData"] as? Bool, true)
    }

    func testIntegrationTimeoutSurfacesHarnessTimeout() async {
        do {
            _ = try await withLiveKitIntegrationTimeout(seconds: 0.01) {
                try await Task.sleep(nanoseconds: 1_000_000_000)
                return "finished"
            }
            XCTFail("Expected integration timeout.")
        } catch let error as LiveKitIntegrationHarnessError {
            guard case let .timeout(seconds) = error else {
                return XCTFail("Expected integration timeout, got \(error).")
            }
            XCTAssertEqual(seconds, 0.01, accuracy: 0.001)
        } catch {
            XCTFail("Expected integration timeout, got \(error).")
        }
    }

    func testIntegrationTimeoutReturnsOperationResultBeforeDeadline() async throws {
        let result = try await withLiveKitIntegrationTimeout(seconds: 1) {
            "finished"
        }

        XCTAssertEqual(result, "finished")
    }

    func testIntegrationTimeoutPreservesOperationErrorBeforeDeadline() async {
        do {
            _ = try await withLiveKitIntegrationTimeout(seconds: 1) {
                throw IntegrationTimeoutTestError.operationFailed
            }
            XCTFail("Expected operation error.")
        } catch let error as IntegrationTimeoutTestError {
            XCTAssertEqual(error, .operationFailed)
        } catch {
            XCTFail("Expected operation error, got \(error).")
        }
    }

    func testLiveKitServerConnectsAndDisconnects() async throws {
        let harness = try LiveKitIntegrationHarness.load()
        let roomName = harness.roomName(suffix: "connect")
        let identity = "swift-native-connect"
        let room = liveIntegrationSignalingRoom()
        let token = try harness.token(identity: identity, roomName: roomName)

        do {
            try await withLiveKitIntegrationTimeout(seconds: 15) {
                try await room.connect(url: harness.liveKitURL, token: token)
            }
        } catch {
            await room.disconnect()
            throw error
        }

        XCTAssertEqual(room.connectionState, .connected)
        XCTAssertEqual(room.localParticipant.identity, identity)

        await room.disconnect()

        XCTAssertEqual(room.connectionState, .disconnected)
    }

    func testTwoLiveKitClientsObserveParticipantJoinAndLeave() async throws {
        let harness = try LiveKitIntegrationHarness.load()
        let roomName = harness.roomName(suffix: "two-client")
        let firstIdentity = "swift-native-first"
        let secondIdentity = "swift-native-second"
        let firstRoom = liveIntegrationSignalingRoom()
        let secondRoom = liveIntegrationSignalingRoom()
        let firstEvents = LiveKitIntegrationEventRecorder()
        firstRoom.delegate = firstEvents

        do {
            try await harness.connect(firstRoom, identity: firstIdentity, roomName: roomName)
            try await harness.connect(secondRoom, identity: secondIdentity, roomName: roomName)

            let joinedParticipant = try await firstEvents.waitForParticipantConnected(
                identity: secondIdentity
            )
            XCTAssertEqual(joinedParticipant.identity, secondIdentity)
            XCTAssertEqual(firstRoom.remoteParticipants.map(\.identity), [secondIdentity])
            XCTAssertTrue(secondRoom.remoteParticipants.contains { $0.identity == firstIdentity })

            await secondRoom.disconnect()

            let leftParticipant = try await firstEvents.waitForParticipantDisconnected(
                identity: secondIdentity
            )
            XCTAssertEqual(leftParticipant.identity, secondIdentity)
            XCTAssertTrue(firstRoom.remoteParticipants.isEmpty)

            await firstRoom.disconnect()
        } catch {
            await secondRoom.disconnect()
            await firstRoom.disconnect()
            throw error
        }
    }

    func testTwoLiveKitClientsReceiveDataTrackSubscriberHandles() async throws {
        guard ProcessInfo.processInfo.environment["LIVEKIT_NATIVE_RUN_DATA_TRACK_INTEGRATION"] == "1" else {
            throw XCTSkip(
                "Live data-track subscriber handles require the DTLS-backed SCTP data channel transport, " +
                "which remains a separate production-readiness blocker."
            )
        }

        let harness = try LiveKitIntegrationHarness.load()
        let roomName = harness.roomName(suffix: "data-track")
        let firstIdentity = "swift-native-data-sub"
        let secondIdentity = "swift-native-data-pub"
        let firstRoom = liveIntegrationSignalingRoom()
        let secondRoom = liveIntegrationSignalingRoom()
        let firstEvents = LiveKitIntegrationEventRecorder()
        firstRoom.delegate = firstEvents

        do {
            try await harness.connect(firstRoom, identity: firstIdentity, roomName: roomName)
            try await harness.connect(secondRoom, identity: secondIdentity, roomName: roomName)
            _ = try await firstEvents.waitForParticipantConnected(identity: secondIdentity)

            let dataTrack = try await withLiveKitIntegrationTimeout(seconds: 10) {
                try await secondRoom.localParticipant.publishDataTrack(name: "telemetry")
            }
            XCTAssertFalse(dataTrack.sid.isEmpty)
            XCTAssertEqual(dataTrack.name, "telemetry")

            let subscriberHandle = try await firstEvents.waitForDataTrackSubscriberHandle(
                publisherIdentity: secondIdentity
            )
            XCTAssertEqual(subscriberHandle.publisherIdentity, secondIdentity)
            XCTAssertEqual(subscriberHandle.trackSID, dataTrack.sid)

            await secondRoom.disconnect()
            await firstRoom.disconnect()
        } catch {
            await secondRoom.disconnect()
            await firstRoom.disconnect()
            throw error
        }
    }

    func testTwoLiveKitClientsPublishAndReceiveDataPacketOverStandardsSCTP() async throws {
        guard ProcessInfo.processInfo.environment["LIVEKIT_NATIVE_RUN_DATA_TRACK_INTEGRATION"] == "1" else {
            throw XCTSkip(
                "Live data-packet publish/receive requires standards-shaped DTLS-backed SCTP validation, " +
                "which remains a separate production-readiness blocker."
            )
        }

        let harness = try LiveKitIntegrationHarness.load()
        let roomName = harness.roomName(suffix: "data-packet")
        let subscriberIdentity = "swift-native-data-packet-sub"
        let publisherIdentity = "swift-native-data-packet-pub"
        let subscriberRoom = liveIntegrationMediaDataRoom(
            liveKitURL: harness.liveKitURL,
            options: liveIntegrationMediaDataPacketOptions()
        )
        let publisherRoom = liveIntegrationMediaDataRoom(
            liveKitURL: harness.liveKitURL,
            options: liveIntegrationMediaDataPacketOptions()
        )
        let subscriberEvents = LiveKitIntegrationEventRecorder()
        subscriberRoom.delegate = subscriberEvents

        do {
            try await harness.connect(subscriberRoom, identity: subscriberIdentity, roomName: roomName)
            try await harness.connect(publisherRoom, identity: publisherIdentity, roomName: roomName)
            _ = try await subscriberEvents.waitForParticipantConnected(identity: publisherIdentity)

            let videoTrack = LocalVideoTrack(name: "camera")
            let videoPublication = try await withLiveKitIntegrationTimeout(seconds: 20) {
                try await publisherRoom.localParticipant.publish(videoTrack: videoTrack)
            }
            _ = try await harness.waitForPublisherMediaStartup(publisherRoom, timeoutSeconds: 30)
            _ = try await harness.waitForPublisherDataChannelInstalled(publisherRoom, timeoutSeconds: 10)

            _ = try await subscriberEvents.waitForTrackSubscribedOrRemoteVideoPublication(
                publisherIdentity: publisherIdentity,
                trackSID: videoPublication.sid,
                timeoutSeconds: 20
            )
            try await subscriberRoom.updateSubscription(trackSIDs: [videoPublication.sid], subscribe: true)

            _ = try await harness.waitForSubscriberMediaStartup(subscriberRoom, timeoutSeconds: 30)
            _ = try await harness.waitForSubscriberDataChannelInstalled(subscriberRoom, timeoutSeconds: 10)

            let payload = Data("standards-sctp-ping".utf8)
            try await withLiveKitIntegrationTimeout(seconds: 10) {
                try await publisherRoom.localParticipant.publish(
                    data: payload,
                    options: DataPublishOptions(reliable: true, topic: "chat")
                )
            }
            let publisherDataChannel = try await harness.waitForPublisherReliableDataChannelOpenAndFlushed(
                publisherRoom,
                timeoutSeconds: 10
            )
            XCTAssertTrue(publisherDataChannel.reliableOpen)
            XCTAssertEqual(publisherDataChannel.pendingPlanCount, 0)

            let received = try await subscriberEvents.waitForDataReceived(
                payload: payload,
                topic: "chat",
                participantIdentity: publisherIdentity,
                timeoutSeconds: 20
            )
            XCTAssertEqual(received.0, payload)
            XCTAssertEqual(received.1?.identity, publisherIdentity)
            XCTAssertEqual(received.2, "chat")

            await publisherRoom.disconnect()
            await subscriberRoom.disconnect()
        } catch {
            await publisherRoom.disconnect()
            await subscriberRoom.disconnect()
            throw error
        }
    }
}

private enum IntegrationTimeoutTestError: Error, Equatable {
    case operationFailed
}

private func liveIntegrationRoomOptions() -> RoomOptions {
    RoomOptions(
        defaultAutoSubscribe: true,
        defaultAdaptiveStream: true,
        defaultSubscriberAllowPause: true,
        defaultAutoSubscribeDataTrack: true
    )
}

private func liveIntegrationSignalingRoom() -> Room {
    Room(
        options: liveIntegrationRoomOptions(),
        signalConnection: SignalConnection()
    )
}

private func liveIntegrationMediaDataPacketOptions() -> RoomOptions {
    RoomOptions(
        defaultAutoSubscribe: false,
        defaultAdaptiveStream: true,
        defaultSubscriberAllowPause: true,
        defaultAutoSubscribeDataTrack: false
    )
}

private func liveIntegrationMediaDataRoom(
    liveKitURL: URL,
    options: RoomOptions = liveIntegrationRoomOptions()
) -> Room {
    let subscriberIdentity = DTLSSRTPIdentity.generated()
    let publisherIdentity = DTLSSRTPIdentity.generated()
    let hostCandidateAddresses = liveIntegrationHostCandidateAddresses(for: liveKitURL)
    let bindAddress = liveIntegrationBindAddress(for: liveKitURL)
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
        options: options,
        signalConnection: SignalConnection(),
        subscriberPeerConnection: subscriberPeerConnection,
        publisherPeerConnection: publisherPeerConnection,
        subscriberMediaStartupConfiguration: .defaultLiveMediaData(
            hostCandidateAddresses: { hostCandidateAddresses },
            bindAddress: bindAddress,
            localCredentials: {
                subscriberPeerConnection.configuration.iceCredentials
            },
            identity: subscriberIdentity,
            dataChannelTransportMode: liveIntegrationStandardsSCTPMode()
        ),
        publisherMediaStartupConfiguration: .defaultLiveMediaData(
            hostCandidateAddresses: { hostCandidateAddresses },
            bindAddress: bindAddress,
            localCredentials: {
                publisherPeerConnection.configuration.iceCredentials
            },
            identity: publisherIdentity,
            dataChannelTransportMode: liveIntegrationStandardsSCTPMode()
        )
    )
}

private func liveIntegrationStandardsSCTPMode() -> DTLSSCTPDataChannelTransportMode {
    .association(SCTPAssociationConfiguration(maxDataChunkPayloadSize: 1_200))
}

private func liveIntegrationHostCandidateAddresses(for liveKitURL: URL) -> [ICEInterfaceAddress] {
    guard let host = liveKitURL.host?.lowercased(),
          ["localhost", "127.0.0.1"].contains(host)
    else {
        return ICEHostCandidateGatherer.localInterfaceAddresses()
    }

    return [
        ICEInterfaceAddress(name: "lo0", address: "127.0.0.1", localPreference: 101),
    ]
}

private func liveIntegrationBindAddress(for liveKitURL: URL) -> String {
    guard let host = liveKitURL.host?.lowercased(),
          ["localhost", "127.0.0.1"].contains(host)
    else {
        return "0.0.0.0"
    }

    return "127.0.0.1"
}
