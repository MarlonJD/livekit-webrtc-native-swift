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

    func testPeerConnectionUpdatesICEServersFromSignalingConfiguration() {
        let coordinator = PeerConnectionCoordinator(configuration: .init(role: .subscriber))
        let iceServers = [
            ICEServer(
                urls: ["stun:stun.example.test:3478"],
                username: nil,
                credential: nil
            ),
            ICEServer(
                urls: ["turn:turn.example.test:3478?transport=udp"],
                username: "user",
                credential: "pass"
            ),
        ]

        coordinator.updateICEServers(iceServers)

        XCTAssertEqual(coordinator.configuration.iceServers, iceServers)
        XCTAssertEqual(coordinator.configuration.role, .subscriber)
    }

    func testPeerConnectionResetNegotiationStatePreservesConfigurationAndClearsRemoteState() throws {
        let coordinator = PeerConnectionCoordinator(configuration: .init(role: .publisher))
        let iceServers = [
            ICEServer(
                urls: ["turn:turn.example.test:3478?transport=udp"],
                username: "user",
                credential: "pass"
            ),
        ]
        let answer = """
        v=0
        o=- 1 1 IN IP4 127.0.0.1
        s=-
        t=0 0
        a=ice-ufrag:remote-ufrag
        a=ice-pwd:remote-password
        a=fingerprint:sha-256 00:11:22
        a=setup:active
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=mid:0
        a=rtcp-mux
        a=rtpmap:111 opus/48000/2
        """

        coordinator.updateICEServers(iceServers)
        try coordinator.applyPublisherAnswer(type: "answer", sdp: answer, id: 10)
        try coordinator.addRemoteICECandidate(
            candidateInitJSON: #"{"candidate":"candidate:remote 1 UDP 1694498815 203.0.113.9 6000 typ srflx","sdpMid":"0","sdpMLineIndex":0}"#,
            isFinal: true
        )

        XCTAssertEqual(coordinator.state, .connected)
        XCTAssertNotNil(coordinator.remoteAnswer)
        XCTAssertNotNil(coordinator.remoteICECredentials)
        XCTAssertNotNil(coordinator.remoteDTLSFingerprint)
        XCTAssertTrue(coordinator.isRemoteICEGatheringComplete)
        XCTAssertEqual(coordinator.remoteICECandidates.count, 1)

        coordinator.resetNegotiationState()

        XCTAssertEqual(coordinator.state, .new)
        XCTAssertEqual(coordinator.configuration.iceServers, iceServers)
        XCTAssertNil(coordinator.remoteAnswer)
        XCTAssertNil(coordinator.remoteICECredentials)
        XCTAssertNil(coordinator.remoteDTLSFingerprint)
        XCTAssertNil(coordinator.remoteDTLSSetupRole)
        XCTAssertFalse(coordinator.isRemoteICEGatheringComplete)
        XCTAssertTrue(coordinator.remoteICECandidates.isEmpty)
    }

    func testPeerConnectionRestartICERegeneratesLocalCredentialsAndClearsRemoteState() throws {
        let initialCredentials = ICECredentials(
            usernameFragment: "initial-local",
            password: "initial-password"
        )
        let coordinator = PeerConnectionCoordinator(configuration: .init(
            role: .publisher,
            iceCredentials: initialCredentials
        ))
        let iceServers = [
            ICEServer(
                urls: ["turn:turn.example.test:3478?transport=udp"],
                username: "user",
                credential: "pass"
            ),
        ]
        let answer = """
        v=0
        o=- 1 1 IN IP4 127.0.0.1
        s=-
        t=0 0
        a=ice-ufrag:remote-ufrag
        a=ice-pwd:remote-password
        a=fingerprint:sha-256 00:11:22
        a=setup:active
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=mid:0
        a=rtcp-mux
        a=rtpmap:111 opus/48000/2
        """

        coordinator.updateICEServers(iceServers)
        try coordinator.applyPublisherAnswer(type: "answer", sdp: answer, id: 10)
        try coordinator.addRemoteICECandidate(
            candidateInitJSON: #"{"candidate":"candidate:remote 1 UDP 1694498815 203.0.113.9 6000 typ srflx","sdpMid":"0","sdpMLineIndex":0}"#,
            isFinal: true
        )

        coordinator.restartICE()

        XCTAssertEqual(coordinator.state, .new)
        XCTAssertEqual(coordinator.configuration.iceServers, iceServers)
        XCTAssertNotEqual(coordinator.configuration.iceCredentials, initialCredentials)
        XCTAssertNil(coordinator.remoteAnswer)
        XCTAssertNil(coordinator.remoteICECredentials)
        XCTAssertNil(coordinator.remoteDTLSFingerprint)
        XCTAssertNil(coordinator.remoteDTLSSetupRole)
        XCTAssertFalse(coordinator.isRemoteICEGatheringComplete)
        XCTAssertTrue(coordinator.remoteICECandidates.isEmpty)
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

    func testSubscriberStoresRemoteDTLSParametersAndBuildsHandshakeConfiguration() throws {
        let coordinator = PeerConnectionCoordinator(configuration: .init(role: .subscriber))
        let offer = """
        v=0
        o=- 1 1 IN IP4 127.0.0.1
        s=-
        t=0 0
        a=ice-ufrag:remote-ufrag
        a=ice-pwd:remote-password
        a=fingerprint:sha-256 AA:BB:CC
        a=setup:actpass
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=mid:0
        a=rtcp-mux
        a=rtpmap:111 opus/48000/2
        """

        _ = try coordinator.makeSubscriberAnswer(for: offer)
        let configuration = try coordinator.makeDTLSSRTPHandshakeConfiguration()

        XCTAssertEqual(coordinator.remoteDTLSFingerprint, DTLSSignature(hashFunction: "sha-256", value: "AA:BB:CC"))
        XCTAssertEqual(coordinator.remoteDTLSSetupRole, .actpass)
        XCTAssertEqual(configuration.role, .client)
        XCTAssertEqual(configuration.remoteFingerprint, DTLSSignature(hashFunction: "sha-256", value: "AA:BB:CC"))
        XCTAssertEqual(configuration.useSRTExtension.protectionProfiles, [.aes128CMHMACSHA180])
    }

    func testPublisherAnswerActiveSetupMakesLocalDTLSServer() throws {
        let coordinator = PeerConnectionCoordinator(configuration: .init(role: .publisher))
        let answer = """
        v=0
        o=- 1 1 IN IP4 127.0.0.1
        s=-
        t=0 0
        a=ice-ufrag:remote-ufrag
        a=ice-pwd:remote-password
        a=fingerprint:sha-256 00:11:22
        a=setup:active
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=mid:0
        a=rtcp-mux
        a=rtpmap:111 opus/48000/2
        """

        try coordinator.applyPublisherAnswer(type: "answer", sdp: answer, id: 10)
        let configuration = try coordinator.makeDTLSSRTPHandshakeConfiguration()

        XCTAssertEqual(configuration.role, .server)
        XCTAssertEqual(configuration.remoteFingerprint, DTLSSignature(hashFunction: "sha-256", value: "00:11:22"))
    }

    func testPeerConnectionBuildsSecureMediaTransportFromNegotiatedAnswerAndICEPair() async throws {
        let fingerprint = DTLSSignature(hashFunction: "sha-256", value: "00:11:22")
        let coordinator = PeerConnectionCoordinator(configuration: .init(role: .publisher))
        let answer = """
        v=0
        o=- 1 1 IN IP4 127.0.0.1
        s=-
        t=0 0
        a=ice-ufrag:remote-ufrag
        a=ice-pwd:remote-password
        a=fingerprint:sha-256 00:11:22
        a=setup:active
        m=video 9 UDP/TLS/RTP/SAVPF 102
        a=mid:0
        a=rtcp-mux
        a=rtpmap:102 H264/90000
        """
        let datagrams = WebRTCMediaProfileMockDatagramTransport()
        let datagramFactory = WebRTCMediaProfileDatagramTransportFactory(transport: datagrams)
        let handshaker = WebRTCMediaProfileDTLSHandshaker(
            result: try DTLSSRTPHandshakeResult(
                role: .server,
                exportedKeyingMaterial: Data(
                    (0..<SRTPProtectionProfile.aes128CMHMACSHA180.exporterByteCount).map(UInt8.init)
                ),
                remoteFingerprint: fingerprint
            )
        )
        let binder = DTLSSRTPMediaSessionBinder(
            datagramTransportFactory: datagramFactory,
            handshaker: handshaker
        )

        try coordinator.applyPublisherAnswer(type: "answer", sdp: answer, id: 10)
        let transport = try await coordinator.makeSecureMediaTransport(
            selectedCandidatePair: candidatePair(state: .succeeded, nominated: true),
            binder: binder
        )
        try await transport.sendRTP(
            RTPPacket(
                marker: true,
                payloadType: 102,
                sequenceNumber: 7,
                timestamp: 90_000,
                ssrc: 0x1122_3344,
                payload: Data([0xAA, 0xBB])
            )
        )

        let sentDatagrams = await datagrams.sentDatagramsSnapshot()
        XCTAssertEqual(handshaker.capturedConfiguration?.role, .server)
        XCTAssertEqual(handshaker.capturedConfiguration?.remoteFingerprint, fingerprint)
        XCTAssertEqual(datagramFactory.capturedPair?.remote.foundation, "remote")
        XCTAssertEqual(sentDatagrams.count, 1)
    }

    func testPeerConnectionRunsICEAndStartsSecureMediaTransport() async throws {
        let fingerprint = DTLSSignature(hashFunction: "sha-256", value: "00:11:22")
        let coordinator = PeerConnectionCoordinator(
            configuration: .init(
                role: .publisher,
                iceCredentials: ICECredentials(usernameFragment: "local-ufrag", password: "local-password")
            )
        )
        let answer = """
        v=0
        o=- 1 1 IN IP4 127.0.0.1
        s=-
        t=0 0
        a=ice-ufrag:remote-ufrag
        a=ice-pwd:remote-password
        a=fingerprint:sha-256 00:11:22
        a=setup:active
        m=video 9 UDP/TLS/RTP/SAVPF 102
        a=mid:0
        a=rtcp-mux
        a=rtpmap:102 H264/90000
        """
        let datagrams = WebRTCMediaProfileMockDatagramTransport()
        let datagramFactory = WebRTCMediaProfileDatagramTransportFactory(transport: datagrams)
        let handshaker = WebRTCMediaProfileDTLSHandshaker(
            result: try DTLSSRTPHandshakeResult(
                role: .server,
                exportedKeyingMaterial: Data(
                    (0..<SRTPProtectionProfile.aes128CMHMACSHA180.exporterByteCount).map(UInt8.init)
                ),
                remoteFingerprint: fingerprint
            )
        )
        let binder = DTLSSRTPMediaSessionBinder(
            datagramTransportFactory: datagramFactory,
            handshaker: handshaker
        )
        let checker = CapturingICEConnectivityChecker()

        try coordinator.applyPublisherAnswer(type: "answer", sdp: answer, id: 10)
        try coordinator.addRemoteICECandidate(
            candidateInitJSON: #"{"candidate":"candidate:remote 1 UDP 1694498815 203.0.113.10 6000 typ srflx","sdpMid":"0","sdpMLineIndex":0}"#,
            isFinal: false
        )
        let result = try await coordinator.startSecureMediaTransport(
            localCandidates: [candidatePair(state: .succeeded, nominated: true).local],
            iceRole: .controlling,
            tieBreaker: 99,
            checker: checker,
            binder: binder
        )
        try await result.transport.sendRTP(
            RTPPacket(
                marker: true,
                payloadType: 102,
                sequenceNumber: 8,
                timestamp: 90_000,
                ssrc: 0x1122_3344,
                payload: Data([0xCC])
            )
        )

        let sentDatagrams = await datagrams.sentDatagramsSnapshot()
        XCTAssertEqual(result.iceSummary.state, .connected)
        XCTAssertEqual(result.iceSummary.checkedPairCount, 1)
        XCTAssertEqual(result.selectedCandidatePair.remote.foundation, "remote")
        XCTAssertEqual(checker.capturedConfiguration?.localCredentials.usernameFragment, "local-ufrag")
        XCTAssertEqual(checker.capturedConfiguration?.remoteCredentials.usernameFragment, "remote-ufrag")
        XCTAssertEqual(handshaker.capturedConfiguration?.remoteFingerprint, fingerprint)
        XCTAssertEqual(datagramFactory.capturedPair?.remote.foundation, "remote")
        XCTAssertEqual(sentDatagrams.count, 1)
    }

    func testPeerConnectionStartSecureMediaTransportRequiresSelectedICEPair() async throws {
        let fingerprint = DTLSSignature(hashFunction: "sha-256", value: "00:11:22")
        let coordinator = PeerConnectionCoordinator(configuration: .init(role: .publisher))
        let answer = """
        v=0
        o=- 1 1 IN IP4 127.0.0.1
        s=-
        t=0 0
        a=ice-ufrag:remote-ufrag
        a=ice-pwd:remote-password
        a=fingerprint:sha-256 00:11:22
        a=setup:active
        m=video 9 UDP/TLS/RTP/SAVPF 102
        a=mid:0
        a=rtcp-mux
        a=rtpmap:102 H264/90000
        """
        let datagramFactory = WebRTCMediaProfileDatagramTransportFactory(
            transport: WebRTCMediaProfileMockDatagramTransport()
        )
        let binder = DTLSSRTPMediaSessionBinder(
            datagramTransportFactory: datagramFactory,
            handshaker: WebRTCMediaProfileDTLSHandshaker(
                result: try DTLSSRTPHandshakeResult(
                    role: .server,
                    exportedKeyingMaterial: Data(
                        (0..<SRTPProtectionProfile.aes128CMHMACSHA180.exporterByteCount).map(UInt8.init)
                    ),
                    remoteFingerprint: fingerprint
                )
            )
        )

        try coordinator.applyPublisherAnswer(type: "answer", sdp: answer, id: 10)

        do {
            _ = try await coordinator.startSecureMediaTransport(
                localCandidates: [candidatePair(state: .succeeded, nominated: true).local],
                iceRole: .controlling,
                tieBreaker: 99,
                checker: CapturingICEConnectivityChecker(),
                binder: binder
            )
            XCTFail("Expected selected ICE candidate pair requirement.")
        } catch {
            XCTAssertEqual(error as? PeerConnectionNegotiationError, .missingSelectedICECandidatePair)
        }
        XCTAssertNil(datagramFactory.capturedPair)
    }

    func testPeerConnectionRequiresRemoteDTLSFingerprintForHandshakeConfiguration() throws {
        let coordinator = PeerConnectionCoordinator(configuration: .init(role: .subscriber))
        let offer = """
        v=0
        o=- 1 1 IN IP4 127.0.0.1
        s=-
        t=0 0
        a=ice-ufrag:remote-ufrag
        a=ice-pwd:remote-password
        a=setup:actpass
        m=audio 9 UDP/TLS/RTP/SAVPF 111
        a=mid:0
        a=rtcp-mux
        a=rtpmap:111 opus/48000/2
        """

        _ = try coordinator.makeSubscriberAnswer(for: offer)

        XCTAssertThrowsError(try coordinator.makeDTLSSRTPHandshakeConfiguration()) { error in
            XCTAssertEqual(error as? PeerConnectionNegotiationError, .missingRemoteDTLSFingerprint)
        }
    }
}

private actor WebRTCMediaProfileMockDatagramTransport: MediaDatagramTransport {
    private var sentDatagrams: [Data] = []

    func sentDatagramsSnapshot() -> [Data] {
        sentDatagrams
    }

    func send(_ datagram: Data) async throws {
        sentDatagrams.append(datagram)
    }

    func receive() async throws -> Data {
        Data()
    }
}

private final class WebRTCMediaProfileDatagramTransportFactory: MediaDatagramTransportFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var mutableCapturedPair: ICECandidatePair?
    private let transport: WebRTCMediaProfileMockDatagramTransport

    var capturedPair: ICECandidatePair? {
        lock.withLock {
            mutableCapturedPair
        }
    }

    init(transport: WebRTCMediaProfileMockDatagramTransport) {
        self.transport = transport
    }

    func makeTransport(selectedCandidatePair: ICECandidatePair) throws -> any MediaDatagramTransport {
        lock.withLock {
            mutableCapturedPair = selectedCandidatePair
        }
        return transport
    }
}

private final class WebRTCMediaProfileDTLSHandshaker: DTLSSRTPHandshaking, @unchecked Sendable {
    private let lock = NSLock()
    private var mutableCapturedConfiguration: DTLSSRTPHandshakeConfiguration?
    private let result: DTLSSRTPHandshakeResult

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

private func candidatePair(state: ICECandidatePairState, nominated: Bool) -> ICECandidatePair {
    ICECandidatePair(
        local: ICECandidate(
            foundation: "local",
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(type: .host, localPreference: 65_535).value,
            address: "192.0.2.10",
            port: 50_000,
            type: .host
        ),
        remote: ICECandidate(
            foundation: "remote",
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(type: .serverReflexive, localPreference: 100).value,
            address: "203.0.113.10",
            port: 60_000,
            type: .serverReflexive
        ),
        isControlling: true,
        state: state,
        nominated: nominated
    )
}
