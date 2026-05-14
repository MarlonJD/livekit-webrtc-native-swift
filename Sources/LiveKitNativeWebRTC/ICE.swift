import Foundation

package enum ICECandidateType: String, Equatable, Sendable {
    case host
    case peerReflexive
    case serverReflexive
    case relayed

    package var typePreference: UInt32 {
        switch self {
        case .host:
            126
        case .peerReflexive:
            110
        case .serverReflexive:
            100
        case .relayed:
            0
        }
    }
}

package enum ICEComponentID: UInt8, Equatable, Sendable {
    case rtp = 1
    case rtcp = 2
}

package enum ICETransportProtocol: String, Equatable, Sendable {
    case udp
    case tcp
}

package struct ICECandidatePriority: Equatable, Sendable {
    package var type: ICECandidateType
    package var localPreference: UInt16
    package var componentID: ICEComponentID

    package init(
        type: ICECandidateType,
        localPreference: UInt16,
        componentID: ICEComponentID = .rtp
    ) {
        self.type = type
        self.localPreference = localPreference
        self.componentID = componentID
    }

    package var value: UInt32 {
        (type.typePreference << 24) +
            (UInt32(localPreference) << 8) +
            (256 - UInt32(componentID.rawValue))
    }

    package static func candidatePairPriority(
        local: UInt32,
        remote: UInt32,
        isControlling: Bool
    ) -> UInt64 {
        let controlling = isControlling ? local : remote
        let controlled = isControlling ? remote : local
        let lesser = UInt64(min(controlling, controlled))
        let greater = UInt64(max(controlling, controlled))
        let tieBreaker: UInt64 = controlling > controlled ? 1 : 0

        return (lesser << 32) + (2 * greater) + tieBreaker
    }
}

package struct ICECandidate: Equatable, Sendable {
    package var foundation: String
    package var componentID: ICEComponentID
    package var transport: ICETransportProtocol
    package var priority: UInt32
    package var address: String
    package var port: UInt16
    package var type: ICECandidateType

    package init(
        foundation: String,
        componentID: ICEComponentID,
        transport: ICETransportProtocol,
        priority: UInt32,
        address: String,
        port: UInt16,
        type: ICECandidateType
    ) {
        self.foundation = foundation
        self.componentID = componentID
        self.transport = transport
        self.priority = priority
        self.address = address
        self.port = port
        self.type = type
    }

    package var sdpAttributeValue: String {
        "candidate:\(foundation) \(componentID.rawValue) \(transport.rawValue.uppercased()) \(priority) \(address) \(port) typ \(type.sdpToken)"
    }
}

private extension ICECandidateType {
    var sdpToken: String {
        switch self {
        case .host:
            "host"
        case .peerReflexive:
            "prflx"
        case .serverReflexive:
            "srflx"
        case .relayed:
            "relay"
        }
    }
}
