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

    package init(sdpAttributeValue: String) throws {
        let candidateLine = sdpAttributeValue.hasPrefix("a=")
            ? String(sdpAttributeValue.dropFirst(2))
            : sdpAttributeValue
        let candidatePrefix = "candidate:"
        guard candidateLine.hasPrefix(candidatePrefix) else {
            throw ICECandidateSDPError.missingCandidatePrefix
        }

        let fields = candidateLine
            .dropFirst(candidatePrefix.count)
            .split(separator: " ")
            .map(String.init)

        guard fields.count >= 8 else {
            throw ICECandidateSDPError.malformedCandidate
        }

        guard let componentRawValue = UInt8(fields[1]),
              let componentID = ICEComponentID(rawValue: componentRawValue)
        else {
            throw ICECandidateSDPError.unsupportedComponent(fields[1])
        }

        guard let transport = ICETransportProtocol(sdpToken: fields[2]) else {
            throw ICECandidateSDPError.unsupportedTransport(fields[2])
        }

        guard let priority = UInt32(fields[3]) else {
            throw ICECandidateSDPError.invalidPriority(fields[3])
        }

        guard let port = UInt16(fields[5]) else {
            throw ICECandidateSDPError.invalidPort(fields[5])
        }

        guard fields[6].lowercased() == "typ",
              let type = ICECandidateType(sdpToken: fields[7])
        else {
            throw ICECandidateSDPError.unsupportedType(fields.indices.contains(7) ? fields[7] : "")
        }

        self.init(
            foundation: fields[0],
            componentID: componentID,
            transport: transport,
            priority: priority,
            address: fields[4],
            port: port,
            type: type
        )
    }

    package var sdpAttributeValue: String {
        "candidate:\(foundation) \(componentID.rawValue) \(transport.rawValue.uppercased()) \(priority) \(address) \(port) typ \(type.sdpToken)"
    }

    package var localPreference: UInt16 {
        UInt16((priority >> 8) & 0xFFFF)
    }
}

package enum ICECandidateSDPError: Error, Equatable, Sendable {
    case missingCandidatePrefix
    case malformedCandidate
    case unsupportedComponent(String)
    case unsupportedTransport(String)
    case invalidPriority(String)
    case invalidPort(String)
    case unsupportedType(String)
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

package enum ICEAgentState: String, Equatable, Sendable {
    case new
    case checking
    case connected
    case failed
    case closed
}

package enum ICEPairNominationPolicy: String, Equatable, Sendable {
    case validateOnly
    case nominateFirstSuccessful
}

package struct ICECandidateChecklist: Equatable, Sendable {
    package private(set) var localCandidates: [ICECandidate]
    package private(set) var remoteCandidates: [ICECandidate]
    package private(set) var pairs: [ICECandidatePair]

    package init(localCandidates: [ICECandidate], remoteCandidates: [ICECandidate], isControlling: Bool) {
        self.localCandidates = localCandidates
        self.remoteCandidates = remoteCandidates
        self.pairs = Self.makePairs(
            localCandidates: localCandidates,
            remoteCandidates: remoteCandidates,
            isControlling: isControlling
        )
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

    package mutating func nominateSucceededPair(localFoundation: String, remoteFoundation: String) {
        updatePair(localFoundation: localFoundation, remoteFoundation: remoteFoundation) {
            guard $0.state == .succeeded else {
                return
            }

            $0.nominated = true
        }
    }

    package mutating func markFailed(localFoundation: String, remoteFoundation: String) {
        updatePair(localFoundation: localFoundation, remoteFoundation: remoteFoundation) {
            $0.state = .failed
        }
    }

    package mutating func addLocalCandidate(_ candidate: ICECandidate, isControlling: Bool) {
        guard !localCandidates.contains(candidate) else {
            return
        }

        localCandidates.append(candidate)
        pairs.append(
            contentsOf: remoteCandidates.map { remote in
                ICECandidatePair(local: candidate, remote: remote, isControlling: isControlling)
            }
        )
        sortPairs()
    }

    package mutating func addRemoteCandidate(_ candidate: ICECandidate, isControlling: Bool) {
        guard !remoteCandidates.contains(candidate) else {
            return
        }

        remoteCandidates.append(candidate)
        pairs.append(
            contentsOf: localCandidates.map { local in
                ICECandidatePair(local: local, remote: candidate, isControlling: isControlling)
            }
        )
        sortPairs()
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

    private mutating func sortPairs() {
        pairs.sort { $0.priority > $1.priority }
    }

    private static func makePairs(
        localCandidates: [ICECandidate],
        remoteCandidates: [ICECandidate],
        isControlling: Bool
    ) -> [ICECandidatePair] {
        localCandidates.flatMap { local in
            remoteCandidates.map { remote in
                ICECandidatePair(local: local, remote: remote, isControlling: isControlling)
            }
        }
        .sorted { $0.priority > $1.priority }
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

package struct STUNServerEndpoint: Equatable, Sendable {
    package var host: String
    package var port: UInt16

    package init(host: String, port: UInt16 = 3_478) {
        self.host = host
        self.port = port
    }

    package init?(iceURL: String) {
        let lowercasedURL = iceURL.lowercased()
        guard lowercasedURL.hasPrefix("stun:") else {
            return nil
        }

        let remainder = String(iceURL.dropFirst("stun:".count))
        let parts = remainder.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let hostPort = String(parts[0])

        if parts.count == 2,
           let queryItems = URLComponents(string: "stun://ignored?\(parts[1])")?.queryItems,
           let transport = queryItems.first(where: { $0.name.lowercased() == "transport" })?.value,
           transport.lowercased() != "udp" {
            return nil
        }

        let parsed: (host: String, port: UInt16)?
        if hostPort.hasPrefix("["),
           let endBracket = hostPort.firstIndex(of: "]") {
            let host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<endBracket])
            let portStart = hostPort.index(after: endBracket)
            if portStart < hostPort.endIndex, hostPort[portStart] == ":" {
                let portString = String(hostPort[hostPort.index(after: portStart)...])
                guard let port = UInt16(portString) else {
                    return nil
                }
                parsed = (host, port)
            } else {
                parsed = (host, 3_478)
            }
        } else if let lastColon = hostPort.lastIndex(of: ":"),
                  hostPort[..<lastColon].contains(":") == false {
            let host = String(hostPort[..<lastColon])
            let portString = String(hostPort[hostPort.index(after: lastColon)...])
            guard let port = UInt16(portString) else {
                return nil
            }
            parsed = (host, port)
        } else {
            parsed = (hostPort, 3_478)
        }

        guard let parsed, !parsed.host.isEmpty else {
            return nil
        }

        self.init(host: parsed.host, port: parsed.port)
    }

    package static func endpoints(from iceServers: [ICEServer]) -> [STUNServerEndpoint] {
        var endpoints: [STUNServerEndpoint] = []
        var seen = Set<String>()

        for server in iceServers {
            for url in server.urls {
                guard let endpoint = STUNServerEndpoint(iceURL: url) else {
                    continue
                }

                let key = "\(endpoint.host.lowercased()):\(endpoint.port)"
                guard seen.insert(key).inserted else {
                    continue
                }

                endpoints.append(endpoint)
            }
        }

        return endpoints
    }
}

private func parseICEURLHostPort(_ hostPort: String, defaultPort: UInt16) -> (host: String, port: UInt16)? {
    let parsed: (host: String, port: UInt16)?
    if hostPort.hasPrefix("["),
       let endBracket = hostPort.firstIndex(of: "]") {
        let host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<endBracket])
        let portStart = hostPort.index(after: endBracket)
        if portStart < hostPort.endIndex, hostPort[portStart] == ":" {
            let portString = String(hostPort[hostPort.index(after: portStart)...])
            guard let port = UInt16(portString) else {
                return nil
            }
            parsed = (host, port)
        } else {
            parsed = (host, defaultPort)
        }
    } else if let lastColon = hostPort.lastIndex(of: ":"),
              hostPort[..<lastColon].contains(":") == false {
        let host = String(hostPort[..<lastColon])
        let portString = String(hostPort[hostPort.index(after: lastColon)...])
        guard let port = UInt16(portString) else {
            return nil
        }
        parsed = (host, port)
    } else {
        parsed = (hostPort, defaultPort)
    }

    guard let parsed, !parsed.host.isEmpty else {
        return nil
    }

    return parsed
}

package struct TURNServerEndpoint: Equatable, Sendable {
    package var host: String
    package var port: UInt16
    package var transport: ICETransportProtocol
    package var isSecure: Bool
    package var username: String?
    package var credential: String?

    package init(
        host: String,
        port: UInt16,
        transport: ICETransportProtocol,
        isSecure: Bool,
        username: String? = nil,
        credential: String? = nil
    ) {
        self.host = host
        self.port = port
        self.transport = transport
        self.isSecure = isSecure
        self.username = username
        self.credential = credential
    }

    package init?(iceURL: String, username: String? = nil, credential: String? = nil) {
        let lowercasedURL = iceURL.lowercased()
        let isSecure: Bool
        let remainder: String
        if lowercasedURL.hasPrefix("turns:") {
            isSecure = true
            remainder = String(iceURL.dropFirst("turns:".count))
        } else if lowercasedURL.hasPrefix("turn:") {
            isSecure = false
            remainder = String(iceURL.dropFirst("turn:".count))
        } else {
            return nil
        }

        let parts = remainder.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let hostPort = String(parts[0])
        var transport: ICETransportProtocol = isSecure ? .tcp : .udp

        if parts.count == 2 {
            guard let queryItems = URLComponents(string: "turn://ignored?\(parts[1])")?.queryItems else {
                return nil
            }
            if let transportValue = queryItems.first(where: { $0.name.lowercased() == "transport" })?.value {
                guard let parsedTransport = ICETransportProtocol(rawValue: transportValue.lowercased()) else {
                    return nil
                }
                transport = parsedTransport
            }
        }

        guard let parsed = parseICEURLHostPort(hostPort, defaultPort: isSecure ? 5_349 : 3_478) else {
            return nil
        }

        self.init(
            host: parsed.host,
            port: parsed.port,
            transport: transport,
            isSecure: isSecure,
            username: username,
            credential: credential
        )
    }

    package static func endpoints(from iceServers: [ICEServer]) -> [TURNServerEndpoint] {
        var endpoints: [TURNServerEndpoint] = []
        var seen = Set<String>()

        for server in iceServers {
            for url in server.urls {
                guard let endpoint = TURNServerEndpoint(
                    iceURL: url,
                    username: server.username,
                    credential: server.credential
                ) else {
                    continue
                }

                let key = [
                    endpoint.isSecure ? "turns" : "turn",
                    endpoint.transport.rawValue,
                    endpoint.host.lowercased(),
                    String(endpoint.port),
                    endpoint.username ?? "",
                    endpoint.credential ?? "",
                ].joined(separator: "|")
                guard seen.insert(key).inserted else {
                    continue
                }

                endpoints.append(endpoint)
            }
        }

        return endpoints
    }
}

package struct STUNServerReflexiveCandidateGatherer: Sendable {
    package var makeTransport: @Sendable (STUNServerEndpoint) throws -> any STUNDatagramTransport

    package init(
        makeTransport: @escaping @Sendable (STUNServerEndpoint) throws -> any STUNDatagramTransport = { endpoint in
            STUNUDPSocketTransport(host: endpoint.host, port: endpoint.port)
        }
    ) {
        self.makeTransport = makeTransport
    }

    package func gatherCandidates(
        for localCandidate: ICECandidate,
        iceServers: [ICEServer],
        retryPolicy: STUNBindingRetryPolicy = .once
    ) -> [ICECandidate] {
        guard localCandidate.transport == .udp,
              localCandidate.componentID == .rtp
        else {
            return []
        }

        var candidates: [ICECandidate] = []
        var seenMappedAddresses = Set<String>()
        let endpoints = STUNServerEndpoint.endpoints(from: iceServers)

        for (index, endpoint) in endpoints.enumerated() {
            do {
                let result = try STUNBindingClient(
                    transport: try makeTransport(endpoint)
                ).requestMappedAddress(retryPolicy: retryPolicy)
                let key = "\(result.mappedAddress.address):\(result.mappedAddress.port)"
                guard seenMappedAddresses.insert(key).inserted else {
                    continue
                }

                candidates.append(
                    ICECandidate(
                        foundation: "\(localCandidate.foundation)-srflx-\(index + 1)",
                        componentID: localCandidate.componentID,
                        transport: .udp,
                        priority: ICECandidatePriority(
                            type: .serverReflexive,
                            localPreference: localCandidate.localPreference,
                            componentID: localCandidate.componentID
                        ).value,
                        address: result.mappedAddress.address,
                        port: result.mappedAddress.port,
                        type: .serverReflexive
                    )
                )
            } catch {
                continue
            }
        }

        return candidates
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

package struct ICEAgentConfiguration: Equatable, Sendable {
    package var localCredentials: ICECredentials
    package var remoteCredentials: ICECredentials
    package var role: ICEAgentRole
    package var tieBreaker: UInt64
    package var nominationPolicy: ICEPairNominationPolicy
    package var retryPolicy: STUNBindingRetryPolicy
    package var requireResponseMessageIntegrity: Bool
    package var requireResponseFingerprint: Bool

    package init(
        localCredentials: ICECredentials,
        remoteCredentials: ICECredentials,
        role: ICEAgentRole,
        tieBreaker: UInt64,
        nominationPolicy: ICEPairNominationPolicy = .nominateFirstSuccessful,
        retryPolicy: STUNBindingRetryPolicy = .connectivityCheck,
        requireResponseMessageIntegrity: Bool = false,
        requireResponseFingerprint: Bool = false
    ) {
        self.localCredentials = localCredentials
        self.remoteCredentials = remoteCredentials
        self.role = role
        self.tieBreaker = tieBreaker
        self.nominationPolicy = nominationPolicy
        self.retryPolicy = retryPolicy
        self.requireResponseMessageIntegrity = requireResponseMessageIntegrity
        self.requireResponseFingerprint = requireResponseFingerprint
    }
}

package struct ICEAgentCheckSummary: Equatable, Sendable {
    package var state: ICEAgentState
    package var checkedPairCount: Int
    package var failedPairCount: Int
    package var selectedPair: ICECandidatePair?

    package init(
        state: ICEAgentState,
        checkedPairCount: Int,
        failedPairCount: Int,
        selectedPair: ICECandidatePair?
    ) {
        self.state = state
        self.checkedPairCount = checkedPairCount
        self.failedPairCount = failedPairCount
        self.selectedPair = selectedPair
    }
}

package enum ICEConnectivityCheckKind: String, Equatable, Sendable {
    case ordinary
    case triggered
}

package struct ICEConnectivityCheckPacingPolicy: Equatable, Sendable {
    package var intervalSeconds: TimeInterval
    package var transactionTimeoutSeconds: TimeInterval
    package var maxTriggeredChecksPerBurst: Int

    package init(
        intervalSeconds: TimeInterval = 0.050,
        transactionTimeoutSeconds: TimeInterval = 5,
        maxTriggeredChecksPerBurst: Int = 16
    ) {
        self.intervalSeconds = max(0, intervalSeconds)
        self.transactionTimeoutSeconds = max(0, transactionTimeoutSeconds)
        self.maxTriggeredChecksPerBurst = max(0, maxTriggeredChecksPerBurst)
    }

    package static let standard = ICEConnectivityCheckPacingPolicy()

    package func dueTime(startTime: TimeInterval, index: Int) -> TimeInterval {
        startTime + (Double(max(0, index)) * intervalSeconds)
    }

    package func timeoutTime(for dueAt: TimeInterval) -> TimeInterval {
        dueAt + transactionTimeoutSeconds
    }
}

package struct ICEConnectivityCheckScheduleEntry: Equatable, Sendable {
    package var pair: ICECandidatePair
    package var kind: ICEConnectivityCheckKind
    package var dueAt: TimeInterval
    package var timeoutAt: TimeInterval
    package var shouldNominate: Bool

    package init(
        pair: ICECandidatePair,
        kind: ICEConnectivityCheckKind,
        dueAt: TimeInterval,
        timeoutAt: TimeInterval,
        shouldNominate: Bool
    ) {
        self.pair = pair
        self.kind = kind
        self.dueAt = dueAt
        self.timeoutAt = timeoutAt
        self.shouldNominate = shouldNominate
    }
}

package struct ICEConnectivityCheckScheduler: Equatable, Sendable {
    package var policy: ICEConnectivityCheckPacingPolicy

    package init(policy: ICEConnectivityCheckPacingPolicy = .standard) {
        self.policy = policy
    }

    package func schedule(
        checklist: ICECandidateChecklist,
        triggeredPairs: [ICECandidatePair] = [],
        startTime: TimeInterval = 0,
        nominationPolicy: ICEPairNominationPolicy = .nominateFirstSuccessful
    ) -> [ICEConnectivityCheckScheduleEntry] {
        var scheduledKeys = Set<ICECandidatePairKey>()
        var orderedPairs: [(ICECandidatePair, ICEConnectivityCheckKind)] = []

        for pair in triggeredPairs.prefix(policy.maxTriggeredChecksPerBurst) where pair.isEligibleForConnectivityCheck {
            let key = ICECandidatePairKey(pair)
            guard scheduledKeys.insert(key).inserted else {
                continue
            }
            orderedPairs.append((pair, .triggered))
        }

        for pair in checklist.pairs where pair.isEligibleForConnectivityCheck {
            let key = ICECandidatePairKey(pair)
            guard scheduledKeys.insert(key).inserted else {
                continue
            }
            orderedPairs.append((pair, .ordinary))
        }

        return orderedPairs.enumerated().map { index, item in
            let dueAt = policy.dueTime(startTime: startTime, index: index)
            return ICEConnectivityCheckScheduleEntry(
                pair: item.0,
                kind: item.1,
                dueAt: dueAt,
                timeoutAt: policy.timeoutTime(for: dueAt),
                shouldNominate: nominationPolicy == .nominateFirstSuccessful
            )
        }
    }
}

package enum ICERoleAssertion: Equatable, Sendable {
    case controlling(tieBreaker: UInt64)
    case controlled(tieBreaker: UInt64)

    package init?(message: STUNMessage) {
        if let tieBreaker = message.firstAttribute(.iceControlling)?.uint64Value {
            self = .controlling(tieBreaker: tieBreaker)
            return
        }

        if let tieBreaker = message.firstAttribute(.iceControlled)?.uint64Value {
            self = .controlled(tieBreaker: tieBreaker)
            return
        }

        return nil
    }

    package var role: ICEAgentRole {
        switch self {
        case .controlling:
            .controlling
        case .controlled:
            .controlled
        }
    }

    package var tieBreaker: UInt64 {
        switch self {
        case let .controlling(tieBreaker), let .controlled(tieBreaker):
            tieBreaker
        }
    }
}

package enum ICERoleConflictAction: Equatable, Sendable {
    case none
    case switchRole(ICEAgentRole)
    case rejectWithRoleConflict
}

package struct ICERoleConflictResolution: Equatable, Sendable {
    package var resolvedRole: ICEAgentRole
    package var action: ICERoleConflictAction

    package init(resolvedRole: ICEAgentRole, action: ICERoleConflictAction) {
        self.resolvedRole = resolvedRole
        self.action = action
    }

    package var shouldRejectRequest: Bool {
        action == .rejectWithRoleConflict
    }
}

package enum ICERoleConflictResolver {
    package static func resolve(
        localRole: ICEAgentRole,
        localTieBreaker: UInt64,
        remoteAssertion: ICERoleAssertion
    ) -> ICERoleConflictResolution {
        guard localRole == remoteAssertion.role else {
            return ICERoleConflictResolution(resolvedRole: localRole, action: .none)
        }

        switch localRole {
        case .controlling:
            if localTieBreaker >= remoteAssertion.tieBreaker {
                return ICERoleConflictResolution(
                    resolvedRole: .controlling,
                    action: .rejectWithRoleConflict
                )
            }
            return ICERoleConflictResolution(
                resolvedRole: .controlled,
                action: .switchRole(.controlled)
            )
        case .controlled:
            if localTieBreaker >= remoteAssertion.tieBreaker {
                return ICERoleConflictResolution(
                    resolvedRole: .controlling,
                    action: .switchRole(.controlling)
                )
            }
            return ICERoleConflictResolution(
                resolvedRole: .controlled,
                action: .rejectWithRoleConflict
            )
        }
    }
}

package protocol ICEConnectivityChecking: Sendable {
    func checkCandidatePair(
        _ pair: ICECandidatePair,
        configuration: ICEAgentConfiguration,
        nominate: Bool
    ) throws -> ICEConnectivityCheckResult
}

package struct STUNICEConnectivityChecker: ICEConnectivityChecking {
    package var makeTransport: @Sendable (ICECandidatePair) throws -> any STUNDatagramTransport

    package init(
        makeTransport: @escaping @Sendable (ICECandidatePair) throws -> any STUNDatagramTransport = { pair in
            STUNUDPSocketTransport(host: pair.remote.address, port: pair.remote.port)
        }
    ) {
        self.makeTransport = makeTransport
    }

    package func checkCandidatePair(
        _ pair: ICECandidatePair,
        configuration: ICEAgentConfiguration,
        nominate: Bool
    ) throws -> ICEConnectivityCheckResult {
        let client = STUNBindingClient(transport: try makeTransport(pair))
        return try client.requestServerReflexiveAddress(
            localCredentials: configuration.localCredentials,
            remoteCredentials: configuration.remoteCredentials,
            priority: pair.local.priority,
            role: configuration.role,
            tieBreaker: configuration.tieBreaker,
            useCandidate: nominate,
            requireResponseMessageIntegrity: configuration.requireResponseMessageIntegrity,
            requireResponseFingerprint: configuration.requireResponseFingerprint,
            retryPolicy: configuration.retryPolicy
        )
    }
}

package actor ICEAgent {
    package private(set) var state: ICEAgentState
    package private(set) var checklist: ICECandidateChecklist

    private let configuration: ICEAgentConfiguration
    private let checker: any ICEConnectivityChecking

    package init(
        localCandidates: [ICECandidate],
        remoteCandidates: [ICECandidate],
        configuration: ICEAgentConfiguration,
        checker: any ICEConnectivityChecking = STUNICEConnectivityChecker()
    ) {
        self.state = .new
        self.checklist = ICECandidateChecklist(
            localCandidates: localCandidates,
            remoteCandidates: remoteCandidates,
            isControlling: configuration.role == .controlling
        )
        self.configuration = configuration
        self.checker = checker
    }

    package var selectedCandidatePair: ICECandidatePair? {
        checklist.nominatedPair
    }

    package func addLocalCandidate(_ candidate: ICECandidate) {
        checklist.addLocalCandidate(candidate, isControlling: configuration.role == .controlling)
    }

    package func addRemoteCandidate(_ candidate: ICECandidate) {
        checklist.addRemoteCandidate(candidate, isControlling: configuration.role == .controlling)
    }

    package func nominateSucceededPair(localFoundation: String, remoteFoundation: String) {
        checklist.nominateSucceededPair(localFoundation: localFoundation, remoteFoundation: remoteFoundation)
        if checklist.nominatedPair != nil {
            state = .connected
        }
    }

    package func close() {
        state = .closed
    }

    @discardableResult
    package func performConnectivityChecks(maxPairs: Int? = nil) async -> ICEAgentCheckSummary {
        guard state != .closed else {
            return summary(checkedPairCount: 0, failedPairCount: 0)
        }

        checklist.unfreezeInitialPairs()

        guard !checklist.pairs.isEmpty else {
            state = .failed
            return summary(checkedPairCount: 0, failedPairCount: 0)
        }

        state = .checking
        let checkLimit = maxPairs ?? Int.max
        var checkedPairCount = 0
        var failedPairCount = 0

        while checkedPairCount < checkLimit, let pair = checklist.nextWaitingPair {
            checklist.markInProgress(
                localFoundation: pair.local.foundation,
                remoteFoundation: pair.remote.foundation
            )
            checkedPairCount += 1

            do {
                let shouldNominate = configuration.nominationPolicy == .nominateFirstSuccessful
                _ = try checker.checkCandidatePair(pair, configuration: configuration, nominate: shouldNominate)
                checklist.markSucceeded(
                    localFoundation: pair.local.foundation,
                    remoteFoundation: pair.remote.foundation,
                    nominated: shouldNominate
                )

                if shouldNominate {
                    state = .connected
                    return summary(checkedPairCount: checkedPairCount, failedPairCount: failedPairCount)
                }
            } catch {
                failedPairCount += 1
                checklist.markFailed(
                    localFoundation: pair.local.foundation,
                    remoteFoundation: pair.remote.foundation
                )
            }
        }

        if checklist.nominatedPair != nil {
            state = .connected
        } else if configuration.nominationPolicy == .validateOnly,
                  checklist.pairs.contains(where: { $0.state == .succeeded }) {
            state = .checking
        } else if checklist.pairs.contains(where: { $0.state == .waiting }) {
            state = .checking
        } else {
            state = .failed
        }

        return summary(checkedPairCount: checkedPairCount, failedPairCount: failedPairCount)
    }

    private func summary(checkedPairCount: Int, failedPairCount: Int) -> ICEAgentCheckSummary {
        ICEAgentCheckSummary(
            state: state,
            checkedPairCount: checkedPairCount,
            failedPairCount: failedPairCount,
            selectedPair: checklist.nominatedPair
        )
    }
}

package enum ICEConnectivityCheckError: Error, Equatable, Sendable {
    case transactionMismatch
    case unexpectedResponseType(UInt16)
    case missingMappedAddress
    case invalidMessageIntegrity
    case invalidFingerprint
    case roleConflict(STUNErrorCode)
    case errorResponse(STUNErrorCode)
}

package protocol STUNDatagramTransport: Sendable {
    func send(_ data: Data) throws -> Data
}

package struct STUNBindingRetryPolicy: Equatable, Sendable {
    package var maxAttempts: Int

    package init(maxAttempts: Int = 3) {
        self.maxAttempts = max(1, maxAttempts)
    }

    package static let once = STUNBindingRetryPolicy(maxAttempts: 1)
    package static let connectivityCheck = STUNBindingRetryPolicy(maxAttempts: 3)
}

package struct STUNBindingClient: Sendable {
    package var transport: any STUNDatagramTransport

    package init(transport: any STUNDatagramTransport) {
        self.transport = transport
    }

    package func requestMappedAddress(
        transactionID: STUNTransactionID = .random(),
        includeFingerprint: Bool = true,
        requireResponseFingerprint: Bool = false,
        retryPolicy: STUNBindingRetryPolicy = .connectivityCheck
    ) throws -> ICEConnectivityCheckResult {
        let request = STUNMessage(type: .bindingRequest, transactionID: transactionID)
        let requestData = try request.encoded(includeFingerprint: includeFingerprint)

        var lastTransportError: (any Error)?
        for _ in 0..<retryPolicy.maxAttempts {
            let responseData: Data
            do {
                responseData = try transport.send(requestData)
            } catch {
                lastTransportError = error
                continue
            }

            return try validateBindingResponse(
                responseData,
                transactionID: transactionID,
                messageIntegrityKey: nil,
                requireResponseMessageIntegrity: false,
                requireResponseFingerprint: requireResponseFingerprint
            )
        }

        if let lastTransportError {
            throw lastTransportError
        }

        throw ICEConnectivityCheckError.missingMappedAddress
    }

    package func requestServerReflexiveAddress(
        localCredentials: ICECredentials,
        remoteCredentials: ICECredentials,
        priority: UInt32,
        role: ICEAgentRole,
        tieBreaker: UInt64,
        transactionID: STUNTransactionID = .random(),
        useCandidate: Bool = false,
        requireResponseMessageIntegrity: Bool = false,
        requireResponseFingerprint: Bool = false,
        retryPolicy: STUNBindingRetryPolicy = .connectivityCheck
    ) throws -> ICEConnectivityCheckResult {
        let request = ICEConnectivityCheckRequestFactory.makeBindingRequest(
            localCredentials: localCredentials,
            remoteCredentials: remoteCredentials,
            priority: priority,
            role: role,
            tieBreaker: tieBreaker,
            useCandidate: useCandidate,
            transactionID: transactionID
        )
        let requestData = try request.encoded(
            messageIntegrityKey: remoteCredentials.password,
            includeFingerprint: true
        )

        var lastTransportError: (any Error)?
        for _ in 0..<retryPolicy.maxAttempts {
            let responseData: Data
            do {
                responseData = try transport.send(requestData)
            } catch {
                lastTransportError = error
                continue
            }

            return try validateBindingResponse(
                responseData,
                transactionID: transactionID,
                messageIntegrityKey: remoteCredentials.password,
                requireResponseMessageIntegrity: requireResponseMessageIntegrity,
                requireResponseFingerprint: requireResponseFingerprint
            )
        }

        if let lastTransportError {
            throw lastTransportError
        }

        throw ICEConnectivityCheckError.missingMappedAddress
    }

    private func validateBindingResponse(
        _ responseData: Data,
        transactionID: STUNTransactionID,
        messageIntegrityKey: String?,
        requireResponseMessageIntegrity: Bool,
        requireResponseFingerprint: Bool
    ) throws -> ICEConnectivityCheckResult {
        let response = try STUNMessage(decoding: responseData)

        guard response.transactionID == transactionID else {
            throw ICEConnectivityCheckError.transactionMismatch
        }

        if response.firstAttribute(.fingerprint) != nil || requireResponseFingerprint {
            guard try response.validatesFingerprint() else {
                throw ICEConnectivityCheckError.invalidFingerprint
            }
        }

        if response.firstAttribute(.messageIntegrity) != nil || requireResponseMessageIntegrity {
            guard let messageIntegrityKey,
                  try response.validatesMessageIntegrity(key: messageIntegrityKey)
            else {
                throw ICEConnectivityCheckError.invalidMessageIntegrity
            }
        }

        if response.type == .bindingErrorResponse,
           let errorCode = try response.firstAttribute(.errorCode)?.errorCodeValue {
            if errorCode.code == 487 {
                throw ICEConnectivityCheckError.roleConflict(errorCode)
            }

            throw ICEConnectivityCheckError.errorResponse(errorCode)
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

private struct ICECandidatePairKey: Hashable {
    var localFoundation: String
    var remoteFoundation: String

    init(_ pair: ICECandidatePair) {
        self.localFoundation = pair.local.foundation
        self.remoteFoundation = pair.remote.foundation
    }
}

private extension ICECandidatePair {
    var isEligibleForConnectivityCheck: Bool {
        switch state {
        case .frozen, .waiting, .inProgress:
            true
        case .succeeded, .failed:
            false
        }
    }
}

private extension ICECandidateType {
    init?(sdpToken: String) {
        switch sdpToken.lowercased() {
        case "host":
            self = .host
        case "prflx":
            self = .peerReflexive
        case "srflx":
            self = .serverReflexive
        case "relay":
            self = .relayed
        default:
            return nil
        }
    }

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

private extension ICETransportProtocol {
    init?(sdpToken: String) {
        switch sdpToken.lowercased() {
        case "udp":
            self = .udp
        case "tcp":
            self = .tcp
        default:
            return nil
        }
    }
}
