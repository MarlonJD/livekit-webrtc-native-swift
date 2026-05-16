import Foundation
import XCTest
@testable import LiveKitNativeWebRTC

final class TURNRelayCandidateTests: XCTestCase {
    func testBuildsRelayICECandidateFromIPv4RelayedAddress() throws {
        let relayedAddress = STUNMappedAddress(address: "192.0.2.55", port: 49_152)
        let binding = try channelBinding(channelNumber: 0x4000)

        let plan = TURNRelayCandidateFactory.makePlan(
            relayedAddress: relayedAddress,
            channelBinding: binding
        )

        XCTAssertEqual(plan.candidate.foundation, "turn-relay-16384")
        XCTAssertEqual(plan.candidate.componentID, .rtp)
        XCTAssertEqual(plan.candidate.transport, .udp)
        XCTAssertEqual(plan.candidate.address, "192.0.2.55")
        XCTAssertEqual(plan.candidate.port, 49_152)
        XCTAssertEqual(plan.candidate.type, .relayed)
        XCTAssertEqual(
            plan.candidate.priority,
            ICECandidatePriority(type: .relayed, localPreference: 100, componentID: .rtp).value
        )
    }

    func testRelayPriorityUsesRelayPreferenceAndRanksBelowHost() throws {
        let binding = try channelBinding(channelNumber: 0x4001)
        let localPreference: UInt16 = 250

        let candidate = TURNRelayCandidateFactory.makeCandidate(
            relayedAddress: STUNMappedAddress(address: "198.51.100.7", port: 61_000),
            channelBinding: binding,
            localPreference: localPreference
        )

        XCTAssertEqual(
            candidate.priority,
            ICECandidatePriority(type: .relayed, localPreference: localPreference, componentID: .rtp).value
        )
        XCTAssertLessThan(
            candidate.priority,
            ICECandidatePriority(type: .host, localPreference: localPreference, componentID: .rtp).value
        )
    }

    func testPreservesChannelBindingMetadataInPlan() throws {
        let binding = try TURNRelayChannelBinding(
            channelNumber: 0x4002,
            peerAddress: STUNMappedAddress(address: "203.0.113.9", port: 5_000)
        )
        let relayedAddress = STUNMappedAddress(address: "192.0.2.56", port: 49_153)

        let plan = TURNRelayCandidateFactory.makePlan(
            relayedAddress: relayedAddress,
            channelBinding: binding,
            foundation: "relay-foundation"
        )

        XCTAssertEqual(plan.relayedAddress, relayedAddress)
        XCTAssertEqual(plan.channelBinding, binding)
        XCTAssertEqual(plan.channelBinding.channelNumber, 0x4002)
        XCTAssertEqual(plan.channelBinding.peerAddress, STUNMappedAddress(address: "203.0.113.9", port: 5_000))
        XCTAssertEqual(plan.candidate.foundation, "relay-foundation")
    }

    func testInvalidChannelBindingIsRejectedBeforePlanning() {
        XCTAssertThrowsError(
            try TURNRelayChannelBinding(
                channelNumber: 0x3FFF,
                peerAddress: STUNMappedAddress(address: "203.0.113.10", port: 5_001)
            )
        ) { error in
            XCTAssertEqual(error as? TURNChannelDataError, .invalidChannelNumber(0x3FFF))
        }
    }

    private func channelBinding(channelNumber: UInt16) throws -> TURNRelayChannelBinding {
        try TURNRelayChannelBinding(
            channelNumber: channelNumber,
            peerAddress: STUNMappedAddress(address: "203.0.113.9", port: 5_000)
        )
    }
}
