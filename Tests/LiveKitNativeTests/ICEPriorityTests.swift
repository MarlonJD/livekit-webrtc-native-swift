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
}
