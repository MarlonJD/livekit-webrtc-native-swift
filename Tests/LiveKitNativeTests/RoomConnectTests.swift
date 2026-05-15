import Foundation
import LiveKitNativeProtocol
import LiveKitNativeWebRTC
import XCTest
@testable import LiveKitNative

final class RoomConnectTests: XCTestCase {
    func testConnectConsumesJoinResponseAndUpdatesRoomState() async throws {
        let response = makeJoinResponse()
        let encodedResponse = try SignalFrameCodec().encode(response)
        let transport = MockSignalTransport(incomingFrames: [.binary(encodedResponse)])
        let room = Room(signalConnection: SignalConnection(transport: transport))
        let eventRecorder = RoomEventRecorder()
        room.delegate = eventRecorder

        try await room.connect(url: URL(string: "https://example.test")!, token: "token")

        let connectedURLs = await transport.connectedURLs
        let connectedURL = try XCTUnwrap(connectedURLs.first)
        let queryItems = URLComponents(url: connectedURL, resolvingAgainstBaseURL: false)?.queryItems ?? []

        XCTAssertEqual(connectedURLs.count, 1)
        XCTAssertEqual(connectedURL.scheme, "wss")
        XCTAssertEqual(connectedURL.path, "/rtc")
        XCTAssertEqual(queryItems.first(where: { $0.name == "access_token" })?.value, "token")
        XCTAssertEqual(queryItems.first(where: { $0.name == "protocol" })?.value, "9")

        XCTAssertEqual(room.connectionState, .connected)
        XCTAssertEqual(room.localParticipant.sid, "PA_local")
        XCTAssertEqual(room.localParticipant.identity, "marlon")
        XCTAssertEqual(room.localParticipant.name, "Marlon")
        XCTAssertEqual(room.localParticipant.attributes, ["role": "host"])

        let remoteParticipant = try XCTUnwrap(room.remoteParticipants.first)
        XCTAssertEqual(room.remoteParticipants.count, 1)
        XCTAssertEqual(remoteParticipant.sid, "PA_alice")
        XCTAssertEqual(remoteParticipant.identity, "alice")
        XCTAssertEqual(remoteParticipant.name, "Alice")
        XCTAssertEqual(remoteParticipant.metadata, "remote-metadata")
        XCTAssertEqual(remoteParticipant.trackPublications.count, 1)
        XCTAssertEqual(remoteParticipant.trackPublications.first?.sid, "TR_camera")
        XCTAssertEqual(remoteParticipant.trackPublications.first?.kind, .video)
        XCTAssertEqual(remoteParticipant.trackPublications.first?.source, .camera)

        let events = eventRecorder.recordedEvents
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events[0], .connectionStateChanged(.connecting))
        XCTAssertEqual(events[1], .connectionStateChanged(.connected))

        guard case let .participantConnected(eventParticipant) = events[2] else {
            return XCTFail("Expected participantConnected event.")
        }
        XCTAssertEqual(eventParticipant.sid, "PA_alice")

        guard case let .trackPublished(publication, participant) = events[3] else {
            return XCTFail("Expected trackPublished event.")
        }
        XCTAssertEqual(publication.sid, "TR_camera")
        XCTAssertEqual(participant.sid, "PA_alice")
    }

    func testConnectReturnsToDisconnectedWhenInitialFrameIsNotJoin() async throws {
        var pong = Livekit_Pong()
        pong.timestamp = 42
        var response = Livekit_SignalResponse()
        response.pongResp = pong

        let encodedResponse = try SignalFrameCodec().encode(response)
        let transport = MockSignalTransport(incomingFrames: [.binary(encodedResponse)])
        let room = Room(signalConnection: SignalConnection(transport: transport))

        await XCTAssertThrowsErrorAsync {
            try await room.connect(url: URL(string: "wss://example.test")!, token: "token")
        }

        XCTAssertEqual(room.connectionState, .disconnected)
        let closeCalls = await transport.closeCalls
        XCTAssertEqual(closeCalls.count, 1)
    }

    func testConnectRetriesAlternativeSignalURL() async throws {
        let frames = try [
            makeJoinResponse(alternativeURL: "https://alt.example.test/edge?region=eu"),
            makeJoinResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))

        try await room.connect(url: URL(string: "https://example.test")!, token: "token")

        let connectedURLs = await transport.connectedURLs
        XCTAssertEqual(connectedURLs.count, 2)
        XCTAssertEqual(connectedURLs[0].host, "example.test")
        XCTAssertEqual(connectedURLs[1].host, "alt.example.test")
        XCTAssertEqual(connectedURLs[1].path, "/edge/rtc")
        XCTAssertEqual(room.connectionState, .connected)
        XCTAssertEqual(room.remoteParticipants.count, 1)

        let closeCalls = await transport.closeCalls
        XCTAssertEqual(closeCalls.count, 1)
    }

    func testSignalLoopAppliesParticipantUpdatesRefreshTokenAndLeave() async throws {
        let frames = try [
            makeJoinResponse(),
            makeParticipantUpdateResponse(),
            makeRefreshTokenResponse(),
            makeLeaveResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))
        let eventRecorder = RoomEventRecorder()
        room.delegate = eventRecorder

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let events = await eventRecorder.waitForEventCount(8)

        XCTAssertEqual(room.connectionState, .disconnected)
        XCTAssertEqual(room.remoteParticipants.count, 2)
        XCTAssertEqual(room.remoteParticipants.map(\.identity).sorted(), ["alice", "bob"])

        let bob = try XCTUnwrap(room.remoteParticipants.first { $0.identity == "bob" })
        XCTAssertEqual(bob.trackPublications.count, 1)
        XCTAssertEqual(bob.trackPublications.first?.sid, "TR_microphone")
        XCTAssertEqual(bob.trackPublications.first?.kind, .audio)

        XCTAssertEqual(events.count, 8)
        XCTAssertEqual(events[4], .participantConnected(bob))

        guard case let .trackPublished(publication, participant) = events[5] else {
            return XCTFail("Expected bob trackPublished event.")
        }
        XCTAssertEqual(publication.sid, "TR_microphone")
        XCTAssertEqual(participant.sid, "PA_bob")

        XCTAssertEqual(events[6], .tokenRefreshed("refreshed-token"))
        XCTAssertEqual(events[7], .connectionStateChanged(.disconnected))

        let closeCalls = await transport.closeCalls
        XCTAssertEqual(closeCalls.count, 1)
    }

    func testLeaveResumeReconnectsWithReconnectQueryAndAppliesReconnectResponse() async throws {
        let frames = try [
            makeJoinResponse(),
            makeLeaveResponse(action: .resume),
            makeReconnectResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))
        let eventRecorder = RoomEventRecorder()
        room.delegate = eventRecorder

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let events = await eventRecorder.waitForEventCount(6)
        XCTAssertEqual(room.connectionState, .connected)
        XCTAssertEqual(events[4], .connectionStateChanged(.reconnecting))
        XCTAssertEqual(events[5], .connectionStateChanged(.connected))

        let connectedURLs = await transport.connectedURLs
        XCTAssertEqual(connectedURLs.count, 2)
        let reconnectQueryItems = URLComponents(url: connectedURLs[1], resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(reconnectQueryItems.first(where: { $0.name == "reconnect" })?.value, "true")

        let closeCalls = await transport.closeCalls
        XCTAssertEqual(closeCalls.count, 1)
    }

    func testLeaveFullReconnectUsesFreshJoinAndReplacesRemoteParticipants() async throws {
        let frames = try [
            makeJoinResponse(),
            makeLeaveResponse(action: .reconnect),
            makeJoinResponse(remoteSID: "PA_bob", remoteIdentity: "bob", remoteName: "Bob", remoteTrackSID: "TR_bob_camera"),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))
        let eventRecorder = RoomEventRecorder()
        room.delegate = eventRecorder

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let events = await eventRecorder.waitForEventCount(10)
        XCTAssertEqual(room.connectionState, .connected)
        XCTAssertEqual(room.remoteParticipants.map(\.identity), ["bob"])

        XCTAssertEqual(events[4], .connectionStateChanged(.reconnecting))
        XCTAssertEqual(events[5], .connectionStateChanged(.connected))

        guard case let .trackUnpublished(oldPublication, oldParticipant) = events[6] else {
            return XCTFail("Expected stale remote track cleanup event.")
        }
        XCTAssertEqual(oldPublication.sid, "TR_camera")
        XCTAssertEqual(oldParticipant.identity, "alice")
        XCTAssertEqual(events[7], .participantDisconnected(oldParticipant))

        guard case let .participantConnected(newParticipant) = events[8] else {
            return XCTFail("Expected fresh remote participant after full reconnect.")
        }
        XCTAssertEqual(newParticipant.identity, "bob")

        guard case let .trackPublished(newPublication, participant) = events[9] else {
            return XCTFail("Expected fresh remote track after full reconnect.")
        }
        XCTAssertEqual(newPublication.sid, "TR_bob_camera")
        XCTAssertEqual(participant.identity, "bob")

        let connectedURLs = await transport.connectedURLs
        XCTAssertEqual(connectedURLs.count, 2)
        let reconnectQueryItems = URLComponents(url: connectedURLs[1], resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(reconnectQueryItems.first(where: { $0.name == "reconnect" })?.value, "false")
    }

    func testSignalLoopAnswersSubscriberOffer() async throws {
        let frames = try [
            makeJoinResponse(),
            makeSubscriberOfferResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let sentFrames = await waitForSentFrameCount(1, transport: transport)
        XCTAssertEqual(sentFrames.count, 1)

        guard case let .binary(data) = sentFrames[0] else {
            return XCTFail("Expected binary answer request.")
        }

        let request = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: data)
        guard case let .answer(answer)? = request.message else {
            return XCTFail("Expected SignalRequest.answer.")
        }

        XCTAssertEqual(answer.type, "answer")
        XCTAssertEqual(answer.id, 7)
        XCTAssertTrue(answer.sdp.contains("a=group:BUNDLE 0 1 data"))
        XCTAssertTrue(answer.sdp.contains("m=audio 9 UDP/TLS/RTP/SAVPF 111"))
        XCTAssertTrue(answer.sdp.contains("m=video 9 UDP/TLS/RTP/SAVPF 102 96"))
        XCTAssertTrue(answer.sdp.contains("a=ice-ufrag:"))
        XCTAssertTrue(answer.sdp.contains("a=ice-pwd:"))
        XCTAssertTrue(answer.sdp.contains("a=fingerprint:"))
        XCTAssertTrue(answer.sdp.contains("a=setup:active"))
        XCTAssertFalse(answer.sdp.contains("AV1/90000"))
    }

    func testSignalLoopAppliesPublisherAnswer() async throws {
        let frames = try [
            makeJoinResponse(),
            makePublisherAnswerResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let publisherPeerConnection = PeerConnectionCoordinator(
            configuration: NativeWebRTCConfiguration(role: .publisher)
        )
        let room = Room(
            signalConnection: SignalConnection(transport: transport),
            publisherPeerConnection: publisherPeerConnection
        )

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let receivedRemoteAnswer = await waitForRemoteAnswer(peerConnection: publisherPeerConnection)
        let remoteAnswer = try XCTUnwrap(receivedRemoteAnswer)
        XCTAssertEqual(remoteAnswer.type, "answer")
        XCTAssertEqual(remoteAnswer.id, 11)
        XCTAssertTrue(remoteAnswer.sdp.contains("m=video 9 UDP/TLS/RTP/SAVPF 102"))
        XCTAssertEqual(publisherPeerConnection.state, .connected)
    }

    func testSignalLoopRoutesSubscriberTrickleToPeerConnection() async throws {
        let frames = try [
            makeJoinResponse(),
            makeSubscriberTrickleResponse(),
            makeSubscriberTrickleCompleteResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let subscriberPeerConnection = PeerConnectionCoordinator(
            configuration: NativeWebRTCConfiguration(role: .subscriber)
        )
        let room = Room(
            signalConnection: SignalConnection(transport: transport),
            subscriberPeerConnection: subscriberPeerConnection
        )

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let candidates = await waitForRemoteCandidateCount(1, peerConnection: subscriberPeerConnection)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].candidateInit.candidate, "candidate:1 1 UDP 2122260223 192.0.2.1 54545 typ host")
        XCTAssertEqual(candidates[0].candidateInit.sdpMid, "0")
        XCTAssertEqual(candidates[0].candidateInit.sdpMLineIndex, 0)
        XCTAssertEqual(candidates[0].candidateInit.usernameFragment, "remote-ufrag")
        XCTAssertTrue(subscriberPeerConnection.isRemoteICEGatheringComplete)
    }

    func testSignalLoopRoutesPublisherTrickleToPeerConnection() async throws {
        let frames = try [
            makeJoinResponse(),
            makePublisherTrickleResponse(),
            makePublisherTrickleCompleteResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let publisherPeerConnection = PeerConnectionCoordinator(
            configuration: NativeWebRTCConfiguration(role: .publisher)
        )
        let room = Room(
            signalConnection: SignalConnection(transport: transport),
            publisherPeerConnection: publisherPeerConnection
        )

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let candidates = await waitForRemoteCandidateCount(1, peerConnection: publisherPeerConnection)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].candidateInit.candidate, "candidate:2 1 UDP 2122260223 192.0.2.2 54546 typ host")
        XCTAssertEqual(candidates[0].candidateInit.sdpMid, "1")
        XCTAssertEqual(candidates[0].candidateInit.sdpMLineIndex, 1)
        XCTAssertEqual(candidates[0].candidateInit.usernameFragment, "publisher-ufrag")
        XCTAssertTrue(publisherPeerConnection.isRemoteICEGatheringComplete)
    }

    func testSignalLoopEmitsSpeakerQualityAndStreamStateEvents() async throws {
        let frames = try [
            makeJoinResponse(),
            makeSpeakersChangedResponse(),
            makeConnectionQualityResponse(),
            makeStreamStateUpdateResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))
        let eventRecorder = RoomEventRecorder()
        room.delegate = eventRecorder

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let events = await eventRecorder.waitForEventCount(7)

        guard case let .speakersChanged(speakers) = events[4] else {
            return XCTFail("Expected speakersChanged event.")
        }
        XCTAssertEqual(speakers, [SpeakerInfo(participantSID: "PA_alice", level: 0.5, isActive: true)])

        guard case let .connectionQualityChanged(qualities) = events[5] else {
            return XCTFail("Expected connectionQualityChanged event.")
        }
        XCTAssertEqual(qualities.map(\.participantSID), ["PA_alice"])
        XCTAssertEqual(qualities.first?.quality, .excellent)
        XCTAssertEqual(qualities.first?.score ?? 0, 0.75, accuracy: 0.0001)

        guard case let .streamStateChanged(streamStates) = events[6] else {
            return XCTFail("Expected streamStateChanged event.")
        }
        XCTAssertEqual(streamStates, [
            TrackStreamStateInfo(participantSID: "PA_alice", trackSID: "TR_camera", state: .paused)
        ])
    }

    func testSignalLoopEmitsRoomAndSubscriptionEvents() async throws {
        let frames = try [
            makeJoinResponse(),
            makeRoomUpdateResponse(),
            makeSubscribedQualityUpdateResponse(),
            makeSubscriptionPermissionUpdateResponse(),
            makeSubscriptionResponse(),
            makeTrackSubscribedResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))
        let eventRecorder = RoomEventRecorder()
        room.delegate = eventRecorder

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let events = await eventRecorder.waitForEventCount(9)

        guard case let .roomUpdated(info) = events[4] else {
            return XCTFail("Expected roomUpdated event.")
        }
        XCTAssertEqual(info.sid, "RM_main")
        XCTAssertEqual(info.name, "main-room")
        XCTAssertEqual(info.metadata, "room-metadata")
        XCTAssertEqual(info.participantCount, 3)
        XCTAssertEqual(info.publisherCount, 2)
        XCTAssertTrue(info.isRecording)

        guard case let .subscribedQualityChanged(qualityUpdate) = events[5] else {
            return XCTFail("Expected subscribedQualityChanged event.")
        }
        XCTAssertEqual(qualityUpdate.trackSID, "TR_camera")
        XCTAssertEqual(qualityUpdate.qualities, [
            SubscribedQualityInfo(quality: .high, isEnabled: true),
            SubscribedQualityInfo(quality: .low, isEnabled: false),
        ])
        XCTAssertEqual(qualityUpdate.codecs, [
            SubscribedCodecInfo(
                codec: "h264",
                qualities: [SubscribedQualityInfo(quality: .medium, isEnabled: true)]
            )
        ])

        guard case let .subscriptionPermissionChanged(permissionUpdate) = events[6] else {
            return XCTFail("Expected subscriptionPermissionChanged event.")
        }
        XCTAssertEqual(permissionUpdate, SubscriptionPermissionUpdateInfo(
            participantSID: "PA_alice",
            trackSID: "TR_camera",
            isAllowed: false
        ))

        guard case let .subscriptionResponded(subscriptionResponse) = events[7] else {
            return XCTFail("Expected subscriptionResponded event.")
        }
        XCTAssertEqual(subscriptionResponse, SubscriptionResponseInfo(
            trackSID: "TR_camera",
            error: .codecUnsupported
        ))

        guard case let .trackSubscribed(info) = events[8] else {
            return XCTFail("Expected trackSubscribed event.")
        }
        XCTAssertEqual(info, TrackSubscribedInfo(trackSID: "TR_camera"))
    }

    func testSignalLoopEmitsMediaAndDataTrackControlEvents() async throws {
        let frames = try [
            makeJoinResponse(),
            makeMediaSectionsRequirementResponse(),
            makeSubscribedAudioCodecUpdateResponse(),
            makePublishDataTrackResponse(),
            makeUnpublishDataTrackResponse(),
            makeDataTrackSubscriberHandlesResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))
        let eventRecorder = RoomEventRecorder()
        room.delegate = eventRecorder

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let events = await eventRecorder.waitForEventCount(9)

        guard case let .mediaSectionsRequirementChanged(requirement) = events[4] else {
            return XCTFail("Expected mediaSectionsRequirementChanged event.")
        }
        XCTAssertEqual(requirement, MediaSectionsRequirementInfo(audioCount: 2, videoCount: 3))

        guard case let .subscribedAudioCodecChanged(audioUpdate) = events[5] else {
            return XCTFail("Expected subscribedAudioCodecChanged event.")
        }
        XCTAssertEqual(audioUpdate, SubscribedAudioCodecUpdateInfo(
            trackSID: "TR_microphone",
            codecs: [
                SubscribedAudioCodecInfo(codec: "opus", isEnabled: true),
                SubscribedAudioCodecInfo(codec: "aac", isEnabled: false),
            ]
        ))

        guard case let .dataTrackPublished(published) = events[6] else {
            return XCTFail("Expected dataTrackPublished event.")
        }
        XCTAssertEqual(published, DataTrackInfo(
            publisherHandle: 41,
            sid: "DT_location",
            name: "location",
            encryption: .gcm
        ))

        guard case let .dataTrackUnpublished(unpublished) = events[7] else {
            return XCTFail("Expected dataTrackUnpublished event.")
        }
        XCTAssertEqual(unpublished, DataTrackInfo(
            publisherHandle: 41,
            sid: "DT_location",
            name: "location",
            encryption: .gcm
        ))

        guard case let .dataTrackSubscriberHandlesChanged(handles) = events[8] else {
            return XCTFail("Expected dataTrackSubscriberHandlesChanged event.")
        }
        XCTAssertEqual(handles, DataTrackSubscriberHandlesInfo(handles: [
            DataTrackSubscriberHandleInfo(
                subscriberHandle: 7,
                publisherIdentity: "alice",
                publisherSID: "PA_alice",
                trackSID: "DT_location"
            ),
            DataTrackSubscriberHandleInfo(
                subscriberHandle: 9,
                publisherIdentity: "bob",
                publisherSID: "PA_bob",
                trackSID: "DT_controls"
            ),
        ]))
    }

    func testSignalLoopAppliesRoomMovedResponse() async throws {
        let frames = try [
            makeJoinResponse(),
            makeRoomMovedResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))
        let eventRecorder = RoomEventRecorder()
        room.delegate = eventRecorder

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let events = await eventRecorder.waitForEventCount(9)
        XCTAssertEqual(room.connectionState, .connected)
        XCTAssertEqual(room.localParticipant.sid, "PA_moved_local")
        XCTAssertEqual(room.localParticipant.identity, "moved-local")
        XCTAssertEqual(room.remoteParticipants.map(\.identity), ["bob"])

        guard case let .roomMoved(info) = events[4] else {
            return XCTFail("Expected roomMoved event.")
        }
        XCTAssertEqual(info.roomSID, "RM_moved")
        XCTAssertEqual(info.roomName, "moved-room")
        XCTAssertEqual(info.reconnectToken, "moved-token")
        XCTAssertEqual(info.participantSID, "PA_moved_local")
        XCTAssertEqual(info.participantIdentity, "moved-local")
        XCTAssertEqual(info.remoteParticipantIdentities, ["bob"])

        guard case let .trackUnpublished(oldPublication, oldParticipant) = events[5] else {
            return XCTFail("Expected stale track cleanup event.")
        }
        XCTAssertEqual(oldPublication.sid, "TR_camera")
        XCTAssertEqual(oldParticipant.identity, "alice")
        XCTAssertEqual(events[6], .participantDisconnected(oldParticipant))

        guard case let .participantConnected(newParticipant) = events[7] else {
            return XCTFail("Expected moved remote participant event.")
        }
        XCTAssertEqual(newParticipant.identity, "bob")

        guard case let .trackPublished(newPublication, participant) = events[8] else {
            return XCTFail("Expected moved remote track event.")
        }
        XCTAssertEqual(newPublication.sid, "TR_bob_camera")
        XCTAssertEqual(participant.identity, "bob")
    }

    func testSignalLoopAppliesTrackUnpublished() async throws {
        let frames = try [
            makeJoinResponse(),
            makeTrackUnpublishedResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))
        let eventRecorder = RoomEventRecorder()
        room.delegate = eventRecorder

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let events = await eventRecorder.waitForEventCount(5)
        let alice = try XCTUnwrap(room.remoteParticipants.first { $0.identity == "alice" })

        XCTAssertEqual(alice.trackPublications.count, 0)

        guard case let .trackUnpublished(publication, participant) = events[4] else {
            return XCTFail("Expected trackUnpublished event.")
        }
        XCTAssertEqual(publication.sid, "TR_camera")
        XCTAssertEqual(participant.sid, "PA_alice")
    }

    func testLocalParticipantMetadataUpdateSendsRequestAndAppliesAck() async throws {
        let frames = try [
            makeJoinResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let updateTask = Task {
            try await room.localParticipant.setMetadata("updated-metadata")
        }

        let sentFrames = await waitForSentFrameCount(1, transport: transport)
        XCTAssertEqual(sentFrames.count, 1)

        guard case let .binary(data) = sentFrames[0] else {
            return XCTFail("Expected binary metadata update request.")
        }

        let request = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: data)
        guard case let .updateMetadata(update)? = request.message else {
            return XCTFail("Expected SignalRequest.updateMetadata.")
        }
        XCTAssertEqual(update.metadata, "updated-metadata")
        XCTAssertNotEqual(update.requestID, 0)

        try await transport.enqueueIncomingFrame(
            .binary(SignalFrameCodec().encode(makeRequestResponse(requestID: update.requestID, reason: .ok)))
        )

        try await updateTask.value
        XCTAssertEqual(room.localParticipant.metadata, "updated-metadata")
    }

    func testLocalParticipantMetadataUpdateMapsPermissionDenied() async throws {
        let frames = try [
            makeJoinResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let updateTask = Task {
            try await room.localParticipant.setMetadata("forbidden")
        }

        let sentFrames = await waitForSentFrameCount(1, transport: transport)
        guard case let .binary(data) = try XCTUnwrap(sentFrames.first) else {
            return XCTFail("Expected binary metadata update request.")
        }

        let request = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: data)
        guard case let .updateMetadata(update)? = request.message else {
            return XCTFail("Expected SignalRequest.updateMetadata.")
        }

        try await transport.enqueueIncomingFrame(
            .binary(SignalFrameCodec().encode(makeRequestResponse(requestID: update.requestID, reason: .notAllowed)))
        )

        do {
            try await updateTask.value
            XCTFail("Expected metadata update to fail.")
        } catch {
            XCTAssertEqual(error as? LiveKitNativeError, .permissionDenied(action: "participant metadata update"))
        }
        XCTAssertNil(room.localParticipant.metadata)
    }

    func testPublishVideoTrackSendsAddTrackAndAppliesTrackPublishedResponse() async throws {
        let frames = try [
            makeJoinResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))
        let track = LocalVideoTrack(name: "camera", source: .camera)

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let publishTask = Task {
            try await room.localParticipant.publish(
                videoTrack: track,
                options: TrackPublishOptions(name: "main-camera", source: .camera)
            )
        }

        let sentFrames = await waitForSentFrameCount(1, transport: transport)
        guard case let .binary(data) = try XCTUnwrap(sentFrames.first) else {
            return XCTFail("Expected binary AddTrack request.")
        }

        let request = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: data)
        guard case let .addTrack(addTrack)? = request.message else {
            return XCTFail("Expected SignalRequest.addTrack.")
        }
        XCTAssertEqual(addTrack.cid, track.id)
        XCTAssertEqual(addTrack.name, "main-camera")
        XCTAssertEqual(addTrack.type, .video)
        XCTAssertEqual(addTrack.source, .camera)

        try await transport.enqueueIncomingFrame(
            .binary(
                SignalFrameCodec().encode(
                    makeTrackPublishedResponse(
                        cid: addTrack.cid,
                        sid: "TR_local_camera",
                        name: "main-camera",
                        type: .video,
                        source: .camera
                    )
                )
            )
        )

        let publication = try await publishTask.value
        XCTAssertEqual(publication.sid, "TR_local_camera")
        XCTAssertEqual(publication.name, "main-camera")
        XCTAssertEqual(publication.kind, .video)
        XCTAssertEqual(room.localParticipant.trackPublications.map(\.sid), ["TR_local_camera"])
    }

    func testPublishAudioTrackSendsAddTrackAndAppliesTrackPublishedResponse() async throws {
        let frames = try [
            makeJoinResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))
        let track = LocalAudioTrack(name: "microphone", source: .microphone)

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let publishTask = Task {
            try await room.localParticipant.publish(
                audioTrack: track,
                options: TrackPublishOptions(name: "main-mic", source: .microphone)
            )
        }

        let sentFrames = await waitForSentFrameCount(1, transport: transport)
        guard case let .binary(data) = try XCTUnwrap(sentFrames.first) else {
            return XCTFail("Expected binary AddTrack request.")
        }

        let request = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: data)
        guard case let .addTrack(addTrack)? = request.message else {
            return XCTFail("Expected SignalRequest.addTrack.")
        }
        XCTAssertEqual(addTrack.cid, track.id)
        XCTAssertEqual(addTrack.name, "main-mic")
        XCTAssertEqual(addTrack.type, .audio)
        XCTAssertEqual(addTrack.source, .microphone)

        try await transport.enqueueIncomingFrame(
            .binary(
                SignalFrameCodec().encode(
                    makeTrackPublishedResponse(
                        cid: addTrack.cid,
                        sid: "TR_local_microphone",
                        name: "main-mic",
                        type: .audio,
                        source: .microphone
                    )
                )
            )
        )

        let publication = try await publishTask.value
        XCTAssertEqual(publication.sid, "TR_local_microphone")
        XCTAssertEqual(publication.name, "main-mic")
        XCTAssertEqual(publication.kind, .audio)
        XCTAssertEqual(room.localParticipant.trackPublications.map(\.sid), ["TR_local_microphone"])
    }

    func testPublishDataTrackSendsRequestAndAppliesResponse() async throws {
        let frames = try [
            makeJoinResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let publishTask = Task {
            try await room.localParticipant.publishDataTrack(name: "telemetry", encryption: .gcm)
        }

        let sentFrames = await waitForSentFrameCount(1, transport: transport)
        guard case let .binary(data) = try XCTUnwrap(sentFrames.first) else {
            return XCTFail("Expected binary PublishDataTrack request.")
        }

        let request = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: data)
        guard case let .publishDataTrackRequest(publishRequest)? = request.message else {
            return XCTFail("Expected SignalRequest.publishDataTrackRequest.")
        }
        XCTAssertEqual(publishRequest.pubHandle, 1)
        XCTAssertEqual(publishRequest.name, "telemetry")
        XCTAssertEqual(publishRequest.encryption, .gcm)

        try await transport.enqueueIncomingFrame(
            .binary(
                SignalFrameCodec().encode(
                    makePublishDataTrackResponse(
                        pubHandle: publishRequest.pubHandle,
                        sid: "DT_telemetry",
                        name: "telemetry",
                        encryption: .gcm
                    )
                )
            )
        )

        let dataTrack = try await publishTask.value
        XCTAssertEqual(dataTrack, DataTrackInfo(
            publisherHandle: 1,
            sid: "DT_telemetry",
            name: "telemetry",
            encryption: .gcm
        ))
        XCTAssertEqual(room.localParticipant.dataTrackPublications, [dataTrack])
    }

    func testUnpublishDataTrackSendsRequestAndAppliesResponse() async throws {
        let frames = try [
            makeJoinResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let publishTask = Task {
            try await room.localParticipant.publishDataTrack(name: "telemetry", encryption: .gcm)
        }
        let publishSentFrames = await waitForSentFrameCount(1, transport: transport)
        guard case let .binary(publishData) = try XCTUnwrap(publishSentFrames.first) else {
            return XCTFail("Expected binary PublishDataTrack request.")
        }
        let publishSignalRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: publishData)
        guard case let .publishDataTrackRequest(publishRequest)? = publishSignalRequest.message else {
            return XCTFail("Expected SignalRequest.publishDataTrackRequest.")
        }
        try await transport.enqueueIncomingFrame(
            .binary(
                SignalFrameCodec().encode(
                    makePublishDataTrackResponse(
                        pubHandle: publishRequest.pubHandle,
                        sid: "DT_telemetry",
                        name: "telemetry",
                        encryption: .gcm
                    )
                )
            )
        )
        let dataTrack = try await publishTask.value

        let unpublishTask = Task {
            try await room.localParticipant.unpublishDataTrack(dataTrack)
        }
        let unpublishSentFrames = await waitForSentFrameCount(2, transport: transport)
        guard case let .binary(unpublishData) = unpublishSentFrames[1] else {
            return XCTFail("Expected binary UnpublishDataTrack request.")
        }

        let unpublishSignalRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: unpublishData)
        guard case let .unpublishDataTrackRequest(unpublishRequest)? = unpublishSignalRequest.message else {
            return XCTFail("Expected SignalRequest.unpublishDataTrackRequest.")
        }
        XCTAssertEqual(unpublishRequest.pubHandle, dataTrack.publisherHandle)

        try await transport.enqueueIncomingFrame(
            .binary(
                SignalFrameCodec().encode(
                    makeUnpublishDataTrackResponse(
                        pubHandle: dataTrack.publisherHandle,
                        sid: dataTrack.sid,
                        name: dataTrack.name,
                        encryption: .gcm
                    )
                )
            )
        )

        let unpublished = try await unpublishTask.value
        XCTAssertEqual(unpublished, dataTrack)
        XCTAssertEqual(room.localParticipant.dataTrackPublications, [])
    }

    func testUpdateDataSubscriptionSendsSignalRequest() async throws {
        let frames = try [
            makeJoinResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")
        try await room.localParticipant.updateDataSubscription(
            trackSID: "DT_remote",
            subscribe: true,
            targetFPS: 24
        )

        let sentFrames = await waitForSentFrameCount(1, transport: transport)
        guard case let .binary(data) = try XCTUnwrap(sentFrames.first) else {
            return XCTFail("Expected binary UpdateDataSubscription request.")
        }

        let request = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: data)
        guard case let .updateDataSubscription(update)? = request.message else {
            return XCTFail("Expected SignalRequest.updateDataSubscription.")
        }
        XCTAssertEqual(update.updates.count, 1)
        XCTAssertEqual(update.updates[0].trackSid, "DT_remote")
        XCTAssertTrue(update.updates[0].subscribe)
        XCTAssertEqual(update.updates[0].options.targetFps, 24)
    }

    func testDisconnectClearsRemoteParticipantsAndEmitsLifecycleEvents() async throws {
        let frames = try [
            makeJoinResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))
        let eventRecorder = RoomEventRecorder()
        room.delegate = eventRecorder

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")
        XCTAssertEqual(room.remoteParticipants.count, 1)

        await room.disconnect()

        XCTAssertEqual(room.connectionState, .disconnected)
        XCTAssertEqual(room.remoteParticipants.count, 0)

        let events = eventRecorder.recordedEvents
        XCTAssertEqual(events.count, 8)
        XCTAssertEqual(events[4], .connectionStateChanged(.disconnecting))

        guard case let .trackUnpublished(publication, participant) = events[5] else {
            return XCTFail("Expected remote track cleanup event.")
        }
        XCTAssertEqual(publication.sid, "TR_camera")
        XCTAssertEqual(participant.sid, "PA_alice")
        XCTAssertEqual(events[6], .participantDisconnected(participant))
        XCTAssertEqual(events[7], .connectionStateChanged(.disconnected))

        let closeCalls = await transport.closeCalls
        XCTAssertEqual(closeCalls.count, 1)
    }
}

private func makeJoinResponse(
    alternativeURL: String = "",
    remoteSID: String = "PA_alice",
    remoteIdentity: String = "alice",
    remoteName: String = "Alice",
    remoteTrackSID: String = "TR_camera"
) -> Livekit_SignalResponse {
    var localParticipant = Livekit_ParticipantInfo()
    localParticipant.sid = "PA_local"
    localParticipant.identity = "marlon"
    localParticipant.name = "Marlon"
    localParticipant.attributes = ["role": "host"]

    var remoteParticipant = Livekit_ParticipantInfo()
    remoteParticipant.sid = remoteSID
    remoteParticipant.identity = remoteIdentity
    remoteParticipant.name = remoteName
    remoteParticipant.metadata = "remote-metadata"
    remoteParticipant.tracks = [makeRemoteCameraTrack(sid: remoteTrackSID)]

    var join = Livekit_JoinResponse()
    join.participant = localParticipant
    join.otherParticipants = [remoteParticipant]
    join.alternativeURL = alternativeURL

    var response = Livekit_SignalResponse()
    response.join = join
    return response
}

private func makeRemoteCameraTrack(sid: String = "TR_camera") -> Livekit_TrackInfo {
    var track = Livekit_TrackInfo()
    track.sid = sid
    track.name = "camera"
    track.type = .video
    track.source = .camera
    return track
}

private func makeParticipantUpdateResponse() -> Livekit_SignalResponse {
    var participant = Livekit_ParticipantInfo()
    participant.sid = "PA_bob"
    participant.identity = "bob"
    participant.name = "Bob"
    participant.tracks = [makeRemoteMicrophoneTrack()]

    var update = Livekit_ParticipantUpdate()
    update.participants = [participant]

    var response = Livekit_SignalResponse()
    response.update = update
    return response
}

private func makeRemoteMicrophoneTrack() -> Livekit_TrackInfo {
    var track = Livekit_TrackInfo()
    track.sid = "TR_microphone"
    track.name = "microphone"
    track.type = .audio
    track.source = .microphone
    return track
}

private func makeRefreshTokenResponse() -> Livekit_SignalResponse {
    var response = Livekit_SignalResponse()
    response.refreshToken = "refreshed-token"
    return response
}

private func makeLeaveResponse(action: Livekit_LeaveRequest.Action = .disconnect) -> Livekit_SignalResponse {
    var leave = Livekit_LeaveRequest()
    leave.action = action

    var response = Livekit_SignalResponse()
    response.leave = leave
    return response
}

private func makeReconnectResponse() -> Livekit_SignalResponse {
    var reconnect = Livekit_ReconnectResponse()
    reconnect.lastMessageSeq = 5

    var response = Livekit_SignalResponse()
    response.reconnect = reconnect
    return response
}

private func makeSubscriberOfferResponse() -> Livekit_SignalResponse {
    var offer = Livekit_SessionDescription()
    offer.type = "offer"
    offer.id = 7
    offer.sdp = subscriberOfferSDP()

    var response = Livekit_SignalResponse()
    response.offer = offer
    return response
}

private func makePublisherAnswerResponse() -> Livekit_SignalResponse {
    var answer = Livekit_SessionDescription()
    answer.type = "answer"
    answer.id = 11
    answer.sdp = publisherAnswerSDP()

    var response = Livekit_SignalResponse()
    response.answer = answer
    return response
}

private func makeSubscriberTrickleResponse() -> Livekit_SignalResponse {
    var trickle = Livekit_TrickleRequest()
    trickle.target = .subscriber
    trickle.candidateInit = """
    {"candidate":"candidate:1 1 UDP 2122260223 192.0.2.1 54545 typ host","sdpMid":"0","sdpMLineIndex":0,"usernameFragment":"remote-ufrag"}
    """

    var response = Livekit_SignalResponse()
    response.trickle = trickle
    return response
}

private func makeSubscriberTrickleCompleteResponse() -> Livekit_SignalResponse {
    var trickle = Livekit_TrickleRequest()
    trickle.target = .subscriber
    trickle.final = true

    var response = Livekit_SignalResponse()
    response.trickle = trickle
    return response
}

private func makePublisherTrickleResponse() -> Livekit_SignalResponse {
    var trickle = Livekit_TrickleRequest()
    trickle.target = .publisher
    trickle.candidateInit = """
    {"candidate":"candidate:2 1 UDP 2122260223 192.0.2.2 54546 typ host","sdpMid":"1","sdpMLineIndex":1,"usernameFragment":"publisher-ufrag"}
    """

    var response = Livekit_SignalResponse()
    response.trickle = trickle
    return response
}

private func makePublisherTrickleCompleteResponse() -> Livekit_SignalResponse {
    var trickle = Livekit_TrickleRequest()
    trickle.target = .publisher
    trickle.final = true

    var response = Livekit_SignalResponse()
    response.trickle = trickle
    return response
}

private func makeTrackUnpublishedResponse() -> Livekit_SignalResponse {
    var trackUnpublished = Livekit_TrackUnpublishedResponse()
    trackUnpublished.trackSid = "TR_camera"

    var response = Livekit_SignalResponse()
    response.trackUnpublished = trackUnpublished
    return response
}

private func makeRequestResponse(
    requestID: UInt32,
    reason: Livekit_RequestResponse.Reason,
    message: String = ""
) -> Livekit_SignalResponse {
    var requestResponse = Livekit_RequestResponse()
    requestResponse.requestID = requestID
    requestResponse.reason = reason
    requestResponse.message = message

    var response = Livekit_SignalResponse()
    response.requestResponse = requestResponse
    return response
}

private func makeTrackPublishedResponse(
    cid: String,
    sid: String,
    name: String,
    type: Livekit_TrackType,
    source: Livekit_TrackSource
) -> Livekit_SignalResponse {
    var track = Livekit_TrackInfo()
    track.sid = sid
    track.name = name
    track.type = type
    track.source = source

    var trackPublished = Livekit_TrackPublishedResponse()
    trackPublished.cid = cid
    trackPublished.track = track

    var response = Livekit_SignalResponse()
    response.trackPublished = trackPublished
    return response
}

private func makeSpeakersChangedResponse() -> Livekit_SignalResponse {
    var speaker = Livekit_SpeakerInfo()
    speaker.sid = "PA_alice"
    speaker.level = 0.5
    speaker.active = true

    var speakers = Livekit_SpeakersChanged()
    speakers.speakers = [speaker]

    var response = Livekit_SignalResponse()
    response.speakersChanged = speakers
    return response
}

private func makeConnectionQualityResponse() -> Livekit_SignalResponse {
    var qualityInfo = Livekit_ConnectionQualityInfo()
    qualityInfo.participantSid = "PA_alice"
    qualityInfo.quality = .excellent
    qualityInfo.score = 0.75

    var update = Livekit_ConnectionQualityUpdate()
    update.updates = [qualityInfo]

    var response = Livekit_SignalResponse()
    response.connectionQuality = update
    return response
}

private func makeStreamStateUpdateResponse() -> Livekit_SignalResponse {
    var streamState = Livekit_StreamStateInfo()
    streamState.participantSid = "PA_alice"
    streamState.trackSid = "TR_camera"
    streamState.state = .paused

    var update = Livekit_StreamStateUpdate()
    update.streamStates = [streamState]

    var response = Livekit_SignalResponse()
    response.streamStateUpdate = update
    return response
}

private func makeRoomUpdateResponse() -> Livekit_SignalResponse {
    var room = Livekit_Room()
    room.sid = "RM_main"
    room.name = "main-room"
    room.metadata = "room-metadata"
    room.numParticipants = 3
    room.numPublishers = 2
    room.activeRecording = true

    var update = Livekit_RoomUpdate()
    update.room = room

    var response = Livekit_SignalResponse()
    response.roomUpdate = update
    return response
}

private func makeSubscribedQualityUpdateResponse() -> Livekit_SignalResponse {
    var highQuality = Livekit_SubscribedQuality()
    highQuality.quality = .high
    highQuality.enabled = true

    var lowQuality = Livekit_SubscribedQuality()
    lowQuality.quality = .low
    lowQuality.enabled = false

    var mediumQuality = Livekit_SubscribedQuality()
    mediumQuality.quality = .medium
    mediumQuality.enabled = true

    var codec = Livekit_SubscribedCodec()
    codec.codec = "h264"
    codec.qualities = [mediumQuality]

    var update = Livekit_SubscribedQualityUpdate()
    update.trackSid = "TR_camera"
    update.subscribedQualities = [highQuality, lowQuality]
    update.subscribedCodecs = [codec]

    var response = Livekit_SignalResponse()
    response.subscribedQualityUpdate = update
    return response
}

private func makeSubscriptionPermissionUpdateResponse() -> Livekit_SignalResponse {
    var update = Livekit_SubscriptionPermissionUpdate()
    update.participantSid = "PA_alice"
    update.trackSid = "TR_camera"
    update.allowed = false

    var response = Livekit_SignalResponse()
    response.subscriptionPermissionUpdate = update
    return response
}

private func makeSubscriptionResponse() -> Livekit_SignalResponse {
    var subscriptionResponse = Livekit_SubscriptionResponse()
    subscriptionResponse.trackSid = "TR_camera"
    subscriptionResponse.err = .seCodecUnsupported

    var response = Livekit_SignalResponse()
    response.subscriptionResponse = subscriptionResponse
    return response
}

private func makeTrackSubscribedResponse() -> Livekit_SignalResponse {
    var trackSubscribed = Livekit_TrackSubscribed()
    trackSubscribed.trackSid = "TR_camera"

    var response = Livekit_SignalResponse()
    response.trackSubscribed = trackSubscribed
    return response
}

private func makeMediaSectionsRequirementResponse() -> Livekit_SignalResponse {
    var requirement = Livekit_MediaSectionsRequirement()
    requirement.numAudios = 2
    requirement.numVideos = 3

    var response = Livekit_SignalResponse()
    response.mediaSectionsRequirement = requirement
    return response
}

private func makeSubscribedAudioCodecUpdateResponse() -> Livekit_SignalResponse {
    var opus = Livekit_SubscribedAudioCodec()
    opus.codec = "opus"
    opus.enabled = true

    var aac = Livekit_SubscribedAudioCodec()
    aac.codec = "aac"
    aac.enabled = false

    var update = Livekit_SubscribedAudioCodecUpdate()
    update.trackSid = "TR_microphone"
    update.subscribedAudioCodecs = [opus, aac]

    var response = Livekit_SignalResponse()
    response.subscribedAudioCodecUpdate = update
    return response
}

private func makePublishDataTrackResponse(
    pubHandle: UInt32 = 41,
    sid: String = "DT_location",
    name: String = "location",
    encryption: Livekit_Encryption.TypeEnum = .gcm
) -> Livekit_SignalResponse {
    var response = Livekit_SignalResponse()
    response.publishDataTrackResponse = makePublishDataTrackResponsePayload(
        pubHandle: pubHandle,
        sid: sid,
        name: name,
        encryption: encryption
    )
    return response
}

private func makeUnpublishDataTrackResponse(
    pubHandle: UInt32 = 41,
    sid: String = "DT_location",
    name: String = "location",
    encryption: Livekit_Encryption.TypeEnum = .gcm
) -> Livekit_SignalResponse {
    var response = Livekit_SignalResponse()
    response.unpublishDataTrackResponse = makeUnpublishDataTrackResponsePayload(
        pubHandle: pubHandle,
        sid: sid,
        name: name,
        encryption: encryption
    )
    return response
}

private func makePublishDataTrackResponsePayload(
    pubHandle: UInt32 = 41,
    sid: String = "DT_location",
    name: String = "location",
    encryption: Livekit_Encryption.TypeEnum = .gcm
) -> Livekit_PublishDataTrackResponse {
    var response = Livekit_PublishDataTrackResponse()
    response.info = makeDataTrackInfo(
        pubHandle: pubHandle,
        sid: sid,
        name: name,
        encryption: encryption
    )
    return response
}

private func makeUnpublishDataTrackResponsePayload(
    pubHandle: UInt32 = 41,
    sid: String = "DT_location",
    name: String = "location",
    encryption: Livekit_Encryption.TypeEnum = .gcm
) -> Livekit_UnpublishDataTrackResponse {
    var response = Livekit_UnpublishDataTrackResponse()
    response.info = makeDataTrackInfo(
        pubHandle: pubHandle,
        sid: sid,
        name: name,
        encryption: encryption
    )
    return response
}

private func makeDataTrackInfo(
    pubHandle: UInt32 = 41,
    sid: String = "DT_location",
    name: String = "location",
    encryption: Livekit_Encryption.TypeEnum = .gcm
) -> Livekit_DataTrackInfo {
    var info = Livekit_DataTrackInfo()
    info.pubHandle = pubHandle
    info.sid = sid
    info.name = name
    info.encryption = encryption
    return info
}

private func makeDataTrackSubscriberHandlesResponse() -> Livekit_SignalResponse {
    var aliceTrack = Livekit_DataTrackSubscriberHandles.PublishedDataTrack()
    aliceTrack.publisherIdentity = "alice"
    aliceTrack.publisherSid = "PA_alice"
    aliceTrack.trackSid = "DT_location"

    var bobTrack = Livekit_DataTrackSubscriberHandles.PublishedDataTrack()
    bobTrack.publisherIdentity = "bob"
    bobTrack.publisherSid = "PA_bob"
    bobTrack.trackSid = "DT_controls"

    var handles = Livekit_DataTrackSubscriberHandles()
    handles.subHandles = [
        9: bobTrack,
        7: aliceTrack,
    ]

    var response = Livekit_SignalResponse()
    response.dataTrackSubscriberHandles = handles
    return response
}

private func makeRoomMovedResponse() -> Livekit_SignalResponse {
    var room = Livekit_Room()
    room.sid = "RM_moved"
    room.name = "moved-room"

    var localParticipant = Livekit_ParticipantInfo()
    localParticipant.sid = "PA_moved_local"
    localParticipant.identity = "moved-local"
    localParticipant.name = "Moved Local"

    var remoteParticipant = Livekit_ParticipantInfo()
    remoteParticipant.sid = "PA_bob"
    remoteParticipant.identity = "bob"
    remoteParticipant.name = "Bob"
    remoteParticipant.tracks = [makeRemoteCameraTrack(sid: "TR_bob_camera")]

    var roomMoved = Livekit_RoomMovedResponse()
    roomMoved.room = room
    roomMoved.token = "moved-token"
    roomMoved.participant = localParticipant
    roomMoved.otherParticipants = [remoteParticipant]

    var response = Livekit_SignalResponse()
    response.roomMoved = roomMoved
    return response
}

private func subscriberOfferSDP() -> String {
    """
    v=0
    o=- 1 1 IN IP4 127.0.0.1
    s=-
    t=0 0
    a=group:BUNDLE 0 1 data
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    a=mid:0
    a=setup:actpass
    a=rtcp-mux
    a=rtpmap:111 opus/48000/2
    m=video 9 UDP/TLS/RTP/SAVPF 102 96 35
    a=mid:1
    a=setup:actpass
    a=rtcp-mux
    a=rtpmap:102 H264/90000
    a=rtpmap:96 VP8/90000
    a=rtpmap:35 AV1/90000
    m=application 9 UDP/DTLS/SCTP webrtc-datachannel
    a=mid:data
    a=setup:actpass
    a=sctp-port:5000
    """
}

private func publisherAnswerSDP() -> String {
    """
    v=0
    o=- 2 2 IN IP4 127.0.0.1
    s=-
    t=0 0
    a=group:BUNDLE 0 1 data
    m=audio 9 UDP/TLS/RTP/SAVPF 111
    a=mid:0
    a=setup:active
    a=rtcp-mux
    a=rtpmap:111 opus/48000/2
    m=video 9 UDP/TLS/RTP/SAVPF 102
    a=mid:1
    a=setup:active
    a=rtcp-mux
    a=rtpmap:102 H264/90000
    m=application 9 UDP/DTLS/SCTP webrtc-datachannel
    a=mid:data
    a=setup:active
    a=sctp-port:5000
    """
}

private func waitForSentFrameCount(_ expectedCount: Int, transport: MockSignalTransport) async -> [SignalTransportFrame] {
    for _ in 0..<100 {
        let sentFrames = await transport.sentFrames
        if sentFrames.count >= expectedCount {
            return sentFrames
        }

        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    return await transport.sentFrames
}

private func waitForRemoteAnswer(peerConnection: PeerConnectionCoordinator) async -> RemoteSessionDescription? {
    for _ in 0..<100 {
        if let remoteAnswer = peerConnection.remoteAnswer {
            return remoteAnswer
        }

        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    return peerConnection.remoteAnswer
}

private func waitForRemoteCandidateCount(
    _ expectedCount: Int,
    peerConnection: PeerConnectionCoordinator
) async -> [RemoteICECandidate] {
    for _ in 0..<100 {
        let candidates = peerConnection.remoteICECandidates
        if candidates.count >= expectedCount, peerConnection.isRemoteICEGatheringComplete {
            return candidates
        }

        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    return peerConnection.remoteICECandidates
}

private final class RoomEventRecorder: RoomDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RoomEvent] = []

    var recordedEvents: [RoomEvent] {
        lock.withLock {
            events
        }
    }

    func room(_ room: Room, didEmit event: RoomEvent) {
        lock.withLock {
            events.append(event)
        }
    }

    func waitForEventCount(_ expectedCount: Int) async -> [RoomEvent] {
        for _ in 0..<100 {
            let events = recordedEvents
            if events.count >= expectedCount {
                return events
            }

            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        return recordedEvents
    }
}
