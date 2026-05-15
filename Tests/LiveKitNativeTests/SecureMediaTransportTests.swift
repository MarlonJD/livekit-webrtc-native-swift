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
