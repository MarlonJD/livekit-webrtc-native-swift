import Foundation
import AVFoundation
import CoreMedia
import CoreVideo
import Darwin
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

    func testConnectIncludesConnectionSettingsInSignalURL() async throws {
        let response = makeJoinResponse()
        let encodedResponse = try SignalFrameCodec().encode(response)
        let transport = MockSignalTransport(incomingFrames: [.binary(encodedResponse)])
        let room = Room(signalConnection: SignalConnection(transport: transport))

        try await room.connect(
            url: URL(string: "https://example.test?region=eu&adaptive_stream=false")!,
            token: "token",
            connectOptions: ConnectOptions(
                adaptiveStream: true,
                subscriberAllowPause: true,
                autoSubscribeDataTrack: false
            )
        )

        let connectedURLs = await transport.connectedURLs
        let connectedURL = try XCTUnwrap(connectedURLs.first)
        let queryItems = URLComponents(url: connectedURL, resolvingAgainstBaseURL: false)?.queryItems ?? []

        XCTAssertEqual(queryItems.first(where: { $0.name == "region" })?.value, "eu")
        XCTAssertEqual(queryItems.first(where: { $0.name == "adaptive_stream" })?.value, "true")
        XCTAssertEqual(queryItems.first(where: { $0.name == "subscriber_allow_pause" })?.value, "true")
        XCTAssertEqual(queryItems.first(where: { $0.name == "auto_subscribe_data_track" })?.value, "false")
    }

    func testConnectUsesRoomDefaultConnectionSettings() async throws {
        let response = makeJoinResponse()
        let encodedResponse = try SignalFrameCodec().encode(response)
        let transport = MockSignalTransport(incomingFrames: [.binary(encodedResponse)])
        let room = Room(
            options: RoomOptions(
                defaultAutoSubscribe: false,
                defaultAdaptiveStream: true,
                defaultSubscriberAllowPause: true,
                defaultAutoSubscribeDataTrack: false
            ),
            signalConnection: SignalConnection(transport: transport)
        )

        try await room.connect(url: URL(string: "https://example.test")!, token: "token")

        let connectedURLs = await transport.connectedURLs
        let connectedURL = try XCTUnwrap(connectedURLs.first)
        let queryItems = URLComponents(url: connectedURL, resolvingAgainstBaseURL: false)?.queryItems ?? []

        XCTAssertEqual(queryItems.first(where: { $0.name == "auto_subscribe" })?.value, "false")
        XCTAssertEqual(queryItems.first(where: { $0.name == "adaptive_stream" })?.value, "true")
        XCTAssertEqual(queryItems.first(where: { $0.name == "subscriber_allow_pause" })?.value, "true")
        XCTAssertEqual(queryItems.first(where: { $0.name == "auto_subscribe_data_track" })?.value, "false")
    }

    func testConnectConfiguresAudioSessionWhenEnabled() async throws {
        let response = makeJoinResponse()
        let encodedResponse = try SignalFrameCodec().encode(response)
        let transport = MockSignalTransport(incomingFrames: [.binary(encodedResponse)])
        let audioSessionController = RecordingAudioSessionController()
        let room = Room(
            options: RoomOptions(automaticallyConfigureAudioSession: true),
            signalConnection: SignalConnection(transport: transport),
            audioSessionController: audioSessionController
        )

        try await room.connect(url: URL(string: "https://example.test")!, token: "token")

        XCTAssertEqual(
            audioSessionController.events,
            [.configure(.voiceChat), .activate]
        )

        await room.disconnect()

        XCTAssertEqual(
            audioSessionController.events,
            [.configure(.voiceChat), .activate, .deactivate]
        )
    }

    func testConnectLeavesAudioSessionAloneByDefault() async throws {
        let response = makeJoinResponse()
        let encodedResponse = try SignalFrameCodec().encode(response)
        let transport = MockSignalTransport(incomingFrames: [.binary(encodedResponse)])
        let audioSessionController = RecordingAudioSessionController()
        let room = Room(
            signalConnection: SignalConnection(transport: transport),
            audioSessionController: audioSessionController
        )

        try await room.connect(url: URL(string: "https://example.test")!, token: "token")
        await room.disconnect()

        XCTAssertEqual(audioSessionController.events, [])
    }

    func testConnectOptionsOverrideRoomDefaultConnectionSettings() async throws {
        let response = makeJoinResponse()
        let encodedResponse = try SignalFrameCodec().encode(response)
        let transport = MockSignalTransport(incomingFrames: [.binary(encodedResponse)])
        let room = Room(
            options: RoomOptions(
                defaultAutoSubscribe: false,
                defaultAdaptiveStream: true,
                defaultSubscriberAllowPause: true,
                defaultAutoSubscribeDataTrack: false
            ),
            signalConnection: SignalConnection(transport: transport)
        )

        try await room.connect(
            url: URL(string: "https://example.test")!,
            token: "token",
            connectOptions: ConnectOptions(
                autoSubscribe: true,
                adaptiveStream: false,
                subscriberAllowPause: false,
                autoSubscribeDataTrack: true
            )
        )

        let connectedURLs = await transport.connectedURLs
        let connectedURL = try XCTUnwrap(connectedURLs.first)
        let queryItems = URLComponents(url: connectedURL, resolvingAgainstBaseURL: false)?.queryItems ?? []

        XCTAssertEqual(queryItems.first(where: { $0.name == "auto_subscribe" })?.value, "true")
        XCTAssertEqual(queryItems.first(where: { $0.name == "adaptive_stream" })?.value, "false")
        XCTAssertEqual(queryItems.first(where: { $0.name == "subscriber_allow_pause" })?.value, "false")
        XCTAssertEqual(queryItems.first(where: { $0.name == "auto_subscribe_data_track" })?.value, "true")
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

    func testConnectAppliesJoinICEServersToPeerConnections() async throws {
        let frames = try [
            makeJoinResponse(iceServers: [
                makeICEServer(
                    urls: ["stun:stun.example.test:3478"]
                ),
                makeICEServer(
                    urls: ["turn:turn.example.test:3478?transport=udp"],
                    username: "user",
                    credential: "pass"
                ),
            ]),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let staleSubscriberCredentials = ICECredentials(
            usernameFragment: "stale-sub-local",
            password: "stale-sub-password"
        )
        let stalePublisherCredentials = ICECredentials(
            usernameFragment: "stale-pub-local",
            password: "stale-pub-password"
        )
        let subscriberPeerConnection = PeerConnectionCoordinator(
            configuration: NativeWebRTCConfiguration(
                role: .subscriber,
                iceCredentials: staleSubscriberCredentials
            )
        )
        let publisherPeerConnection = PeerConnectionCoordinator(
            configuration: NativeWebRTCConfiguration(
                role: .publisher,
                iceCredentials: stalePublisherCredentials
            )
        )
        let room = Room(
            signalConnection: SignalConnection(transport: transport),
            subscriberPeerConnection: subscriberPeerConnection,
            publisherPeerConnection: publisherPeerConnection
        )

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let expected = [
            ICEServer(urls: ["stun:stun.example.test:3478"]),
            ICEServer(
                urls: ["turn:turn.example.test:3478?transport=udp"],
                username: "user",
                credential: "pass"
            ),
        ]
        XCTAssertEqual(subscriberPeerConnection.configuration.iceServers, expected)
        XCTAssertEqual(publisherPeerConnection.configuration.iceServers, expected)
    }

    func testConnectClearsStalePeerConnectionNegotiationState() async throws {
        let frames = try [
            makeJoinResponse(iceServers: [
                makeICEServer(urls: ["stun:fresh.example.test:3478"]),
            ]),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let staleSubscriberCredentials = ICECredentials(
            usernameFragment: "stale-sub-local",
            password: "stale-sub-password"
        )
        let stalePublisherCredentials = ICECredentials(
            usernameFragment: "stale-pub-local",
            password: "stale-pub-password"
        )
        let subscriberPeerConnection = PeerConnectionCoordinator(
            configuration: NativeWebRTCConfiguration(
                role: .subscriber,
                iceCredentials: staleSubscriberCredentials
            )
        )
        let publisherPeerConnection = PeerConnectionCoordinator(
            configuration: NativeWebRTCConfiguration(
                role: .publisher,
                iceCredentials: stalePublisherCredentials
            )
        )
        _ = try subscriberPeerConnection.makeSubscriberAnswer(for: subscriberOfferSDP())
        try subscriberPeerConnection.addRemoteICECandidate(
            candidateInitJSON: #"{"candidate":"candidate:stale-sub 1 UDP 2122260223 192.0.2.30 54545 typ host","sdpMid":"0","sdpMLineIndex":0}"#,
            isFinal: true
        )
        try publisherPeerConnection.applyPublisherAnswer(type: "answer", sdp: publisherAnswerSDP(), id: 3)
        try publisherPeerConnection.addRemoteICECandidate(
            candidateInitJSON: #"{"candidate":"candidate:stale-pub 1 UDP 2122260223 192.0.2.31 54546 typ host","sdpMid":"1","sdpMLineIndex":1}"#,
            isFinal: true
        )
        let room = Room(
            signalConnection: SignalConnection(transport: transport),
            subscriberPeerConnection: subscriberPeerConnection,
            publisherPeerConnection: publisherPeerConnection
        )

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let expected = [ICEServer(urls: ["stun:fresh.example.test:3478"])]
        XCTAssertEqual(subscriberPeerConnection.configuration.iceServers, expected)
        XCTAssertEqual(publisherPeerConnection.configuration.iceServers, expected)
        XCTAssertNotEqual(subscriberPeerConnection.configuration.iceCredentials, staleSubscriberCredentials)
        XCTAssertNotEqual(publisherPeerConnection.configuration.iceCredentials, stalePublisherCredentials)
        XCTAssertNil(subscriberPeerConnection.remoteICECredentials)
        XCTAssertNil(subscriberPeerConnection.remoteDTLSFingerprint)
        XCTAssertFalse(subscriberPeerConnection.isRemoteICEGatheringComplete)
        XCTAssertTrue(subscriberPeerConnection.remoteICECandidates.isEmpty)
        XCTAssertNil(publisherPeerConnection.remoteAnswer)
        XCTAssertNil(publisherPeerConnection.remoteICECredentials)
        XCTAssertNil(publisherPeerConnection.remoteDTLSFingerprint)
        XCTAssertFalse(publisherPeerConnection.isRemoteICEGatheringComplete)
        XCTAssertTrue(publisherPeerConnection.remoteICECandidates.isEmpty)
        XCTAssertEqual(publisherPeerConnection.state, .new)
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

    func testSignalLoopIgnoresLocalParticipantEchoInParticipantUpdate() async throws {
        var localEcho = Livekit_ParticipantInfo()
        localEcho.sid = "PA_local"
        localEcho.identity = "marlon"
        localEcho.name = "Marlon"

        var remoteParticipant = Livekit_ParticipantInfo()
        remoteParticipant.sid = "PA_bob"
        remoteParticipant.identity = "bob"
        remoteParticipant.name = "Bob"
        remoteParticipant.tracks = [makeRemoteMicrophoneTrack()]

        var update = Livekit_ParticipantUpdate()
        update.participants = [localEcho, remoteParticipant]

        var updateResponse = Livekit_SignalResponse()
        updateResponse.update = update

        let frames = try [
            makeJoinResponse(),
            updateResponse,
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }
        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))
        let eventRecorder = RoomEventRecorder()
        room.delegate = eventRecorder

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let events = await eventRecorder.waitForEventCount(5)

        XCTAssertEqual(room.remoteParticipants.map(\.identity).sorted(), ["alice", "bob"])
        XCTAssertFalse(room.remoteParticipants.contains { $0.identity == "marlon" })
        XCTAssertFalse(events.contains { event in
            if case let .participantConnected(participant) = event {
                return participant.identity == "marlon"
            }
            return false
        })

        await room.disconnect()
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

    func testRefreshTokenIsUsedForSignalResume() async throws {
        let frames = try [
            makeJoinResponse(),
            makeRefreshTokenResponse(),
            makeLeaveResponse(action: .resume),
            makeReconnectResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))
        let eventRecorder = RoomEventRecorder()
        room.delegate = eventRecorder

        try await room.connect(url: URL(string: "wss://example.test")!, token: "initial-token")

        let events = await eventRecorder.waitForEventCount(7)
        XCTAssertEqual(events[4], .tokenRefreshed("refreshed-token"))
        XCTAssertEqual(events[5], .connectionStateChanged(.reconnecting))
        XCTAssertEqual(events[6], .connectionStateChanged(.connected))

        let connectedURLs = await transport.connectedURLs
        XCTAssertEqual(connectedURLs.count, 2)
        let reconnectQueryItems = URLComponents(url: connectedURLs[1], resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(reconnectQueryItems.first(where: { $0.name == "access_token" })?.value, "refreshed-token")
        XCTAssertEqual(reconnectQueryItems.first(where: { $0.name == "reconnect" })?.value, "true")
    }

    func testReconnectAppliesReconnectICEServersToPeerConnections() async throws {
        let frames = try [
            makeJoinResponse(iceServers: [
                makeICEServer(urls: ["stun:old.example.test:3478"]),
            ]),
            makeLeaveResponse(action: .resume),
            makeReconnectResponse(iceServers: [
                makeICEServer(
                    urls: ["turn:new.example.test:3478?transport=udp"],
                    username: "new-user",
                    credential: "new-pass"
                ),
            ]),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let subscriberPeerConnection = PeerConnectionCoordinator(
            configuration: NativeWebRTCConfiguration(role: .subscriber)
        )
        let publisherPeerConnection = PeerConnectionCoordinator(
            configuration: NativeWebRTCConfiguration(role: .publisher)
        )
        let room = Room(
            signalConnection: SignalConnection(transport: transport),
            subscriberPeerConnection: subscriberPeerConnection,
            publisherPeerConnection: publisherPeerConnection
        )
        let eventRecorder = RoomEventRecorder()
        room.delegate = eventRecorder

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")
        _ = await eventRecorder.waitForEventCount(6)

        let expected = [
            ICEServer(
                urls: ["turn:new.example.test:3478?transport=udp"],
                username: "new-user",
                credential: "new-pass"
            ),
        ]
        XCTAssertEqual(subscriberPeerConnection.configuration.iceServers, expected)
        XCTAssertEqual(publisherPeerConnection.configuration.iceServers, expected)
    }

    func testReconnectResponseClearsStalePeerConnectionNegotiationState() async throws {
        let frames = try [
            makeJoinResponse(iceServers: [
                makeICEServer(urls: ["stun:old.example.test:3478"]),
            ]),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let subscriberPeerConnection = PeerConnectionCoordinator(
            configuration: NativeWebRTCConfiguration(role: .subscriber)
        )
        let publisherPeerConnection = PeerConnectionCoordinator(
            configuration: NativeWebRTCConfiguration(role: .publisher)
        )
        let room = Room(
            signalConnection: SignalConnection(transport: transport),
            subscriberPeerConnection: subscriberPeerConnection,
            publisherPeerConnection: publisherPeerConnection
        )
        let eventRecorder = RoomEventRecorder()
        room.delegate = eventRecorder

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")
        let connectedSubscriberCredentials = subscriberPeerConnection.configuration.iceCredentials
        let connectedPublisherCredentials = publisherPeerConnection.configuration.iceCredentials
        _ = try subscriberPeerConnection.makeSubscriberAnswer(for: subscriberOfferSDP())
        try subscriberPeerConnection.addRemoteICECandidate(
            candidateInitJSON: #"{"candidate":"candidate:stale-sub 1 UDP 2122260223 192.0.2.30 54545 typ host","sdpMid":"0","sdpMLineIndex":0}"#,
            isFinal: true
        )
        try publisherPeerConnection.applyPublisherAnswer(type: "answer", sdp: publisherAnswerSDP(), id: 3)
        try publisherPeerConnection.addRemoteICECandidate(
            candidateInitJSON: #"{"candidate":"candidate:stale-pub 1 UDP 2122260223 192.0.2.31 54546 typ host","sdpMid":"1","sdpMLineIndex":1}"#,
            isFinal: true
        )

        try await transport.enqueueIncomingFrame(
            .binary(SignalFrameCodec().encode(makeLeaveResponse(action: .resume)))
        )
        try await transport.enqueueIncomingFrame(
            .binary(
                SignalFrameCodec().encode(
                    makeReconnectResponse(iceServers: [
                        makeICEServer(
                            urls: ["turn:new.example.test:3478?transport=udp"],
                            username: "new-user",
                            credential: "new-pass"
                        ),
                    ])
                )
            )
        )

        let events = await eventRecorder.waitForEventCount(6)
        XCTAssertEqual(events[4], .connectionStateChanged(.reconnecting))
        XCTAssertEqual(events[5], .connectionStateChanged(.connected))

        let expected = [
            ICEServer(
                urls: ["turn:new.example.test:3478?transport=udp"],
                username: "new-user",
                credential: "new-pass"
            ),
        ]
        XCTAssertEqual(subscriberPeerConnection.configuration.iceServers, expected)
        XCTAssertEqual(publisherPeerConnection.configuration.iceServers, expected)
        XCTAssertNotEqual(subscriberPeerConnection.configuration.iceCredentials, connectedSubscriberCredentials)
        XCTAssertNotEqual(publisherPeerConnection.configuration.iceCredentials, connectedPublisherCredentials)
        XCTAssertNil(subscriberPeerConnection.remoteICECredentials)
        XCTAssertNil(subscriberPeerConnection.remoteDTLSFingerprint)
        XCTAssertFalse(subscriberPeerConnection.isRemoteICEGatheringComplete)
        XCTAssertTrue(subscriberPeerConnection.remoteICECandidates.isEmpty)
        XCTAssertNil(publisherPeerConnection.remoteAnswer)
        XCTAssertNil(publisherPeerConnection.remoteICECredentials)
        XCTAssertNil(publisherPeerConnection.remoteDTLSFingerprint)
        XCTAssertFalse(publisherPeerConnection.isRemoteICEGatheringComplete)
        XCTAssertTrue(publisherPeerConnection.remoteICECandidates.isEmpty)
        XCTAssertEqual(publisherPeerConnection.state, .new)
    }

    func testReconnectSendsSyncStateForSubscriptionPreferences() async throws {
        let frames = try [
            makeJoinResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))
        let eventRecorder = RoomEventRecorder()
        room.delegate = eventRecorder

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")
        try await room.updateSubscription(trackSIDs: ["TR_camera", "TR_microphone"], subscribe: true)
        try await room.updateSubscription(trackSIDs: ["TR_microphone"], subscribe: false)
        try await room.updateTrackSettings(trackSIDs: ["TR_camera"], disabled: true)

        try await transport.enqueueIncomingFrame(
            .binary(SignalFrameCodec().encode(makeLeaveResponse(action: .resume)))
        )
        try await transport.enqueueIncomingFrame(
            .binary(SignalFrameCodec().encode(makeReconnectResponse()))
        )

        let sentFrames = await waitForSentFrameCount(4, transport: transport)
        guard case let .binary(syncData) = sentFrames[3] else {
            return XCTFail("Expected binary SyncState request.")
        }

        let request = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: syncData)
        guard case let .syncState(syncState)? = request.message else {
            return XCTFail("Expected SignalRequest.syncState.")
        }
        XCTAssertTrue(syncState.hasSubscription)
        XCTAssertEqual(syncState.subscription.trackSids, ["TR_camera"])
        XCTAssertTrue(syncState.subscription.subscribe)
        XCTAssertEqual(syncState.trackSidsDisabled, ["TR_camera"])

        let events = await eventRecorder.waitForEventCount(6)
        XCTAssertEqual(events[4], .connectionStateChanged(.reconnecting))
        XCTAssertEqual(events[5], .connectionStateChanged(.connected))
    }

    func testReconnectSendsSyncStateForNegotiatedSubscriberAnswer() async throws {
        let frames = try [
            makeJoinResponse(),
            makeSubscriberOfferResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))
        let eventRecorder = RoomEventRecorder()
        room.delegate = eventRecorder

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let answerFrames = await waitForSentFrameCount(1, transport: transport)
        guard case let .binary(answerData) = try XCTUnwrap(answerFrames.first) else {
            return XCTFail("Expected binary subscriber answer request.")
        }
        let answerRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: answerData)
        guard case let .answer(answer)? = answerRequest.message else {
            return XCTFail("Expected SignalRequest.answer.")
        }

        try await transport.enqueueIncomingFrame(
            .binary(SignalFrameCodec().encode(makeLeaveResponse(action: .resume)))
        )
        try await transport.enqueueIncomingFrame(
            .binary(SignalFrameCodec().encode(makeReconnectResponse()))
        )

        let sentFrames = await waitForSentFrameCount(2, transport: transport)
        guard case let .binary(syncData) = sentFrames[1] else {
            return XCTFail("Expected binary SyncState request.")
        }
        let syncRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: syncData)
        guard case let .syncState(syncState)? = syncRequest.message else {
            return XCTFail("Expected SignalRequest.syncState.")
        }

        XCTAssertTrue(syncState.hasAnswer)
        XCTAssertEqual(syncState.answer.type, answer.type)
        XCTAssertEqual(syncState.answer.id, answer.id)
        XCTAssertNotEqual(syncState.answer.sdp, answer.sdp)
        XCTAssertNotEqual(
            try XCTUnwrap(iceUfrag(in: syncState.answer.sdp)),
            try XCTUnwrap(iceUfrag(in: answer.sdp))
        )

        let events = await eventRecorder.waitForEventCount(6)
        XCTAssertEqual(events[4], .connectionStateChanged(.reconnecting))
        XCTAssertEqual(events[5], .connectionStateChanged(.connected))
    }

    func testReconnectSendsSyncStateForPublishedMediaAndDataTracks() async throws {
        let frames = try [
            makeJoinResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))
        let eventRecorder = RoomEventRecorder()
        room.delegate = eventRecorder
        let track = LocalVideoTrack(id: "camera-cid", name: "camera", source: .camera)

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let publishTask = Task {
            try await room.localParticipant.publish(
                videoTrack: track,
                options: TrackPublishOptions(name: "main-camera", source: .camera)
            )
        }

        let addTrackFrames = await waitForSentFrameCount(1, transport: transport)
        guard case let .binary(addTrackData) = try XCTUnwrap(addTrackFrames.first) else {
            return XCTFail("Expected binary AddTrack request.")
        }
        let addTrackSignalRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: addTrackData)
        guard case let .addTrack(addTrack)? = addTrackSignalRequest.message else {
            return XCTFail("Expected SignalRequest.addTrack.")
        }

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

        let publisherOfferFrames = await waitForSentFrameCount(2, transport: transport)
        guard case let .binary(publisherOfferData) = publisherOfferFrames[1] else {
            return XCTFail("Expected binary publisher offer request.")
        }
        let publisherOfferRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: publisherOfferData)
        guard case let .offer(publisherOffer)? = publisherOfferRequest.message else {
            return XCTFail("Expected SignalRequest.offer.")
        }
        XCTAssertEqual(publisherOffer.id, 1)
        XCTAssertTrue(publisherOffer.sdp.contains("a=msid:livekit TR_local_camera"))

        let publication = try await publishTask.value
        XCTAssertEqual(publication.sid, "TR_local_camera")

        let dataTrackTask = Task {
            try await room.localParticipant.publishDataTrack(name: "telemetry", encryption: .gcm)
        }

        let publishDataFrames = await waitForSentFrameCount(3, transport: transport)
        guard case let .binary(publishData) = publishDataFrames[2] else {
            return XCTFail("Expected binary PublishDataTrack request.")
        }
        let publishDataRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: publishData)
        guard case let .publishDataTrackRequest(publishDataTrack)? = publishDataRequest.message else {
            return XCTFail("Expected SignalRequest.publishDataTrackRequest.")
        }

        try await transport.enqueueIncomingFrame(
            .binary(
                SignalFrameCodec().encode(
                    makePublishDataTrackResponse(
                        pubHandle: publishDataTrack.pubHandle,
                        sid: "DT_telemetry",
                        name: "telemetry",
                        encryption: .gcm
                    )
                )
            )
        )
        let dataTrack = try await dataTrackTask.value

        try await transport.enqueueIncomingFrame(
            .binary(SignalFrameCodec().encode(makeLeaveResponse(action: .resume)))
        )
        try await transport.enqueueIncomingFrame(
            .binary(SignalFrameCodec().encode(makeReconnectResponse()))
        )

        let sentFrames = await waitForSentFrameCount(4, transport: transport)
        guard case let .binary(syncData) = sentFrames[3] else {
            return XCTFail("Expected binary SyncState request.")
        }
        let syncRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: syncData)
        guard case let .syncState(syncState)? = syncRequest.message else {
            return XCTFail("Expected SignalRequest.syncState.")
        }

        XCTAssertEqual(syncState.publishTracks.count, 1)
        XCTAssertEqual(syncState.publishTracks[0].cid, "camera-cid")
        XCTAssertEqual(syncState.publishTracks[0].track.sid, "TR_local_camera")
        XCTAssertEqual(syncState.publishTracks[0].track.name, "main-camera")
        XCTAssertEqual(syncState.publishTracks[0].track.type, .video)
        XCTAssertEqual(syncState.publishTracks[0].track.source, .camera)
        XCTAssertTrue(syncState.hasOffer)
        XCTAssertEqual(syncState.offer.type, "offer")
        XCTAssertEqual(syncState.offer.id, 2)
        XCTAssertTrue(syncState.offer.sdp.contains("a=msid:livekit TR_local_camera"))
        XCTAssertNotEqual(
            try XCTUnwrap(iceUfrag(in: syncState.offer.sdp)),
            try XCTUnwrap(iceUfrag(in: publisherOffer.sdp))
        )
        XCTAssertEqual(syncState.publishDataTracks.count, 1)
        XCTAssertEqual(syncState.publishDataTracks[0].info.pubHandle, dataTrack.publisherHandle)
        XCTAssertEqual(syncState.publishDataTracks[0].info.sid, "DT_telemetry")
        XCTAssertEqual(syncState.publishDataTracks[0].info.name, "telemetry")
        XCTAssertEqual(syncState.publishDataTracks[0].info.encryption, .gcm)

        let events = await eventRecorder.waitForEventCount(7)
        XCTAssertEqual(events[5], .connectionStateChanged(.reconnecting))
        XCTAssertEqual(events[6], .connectionStateChanged(.connected))
    }

    func testResumeReconnectPreservesPublisherOfferTracksForSubsequentPublish() async throws {
        let frames = try [
            makeJoinResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))
        let videoTrack = LocalVideoTrack(id: "camera-cid", name: "camera", source: .camera)
        let audioTrack = LocalAudioTrack(id: "mic-cid", name: "microphone", source: .microphone)

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let videoPublishTask = Task {
            try await room.localParticipant.publish(
                videoTrack: videoTrack,
                options: TrackPublishOptions(name: "main-camera", source: .camera)
            )
        }

        let addVideoFrames = await waitForSentFrameCount(1, transport: transport)
        guard case let .binary(addVideoData) = try XCTUnwrap(addVideoFrames.first) else {
            return XCTFail("Expected binary video AddTrack request.")
        }
        let addVideoRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: addVideoData)
        guard case let .addTrack(addVideoTrack)? = addVideoRequest.message else {
            return XCTFail("Expected SignalRequest.addTrack.")
        }

        try await transport.enqueueIncomingFrame(
            .binary(
                SignalFrameCodec().encode(
                    makeTrackPublishedResponse(
                        cid: addVideoTrack.cid,
                        sid: "TR_local_camera",
                        name: "main-camera",
                        type: .video,
                        source: .camera
                    )
                )
            )
        )

        let videoOfferFrames = await waitForSentFrameCount(2, transport: transport)
        guard case let .binary(videoOfferData) = videoOfferFrames[1] else {
            return XCTFail("Expected binary publisher video offer request.")
        }
        let videoOfferRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: videoOfferData)
        guard case let .offer(videoOffer)? = videoOfferRequest.message else {
            return XCTFail("Expected SignalRequest.offer.")
        }
        XCTAssertEqual(videoOffer.id, 1)
        XCTAssertTrue(videoOffer.sdp.contains("a=msid:livekit TR_local_camera"))

        _ = try await videoPublishTask.value

        try await transport.enqueueIncomingFrame(
            .binary(SignalFrameCodec().encode(makeLeaveResponse(action: .resume)))
        )
        try await transport.enqueueIncomingFrame(
            .binary(SignalFrameCodec().encode(makeReconnectResponse()))
        )

        let syncFrames = await waitForSentFrameCount(3, transport: transport)
        guard case let .binary(syncData) = syncFrames[2] else {
            return XCTFail("Expected binary SyncState request.")
        }
        let syncRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: syncData)
        guard case let .syncState(syncState)? = syncRequest.message else {
            return XCTFail("Expected SignalRequest.syncState.")
        }
        XCTAssertTrue(syncState.hasOffer)
        XCTAssertEqual(syncState.offer.id, 2)
        XCTAssertTrue(syncState.offer.sdp.contains("a=msid:livekit TR_local_camera"))
        XCTAssertNotEqual(
            try XCTUnwrap(iceUfrag(in: syncState.offer.sdp)),
            try XCTUnwrap(iceUfrag(in: videoOffer.sdp))
        )

        let audioPublishTask = Task {
            try await room.localParticipant.publish(
                audioTrack: audioTrack,
                options: TrackPublishOptions(name: "main-mic", source: .microphone)
            )
        }

        let addAudioFrames = await waitForSentFrameCount(4, transport: transport)
        guard case let .binary(addAudioData) = addAudioFrames[3] else {
            return XCTFail("Expected binary audio AddTrack request.")
        }
        let addAudioRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: addAudioData)
        guard case let .addTrack(addAudioTrack)? = addAudioRequest.message else {
            return XCTFail("Expected SignalRequest.addTrack.")
        }

        try await transport.enqueueIncomingFrame(
            .binary(
                SignalFrameCodec().encode(
                    makeTrackPublishedResponse(
                        cid: addAudioTrack.cid,
                        sid: "TR_local_microphone",
                        name: "main-mic",
                        type: .audio,
                        source: .microphone
                    )
                )
            )
        )

        let audioOfferFrames = await waitForSentFrameCount(5, transport: transport)
        guard case let .binary(audioOfferData) = audioOfferFrames[4] else {
            return XCTFail("Expected binary publisher audio offer request.")
        }
        let audioOfferRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: audioOfferData)
        guard case let .offer(audioOffer)? = audioOfferRequest.message else {
            return XCTFail("Expected SignalRequest.offer.")
        }

        XCTAssertEqual(audioOffer.id, 3)
        XCTAssertTrue(audioOffer.sdp.contains("m=video 9 UDP/TLS/RTP/SAVPF 102"))
        XCTAssertTrue(audioOffer.sdp.contains("m=audio 9 UDP/TLS/RTP/SAVPF 111"))
        XCTAssertTrue(audioOffer.sdp.contains("a=msid:livekit TR_local_camera"))
        XCTAssertTrue(audioOffer.sdp.contains("a=msid:livekit TR_local_microphone"))

        _ = try await audioPublishTask.value
        XCTAssertEqual(room.localParticipant.trackPublications.map(\.sid), ["TR_local_camera", "TR_local_microphone"])
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

    func testSignalLoopSendsSubscriberLocalICETrickleWhenMediaStartupConfigured() async throws {
        let frames = try [
            makeJoinResponse(),
            makeSubscriberOfferResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let localCandidate = ICECandidate(
            foundation: "subscriber-local",
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(type: .host, localPreference: 65_535).value,
            address: "192.0.2.11",
            port: 55001,
            type: .host
        )
        let subscriberPeerConnection = PeerConnectionCoordinator(
            configuration: NativeWebRTCConfiguration(role: .subscriber)
        )
        let room = Room(
            signalConnection: SignalConnection(transport: transport),
            subscriberPeerConnection: subscriberPeerConnection,
            subscriberMediaStartupConfiguration: RoomSubscriberMediaStartupConfiguration(
                localCandidates: { [localCandidate] },
                binder: DTLSSRTPMediaSessionBinder(
                    datagramTransportFactory: RoomMediaStartupDatagramTransportFactory(
                        transport: RoomMediaStartupDatagramTransport()
                    ),
                    handshaker: RoomMediaStartupDTLSHandshaker(
                        result: try DTLSSRTPHandshakeResult(
                            role: .client,
                            exportedKeyingMaterial: Data(
                                (0..<SRTPProtectionProfile.aes128CMHMACSHA180.exporterByteCount).map(UInt8.init)
                            ),
                            remoteFingerprint: DTLSSignature(hashFunction: "sha-256", value: "DD:EE:FF")
                        )
                    )
                )
            )
        )

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let sentFrames = await waitForSentFrameCount(3, transport: transport)
        XCTAssertEqual(sentFrames.count, 3)

        guard case let .binary(candidateData) = sentFrames[1] else {
            return XCTFail("Expected binary subscriber trickle request.")
        }
        let candidateRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: candidateData)
        guard case let .trickle(candidateTrickle)? = candidateRequest.message else {
            return XCTFail("Expected SignalRequest.trickle.")
        }
        let candidateInit = try RTCIceCandidateInit(jsonString: candidateTrickle.candidateInit)
        XCTAssertEqual(candidateTrickle.target, .subscriber)
        XCTAssertFalse(candidateTrickle.final)
        XCTAssertEqual(candidateInit.candidate, localCandidate.sdpAttributeValue)
        XCTAssertEqual(candidateInit.sdpMid, "0")
        XCTAssertEqual(candidateInit.sdpMLineIndex, 0)
        XCTAssertEqual(
            candidateInit.usernameFragment,
            subscriberPeerConnection.configuration.iceCredentials.usernameFragment
        )

        guard case let .binary(finalData) = sentFrames[2] else {
            return XCTFail("Expected binary final subscriber trickle request.")
        }
        let finalRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: finalData)
        guard case let .trickle(finalTrickle)? = finalRequest.message else {
            return XCTFail("Expected final SignalRequest.trickle.")
        }
        XCTAssertEqual(finalTrickle.target, .subscriber)
        XCTAssertTrue(finalTrickle.final)
        XCTAssertTrue(finalTrickle.candidateInit.isEmpty)
    }

    func testSignalLoopPassesJoinICEServersToSubscriberLocalCandidateGathering() async throws {
        let frames = try [
            makeJoinResponse(iceServers: [
                makeICEServer(
                    urls: ["stun:stun.example.test:3478"],
                    username: "ignored-for-stun",
                    credential: "ignored-for-stun"
                ),
            ]),
            makeSubscriberOfferResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let recorder = ICEServerRecorder()
        let localCandidate = ICECandidate(
            foundation: "subscriber-local",
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(type: .host, localPreference: 65_535).value,
            address: "192.0.2.11",
            port: 55001,
            type: .host
        )
        let room = Room(
            signalConnection: SignalConnection(transport: transport),
            subscriberMediaStartupConfiguration: RoomSubscriberMediaStartupConfiguration(
                localCandidatesProvider: { iceServers in
                    recorder.record(iceServers)
                    return [localCandidate]
                },
                binder: DTLSSRTPMediaSessionBinder(
                    datagramTransportFactory: RoomMediaStartupDatagramTransportFactory(
                        transport: RoomMediaStartupDatagramTransport()
                    ),
                    handshaker: RoomMediaStartupDTLSHandshaker(
                        result: try DTLSSRTPHandshakeResult(
                            role: .client,
                            exportedKeyingMaterial: Data(
                                (0..<SRTPProtectionProfile.aes128CMHMACSHA180.exporterByteCount).map(UInt8.init)
                            ),
                            remoteFingerprint: DTLSSignature(hashFunction: "sha-256", value: "DD:EE:FF")
                        )
                    )
                )
            )
        )

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")
        _ = await waitForSentFrameCount(3, transport: transport)

        XCTAssertEqual(recorder.iceServers, [
            ICEServer(
                urls: ["stun:stun.example.test:3478"],
                username: "ignored-for-stun",
                credential: "ignored-for-stun"
            ),
        ])
    }

    func testSignalLoopSendsSubscriberLocalICETrickleFromHostCandidateSocketConfiguration() async throws {
        let frames = try [
            makeJoinResponse(),
            makeSubscriberOfferResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let subscriberPeerConnection = PeerConnectionCoordinator(
            configuration: NativeWebRTCConfiguration(role: .subscriber)
        )
        let room = Room(
            signalConnection: SignalConnection(transport: transport),
            subscriberPeerConnection: subscriberPeerConnection,
            subscriberMediaStartupConfiguration: try RoomSubscriberMediaStartupConfiguration(
                hostCandidateAddresses: [
                    ICEInterfaceAddress(name: "lo0", address: "127.0.0.1", localPreference: 101),
                ],
                bindAddress: "127.0.0.1",
                receiveTimeoutMilliseconds: 250,
                handshaker: RoomMediaStartupDTLSHandshaker(
                    result: try DTLSSRTPHandshakeResult(
                        role: .client,
                        exportedKeyingMaterial: Data(
                            (0..<SRTPProtectionProfile.aes128CMHMACSHA180.exporterByteCount).map(UInt8.init)
                        ),
                        remoteFingerprint: DTLSSignature(hashFunction: "sha-256", value: "DD:EE:FF")
                    )
                )
            )
        )

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let sentFrames = await waitForSentFrameCount(3, transport: transport)
        XCTAssertEqual(sentFrames.count, 3)

        guard case let .binary(candidateData) = sentFrames[1] else {
            return XCTFail("Expected binary subscriber trickle request.")
        }
        let candidateRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: candidateData)
        guard case let .trickle(candidateTrickle)? = candidateRequest.message else {
            return XCTFail("Expected SignalRequest.trickle.")
        }
        let candidateInit = try RTCIceCandidateInit(jsonString: candidateTrickle.candidateInit)
        let localCandidate = try ICECandidate(sdpAttributeValue: candidateInit.candidate)

        XCTAssertEqual(candidateTrickle.target, .subscriber)
        XCTAssertFalse(candidateTrickle.final)
        XCTAssertEqual(localCandidate.foundation, "1")
        XCTAssertEqual(localCandidate.address, "127.0.0.1")
        XCTAssertGreaterThan(localCandidate.port, 0)
        XCTAssertEqual(localCandidate.priority, ICECandidatePriority(
            type: .host,
            localPreference: 101
        ).value)
        XCTAssertEqual(candidateInit.usernameFragment, subscriberPeerConnection.configuration.iceCredentials.usernameFragment)
    }

    func testDefaultLiveMediaStartupConfigurationSendsSocketBackedSubscriberLocalICETrickle() async throws {
        let frames = try [
            makeJoinResponse(),
            makeSubscriberOfferResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let subscriberPeerConnection = PeerConnectionCoordinator(
            configuration: NativeWebRTCConfiguration(role: .subscriber)
        )
        let room = Room(
            signalConnection: SignalConnection(transport: transport),
            subscriberPeerConnection: subscriberPeerConnection,
            subscriberMediaStartupConfiguration: .defaultLive(
                hostCandidateAddresses: {
                    [ICEInterfaceAddress(name: "lo0", address: "127.0.0.1", localPreference: 101)]
                },
                bindAddress: "127.0.0.1",
                receiveTimeoutMilliseconds: 250
            )
        )

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let sentFrames = await waitForSentFrameCount(3, transport: transport)
        XCTAssertEqual(sentFrames.count, 3)

        guard case let .binary(candidateData) = sentFrames[1] else {
            return XCTFail("Expected binary subscriber trickle request.")
        }
        let candidateRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: candidateData)
        guard case let .trickle(candidateTrickle)? = candidateRequest.message else {
            return XCTFail("Expected SignalRequest.trickle.")
        }
        let candidateInit = try RTCIceCandidateInit(jsonString: candidateTrickle.candidateInit)
        let localCandidate = try ICECandidate(sdpAttributeValue: candidateInit.candidate)

        XCTAssertEqual(candidateTrickle.target, .subscriber)
        XCTAssertFalse(candidateTrickle.final)
        XCTAssertEqual(localCandidate.foundation, "1")
        XCTAssertEqual(localCandidate.address, "127.0.0.1")
        XCTAssertGreaterThan(localCandidate.port, 0)
        XCTAssertEqual(localCandidate.priority, ICECandidatePriority(
            type: .host,
            localPreference: 101
        ).value)
        XCTAssertEqual(candidateInit.usernameFragment, subscriberPeerConnection.configuration.iceCredentials.usernameFragment)
    }

    func testDefaultLiveMediaDataStartupConfigurationInstallsSharedBinder() {
        let dataChannelMode = DTLSSCTPDataChannelTransportMode.association(
            SCTPAssociationConfiguration(
                localInitiateTag: 0x0102_0304,
                initialTSN: 7,
                maxDataChunkPayloadSize: 1_200
            )
        )
        let configuration = RoomPublisherMediaStartupConfiguration.defaultLiveMediaData(
            hostCandidateAddresses: { [] },
            identity: DTLSSRTPIdentity.generated(),
            dataChannelTransportMode: dataChannelMode,
            consentFreshnessPolicy: .disabled
        )

        XCTAssertNotNil(configuration.mediaDataBinder)
        XCTAssertEqual(configuration.mediaDataBinder?.dataChannelTransportMode, dataChannelMode)
    }

    func testSubscriberMediaStartupWaitsForRTPMediaWhenInitialOfferIsDataOnly() async throws {
        let frames = try [
            makeJoinResponse(),
            makeSubscriberDataOnlyOfferResponse(),
            makeSubscriberTrickleResponse(),
            makeSubscriberTrickleCompleteResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let localCandidate = ICECandidate(
            foundation: "subscriber-local",
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(type: .host, localPreference: 65_535).value,
            address: "192.0.2.11",
            port: 55001,
            type: .host
        )
        let checker = RoomMediaStartupICEChecker()
        let inboundSTUNRecorder = SubscriberInboundSTUNResponderRecorder()
        let subscriberPeerConnection = PeerConnectionCoordinator(
            configuration: NativeWebRTCConfiguration(role: .subscriber)
        )
        let room = Room(
            signalConnection: SignalConnection(transport: transport),
            subscriberPeerConnection: subscriberPeerConnection,
            subscriberMediaStartupConfiguration: RoomSubscriberMediaStartupConfiguration(
                localCandidates: { [localCandidate] },
                tieBreaker: 43,
                checker: checker,
                binder: DTLSSRTPMediaSessionBinder(
                    datagramTransportFactory: RoomMediaStartupDatagramTransportFactory(
                        transport: RoomMediaStartupDatagramTransport()
                    ),
                    handshaker: RoomMediaStartupDTLSHandshaker(
                        result: try DTLSSRTPHandshakeResult(
                            role: .client,
                            exportedKeyingMaterial: roomMediaStartupExportedKeyingMaterial(),
                            remoteFingerprint: DTLSSignature(hashFunction: "sha-256", value: "DD:EE:FF")
                        )
                    )
                ),
                mediaDataBinder: DTLSSRTPMediaDataSessionBinder(
                    datagramTransportFactory: RoomMediaStartupDatagramTransportFactory(
                        transport: RoomMediaStartupDatagramTransport()
                    ),
                    receiveAttemptLimit: 1
                ),
                inboundSTUNResponder: { credentials in
                    inboundSTUNRecorder.record(credentials)
                    return Task {}
                },
                consentFreshnessPolicy: .disabled
            )
        )

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")
        _ = await waitForSentFrameCount(3, transport: transport)
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(checker.capturedConfiguration)
        XCTAssertNil(room.lastSubscriberMediaStartupResult)
        XCTAssertNil(room.lastSubscriberMediaStartupError)
        XCTAssertEqual(
            inboundSTUNRecorder.credentials?.usernameFragment,
            subscriberPeerConnection.configuration.iceCredentials.usernameFragment
        )
    }

    func testDefaultLiveSubscriberMediaStartupFailsAtUnavailableDTLSSRTPBoundaryAfterSelectedICEPair() async throws {
        let stunResponder = try RoomSTUNResponderSocket()
        stunResponder.start()
        let frames = try [
            makeJoinResponse(),
            makeSubscriberOfferResponse(),
            makeSubscriberTrickleResponse(address: "127.0.0.1", port: stunResponder.port),
            makeSubscriberTrickleCompleteResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let subscriberPeerConnection = PeerConnectionCoordinator(
            configuration: NativeWebRTCConfiguration(role: .subscriber)
        )
        let room = Room(
            signalConnection: SignalConnection(transport: transport),
            subscriberPeerConnection: subscriberPeerConnection,
            subscriberMediaStartupConfiguration: .defaultLive(
                hostCandidateAddresses: {
                    [ICEInterfaceAddress(name: "lo0", address: "127.0.0.1", localPreference: 101)]
                },
                bindAddress: "127.0.0.1",
                receiveTimeoutMilliseconds: 250,
                handshaker: UnavailableAppleDTLSSRTPHandshaker(),
                consentFreshnessPolicy: .disabled
            )
        )

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let error = await waitForSubscriberMediaStartupError(room)
        XCTAssertEqual(error as? DTLSSRTPError, .webRTCUseSRTPNegotiationUnavailable)
        XCTAssertNil(room.lastSubscriberMediaStartupResult)
        XCTAssertNotNil(stunResponder.waitForSourcePort())
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

    func testSignalLoopStartsSubscriberMediaTransportAfterOfferAndFinalTrickle() async throws {
        let frames = try [
            makeJoinResponse(),
            makeSubscriberOfferResponse(),
            makeSubscriberTrickleResponse(),
            makeSubscriberTrickleCompleteResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let localCandidate = ICECandidate(
            foundation: "subscriber-local",
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(type: .host, localPreference: 65_535).value,
            address: "192.0.2.11",
            port: 55001,
            type: .host
        )
        let checker = RoomMediaStartupICEChecker()
        let datagramTransport = RoomMediaStartupDatagramTransport()
        let datagramFactory = RoomMediaStartupDatagramTransportFactory(transport: datagramTransport)
        let handshaker = RoomMediaStartupDTLSHandshaker(
            result: try DTLSSRTPHandshakeResult(
                role: .client,
                exportedKeyingMaterial: Data(
                    (0..<SRTPProtectionProfile.aes128CMHMACSHA180.exporterByteCount).map(UInt8.init)
                ),
                remoteFingerprint: DTLSSignature(hashFunction: "sha-256", value: "DD:EE:FF")
            )
        )
        let binder = DTLSSRTPMediaSessionBinder(
            datagramTransportFactory: datagramFactory,
            handshaker: handshaker
        )
        let subscriberPeerConnection = PeerConnectionCoordinator(
            configuration: NativeWebRTCConfiguration(role: .subscriber)
        )
        let room = Room(
            signalConnection: SignalConnection(transport: transport),
            subscriberPeerConnection: subscriberPeerConnection,
            subscriberMediaStartupConfiguration: RoomSubscriberMediaStartupConfiguration(
                localCandidates: { [localCandidate] },
                tieBreaker: 43,
                checker: checker,
                binder: binder
            )
        )

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let startupResult = await waitForSubscriberMediaStartupResult(room)
        let startup = try XCTUnwrap(startupResult)
        XCTAssertNil(room.lastSubscriberMediaStartupError)
        XCTAssertEqual(startup.iceSummary.state, .connected)
        XCTAssertEqual(startup.iceSummary.checkedPairCount, 1)
        XCTAssertEqual(startup.selectedCandidatePair.local.foundation, "subscriber-local")
        XCTAssertEqual(startup.selectedCandidatePair.remote.foundation, "1")
        XCTAssertEqual(checker.capturedConfiguration?.remoteCredentials.usernameFragment, "subscriber-remote-ufrag")
        XCTAssertEqual(handshaker.capturedConfiguration?.remoteFingerprint, DTLSSignature(
            hashFunction: "sha-256",
            value: "DD:EE:FF"
        ))
        XCTAssertEqual(datagramFactory.capturedPair?.remote.foundation, "1")
    }

    func testSignalLoopStartsPublisherMediaTransportAfterAnswerAndFinalTrickle() async throws {
        let frames = try [
            makeJoinResponse(),
            makePublisherAnswerResponse(),
            makePublisherTrickleResponse(),
            makePublisherTrickleCompleteResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let localCandidate = ICECandidate(
            foundation: "local",
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(type: .host, localPreference: 65_535).value,
            address: "192.0.2.10",
            port: 55000,
            type: .host
        )
        let checker = RoomMediaStartupICEChecker()
        let datagramTransport = RoomMediaStartupDatagramTransport()
        let datagramFactory = RoomMediaStartupDatagramTransportFactory(transport: datagramTransport)
        let handshaker = RoomMediaStartupDTLSHandshaker(
            result: try DTLSSRTPHandshakeResult(
                role: .server,
                exportedKeyingMaterial: Data(
                    (0..<SRTPProtectionProfile.aes128CMHMACSHA180.exporterByteCount).map(UInt8.init)
                ),
                remoteFingerprint: DTLSSignature(hashFunction: "sha-256", value: "AA:BB:CC")
            )
        )
        let binder = DTLSSRTPMediaSessionBinder(
            datagramTransportFactory: datagramFactory,
            handshaker: handshaker
        )
        let publisherPeerConnection = PeerConnectionCoordinator(
            configuration: NativeWebRTCConfiguration(role: .publisher)
        )
        let room = Room(
            signalConnection: SignalConnection(transport: transport),
            publisherPeerConnection: publisherPeerConnection,
            publisherMediaStartupConfiguration: RoomPublisherMediaStartupConfiguration(
                localCandidates: { [localCandidate] },
                tieBreaker: 42,
                checker: checker,
                binder: binder
            )
        )

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let startupResult = await waitForPublisherMediaStartupResult(room)
        let startup = try XCTUnwrap(startupResult)
        XCTAssertNil(room.lastPublisherMediaStartupError)
        XCTAssertEqual(startup.iceSummary.state, .connected)
        XCTAssertEqual(startup.iceSummary.checkedPairCount, 1)
        XCTAssertEqual(startup.selectedCandidatePair.local.foundation, "local")
        XCTAssertEqual(startup.selectedCandidatePair.remote.foundation, "2")
        XCTAssertEqual(checker.capturedConfiguration?.remoteCredentials.usernameFragment, "publisher-remote-ufrag")
        XCTAssertEqual(handshaker.capturedConfiguration?.remoteFingerprint, DTLSSignature(
            hashFunction: "sha-256",
            value: "AA:BB:CC"
        ))
        XCTAssertEqual(datagramFactory.capturedPair?.remote.foundation, "2")
    }

    func testDefaultLivePublisherMediaStartupFailsAtUnavailableDTLSSRTPBoundaryAfterSelectedICEPair() async throws {
        let stunResponder = try RoomSTUNResponderSocket()
        stunResponder.start()
        let frames = try [
            makeJoinResponse(),
            makePublisherAnswerResponse(),
            makePublisherTrickleResponse(address: "127.0.0.1", port: stunResponder.port),
            makePublisherTrickleCompleteResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let publisherPeerConnection = PeerConnectionCoordinator(
            configuration: NativeWebRTCConfiguration(role: .publisher)
        )
        let room = Room(
            signalConnection: SignalConnection(transport: transport),
            publisherPeerConnection: publisherPeerConnection,
            publisherMediaStartupConfiguration: .defaultLive(
                hostCandidateAddresses: {
                    [ICEInterfaceAddress(name: "lo0", address: "127.0.0.1", localPreference: 101)]
                },
                bindAddress: "127.0.0.1",
                receiveTimeoutMilliseconds: 250,
                handshaker: UnavailableAppleDTLSSRTPHandshaker(),
                consentFreshnessPolicy: .disabled
            )
        )

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let error = await waitForPublisherMediaStartupError(room)
        XCTAssertEqual(error as? DTLSSRTPError, .webRTCUseSRTPNegotiationUnavailable)
        XCTAssertNil(room.lastPublisherMediaStartupResult)
        XCTAssertNotNil(stunResponder.waitForSourcePort())
    }

    func testSubscriberMediaTransportRunsICEConsentFreshnessAfterStartup() async throws {
        let frames = try [
            makeJoinResponse(),
            makeSubscriberOfferResponse(),
            makeSubscriberTrickleResponse(),
            makeSubscriberTrickleCompleteResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let localCandidate = ICECandidate(
            foundation: "subscriber-local",
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(type: .host, localPreference: 65_535).value,
            address: "192.0.2.11",
            port: 55001,
            type: .host
        )
        let checker = RoomMediaStartupCountingICEChecker(consentChecksSucceed: true)
        let handshaker = RoomMediaStartupDTLSHandshaker(
            result: try DTLSSRTPHandshakeResult(
                role: .client,
                exportedKeyingMaterial: roomMediaStartupExportedKeyingMaterial(),
                remoteFingerprint: DTLSSignature(hashFunction: "sha-256", value: "DD:EE:FF")
            )
        )
        let room = Room(
            signalConnection: SignalConnection(transport: transport),
            subscriberMediaStartupConfiguration: RoomSubscriberMediaStartupConfiguration(
                localCandidates: { [localCandidate] },
                tieBreaker: 43,
                checker: checker,
                binder: DTLSSRTPMediaSessionBinder(
                    datagramTransportFactory: RoomMediaStartupDatagramTransportFactory(
                        transport: RoomMediaStartupDatagramTransport()
                    ),
                    handshaker: handshaker
                ),
                consentFreshnessPolicy: ICEConsentFreshnessPolicy(
                    intervalSeconds: 0.010,
                    timeoutSeconds: 0.250,
                    maxConsecutiveFailures: 2
                )
            )
        )

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")
        let startupResult = await waitForSubscriberMediaStartupResult(room)
        _ = try XCTUnwrap(startupResult)

        let consentCheckCount = await checker.waitForConsentCheckCount(1)
        XCTAssertGreaterThanOrEqual(consentCheckCount, 1)
        XCTAssertNil(room.lastSubscriberMediaStartupError)
    }

    func testSubscriberMediaTransportClosesWhenICEConsentFreshnessExpires() async throws {
        let frames = try [
            makeJoinResponse(),
            makeSubscriberOfferResponse(),
            makeSubscriberTrickleResponse(),
            makeSubscriberTrickleCompleteResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let datagramTransport = RoomMediaStartupDatagramTransport()
        let localCandidate = ICECandidate(
            foundation: "subscriber-local",
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(type: .host, localPreference: 65_535).value,
            address: "192.0.2.11",
            port: 55001,
            type: .host
        )
        let checker = RoomMediaStartupCountingICEChecker(consentChecksSucceed: false)
        let handshaker = RoomMediaStartupDTLSHandshaker(
            result: try DTLSSRTPHandshakeResult(
                role: .client,
                exportedKeyingMaterial: roomMediaStartupExportedKeyingMaterial(),
                remoteFingerprint: DTLSSignature(hashFunction: "sha-256", value: "DD:EE:FF")
            )
        )
        let room = Room(
            signalConnection: SignalConnection(transport: transport),
            subscriberMediaStartupConfiguration: RoomSubscriberMediaStartupConfiguration(
                localCandidates: { [localCandidate] },
                tieBreaker: 43,
                checker: checker,
                binder: DTLSSRTPMediaSessionBinder(
                    datagramTransportFactory: RoomMediaStartupDatagramTransportFactory(
                        transport: datagramTransport
                    ),
                    handshaker: handshaker
                ),
                consentFreshnessPolicy: ICEConsentFreshnessPolicy(
                    intervalSeconds: 0.010,
                    timeoutSeconds: 0.250,
                    maxConsecutiveFailures: 2
                )
            )
        )

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")
        let startupResult = await waitForSubscriberMediaStartupResult(room)
        _ = try XCTUnwrap(startupResult)

        let error = await waitForSubscriberMediaStartupError(room)
        XCTAssertNotNil(error as? ICEConsentFreshnessError)

        do {
            try await room.sendSubscriberRTCP(.receiverReport(RTCPReceiverReport(senderSSRC: 42)))
            XCTFail("Expected subscriber RTCP send to fail after consent expiration.")
        } catch {
            XCTAssertEqual(error as? SecureMediaTransportError, .transportClosed)
        }
    }

    func testPublisherRTPBridgeSendsThroughStartedSecureMediaTransport() async throws {
        let frames = try [
            makeJoinResponse(),
            makePublisherAnswerResponse(),
            makePublisherTrickleResponse(),
            makePublisherTrickleCompleteResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let localCandidate = ICECandidate(
            foundation: "local",
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(type: .host, localPreference: 65_535).value,
            address: "192.0.2.10",
            port: 55000,
            type: .host
        )
        let datagramTransport = RoomMediaStartupDatagramTransport()
        let binder = DTLSSRTPMediaSessionBinder(
            datagramTransportFactory: RoomMediaStartupDatagramTransportFactory(transport: datagramTransport),
            handshaker: RoomMediaStartupDTLSHandshaker(
                result: try DTLSSRTPHandshakeResult(
                    role: .server,
                    exportedKeyingMaterial: Data(
                        (0..<SRTPProtectionProfile.aes128CMHMACSHA180.exporterByteCount).map(UInt8.init)
                    ),
                    remoteFingerprint: DTLSSignature(hashFunction: "sha-256", value: "AA:BB:CC")
                )
            )
        )
        let room = Room(
            signalConnection: SignalConnection(transport: transport),
            publisherPeerConnection: PeerConnectionCoordinator(configuration: NativeWebRTCConfiguration(role: .publisher)),
            publisherMediaStartupConfiguration: RoomPublisherMediaStartupConfiguration(
                localCandidates: { [localCandidate] },
                tieBreaker: 42,
                checker: RoomMediaStartupICEChecker(),
                binder: binder
            )
        )

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")
        let startupResult = await waitForPublisherMediaStartupResult(room)
        _ = try XCTUnwrap(startupResult)
        let packet = RTPPacket(
            marker: true,
            payloadType: 102,
            sequenceNumber: 12,
            timestamp: 90_000,
            ssrc: 0x1122_3344,
            payload: Data([0x01, 0x02, 0x03])
        )

        try await room.sendPublisherRTP(packet)

        let sentDatagram = try XCTUnwrap(datagramTransport.sentDatagrams.first)
        XCTAssertEqual(datagramTransport.sentDatagrams.count, 1)
        XCTAssertNotEqual(sentDatagram, packet.encoded())
        XCTAssertGreaterThan(sentDatagram.count, packet.encoded().count)
    }

    func testPublisherRTCPSendsThroughStartedSecureMediaTransport() async throws {
        let frames = try [
            makeJoinResponse(),
            makePublisherAnswerResponse(),
            makePublisherTrickleResponse(),
            makePublisherTrickleCompleteResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let localCandidate = ICECandidate(
            foundation: "local",
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(type: .host, localPreference: 65_535).value,
            address: "192.0.2.10",
            port: 55000,
            type: .host
        )
        let datagramTransport = RoomMediaStartupDatagramTransport()
        let binder = DTLSSRTPMediaSessionBinder(
            datagramTransportFactory: RoomMediaStartupDatagramTransportFactory(transport: datagramTransport),
            handshaker: RoomMediaStartupDTLSHandshaker(
                result: try DTLSSRTPHandshakeResult(
                    role: .server,
                    exportedKeyingMaterial: Data(
                        (0..<SRTPProtectionProfile.aes128CMHMACSHA180.exporterByteCount).map(UInt8.init)
                    ),
                    remoteFingerprint: DTLSSignature(hashFunction: "sha-256", value: "AA:BB:CC")
                )
            )
        )
        let room = Room(
            signalConnection: SignalConnection(transport: transport),
            publisherPeerConnection: PeerConnectionCoordinator(configuration: NativeWebRTCConfiguration(role: .publisher)),
            publisherMediaStartupConfiguration: RoomPublisherMediaStartupConfiguration(
                localCandidates: { [localCandidate] },
                tieBreaker: 42,
                checker: RoomMediaStartupICEChecker(),
                binder: binder
            )
        )

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")
        let startupResult = await waitForPublisherMediaStartupResult(room)
        _ = try XCTUnwrap(startupResult)
        let packet = RTCPPacket.pictureLossIndication(
            RTCPPictureLossIndication(senderSSRC: 0x0102_0304, mediaSSRC: 0x0506_0708)
        )

        try await room.sendPublisherRTCP(packet)

        let sentDatagram = try XCTUnwrap(datagramTransport.sentDatagrams.first)
        XCTAssertEqual(datagramTransport.sentDatagrams.count, 1)
        XCTAssertNotEqual(sentDatagram, try packet.encoded())
        XCTAssertGreaterThan(sentDatagram.count, try packet.encoded().count)
    }

    func testPublisherRTCPReceiveHandlerReceivesDecodedPacket() async throws {
        let frames = try [
            makeJoinResponse(),
            makePublisherAnswerResponse(),
            makePublisherTrickleResponse(),
            makePublisherTrickleCompleteResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let localCandidate = ICECandidate(
            foundation: "local",
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(type: .host, localPreference: 65_535).value,
            address: "192.0.2.10",
            port: 55000,
            type: .host
        )
        let datagramTransport = RoomMediaStartupDatagramTransport()
        let binder = DTLSSRTPMediaSessionBinder(
            datagramTransportFactory: RoomMediaStartupDatagramTransportFactory(transport: datagramTransport),
            handshaker: RoomMediaStartupDTLSHandshaker(
                result: try DTLSSRTPHandshakeResult(
                    role: .server,
                    exportedKeyingMaterial: roomMediaStartupExportedKeyingMaterial(),
                    remoteFingerprint: DTLSSignature(hashFunction: "sha-256", value: "AA:BB:CC")
                )
            )
        )
        let room = Room(
            signalConnection: SignalConnection(transport: transport),
            publisherPeerConnection: PeerConnectionCoordinator(configuration: NativeWebRTCConfiguration(role: .publisher)),
            publisherMediaStartupConfiguration: RoomPublisherMediaStartupConfiguration(
                localCandidates: { [localCandidate] },
                tieBreaker: 42,
                checker: RoomMediaStartupICEChecker(),
                binder: binder
            )
        )
        let recorder = PublisherRTCPRecorder()
        room.setPublisherRTCPHandler { packet in
            await recorder.record(packet)
        }

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")
        let startupResult = await waitForPublisherMediaStartupResult(room)
        _ = try XCTUnwrap(startupResult)
        XCTAssertTrue(room.isPublisherRTCPReceiveLoopActive)

        let packet = RTCPPacket.pictureLossIndication(
            RTCPPictureLossIndication(senderSSRC: 0x0102_0304, mediaSSRC: 0x0506_0708)
        )
        let protectedDatagram = try await protectedPublisherInboundRTCPDatagram(packet)

        datagramTransport.enqueueIncomingDatagram(protectedDatagram)

        let receivedPackets = await recorder.waitForPacketCount(1)
        XCTAssertEqual(receivedPackets, [packet])
    }

    func testPublisherRTCPReceiverReportsUpdateBandwidthEstimateWithoutExternalHandler() async throws {
        let frames = try [
            makeJoinResponse(),
            makePublisherAnswerResponse(),
            makePublisherTrickleResponse(),
            makePublisherTrickleCompleteResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let localCandidate = ICECandidate(
            foundation: "local",
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(type: .host, localPreference: 65_535).value,
            address: "192.0.2.10",
            port: 55000,
            type: .host
        )
        let datagramTransport = RoomMediaStartupDatagramTransport()
        let binder = DTLSSRTPMediaSessionBinder(
            datagramTransportFactory: RoomMediaStartupDatagramTransportFactory(transport: datagramTransport),
            handshaker: RoomMediaStartupDTLSHandshaker(
                result: try DTLSSRTPHandshakeResult(
                    role: .server,
                    exportedKeyingMaterial: roomMediaStartupExportedKeyingMaterial(),
                    remoteFingerprint: DTLSSignature(hashFunction: "sha-256", value: "AA:BB:CC")
                )
            )
        )
        let room = Room(
            signalConnection: SignalConnection(transport: transport),
            publisherPeerConnection: PeerConnectionCoordinator(configuration: NativeWebRTCConfiguration(role: .publisher)),
            publisherMediaStartupConfiguration: RoomPublisherMediaStartupConfiguration(
                localCandidates: { [localCandidate] },
                tieBreaker: 42,
                checker: RoomMediaStartupICEChecker(),
                binder: binder
            )
        )

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")
        let startupResult = await waitForPublisherMediaStartupResult(room)
        _ = try XCTUnwrap(startupResult)
        XCTAssertTrue(room.isPublisherRTCPReceiveLoopActive)

        let report = RTCPPacket.receiverReport(RTCPReceiverReport(
            senderSSRC: 0x0102_0304,
            reports: [
                RTCPReceptionReport(
                    ssrc: 0x1122_3344,
                    fractionLost: 64,
                    cumulativePacketsLost: 0,
                    highestSequenceNumber: 100,
                    jitter: 0,
                    lastSenderReport: 0,
                    delaySinceLastSenderReport: 0
                ),
            ]
        ))
        let protectedDatagram = try await protectedPublisherInboundRTCPDatagram(report)

        datagramTransport.enqueueIncomingDatagram(protectedDatagram)

        let maybeSnapshot = await waitForPublisherBandwidthEstimate(room, ssrc: 0x1122_3344)
        let snapshot = try XCTUnwrap(maybeSnapshot)
        XCTAssertEqual(snapshot.estimate.lossFraction, 0.25, accuracy: 0.001)
        XCTAssertEqual(snapshot.estimate.estimatedBitrateBps, 975_000)
        XCTAssertEqual(snapshot.estimate.recommendation.level, .medium)
    }

    func testSubscriberRTCPSendsThroughStartedSecureMediaTransport() async throws {
        let frames = try [
            makeJoinResponse(),
            makeSubscriberOfferResponse(),
            makeSubscriberTrickleResponse(),
            makeSubscriberTrickleCompleteResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let localCandidate = ICECandidate(
            foundation: "subscriber-local",
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(type: .host, localPreference: 65_535).value,
            address: "192.0.2.11",
            port: 55001,
            type: .host
        )
        let datagramTransport = RoomMediaStartupDatagramTransport()
        let binder = DTLSSRTPMediaSessionBinder(
            datagramTransportFactory: RoomMediaStartupDatagramTransportFactory(transport: datagramTransport),
            handshaker: RoomMediaStartupDTLSHandshaker(
                result: try DTLSSRTPHandshakeResult(
                    role: .client,
                    exportedKeyingMaterial: roomMediaStartupExportedKeyingMaterial(),
                    remoteFingerprint: DTLSSignature(hashFunction: "sha-256", value: "DD:EE:FF")
                )
            )
        )
        let room = Room(
            signalConnection: SignalConnection(transport: transport),
            subscriberPeerConnection: PeerConnectionCoordinator(configuration: NativeWebRTCConfiguration(role: .subscriber)),
            subscriberMediaStartupConfiguration: RoomSubscriberMediaStartupConfiguration(
                localCandidates: { [localCandidate] },
                tieBreaker: 43,
                checker: RoomMediaStartupICEChecker(),
                binder: binder
            )
        )

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")
        let startupResult = await waitForSubscriberMediaStartupResult(room)
        _ = try XCTUnwrap(startupResult)
        let packet = RTCPPacket.pictureLossIndication(
            RTCPPictureLossIndication(senderSSRC: 0x0102_0304, mediaSSRC: 0x0506_0708)
        )

        try await room.sendSubscriberRTCP(packet)

        let sentDatagram = try XCTUnwrap(datagramTransport.sentDatagrams.first)
        XCTAssertEqual(datagramTransport.sentDatagrams.count, 1)
        XCTAssertNotEqual(sentDatagram, try packet.encoded())
        XCTAssertGreaterThan(sentDatagram.count, try packet.encoded().count)
    }

    func testSubscriberRTCPFeedbackSequenceGapSendsTransportLayerNACKThroughStartedSecureMediaTransport() async throws {
        let (room, datagramTransport) = try await makeStartedSubscriberRTCPFeedbackRoom()

        let plannedPackets = try await room.sendSubscriberRTCPFeedback(
            senderSSRC: 0x0102_0304,
            mediaSSRC: 0x0506_0708,
            signals: [.h264RTPError(.sequenceNumberGap(expected: 100, actual: 103))]
        )

        let expectedPackets: [RTCPPacket] = [
            .transportLayerNACK(
                RTCPTransportLayerNACK(
                    senderSSRC: 0x0102_0304,
                    mediaSSRC: 0x0506_0708,
                    lostPacketIDs: [100, 101, 102]
                )
            )
        ]
        XCTAssertEqual(plannedPackets, expectedPackets)
        let decodedPackets = try await decodedSubscriberOutboundRTCPPackets(from: datagramTransport.sentDatagrams)
        XCTAssertEqual(decodedPackets, expectedPackets)
    }

    func testSubscriberRTCPFeedbackKeyFrameRequestSendsPLIThroughStartedSecureMediaTransport() async throws {
        let (room, datagramTransport) = try await makeStartedSubscriberRTCPFeedbackRoom()

        let plannedPackets = try await room.sendSubscriberRTCPFeedback(
            senderSSRC: 0x0102_0304,
            mediaSSRC: 0x0506_0708,
            signals: [.keyFrameRequest]
        )

        let expectedPackets: [RTCPPacket] = [
            .pictureLossIndication(
                RTCPPictureLossIndication(senderSSRC: 0x0102_0304, mediaSSRC: 0x0506_0708)
            )
        ]
        XCTAssertEqual(plannedPackets, expectedPackets)
        let decodedPackets = try await decodedSubscriberOutboundRTCPPackets(from: datagramTransport.sentDatagrams)
        XCTAssertEqual(decodedPackets, expectedPackets)
    }

    func testSubscriberRTCPFeedbackCombinedLossAndKeyFrameSendsNACKThenPLIThroughStartedSecureMediaTransport() async throws {
        let (room, datagramTransport) = try await makeStartedSubscriberRTCPFeedbackRoom()

        let plannedPackets = try await room.sendSubscriberRTCPFeedback(
            senderSSRC: 0x0102_0304,
            mediaSSRC: 0x0506_0708,
            missingSequenceNumbers: [42, 43],
            requestsKeyFrame: true
        )

        let expectedPackets: [RTCPPacket] = [
            .transportLayerNACK(
                RTCPTransportLayerNACK(
                    senderSSRC: 0x0102_0304,
                    mediaSSRC: 0x0506_0708,
                    lostPacketIDs: [42, 43]
                )
            ),
            .pictureLossIndication(
                RTCPPictureLossIndication(senderSSRC: 0x0102_0304, mediaSSRC: 0x0506_0708)
            )
        ]
        XCTAssertEqual(plannedPackets, expectedPackets)
        let decodedPackets = try await decodedSubscriberOutboundRTCPPackets(from: datagramTransport.sentDatagrams)
        XCTAssertEqual(decodedPackets, expectedPackets)
    }

    func testSubscriberReceiverReportSendsObservedRTPStatsThroughStartedSecureMediaTransport() async throws {
        let (room, datagramTransport) = try await makeStartedSubscriberRTCPFeedbackRoom()
        let mediaSSRC: UInt32 = 0x0506_0708

        datagramTransport.enqueueIncomingDatagram(
            try await protectedSubscriberInboundRTPDatagram(
                RTPPacket(
                    marker: false,
                    payloadType: 111,
                    sequenceNumber: 1,
                    timestamp: 960,
                    ssrc: mediaSSRC,
                    payload: Data([0x08])
                )
            )
        )
        datagramTransport.enqueueIncomingDatagram(
            try await protectedSubscriberInboundRTPDatagram(
                RTPPacket(
                    marker: false,
                    payloadType: 111,
                    sequenceNumber: 2,
                    timestamp: 1_920,
                    ssrc: mediaSSRC,
                    payload: Data([0x08])
                )
            )
        )

        let snapshots = await waitForSubscriberReceiverReportSnapshots(
            room,
            mediaSSRC: mediaSSRC,
            receivedPackets: 2
        )
        XCTAssertEqual(snapshots.first?.report.highestSequenceNumber, 2)

        let plannedPacket = try await room.sendSubscriberRTCPReceiverReport(senderSSRC: 0x0102_0304)
        let decodedPackets = try await decodedSubscriberOutboundRTCPPackets(from: datagramTransport.sentDatagrams)
        XCTAssertEqual(decodedPackets, plannedPacket.map { [$0] } ?? [])

        guard case let .receiverReport(report) = plannedPacket else {
            return XCTFail("Expected receiver report.")
        }
        let receptionReport = try XCTUnwrap(report.reports.first)
        XCTAssertEqual(report.senderSSRC, 0x0102_0304)
        XCTAssertEqual(receptionReport.ssrc, mediaSSRC)
        XCTAssertEqual(receptionReport.highestSequenceNumber, 2)
        XCTAssertEqual(receptionReport.cumulativePacketsLost, 0)
        XCTAssertEqual(receptionReport.fractionLost, 0)
    }

    func testSubscriberReceiverEstimatedMaximumBitrateSendsFromReceiverReportEstimate() async throws {
        let (room, datagramTransport) = try await makeStartedSubscriberRTCPFeedbackRoom()
        let mediaSSRC: UInt32 = 0x0506_0708

        datagramTransport.enqueueIncomingDatagram(
            try await protectedSubscriberInboundRTPDatagram(
                RTPPacket(
                    marker: false,
                    payloadType: 111,
                    sequenceNumber: 1,
                    timestamp: 960,
                    ssrc: mediaSSRC,
                    payload: Data([0x08])
                )
            )
        )
        datagramTransport.enqueueIncomingDatagram(
            try await protectedSubscriberInboundRTPDatagram(
                RTPPacket(
                    marker: false,
                    payloadType: 111,
                    sequenceNumber: 2,
                    timestamp: 1_920,
                    ssrc: mediaSSRC,
                    payload: Data([0x08])
                )
            )
        )

        _ = await waitForSubscriberReceiverReportSnapshots(
            room,
            mediaSSRC: mediaSSRC,
            receivedPackets: 2
        )

        let receiverReportPacket = try await room.sendSubscriberRTCPReceiverReport(senderSSRC: 0x0102_0304)
        let estimate = try XCTUnwrap(room.subscriberBandwidthEstimateSnapshots.first(where: { $0.ssrc == mediaSSRC }))
        XCTAssertEqual(estimate.estimate.estimatedBitrateBps, 1_620_000)

        let rembPacket = try await room.sendSubscriberRTCPReceiverEstimatedMaximumBitrate(senderSSRC: 0x0102_0304)
        let decodedPackets = try await decodedSubscriberOutboundRTCPPackets(from: datagramTransport.sentDatagrams)
        XCTAssertEqual(decodedPackets, [try XCTUnwrap(receiverReportPacket), try XCTUnwrap(rembPacket)])

        guard case let .receiverEstimatedMaximumBitrate(remb) = rembPacket else {
            return XCTFail("Expected REMB packet.")
        }
        XCTAssertEqual(remb.senderSSRC, 0x0102_0304)
        XCTAssertEqual(remb.bitrateBps, 1_620_000)
        XCTAssertEqual(remb.ssrcs, [mediaSSRC])
    }

    func testSubscriberReceiverReportAutoAppliesAdaptiveTrackSettingsWhenEnabled() async throws {
        let (room, datagramTransport, signalTransport) = try await makeStartedSubscriberRTCPFeedbackRoomWithSignalTransport(
            roomOptions: RoomOptions(
                automaticallyApplySubscriberAdaptiveTrackSettings: true,
                subscriberAdaptiveTrackSettingsPriority: 2
            )
        )
        let mediaSSRC: UInt32 = 0x0506_0708

        datagramTransport.enqueueIncomingDatagram(
            try await protectedSubscriberInboundRTPDatagram(
                RTPPacket(
                    marker: false,
                    payloadType: 111,
                    sequenceNumber: 1,
                    timestamp: 960,
                    ssrc: mediaSSRC,
                    payload: Data([0x08])
                )
            )
        )
        datagramTransport.enqueueIncomingDatagram(
            try await protectedSubscriberInboundRTPDatagram(
                RTPPacket(
                    marker: false,
                    payloadType: 111,
                    sequenceNumber: 2,
                    timestamp: 1_920,
                    ssrc: mediaSSRC,
                    payload: Data([0x08])
                )
            )
        )

        _ = await waitForSubscriberReceiverReportSnapshots(
            room,
            mediaSSRC: mediaSSRC,
            receivedPackets: 2
        )

        _ = try await room.sendSubscriberRTCPReceiverReport(senderSSRC: 0x0102_0304)

        let sentFrames = await waitForSentFrameCount(4, transport: signalTransport)
        guard case let .binary(data) = sentFrames[3] else {
            return XCTFail("Expected binary UpdateTrackSettings request.")
        }

        let request = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: data)
        guard case let .trackSetting(settings)? = request.message else {
            return XCTFail("Expected SignalRequest.trackSetting.")
        }
        XCTAssertEqual(settings.trackSids, ["TR_camera"])
        XCTAssertFalse(settings.disabled)
        XCTAssertEqual(settings.quality, .medium)
        XCTAssertEqual(settings.width, 1_280)
        XCTAssertEqual(settings.height, 720)
        XCTAssertEqual(settings.fps, 24)
        XCTAssertEqual(settings.priority, 2)

        _ = try await room.sendSubscriberRTCPReceiverReport(senderSSRC: 0x0102_0304)
        try await Task.sleep(nanoseconds: 20_000_000)
        let sentFrameCountAfterDuplicatePlan = await signalTransport.sentFrames.count
        XCTAssertEqual(sentFrameCountAfterDuplicatePlan, 4)
    }

    func testSubscriberReceiveLoopSchedulesAudioPlayoutWhenEnabled() async throws {
        let opusPacket: OpusPacket
        do {
            opusPacket = try makeEncodedOpusPacket()
            _ = try OpusAudioConverterDecoder().decode(opusPacket)
        } catch let error as OpusAudioPipelineError {
            throw XCTSkip("AudioToolbox Opus playout unavailable in this environment: \(error)")
        }

        let (room, datagramTransport, _) = try await makeStartedSubscriberRTCPFeedbackRoomWithSignalTransport(
            roomOptions: RoomOptions(automaticallyPlaySubscriberAudio: true)
        )
        let mediaSSRC: UInt32 = 0x0506_0708

        datagramTransport.enqueueIncomingDatagram(
            try await protectedSubscriberInboundRTPDatagram(
                RTPPacket(
                    marker: false,
                    payloadType: 111,
                    sequenceNumber: 1,
                    timestamp: 960,
                    ssrc: mediaSSRC,
                    payload: opusPacket.payload
                )
            )
        )

        let scheduledBufferCount = await waitForSubscriberAudioPlayoutScheduledBufferCount(room, count: 1)
        XCTAssertEqual(scheduledBufferCount, 1)
    }

    func testSubscriberReceiveLoopDecodesVideoWhenEnabled() async throws {
        let mediaSSRC: UInt32 = 0x0506_0708
        let encodedFrame = try makeEncodedH264Frame()
        let packets = try H264PublishRTPPacketizer(
            payloadType: 102,
            mtu: 1_200,
            ssrc: mediaSSRC
        ).packetize(encodedFrame)

        do {
            _ = try H264VideoToolboxSubscribeDecoder().decode(
                H264AccessUnit(timestamp: encodedFrame.rtpTimestamp, nalUnits: encodedFrame.nalUnits)
            )
        } catch let error as H264VideoToolboxSubscribeDecoderError {
            throw XCTSkip("VideoToolbox H.264 decoder unavailable in this environment: \(error)")
        }

        let (room, datagramTransport, _) = try await makeStartedSubscriberRTCPFeedbackRoomWithSignalTransport(
            roomOptions: RoomOptions(automaticallyDecodeSubscriberVideo: true)
        )

        for packet in packets {
            datagramTransport.enqueueIncomingDatagram(try await protectedSubscriberInboundRTPDatagram(packet))
        }

        let decodedFrameCount = await waitForSubscriberDecodedVideoFrameCount(room, count: 1)
        XCTAssertEqual(decodedFrameCount, 1)
    }

    func testSubscriberReceiveLoopRendersDecodedVideoWhenRendererAttached() async throws {
        let mediaSSRC: UInt32 = 0x0506_0708
        let encodedFrame = try makeEncodedH264Frame()
        let packets = try H264PublishRTPPacketizer(
            payloadType: 102,
            mtu: 1_200,
            ssrc: mediaSSRC
        ).packetize(encodedFrame)

        do {
            _ = try H264VideoToolboxSubscribeDecoder().decode(
                H264AccessUnit(timestamp: encodedFrame.rtpTimestamp, nalUnits: encodedFrame.nalUnits)
            )
        } catch let error as H264VideoToolboxSubscribeDecoderError {
            throw XCTSkip("VideoToolbox H.264 decoder unavailable in this environment: \(error)")
        }

        let renderer = RecordingSubscriberVideoFrameRenderer()
        let (room, datagramTransport, _) = try await makeStartedSubscriberRTCPFeedbackRoomWithSignalTransport()
        room.setSubscriberVideoRenderer(renderer)

        for packet in packets {
            datagramTransport.enqueueIncomingDatagram(try await protectedSubscriberInboundRTPDatagram(packet))
        }

        let renderedFrameCount = await waitForSubscriberRenderedVideoFrameCount(room, count: 1)
        let renderedFrames = await waitForRenderedVideoFrames(renderer, count: 1)
        let renderedFrame = try XCTUnwrap(renderedFrames.first)
        XCTAssertEqual(renderedFrameCount, 1)
        XCTAssertEqual(renderedFrame.width, 16)
        XCTAssertEqual(renderedFrame.height, 16)
    }

    func testSubscriberReceiverReportLoopSendsCadencedReportsAfterObservedRTP() async throws {
        let (room, datagramTransport) = try await makeStartedSubscriberRTCPFeedbackRoom(
            receiverReportPolicy: RTCPReceiverReportSchedulePolicy(intervalSeconds: 0.01)
        )
        let mediaSSRC: UInt32 = 0x0506_0708
        XCTAssertTrue(room.isSubscriberRTCPReceiverReportLoopActive)

        datagramTransport.enqueueIncomingDatagram(
            try await protectedSubscriberInboundRTPDatagram(
                RTPPacket(
                    marker: false,
                    payloadType: 111,
                    sequenceNumber: 10,
                    timestamp: 960,
                    ssrc: mediaSSRC,
                    payload: Data([0x08])
                )
            )
        )

        let sentDatagrams = await waitForSentDatagramCount(1, transport: datagramTransport)
        let decodedPackets = try await decodedSubscriberOutboundRTCPPackets(from: [try XCTUnwrap(sentDatagrams.first)])

        guard case let .receiverReport(report) = try XCTUnwrap(decodedPackets.first) else {
            return XCTFail("Expected receiver report.")
        }
        let receptionReport = try XCTUnwrap(report.reports.first)
        XCTAssertEqual(receptionReport.ssrc, mediaSSRC)
        XCTAssertEqual(receptionReport.highestSequenceNumber, 10)
        XCTAssertEqual(receptionReport.cumulativePacketsLost, 0)
    }

    func testSubscriberRTCPReceiveHandlerReceivesDecodedPacket() async throws {
        let frames = try [
            makeJoinResponse(),
            makeSubscriberOfferResponse(),
            makeSubscriberTrickleResponse(),
            makeSubscriberTrickleCompleteResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let localCandidate = ICECandidate(
            foundation: "subscriber-local",
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(type: .host, localPreference: 65_535).value,
            address: "192.0.2.11",
            port: 55001,
            type: .host
        )
        let datagramTransport = RoomMediaStartupDatagramTransport()
        let binder = DTLSSRTPMediaSessionBinder(
            datagramTransportFactory: RoomMediaStartupDatagramTransportFactory(transport: datagramTransport),
            handshaker: RoomMediaStartupDTLSHandshaker(
                result: try DTLSSRTPHandshakeResult(
                    role: .client,
                    exportedKeyingMaterial: roomMediaStartupExportedKeyingMaterial(),
                    remoteFingerprint: DTLSSignature(hashFunction: "sha-256", value: "DD:EE:FF")
                )
            )
        )
        let room = Room(
            signalConnection: SignalConnection(transport: transport),
            subscriberPeerConnection: PeerConnectionCoordinator(configuration: NativeWebRTCConfiguration(role: .subscriber)),
            subscriberMediaStartupConfiguration: RoomSubscriberMediaStartupConfiguration(
                localCandidates: { [localCandidate] },
                tieBreaker: 43,
                checker: RoomMediaStartupICEChecker(),
                binder: binder
            )
        )
        let recorder = SubscriberRTCPRecorder()
        room.setSubscriberRTCPHandler { packet in
            await recorder.record(packet)
        }

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")
        let startupResult = await waitForSubscriberMediaStartupResult(room)
        _ = try XCTUnwrap(startupResult)
        XCTAssertTrue(room.isSubscriberRTCPReceiveLoopActive)

        let packet = RTCPPacket.pictureLossIndication(
            RTCPPictureLossIndication(senderSSRC: 0x0102_0304, mediaSSRC: 0x0506_0708)
        )
        let protectedDatagram = try await protectedSubscriberInboundRTCPDatagram(packet)

        datagramTransport.enqueueIncomingDatagram(protectedDatagram)

        let receivedPackets = await recorder.waitForPacketCount(1)
        XCTAssertEqual(receivedPackets, [packet])
    }

    func testDisconnectClearsSubscriberRTCPReceiveLoop() async throws {
        let frames = try [
            makeJoinResponse(),
            makeSubscriberOfferResponse(),
            makeSubscriberTrickleResponse(),
            makeSubscriberTrickleCompleteResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let localCandidate = ICECandidate(
            foundation: "subscriber-local",
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(type: .host, localPreference: 65_535).value,
            address: "192.0.2.11",
            port: 55001,
            type: .host
        )
        let datagramTransport = RoomMediaStartupDatagramTransport()
        let binder = DTLSSRTPMediaSessionBinder(
            datagramTransportFactory: RoomMediaStartupDatagramTransportFactory(transport: datagramTransport),
            handshaker: RoomMediaStartupDTLSHandshaker(
                result: try DTLSSRTPHandshakeResult(
                    role: .client,
                    exportedKeyingMaterial: roomMediaStartupExportedKeyingMaterial(),
                    remoteFingerprint: DTLSSignature(hashFunction: "sha-256", value: "DD:EE:FF")
                )
            )
        )
        let room = Room(
            signalConnection: SignalConnection(transport: transport),
            subscriberPeerConnection: PeerConnectionCoordinator(configuration: NativeWebRTCConfiguration(role: .subscriber)),
            subscriberMediaStartupConfiguration: RoomSubscriberMediaStartupConfiguration(
                localCandidates: { [localCandidate] },
                tieBreaker: 43,
                checker: RoomMediaStartupICEChecker(),
                binder: binder
            )
        )
        let recorder = SubscriberRTCPRecorder()
        room.setSubscriberRTCPHandler { packet in
            await recorder.record(packet)
        }

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")
        let startupResult = await waitForSubscriberMediaStartupResult(room)
        _ = try XCTUnwrap(startupResult)
        XCTAssertTrue(room.isSubscriberRTCPReceiveLoopActive)

        await room.disconnect()
        XCTAssertNil(room.lastSubscriberMediaStartupResult)
        XCTAssertFalse(room.isSubscriberRTCPReceiveLoopActive)

        let packet = RTCPPacket.pictureLossIndication(
            RTCPPictureLossIndication(senderSSRC: 0x0102_0304, mediaSSRC: 0x0506_0708)
        )
        datagramTransport.enqueueIncomingDatagram(try await protectedSubscriberInboundRTCPDatagram(packet))

        let receivedPacketsAfterCleanup = await recorder.waitForPacketCount(1, attempts: 10)
        XCTAssertEqual(receivedPacketsAfterCleanup, [])
    }

    func testPublisherSendingHooksUseStoredSendersForPublishedSIDs() async throws {
        let frames = try [
            makeJoinResponse(),
            makePublisherAnswerResponse(),
            makePublisherTrickleResponse(),
            makePublisherTrickleCompleteResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let localCandidate = ICECandidate(
            foundation: "local",
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(type: .host, localPreference: 65_535).value,
            address: "192.0.2.10",
            port: 55000,
            type: .host
        )
        let datagramTransport = RoomMediaStartupDatagramTransport()
        let binder = DTLSSRTPMediaSessionBinder(
            datagramTransportFactory: RoomMediaStartupDatagramTransportFactory(transport: datagramTransport),
            handshaker: RoomMediaStartupDTLSHandshaker(
                result: try DTLSSRTPHandshakeResult(
                    role: .server,
                    exportedKeyingMaterial: Data(
                        (0..<SRTPProtectionProfile.aes128CMHMACSHA180.exporterByteCount).map(UInt8.init)
                    ),
                    remoteFingerprint: DTLSSignature(hashFunction: "sha-256", value: "AA:BB:CC")
                )
            )
        )
        let room = Room(
            signalConnection: SignalConnection(transport: transport),
            publisherPeerConnection: PeerConnectionCoordinator(configuration: NativeWebRTCConfiguration(role: .publisher)),
            publisherMediaStartupConfiguration: RoomPublisherMediaStartupConfiguration(
                localCandidates: { [localCandidate] },
                tieBreaker: 42,
                checker: RoomMediaStartupICEChecker(),
                binder: binder
            )
        )
        let videoTrack = LocalVideoTrack(id: "camera-cid", name: "camera", source: .camera)
        let audioTrack = LocalAudioTrack(id: "mic-cid", name: "microphone", source: .microphone)

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")
        let startupResult = await waitForPublisherMediaStartupResult(room)
        _ = try XCTUnwrap(startupResult)

        let videoPublishTask = Task {
            try await room.localParticipant.publish(
                videoTrack: videoTrack,
                options: TrackPublishOptions(name: "main-camera", source: .camera)
            )
        }
        let addVideoFrames = await waitForSentFrameCount(1, transport: transport)
        guard case let .binary(addVideoData) = try XCTUnwrap(addVideoFrames.first) else {
            return XCTFail("Expected binary video AddTrack request.")
        }
        let addVideoRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: addVideoData)
        guard case let .addTrack(addVideoTrack)? = addVideoRequest.message else {
            return XCTFail("Expected SignalRequest.addTrack.")
        }
        try await transport.enqueueIncomingFrame(
            .binary(
                SignalFrameCodec().encode(
                    makeTrackPublishedResponse(
                        cid: addVideoTrack.cid,
                        sid: "TR_local_camera",
                        name: "main-camera",
                        type: .video,
                        source: .camera
                    )
                )
            )
        )
        _ = await waitForSentFrameCount(4, transport: transport)
        let videoPublication = try await videoPublishTask.value
        XCTAssertNotNil(room.publisherVideoRTPSender(sid: videoPublication.sid))

        let videoPackets = try await room.sendPublisherVideo(
            H264EncodedFrame(nalUnits: [Data([0x65, 0x01, 0x02])], rtpTimestamp: 90_000, isKeyFrame: true),
            sid: videoPublication.sid
        )

        XCTAssertEqual(videoPackets.count, 1)
        XCTAssertEqual(datagramTransport.sentDatagrams.count, 1)
        XCTAssertNotEqual(datagramTransport.sentDatagrams[0], videoPackets[0].encoded())

        let audioPublishTask = Task {
            try await room.localParticipant.publish(
                audioTrack: audioTrack,
                options: TrackPublishOptions(name: "main-mic", source: .microphone)
            )
        }
        let addAudioFrames = await waitForSentFrameCount(5, transport: transport)
        guard case let .binary(addAudioData) = addAudioFrames[4] else {
            return XCTFail("Expected binary audio AddTrack request.")
        }
        let addAudioRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: addAudioData)
        guard case let .addTrack(addAudioTrack)? = addAudioRequest.message else {
            return XCTFail("Expected SignalRequest.addTrack.")
        }
        try await transport.enqueueIncomingFrame(
            .binary(
                SignalFrameCodec().encode(
                    makeTrackPublishedResponse(
                        cid: addAudioTrack.cid,
                        sid: "TR_local_microphone",
                        name: "main-mic",
                        type: .audio,
                        source: .microphone
                    )
                )
            )
        )
        _ = await waitForSentFrameCount(8, transport: transport)
        let audioPublication = try await audioPublishTask.value
        XCTAssertNotNil(room.publisherAudioRTPSender(sid: audioPublication.sid))

        let audioPacket = try await room.sendPublisherAudio(
            try OpusPacket(payload: Data([0x08, 0xAA])),
            sid: audioPublication.sid
        )

        XCTAssertEqual(datagramTransport.sentDatagrams.count, 2)
        XCTAssertNotEqual(datagramTransport.sentDatagrams[1], audioPacket.encoded())
    }

    func testPublisherSendingHooksRejectMissingSID() async throws {
        let room = Room()

        do {
            try await room.sendPublisherAudio(try OpusPacket(payload: Data([0x08, 0xAA])), sid: "TR_missing_audio")
            XCTFail("Expected missing publisher audio RTP sender failure.")
        } catch {
            XCTAssertEqual(
                error as? LiveKitNativeError,
                .requestFailed(
                    action: "send publisher audio",
                    reason: "publisherAudioRTPSenderUnavailable",
                    message: "No publisher audio RTP sender is registered for SID TR_missing_audio."
                )
            )
        }

        do {
            try await room.sendPublisherVideo(
                H264EncodedFrame(nalUnits: [Data([0x65, 0x01])], rtpTimestamp: 90_000, isKeyFrame: true),
                sid: "TR_missing_video"
            )
            XCTFail("Expected missing publisher video RTP sender failure.")
        } catch {
            XCTAssertEqual(
                error as? LiveKitNativeError,
                .requestFailed(
                    action: "send publisher video",
                    reason: "publisherVideoRTPSenderUnavailable",
                    message: "No publisher video RTP sender is registered for SID TR_missing_video."
                )
            )
        }
    }

    func testSubscriberRTCPRejectsMissingSecureMediaTransport() async {
        let room = Room()
        let packet = RTCPPacket.pictureLossIndication(
            RTCPPictureLossIndication(senderSSRC: 0x0102_0304, mediaSSRC: 0x0506_0708)
        )

        do {
            try await room.sendSubscriberRTCP(packet)
            XCTFail("Expected missing subscriber media transport failure.")
        } catch {
            XCTAssertEqual(
                error as? LiveKitNativeError,
                .requestFailed(
                    action: "send RTCP",
                    reason: "subscriberMediaTransportUnavailable",
                    message: "Subscriber secure media transport is not started."
                )
            )
        }
    }

    func testSubscriberRTCPFeedbackRejectsMissingSecureMediaTransport() async {
        let room = Room()

        do {
            try await room.sendSubscriberRTCPFeedback(
                senderSSRC: 0x0102_0304,
                mediaSSRC: 0x0506_0708,
                missingSequenceNumbers: [100]
            )
            XCTFail("Expected missing subscriber media transport failure.")
        } catch {
            XCTAssertEqual(
                error as? LiveKitNativeError,
                .requestFailed(
                    action: "send RTCP",
                    reason: "subscriberMediaTransportUnavailable",
                    message: "Subscriber secure media transport is not started."
                )
            )
        }
    }

    func testPublisherRTCPRejectsMissingSecureMediaTransport() async {
        let room = Room()
        let packet = RTCPPacket.pictureLossIndication(
            RTCPPictureLossIndication(senderSSRC: 0x0102_0304, mediaSSRC: 0x0506_0708)
        )

        do {
            try await room.sendPublisherRTCP(packet)
            XCTFail("Expected missing publisher media transport failure.")
        } catch {
            XCTAssertEqual(
                error as? LiveKitNativeError,
                .requestFailed(
                    action: "send RTCP",
                    reason: "publisherMediaTransportUnavailable",
                    message: "Publisher secure media transport is not started."
                )
            )
        }
    }

    func testPublisherRTPBridgeRejectsMissingSecureMediaTransport() async {
        let room = Room()
        let packet = RTPPacket(
            marker: true,
            payloadType: 102,
            sequenceNumber: 12,
            timestamp: 90_000,
            ssrc: 0x1122_3344,
            payload: Data([0x01])
        )

        do {
            try await room.sendPublisherRTP(packet)
            XCTFail("Expected missing publisher media transport failure.")
        } catch {
            XCTAssertEqual(
                error as? LiveKitNativeError,
                .requestFailed(
                    action: "send RTP",
                    reason: "publisherMediaTransportUnavailable",
                    message: "Publisher secure media transport is not started."
                )
            )
        }
    }

    func testUnpublishLastTrackClosesPublisherMediaTransport() async throws {
        let frames = try [
            makeJoinResponse(),
            makePublisherAnswerResponse(),
            makePublisherTrickleResponse(),
            makePublisherTrickleCompleteResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let localCandidate = ICECandidate(
            foundation: "local",
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(type: .host, localPreference: 65_535).value,
            address: "192.0.2.10",
            port: 55000,
            type: .host
        )
        let publisherPeerConnection = PeerConnectionCoordinator(
            configuration: NativeWebRTCConfiguration(role: .publisher)
        )
        let datagramTransport = RoomMediaStartupDatagramTransport()
        let room = Room(
            signalConnection: SignalConnection(transport: transport),
            publisherPeerConnection: publisherPeerConnection,
            publisherMediaStartupConfiguration: RoomPublisherMediaStartupConfiguration(
                localCandidates: { [localCandidate] },
                tieBreaker: 42,
                checker: RoomMediaStartupICEChecker(),
                binder: DTLSSRTPMediaSessionBinder(
                    datagramTransportFactory: RoomMediaStartupDatagramTransportFactory(
                        transport: datagramTransport
                    ),
                    handshaker: RoomMediaStartupDTLSHandshaker(
                        result: try DTLSSRTPHandshakeResult(
                            role: .server,
                            exportedKeyingMaterial: Data(
                                (0..<SRTPProtectionProfile.aes128CMHMACSHA180.exporterByteCount).map(UInt8.init)
                            ),
                            remoteFingerprint: DTLSSignature(hashFunction: "sha-256", value: "AA:BB:CC")
                        )
                    )
                )
            )
        )
        let track = LocalVideoTrack(id: "camera-cid", name: "camera", source: .camera)
        let recorder = PublisherRTCPRecorder()
        room.setPublisherRTCPHandler { packet in
            await recorder.record(packet)
        }

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")
        let startupResult = await waitForPublisherMediaStartupResult(room)
        let startup = try XCTUnwrap(startupResult)
        XCTAssertTrue(room.isPublisherRTCPReceiveLoopActive)

        let publishTask = Task {
            try await room.localParticipant.publish(
                videoTrack: track,
                options: TrackPublishOptions(name: "main-camera", source: .camera)
            )
        }

        let addTrackFrames = await waitForSentFrameCount(1, transport: transport)
        guard case let .binary(addTrackData) = try XCTUnwrap(addTrackFrames.first) else {
            return XCTFail("Expected binary AddTrack request.")
        }
        let addTrackRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: addTrackData)
        guard case let .addTrack(addTrack)? = addTrackRequest.message else {
            return XCTFail("Expected SignalRequest.addTrack.")
        }

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
        _ = await waitForSentFrameCount(4, transport: transport)
        let publication = try await publishTask.value
        XCTAssertNotNil(room.publisherVideoRTPSender(sid: "TR_local_camera"))
        XCTAssertEqual(room.publisherRTPSenderSID(forCID: track.id), "TR_local_camera")

        let unpublishTask = Task {
            try await room.localParticipant.unpublish(publication: publication)
        }

        let muteFrames = await waitForSentFrameCount(5, transport: transport)
        guard case let .binary(muteData) = muteFrames[4] else {
            return XCTFail("Expected binary MuteTrack request.")
        }
        let muteSignalRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: muteData)
        guard case let .mute(mute)? = muteSignalRequest.message else {
            return XCTFail("Expected SignalRequest.mute.")
        }

        try await transport.enqueueIncomingFrame(
            .binary(SignalFrameCodec().encode(makeRequestResponse(reason: .ok, request: .mute(mute))))
        )

        try await unpublishTask.value
        XCTAssertNil(room.lastPublisherMediaStartupResult)
        XCTAssertFalse(room.isPublisherRTCPReceiveLoopActive)
        XCTAssertNil(room.publisherVideoRTPSender(sid: "TR_local_camera"))
        XCTAssertNil(room.publisherRTPSenderSID(forCID: track.id))

        let packet = RTCPPacket.pictureLossIndication(
            RTCPPictureLossIndication(senderSSRC: 0x0102_0304, mediaSSRC: 0x0506_0708)
        )
        datagramTransport.enqueueIncomingDatagram(try await protectedPublisherInboundRTCPDatagram(packet))
        let receivedPacketsAfterCleanup = await recorder.waitForPacketCount(1, attempts: 10)
        XCTAssertEqual(receivedPacketsAfterCleanup, [])

        do {
            try await startup.transport.sendRTP(
                RTPPacket(
                    marker: true,
                    payloadType: 102,
                    sequenceNumber: 1,
                    timestamp: 90_000,
                    ssrc: 0x1122_3344,
                    payload: Data([0x01])
                )
            )
            XCTFail("Expected publisher transport to be closed.")
        } catch {
            XCTAssertEqual(error as? SecureMediaTransportError, .transportClosed)
        }
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
        let expectedRequirement = MediaSectionsRequirementInfo(audioCount: 2, videoCount: 3)
        XCTAssertEqual(requirement, expectedRequirement)
        XCTAssertEqual(room.mediaSectionsRequirement, expectedRequirement)

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
        let expectedHandles = DataTrackSubscriberHandlesInfo(handles: [
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
        ])
        XCTAssertEqual(handles, expectedHandles)
        XCTAssertEqual(room.dataTrackSubscriberHandles, expectedHandles)

        await room.disconnect()

        XCTAssertNil(room.mediaSectionsRequirement)
        XCTAssertNil(room.dataTrackSubscriberHandles)
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

    func testServerTrackUnpublishedClearsLocalPublicationAndPublisherReconnectState() async throws {
        let frames = try [
            makeJoinResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))
        let videoTrack = LocalVideoTrack(id: "camera-cid", name: "camera", source: .camera)
        let audioTrack = LocalAudioTrack(id: "mic-cid", name: "microphone", source: .microphone)

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let videoPublishTask = Task {
            try await room.localParticipant.publish(
                videoTrack: videoTrack,
                options: TrackPublishOptions(name: "main-camera", source: .camera)
            )
        }

        let addVideoFrames = await waitForSentFrameCount(1, transport: transport)
        guard case let .binary(addVideoData) = try XCTUnwrap(addVideoFrames.first) else {
            return XCTFail("Expected binary video AddTrack request.")
        }
        let addVideoRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: addVideoData)
        guard case let .addTrack(addVideoTrack)? = addVideoRequest.message else {
            return XCTFail("Expected SignalRequest.addTrack.")
        }

        try await transport.enqueueIncomingFrame(
            .binary(
                SignalFrameCodec().encode(
                    makeTrackPublishedResponse(
                        cid: addVideoTrack.cid,
                        sid: "TR_local_camera",
                        name: "main-camera",
                        type: .video,
                        source: .camera
                    )
                )
            )
        )

        let videoOfferFrames = await waitForSentFrameCount(2, transport: transport)
        guard case let .binary(videoOfferData) = videoOfferFrames[1] else {
            return XCTFail("Expected binary publisher video offer request.")
        }
        let videoOfferRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: videoOfferData)
        guard case let .offer(videoOffer)? = videoOfferRequest.message else {
            return XCTFail("Expected SignalRequest.offer.")
        }
        XCTAssertTrue(videoOffer.sdp.contains("a=msid:livekit TR_local_camera"))

        _ = try await videoPublishTask.value

        try await transport.enqueueIncomingFrame(
            .binary(SignalFrameCodec().encode(makeTrackUnpublishedResponse(sid: "TR_local_camera")))
        )

        _ = await waitForLocalTrackPublicationCount(0, room: room)
        XCTAssertEqual(room.localParticipant.trackPublications, [])

        try await transport.enqueueIncomingFrame(
            .binary(SignalFrameCodec().encode(makeLeaveResponse(action: .resume)))
        )
        try await transport.enqueueIncomingFrame(
            .binary(SignalFrameCodec().encode(makeReconnectResponse()))
        )

        _ = await waitForConnectedURLCount(2, transport: transport)
        let sentFramesAfterReconnect = await transport.sentFrames
        XCTAssertEqual(sentFramesAfterReconnect.count, 2)

        let audioPublishTask = Task {
            try await room.localParticipant.publish(
                audioTrack: audioTrack,
                options: TrackPublishOptions(name: "main-mic", source: .microphone)
            )
        }

        let addAudioFrames = await waitForSentFrameCount(3, transport: transport)
        guard case let .binary(addAudioData) = addAudioFrames[2] else {
            return XCTFail("Expected binary audio AddTrack request.")
        }
        let addAudioRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: addAudioData)
        guard case let .addTrack(addAudioTrack)? = addAudioRequest.message else {
            return XCTFail("Expected SignalRequest.addTrack.")
        }

        try await transport.enqueueIncomingFrame(
            .binary(
                SignalFrameCodec().encode(
                    makeTrackPublishedResponse(
                        cid: addAudioTrack.cid,
                        sid: "TR_local_microphone",
                        name: "main-mic",
                        type: .audio,
                        source: .microphone
                    )
                )
            )
        )

        let audioOfferFrames = await waitForSentFrameCount(4, transport: transport)
        guard case let .binary(audioOfferData) = audioOfferFrames[3] else {
            return XCTFail("Expected binary publisher audio offer request.")
        }
        let audioOfferRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: audioOfferData)
        guard case let .offer(audioOffer)? = audioOfferRequest.message else {
            return XCTFail("Expected SignalRequest.offer.")
        }

        XCTAssertEqual(audioOffer.id, 2)
        XCTAssertFalse(audioOffer.sdp.contains("a=msid:livekit TR_local_camera"))
        XCTAssertTrue(audioOffer.sdp.contains("a=msid:livekit TR_local_microphone"))

        _ = try await audioPublishTask.value
    }

    func testSignalLoopAppliesTrackMute() async throws {
        let frames = try [
            makeJoinResponse(),
            makeMuteTrackResponse(sid: "TR_camera", muted: true),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))
        let eventRecorder = RoomEventRecorder()
        room.delegate = eventRecorder

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let events = await eventRecorder.waitForEventCount(5)
        let alice = try XCTUnwrap(room.remoteParticipants.first { $0.identity == "alice" })
        let publication = try XCTUnwrap(alice.trackPublications.first)

        XCTAssertTrue(publication.isMuted)

        guard case let .trackMuteChanged(mutedPublication, participant, isMuted) = events[4] else {
            return XCTFail("Expected trackMuteChanged event.")
        }
        XCTAssertEqual(mutedPublication.sid, "TR_camera")
        XCTAssertEqual(participant.sid, "PA_alice")
        XCTAssertTrue(isMuted)
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

        let offerFrames = await waitForSentFrameCount(2, transport: transport)
        guard case let .binary(offerData) = offerFrames[1] else {
            return XCTFail("Expected binary publisher offer request.")
        }
        let offerRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: offerData)
        guard case let .offer(offer)? = offerRequest.message else {
            return XCTFail("Expected SignalRequest.offer.")
        }
        XCTAssertEqual(offer.type, "offer")
        XCTAssertEqual(offer.id, 1)
        XCTAssertTrue(offer.sdp.contains("m=video 9 UDP/TLS/RTP/SAVPF 102"))
        XCTAssertTrue(offer.sdp.contains("a=sendonly"))
        XCTAssertTrue(offer.sdp.contains("a=msid:livekit TR_local_camera"))

        let publication = try await publishTask.value
        XCTAssertEqual(publication.sid, "TR_local_camera")
        XCTAssertEqual(publication.name, "main-camera")
        XCTAssertEqual(publication.kind, .video)
        XCTAssertEqual(room.localParticipant.trackPublications.map(\.sid), ["TR_local_camera"])
    }

    func testPublishVideoTrackMapsRequestResponseFailure() async throws {
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

        try await transport.enqueueIncomingFrame(
            .binary(
                SignalFrameCodec().encode(
                    makeRequestResponse(reason: .notAllowed, request: .addTrack(addTrack))
                )
            )
        )

        do {
            _ = try await publishTask.value
            XCTFail("Expected publish to fail.")
        } catch {
            XCTAssertEqual(error as? LiveKitNativeError, .permissionDenied(action: "publish video track"))
        }
        XCTAssertEqual(room.localParticipant.trackPublications, [])
    }

    func testPublishVideoTrackSendsPublisherLocalICETrickleWhenMediaStartupConfigured() async throws {
        let frames = try [
            makeJoinResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let localCandidate = ICECandidate(
            foundation: "local",
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(type: .host, localPreference: 65_535).value,
            address: "192.0.2.10",
            port: 55000,
            type: .host
        )
        let publisherPeerConnection = PeerConnectionCoordinator(
            configuration: NativeWebRTCConfiguration(role: .publisher)
        )
        let room = Room(
            signalConnection: SignalConnection(transport: transport),
            publisherPeerConnection: publisherPeerConnection,
            publisherMediaStartupConfiguration: RoomPublisherMediaStartupConfiguration(
                localCandidates: { [localCandidate] },
                binder: DTLSSRTPMediaSessionBinder(
                    datagramTransportFactory: RoomMediaStartupDatagramTransportFactory(
                        transport: RoomMediaStartupDatagramTransport()
                    ),
                    handshaker: RoomMediaStartupDTLSHandshaker(
                        result: try DTLSSRTPHandshakeResult(
                            role: .server,
                            exportedKeyingMaterial: Data(
                                (0..<SRTPProtectionProfile.aes128CMHMACSHA180.exporterByteCount).map(UInt8.init)
                            ),
                            remoteFingerprint: DTLSSignature(hashFunction: "sha-256", value: "AA:BB:CC")
                        )
                    )
                )
            )
        )
        let track = LocalVideoTrack(name: "camera", source: .camera)

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let publishTask = Task {
            try await room.localParticipant.publish(
                videoTrack: track,
                options: TrackPublishOptions(name: "main-camera", source: .camera)
            )
        }

        let addTrackFrames = await waitForSentFrameCount(1, transport: transport)
        guard case let .binary(addTrackData) = try XCTUnwrap(addTrackFrames.first) else {
            return XCTFail("Expected binary AddTrack request.")
        }
        let addTrackRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: addTrackData)
        guard case let .addTrack(addTrack)? = addTrackRequest.message else {
            return XCTFail("Expected SignalRequest.addTrack.")
        }

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

        let sentFrames = await waitForSentFrameCount(4, transport: transport)
        guard case let .binary(candidateData) = sentFrames[2] else {
            return XCTFail("Expected binary publisher trickle request.")
        }
        let candidateRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: candidateData)
        guard case let .trickle(candidateTrickle)? = candidateRequest.message else {
            return XCTFail("Expected SignalRequest.trickle.")
        }
        let candidateInit = try RTCIceCandidateInit(jsonString: candidateTrickle.candidateInit)
        XCTAssertEqual(candidateTrickle.target, .publisher)
        XCTAssertFalse(candidateTrickle.final)
        XCTAssertEqual(candidateInit.candidate, localCandidate.sdpAttributeValue)
        XCTAssertEqual(candidateInit.sdpMid, "0")
        XCTAssertEqual(candidateInit.sdpMLineIndex, 0)
        XCTAssertEqual(
            candidateInit.usernameFragment,
            publisherPeerConnection.configuration.iceCredentials.usernameFragment
        )

        guard case let .binary(finalData) = sentFrames[3] else {
            return XCTFail("Expected binary final publisher trickle request.")
        }
        let finalRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: finalData)
        guard case let .trickle(finalTrickle)? = finalRequest.message else {
            return XCTFail("Expected final SignalRequest.trickle.")
        }
        XCTAssertEqual(finalTrickle.target, .publisher)
        XCTAssertTrue(finalTrickle.final)
        XCTAssertTrue(finalTrickle.candidateInit.isEmpty)

        _ = try await publishTask.value
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

    func testSetTrackMutedSendsMuteRequestAndUpdatesLocalPublication() async throws {
        let frames = try [
            makeJoinResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))
        let eventRecorder = RoomEventRecorder()
        room.delegate = eventRecorder
        let track = LocalVideoTrack(name: "camera", source: .camera)

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let publishTask = Task {
            try await room.localParticipant.publish(
                videoTrack: track,
                options: TrackPublishOptions(name: "main-camera", source: .camera)
            )
        }

        let addTrackFrames = await waitForSentFrameCount(1, transport: transport)
        guard case let .binary(addTrackData) = try XCTUnwrap(addTrackFrames.first) else {
            return XCTFail("Expected binary AddTrack request.")
        }
        let addTrackRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: addTrackData)
        guard case let .addTrack(addTrack)? = addTrackRequest.message else {
            return XCTFail("Expected SignalRequest.addTrack.")
        }

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

        let muteTask = Task {
            try await room.localParticipant.setTrackMuted(publication: publication, muted: true)
        }

        let sentFrames = await waitForSentFrameCount(3, transport: transport)
        guard case let .binary(muteData) = sentFrames[2] else {
            return XCTFail("Expected binary MuteTrack request.")
        }

        let muteSignalRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: muteData)
        guard case let .mute(mute)? = muteSignalRequest.message else {
            return XCTFail("Expected SignalRequest.mute.")
        }
        XCTAssertEqual(mute.sid, "TR_local_camera")
        XCTAssertTrue(mute.muted)

        try await transport.enqueueIncomingFrame(
            .binary(SignalFrameCodec().encode(makeRequestResponse(reason: .ok, request: .mute(mute))))
        )

        try await muteTask.value
        XCTAssertTrue(publication.isMuted)

        let events = eventRecorder.recordedEvents
        guard case let .trackMuteChanged(mutedPublication, participant, isMuted) = events.last else {
            return XCTFail("Expected trackMuteChanged event.")
        }
        XCTAssertEqual(mutedPublication.sid, "TR_local_camera")
        XCTAssertEqual(participant.sid, "PA_local")
        XCTAssertTrue(isMuted)
    }

    func testUnpublishTrackSendsMuteRequestAndRemovesLocalPublication() async throws {
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

        let addTrackFrames = await waitForSentFrameCount(1, transport: transport)
        guard case let .binary(addTrackData) = try XCTUnwrap(addTrackFrames.first) else {
            return XCTFail("Expected binary AddTrack request.")
        }
        let addTrackRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: addTrackData)
        guard case let .addTrack(addTrack)? = addTrackRequest.message else {
            return XCTFail("Expected SignalRequest.addTrack.")
        }

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

        let unpublishTask = Task {
            try await room.localParticipant.unpublish(publication: publication)
        }

        let sentFrames = await waitForSentFrameCount(3, transport: transport)
        guard case let .binary(muteData) = sentFrames[2] else {
            return XCTFail("Expected binary MuteTrack request.")
        }

        let muteSignalRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: muteData)
        guard case let .mute(mute)? = muteSignalRequest.message else {
            return XCTFail("Expected SignalRequest.mute.")
        }
        XCTAssertEqual(mute.sid, "TR_local_camera")
        XCTAssertTrue(mute.muted)

        try await transport.enqueueIncomingFrame(
            .binary(SignalFrameCodec().encode(makeRequestResponse(reason: .ok, request: .mute(mute))))
        )

        try await unpublishTask.value
        XCTAssertEqual(room.localParticipant.trackPublications, [])
    }

    func testUnpublishLastTrackClearsReconnectPublisherOffer() async throws {
        let frames = try [
            makeJoinResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))
        let track = LocalVideoTrack(id: "camera-cid", name: "camera", source: .camera)

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let publishTask = Task {
            try await room.localParticipant.publish(
                videoTrack: track,
                options: TrackPublishOptions(name: "main-camera", source: .camera)
            )
        }

        let addTrackFrames = await waitForSentFrameCount(1, transport: transport)
        guard case let .binary(addTrackData) = try XCTUnwrap(addTrackFrames.first) else {
            return XCTFail("Expected binary AddTrack request.")
        }
        let addTrackRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: addTrackData)
        guard case let .addTrack(addTrack)? = addTrackRequest.message else {
            return XCTFail("Expected SignalRequest.addTrack.")
        }

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

        let offerFrames = await waitForSentFrameCount(2, transport: transport)
        guard case let .binary(offerData) = offerFrames[1] else {
            return XCTFail("Expected binary publisher offer request.")
        }
        let offerRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: offerData)
        guard case let .offer(offer)? = offerRequest.message else {
            return XCTFail("Expected SignalRequest.offer.")
        }
        XCTAssertTrue(offer.sdp.contains("a=msid:livekit TR_local_camera"))

        let publication = try await publishTask.value
        let unpublishTask = Task {
            try await room.localParticipant.unpublish(publication: publication)
        }

        let muteFrames = await waitForSentFrameCount(3, transport: transport)
        guard case let .binary(muteData) = muteFrames[2] else {
            return XCTFail("Expected binary MuteTrack request.")
        }
        let muteSignalRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: muteData)
        guard case let .mute(mute)? = muteSignalRequest.message else {
            return XCTFail("Expected SignalRequest.mute.")
        }

        try await transport.enqueueIncomingFrame(
            .binary(SignalFrameCodec().encode(makeRequestResponse(reason: .ok, request: .mute(mute))))
        )

        try await unpublishTask.value
        XCTAssertEqual(room.localParticipant.trackPublications, [])

        try await transport.enqueueIncomingFrame(
            .binary(SignalFrameCodec().encode(makeLeaveResponse(action: .resume)))
        )
        try await transport.enqueueIncomingFrame(
            .binary(SignalFrameCodec().encode(makeReconnectResponse()))
        )

        _ = await waitForConnectedURLCount(2, transport: transport)
        let sentFramesAfterReconnect = await transport.sentFrames
        XCTAssertEqual(sentFramesAfterReconnect.count, 3)
    }

    func testUnpublishTrackRenegotiatesPublisherOfferAndReconnectState() async throws {
        let frames = try [
            makeJoinResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))
        let videoTrack = LocalVideoTrack(id: "camera-cid", name: "camera", source: .camera)
        let audioTrack = LocalAudioTrack(id: "mic-cid", name: "microphone", source: .microphone)

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let videoPublishTask = Task {
            try await room.localParticipant.publish(
                videoTrack: videoTrack,
                options: TrackPublishOptions(name: "main-camera", source: .camera)
            )
        }

        let videoAddFrames = await waitForSentFrameCount(1, transport: transport)
        guard case let .binary(videoAddData) = try XCTUnwrap(videoAddFrames.first) else {
            return XCTFail("Expected binary video AddTrack request.")
        }
        let videoAddRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: videoAddData)
        guard case let .addTrack(videoAddTrack)? = videoAddRequest.message else {
            return XCTFail("Expected SignalRequest.addTrack.")
        }

        try await transport.enqueueIncomingFrame(
            .binary(
                SignalFrameCodec().encode(
                    makeTrackPublishedResponse(
                        cid: videoAddTrack.cid,
                        sid: "TR_local_camera",
                        name: "main-camera",
                        type: .video,
                        source: .camera
                    )
                )
            )
        )
        _ = await waitForSentFrameCount(2, transport: transport)
        let videoPublication = try await videoPublishTask.value
        XCTAssertNotNil(room.publisherVideoRTPSender(sid: "TR_local_camera"))
        XCTAssertEqual(room.publisherRTPSenderSID(forCID: videoTrack.id), "TR_local_camera")

        let audioPublishTask = Task {
            try await room.localParticipant.publish(
                audioTrack: audioTrack,
                options: TrackPublishOptions(name: "main-mic", source: .microphone)
            )
        }

        let audioAddFrames = await waitForSentFrameCount(3, transport: transport)
        guard case let .binary(audioAddData) = audioAddFrames[2] else {
            return XCTFail("Expected binary audio AddTrack request.")
        }
        let audioAddRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: audioAddData)
        guard case let .addTrack(audioAddTrack)? = audioAddRequest.message else {
            return XCTFail("Expected SignalRequest.addTrack.")
        }

        try await transport.enqueueIncomingFrame(
            .binary(
                SignalFrameCodec().encode(
                    makeTrackPublishedResponse(
                        cid: audioAddTrack.cid,
                        sid: "TR_local_microphone",
                        name: "main-mic",
                        type: .audio,
                        source: .microphone
                    )
                )
            )
        )

        let audioOfferFrames = await waitForSentFrameCount(4, transport: transport)
        guard case let .binary(audioOfferData) = audioOfferFrames[3] else {
            return XCTFail("Expected binary publisher audio offer request.")
        }
        let audioOfferRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: audioOfferData)
        guard case let .offer(audioOffer)? = audioOfferRequest.message else {
            return XCTFail("Expected SignalRequest.offer.")
        }
        XCTAssertEqual(audioOffer.id, 2)
        XCTAssertTrue(audioOffer.sdp.contains("a=msid:livekit TR_local_camera"))
        XCTAssertTrue(audioOffer.sdp.contains("a=msid:livekit TR_local_microphone"))

        _ = try await audioPublishTask.value
        XCTAssertNotNil(room.publisherAudioRTPSender(sid: "TR_local_microphone"))
        XCTAssertEqual(room.publisherRTPSenderSID(forCID: audioTrack.id), "TR_local_microphone")

        let unpublishTask = Task {
            try await room.localParticipant.unpublish(publication: videoPublication)
        }

        let muteFrames = await waitForSentFrameCount(5, transport: transport)
        guard case let .binary(muteData) = muteFrames[4] else {
            return XCTFail("Expected binary MuteTrack request.")
        }
        let muteSignalRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: muteData)
        guard case let .mute(mute)? = muteSignalRequest.message else {
            return XCTFail("Expected SignalRequest.mute.")
        }

        try await transport.enqueueIncomingFrame(
            .binary(SignalFrameCodec().encode(makeRequestResponse(reason: .ok, request: .mute(mute))))
        )

        let unpublishOfferFrames = await waitForSentFrameCount(6, transport: transport)
        guard case let .binary(unpublishOfferData) = unpublishOfferFrames[5] else {
            return XCTFail("Expected binary publisher unpublish offer request.")
        }
        let unpublishOfferRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: unpublishOfferData)
        guard case let .offer(unpublishOffer)? = unpublishOfferRequest.message else {
            return XCTFail("Expected SignalRequest.offer.")
        }
        XCTAssertEqual(unpublishOffer.id, 3)
        XCTAssertFalse(unpublishOffer.sdp.contains("a=msid:livekit TR_local_camera"))
        XCTAssertTrue(unpublishOffer.sdp.contains("a=msid:livekit TR_local_microphone"))

        try await unpublishTask.value
        XCTAssertEqual(room.localParticipant.trackPublications.map(\.sid), ["TR_local_microphone"])
        XCTAssertNil(room.publisherVideoRTPSender(sid: "TR_local_camera"))
        XCTAssertNil(room.publisherRTPSenderSID(forCID: videoTrack.id))
        XCTAssertNotNil(room.publisherAudioRTPSender(sid: "TR_local_microphone"))
        XCTAssertEqual(room.publisherRTPSenderSID(forCID: audioTrack.id), "TR_local_microphone")

        try await transport.enqueueIncomingFrame(
            .binary(SignalFrameCodec().encode(makeLeaveResponse(action: .resume)))
        )
        try await transport.enqueueIncomingFrame(
            .binary(SignalFrameCodec().encode(makeReconnectResponse()))
        )

        let syncFrames = await waitForSentFrameCount(7, transport: transport)
        guard case let .binary(syncData) = syncFrames[6] else {
            return XCTFail("Expected binary SyncState request.")
        }
        let syncRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: syncData)
        guard case let .syncState(syncState)? = syncRequest.message else {
            return XCTFail("Expected SignalRequest.syncState.")
        }
        XCTAssertEqual(syncState.publishTracks.count, 1)
        XCTAssertEqual(syncState.publishTracks[0].track.sid, "TR_local_microphone")
        XCTAssertTrue(syncState.hasOffer)
        XCTAssertEqual(syncState.offer.id, 4)
        XCTAssertFalse(syncState.offer.sdp.contains("a=msid:livekit TR_local_camera"))
        XCTAssertTrue(syncState.offer.sdp.contains("a=msid:livekit TR_local_microphone"))
        XCTAssertNotEqual(
            try XCTUnwrap(iceUfrag(in: syncState.offer.sdp)),
            try XCTUnwrap(iceUfrag(in: unpublishOffer.sdp))
        )
    }

    func testSetCameraDisabledSendsMuteRequestForPublishedCamera() async throws {
        let frames = try [
            makeJoinResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let publishTask = Task {
            try await room.localParticipant.setCamera(enabled: true)
        }

        let addTrackFrames = await waitForSentFrameCount(1, transport: transport)
        guard case let .binary(addTrackData) = try XCTUnwrap(addTrackFrames.first) else {
            return XCTFail("Expected binary AddTrack request.")
        }
        let addTrackRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: addTrackData)
        guard case let .addTrack(addTrack)? = addTrackRequest.message else {
            return XCTFail("Expected SignalRequest.addTrack.")
        }

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
        try await publishTask.value

        let disableTask = Task {
            try await room.localParticipant.setCamera(enabled: false)
        }

        let sentFrames = await waitForSentFrameCount(3, transport: transport)
        guard case let .binary(muteData) = sentFrames[2] else {
            return XCTFail("Expected binary MuteTrack request.")
        }

        let muteSignalRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: muteData)
        guard case let .mute(mute)? = muteSignalRequest.message else {
            return XCTFail("Expected SignalRequest.mute.")
        }
        XCTAssertEqual(mute.sid, "TR_local_camera")
        XCTAssertTrue(mute.muted)

        try await transport.enqueueIncomingFrame(
            .binary(SignalFrameCodec().encode(makeRequestResponse(reason: .ok, request: .mute(mute))))
        )

        try await disableTask.value
        XCTAssertEqual(room.localParticipant.trackPublications, [])
    }

    func testSetMicrophoneDisabledSendsMuteRequestForPublishedMicrophone() async throws {
        let frames = try [
            makeJoinResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")

        let publishTask = Task {
            try await room.localParticipant.setMicrophone(enabled: true)
        }

        let addTrackFrames = await waitForSentFrameCount(1, transport: transport)
        guard case let .binary(addTrackData) = try XCTUnwrap(addTrackFrames.first) else {
            return XCTFail("Expected binary AddTrack request.")
        }
        let addTrackRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: addTrackData)
        guard case let .addTrack(addTrack)? = addTrackRequest.message else {
            return XCTFail("Expected SignalRequest.addTrack.")
        }

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
        try await publishTask.value

        let disableTask = Task {
            try await room.localParticipant.setMicrophone(enabled: false)
        }

        let sentFrames = await waitForSentFrameCount(3, transport: transport)
        guard case let .binary(muteData) = sentFrames[2] else {
            return XCTFail("Expected binary MuteTrack request.")
        }

        let muteSignalRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: muteData)
        guard case let .mute(mute)? = muteSignalRequest.message else {
            return XCTFail("Expected SignalRequest.mute.")
        }
        XCTAssertEqual(mute.sid, "TR_local_microphone")
        XCTAssertTrue(mute.muted)

        try await transport.enqueueIncomingFrame(
            .binary(SignalFrameCodec().encode(makeRequestResponse(reason: .ok, request: .mute(mute))))
        )

        try await disableTask.value
        XCTAssertEqual(room.localParticipant.trackPublications, [])
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

    func testPublishDataTrackMapsRequestResponseFailure() async throws {
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

        try await transport.enqueueIncomingFrame(
            .binary(
                SignalFrameCodec().encode(
                    makeRequestResponse(reason: .notAllowed, request: .publishDataTrack(publishRequest))
                )
            )
        )

        do {
            _ = try await publishTask.value
            XCTFail("Expected publish data track to fail.")
        } catch {
            XCTAssertEqual(error as? LiveKitNativeError, .permissionDenied(action: "publish data track"))
        }
        XCTAssertEqual(room.localParticipant.dataTrackPublications, [])
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

    func testServerDataTrackUnpublishClearsLocalPublicationAndReconnectState() async throws {
        let frames = try [
            makeJoinResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))
        let eventRecorder = RoomEventRecorder()
        room.delegate = eventRecorder

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
        XCTAssertEqual(room.localParticipant.dataTrackPublications, [dataTrack])

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

        let events = await eventRecorder.waitForEventCount(6)
        guard case let .dataTrackUnpublished(unpublished) = events[5] else {
            return XCTFail("Expected dataTrackUnpublished event.")
        }
        XCTAssertEqual(unpublished, dataTrack)
        XCTAssertEqual(room.localParticipant.dataTrackPublications, [])

        try await transport.enqueueIncomingFrame(
            .binary(SignalFrameCodec().encode(makeLeaveResponse(action: .resume)))
        )
        try await transport.enqueueIncomingFrame(
            .binary(SignalFrameCodec().encode(makeReconnectResponse()))
        )

        _ = await eventRecorder.waitForEventCount(8)
        let sentFrames = await transport.sentFrames
        XCTAssertEqual(sentFrames.count, 1)
    }

    func testUnpublishDataTrackMapsRequestResponseFailure() async throws {
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

        try await transport.enqueueIncomingFrame(
            .binary(
                SignalFrameCodec().encode(
                    makeRequestResponse(
                        reason: .invalidHandle,
                        message: "missing data track",
                        request: .unpublishDataTrack(unpublishRequest)
                    )
                )
            )
        )

        do {
            _ = try await unpublishTask.value
            XCTFail("Expected unpublish data track to fail.")
        } catch {
            XCTAssertEqual(
                error as? LiveKitNativeError,
                .requestFailed(
                    action: "unpublish data track",
                    reason: "invalidHandle",
                    message: "missing data track"
                )
            )
        }
        XCTAssertEqual(room.localParticipant.dataTrackPublications, [dataTrack])
    }

    func testPublishDataUsesInjectedDataChannelPublisherAndFlushesAfterAck() async throws {
        let frames = try [
            makeJoinResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let signalTransport = MockSignalTransport(incomingFrames: frames)
        let dataTransport = RecordingSCTPDataChannelPacketTransport()
        let dataChannelPublisher = LocalDataChannelPublisher(transport: dataTransport)
        let room = Room(
            signalConnection: SignalConnection(transport: signalTransport),
            publisherDataChannel: dataChannelPublisher
        )

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")
        try await room.localParticipant.publish(
            data: Data("hello".utf8),
            options: DataPublishOptions(reliable: true, topic: "chat")
        )

        XCTAssertEqual(room.localParticipant.dataPublishPlans.count, 1)
        XCTAssertEqual(dataTransport.sentPackets.count, 1)
        XCTAssertEqual(dataTransport.sentPackets[0].ppid, .dataChannelControl)

        try await dataChannelPublisher.acceptControlPacket(
            SCTPDataChannelPacket(
                streamID: await dataChannelPublisher.streamID(for: .reliable),
                ppid: .dataChannelControl,
                payload: SCTPDataChannelControlMessage.acknowledgement.encoded()
            )
        )

        XCTAssertEqual(dataTransport.sentPackets.count, 2)
        let dataPacket = try Livekit_DataPacket(serializedBytes: dataTransport.sentPackets[1].payload)
        XCTAssertEqual(dataPacket.kind, .reliable)
        XCTAssertEqual(dataPacket.user.payload, Data("hello".utf8))
        XCTAssertEqual(dataPacket.user.topic, "chat")
        XCTAssertEqual(dataPacket.participantSid, "PA_local")
        XCTAssertEqual(dataPacket.participantIdentity, "marlon")
    }

    func testReconnectResetsInjectedDataChannelBeforeNextPublish() async throws {
        let frames = try [
            makeJoinResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let signalTransport = MockSignalTransport(incomingFrames: frames)
        let dataTransport = RecordingSCTPDataChannelPacketTransport()
        let dataChannelPublisher = LocalDataChannelPublisher(transport: dataTransport)
        let room = Room(
            signalConnection: SignalConnection(transport: signalTransport),
            publisherDataChannel: dataChannelPublisher
        )
        let eventRecorder = RoomEventRecorder()
        room.delegate = eventRecorder

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")
        try await room.localParticipant.publish(
            data: Data("before".utf8),
            options: DataPublishOptions(reliable: true, topic: "chat")
        )

        let reliableStreamID = await dataChannelPublisher.streamID(for: .reliable)
        try await dataChannelPublisher.acceptControlPacket(
            SCTPDataChannelPacket(
                streamID: reliableStreamID,
                ppid: .dataChannelControl,
                payload: SCTPDataChannelControlMessage.acknowledgement.encoded()
            )
        )
        XCTAssertEqual(dataTransport.sentPackets.count, 2)
        XCTAssertEqual(dataTransport.sentPackets[1].ppid, .binary)

        try await signalTransport.enqueueIncomingFrame(
            .binary(SignalFrameCodec().encode(makeLeaveResponse(action: .resume)))
        )
        try await signalTransport.enqueueIncomingFrame(
            .binary(SignalFrameCodec().encode(makeReconnectResponse()))
        )
        let events = await eventRecorder.waitForEventCount(6)
        XCTAssertEqual(events[4], .connectionStateChanged(.reconnecting))
        XCTAssertEqual(events[5], .connectionStateChanged(.connected))

        try await room.localParticipant.publish(
            data: Data("after".utf8),
            options: DataPublishOptions(reliable: true, topic: "chat")
        )

        XCTAssertEqual(dataTransport.sentPackets.count, 3)
        XCTAssertEqual(dataTransport.sentPackets[2].streamID, reliableStreamID)
        XCTAssertEqual(dataTransport.sentPackets[2].ppid, .dataChannelControl)

        try await dataChannelPublisher.acceptControlPacket(
            SCTPDataChannelPacket(
                streamID: reliableStreamID,
                ppid: .dataChannelControl,
                payload: SCTPDataChannelControlMessage.acknowledgement.encoded()
            )
        )

        XCTAssertEqual(dataTransport.sentPackets.count, 4)
        let dataPacket = try Livekit_DataPacket(serializedBytes: dataTransport.sentPackets[3].payload)
        XCTAssertEqual(dataPacket.user.payload, Data("after".utf8))
        XCTAssertEqual(dataPacket.user.topic, "chat")
    }

    func testInboundDataChannelPacketEmitsDataReceivedEvent() async throws {
        let frames = try [
            makeJoinResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let signalTransport = MockSignalTransport(incomingFrames: frames)
        let dataTransport = RecordingSCTPDataChannelPacketTransport()
        let dataChannelPublisher = LocalDataChannelPublisher(transport: dataTransport)
        let room = Room(
            signalConnection: SignalConnection(transport: signalTransport),
            publisherDataChannel: dataChannelPublisher
        )
        let eventRecorder = RoomEventRecorder()
        room.delegate = eventRecorder

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")
        let reliableStreamID = await dataChannelPublisher.streamID(for: .reliable)
        try await room.acceptDataChannelPacket(
            SCTPDataChannelPacket(
                streamID: reliableStreamID,
                ppid: .dataChannelControl,
                payload: SCTPDataChannelControlMessage.open(
                    SCTPDataChannelOpenMessage(reliability: .reliable, label: LiveKitSCTPDataChannelLabel.reliable)
                ).encoded()
            )
        )

        let packet = LiveKitDataPacketMapper.makeUserPacket(
            data: Data("hello".utf8),
            options: DataPublishOptions(reliable: true, topic: "chat"),
            participantSid: "PA_alice",
            participantIdentity: "alice"
        )
        try await room.acceptDataChannelPacket(
            SCTPDataChannelPacket(
                streamID: reliableStreamID,
                ppid: .binary,
                payload: try packet.serializedData()
            )
        )

        let events = await eventRecorder.waitForEventCount(5)
        guard case let .dataReceived(payload, participant, topic) = events.last else {
            return XCTFail("Expected dataReceived event.")
        }
        XCTAssertEqual(payload, Data("hello".utf8))
        XCTAssertEqual(participant?.sid, "PA_alice")
        XCTAssertEqual(topic, "chat")
        XCTAssertEqual(dataTransport.sentPackets.last?.ppid, .dataChannelControl)
    }

    func testInjectedSubscriberDataChannelReceiveLoopEmitsDataReceivedEvent() async throws {
        let frames = try [
            makeJoinResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let signalTransport = MockSignalTransport(incomingFrames: frames)
        let dataTransport = ScriptedSCTPDataChannelPacketTransceiver()
        let subscriberDataChannel = LocalDataChannelPublisher(transport: dataTransport)
        let room = Room(
            signalConnection: SignalConnection(transport: signalTransport),
            subscriberDataChannel: subscriberDataChannel
        )
        let eventRecorder = RoomEventRecorder()
        room.delegate = eventRecorder

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")
        XCTAssertTrue(room.isDataChannelReceiveLoopActive)

        let reliableStreamID = await subscriberDataChannel.streamID(for: .reliable)
        dataTransport.enqueueIncomingPacket(
            SCTPDataChannelPacket(
                streamID: reliableStreamID,
                ppid: .dataChannelControl,
                payload: SCTPDataChannelControlMessage.open(
                    SCTPDataChannelOpenMessage(reliability: .reliable, label: LiveKitSCTPDataChannelLabel.reliable)
                ).encoded()
            )
        )

        let sentPackets = await dataTransport.waitForSentPacketCount(1)
        XCTAssertEqual(
            sentPackets.first,
            SCTPDataChannelPacket(
                streamID: reliableStreamID,
                ppid: .dataChannelControl,
                payload: SCTPDataChannelControlMessage.acknowledgement.encoded()
            )
        )

        let packet = LiveKitDataPacketMapper.makeUserPacket(
            data: Data("from-remote".utf8),
            options: DataPublishOptions(reliable: true, topic: "chat"),
            participantSid: "PA_alice",
            participantIdentity: "alice"
        )
        dataTransport.enqueueIncomingPacket(
            SCTPDataChannelPacket(
                streamID: reliableStreamID,
                ppid: .binary,
                payload: try packet.serializedData()
            )
        )

        let events = await eventRecorder.waitForEventCount(5)
        guard case let .dataReceived(payload, participant, topic) = events.last else {
            return XCTFail("Expected dataReceived event.")
        }
        XCTAssertEqual(payload, Data("from-remote".utf8))
        XCTAssertEqual(participant?.identity, "alice")
        XCTAssertEqual(topic, "chat")

        await room.disconnect()
        XCTAssertFalse(room.isDataChannelReceiveLoopActive)
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

    func testUpdateSubscriptionSendsSignalRequest() async throws {
        let frames = try [
            makeJoinResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")
        try await room.updateSubscription(trackSIDs: ["TR_camera", "TR_screen"], subscribe: false)

        let sentFrames = await waitForSentFrameCount(1, transport: transport)
        guard case let .binary(data) = try XCTUnwrap(sentFrames.first) else {
            return XCTFail("Expected binary UpdateSubscription request.")
        }

        let request = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: data)
        guard case let .subscription(update)? = request.message else {
            return XCTFail("Expected SignalRequest.subscription.")
        }
        XCTAssertEqual(update.trackSids, ["TR_camera", "TR_screen"])
        XCTAssertFalse(update.subscribe)
    }

    func testUpdateTrackSettingsSendsSignalRequest() async throws {
        let frames = try [
            makeJoinResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")
        try await room.updateTrackSettings(
            trackSIDs: ["TR_camera"],
            disabled: true,
            quality: .medium,
            width: 640,
            height: 360,
            fps: 15,
            priority: 2
        )

        let sentFrames = await waitForSentFrameCount(1, transport: transport)
        guard case let .binary(data) = try XCTUnwrap(sentFrames.first) else {
            return XCTFail("Expected binary UpdateTrackSettings request.")
        }

        let request = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: data)
        guard case let .trackSetting(settings)? = request.message else {
            return XCTFail("Expected SignalRequest.trackSetting.")
        }
        XCTAssertEqual(settings.trackSids, ["TR_camera"])
        XCTAssertTrue(settings.disabled)
        XCTAssertEqual(settings.quality, .medium)
        XCTAssertEqual(settings.width, 640)
        XCTAssertEqual(settings.height, 360)
        XCTAssertEqual(settings.fps, 15)
        XCTAssertEqual(settings.priority, 2)
    }

    func testSetSubscribedVideoQualitySendsPresetTrackSettings() async throws {
        let frames = try [
            makeJoinResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")
        try await room.setSubscribedVideoQuality(
            trackSIDs: ["TR_camera"],
            quality: .medium,
            priority: 3
        )

        let sentFrames = await waitForSentFrameCount(1, transport: transport)
        guard case let .binary(data) = try XCTUnwrap(sentFrames.first) else {
            return XCTFail("Expected binary UpdateTrackSettings request.")
        }

        let request = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: data)
        guard case let .trackSetting(settings)? = request.message else {
            return XCTFail("Expected SignalRequest.trackSetting.")
        }
        XCTAssertEqual(settings.trackSids, ["TR_camera"])
        XCTAssertFalse(settings.disabled)
        XCTAssertEqual(settings.quality, .medium)
        XCTAssertEqual(settings.width, 1_280)
        XCTAssertEqual(settings.height, 720)
        XCTAssertEqual(settings.fps, 24)
        XCTAssertEqual(settings.priority, 3)
    }

    func testUpdatePublishedVideoLayersSendsSignalRequest() async throws {
        let frames = try [
            makeJoinResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")
        try await room.updatePublishedVideoLayers(
            trackSID: "TR_camera",
            activeLayers: [
                PublishedVideoLayer(
                    quality: .low,
                    width: 320,
                    height: 180,
                    bitrate: 150_000,
                    ssrc: 0x1111,
                    spatialLayer: 0,
                    rid: "q"
                ),
                PublishedVideoLayer(
                    quality: .high,
                    width: 1_280,
                    height: 720,
                    bitrate: 1_500_000,
                    ssrc: 0x3333,
                    spatialLayer: 2,
                    rid: "f"
                ),
            ]
        )

        let sentFrames = await waitForSentFrameCount(1, transport: transport)
        guard case let .binary(data) = try XCTUnwrap(sentFrames.first) else {
            return XCTFail("Expected binary UpdateVideoLayers request.")
        }

        let request = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: data)
        guard case let .updateLayers(update)? = request.message else {
            return XCTFail("Expected SignalRequest.updateLayers.")
        }
        XCTAssertEqual(update.trackSid, "TR_camera")
        XCTAssertEqual(update.layers.count, 2)
        XCTAssertEqual(update.layers[0].quality, .low)
        XCTAssertEqual(update.layers[0].width, 320)
        XCTAssertEqual(update.layers[0].height, 180)
        XCTAssertEqual(update.layers[0].bitrate, 150_000)
        XCTAssertEqual(update.layers[0].ssrc, 0x1111)
        XCTAssertEqual(update.layers[0].spatialLayer, 0)
        XCTAssertEqual(update.layers[0].rid, "q")
        XCTAssertEqual(update.layers[1].quality, .high)
        XCTAssertEqual(update.layers[1].width, 1_280)
        XCTAssertEqual(update.layers[1].height, 720)
        XCTAssertEqual(update.layers[1].bitrate, 1_500_000)
        XCTAssertEqual(update.layers[1].ssrc, 0x3333)
        XCTAssertEqual(update.layers[1].spatialLayer, 2)
        XCTAssertEqual(update.layers[1].rid, "f")
    }

    func testAdaptiveTrackSettingsSendsRecommendedUpdateTrackSettings() async throws {
        let frames = try [
            makeJoinResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))
        let estimate = BandwidthEstimate(
            estimatedBitrateBps: 500_000,
            lossFraction: 0.10,
            recommendation: AdaptiveVideoQualityRecommendation(
                level: .low,
                targetBitrateBps: 500_000,
                maxWidth: 640,
                maxHeight: 360,
                maxFramesPerSecond: 15
            )
        )

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")
        let plan = try await room.updateAdaptiveTrackSettings(
            trackSIDs: ["TR_camera"],
            estimate: estimate,
            priority: 1
        )

        XCTAssertEqual(
            plan,
            AdaptiveTrackSettingsPlan(
                trackSIDs: ["TR_camera"],
                disabled: false,
                quality: .low,
                width: 640,
                height: 360,
                fps: 15,
                priority: 1
            )
        )

        let sentFrames = await waitForSentFrameCount(1, transport: transport)
        guard case let .binary(data) = try XCTUnwrap(sentFrames.first) else {
            return XCTFail("Expected binary UpdateTrackSettings request.")
        }

        let request = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: data)
        guard case let .trackSetting(settings)? = request.message else {
            return XCTFail("Expected SignalRequest.trackSetting.")
        }
        XCTAssertEqual(settings.trackSids, ["TR_camera"])
        XCTAssertFalse(settings.disabled)
        XCTAssertEqual(settings.quality, .low)
        XCTAssertEqual(settings.width, 640)
        XCTAssertEqual(settings.height, 360)
        XCTAssertEqual(settings.fps, 15)
        XCTAssertEqual(settings.priority, 1)
    }

    func testSetTrackSubscriptionPermissionsSendsSignalRequest() async throws {
        let frames = try [
            makeJoinResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")
        try await room.localParticipant.setTrackSubscriptionPermissions(
            allParticipantsAllowed: false,
            permissions: [
                TrackSubscriptionPermission(
                    participantSID: "PA_alice",
                    allTracks: false,
                    trackSIDs: ["TR_camera"]
                ),
                TrackSubscriptionPermission(
                    participantIdentity: "bob",
                    allTracks: true
                ),
            ]
        )

        let sentFrames = await waitForSentFrameCount(1, transport: transport)
        guard case let .binary(data) = try XCTUnwrap(sentFrames.first) else {
            return XCTFail("Expected binary SubscriptionPermission request.")
        }

        let request = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: data)
        guard case let .subscriptionPermission(permission)? = request.message else {
            return XCTFail("Expected SignalRequest.subscriptionPermission.")
        }
        XCTAssertFalse(permission.allParticipants)
        XCTAssertEqual(permission.trackPermissions.count, 2)
        XCTAssertEqual(permission.trackPermissions[0].participantSid, "PA_alice")
        XCTAssertEqual(permission.trackPermissions[0].participantIdentity, "")
        XCTAssertFalse(permission.trackPermissions[0].allTracks)
        XCTAssertEqual(permission.trackPermissions[0].trackSids, ["TR_camera"])
        XCTAssertEqual(permission.trackPermissions[1].participantSid, "")
        XCTAssertEqual(permission.trackPermissions[1].participantIdentity, "bob")
        XCTAssertTrue(permission.trackPermissions[1].allTracks)
        XCTAssertEqual(permission.trackPermissions[1].trackSids, [])
    }

    func testUpdateAudioTrackSendsSignalRequest() async throws {
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

        let addTrackFrames = await waitForSentFrameCount(1, transport: transport)
        guard case let .binary(addTrackData) = try XCTUnwrap(addTrackFrames.first) else {
            return XCTFail("Expected binary AddTrack request.")
        }
        let addTrackRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: addTrackData)
        guard case let .addTrack(addTrack)? = addTrackRequest.message else {
            return XCTFail("Expected SignalRequest.addTrack.")
        }

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

        let updateTask = Task {
            try await room.localParticipant.updateAudioTrack(
                publication: publication,
                features: [.echoCancellation, .noiseSuppression, .noDTX]
            )
        }

        let sentFrames = await waitForSentFrameCount(3, transport: transport)
        guard case let .binary(updateData) = sentFrames[2] else {
            return XCTFail("Expected binary UpdateLocalAudioTrack request.")
        }

        let updateRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: updateData)
        guard case let .updateAudioTrack(update)? = updateRequest.message else {
            return XCTFail("Expected SignalRequest.updateAudioTrack.")
        }
        XCTAssertEqual(update.trackSid, "TR_local_microphone")
        XCTAssertEqual(update.features, [.tfEchoCancellation, .tfNoiseSuppression, .tfNoDtx])

        try await transport.enqueueIncomingFrame(
            .binary(SignalFrameCodec().encode(makeRequestResponse(reason: .ok, request: .updateAudioTrack(update))))
        )

        try await updateTask.value
    }

    func testUpdateVideoTrackSendsSignalRequest() async throws {
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

        let addTrackFrames = await waitForSentFrameCount(1, transport: transport)
        guard case let .binary(addTrackData) = try XCTUnwrap(addTrackFrames.first) else {
            return XCTFail("Expected binary AddTrack request.")
        }
        let addTrackRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: addTrackData)
        guard case let .addTrack(addTrack)? = addTrackRequest.message else {
            return XCTFail("Expected SignalRequest.addTrack.")
        }

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

        let updateTask = Task {
            try await room.localParticipant.updateVideoTrack(
                publication: publication,
                width: 960,
                height: 540
            )
        }

        let sentFrames = await waitForSentFrameCount(3, transport: transport)
        guard case let .binary(updateData) = sentFrames[2] else {
            return XCTFail("Expected binary UpdateLocalVideoTrack request.")
        }

        let updateRequest = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: updateData)
        guard case let .updateVideoTrack(update)? = updateRequest.message else {
            return XCTFail("Expected SignalRequest.updateVideoTrack.")
        }
        XCTAssertEqual(update.trackSid, "TR_local_camera")
        XCTAssertEqual(update.width, 960)
        XCTAssertEqual(update.height, 540)

        try await transport.enqueueIncomingFrame(
            .binary(SignalFrameCodec().encode(makeRequestResponse(reason: .ok, request: .updateVideoTrack(update))))
        )

        try await updateTask.value
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

        let sentFrames = await transport.sentFrames
        XCTAssertEqual(sentFrames.count, 1)
        guard case let .binary(data) = sentFrames[0] else {
            return XCTFail("Expected binary leave request.")
        }

        let request = try SignalFrameCodec().decode(Livekit_SignalRequest.self, from: data)
        guard case let .leave(leave)? = request.message else {
            return XCTFail("Expected SignalRequest.leave.")
        }
        XCTAssertEqual(leave.action, .disconnect)
        XCTAssertEqual(leave.reason, .clientInitiated)
    }

    func testDisconnectClearsLocalParticipantCommandHandler() async throws {
        let frames = try [
            makeJoinResponse(),
        ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

        let transport = MockSignalTransport(incomingFrames: frames)
        let room = Room(signalConnection: SignalConnection(transport: transport))

        try await room.connect(url: URL(string: "wss://example.test")!, token: "token")
        await room.disconnect()

        let sentFramesBeforeLocalPublish = await transport.sentFrames
        XCTAssertEqual(sentFramesBeforeLocalPublish.count, 1)

        let track = LocalVideoTrack(id: "offline-camera-cid", name: "offline-camera", source: .camera)
        let publication = try await room.localParticipant.publish(videoTrack: track)

        XCTAssertEqual(publication.sid, "offline-camera-cid")
        XCTAssertEqual(room.localParticipant.trackPublications.map(\.sid), ["offline-camera-cid"])

        let sentFramesAfterLocalPublish = await transport.sentFrames
        XCTAssertEqual(sentFramesAfterLocalPublish.count, 1)
    }
}

private enum RecordingAudioSessionEvent: Equatable {
    case configure(AudioSessionConfiguration)
    case activate
    case deactivate
}

private final class RecordingAudioSessionController: AudioSessionControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var mutableEvents: [RecordingAudioSessionEvent] = []

    var events: [RecordingAudioSessionEvent] {
        lock.withLock {
            mutableEvents
        }
    }

    func configureForVoiceChat(_ configuration: AudioSessionConfiguration) throws {
        lock.withLock {
            mutableEvents.append(.configure(configuration))
        }
    }

    func activate() throws {
        lock.withLock {
            mutableEvents.append(.activate)
        }
    }

    func deactivate() throws {
        lock.withLock {
            mutableEvents.append(.deactivate)
        }
    }
}

private func makeJoinResponse(
    alternativeURL: String = "",
    remoteSID: String = "PA_alice",
    remoteIdentity: String = "alice",
    remoteName: String = "Alice",
    remoteTrackSID: String = "TR_camera",
    iceServers: [Livekit_ICEServer] = []
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
    join.iceServers = iceServers

    var response = Livekit_SignalResponse()
    response.join = join
    return response
}

private func makeICEServer(
    urls: [String],
    username: String = "",
    credential: String = ""
) -> Livekit_ICEServer {
    var iceServer = Livekit_ICEServer()
    iceServer.urls = urls
    iceServer.username = username
    iceServer.credential = credential
    return iceServer
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

private func makeReconnectResponse(iceServers: [Livekit_ICEServer] = []) -> Livekit_SignalResponse {
    var reconnect = Livekit_ReconnectResponse()
    reconnect.lastMessageSeq = 5
    reconnect.iceServers = iceServers

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

private func makeSubscriberDataOnlyOfferResponse() -> Livekit_SignalResponse {
    var offer = Livekit_SessionDescription()
    offer.type = "offer"
    offer.id = 7
    offer.sdp = subscriberDataOnlyOfferSDP()

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

private func makeSubscriberTrickleResponse(
    address: String = "192.0.2.1",
    port: UInt16 = 54_545
) -> Livekit_SignalResponse {
    var trickle = Livekit_TrickleRequest()
    trickle.target = .subscriber
    trickle.candidateInit = """
    {"candidate":"candidate:1 1 UDP 2122260223 \(address) \(port) typ host","sdpMid":"0","sdpMLineIndex":0,"usernameFragment":"remote-ufrag"}
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

private func makePublisherTrickleResponse(
    address: String = "192.0.2.2",
    port: UInt16 = 54_546
) -> Livekit_SignalResponse {
    var trickle = Livekit_TrickleRequest()
    trickle.target = .publisher
    trickle.candidateInit = """
    {"candidate":"candidate:2 1 UDP 2122260223 \(address) \(port) typ host","sdpMid":"1","sdpMLineIndex":1,"usernameFragment":"publisher-ufrag"}
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

private func makeTrackUnpublishedResponse(sid: String = "TR_camera") -> Livekit_SignalResponse {
    var trackUnpublished = Livekit_TrackUnpublishedResponse()
    trackUnpublished.trackSid = sid

    var response = Livekit_SignalResponse()
    response.trackUnpublished = trackUnpublished
    return response
}

private func makeMuteTrackResponse(sid: String, muted: Bool) -> Livekit_SignalResponse {
    var mute = Livekit_MuteTrackRequest()
    mute.sid = sid
    mute.muted = muted

    var response = Livekit_SignalResponse()
    response.mute = mute
    return response
}

private func makeRequestResponse(
    requestID: UInt32 = 0,
    reason: Livekit_RequestResponse.Reason,
    message: String = "",
    request: Livekit_RequestResponse.OneOf_Request? = nil
) -> Livekit_SignalResponse {
    var requestResponse = Livekit_RequestResponse()
    requestResponse.requestID = requestID
    requestResponse.reason = reason
    requestResponse.message = message
    requestResponse.request = request

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
    a=ice-ufrag:subscriber-remote-ufrag
    a=ice-pwd:subscriber-remote-password
    a=fingerprint:sha-256 DD:EE:FF
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

private func subscriberDataOnlyOfferSDP() -> String {
    """
    v=0
    o=- 1 1 IN IP4 127.0.0.1
    s=-
    t=0 0
    a=ice-ufrag:subscriber-remote-ufrag
    a=ice-pwd:subscriber-remote-password
    a=fingerprint:sha-256 DD:EE:FF
    a=group:BUNDLE 0
    m=application 9 UDP/DTLS/SCTP webrtc-datachannel
    a=mid:0
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
    a=ice-ufrag:publisher-remote-ufrag
    a=ice-pwd:publisher-remote-password
    a=fingerprint:sha-256 AA:BB:CC
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

private func iceUfrag(in sdp: String) -> String? {
    let prefix = "a=ice-ufrag:"
    return sdp
        .split(whereSeparator: \.isNewline)
        .first { $0.hasPrefix(prefix) }
        .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespacesAndNewlines) }
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

private func waitForConnectedURLCount(_ expectedCount: Int, transport: MockSignalTransport) async -> [URL] {
    for _ in 0..<100 {
        let connectedURLs = await transport.connectedURLs
        if connectedURLs.count >= expectedCount {
            return connectedURLs
        }

        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    return await transport.connectedURLs
}

private func waitForLocalTrackPublicationCount(_ expectedCount: Int, room: Room) async -> [LocalTrackPublication] {
    for _ in 0..<100 {
        let publications = room.localParticipant.trackPublications
        if publications.count == expectedCount {
            return publications
        }

        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    return room.localParticipant.trackPublications
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

private func waitForPublisherMediaStartupResult(_ room: Room) async -> PeerConnectionMediaStartupResult? {
    for _ in 0..<100 {
        await room.waitForPublisherMediaStartup()
        if let startup = room.lastPublisherMediaStartupResult {
            return startup
        }

        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    return room.lastPublisherMediaStartupResult
}

private func waitForSubscriberMediaStartupResult(_ room: Room) async -> PeerConnectionMediaStartupResult? {
    for _ in 0..<100 {
        await room.waitForSubscriberMediaStartup()
        if let startup = room.lastSubscriberMediaStartupResult {
            return startup
        }

        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    return room.lastSubscriberMediaStartupResult
}

private func waitForPublisherBandwidthEstimate(
    _ room: Room,
    ssrc: UInt32
) async -> MediaQualityEstimateSnapshot? {
    for _ in 0..<100 {
        if let snapshot = room.publisherBandwidthEstimateSnapshots.first(where: { $0.ssrc == ssrc }) {
            return snapshot
        }

        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    return room.publisherBandwidthEstimateSnapshots.first(where: { $0.ssrc == ssrc })
}

private func waitForSentDatagramCount(
    _ expectedCount: Int,
    transport: RoomMediaStartupDatagramTransport
) async -> [Data] {
    for _ in 0..<100 {
        let sentDatagrams = transport.sentDatagrams
        if sentDatagrams.count >= expectedCount {
            return sentDatagrams
        }

        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    return transport.sentDatagrams
}

private func waitForSubscriberReceiverReportSnapshots(
    _ room: Room,
    mediaSSRC: UInt32,
    receivedPackets: UInt32
) async -> [RTCPReceiverReportSnapshot] {
    for _ in 0..<100 {
        let snapshots = room.subscriberReceiverReportSnapshots
        if snapshots.contains(where: { $0.mediaSSRC == mediaSSRC && $0.receivedPackets >= receivedPackets }) {
            return snapshots
        }

        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    return room.subscriberReceiverReportSnapshots
}

private func waitForSubscriberAudioPlayoutScheduledBufferCount(_ room: Room, count: Int) async -> Int {
    for _ in 0..<100 {
        let scheduledBufferCount = room.subscriberAudioPlayoutScheduledBufferCount
        if scheduledBufferCount >= count {
            return scheduledBufferCount
        }

        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    return room.subscriberAudioPlayoutScheduledBufferCount
}

private func waitForSubscriberDecodedVideoFrameCount(_ room: Room, count: Int) async -> Int {
    for _ in 0..<100 {
        let decodedFrameCount = room.subscriberDecodedVideoFrameCount
        if decodedFrameCount >= count {
            return decodedFrameCount
        }

        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    return room.subscriberDecodedVideoFrameCount
}

private func waitForSubscriberRenderedVideoFrameCount(_ room: Room, count: Int) async -> Int {
    for _ in 0..<100 {
        let renderedFrameCount = room.subscriberRenderedVideoFrameCount
        if renderedFrameCount >= count {
            return renderedFrameCount
        }

        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    return room.subscriberRenderedVideoFrameCount
}

private func waitForRenderedVideoFrames(
    _ renderer: RecordingSubscriberVideoFrameRenderer,
    count: Int
) async -> [SubscriberVideoFrame] {
    for _ in 0..<100 {
        let frames = await renderer.frames
        if frames.count >= count {
            return frames
        }

        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    return await renderer.frames
}

private func waitForSubscriberMediaStartupError(_ room: Room) async -> (any Error)? {
    for _ in 0..<100 {
        if let error = room.lastSubscriberMediaStartupError {
            return error
        }

        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    return room.lastSubscriberMediaStartupError
}

private func waitForPublisherMediaStartupError(_ room: Room) async -> (any Error)? {
    for _ in 0..<100 {
        if let error = room.lastPublisherMediaStartupError {
            return error
        }

        try? await Task.sleep(nanoseconds: 10_000_000)
    }

    return room.lastPublisherMediaStartupError
}

private func makeStartedSubscriberRTCPFeedbackRoom(
    receiverReportPolicy: RTCPReceiverReportSchedulePolicy = .standard
) async throws -> (Room, RoomMediaStartupDatagramTransport) {
    let result = try await makeStartedSubscriberRTCPFeedbackRoomWithSignalTransport(
        receiverReportPolicy: receiverReportPolicy
    )
    return (result.room, result.datagramTransport)
}

private func makeStartedSubscriberRTCPFeedbackRoomWithSignalTransport(
    roomOptions: RoomOptions = RoomOptions(),
    receiverReportPolicy: RTCPReceiverReportSchedulePolicy = .standard
) async throws -> (room: Room, datagramTransport: RoomMediaStartupDatagramTransport, signalTransport: MockSignalTransport) {
    let frames = try [
        makeJoinResponse(),
        makeSubscriberOfferResponse(),
        makeSubscriberTrickleResponse(),
        makeSubscriberTrickleCompleteResponse(),
    ].map { SignalTransportFrame.binary(try SignalFrameCodec().encode($0)) }

    let signalTransport = MockSignalTransport(incomingFrames: frames)
    let localCandidate = ICECandidate(
        foundation: "subscriber-local",
        componentID: .rtp,
        transport: .udp,
        priority: ICECandidatePriority(type: .host, localPreference: 65_535).value,
        address: "192.0.2.11",
        port: 55001,
        type: .host
    )
    let datagramTransport = RoomMediaStartupDatagramTransport()
    let binder = DTLSSRTPMediaSessionBinder(
        datagramTransportFactory: RoomMediaStartupDatagramTransportFactory(transport: datagramTransport),
        handshaker: RoomMediaStartupDTLSHandshaker(
            result: try DTLSSRTPHandshakeResult(
                role: .client,
                exportedKeyingMaterial: roomMediaStartupExportedKeyingMaterial(),
                remoteFingerprint: DTLSSignature(hashFunction: "sha-256", value: "DD:EE:FF")
            )
        )
    )
    let room = Room(
        options: roomOptions,
        signalConnection: SignalConnection(transport: signalTransport),
        subscriberPeerConnection: PeerConnectionCoordinator(configuration: NativeWebRTCConfiguration(role: .subscriber)),
            subscriberMediaStartupConfiguration: RoomSubscriberMediaStartupConfiguration(
                localCandidates: { [localCandidate] },
                tieBreaker: 43,
                checker: RoomMediaStartupICEChecker(),
                binder: binder
            ),
            subscriberRTCPReceiverReportPolicy: receiverReportPolicy
        )

    try await room.connect(url: URL(string: "wss://example.test")!, token: "token")
    let startupResult = await waitForSubscriberMediaStartupResult(room)
    _ = try XCTUnwrap(startupResult)

    return (room, datagramTransport, signalTransport)
}

private func decodedSubscriberOutboundRTCPPackets(from datagrams: [Data]) async throws -> [RTCPPacket] {
    let datagramTransport = RoomMediaStartupDatagramTransport()
    let peerTransport = try DTLSSRTPMediaTransport(
        packetProtectionContext: DTLSSRTPPacketProtectionContext(
            keyMaterial: DTLSSRTPKeyMaterial(exportedKeyingMaterial: roomMediaStartupExportedKeyingMaterial()),
            role: .server
        ),
        datagramTransport: datagramTransport
    )

    for datagram in datagrams {
        datagramTransport.enqueueIncomingDatagram(datagram)
    }

    var packets: [RTCPPacket] = []
    for _ in datagrams {
        guard case let .rtcp(packet) = try await peerTransport.receive() else {
            XCTFail("Expected outbound subscriber RTCP packet.")
            continue
        }
        packets.append(packet)
    }

    return packets
}

private func protectedPublisherInboundRTCPDatagram(_ packet: RTCPPacket) async throws -> Data {
    let datagramTransport = RoomMediaStartupDatagramTransport()
    let peerTransport = try DTLSSRTPMediaTransport(
        packetProtectionContext: DTLSSRTPPacketProtectionContext(
            keyMaterial: DTLSSRTPKeyMaterial(exportedKeyingMaterial: roomMediaStartupExportedKeyingMaterial()),
            role: .client
        ),
        datagramTransport: datagramTransport
    )

    try await peerTransport.sendRTCP(packet)
    return try XCTUnwrap(datagramTransport.sentDatagrams.first)
}

private func protectedSubscriberInboundRTCPDatagram(_ packet: RTCPPacket) async throws -> Data {
    let datagramTransport = RoomMediaStartupDatagramTransport()
    let peerTransport = try DTLSSRTPMediaTransport(
        packetProtectionContext: DTLSSRTPPacketProtectionContext(
            keyMaterial: DTLSSRTPKeyMaterial(exportedKeyingMaterial: roomMediaStartupExportedKeyingMaterial()),
            role: .server
        ),
        datagramTransport: datagramTransport
    )

    try await peerTransport.sendRTCP(packet)
    return try XCTUnwrap(datagramTransport.sentDatagrams.first)
}

private func protectedSubscriberInboundRTPDatagram(_ packet: RTPPacket) async throws -> Data {
    let datagramTransport = RoomMediaStartupDatagramTransport()
    let peerTransport = try DTLSSRTPMediaTransport(
        packetProtectionContext: DTLSSRTPPacketProtectionContext(
            keyMaterial: DTLSSRTPKeyMaterial(exportedKeyingMaterial: roomMediaStartupExportedKeyingMaterial()),
            role: .server
        ),
        datagramTransport: datagramTransport
    )

    try await peerTransport.sendRTP(packet)
    return try XCTUnwrap(datagramTransport.sentDatagrams.first)
}

private func makeEncodedOpusPacket() throws -> OpusPacket {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
    buffer.frameLength = 960
    let channel = try XCTUnwrap(buffer.floatChannelData?[0])
    for frame in 0..<Int(buffer.frameLength) {
        channel[frame] = sin(Float(frame) * 0.01) * 0.1
    }

    return try OpusAudioConverterEncoder().encode(buffer)
}

private func makeEncodedH264Frame() throws -> H264EncodedFrame {
    let recorder = RoomH264EncodedFrameRecorder()
    let encoder = H264VideoToolboxEncoder(
        settings: H264EncoderSettings(
            width: 16,
            height: 16,
            framesPerSecond: 30,
            bitrate: 100_000
        )
    )

    do {
        try encoder.configure { frame in
            recorder.record(frame)
        }
        try encoder.encode(
            pixelBuffer: makeNV12PixelBuffer(width: 16, height: 16),
            presentationTimeStamp: CMTime(value: 1, timescale: 30),
            duration: CMTime(value: 1, timescale: 30)
        )
        try encoder.completeFrames()
    } catch let error as H264VideoToolboxEncoderError {
        throw XCTSkip("VideoToolbox H.264 encoder unavailable in this environment: \(error)")
    }

    for _ in 0..<100 {
        if let frame = recorder.frames.first {
            return frame
        }

        Thread.sleep(forTimeInterval: 0.01)
    }

    return try XCTUnwrap(recorder.frames.first)
}

private func makeNV12PixelBuffer(width: Int, height: Int) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        width,
        height,
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ] as CFDictionary,
        &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
        throw RoomH264TestError.pixelBufferCreationFailed(status)
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

    for plane in 0..<CVPixelBufferGetPlaneCount(pixelBuffer) {
        guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else {
            continue
        }
        let height = CVPixelBufferGetHeightOfPlane(pixelBuffer, plane)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
        memset(baseAddress, 0x80, height * bytesPerRow)
    }

    return pixelBuffer
}

private func roomMediaStartupExportedKeyingMaterial() -> Data {
    Data((0..<SRTPProtectionProfile.aes128CMHMACSHA180.exporterByteCount).map(UInt8.init))
}

private final class RoomH264EncodedFrameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var mutableFrames: [H264EncodedFrame] = []

    var frames: [H264EncodedFrame] {
        lock.withLock {
            mutableFrames
        }
    }

    func record(_ frame: H264EncodedFrame) {
        lock.withLock {
            mutableFrames.append(frame)
        }
    }
}

private enum RoomH264TestError: Error {
    case pixelBufferCreationFailed(CVReturn)
}

private actor RecordingSubscriberVideoFrameRenderer: SubscriberVideoFrameRenderer {
    private var mutableFrames: [SubscriberVideoFrame] = []

    var frames: [SubscriberVideoFrame] {
        mutableFrames
    }

    nonisolated func render(_ frame: SubscriberVideoFrame) {
        Task { [weak self] in
            await self?.record(frame)
        }
    }

    private func record(_ frame: SubscriberVideoFrame) {
        mutableFrames.append(frame)
    }
}

private actor PublisherRTCPRecorder {
    private var packets: [RTCPPacket] = []

    func record(_ packet: RTCPPacket) {
        packets.append(packet)
    }

    func waitForPacketCount(_ expectedCount: Int, attempts: Int = 100) async -> [RTCPPacket] {
        for _ in 0..<attempts {
            if packets.count >= expectedCount {
                return packets
            }

            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        return packets
    }
}

private actor SubscriberRTCPRecorder {
    private var packets: [RTCPPacket] = []

    func record(_ packet: RTCPPacket) {
        packets.append(packet)
    }

    func waitForPacketCount(_ expectedCount: Int, attempts: Int = 100) async -> [RTCPPacket] {
        for _ in 0..<attempts {
            if packets.count >= expectedCount {
                return packets
            }

            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        return packets
    }
}

private final class RoomMediaStartupICEChecker: ICEConnectivityChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var mutableCapturedConfiguration: ICEAgentConfiguration?

    var capturedConfiguration: ICEAgentConfiguration? {
        lock.withLock {
            mutableCapturedConfiguration
        }
    }

    func checkCandidatePair(
        _ pair: ICECandidatePair,
        configuration: ICEAgentConfiguration,
        nominate: Bool
    ) throws -> ICEConnectivityCheckResult {
        lock.withLock {
            mutableCapturedConfiguration = configuration
        }

        return ICEConnectivityCheckResult(
            mappedAddress: STUNMappedAddress(address: pair.local.address, port: pair.local.port),
            response: STUNMessage(type: .bindingSuccessResponse)
        )
    }
}

private final class RoomMediaStartupCountingICEChecker: ICEConnectivityChecking, @unchecked Sendable {
    private let lock = NSLock()
    private let consentChecksSucceed: Bool
    private var mutableConnectivityCheckCount = 0
    private var mutableConsentCheckCount = 0

    init(consentChecksSucceed: Bool) {
        self.consentChecksSucceed = consentChecksSucceed
    }

    func waitForConsentCheckCount(_ expectedCount: Int, attempts: Int = 100) async -> Int {
        for _ in 0..<attempts {
            let count = lock.withLock {
                mutableConsentCheckCount
            }
            if count >= expectedCount {
                return count
            }

            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        return lock.withLock {
            mutableConsentCheckCount
        }
    }

    func checkCandidatePair(
        _ pair: ICECandidatePair,
        configuration: ICEAgentConfiguration,
        nominate: Bool
    ) throws -> ICEConnectivityCheckResult {
        if nominate {
            lock.withLock {
                mutableConnectivityCheckCount += 1
            }
        } else {
            lock.withLock {
                mutableConsentCheckCount += 1
            }

            guard consentChecksSucceed else {
                throw ICEConnectivityCheckError.missingMappedAddress
            }
        }

        return ICEConnectivityCheckResult(
            mappedAddress: STUNMappedAddress(address: pair.local.address, port: pair.local.port),
            response: STUNMessage(type: .bindingSuccessResponse)
        )
    }
}

private final class RoomMediaStartupDatagramTransport: MediaDatagramTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var mutableSentDatagrams: [Data] = []
    private var mutableIncomingDatagrams: [Data] = []
    private var mutableReceiveContinuations: [UUID: CheckedContinuation<Data, Error>] = [:]

    var sentDatagrams: [Data] {
        lock.withLock {
            mutableSentDatagrams
        }
    }

    func send(_ datagram: Data) async throws {
        lock.withLock {
            mutableSentDatagrams.append(datagram)
        }
    }

    func enqueueIncomingDatagram(_ datagram: Data) {
        let continuation: CheckedContinuation<Data, Error>? = lock.withLock {
            if let id = mutableReceiveContinuations.keys.first,
               let continuation = mutableReceiveContinuations.removeValue(forKey: id) {
                return continuation
            }

            mutableIncomingDatagrams.append(datagram)
            return nil
        }

        continuation?.resume(returning: datagram)
    }

    func receive() async throws -> Data {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediateResult: Result<Data, Error>? = lock.withLock {
                    if Task.isCancelled {
                        return Result<Data, Error>.failure(CancellationError())
                    }

                    guard !mutableIncomingDatagrams.isEmpty else {
                        mutableReceiveContinuations[id] = continuation
                        return nil
                    }

                    return .success(mutableIncomingDatagrams.removeFirst())
                }

                if let immediateResult {
                    continuation.resume(with: immediateResult)
                }
            }
        } onCancel: {
            let continuation = lock.withLock {
                mutableReceiveContinuations.removeValue(forKey: id)
            }
            continuation?.resume(throwing: CancellationError())
        }
    }
}

private final class RoomMediaStartupDatagramTransportFactory: MediaDatagramTransportFactory, @unchecked Sendable {
    private let lock = NSLock()
    private let transport: RoomMediaStartupDatagramTransport
    private var mutableCapturedPair: ICECandidatePair?

    var capturedPair: ICECandidatePair? {
        lock.withLock {
            mutableCapturedPair
        }
    }

    init(transport: RoomMediaStartupDatagramTransport) {
        self.transport = transport
    }

    func makeTransport(selectedCandidatePair: ICECandidatePair) throws -> any MediaDatagramTransport {
        lock.withLock {
            mutableCapturedPair = selectedCandidatePair
        }
        return transport
    }
}

private final class RoomMediaStartupDTLSHandshaker: DTLSSRTPHandshaking, @unchecked Sendable {
    private let lock = NSLock()
    private let result: DTLSSRTPHandshakeResult
    private var mutableCapturedConfiguration: DTLSSRTPHandshakeConfiguration?

    var capturedConfiguration: DTLSSRTPHandshakeConfiguration? {
        lock.withLock {
            mutableCapturedConfiguration
        }
    }

    init(result: DTLSSRTPHandshakeResult) {
        self.result = result
    }

    func performHandshake(
        configuration: DTLSSRTPHandshakeConfiguration,
        transport: any MediaDatagramTransport
    ) async throws -> DTLSSRTPHandshakeResult {
        lock.withLock {
            mutableCapturedConfiguration = configuration
        }
        return result
    }
}

private final class RoomSTUNResponderSocket: @unchecked Sendable {
    let port: UInt16

    private let socketDescriptor: Int32
    private let lock = NSLock()
    private var mutableSourcePort: UInt16?

    init() throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else {
            throw SecureMediaTransportError.socketCreationFailed(errno)
        }

        do {
            var timeout = timeval(tv_sec: 1, tv_usec: 0)
            guard setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                &timeout,
                socklen_t(MemoryLayout<timeval>.size)
            ) == 0 else {
                throw SecureMediaTransportError.socketOptionFailed(errno)
            }

            var address = sockaddr_in(
                sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
                sin_family: sa_family_t(AF_INET),
                sin_port: 0,
                sin_addr: in_addr(s_addr: inet_addr("127.0.0.1")),
                sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
            )
            let bindResult = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bindResult == 0 else {
                throw SecureMediaTransportError.socketBindFailed(errno)
            }

            self.port = try Self.boundPort(socketDescriptor: descriptor)
            self.socketDescriptor = descriptor
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    deinit {
        Darwin.close(socketDescriptor)
    }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            try? respondOnce()
        }
    }

    func waitForSourcePort(timeout: TimeInterval = 1) -> UInt16? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let sourcePort {
                return sourcePort
            }
            Thread.sleep(forTimeInterval: 0.01)
        }

        return sourcePort
    }

    private var sourcePort: UInt16? {
        lock.withLock {
            mutableSourcePort
        }
    }

    private func respondOnce() throws {
        var buffer = [UInt8](repeating: 0, count: 1_500)
        var sourceStorage = sockaddr_storage()
        var sourceLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let receivedCount = withUnsafeMutablePointer(to: &sourceStorage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sourceAddress in
                Darwin.recvfrom(
                    socketDescriptor,
                    &buffer,
                    buffer.count,
                    0,
                    sourceAddress,
                    &sourceLength
                )
            }
        }
        guard receivedCount > 0 else {
            throw SecureMediaTransportError.socketReceiveFailed(errno)
        }

        let source = Self.ipv4SocketAddress(from: sourceStorage)
        let sourcePort = UInt16(bigEndian: source.sin_port)
        let sourceAddress = try Self.ipv4String(from: source.sin_addr)
        lock.withLock {
            mutableSourcePort = sourcePort
        }

        let request = try STUNMessage(decoding: Data(buffer.prefix(receivedCount)))
        let response = STUNMessage(
            type: .bindingSuccessResponse,
            transactionID: request.transactionID,
            attributes: [
                try .xorMappedAddressIPv4(
                    address: sourceAddress,
                    port: sourcePort,
                    transactionID: request.transactionID
                ),
            ]
        )
        let responseData = try response.encoded(includeFingerprint: true)
        var responseAddress = source
        let sentCount = responseData.withUnsafeBytes { responseBuffer in
            withUnsafePointer(to: &responseAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.sendto(
                        socketDescriptor,
                        responseBuffer.baseAddress,
                        responseData.count,
                        0,
                        socketAddress,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
        }
        guard sentCount == responseData.count else {
            throw SecureMediaTransportError.socketSendFailed(errno)
        }
    }

    private static func boundPort(socketDescriptor: Int32) throws -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.getsockname(socketDescriptor, socketAddress, &length)
            }
        }
        guard result == 0 else {
            throw SecureMediaTransportError.socketBindFailed(errno)
        }

        return UInt16(bigEndian: address.sin_port)
    }

    private static func ipv4SocketAddress(from storage: sockaddr_storage) -> sockaddr_in {
        var storage = storage
        return withUnsafePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
        }
    }

    private static func ipv4String(from address: in_addr) throws -> String {
        var address = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else {
            throw SecureMediaTransportError.unsupportedCandidateAddress("")
        }

        let endIndex = buffer.firstIndex(of: 0) ?? buffer.endIndex
        let bytes = buffer[..<endIndex].map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

private final class ICEServerRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var mutableICEServers: [ICEServer] = []

    var iceServers: [ICEServer] {
        lock.withLock {
            mutableICEServers
        }
    }

    func record(_ iceServers: [ICEServer]) {
        lock.withLock {
            mutableICEServers = iceServers
        }
    }
}

private final class SubscriberInboundSTUNResponderRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var mutableCredentials: ICECredentials?

    var credentials: ICECredentials? {
        lock.withLock {
            mutableCredentials
        }
    }

    func record(_ credentials: ICECredentials) {
        lock.withLock {
            mutableCredentials = credentials
        }
    }
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
