import Foundation
import XCTest
@testable import LiveKitNativeWebRTC

final class DTLSSRTPTests: XCTestCase {
    func testProtectionProfileMetadataMatchesWebRTCDefaults() throws {
        let profile = try SRTPProtectionProfile(identifier: 0x0001)

        XCTAssertEqual(profile, .aes128CMHMACSHA180)
        XCTAssertEqual(profile.name, "SRTP_AES128_CM_HMAC_SHA1_80")
        XCTAssertEqual(profile.masterKeyLength, 16)
        XCTAssertEqual(profile.masterSaltLength, 14)
        XCTAssertEqual(profile.authenticationKeyLength, 20)
        XCTAssertEqual(profile.srtpAuthenticationTagLength, 10)
        XCTAssertEqual(profile.srtcpAuthenticationTagLength, 10)
        XCTAssertEqual(profile.exporterByteCount, 60)
        XCTAssertEqual(SRTPProtectionProfile.exporterLabel, "EXTRACTOR-dtls_srtp")
    }

    func testRejectsUnsupportedProtectionProfile() {
        XCTAssertThrowsError(try SRTPProtectionProfile(identifier: 0x9999)) { error in
            XCTAssertEqual(error as? DTLSSRTPError, .unsupportedProtectionProfile(0x9999))
        }
    }

    func testUseSRTExtensionEncodesAndDecodesProtectionProfilesAndMKI() throws {
        let extensionData = try DTLSSRTPUseSRTExtension(
            protectionProfiles: [.aes128CMHMACSHA180, .aes128CMHMACSHA132],
            mki: Data([0xCA, 0xFE])
        )

        let encoded = try extensionData.encoded()
        let decoded = try DTLSSRTPUseSRTExtension(decoding: encoded)
        let prefixed = Data([0xFF]) + encoded
        let sliced = prefixed[prefixed.index(after: prefixed.startIndex)..<prefixed.endIndex]

        XCTAssertEqual(DTLSSRTPUseSRTExtension.extensionType, 14)
        XCTAssertEqual(encoded, Data([0x00, 0x04, 0x00, 0x01, 0x00, 0x02, 0x02, 0xCA, 0xFE]))
        XCTAssertEqual(decoded, extensionData)
        XCTAssertEqual(try DTLSSRTPUseSRTExtension(decoding: sliced), extensionData)
    }

    func testUseSRTExtensionSelectsFirstSupportedProtectionProfile() throws {
        let extensionData = try DTLSSRTPUseSRTExtension(
            protectionProfiles: [.aes128CMHMACSHA132, .aes128CMHMACSHA180]
        )

        XCTAssertEqual(
            extensionData.selectedProfile(supportedProfiles: [.aes128CMHMACSHA180]),
            .aes128CMHMACSHA180
        )
        XCTAssertNil(extensionData.selectedProfile(supportedProfiles: []))
    }

    func testUseSRTExtensionRejectsMalformedPayloads() {
        XCTAssertThrowsError(try DTLSSRTPUseSRTExtension(protectionProfiles: [])) { error in
            XCTAssertEqual(error as? DTLSSRTPError, .missingUseSRTPProtectionProfiles)
        }

        XCTAssertThrowsError(try DTLSSRTPUseSRTExtension(decoding: Data([0x00, 0x02, 0x00]))) { error in
            XCTAssertEqual(error as? DTLSSRTPError, .invalidUseSRTExtensionLength)
        }

        XCTAssertThrowsError(try DTLSSRTPUseSRTExtension(decoding: Data([0x00, 0x02, 0x99, 0x99, 0x00]))) { error in
            XCTAssertEqual(error as? DTLSSRTPError, .unsupportedProtectionProfile(0x9999))
        }
    }

    func testSplitsExporterMaterialIntoClientAndServerKeysAndSalts() throws {
        let exported = Data((0..<60).map(UInt8.init))

        let keyMaterial = try DTLSSRTPKeyMaterial(exportedKeyingMaterial: exported)

        XCTAssertEqual(keyMaterial.clientWrite.masterKey, Data(0..<16))
        XCTAssertEqual(keyMaterial.serverWrite.masterKey, Data(16..<32))
        XCTAssertEqual(keyMaterial.clientWrite.masterSalt, Data(32..<46))
        XCTAssertEqual(keyMaterial.serverWrite.masterSalt, Data(46..<60))
    }

    func testRejectsInvalidExporterMaterialLength() {
        XCTAssertThrowsError(
            try DTLSSRTPKeyMaterial(exportedKeyingMaterial: Data(repeating: 0, count: 59))
        ) { error in
            XCTAssertEqual(error as? DTLSSRTPError, .invalidExporterByteCount(expected: 60, actual: 59))
        }
    }

    func testMapsLocalAndRemoteMaterialFromDTLSRole() throws {
        let exported = Data((0..<60).map(UInt8.init))
        let keyMaterial = try DTLSSRTPKeyMaterial(exportedKeyingMaterial: exported)

        XCTAssertEqual(keyMaterial.localWriteMaterial(for: .client), keyMaterial.clientWrite)
        XCTAssertEqual(keyMaterial.remoteWriteMaterial(for: .client), keyMaterial.serverWrite)
        XCTAssertEqual(keyMaterial.localWriteMaterial(for: .server), keyMaterial.serverWrite)
        XCTAssertEqual(keyMaterial.remoteWriteMaterial(for: .server), keyMaterial.clientWrite)
    }

    func testHandshakeResultCarriesExporterMaterialAndRemoteFingerprint() throws {
        let exported = Data((0..<60).map(UInt8.init))
        let fingerprint = DTLSSignature(hashFunction: "sha-256", value: "AA:BB:CC")

        let result = try DTLSSRTPHandshakeResult(
            role: .client,
            exportedKeyingMaterial: exported,
            remoteFingerprint: fingerprint
        )
        let keyMaterial = try result.keyMaterial()

        XCTAssertEqual(result.role, .client)
        XCTAssertEqual(result.remoteFingerprint, fingerprint)
        XCTAssertEqual(keyMaterial.clientWrite.masterKey, Data(0..<16))
        XCTAssertEqual(keyMaterial.serverWrite.masterSalt, Data(46..<60))
    }

    func testHandshakeResultRejectsInvalidExporterLength() {
        XCTAssertThrowsError(
            try DTLSSRTPHandshakeResult(
                role: .server,
                exportedKeyingMaterial: Data(repeating: 0, count: 59)
            )
        ) { error in
            XCTAssertEqual(error as? DTLSSRTPError, .invalidExporterByteCount(expected: 60, actual: 59))
        }
    }

    func testUnavailableAppleDTLSSRTPHandshakerFailsExplicitly() async throws {
        let handshaker = UnavailableAppleDTLSSRTPHandshaker()
        let configuration = try DTLSSRTPHandshakeConfiguration(
            role: .client,
            remoteFingerprint: DTLSSignature(hashFunction: "sha-256", value: "AA:BB:CC")
        )

        do {
            _ = try await handshaker.performHandshake(
                configuration: configuration,
                transport: NoopDTLSDatagramTransport()
            )
            XCTFail("Expected unavailable Apple DTLS-SRTP handshaker failure.")
        } catch {
            XCTAssertEqual(error as? DTLSSRTPError, .webRTCUseSRTPNegotiationUnavailable)
        }
    }

    func testOpenSSLDTLSSRTPHandshakersNegotiateProfileAndExporter() async throws {
        let clientIdentity = DTLSSRTPIdentity.generated()
        let serverIdentity = DTLSSRTPIdentity.generated()
        let datagrams = PairedDTLSDatagramTransport.makePair()
        let client = OpenSSLDTLSSRTPHandshaker(identity: clientIdentity)
        let server = OpenSSLDTLSSRTPHandshaker(identity: serverIdentity)
        let clientConfiguration = try DTLSSRTPHandshakeConfiguration(
            role: .client,
            remoteFingerprint: serverIdentity.fingerprint
        )
        let serverConfiguration = try DTLSSRTPHandshakeConfiguration(
            role: .server,
            remoteFingerprint: clientIdentity.fingerprint
        )

        async let clientResult = client.performHandshake(
            configuration: clientConfiguration,
            transport: datagrams.client
        )
        async let serverResult = server.performHandshake(
            configuration: serverConfiguration,
            transport: datagrams.server
        )

        let results = try await (clientResult, serverResult)

        XCTAssertEqual(results.0.role, .client)
        XCTAssertEqual(results.1.role, .server)
        XCTAssertEqual(results.0.protectionProfile, .aes128CMHMACSHA180)
        XCTAssertEqual(results.1.protectionProfile, .aes128CMHMACSHA180)
        XCTAssertEqual(results.0.remoteFingerprint, serverIdentity.fingerprint)
        XCTAssertEqual(results.1.remoteFingerprint, clientIdentity.fingerprint)
        XCTAssertEqual(results.0.exportedKeyingMaterial, results.1.exportedKeyingMaterial)
        XCTAssertEqual(results.0.exportedKeyingMaterial.count, SRTPProtectionProfile.aes128CMHMACSHA180.exporterByteCount)
        XCTAssertGreaterThan(datagrams.client.sentDatagramCount, 0)
        XCTAssertGreaterThan(datagrams.server.sentDatagramCount, 0)
    }

    func testOpenSSLDTLSApplicationDataCarriesSCTPDataChannelPackets() async throws {
        let clientIdentity = DTLSSRTPIdentity.generated()
        let serverIdentity = DTLSSRTPIdentity.generated()
        let datagrams = PairedDTLSDatagramTransport.makePair()
        let clientDTLS = try OpenSSLDTLSApplicationDataTransport(
            identity: clientIdentity,
            role: .client,
            transport: datagrams.client
        )
        let serverDTLS = try OpenSSLDTLSApplicationDataTransport(
            identity: serverIdentity,
            role: .server,
            transport: datagrams.server
        )

        async let clientResult = clientDTLS.performHandshake(
            role: .client,
            expectedRemoteFingerprint: serverIdentity.fingerprint
        )
        async let serverResult = serverDTLS.performHandshake(
            role: .server,
            expectedRemoteFingerprint: clientIdentity.fingerprint
        )
        _ = try await (clientResult, serverResult)

        let clientSCTP = DTLSSCTPDataChannelPacketTransport(dtlsTransport: clientDTLS)
        let serverSCTP = DTLSSCTPDataChannelPacketTransport(dtlsTransport: serverDTLS)
        let packet = SCTPDataChannelPacket(
            streamID: 0,
            ppid: .binary,
            payload: Data([0x01, 0x02, 0x03])
        )

        try await clientSCTP.send(packet)
        let received = try await serverSCTP.receive()

        XCTAssertEqual(received, packet)
        await clientDTLS.close()
        await serverDTLS.close()
    }

    func testOpenSSLDTLSApplicationDataReceiveThrowsWhenClosedWhileAwaitingDatagram() async throws {
        let clientIdentity = DTLSSRTPIdentity.generated()
        let serverIdentity = DTLSSRTPIdentity.generated()
        let datagrams = PairedDTLSDatagramTransport.makePair()
        let clientDTLS = try OpenSSLDTLSApplicationDataTransport(
            identity: clientIdentity,
            role: .client,
            transport: datagrams.client
        )
        let serverDTLS = try OpenSSLDTLSApplicationDataTransport(
            identity: serverIdentity,
            role: .server,
            transport: datagrams.server
        )

        async let clientResult = clientDTLS.performHandshake(
            role: .client,
            expectedRemoteFingerprint: serverIdentity.fingerprint
        )
        async let serverResult = serverDTLS.performHandshake(
            role: .server,
            expectedRemoteFingerprint: clientIdentity.fingerprint
        )
        _ = try await (clientResult, serverResult)

        let receiveTask = Task {
            try await serverDTLS.receive()
        }
        try await Task.sleep(nanoseconds: 10_000_000)

        await serverDTLS.close()
        try await clientDTLS.send(Data([0x42]))

        do {
            _ = try await withDTLSTestTimeout {
                try await receiveTask.value
            }
            XCTFail("Expected receive to fail after the DTLS application-data transport closes.")
        } catch {
            XCTAssertEqual(error as? SecureMediaTransportError, .transportClosed)
        }

        await clientDTLS.close()
    }

    func testOpenSSLDTLSApplicationDataCarriesStandardsSCTPAssociationPackets() async throws {
        let clientIdentity = DTLSSRTPIdentity.generated()
        let serverIdentity = DTLSSRTPIdentity.generated()
        let datagrams = PairedDTLSDatagramTransport.makePair()
        let clientDTLS = try OpenSSLDTLSApplicationDataTransport(
            identity: clientIdentity,
            role: .client,
            transport: datagrams.client
        )
        let serverDTLS = try OpenSSLDTLSApplicationDataTransport(
            identity: serverIdentity,
            role: .server,
            transport: datagrams.server
        )

        async let clientResult = clientDTLS.performHandshake(
            role: .client,
            expectedRemoteFingerprint: serverIdentity.fingerprint
        )
        async let serverResult = serverDTLS.performHandshake(
            role: .server,
            expectedRemoteFingerprint: clientIdentity.fingerprint
        )
        _ = try await (clientResult, serverResult)

        let clientSCTP = DTLSSCTPAssociationDataChannelPacketTransport(
            dtlsTransport: clientDTLS,
            configuration: SCTPAssociationConfiguration(
                localInitiateTag: 0x1111_2222,
                initialTSN: 0x0000_0100,
                stateCookie: Data([0xca, 0xfe]),
                maxDataChunkPayloadSize: 4
            )
        )
        let serverSCTP = DTLSSCTPAssociationDataChannelPacketTransport(
            dtlsTransport: serverDTLS,
            configuration: SCTPAssociationConfiguration(
                localInitiateTag: 0x3333_4444,
                initialTSN: 0x0000_0200,
                stateCookie: Data([0xba, 0xad, 0xf0, 0x0d]),
                maxDataChunkPayloadSize: 4
            )
        )
        let outbound = SCTPDataChannelPacket(
            streamID: 0,
            ppid: .binary,
            payload: Data([0x01, 0x02, 0x03])
        )

        async let serverReceive = serverSCTP.receive()
        try await clientSCTP.send(outbound)
        let received = try await serverReceive

        XCTAssertEqual(received, outbound)
        let clientEstablished = await clientSCTP.isEstablished
        let serverEstablished = await serverSCTP.isEstablished
        XCTAssertTrue(clientEstablished)
        XCTAssertTrue(serverEstablished)

        let inbound = SCTPDataChannelPacket(
            streamID: 0,
            ppid: .dataChannelControl,
            payload: SCTPDataChannelControlMessage.acknowledgement.encoded()
        )

        async let clientReceive = clientSCTP.receive()
        try await serverSCTP.send(inbound)
        let clientReceived = try await clientReceive

        XCTAssertEqual(clientReceived, inbound)

        let concurrentOutbound = SCTPDataChannelPacket(
            streamID: 0,
            ppid: .binary,
            payload: Data([0x09, 0x08, 0x07])
        )
        let concurrentInbound = SCTPDataChannelPacket(
            streamID: 0,
            ppid: .binary,
            payload: Data([0x06, 0x05, 0x04])
        )

        async let pendingClientReceive = clientSCTP.receive()
        try await clientSCTP.send(concurrentOutbound)
        let serverReceivedConcurrent = try await serverSCTP.receive()
        try await serverSCTP.send(concurrentInbound)
        let clientReceivedConcurrent = try await pendingClientReceive

        XCTAssertEqual(serverReceivedConcurrent, concurrentOutbound)
        XCTAssertEqual(clientReceivedConcurrent, concurrentInbound)

        let fragmentedOutbound = SCTPDataChannelPacket(
            streamID: 0,
            ppid: .binary,
            payload: Data(0..<13)
        )

        async let serverFragmentedReceive = serverSCTP.receive()
        try await clientSCTP.send(fragmentedOutbound)
        let receivedFragmented = try await serverFragmentedReceive

        XCTAssertEqual(receivedFragmented, fragmentedOutbound)
        await clientDTLS.close()
        await serverDTLS.close()
    }

    func testOpenSSLDTLSApplicationDataReassemblesFragmentedSCTPDataChannelPackets() async throws {
        let clientIdentity = DTLSSRTPIdentity.generated()
        let serverIdentity = DTLSSRTPIdentity.generated()
        let datagrams = PairedDTLSDatagramTransport.makePair()
        let clientDTLS = try OpenSSLDTLSApplicationDataTransport(
            identity: clientIdentity,
            role: .client,
            transport: datagrams.client
        )
        let serverDTLS = try OpenSSLDTLSApplicationDataTransport(
            identity: serverIdentity,
            role: .server,
            transport: datagrams.server
        )

        async let clientResult = clientDTLS.performHandshake(
            role: .client,
            expectedRemoteFingerprint: serverIdentity.fingerprint
        )
        async let serverResult = serverDTLS.performHandshake(
            role: .server,
            expectedRemoteFingerprint: clientIdentity.fingerprint
        )
        _ = try await (clientResult, serverResult)

        let clientSCTP = DTLSSCTPDataChannelPacketTransport(
            dtlsTransport: clientDTLS,
            maxFragmentPayloadSize: 4,
            retransmissionPolicy: SCTPDataChannelRetransmissionPolicy(
                initialDelaySeconds: 0,
                maxAttempts: 2
            )
        )
        let serverSCTP = DTLSSCTPDataChannelPacketTransport(
            dtlsTransport: serverDTLS,
            maxFragmentPayloadSize: 4
        )
        let packet = SCTPDataChannelPacket(
            streamID: 2,
            ppid: .binary,
            payload: Data(0..<13)
        )

        try await clientSCTP.send(packet)
        let received = try await serverSCTP.receive()

        XCTAssertEqual(received, packet)
        let pendingRetransmissions = await clientSCTP.pendingRetransmissionCount
        XCTAssertEqual(pendingRetransmissions, 4)

        let dueFragments = try await clientSCTP.sendDueRetransmissions()
        XCTAssertEqual(dueFragments.count, 4)
        let retransmitted = try await serverSCTP.receive()
        XCTAssertEqual(retransmitted, packet)

        let messageID = try XCTUnwrap(dueFragments.first?.envelope.messageID)
        await clientSCTP.markMessageAcknowledged(messageID: messageID)
        let remainingRetransmissions = await clientSCTP.pendingRetransmissionCount
        XCTAssertEqual(remainingRetransmissions, 0)
        await clientDTLS.close()
        await serverDTLS.close()
    }

    func testWebRTCDatagramClassifierUsesRFC5764Ranges() {
        XCTAssertEqual(WebRTCDatagramClassifier.classify(Data([0x00, 0x01])), .stun)
        XCTAssertEqual(WebRTCDatagramClassifier.classify(Data([0x17, 0xfe, 0xfd])), .dtls)
        XCTAssertEqual(WebRTCDatagramClassifier.classify(Data([0x40, 0x00])), .turnChannelData)
        XCTAssertEqual(WebRTCDatagramClassifier.classify(Data([0x80, 0x66])), .media)
        XCTAssertEqual(WebRTCDatagramClassifier.classify(Data([0xff])), .unknown)
        XCTAssertEqual(WebRTCDatagramClassifier.classify(Data()), .unknown)
    }

    func testMediaDataSessionBinderDemuxesDTLSDataAndSRTPOnSharedTransport() async throws {
        let clientIdentity = DTLSSRTPIdentity.generated()
        let serverIdentity = DTLSSRTPIdentity.generated()
        let datagrams = PairedDTLSDatagramTransport.makePair()
        let clientCandidate = dtlsCandidate(foundation: "client")
        let serverCandidate = dtlsCandidate(foundation: "server")
        let clientPair = ICECandidatePair(
            local: clientCandidate,
            remote: serverCandidate,
            isControlling: true,
            state: .succeeded,
            nominated: true
        )
        let serverPair = ICECandidatePair(
            local: serverCandidate,
            remote: clientCandidate,
            isControlling: false,
            state: .succeeded,
            nominated: true
        )
        let clientBinder = DTLSSRTPMediaDataSessionBinder(
            datagramTransportFactory: FixedMediaDatagramTransportFactory(transport: datagrams.client),
            identity: clientIdentity,
            maxDataChannelFragmentPayloadSize: 4
        )
        let serverBinder = DTLSSRTPMediaDataSessionBinder(
            datagramTransportFactory: FixedMediaDatagramTransportFactory(transport: datagrams.server),
            identity: serverIdentity,
            maxDataChannelFragmentPayloadSize: 4
        )
        let clientConfiguration = try DTLSSRTPHandshakeConfiguration(
            role: .client,
            remoteFingerprint: serverIdentity.fingerprint
        )
        let serverConfiguration = try DTLSSRTPHandshakeConfiguration(
            role: .server,
            remoteFingerprint: clientIdentity.fingerprint
        )

        async let clientSessionTask = clientBinder.makeSession(
            selectedCandidatePair: clientPair,
            handshakeConfiguration: clientConfiguration
        )
        async let serverSessionTask = serverBinder.makeSession(
            selectedCandidatePair: serverPair,
            handshakeConfiguration: serverConfiguration
        )
        let (clientSession, serverSession) = try await (clientSessionTask, serverSessionTask)
        let dataPacket = SCTPDataChannelPacket(
            streamID: 2,
            ppid: .binary,
            payload: Data(0..<13)
        )
        let rtp = RTPPacket(
            marker: true,
            payloadType: 102,
            sequenceNumber: 17,
            timestamp: 9_000,
            ssrc: 0x1122_3344,
            payload: Data((0..<64).map(UInt8.init))
        )

        try await clientSession.dataChannelTransport.send(dataPacket)
        try await clientSession.mediaTransport.sendRTP(rtp)

        guard case let .rtp(receivedRTP) = try await serverSession.mediaTransport.receive() else {
            return XCTFail("Expected demultiplexed SRTP packet.")
        }
        let receivedDataPacket = try await serverSession.dataChannelTransport.receive()

        XCTAssertEqual(clientSession.handshakeResult.remoteFingerprint, serverIdentity.fingerprint)
        XCTAssertEqual(serverSession.handshakeResult.remoteFingerprint, clientIdentity.fingerprint)
        XCTAssertEqual(receivedRTP, rtp)
        XCTAssertEqual(receivedDataPacket, dataPacket)
        await clientSession.close()
        await serverSession.close()
    }

    func testMediaDataSessionBinderCanUseStandardsSCTPAssociationTransport() async throws {
        let clientIdentity = DTLSSRTPIdentity.generated()
        let serverIdentity = DTLSSRTPIdentity.generated()
        let datagrams = PairedDTLSDatagramTransport.makePair()
        let clientCandidate = dtlsCandidate(foundation: "client")
        let serverCandidate = dtlsCandidate(foundation: "server")
        let clientPair = ICECandidatePair(
            local: clientCandidate,
            remote: serverCandidate,
            isControlling: true,
            state: .succeeded,
            nominated: true
        )
        let serverPair = ICECandidatePair(
            local: serverCandidate,
            remote: clientCandidate,
            isControlling: false,
            state: .succeeded,
            nominated: true
        )
        let clientBinder = DTLSSRTPMediaDataSessionBinder(
            datagramTransportFactory: FixedMediaDatagramTransportFactory(transport: datagrams.client),
            identity: clientIdentity,
            dataChannelTransportMode: .association(SCTPAssociationConfiguration(
                localInitiateTag: 0x0102_0304,
                initialTSN: 10,
                stateCookie: Data([0xca, 0xfe])
            ))
        )
        let serverBinder = DTLSSRTPMediaDataSessionBinder(
            datagramTransportFactory: FixedMediaDatagramTransportFactory(transport: datagrams.server),
            identity: serverIdentity,
            dataChannelTransportMode: .association(SCTPAssociationConfiguration(
                localInitiateTag: 0x0506_0708,
                initialTSN: 20,
                stateCookie: Data([0xba, 0xad, 0xf0, 0x0d])
            ))
        )
        let clientConfiguration = try DTLSSRTPHandshakeConfiguration(
            role: .client,
            remoteFingerprint: serverIdentity.fingerprint
        )
        let serverConfiguration = try DTLSSRTPHandshakeConfiguration(
            role: .server,
            remoteFingerprint: clientIdentity.fingerprint
        )

        async let clientSessionTask = clientBinder.makeSession(
            selectedCandidatePair: clientPair,
            handshakeConfiguration: clientConfiguration
        )
        async let serverSessionTask = serverBinder.makeSession(
            selectedCandidatePair: serverPair,
            handshakeConfiguration: serverConfiguration
        )
        let (clientSession, serverSession) = try await (clientSessionTask, serverSessionTask)
        let dataPacket = SCTPDataChannelPacket(
            streamID: 0,
            ppid: .binary,
            payload: Data([0x11, 0x22, 0x33])
        )
        let rtp = RTPPacket(
            marker: true,
            payloadType: 102,
            sequenceNumber: 23,
            timestamp: 18_000,
            ssrc: 0x5566_7788,
            payload: Data((0..<32).map(UInt8.init))
        )

        async let receivedDataPacketTask = serverSession.dataChannelTransport.receive()
        try await clientSession.dataChannelTransport.send(dataPacket)
        try await clientSession.mediaTransport.sendRTP(rtp)

        guard case let .rtp(receivedRTP) = try await serverSession.mediaTransport.receive() else {
            return XCTFail("Expected demultiplexed SRTP packet.")
        }
        let receivedDataPacket = try await receivedDataPacketTask

        XCTAssertEqual(receivedRTP, rtp)
        XCTAssertEqual(receivedDataPacket, dataPacket)
        await clientSession.close()
        await serverSession.close()
    }

    func testShortAuthenticationTagProfileUsesSameExporterByteCount() throws {
        let profile = try SRTPProtectionProfile(identifier: 0x0002)
        let exported = Data((0..<60).map(UInt8.init))

        let keyMaterial = try DTLSSRTPKeyMaterial(
            exportedKeyingMaterial: exported,
            protectionProfile: profile
        )

        XCTAssertEqual(profile, .aes128CMHMACSHA132)
        XCTAssertEqual(profile.srtpAuthenticationTagLength, 4)
        XCTAssertEqual(profile.srtcpAuthenticationTagLength, 10)
        XCTAssertEqual(profile.exporterByteCount, 60)
        XCTAssertEqual(keyMaterial.protectionProfile, profile)
    }

    func testDerivesSessionKeysFromRFC3711Vector() throws {
        let master = SRTPMasterKeyMaterial(
            masterKey: try Data(hex: "E1F97A0D3E018BE0D64FA32C06DE4139"),
            masterSalt: try Data(hex: "0EC675AD498AFEEBB6960B3AABE6")
        )

        let keys = try SRTPSessionKeys(masterKeyMaterial: master)

        XCTAssertEqual(keys.srtpEncryptionKey, try Data(hex: "C61E7A93744F39EE10734AFE3FF7A087"))
        XCTAssertEqual(keys.srtpSaltKey, try Data(hex: "30CBBC08863D8C85D49DB34A9AE1"))
        XCTAssertEqual(keys.srtpAuthenticationKey, try Data(hex: "CEBE321F6FF7716B6FD4AB49AF256A156D38BAA4"))
        XCTAssertNotEqual(keys.srtcpEncryptionKey, keys.srtpEncryptionKey)
        XCTAssertNotEqual(keys.srtcpAuthenticationKey, keys.srtpAuthenticationKey)
        XCTAssertNotEqual(keys.srtcpSaltKey, keys.srtpSaltKey)
    }

    func testRejectsInvalidMasterKeyMaterialForSessionDerivation() {
        let invalidKey = SRTPMasterKeyMaterial(
            masterKey: Data(repeating: 0, count: 15),
            masterSalt: Data(repeating: 0, count: 14)
        )
        XCTAssertThrowsError(try SRTPSessionKeys(masterKeyMaterial: invalidKey)) { error in
            XCTAssertEqual(error as? DTLSSRTPError, .invalidMasterKeyLength(expected: 16, actual: 15))
        }

        let invalidSalt = SRTPMasterKeyMaterial(
            masterKey: Data(repeating: 0, count: 16),
            masterSalt: Data(repeating: 0, count: 13)
        )
        XCTAssertThrowsError(try SRTPSessionKeys(masterKeyMaterial: invalidSalt)) { error in
            XCTAssertEqual(error as? DTLSSRTPError, .invalidMasterSaltLength(expected: 14, actual: 13))
        }
    }

    func testPacketProtectionContextMapsClientAndServerDirections() throws {
        let exported = Data((0..<60).map(UInt8.init))
        let keyMaterial = try DTLSSRTPKeyMaterial(exportedKeyingMaterial: exported)
        var client = try DTLSSRTPPacketProtectionContext(keyMaterial: keyMaterial, role: .client)
        var server = try DTLSSRTPPacketProtectionContext(keyMaterial: keyMaterial, role: .server)
        let rtp = RTPPacket(
            marker: true,
            payloadType: 102,
            sequenceNumber: 17,
            timestamp: 9_000,
            ssrc: 0x1122_3344,
            payload: Data((0..<64).map(UInt8.init))
        )

        let protectedRTP = try client.protectRTP(rtp, rolloverCounter: 0)
        let decodedRTP = try server.unprotectRTP(encoded: protectedRTP.encoded(), rolloverCounter: 0)

        XCTAssertNotEqual(protectedRTP.rtpPacket.payload, rtp.payload)
        XCTAssertEqual(protectedRTP.authenticationTag.count, 10)
        XCTAssertEqual(decodedRTP, rtp)
        XCTAssertThrowsError(try server.unprotectRTP(protectedRTP)) { error in
            XCTAssertEqual(error as? SRTPError, .replayedPacket)
        }

        let rtcp = try pliPacket(index: 3)
        let protectedRTCP = try server.protectRTCP(rtcp)
        let decodedRTCP = try client.unprotectRTCP(encoded: try protectedRTCP.encoded())

        XCTAssertTrue(protectedRTCP.index.isEncrypted)
        XCTAssertEqual(protectedRTCP.authenticationTag.count, 10)
        XCTAssertEqual(decodedRTCP, rtcp)
    }

    func testPacketProtectionContextUsesShortSRTPTagProfile() throws {
        let exported = Data((0..<60).map(UInt8.init))
        let keyMaterial = try DTLSSRTPKeyMaterial(
            exportedKeyingMaterial: exported,
            protectionProfile: .aes128CMHMACSHA132
        )
        var server = try DTLSSRTPPacketProtectionContext(keyMaterial: keyMaterial, role: .server)
        let client = try DTLSSRTPPacketProtectionContext(keyMaterial: keyMaterial, role: .client)
        let rtp = RTPPacket(
            marker: false,
            payloadType: 102,
            sequenceNumber: 21,
            timestamp: 12_000,
            ssrc: 0x5566_7788,
            payload: Data([0x01, 0x02, 0x03])
        )

        let protectedRTP = try client.protectRTP(rtp, rolloverCounter: 0)
        let protectedRTCP = try client.protectRTCP(try pliPacket(index: 4))

        XCTAssertEqual(protectedRTP.authenticationTag.count, 4)
        XCTAssertEqual(try server.unprotectRTP(encoded: protectedRTP.encoded(), rolloverCounter: 0), rtp)
        XCTAssertEqual(protectedRTCP.authenticationTag.count, 10)
    }

    private func pliPacket(index: UInt32) throws -> SRTCPPacket {
        SRTCPPacket(
            rtcpPacket: .pictureLossIndication(
                RTCPPictureLossIndication(senderSSRC: 0x0102_0304, mediaSSRC: 0x0506_0708)
            ),
            index: try SRTCPIndex(value: index)
        )
    }
}

private extension Data {
    init(hex: String) throws {
        let cleaned = hex.filter { !$0.isWhitespace }
        guard cleaned.count.isMultiple(of: 2) else {
            throw HexError.invalidLength
        }

        var bytes: [UInt8] = []
        bytes.reserveCapacity(cleaned.count / 2)

        var index = cleaned.startIndex
        while index < cleaned.endIndex {
            let nextIndex = cleaned.index(index, offsetBy: 2)
            guard let byte = UInt8(cleaned[index..<nextIndex], radix: 16) else {
                throw HexError.invalidByte
            }
            bytes.append(byte)
            index = nextIndex
        }

        self = Data(bytes)
    }
}

private enum HexError: Error {
    case invalidLength
    case invalidByte
}

private struct NoopDTLSDatagramTransport: MediaDatagramTransport {
    func send(_ datagram: Data) async throws {}

    func receive() async throws -> Data {
        Data()
    }
}

private struct FixedMediaDatagramTransportFactory: MediaDatagramTransportFactory {
    var transport: any MediaDatagramTransport

    func makeTransport(selectedCandidatePair: ICECandidatePair) throws -> any MediaDatagramTransport {
        transport
    }
}

private final class PairedDTLSDatagramTransport: MediaDatagramTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var incomingDatagrams: [Data] = []
    private var receiveContinuations: [UUID: CheckedContinuation<Data, Error>] = [:]
    private var peer: PairedDTLSDatagramTransport?
    private var mutableSentDatagramCount = 0

    var sentDatagramCount: Int {
        lock.withLock {
            mutableSentDatagramCount
        }
    }

    static func makePair() -> (client: PairedDTLSDatagramTransport, server: PairedDTLSDatagramTransport) {
        let client = PairedDTLSDatagramTransport()
        let server = PairedDTLSDatagramTransport()
        client.peer = server
        server.peer = client
        return (client, server)
    }

    func send(_ datagram: Data) async throws {
        let destination = try lock.withLock {
            mutableSentDatagramCount += 1
            guard let currentPeer = peer else {
                throw PairedDTLSDatagramTransportError.missingPeer
            }
            return currentPeer
        }
        destination.enqueue(datagram)
    }

    func receive() async throws -> Data {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let immediateDatagram: Data? = lock.withLock {
                    guard incomingDatagrams.isEmpty else {
                        return incomingDatagrams.removeFirst()
                    }

                    receiveContinuations[id] = continuation
                    return nil
                }

                if let immediateDatagram {
                    continuation.resume(returning: immediateDatagram)
                }
            }
        } onCancel: {
            let continuation = lock.withLock {
                receiveContinuations.removeValue(forKey: id)
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    private func enqueue(_ datagram: Data) {
        let continuation: CheckedContinuation<Data, Error>? = lock.withLock {
            if let id = receiveContinuations.keys.first,
               let continuation = receiveContinuations.removeValue(forKey: id) {
                return continuation
            }

            incomingDatagrams.append(datagram)
            return nil
        }
        continuation?.resume(returning: datagram)
    }
}

private enum PairedDTLSDatagramTransportError: Error {
    case missingPeer
}

private func withDTLSTestTimeout<T: Sendable>(
    nanoseconds: UInt64 = 1_000_000_000,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            try await Task.sleep(nanoseconds: nanoseconds)
            throw DTLSTestTimeoutError()
        }

        guard let value = try await group.next() else {
            throw DTLSTestTimeoutError()
        }

        group.cancelAll()
        return value
    }
}

private struct DTLSTestTimeoutError: Error {}

private func dtlsCandidate(foundation: String) -> ICECandidate {
    ICECandidate(
        foundation: foundation,
        componentID: .rtp,
        transport: .udp,
        priority: ICECandidatePriority(type: .host, localPreference: 65_535).value,
        address: "127.0.0.1",
        port: 9,
        type: .host
    )
}
