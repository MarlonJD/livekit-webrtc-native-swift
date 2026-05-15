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
}

private struct FakeSTUNDatagramTransport: STUNDatagramTransport {
    var handler: @Sendable (Data) throws -> Data

    func send(_ data: Data) throws -> Data {
        try handler(data)
    }
}
