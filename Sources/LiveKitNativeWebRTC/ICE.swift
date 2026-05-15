import Foundation
import Darwin

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

package struct ICECandidatePair: Equatable, Sendable {
    package var local: ICECandidate
    package var remote: ICECandidate
    package var priority: UInt64
    package var state: ICECandidatePairState
    package var nominated: Bool

    package init(
        local: ICECandidate,
        remote: ICECandidate,
        isControlling: Bool,
        state: ICECandidatePairState = .frozen,
        nominated: Bool = false
    ) {
        self.local = local
        self.remote = remote
        self.priority = ICECandidatePriority.candidatePairPriority(
            local: local.priority,
            remote: remote.priority,
            isControlling: isControlling
        )
        self.state = state
        self.nominated = nominated
    }
}

package enum ICECandidatePairState: String, Equatable, Sendable {
    case frozen
    case waiting
    case inProgress
    case succeeded
    case failed
}

package struct ICECandidateChecklist: Equatable, Sendable {
    package private(set) var pairs: [ICECandidatePair]

    package init(localCandidates: [ICECandidate], remoteCandidates: [ICECandidate], isControlling: Bool) {
        self.pairs = localCandidates.flatMap { local in
            remoteCandidates.map { remote in
                ICECandidatePair(local: local, remote: remote, isControlling: isControlling)
            }
        }
        .sorted { $0.priority > $1.priority }
    }

    package var nextWaitingPair: ICECandidatePair? {
        pairs.first { $0.state == .waiting }
    }

    package var nominatedPair: ICECandidatePair? {
        pairs.first { $0.nominated && $0.state == .succeeded }
    }

    package mutating func unfreezeInitialPairs() {
        for index in pairs.indices where pairs[index].state == .frozen {
            pairs[index].state = .waiting
        }
    }

    package mutating func markInProgress(localFoundation: String, remoteFoundation: String) {
        updatePair(localFoundation: localFoundation, remoteFoundation: remoteFoundation) {
            $0.state = .inProgress
        }
    }

    package mutating func markSucceeded(localFoundation: String, remoteFoundation: String, nominated: Bool) {
        updatePair(localFoundation: localFoundation, remoteFoundation: remoteFoundation) {
            $0.state = .succeeded
            $0.nominated = nominated
        }
    }

    package mutating func markFailed(localFoundation: String, remoteFoundation: String) {
        updatePair(localFoundation: localFoundation, remoteFoundation: remoteFoundation) {
            $0.state = .failed
        }
    }

    private mutating func updatePair(
        localFoundation: String,
        remoteFoundation: String,
        update: (inout ICECandidatePair) -> Void
    ) {
        guard let index = pairs.firstIndex(where: {
            $0.local.foundation == localFoundation && $0.remote.foundation == remoteFoundation
        }) else {
            return
        }

        update(&pairs[index])
    }
}

package struct ICEInterfaceAddress: Equatable, Sendable {
    package var name: String
    package var address: String
    package var localPreference: UInt16

    package init(name: String, address: String, localPreference: UInt16) {
        self.name = name
        self.address = address
        self.localPreference = localPreference
    }
}

package enum ICEHostCandidateGatherer {
    package static func gatherHostCandidates(port: UInt16, includeLoopback: Bool = false) -> [ICECandidate] {
        candidates(from: localInterfaceAddresses(includeLoopback: includeLoopback), port: port)
    }

    package static func candidates(
        from addresses: [ICEInterfaceAddress],
        port: UInt16,
        componentID: ICEComponentID = .rtp
    ) -> [ICECandidate] {
        addresses.enumerated().map { index, address in
            let priority = ICECandidatePriority(
                type: .host,
                localPreference: address.localPreference,
                componentID: componentID
            ).value

            return ICECandidate(
                foundation: "\(index + 1)",
                componentID: componentID,
                transport: .udp,
                priority: priority,
                address: address.address,
                port: port,
                type: .host
            )
        }
    }

    package static func localInterfaceAddresses(includeLoopback: Bool = false) -> [ICEInterfaceAddress] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
            return []
        }
        defer { freeifaddrs(interfaces) }

        var results: [ICEInterfaceAddress] = []
        var seenAddresses = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = firstInterface

        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }

            let flags = current.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0 else {
                continue
            }

            if !includeLoopback, flags & UInt32(IFF_LOOPBACK) != 0 {
                continue
            }

            guard let socketAddress = current.pointee.ifa_addr else {
                continue
            }

            let family = Int32(socketAddress.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else {
                continue
            }

            guard let address = numericHostAddress(from: socketAddress, family: family) else {
                continue
            }

            guard seenAddresses.insert(address).inserted else {
                continue
            }

            let preference = UInt16(max(1, Int(UInt16.max) - results.count))
            results.append(
                ICEInterfaceAddress(
                    name: String(cString: current.pointee.ifa_name),
                    address: address,
                    localPreference: preference
                )
            )
        }

        return results
    }

    private static func numericHostAddress(from socketAddress: UnsafePointer<sockaddr>, family: Int32) -> String? {
        let length: socklen_t
        switch family {
        case AF_INET:
            length = socklen_t(MemoryLayout<sockaddr_in>.size)
        case AF_INET6:
            length = socklen_t(MemoryLayout<sockaddr_in6>.size)
        default:
            return nil
        }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            socketAddress,
            length,
            &host,
            socklen_t(host.count),
            nil,
            0,
            NI_NUMERICHOST
        )

        guard result == 0 else {
            return nil
        }

        let hostString = host.withUnsafeBufferPointer { buffer in
            let terminatorIndex = buffer.firstIndex(of: 0) ?? buffer.endIndex
            let bytes = buffer[..<terminatorIndex].map { UInt8(bitPattern: $0) }
            return String(decoding: bytes, as: UTF8.self)
        }

        return hostString.split(separator: "%", maxSplits: 1).first.map(String.init)
    }
}

package enum ICEAgentRole: Equatable, Sendable {
    case controlling
    case controlled
}

package enum ICEConnectivityCheckRequestFactory {
    package static func makeBindingRequest(
        localCredentials: ICECredentials,
        remoteCredentials: ICECredentials,
        priority: UInt32,
        role: ICEAgentRole,
        tieBreaker: UInt64,
        useCandidate: Bool = false,
        transactionID: STUNTransactionID = .random()
    ) -> STUNMessage {
        var attributes: [STUNAttribute] = [
            .username("\(remoteCredentials.usernameFragment):\(localCredentials.usernameFragment)"),
            .priority(priority),
        ]

        switch role {
        case .controlling:
            attributes.append(.iceControlling(tieBreaker: tieBreaker))
        case .controlled:
            attributes.append(.iceControlled(tieBreaker: tieBreaker))
        }

        if useCandidate {
            attributes.append(.useCandidate)
        }

        return STUNMessage(type: .bindingRequest, transactionID: transactionID, attributes: attributes)
    }
}

package struct ICEConnectivityCheckResult: Equatable, Sendable {
    package var mappedAddress: STUNMappedAddress
    package var response: STUNMessage

    package init(mappedAddress: STUNMappedAddress, response: STUNMessage) {
        self.mappedAddress = mappedAddress
        self.response = response
    }
}

package enum ICEConnectivityCheckError: Error, Equatable, Sendable {
    case transactionMismatch
    case unexpectedResponseType(UInt16)
    case missingMappedAddress
}

package protocol STUNDatagramTransport: Sendable {
    func send(_ data: Data) throws -> Data
}

package struct STUNBindingClient: Sendable {
    package var transport: any STUNDatagramTransport

    package init(transport: any STUNDatagramTransport) {
        self.transport = transport
    }

    package func requestServerReflexiveAddress(
        localCredentials: ICECredentials,
        remoteCredentials: ICECredentials,
        priority: UInt32,
        role: ICEAgentRole,
        tieBreaker: UInt64,
        transactionID: STUNTransactionID = .random()
    ) throws -> ICEConnectivityCheckResult {
        let request = ICEConnectivityCheckRequestFactory.makeBindingRequest(
            localCredentials: localCredentials,
            remoteCredentials: remoteCredentials,
            priority: priority,
            role: role,
            tieBreaker: tieBreaker,
            transactionID: transactionID
        )
        let responseData = try transport.send(try request.encoded())
        let response = try STUNMessage(decoding: responseData)

        guard response.transactionID == transactionID else {
            throw ICEConnectivityCheckError.transactionMismatch
        }

        guard response.type == .bindingSuccessResponse else {
            throw ICEConnectivityCheckError.unexpectedResponseType(response.type.rawValue)
        }

        guard let mappedAddress = try response.firstAttribute(.xorMappedAddress)?.xorMappedAddressValue else {
            throw ICEConnectivityCheckError.missingMappedAddress
        }

        return ICEConnectivityCheckResult(mappedAddress: mappedAddress, response: response)
    }
}

package final class STUNUDPSocketTransport: STUNDatagramTransport, @unchecked Sendable {
    private let host: String
    private let port: UInt16
    private let timeoutMilliseconds: Int

    package init(host: String, port: UInt16, timeoutMilliseconds: Int = 1_000) {
        self.host = host
        self.port = port
        self.timeoutMilliseconds = timeoutMilliseconds
    }

    package func send(_ data: Data) throws -> Data {
        var hints = addrinfo(
            ai_flags: AI_NUMERICSERV,
            ai_family: AF_INET,
            ai_socktype: SOCK_DGRAM,
            ai_protocol: IPPROTO_UDP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var resolvedAddresses: UnsafeMutablePointer<addrinfo>?
        let resolveResult = getaddrinfo(host, String(port), &hints, &resolvedAddresses)
        guard resolveResult == 0, let address = resolvedAddresses else {
            throw ICEConnectivityCheckError.missingMappedAddress
        }
        defer { freeaddrinfo(resolvedAddresses) }

        let socketDescriptor = Darwin.socket(address.pointee.ai_family, address.pointee.ai_socktype, address.pointee.ai_protocol)
        guard socketDescriptor >= 0 else {
            throw ICEConnectivityCheckError.missingMappedAddress
        }
        defer { Darwin.close(socketDescriptor) }

        var timeout = timeval(
            tv_sec: timeoutMilliseconds / 1_000,
            tv_usec: Int32((timeoutMilliseconds % 1_000) * 1_000)
        )
        setsockopt(
            socketDescriptor,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout<timeval>.size)
        )

        let sentCount = data.withUnsafeBytes { buffer in
            Darwin.sendto(
                socketDescriptor,
                buffer.baseAddress,
                data.count,
                0,
                address.pointee.ai_addr,
                address.pointee.ai_addrlen
            )
        }

        guard sentCount == data.count else {
            throw ICEConnectivityCheckError.missingMappedAddress
        }

        var buffer = [UInt8](repeating: 0, count: 1_500)
        let receivedCount = Darwin.recv(socketDescriptor, &buffer, buffer.count, 0)
        guard receivedCount > 0 else {
            throw ICEConnectivityCheckError.missingMappedAddress
        }

        return Data(buffer.prefix(receivedCount))
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
