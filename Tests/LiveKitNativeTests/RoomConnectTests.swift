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

private func makeJoinResponse() -> Livekit_SignalResponse {
    var localParticipant = Livekit_ParticipantInfo()
    localParticipant.sid = "PA_local"
    localParticipant.identity = "marlon"
    localParticipant.name = "Marlon"
    localParticipant.attributes = ["role": "host"]

    var remoteParticipant = Livekit_ParticipantInfo()
    remoteParticipant.sid = "PA_alice"
    remoteParticipant.identity = "alice"
    remoteParticipant.name = "Alice"
    remoteParticipant.metadata = "remote-metadata"
    remoteParticipant.tracks = [makeRemoteCameraTrack()]

    var join = Livekit_JoinResponse()
    join.participant = localParticipant
    join.otherParticipants = [remoteParticipant]

    var response = Livekit_SignalResponse()
    response.join = join
    return response
}

private func makeRemoteCameraTrack() -> Livekit_TrackInfo {
    var track = Livekit_TrackInfo()
    track.sid = "TR_camera"
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

private func makeLeaveResponse() -> Livekit_SignalResponse {
    var leave = Livekit_LeaveRequest()
    leave.action = .disconnect

    var response = Livekit_SignalResponse()
    response.leave = leave
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
