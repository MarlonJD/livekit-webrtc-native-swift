import XCTest
@testable import LiveKitNativeWebRTC

final class WebRTCMediaProfileTests: XCTestCase {
    func testTinyProfilePublishesH264AndReceivesH264PlusVP8() {
        let profile = NativeWebRTCMediaProfile.liveKitTiny

        XCTAssertEqual(profile.publishVideoCodecs, [.h264])
        XCTAssertEqual(profile.receiveVideoCodecs, [.h264, .vp8])
        XCTAssertEqual(profile.publishAudioCodecs, [.opus])
        XCTAssertEqual(profile.receiveAudioCodecs, [.opus])
        XCTAssertEqual(profile.dataChannelCodec, .webRTCDataChannel)
    }

    func testPeerConnectionCapabilitiesPreferTinyPublishProfile() {
        let coordinator = PeerConnectionCoordinator(configuration: .init(role: .publisher))

        XCTAssertEqual(
            coordinator.localCapabilities,
            [
                SDPCodecCapability(kind: .audio, codec: .opus, clockRate: 48_000, channels: 1),
                SDPCodecCapability(kind: .video, codec: .h264, clockRate: 90_000),
                SDPCodecCapability(kind: .application, codec: .webRTCDataChannel, clockRate: 0),
            ]
        )
    }

    func testDTLSFingerprintUsesSHA256ColonSeparatedFormat() {
        let fingerprint = DTLSSignature.sha256Fingerprint(for: Data("livekit-native".utf8))

        XCTAssertEqual(fingerprint.hashFunction, "sha-256")
        XCTAssertEqual(fingerprint.value.split(separator: ":").count, 32)
        XCTAssertTrue(fingerprint.value.allSatisfy { character in
            character == ":" || character.isHexDigit
        })
    }

    func testDefaultPeerConnectionConfigurationHasDTLSFingerprint() {
        let configuration = NativeWebRTCConfiguration(role: .subscriber)

        XCTAssertEqual(configuration.dtlsFingerprint.hashFunction, "sha-256")
        XCTAssertEqual(configuration.dtlsFingerprint.value.split(separator: ":").count, 32)
    }

    func testPeerConnectionBuildsChecklistFromParsedRemoteICECandidates() throws {
        let coordinator = PeerConnectionCoordinator(configuration: .init(role: .subscriber))
        try coordinator.addRemoteICECandidate(
            candidateInitJSON: #"{"candidate":"candidate:remote 1 UDP 1694498815 203.0.113.9 6000 typ srflx","sdpMid":"0","sdpMLineIndex":0}"#,
            isFinal: false
        )
        let local = ICECandidate(
            foundation: "local",
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(type: .host, localPreference: 65_535).value,
            address: "192.0.2.10",
            port: 5000,
            type: .host
        )

        let checklist = coordinator.makeCandidateChecklist(
            localCandidates: [local],
            isControlling: false
        )

        XCTAssertEqual(coordinator.parsedRemoteICECandidates.count, 1)
        XCTAssertEqual(checklist.pairs.count, 1)
        XCTAssertEqual(checklist.pairs.first?.remote.address, "203.0.113.9")
    }

    func testPeerConnectionBuildsICEAgentFromRemoteCredentialsAndCandidates() async throws {
        let coordinator = PeerConnectionCoordinator(
            configuration: .init(
                role: .subscriber,
                iceCredentials: ICECredentials(usernameFragment: "local-ufrag", password: "local-password")
            )
        )
        let offer = """
        v=0
        o=- 1 1 IN IP4 127.0.0.1
        s=-
        t=0 0
        a=ice-ufrag:remote-ufrag
        a=ice-pwd:remote-password
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=mid:0
        a=setup:actpass
        a=rtcp-mux
        a=rtpmap:111 opus/48000/2
        """
        _ = try coordinator.makeSubscriberAnswer(for: offer)
        try coordinator.addRemoteICECandidate(
            candidateInitJSON: #"{"candidate":"candidate:remote 1 UDP 1694498815 203.0.113.9 6000 typ srflx","sdpMid":"0","sdpMLineIndex":0}"#,
            isFinal: false
        )
        let local = ICECandidate(
            foundation: "local",
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(type: .host, localPreference: 65_535).value,
            address: "192.0.2.10",
            port: 5000,
            type: .host
        )
        let checker = CapturingICEConnectivityChecker()

        let agent = try coordinator.makeICEAgent(
            localCandidates: [local],
            role: .controlling,
            tieBreaker: 1,
            checker: checker
        )
        let summary = await agent.performConnectivityChecks()
        let checklist = await agent.checklist

        XCTAssertEqual(coordinator.remoteICECredentials?.usernameFragment, "remote-ufrag")
        XCTAssertEqual(coordinator.remoteICECredentials?.password, "remote-password")
        XCTAssertEqual(checklist.pairs.count, 1)
        XCTAssertEqual(summary.state, .connected)
        XCTAssertEqual(checker.capturedConfiguration?.localCredentials.usernameFragment, "local-ufrag")
        XCTAssertEqual(checker.capturedConfiguration?.remoteCredentials.usernameFragment, "remote-ufrag")
    }

    func testPeerConnectionRequiresRemoteICECredentialsBeforeBuildingAgent() throws {
        let coordinator = PeerConnectionCoordinator(configuration: .init(role: .subscriber))
        let local = ICECandidate(
            foundation: "local",
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(type: .host, localPreference: 65_535).value,
            address: "192.0.2.10",
            port: 5000,
            type: .host
        )

        XCTAssertThrowsError(
            try coordinator.makeICEAgent(
                localCandidates: [local],
                role: .controlling,
                tieBreaker: 1,
                checker: CapturingICEConnectivityChecker()
            )
        ) { error in
            XCTAssertEqual(error as? PeerConnectionNegotiationError, .missingRemoteICECredentials)
        }
    }
}

private final class CapturingICEConnectivityChecker: ICEConnectivityChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var mutableCapturedConfiguration: ICEAgentConfiguration?

    var capturedConfiguration: ICEAgentConfiguration? {
        lock.lock()
        defer { lock.unlock() }
        return mutableCapturedConfiguration
    }

    func checkCandidatePair(
        _ pair: ICECandidatePair,
        configuration: ICEAgentConfiguration,
        nominate: Bool
    ) throws -> ICEConnectivityCheckResult {
        lock.lock()
        mutableCapturedConfiguration = configuration
        lock.unlock()

        let transactionID = try STUNTransactionID(bytes: Array(repeating: 13, count: 12))
        return ICEConnectivityCheckResult(
            mappedAddress: STUNMappedAddress(address: pair.remote.address, port: pair.remote.port),
            response: STUNMessage(type: .bindingSuccessResponse, transactionID: transactionID)
        )
    }
}
