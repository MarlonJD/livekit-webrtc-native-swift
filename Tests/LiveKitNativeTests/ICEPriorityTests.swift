import Foundation
import XCTest
@testable import LiveKitNativeWebRTC

final class ICEPriorityTests: XCTestCase {
    func testComputesCandidatePriorityForHostRTPComponent() {
        let priority = ICECandidatePriority(type: .host, localPreference: 65_535, componentID: .rtp)

        XCTAssertEqual(priority.value, 2_130_706_431)
    }

    func testCandidateTypePreferencesFollowTinyEngineDefaults() {
        XCTAssertGreaterThan(ICECandidateType.host.typePreference, ICECandidateType.peerReflexive.typePreference)
        XCTAssertGreaterThan(ICECandidateType.peerReflexive.typePreference, ICECandidateType.serverReflexive.typePreference)
        XCTAssertGreaterThan(ICECandidateType.serverReflexive.typePreference, ICECandidateType.relayed.typePreference)
    }

    func testComputesCandidatePairPriorityFromControllingRole() {
        let local = ICECandidatePriority(type: .host, localPreference: 65_535).value
        let remote = ICECandidatePriority(type: .serverReflexive, localPreference: 100).value

        XCTAssertEqual(
            ICECandidatePriority.candidatePairPriority(local: local, remote: remote, isControlling: true),
            7_205_870_454_433_644_543
        )
        XCTAssertEqual(
            ICECandidatePriority.candidatePairPriority(local: local, remote: remote, isControlling: false),
            7_205_870_454_433_644_542
        )
    }

    func testSerializesSDPCandidateAttribute() {
        let priority = ICECandidatePriority(type: .host, localPreference: 65_535).value
        let candidate = ICECandidate(
            foundation: "1",
            componentID: .rtp,
            transport: .udp,
            priority: priority,
            address: "192.0.2.10",
            port: 53123,
            type: .host
        )

        XCTAssertEqual(
            candidate.sdpAttributeValue,
            "candidate:1 1 UDP 2130706431 192.0.2.10 53123 typ host"
        )
    }

    func testParsesSDPCandidateAttribute() throws {
        let candidate = try ICECandidate(
            sdpAttributeValue: "candidate:842163049 1 udp 1677729535 203.0.113.20 54400 typ srflx raddr 10.0.0.2 rport 53123"
        )

        XCTAssertEqual(candidate.foundation, "842163049")
        XCTAssertEqual(candidate.componentID, .rtp)
        XCTAssertEqual(candidate.transport, .udp)
        XCTAssertEqual(candidate.priority, 1_677_729_535)
        XCTAssertEqual(candidate.address, "203.0.113.20")
        XCTAssertEqual(candidate.port, 54_400)
        XCTAssertEqual(candidate.type, .serverReflexive)
    }

    func testParsesCandidateAttributeWithALinePrefixAndRelayType() throws {
        let candidate = try ICECandidate(
            sdpAttributeValue: "a=candidate:1 1 TCP 2122194687 192.0.2.44 9 typ relay tcptype active"
        )

        XCTAssertEqual(candidate.transport, .tcp)
        XCTAssertEqual(candidate.type, .relayed)
        XCTAssertEqual(candidate.sdpAttributeValue, "candidate:1 1 TCP 2122194687 192.0.2.44 9 typ relay")
    }

    func testRejectsMalformedSDPCandidateAttribute() {
        XCTAssertThrowsError(try ICECandidate(sdpAttributeValue: "not-a-candidate")) { error in
            XCTAssertEqual(error as? ICECandidateSDPError, .missingCandidatePrefix)
        }

        XCTAssertThrowsError(
            try ICECandidate(sdpAttributeValue: "candidate:1 3 UDP 1 192.0.2.10 5000 typ host")
        ) { error in
            XCTAssertEqual(error as? ICECandidateSDPError, .unsupportedComponent("3"))
        }
    }

    func testBuildsHostCandidatesFromInterfaceAddresses() {
        let candidates = ICEHostCandidateGatherer.candidates(
            from: [
                ICEInterfaceAddress(name: "en0", address: "192.0.2.10", localPreference: 65_535),
                ICEInterfaceAddress(name: "en1", address: "2001:db8::1", localPreference: 65_534),
            ],
            port: 53123
        )

        XCTAssertEqual(candidates.count, 2)
        XCTAssertEqual(candidates[0].foundation, "1")
        XCTAssertEqual(candidates[0].address, "192.0.2.10")
        XCTAssertEqual(candidates[0].port, 53123)
        XCTAssertEqual(candidates[0].type, .host)
        XCTAssertEqual(candidates[0].transport, .udp)
        XCTAssertEqual(candidates[0].priority, 2_130_706_431)
        XCTAssertEqual(candidates[1].foundation, "2")
        XCTAssertEqual(candidates[1].address, "2001:db8::1")
        XCTAssertEqual(candidates[1].priority, 2_130_706_175)
    }

    func testBuildsICEConnectivityCheckBindingRequest() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 9, count: 12))
        let local = ICECredentials(usernameFragment: "local", password: "local-password")
        let remote = ICECredentials(usernameFragment: "remote", password: "remote-password")
        let message = ICEConnectivityCheckRequestFactory.makeBindingRequest(
            localCredentials: local,
            remoteCredentials: remote,
            priority: 1_864_403_327,
            role: .controlling,
            tieBreaker: 0x0102_0304_0506_0708,
            useCandidate: true,
            transactionID: transactionID
        )

        XCTAssertEqual(message.type, .bindingRequest)
        XCTAssertEqual(message.transactionID, transactionID)
        XCTAssertEqual(try message.firstAttribute(.username)?.stringValue, "remote:local")
        XCTAssertEqual(message.firstAttribute(.priority)?.uint32Value, 1_864_403_327)
        XCTAssertEqual(message.firstAttribute(.iceControlling)?.uint64Value, 0x0102_0304_0506_0708)
        XCTAssertEqual(message.firstAttribute(.useCandidate)?.value, Data())
    }

    func testChecklistSortsPairsAndTracksNomination() {
        let local = ICECandidate(
            foundation: "local",
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(type: .host, localPreference: 65_535).value,
            address: "192.0.2.10",
            port: 5000,
            type: .host
        )
        let remote = ICECandidate(
            foundation: "remote",
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(type: .serverReflexive, localPreference: 100).value,
            address: "203.0.113.20",
            port: 6000,
            type: .serverReflexive
        )

        var checklist = ICECandidateChecklist(
            localCandidates: [local],
            remoteCandidates: [remote],
            isControlling: true
        )

        XCTAssertEqual(checklist.pairs.count, 1)
        XCTAssertEqual(checklist.pairs[0].state, .frozen)
        checklist.unfreezeInitialPairs()
        XCTAssertEqual(checklist.nextWaitingPair?.local.foundation, "local")

        checklist.markInProgress(localFoundation: "local", remoteFoundation: "remote")
        XCTAssertEqual(checklist.pairs[0].state, .inProgress)

        checklist.markSucceeded(localFoundation: "local", remoteFoundation: "remote", nominated: true)
        XCTAssertEqual(checklist.nominatedPair?.remote.foundation, "remote")
    }

    func testChecklistAddsTrickledCandidatesAndMaintainsPriorityOrder() {
        let local = ICECandidate(
            foundation: "local",
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(type: .host, localPreference: 65_535).value,
            address: "192.0.2.10",
            port: 5000,
            type: .host
        )
        let lowPriorityRemote = ICECandidate(
            foundation: "remote-low",
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(type: .relayed, localPreference: 100).value,
            address: "203.0.113.20",
            port: 6000,
            type: .relayed
        )
        let highPriorityRemote = ICECandidate(
            foundation: "remote-high",
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(type: .serverReflexive, localPreference: 65_535).value,
            address: "203.0.113.30",
            port: 7000,
            type: .serverReflexive
        )
        var checklist = ICECandidateChecklist(
            localCandidates: [local],
            remoteCandidates: [],
            isControlling: true
        )

        checklist.addRemoteCandidate(lowPriorityRemote, isControlling: true)
        checklist.addRemoteCandidate(highPriorityRemote, isControlling: true)
        checklist.addRemoteCandidate(highPriorityRemote, isControlling: true)

        XCTAssertEqual(checklist.remoteCandidates.count, 2)
        XCTAssertEqual(checklist.pairs.count, 2)
        XCTAssertEqual(checklist.pairs.first?.remote.foundation, "remote-high")
    }

    func testRemoteICECandidateKeepsParsedCandidateWhenAvailable() throws {
        let initCandidate = RTCIceCandidateInit(
            candidate: "candidate:1 1 UDP 2130706431 192.0.2.10 53123 typ host",
            sdpMid: "0",
            sdpMLineIndex: 0
        )

        let remote = RemoteICECandidate(candidateInit: initCandidate)

        XCTAssertEqual(remote.candidate?.address, "192.0.2.10")
        XCTAssertEqual(remote.candidate?.type, .host)
    }

    func testSTUNBindingClientReturnsMappedAddress() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 4, count: 12))
        let transport = FakeSTUNDatagramTransport { requestData in
            let request = try STUNMessage(decoding: requestData)
            let response = STUNMessage(
                type: .bindingSuccessResponse,
                transactionID: request.transactionID,
                attributes: [
                    try .xorMappedAddressIPv4(address: "203.0.113.5", port: 54_321, transactionID: request.transactionID),
                ]
            )
            return try response.encoded()
        }
        let client = STUNBindingClient(transport: transport)
        let result = try client.requestServerReflexiveAddress(
            localCredentials: ICECredentials(usernameFragment: "local", password: "local-password"),
            remoteCredentials: ICECredentials(usernameFragment: "remote", password: "remote-password"),
            priority: 1_864_403_327,
            role: .controlled,
            tieBreaker: 0x0102_0304_0506_0708,
            transactionID: transactionID
        )

        XCTAssertEqual(result.mappedAddress, STUNMappedAddress(address: "203.0.113.5", port: 54_321))
    }

    func testSTUNBindingClientSendsAuthenticatedRequestAndValidatesAuthenticatedResponse() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 5, count: 12))
        let localCredentials = ICECredentials(usernameFragment: "local", password: "local-password")
        let remoteCredentials = ICECredentials(usernameFragment: "remote", password: "remote-password")
        let transport = FakeSTUNDatagramTransport { requestData in
            let request = try STUNMessage(decoding: requestData)

            XCTAssertEqual(try request.firstAttribute(.username)?.stringValue, "remote:local")
            XCTAssertNotNil(request.firstAttribute(.messageIntegrity))
            XCTAssertNotNil(request.firstAttribute(.fingerprint))
            XCTAssertTrue(try request.validatesMessageIntegrity(key: "remote-password"))
            XCTAssertTrue(try request.validatesFingerprint())

            let response = STUNMessage(
                type: .bindingSuccessResponse,
                transactionID: request.transactionID,
                attributes: [
                    try .xorMappedAddressIPv4(address: "203.0.113.8", port: 12_345, transactionID: request.transactionID),
                ]
            )
            return try response.encoded(
                messageIntegrityKey: "remote-password",
                includeFingerprint: true
            )
        }
        let client = STUNBindingClient(transport: transport)
        let result = try client.requestServerReflexiveAddress(
            localCredentials: localCredentials,
            remoteCredentials: remoteCredentials,
            priority: 1_864_403_327,
            role: .controlled,
            tieBreaker: 0x0102_0304_0506_0708,
            transactionID: transactionID,
            requireResponseMessageIntegrity: true,
            requireResponseFingerprint: true
        )

        XCTAssertEqual(result.mappedAddress, STUNMappedAddress(address: "203.0.113.8", port: 12_345))
    }

    func testSTUNBindingClientRejectsInvalidResponseFingerprint() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 6, count: 12))
        let transport = FakeSTUNDatagramTransport { requestData in
            let request = try STUNMessage(decoding: requestData)
            let response = STUNMessage(
                type: .bindingSuccessResponse,
                transactionID: request.transactionID,
                attributes: [
                    try .xorMappedAddressIPv4(address: "203.0.113.9", port: 12_346, transactionID: request.transactionID),
                ]
            )
            var encoded = try response.encoded(
                messageIntegrityKey: "remote-password",
                includeFingerprint: true
            )
            encoded[encoded.count - 1] ^= 0x01
            return encoded
        }
        let client = STUNBindingClient(transport: transport)

        XCTAssertThrowsError(
            try client.requestServerReflexiveAddress(
                localCredentials: ICECredentials(usernameFragment: "local", password: "local-password"),
                remoteCredentials: ICECredentials(usernameFragment: "remote", password: "remote-password"),
                priority: 1_864_403_327,
                role: .controlled,
                tieBreaker: 0x0102_0304_0506_0708,
                transactionID: transactionID,
                requireResponseMessageIntegrity: true,
                requireResponseFingerprint: true
            )
        ) { error in
            XCTAssertEqual(error as? ICEConnectivityCheckError, .invalidFingerprint)
        }
    }

    func testSTUNBindingClientRejectsInvalidResponseMessageIntegrity() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 7, count: 12))
        let transport = FakeSTUNDatagramTransport { requestData in
            let request = try STUNMessage(decoding: requestData)
            let response = STUNMessage(
                type: .bindingSuccessResponse,
                transactionID: request.transactionID,
                attributes: [
                    try .xorMappedAddressIPv4(address: "203.0.113.10", port: 12_347, transactionID: request.transactionID),
                ]
            )
            return try response.encoded(
                messageIntegrityKey: "wrong-password",
                includeFingerprint: true
            )
        }
        let client = STUNBindingClient(transport: transport)

        XCTAssertThrowsError(
            try client.requestServerReflexiveAddress(
                localCredentials: ICECredentials(usernameFragment: "local", password: "local-password"),
                remoteCredentials: ICECredentials(usernameFragment: "remote", password: "remote-password"),
                priority: 1_864_403_327,
                role: .controlled,
                tieBreaker: 0x0102_0304_0506_0708,
                transactionID: transactionID,
                requireResponseMessageIntegrity: true,
                requireResponseFingerprint: true
            )
        ) { error in
            XCTAssertEqual(error as? ICEConnectivityCheckError, .invalidMessageIntegrity)
        }
    }

    func testSTUNBindingClientRetriesTransportFailures() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 8, count: 12))
        let recorder = RetryRecorder()
        let transport = FakeSTUNDatagramTransport { requestData in
            let attempt = recorder.nextAttempt()
            if attempt < 3 {
                throw ICEConnectivityCheckError.missingMappedAddress
            }

            let request = try STUNMessage(decoding: requestData)
            let response = STUNMessage(
                type: .bindingSuccessResponse,
                transactionID: request.transactionID,
                attributes: [
                    try .xorMappedAddressIPv4(address: "203.0.113.11", port: 12_348, transactionID: request.transactionID),
                ]
            )
            return try response.encoded()
        }
        let client = STUNBindingClient(transport: transport)
        let result = try client.requestServerReflexiveAddress(
            localCredentials: ICECredentials(usernameFragment: "local", password: "local-password"),
            remoteCredentials: ICECredentials(usernameFragment: "remote", password: "remote-password"),
            priority: 1_864_403_327,
            role: .controlled,
            tieBreaker: 0x0102_0304_0506_0708,
            transactionID: transactionID,
            retryPolicy: STUNBindingRetryPolicy(maxAttempts: 3)
        )

        XCTAssertEqual(result.mappedAddress, STUNMappedAddress(address: "203.0.113.11", port: 12_348))
        XCTAssertEqual(recorder.attemptCount, 3)
    }

    func testSTUNBindingClientStopsAfterRetryPolicyMaxAttempts() throws {
        let transactionID = try STUNTransactionID(bytes: Array(repeating: 9, count: 12))
        let recorder = RetryRecorder()
        let transport = FakeSTUNDatagramTransport { _ in
            _ = recorder.nextAttempt()
            throw ICEConnectivityCheckError.missingMappedAddress
        }
        let client = STUNBindingClient(transport: transport)

        XCTAssertThrowsError(
            try client.requestServerReflexiveAddress(
                localCredentials: ICECredentials(usernameFragment: "local", password: "local-password"),
                remoteCredentials: ICECredentials(usernameFragment: "remote", password: "remote-password"),
                priority: 1_864_403_327,
                role: .controlled,
                tieBreaker: 0x0102_0304_0506_0708,
                transactionID: transactionID,
                retryPolicy: STUNBindingRetryPolicy(maxAttempts: 2)
            )
        ) { error in
            XCTAssertEqual(error as? ICEConnectivityCheckError, .missingMappedAddress)
        }
        XCTAssertEqual(recorder.attemptCount, 2)
    }
}

private struct FakeSTUNDatagramTransport: STUNDatagramTransport {
    var handler: @Sendable (Data) throws -> Data

    func send(_ data: Data) throws -> Data {
        try handler(data)
    }
}

private final class RetryRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var attempts = 0

    var attemptCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return attempts
    }

    func nextAttempt() -> Int {
        lock.lock()
        defer { lock.unlock() }
        attempts += 1
        return attempts
    }
}
