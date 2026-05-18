import Foundation
import Darwin
import XCTest
@testable import LiveKitNativeWebRTC

final class SecureMediaTransportTests: XCTestCase {
    func testSendsProtectedRTPDatagramAndPeerReceivesPlainRTP() async throws {
        let clientDatagrams = MockMediaDatagramTransport()
        let serverDatagrams = MockMediaDatagramTransport()
        let client = try DTLSSRTPMediaTransport(
            packetProtectionContext: packetProtectionContext(role: .client),
            datagramTransport: clientDatagrams
        )
        let server = try DTLSSRTPMediaTransport(
            packetProtectionContext: packetProtectionContext(role: .server),
            datagramTransport: serverDatagrams
        )
        let packet = rtp(sequenceNumber: 17, payload: Data((0..<48).map(UInt8.init)))

        try await client.sendRTP(packet)
        let sentDatagrams = await clientDatagrams.sentDatagramsSnapshot()
        let protected = try XCTUnwrap(sentDatagrams.first)
        await serverDatagrams.enqueue(protected)

        let received = try await server.receive()

        XCTAssertNotEqual(protected, packet.encoded())
        XCTAssertEqual(protected.count, packet.encoded().count + SRTPProtectedPacket.defaultAuthenticationTagLength)
        XCTAssertEqual(received, .rtp(packet))
    }

    func testSendsProtectedRTCPDatagramAndPeerReceivesPlainRTCP() async throws {
        let clientDatagrams = MockMediaDatagramTransport()
        let serverDatagrams = MockMediaDatagramTransport()
        let client = try DTLSSRTPMediaTransport(
            packetProtectionContext: packetProtectionContext(role: .client),
            datagramTransport: clientDatagrams
        )
        let server = try DTLSSRTPMediaTransport(
            packetProtectionContext: packetProtectionContext(role: .server),
            datagramTransport: serverDatagrams
        )
        let packet = rtcp()

        try await client.sendRTCP(packet)
        let sentDatagrams = await clientDatagrams.sentDatagramsSnapshot()
        let protected = try XCTUnwrap(sentDatagrams.first)
        let encodedSRTCP = try SRTCPPacket(decoding: protected)
        await serverDatagrams.enqueue(protected)

        let received = try await server.receive()

        XCTAssertTrue(encodedSRTCP.index.isEncrypted)
        XCTAssertEqual(encodedSRTCP.authenticationTag.count, SRTCPPacket.defaultAuthenticationTagLength)
        XCTAssertEqual(received, .rtcp(packet))
    }

    func testIncomingRTPReplayIsRejected() async throws {
        let clientDatagrams = MockMediaDatagramTransport()
        let serverDatagrams = MockMediaDatagramTransport()
        let client = try DTLSSRTPMediaTransport(
            packetProtectionContext: packetProtectionContext(role: .client),
            datagramTransport: clientDatagrams
        )
        let server = try DTLSSRTPMediaTransport(
            packetProtectionContext: packetProtectionContext(role: .server),
            datagramTransport: serverDatagrams
        )

        try await client.sendRTP(rtp(sequenceNumber: 33, payload: Data([0x01])))
        let sentDatagrams = await clientDatagrams.sentDatagramsSnapshot()
        let protected = try XCTUnwrap(sentDatagrams.first)
        await serverDatagrams.enqueue(protected)
        await serverDatagrams.enqueue(protected)

        _ = try await server.receive()
        do {
            _ = try await server.receive()
            XCTFail("Expected replay rejection")
        } catch {
            XCTAssertEqual(error as? SRTPError, .replayedPacket)
        }
    }

    func testRTPRolloverCounterIsTrackedAcrossTransportBoundary() async throws {
        let clientDatagrams = MockMediaDatagramTransport()
        let serverDatagrams = MockMediaDatagramTransport()
        let client = try DTLSSRTPMediaTransport(
            packetProtectionContext: packetProtectionContext(role: .client),
            datagramTransport: clientDatagrams
        )
        let server = try DTLSSRTPMediaTransport(
            packetProtectionContext: packetProtectionContext(role: .server),
            datagramTransport: serverDatagrams
        )
        let beforeWrap = rtp(sequenceNumber: UInt16.max, payload: Data([0xAA]))
        let afterWrap = rtp(sequenceNumber: 0, payload: Data([0xBB]))

        try await client.sendRTP(beforeWrap)
        try await client.sendRTP(afterWrap)
        let protected = await clientDatagrams.sentDatagramsSnapshot()
        XCTAssertEqual(protected.count, 2)
        await serverDatagrams.enqueue(protected[0])
        await serverDatagrams.enqueue(protected[1])

        let firstReceived = try await server.receive()
        let secondReceived = try await server.receive()
        XCTAssertEqual(firstReceived, .rtp(beforeWrap))
        XCTAssertEqual(secondReceived, .rtp(afterWrap))
    }

    func testRejectsTooShortIncomingDatagram() async throws {
        let datagrams = MockMediaDatagramTransport()
        let transport = try DTLSSRTPMediaTransport(
            packetProtectionContext: packetProtectionContext(role: .server),
            datagramTransport: datagrams
        )
        await datagrams.enqueue(Data([0x80]))

        do {
            _ = try await transport.receive()
            XCTFail("Expected short datagram rejection")
        } catch {
            XCTAssertEqual(error as? SecureMediaTransportError, .packetTooShort)
        }
    }

    func testClosedMediaTransportRejectsSendAndReceive() async throws {
        let datagrams = MockMediaDatagramTransport()
        let transport = try DTLSSRTPMediaTransport(
            packetProtectionContext: packetProtectionContext(role: .client),
            datagramTransport: datagrams
        )

        await transport.close()

        do {
            try await transport.sendRTP(rtp(sequenceNumber: 1, payload: Data([0x01])))
            XCTFail("Expected closed RTP send to fail.")
        } catch {
            XCTAssertEqual(error as? SecureMediaTransportError, .transportClosed)
        }

        do {
            try await transport.sendRTCP(rtcp())
            XCTFail("Expected closed RTCP send to fail.")
        } catch {
            XCTAssertEqual(error as? SecureMediaTransportError, .transportClosed)
        }

        do {
            _ = try await transport.receive()
            XCTFail("Expected closed receive to fail.")
        } catch {
            XCTAssertEqual(error as? SecureMediaTransportError, .transportClosed)
        }
    }

    func testBuildsTransportOnlyForSucceededNominatedICEPair() async throws {
        let clientDatagrams = MockMediaDatagramTransport()
        let serverDatagrams = MockMediaDatagramTransport()
        let client = try DTLSSRTPMediaTransport(
            selectedCandidatePair: candidatePair(state: .succeeded, nominated: true),
            keyMaterial: keyMaterial(),
            role: .client,
            datagramTransport: clientDatagrams
        )
        let server = try DTLSSRTPMediaTransport(
            selectedCandidatePair: candidatePair(state: .succeeded, nominated: true),
            keyMaterial: keyMaterial(),
            role: .server,
            datagramTransport: serverDatagrams
        )
        let packet = rtp(sequenceNumber: 91, payload: Data([0xCA, 0xFE]))

        try await client.sendRTP(packet)
        let sentDatagrams = await clientDatagrams.sentDatagramsSnapshot()
        let protected = try XCTUnwrap(sentDatagrams.first)
        await serverDatagrams.enqueue(protected)

        let received = try await server.receive()

        XCTAssertEqual(received, .rtp(packet))
    }

    func testRejectsSecureTransportWithoutNominatedICEPair() {
        XCTAssertThrowsError(
            try DTLSSRTPMediaTransport(
                selectedCandidatePair: candidatePair(state: .succeeded, nominated: false),
                keyMaterial: keyMaterial(),
                role: .client,
                datagramTransport: MockMediaDatagramTransport()
            )
        ) { error in
            XCTAssertEqual(error as? SecureMediaTransportError, .candidatePairNotNominated)
        }
    }

    func testRejectsSecureTransportWithoutSucceededICEPair() {
        XCTAssertThrowsError(
            try DTLSSRTPMediaTransport(
                selectedCandidatePair: candidatePair(state: .inProgress, nominated: true),
                keyMaterial: keyMaterial(),
                role: .client,
                datagramTransport: MockMediaDatagramTransport()
            )
        ) { error in
            XCTAssertEqual(error as? SecureMediaTransportError, .candidatePairNotSucceeded)
        }
    }

    func testUDPMediaDatagramTransportSendsLoopbackDatagram() async throws {
        let clientPort = try availableUDPPort()
        let serverPort = try availableUDPPort()
        let client = try UDPMediaDatagramTransport(
            localCandidate: loopbackCandidate(foundation: "client", port: clientPort),
            remoteCandidate: loopbackCandidate(foundation: "server", port: serverPort),
            receiveTimeoutMilliseconds: 250
        )
        let server = try UDPMediaDatagramTransport(
            localCandidate: loopbackCandidate(foundation: "server", port: serverPort),
            remoteCandidate: loopbackCandidate(foundation: "client", port: clientPort),
            receiveTimeoutMilliseconds: 250
        )
        let datagram = Data([0x01, 0x02, 0x03])

        try await client.send(datagram)
        let received = try await server.receive()

        XCTAssertEqual(received, datagram)
    }

    func testLocalICEUDPSocketBuildsCandidateFromBoundPort() throws {
        let socket = try LocalICEUDPSocket(
            bindAddress: "127.0.0.1",
            port: 0,
            receiveTimeoutMilliseconds: 250
        )
        let candidate = socket.hostCandidate(
            foundation: "local",
            advertisedAddress: "127.0.0.1",
            localPreference: 99
        )

        XCTAssertGreaterThan(socket.localPort, 0)
        XCTAssertEqual(candidate.foundation, "local")
        XCTAssertEqual(candidate.address, "127.0.0.1")
        XCTAssertEqual(candidate.port, socket.localPort)
        XCTAssertEqual(candidate.transport, .udp)
        XCTAssertEqual(candidate.componentID, .rtp)
        XCTAssertEqual(candidate.type, .host)
        XCTAssertEqual(
            candidate.priority,
            ICECandidatePriority(type: .host, localPreference: 99).value
        )
    }

    func testLocalICEUDPSocketCandidateFactoryUsesOneBoundSocketForHostAddresses() throws {
        let candidateSockets = try LocalICEUDPSocketCandidate.hostCandidates(
            from: [
                ICEInterfaceAddress(name: "lo0", address: "127.0.0.1", localPreference: 100),
                ICEInterfaceAddress(name: "lo0-alias", address: "127.0.0.2", localPreference: 99),
            ],
            bindAddress: "127.0.0.1",
            receiveTimeoutMilliseconds: 250
        )

        XCTAssertEqual(candidateSockets.count, 2)
        XCTAssertTrue(candidateSockets[0].socket === candidateSockets[1].socket)
        XCTAssertGreaterThan(candidateSockets[0].socket.localPort, 0)
        XCTAssertEqual(candidateSockets.map(\.candidate.foundation), ["1", "2"])
        XCTAssertEqual(candidateSockets.map(\.candidate.address), ["127.0.0.1", "127.0.0.2"])
        XCTAssertEqual(candidateSockets.map(\.candidate.port), [
            candidateSockets[0].socket.localPort,
            candidateSockets[0].socket.localPort,
        ])
        XCTAssertEqual(candidateSockets[0].candidate.priority, ICECandidatePriority(
            type: .host,
            localPreference: 100
        ).value)
        XCTAssertEqual(candidateSockets[1].candidate.priority, ICECandidatePriority(
            type: .host,
            localPreference: 99
        ).value)
    }

    func testLocalICEUDPSocketCandidateFactoryReturnsNoCandidatesForNoAddresses() throws {
        let candidateSockets = try LocalICEUDPSocketCandidate.hostCandidates(
            from: [],
            bindAddress: "127.0.0.1",
            receiveTimeoutMilliseconds: 250
        )

        XCTAssertTrue(candidateSockets.isEmpty)
    }

    func testLocalICEUDPSocketMediaFactoryReusesBoundSocket() async throws {
        let clientSocket = try LocalICEUDPSocket(
            bindAddress: "127.0.0.1",
            port: 0,
            receiveTimeoutMilliseconds: 250
        )
        let serverSocket = try LocalICEUDPSocket(
            bindAddress: "127.0.0.1",
            port: 0,
            receiveTimeoutMilliseconds: 250
        )
        let clientCandidate = clientSocket.hostCandidate(
            foundation: "client",
            advertisedAddress: "127.0.0.1"
        )
        let serverCandidate = serverSocket.hostCandidate(
            foundation: "server",
            advertisedAddress: "127.0.0.1",
            localPreference: 100
        )
        let selectedPair = ICECandidatePair(
            local: clientCandidate,
            remote: serverCandidate,
            isControlling: true,
            state: .succeeded,
            nominated: true
        )
        let clientTransport = try LocalICEUDPSocketMediaDatagramTransportFactory(
            candidates: [
                LocalICEUDPSocketCandidate(candidate: clientCandidate, socket: clientSocket),
            ]
        ).makeTransport(selectedCandidatePair: selectedPair)
        let serverTransport = LocalICEUDPSocketMediaDatagramTransport(
            socket: serverSocket,
            remoteCandidate: clientCandidate
        )
        let datagram = Data([0x01, 0x02, 0x03, 0x04])

        try await clientTransport.send(datagram)
        let received = try await serverTransport.receive()

        XCTAssertEqual(received, datagram)
    }

    func testLocalICEUDPSocketCandidateStoreReusesSocketForServerReflexiveCandidate() async throws {
        let clientSocket = try LocalICEUDPSocket(
            bindAddress: "127.0.0.1",
            port: 0,
            receiveTimeoutMilliseconds: 250
        )
        let serverSocket = try LocalICEUDPSocket(
            bindAddress: "127.0.0.1",
            port: 0,
            receiveTimeoutMilliseconds: 250
        )
        let hostCandidate = clientSocket.hostCandidate(
            foundation: "client",
            advertisedAddress: "127.0.0.1"
        )
        let reflexiveCandidate = ICECandidate(
            foundation: "client-srflx-1",
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(
                type: .serverReflexive,
                localPreference: hostCandidate.localPreference
            ).value,
            address: "203.0.113.60",
            port: 61_000,
            type: .serverReflexive
        )
        let serverCandidate = serverSocket.hostCandidate(
            foundation: "server",
            advertisedAddress: "127.0.0.1"
        )
        let store = LocalICEUDPSocketCandidateStore(
            candidates: [
                LocalICEUDPSocketCandidate(candidate: hostCandidate, socket: clientSocket),
            ]
        )
        store.add([
            LocalICEUDPSocketCandidate(candidate: reflexiveCandidate, socket: clientSocket),
        ])
        let selectedPair = ICECandidatePair(
            local: reflexiveCandidate,
            remote: serverCandidate,
            isControlling: true,
            state: .succeeded,
            nominated: true
        )
        let transport = try LocalICEUDPSocketMediaDatagramTransportFactory(
            candidateStore: store
        ).makeTransport(selectedCandidatePair: selectedPair)
        let serverTransport = LocalICEUDPSocketMediaDatagramTransport(
            socket: serverSocket,
            remoteCandidate: hostCandidate
        )
        let datagram = Data([0x10, 0x20, 0x30])

        try await transport.send(datagram)
        let received = try await serverTransport.receive()

        XCTAssertEqual(received, datagram)
    }

    func testLocalICEUDPSocketCandidateStoreTracksTURNRelayContext() throws {
        let socket = try LocalICEUDPSocket(
            bindAddress: "127.0.0.1",
            port: 0,
            receiveTimeoutMilliseconds: 250
        )
        let hostCandidate = socket.hostCandidate(
            foundation: "host",
            advertisedAddress: "127.0.0.1"
        )
        let relayCandidate = TURNRelayCandidateFactory.makeCandidate(
            relayedAddress: STUNMappedAddress(address: "198.51.100.44", port: 62_000),
            foundation: "host-relay-1"
        )
        let relayContext = LocalICETURNRelayContext(
            candidate: relayCandidate,
            socket: socket,
            endpoint: TURNServerEndpoint(
                host: "turn.example.test",
                port: 3_478,
                transport: .udp,
                isSecure: false,
                username: "relay-user",
                credential: "relay-password"
            ),
            credentials: TURNRelaySessionCredentials(
                username: "relay-user",
                realm: "turn.example.test",
                nonce: "nonce-1",
                password: "relay-password"
            ),
            allocation: TURNAllocationResult(
                relayedAddress: STUNMappedAddress(address: "198.51.100.44", port: 62_000),
                lifetimeSeconds: 600,
                response: STUNMessage(type: .allocateSuccessResponse),
                credentials: TURNRelaySessionCredentials(
                    username: "relay-user",
                    realm: "turn.example.test",
                    nonce: "nonce-1",
                    password: "relay-password"
                )
            ),
            permissionLifetimeSeconds: 300
        )
        let store = LocalICEUDPSocketCandidateStore(candidates: [
            LocalICEUDPSocketCandidate(candidate: hostCandidate, socket: socket),
        ])

        store.addTURNRelayContexts([relayContext])

        XCTAssertTrue(store.socket(forFoundation: "host-relay-1") === socket)
        XCTAssertTrue(store.turnRelayContext(forFoundation: "host-relay-1") === relayContext)
        XCTAssertEqual(store.candidates.map(\.candidate.foundation), ["host", "host-relay-1"])
    }

    func testLocalICEUDPSocketConnectivityCheckerUsesBoundSocketForSTUN() throws {
        let clientSocket = try LocalICEUDPSocket(
            bindAddress: "127.0.0.1",
            port: 0,
            receiveTimeoutMilliseconds: 250
        )
        let clientCandidate = clientSocket.hostCandidate(
            foundation: "client",
            advertisedAddress: "127.0.0.1"
        )
        let responder = try STUNResponderSocket()
        responder.start()
        let remoteCandidate = loopbackCandidate(
            foundation: "stun",
            port: responder.port
        )
        let checker = LocalICEUDPSocketConnectivityChecker(
            candidates: [
                LocalICEUDPSocketCandidate(candidate: clientCandidate, socket: clientSocket),
            ]
        )

        let result = try checker.checkCandidatePair(
            ICECandidatePair(
                local: clientCandidate,
                remote: remoteCandidate,
                isControlling: true
            ),
            configuration: ICEAgentConfiguration(
                localCredentials: ICECredentials(usernameFragment: "local", password: "local-pass"),
                remoteCredentials: ICECredentials(usernameFragment: "remote", password: "remote-pass"),
                role: .controlling,
                tieBreaker: 7,
                retryPolicy: .once
            ),
            nominate: true
        )

        XCTAssertEqual(result.mappedAddress.address, "127.0.0.1")
        XCTAssertEqual(result.mappedAddress.port, clientSocket.localPort)
        XCTAssertEqual(responder.waitForSourcePort(), clientSocket.localPort)
    }

    func testLocalICEUDPSocketCandidateGathersServerReflexiveCandidateWithBoundSocket() throws {
        let clientSocket = try LocalICEUDPSocket(
            bindAddress: "127.0.0.1",
            port: 0,
            receiveTimeoutMilliseconds: 250
        )
        let hostCandidate = clientSocket.hostCandidate(
            foundation: "client",
            advertisedAddress: "127.0.0.1"
        )
        let responder = try STUNResponderSocket()
        responder.start()

        let reflexiveCandidates = LocalICEUDPSocketCandidate(
            candidate: hostCandidate,
            socket: clientSocket
        ).serverReflexiveCandidates(
            iceServers: [
                ICEServer(urls: ["stun:127.0.0.1:\(responder.port)"]),
            ]
        )

        XCTAssertEqual(reflexiveCandidates.count, 1)
        XCTAssertTrue(reflexiveCandidates[0].socket === clientSocket)
        XCTAssertEqual(reflexiveCandidates[0].candidate.type, .serverReflexive)
        XCTAssertEqual(reflexiveCandidates[0].candidate.address, "127.0.0.1")
        XCTAssertEqual(reflexiveCandidates[0].candidate.port, clientSocket.localPort)
        XCTAssertEqual(reflexiveCandidates[0].candidate.localPreference, hostCandidate.localPreference)
        XCTAssertEqual(responder.waitForSourcePort(), clientSocket.localPort)
    }

    func testUDPMediaDatagramTransportRejectsInvalidAddress() {
        XCTAssertThrowsError(
            try UDPMediaDatagramTransport(
                localCandidate: loopbackCandidate(foundation: "local", address: "not-an-ip", port: 0),
                remoteCandidate: loopbackCandidate(foundation: "remote", port: 9)
            )
        ) { error in
            XCTAssertEqual(error as? SecureMediaTransportError, .unsupportedCandidateAddress("not-an-ip"))
        }
    }

    func testUDPMediaDatagramTransportRejectsUnnominatedPairBeforeOpeningSocket() {
        XCTAssertThrowsError(
            try UDPMediaDatagramTransport(
                selectedCandidatePair: candidatePair(state: .succeeded, nominated: false)
            )
        ) { error in
            XCTAssertEqual(error as? SecureMediaTransportError, .candidatePairNotNominated)
        }
    }

    func testMediaSessionFactoryBuildsTransportFromICEPairAndHandshakeResult() async throws {
        let datagrams = MockMediaDatagramTransport()
        let datagramFactory = CapturingMediaDatagramTransportFactory(transport: datagrams)
        let sessionFactory = DTLSSRTPMediaSessionFactory(datagramTransportFactory: datagramFactory)
        let fingerprint = DTLSSignature(hashFunction: "sha-256", value: "AA:BB:CC")
        let transport = try sessionFactory.makeMediaTransport(
            selectedCandidatePair: candidatePair(state: .succeeded, nominated: true),
            handshakeResult: DTLSSRTPHandshakeResult(
                role: .client,
                exportedKeyingMaterial: exportedKeyingMaterial(),
                remoteFingerprint: fingerprint
            ),
            expectedRemoteFingerprint: fingerprint
        )
        let packet = rtp(sequenceNumber: 101, payload: Data([0x01, 0x02]))

        try await transport.sendRTP(packet)
        let sentDatagrams = await datagrams.sentDatagramsSnapshot()

        XCTAssertEqual(datagramFactory.capturedPair?.remote.foundation, "remote")
        XCTAssertEqual(sentDatagrams.count, 1)
        XCTAssertNotEqual(sentDatagrams.first, packet.encoded())
    }

    func testMediaSessionFactoryRejectsRemoteFingerprintMismatch() throws {
        let sessionFactory = DTLSSRTPMediaSessionFactory(
            datagramTransportFactory: CapturingMediaDatagramTransportFactory(
                transport: MockMediaDatagramTransport()
            )
        )
        let expected = DTLSSignature(hashFunction: "sha-256", value: "AA:BB:CC")
        let actual = DTLSSignature(hashFunction: "sha-256", value: "00:11:22")

        XCTAssertThrowsError(
            try sessionFactory.makeMediaTransport(
                selectedCandidatePair: candidatePair(state: .succeeded, nominated: true),
                handshakeResult: DTLSSRTPHandshakeResult(
                    role: .client,
                    exportedKeyingMaterial: exportedKeyingMaterial(),
                    remoteFingerprint: actual
                ),
                expectedRemoteFingerprint: expected
            )
        ) { error in
            XCTAssertEqual(
                error as? SecureMediaTransportError,
                .remoteFingerprintMismatch(expected: expected, actual: actual)
            )
        }
    }

    func testMediaSessionFactoryRejectsMissingRemoteFingerprintWhenExpected() throws {
        let sessionFactory = DTLSSRTPMediaSessionFactory(
            datagramTransportFactory: CapturingMediaDatagramTransportFactory(
                transport: MockMediaDatagramTransport()
            )
        )
        let expected = DTLSSignature(hashFunction: "sha-256", value: "AA:BB:CC")

        XCTAssertThrowsError(
            try sessionFactory.makeMediaTransport(
                selectedCandidatePair: candidatePair(state: .succeeded, nominated: true),
                handshakeResult: DTLSSRTPHandshakeResult(
                    role: .client,
                    exportedKeyingMaterial: exportedKeyingMaterial()
                ),
                expectedRemoteFingerprint: expected
            )
        ) { error in
            XCTAssertEqual(error as? SecureMediaTransportError, .missingRemoteFingerprint(expected))
        }
    }

    func testMediaSessionFactoryRejectsUnnominatedPairBeforeMakingDatagramTransport() throws {
        let datagramFactory = CapturingMediaDatagramTransportFactory(
            transport: MockMediaDatagramTransport()
        )
        let sessionFactory = DTLSSRTPMediaSessionFactory(datagramTransportFactory: datagramFactory)

        XCTAssertThrowsError(
            try sessionFactory.makeMediaTransport(
                selectedCandidatePair: candidatePair(state: .succeeded, nominated: false),
                handshakeResult: DTLSSRTPHandshakeResult(
                    role: .client,
                    exportedKeyingMaterial: exportedKeyingMaterial()
                )
            )
        ) { error in
            XCTAssertEqual(error as? SecureMediaTransportError, .candidatePairNotNominated)
        }
        XCTAssertNil(datagramFactory.capturedPair)
    }

    func testMediaSessionBinderRunsHandshakeAndBuildsProtectedTransport() async throws {
        let datagrams = MockMediaDatagramTransport()
        let datagramFactory = CapturingMediaDatagramTransportFactory(transport: datagrams)
        let fingerprint = DTLSSignature(hashFunction: "sha-256", value: "AA:BB:CC")
        let handshakeConfiguration = try DTLSSRTPHandshakeConfiguration(
            role: .client,
            remoteFingerprint: fingerprint
        )
        let handshaker = CapturingDTLSSRTPHandshaker(
            result: try DTLSSRTPHandshakeResult(
                role: .client,
                exportedKeyingMaterial: exportedKeyingMaterial(),
                remoteFingerprint: fingerprint
            )
        )
        let binder = DTLSSRTPMediaSessionBinder(
            datagramTransportFactory: datagramFactory,
            handshaker: handshaker
        )
        let transport = try await binder.makeMediaTransport(
            selectedCandidatePair: candidatePair(state: .succeeded, nominated: true),
            handshakeConfiguration: handshakeConfiguration
        )
        let packet = rtp(sequenceNumber: 111, payload: Data([0xAA, 0xBB]))

        try await transport.sendRTP(packet)
        let sentDatagrams = await datagrams.sentDatagramsSnapshot()

        XCTAssertEqual(handshaker.capturedConfiguration, handshakeConfiguration)
        XCTAssertEqual(datagramFactory.capturedPair?.remote.foundation, "remote")
        XCTAssertEqual(sentDatagrams.count, 1)
        XCTAssertNotEqual(sentDatagrams.first, packet.encoded())
    }

    func testMediaSessionBinderRejectsHandshakeFingerprintMismatch() async throws {
        let datagramFactory = CapturingMediaDatagramTransportFactory(
            transport: MockMediaDatagramTransport()
        )
        let expected = DTLSSignature(hashFunction: "sha-256", value: "AA:BB:CC")
        let actual = DTLSSignature(hashFunction: "sha-256", value: "00:11:22")
        let handshaker = CapturingDTLSSRTPHandshaker(
            result: try DTLSSRTPHandshakeResult(
                role: .client,
                exportedKeyingMaterial: exportedKeyingMaterial(),
                remoteFingerprint: actual
            )
        )
        let binder = DTLSSRTPMediaSessionBinder(
            datagramTransportFactory: datagramFactory,
            handshaker: handshaker
        )

        do {
            _ = try await binder.makeMediaTransport(
                selectedCandidatePair: candidatePair(state: .succeeded, nominated: true),
                handshakeConfiguration: try DTLSSRTPHandshakeConfiguration(
                    role: .client,
                    remoteFingerprint: expected
                )
            )
            XCTFail("Expected remote fingerprint mismatch")
        } catch {
            XCTAssertEqual(
                error as? SecureMediaTransportError,
                .remoteFingerprintMismatch(expected: expected, actual: actual)
            )
        }
    }

    func testMediaSessionBinderRejectsHandshakeRoleMismatch() async throws {
        let datagramFactory = CapturingMediaDatagramTransportFactory(
            transport: MockMediaDatagramTransport()
        )
        let fingerprint = DTLSSignature(hashFunction: "sha-256", value: "AA:BB:CC")
        let handshaker = CapturingDTLSSRTPHandshaker(
            result: try DTLSSRTPHandshakeResult(
                role: .server,
                exportedKeyingMaterial: exportedKeyingMaterial(),
                remoteFingerprint: fingerprint
            )
        )
        let binder = DTLSSRTPMediaSessionBinder(
            datagramTransportFactory: datagramFactory,
            handshaker: handshaker
        )

        do {
            _ = try await binder.makeMediaTransport(
                selectedCandidatePair: candidatePair(state: .succeeded, nominated: true),
                handshakeConfiguration: try DTLSSRTPHandshakeConfiguration(
                    role: .client,
                    remoteFingerprint: fingerprint
                )
            )
            XCTFail("Expected handshake role mismatch")
        } catch {
            XCTAssertEqual(
                error as? SecureMediaTransportError,
                .handshakeRoleMismatch(expected: .client, actual: .server)
            )
        }
    }

    func testMediaSessionBinderRejectsUnofferedHandshakeProtectionProfile() async throws {
        let datagramFactory = CapturingMediaDatagramTransportFactory(
            transport: MockMediaDatagramTransport()
        )
        let fingerprint = DTLSSignature(hashFunction: "sha-256", value: "AA:BB:CC")
        let handshaker = CapturingDTLSSRTPHandshaker(
            result: try DTLSSRTPHandshakeResult(
                role: .client,
                protectionProfile: .aes128CMHMACSHA180,
                exportedKeyingMaterial: exportedKeyingMaterial(),
                remoteFingerprint: fingerprint
            )
        )
        let binder = DTLSSRTPMediaSessionBinder(
            datagramTransportFactory: datagramFactory,
            handshaker: handshaker
        )

        do {
            _ = try await binder.makeMediaTransport(
                selectedCandidatePair: candidatePair(state: .succeeded, nominated: true),
                handshakeConfiguration: try DTLSSRTPHandshakeConfiguration(
                    role: .client,
                    remoteFingerprint: fingerprint,
                    useSRTExtension: try DTLSSRTPUseSRTExtension(
                        protectionProfiles: [.aes128CMHMACSHA132]
                    )
                )
            )
            XCTFail("Expected unoffered handshake protection profile")
        } catch {
            XCTAssertEqual(
                error as? SecureMediaTransportError,
                .unofferedHandshakeProtectionProfile(.aes128CMHMACSHA180)
            )
        }
    }

    private func packetProtectionContext(role: DTLSSRTPRole) throws -> DTLSSRTPPacketProtectionContext {
        try DTLSSRTPPacketProtectionContext(
            keyMaterial: keyMaterial(),
            role: role
        )
    }

    private func loopbackCandidate(foundation: String, address: String = "127.0.0.1", port: UInt16) -> ICECandidate {
        ICECandidate(
            foundation: foundation,
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(type: .host, localPreference: 65_535).value,
            address: address,
            port: port,
            type: .host
        )
    }

    private func availableUDPPort() throws -> UInt16 {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else {
            throw SecureMediaTransportError.socketCreationFailed(errno)
        }
        defer { Darwin.close(descriptor) }

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

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.getsockname(descriptor, socketAddress, &length)
            }
        }
        guard nameResult == 0 else {
            throw SecureMediaTransportError.socketBindFailed(errno)
        }

        return UInt16(bigEndian: boundAddress.sin_port)
    }

    private func keyMaterial() throws -> DTLSSRTPKeyMaterial {
        try DTLSSRTPKeyMaterial(exportedKeyingMaterial: exportedKeyingMaterial())
    }

    private func exportedKeyingMaterial() -> Data {
        Data((0..<SRTPProtectionProfile.aes128CMHMACSHA180.exporterByteCount).map(UInt8.init))
    }

    private func candidatePair(
        state: ICECandidatePairState,
        nominated: Bool,
        localTransport: ICETransportProtocol = .udp,
        remoteTransport: ICETransportProtocol = .udp
    ) -> ICECandidatePair {
        ICECandidatePair(
            local: ICECandidate(
                foundation: "local",
                componentID: .rtp,
                transport: localTransport,
                priority: ICECandidatePriority(type: .host, localPreference: 65_535).value,
                address: "192.0.2.10",
                port: 50_000,
                type: .host
            ),
            remote: ICECandidate(
                foundation: "remote",
                componentID: .rtp,
                transport: remoteTransport,
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

    private func rtp(sequenceNumber: UInt16, payload: Data) -> RTPPacket {
        RTPPacket(
            marker: true,
            payloadType: 102,
            sequenceNumber: sequenceNumber,
            timestamp: 90_000,
            ssrc: 0x1122_3344,
            payload: payload
        )
    }

    private func rtcp() -> RTCPPacket {
        .pictureLossIndication(
            RTCPPictureLossIndication(
                senderSSRC: 0x0102_0304,
                mediaSSRC: 0x0506_0708
            )
        )
    }
}

private actor MockMediaDatagramTransport: MediaDatagramTransport {
    private(set) var sentDatagrams: [Data]
    private var incomingDatagrams: [Data]

    init(sentDatagrams: [Data] = [], incomingDatagrams: [Data] = []) {
        self.sentDatagrams = sentDatagrams
        self.incomingDatagrams = incomingDatagrams
    }

    func enqueue(_ datagram: Data) {
        incomingDatagrams.append(datagram)
    }

    func sentDatagramsSnapshot() -> [Data] {
        sentDatagrams
    }

    func send(_ datagram: Data) async throws {
        sentDatagrams.append(datagram)
    }

    func receive() async throws -> Data {
        guard !incomingDatagrams.isEmpty else {
            throw MockMediaDatagramTransportError.empty
        }

        return incomingDatagrams.removeFirst()
    }
}

private enum MockMediaDatagramTransportError: Error {
    case empty
}

private final class STUNResponderSocket: @unchecked Sendable {
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

private final class CapturingMediaDatagramTransportFactory: MediaDatagramTransportFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var mutableCapturedPair: ICECandidatePair?
    private let transport: MockMediaDatagramTransport

    var capturedPair: ICECandidatePair? {
        lock.lock()
        defer { lock.unlock() }
        return mutableCapturedPair
    }

    init(transport: MockMediaDatagramTransport) {
        self.transport = transport
    }

    func makeTransport(selectedCandidatePair: ICECandidatePair) throws -> any MediaDatagramTransport {
        lock.lock()
        mutableCapturedPair = selectedCandidatePair
        lock.unlock()

        return transport
    }
}

private final class CapturingDTLSSRTPHandshaker: DTLSSRTPHandshaking, @unchecked Sendable {
    private let lock = NSLock()
    private var mutableCapturedConfiguration: DTLSSRTPHandshakeConfiguration?
    private let result: DTLSSRTPHandshakeResult

    var capturedConfiguration: DTLSSRTPHandshakeConfiguration? {
        lock.lock()
        defer { lock.unlock() }
        return mutableCapturedConfiguration
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
