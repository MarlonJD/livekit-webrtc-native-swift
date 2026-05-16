import Foundation

package struct TURNRelayCandidatePlan: Equatable, Sendable {
    package var relayedAddress: STUNMappedAddress
    package var channelBinding: TURNRelayChannelBinding
    package var candidate: ICECandidate

    package init(
        relayedAddress: STUNMappedAddress,
        channelBinding: TURNRelayChannelBinding,
        candidate: ICECandidate
    ) {
        self.relayedAddress = relayedAddress
        self.channelBinding = channelBinding
        self.candidate = candidate
    }
}

package enum TURNRelayCandidateFactory {
    package static let defaultLocalPreference: UInt16 = 100

    package static func makePlan(
        relayedAddress: STUNMappedAddress,
        channelBinding: TURNRelayChannelBinding,
        foundation: String? = nil,
        localPreference: UInt16 = defaultLocalPreference
    ) -> TURNRelayCandidatePlan {
        let candidate = ICECandidate(
            foundation: foundation ?? defaultFoundation(for: channelBinding),
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(
                type: .relayed,
                localPreference: localPreference,
                componentID: .rtp
            ).value,
            address: relayedAddress.address,
            port: relayedAddress.port,
            type: .relayed
        )

        return TURNRelayCandidatePlan(
            relayedAddress: relayedAddress,
            channelBinding: channelBinding,
            candidate: candidate
        )
    }

    package static func makeCandidate(
        relayedAddress: STUNMappedAddress,
        channelBinding: TURNRelayChannelBinding,
        foundation: String? = nil,
        localPreference: UInt16 = defaultLocalPreference
    ) -> ICECandidate {
        makePlan(
            relayedAddress: relayedAddress,
            channelBinding: channelBinding,
            foundation: foundation,
            localPreference: localPreference
        ).candidate
    }

    private static func defaultFoundation(for channelBinding: TURNRelayChannelBinding) -> String {
        "turn-relay-\(channelBinding.channelNumber)"
    }
}
