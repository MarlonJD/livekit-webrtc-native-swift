import Darwin
import Foundation

package enum SecureMediaTransportError: Error, Equatable, Sendable {
    case packetTooShort
    case srtcpIndexExhausted
    case candidatePairNotSucceeded
    case candidatePairNotNominated
    case missingLocalCandidateSocket(String)
    case unsupportedCandidatePairTransport
    case unsupportedCandidatePairComponent
    case unsupportedCandidateAddress(String)
    case datagramTooLarge(Int)
    case socketCreationFailed(Int32)
    case socketOptionFailed(Int32)
    case socketBindFailed(Int32)
    case socketConnectFailed(Int32)
    case socketSendFailed(Int32)
    case socketReceiveFailed(Int32)
    case transportClosed
    case missingRemoteFingerprint(DTLSSignature)
    case remoteFingerprintMismatch(expected: DTLSSignature, actual: DTLSSignature)
    case handshakeRoleMismatch(expected: DTLSSRTPRole, actual: DTLSSRTPRole)
    case unofferedHandshakeProtectionProfile(SRTPProtectionProfile)
}

package enum SecureMediaTransportPacket: Equatable, Sendable {
    case rtp(RTPPacket)
    case rtcp(RTCPPacket)
}

package protocol MediaDatagramTransport: Sendable {
    func send(_ datagram: Data) async throws
    func receive() async throws -> Data
}

package protocol MediaDatagramTransportFactory: Sendable {
    func makeTransport(selectedCandidatePair: ICECandidatePair) throws -> any MediaDatagramTransport
}

package enum WebRTCDatagramKind: Hashable, Sendable {
    case stun
    case dtls
    case turnChannelData
    case media
    case unknown
}

package enum WebRTCDatagramClassifier {
    package static func classify(_ datagram: Data) -> WebRTCDatagramKind {
        guard let firstByte = datagram.first else {
            return .unknown
        }

        switch firstByte {
        case 0 ... 3:
            return .stun
        case 20 ... 63:
            return .dtls
        case 64 ... 79:
            return .turnChannelData
        case 128 ... 191:
            return .media
        default:
            return .unknown
        }
    }
}

package actor WebRTCDatagramDemultiplexer {
    private let transport: any MediaDatagramTransport
    private var pendingDatagrams: [WebRTCDatagramKind: [Data]]

    package init(transport: any MediaDatagramTransport) {
        self.transport = transport
        self.pendingDatagrams = [:]
    }

    package func send(_ datagram: Data) async throws {
        try await transport.send(datagram)
    }

    package func receive(kind: WebRTCDatagramKind) async throws -> Data {
        if var pending = pendingDatagrams[kind], !pending.isEmpty {
            let datagram = pending.removeFirst()
            pendingDatagrams[kind] = pending
            return datagram
        }

        while true {
            let datagram = try await transport.receive()
            let datagramKind = WebRTCDatagramClassifier.classify(datagram)
            guard datagramKind != kind else {
                return datagram
            }

            pendingDatagrams[datagramKind, default: []].append(datagram)
        }
    }
}

package struct WebRTCDemultiplexedDatagramTransport: MediaDatagramTransport {
    package var demultiplexer: WebRTCDatagramDemultiplexer
    package var receiveKind: WebRTCDatagramKind

    package init(
        demultiplexer: WebRTCDatagramDemultiplexer,
        receiveKind: WebRTCDatagramKind
    ) {
        self.demultiplexer = demultiplexer
        self.receiveKind = receiveKind
    }

    package func send(_ datagram: Data) async throws {
        try await demultiplexer.send(datagram)
    }

    package func receive() async throws -> Data {
        try await demultiplexer.receive(kind: receiveKind)
    }
}

package protocol DTLSSRTPHandshaking: Sendable {
    func performHandshake(
        configuration: DTLSSRTPHandshakeConfiguration,
        transport: any MediaDatagramTransport
    ) async throws -> DTLSSRTPHandshakeResult
}

package struct UnavailableAppleDTLSSRTPHandshaker: DTLSSRTPHandshaking {
    package init() {}

    package func performHandshake(
        configuration: DTLSSRTPHandshakeConfiguration,
        transport: any MediaDatagramTransport
    ) async throws -> DTLSSRTPHandshakeResult {
        throw DTLSSRTPError.webRTCUseSRTPNegotiationUnavailable
    }
}

package struct LocalICEUDPSocketCandidate: Sendable {
    package var candidate: ICECandidate
    package var socket: LocalICEUDPSocket

    package init(candidate: ICECandidate, socket: LocalICEUDPSocket) {
        self.candidate = candidate
        self.socket = socket
    }

    package static func gatherHostCandidates(
        bindAddress: String = "0.0.0.0",
        includeLoopback: Bool = false,
        receiveTimeoutMilliseconds: Int = 1_000
    ) throws -> [LocalICEUDPSocketCandidate] {
        try hostCandidates(
            from: ICEHostCandidateGatherer.localInterfaceAddresses(includeLoopback: includeLoopback),
            bindAddress: bindAddress,
            receiveTimeoutMilliseconds: receiveTimeoutMilliseconds
        )
    }

    package static func hostCandidates(
        from addresses: [ICEInterfaceAddress],
        bindAddress: String = "0.0.0.0",
        receiveTimeoutMilliseconds: Int = 1_000
    ) throws -> [LocalICEUDPSocketCandidate] {
        guard !addresses.isEmpty else {
            return []
        }

        let socket = try LocalICEUDPSocket(
            bindAddress: bindAddress,
            port: 0,
            receiveTimeoutMilliseconds: receiveTimeoutMilliseconds
        )
        return ICEHostCandidateGatherer.candidates(
            from: addresses,
            port: socket.localPort
        ).map { candidate in
            LocalICEUDPSocketCandidate(candidate: candidate, socket: socket)
        }
    }

    package func serverReflexiveCandidates(
        iceServers: [ICEServer],
        retryPolicy: STUNBindingRetryPolicy = .once
    ) -> [LocalICEUDPSocketCandidate] {
        guard candidate.type == .host else {
            return []
        }

        let gatherer = STUNServerReflexiveCandidateGatherer { endpoint in
            LocalICEUDPSocketSTUNServerTransport(socket: socket, endpoint: endpoint)
        }

        return gatherer.gatherCandidates(
            for: candidate,
            iceServers: iceServers,
            retryPolicy: retryPolicy
        ).map { reflexiveCandidate in
            LocalICEUDPSocketCandidate(candidate: reflexiveCandidate, socket: socket)
        }
    }
}

package final class LocalICEUDPSocketCandidateStore: @unchecked Sendable {
    private let lock = NSLock()
    private var candidatesByFoundation: [String: LocalICEUDPSocketCandidate]

    package init(candidates: [LocalICEUDPSocketCandidate]) {
        self.candidatesByFoundation = Self.makeCandidateMap(candidates)
    }

    package var candidates: [LocalICEUDPSocketCandidate] {
        lock.withLock {
            candidatesByFoundation.values.sorted { lhs, rhs in
                lhs.candidate.foundation < rhs.candidate.foundation
            }
        }
    }

    package func add(_ candidates: [LocalICEUDPSocketCandidate]) {
        lock.withLock {
            for candidate in candidates {
                candidatesByFoundation[candidate.candidate.foundation] = candidate
            }
        }
    }

    package func replace(with candidates: [LocalICEUDPSocketCandidate]) {
        lock.withLock {
            candidatesByFoundation = Self.makeCandidateMap(candidates)
        }
    }

    package func socket(forFoundation foundation: String) -> LocalICEUDPSocket? {
        lock.withLock {
            candidatesByFoundation[foundation]?.socket
        }
    }

    private static func makeCandidateMap(
        _ candidates: [LocalICEUDPSocketCandidate]
    ) -> [String: LocalICEUDPSocketCandidate] {
        var candidatesByFoundation: [String: LocalICEUDPSocketCandidate] = [:]
        for candidate in candidates {
            candidatesByFoundation[candidate.candidate.foundation] = candidate
        }
        return candidatesByFoundation
    }
}

package final class LocalICEUDPSocket: @unchecked Sendable {
    package let bindAddress: String
    package let localPort: UInt16

    private let socketDescriptor: Int32
    private let lock: NSLock

    package init(
        bindAddress: String = "0.0.0.0",
        port: UInt16 = 0,
        receiveTimeoutMilliseconds: Int = 1_000
    ) throws {
        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else {
            throw SecureMediaTransportError.socketCreationFailed(errno)
        }

        do {
            var reuseAddress: Int32 = 1
            guard setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_REUSEADDR,
                &reuseAddress,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else {
                throw SecureMediaTransportError.socketOptionFailed(errno)
            }

            var timeout = timeval(
                tv_sec: receiveTimeoutMilliseconds / 1_000,
                tv_usec: Int32((receiveTimeoutMilliseconds % 1_000) * 1_000)
            )
            guard setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                &timeout,
                socklen_t(MemoryLayout<timeval>.size)
            ) == 0 else {
                throw SecureMediaTransportError.socketOptionFailed(errno)
            }

            var localAddress = try makeIPv4SocketAddress(address: bindAddress, port: port)
            let bindResult = withUnsafePointer(to: &localAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.bind(
                        descriptor,
                        socketAddress,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
            guard bindResult == 0 else {
                throw SecureMediaTransportError.socketBindFailed(errno)
            }

            self.bindAddress = bindAddress
            self.localPort = try Self.boundPort(socketDescriptor: descriptor)
            self.socketDescriptor = descriptor
            self.lock = NSLock()
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    deinit {
        Darwin.close(socketDescriptor)
    }

    package func hostCandidate(
        foundation: String,
        advertisedAddress: String,
        localPreference: UInt16 = UInt16.max
    ) -> ICECandidate {
        ICECandidate(
            foundation: foundation,
            componentID: .rtp,
            transport: .udp,
            priority: ICECandidatePriority(
                type: .host,
                localPreference: localPreference
            ).value,
            address: advertisedAddress,
            port: localPort,
            type: .host
        )
    }

    fileprivate func send(_ datagram: Data, to remoteCandidate: ICECandidate) throws {
        guard datagram.count <= UInt16.max else {
            throw SecureMediaTransportError.datagramTooLarge(datagram.count)
        }

        try validateCandidateEndpoint(remoteCandidate)
        var remoteAddress = try makeIPv4SocketAddress(
            address: remoteCandidate.address,
            port: remoteCandidate.port
        )
        try send(datagram, to: &remoteAddress)
    }

    fileprivate func send(_ datagram: Data, toHost host: String, port: UInt16) throws {
        guard datagram.count <= UInt16.max else {
            throw SecureMediaTransportError.datagramTooLarge(datagram.count)
        }

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
            throw SecureMediaTransportError.unsupportedCandidateAddress(host)
        }
        defer { freeaddrinfo(resolvedAddresses) }

        try send(
            datagram,
            to: address.pointee.ai_addr,
            addressLength: address.pointee.ai_addrlen
        )
    }

    private func send(_ datagram: Data, to remoteAddress: inout sockaddr_in) throws {
        try lock.withLock {
            let sentCount = datagram.withUnsafeBytes { buffer in
                withUnsafePointer(to: &remoteAddress) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                        Darwin.sendto(
                            socketDescriptor,
                            buffer.baseAddress,
                            datagram.count,
                            0,
                            socketAddress,
                            socklen_t(MemoryLayout<sockaddr_in>.size)
                        )
                    }
                }
            }
            guard sentCount == datagram.count else {
                throw SecureMediaTransportError.socketSendFailed(errno)
            }
        }
    }

    private func send(
        _ datagram: Data,
        to remoteAddress: UnsafePointer<sockaddr>,
        addressLength: socklen_t
    ) throws {
        try lock.withLock {
            let sentCount = datagram.withUnsafeBytes { buffer in
                Darwin.sendto(
                    socketDescriptor,
                    buffer.baseAddress,
                    datagram.count,
                    0,
                    remoteAddress,
                    addressLength
                )
            }
            guard sentCount == datagram.count else {
                throw SecureMediaTransportError.socketSendFailed(errno)
            }
        }
    }

    fileprivate func receive(maxByteCount: Int = Int(UInt16.max)) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maxByteCount)

        return try lock.withLock {
            let receivedCount = Darwin.recv(socketDescriptor, &buffer, buffer.count, 0)
            guard receivedCount > 0 else {
                throw SecureMediaTransportError.socketReceiveFailed(errno)
            }

            return Data(buffer.prefix(receivedCount))
        }
    }

    private static func boundPort(socketDescriptor: Int32) throws -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.getsockname(socketDescriptor, socketAddress, &length)
            }
        }

        guard result == 0 else {
            throw SecureMediaTransportError.socketBindFailed(errno)
        }

        return UInt16(bigEndian: address.sin_port)
    }
}

package struct LocalICEUDPSocketConnectivityChecker: ICEConnectivityChecking {
    private var socketForFoundation: @Sendable (String) -> LocalICEUDPSocket?

    package init(candidates: [LocalICEUDPSocketCandidate]) {
        var mutableSocketsByFoundation: [String: LocalICEUDPSocket] = [:]
        for candidate in candidates {
            mutableSocketsByFoundation[candidate.candidate.foundation] = candidate.socket
        }
        let socketsByFoundation = mutableSocketsByFoundation
        self.socketForFoundation = { foundation in
            socketsByFoundation[foundation]
        }
    }

    package init(candidateStore: LocalICEUDPSocketCandidateStore) {
        self.socketForFoundation = { foundation in
            candidateStore.socket(forFoundation: foundation)
        }
    }

    package func checkCandidatePair(
        _ pair: ICECandidatePair,
        configuration: ICEAgentConfiguration,
        nominate: Bool
    ) throws -> ICEConnectivityCheckResult {
        try validateCandidateEndpoint(pair.local)
        try validateCandidateEndpoint(pair.remote)
        guard let socket = socketForFoundation(pair.local.foundation) else {
            throw SecureMediaTransportError.missingLocalCandidateSocket(pair.local.foundation)
        }

        return try STUNBindingClient(
            transport: LocalICEUDPSocketSTUNTransport(
                socket: socket,
                remoteCandidate: pair.remote
            )
        ).requestServerReflexiveAddress(
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

package struct LocalICEUDPSocketMediaDatagramTransportFactory: MediaDatagramTransportFactory {
    private var socketForFoundation: @Sendable (String) -> LocalICEUDPSocket?

    package init(candidates: [LocalICEUDPSocketCandidate]) {
        var mutableSocketsByFoundation: [String: LocalICEUDPSocket] = [:]
        for candidate in candidates {
            mutableSocketsByFoundation[candidate.candidate.foundation] = candidate.socket
        }
        let socketsByFoundation = mutableSocketsByFoundation
        self.socketForFoundation = { foundation in
            socketsByFoundation[foundation]
        }
    }

    package init(candidateStore: LocalICEUDPSocketCandidateStore) {
        self.socketForFoundation = { foundation in
            candidateStore.socket(forFoundation: foundation)
        }
    }

    package func makeTransport(selectedCandidatePair: ICECandidatePair) throws -> any MediaDatagramTransport {
        try UDPMediaDatagramTransport.validateCandidatePair(selectedCandidatePair)
        guard let socket = socketForFoundation(selectedCandidatePair.local.foundation) else {
            throw SecureMediaTransportError.missingLocalCandidateSocket(
                selectedCandidatePair.local.foundation
            )
        }

        return LocalICEUDPSocketMediaDatagramTransport(
            socket: socket,
            remoteCandidate: selectedCandidatePair.remote
        )
    }
}

package struct LocalICEUDPSocketMediaDatagramTransport: MediaDatagramTransport {
    package var socket: LocalICEUDPSocket
    package var remoteCandidate: ICECandidate

    package init(socket: LocalICEUDPSocket, remoteCandidate: ICECandidate) {
        self.socket = socket
        self.remoteCandidate = remoteCandidate
    }

    package func send(_ datagram: Data) async throws {
        try socket.send(datagram, to: remoteCandidate)
    }

    package func receive() async throws -> Data {
        try socket.receive()
    }
}

private struct LocalICEUDPSocketSTUNTransport: STUNDatagramTransport {
    var socket: LocalICEUDPSocket
    var remoteCandidate: ICECandidate

    func send(_ data: Data) throws -> Data {
        try socket.send(data, to: remoteCandidate)
        return try socket.receive(maxByteCount: 1_500)
    }
}

private struct LocalICEUDPSocketSTUNServerTransport: STUNDatagramTransport {
    var socket: LocalICEUDPSocket
    var endpoint: STUNServerEndpoint

    func send(_ data: Data) throws -> Data {
        try socket.send(data, toHost: endpoint.host, port: endpoint.port)
        return try socket.receive(maxByteCount: 1_500)
    }
}

package struct UDPMediaDatagramTransportFactory: MediaDatagramTransportFactory {
    package var receiveTimeoutMilliseconds: Int

    package init(receiveTimeoutMilliseconds: Int = 1_000) {
        self.receiveTimeoutMilliseconds = receiveTimeoutMilliseconds
    }

    package func makeTransport(selectedCandidatePair: ICECandidatePair) throws -> any MediaDatagramTransport {
        try UDPMediaDatagramTransport(
            selectedCandidatePair: selectedCandidatePair,
            receiveTimeoutMilliseconds: receiveTimeoutMilliseconds
        )
    }
}

package final class UDPMediaDatagramTransport: MediaDatagramTransport, @unchecked Sendable {
    package let localCandidate: ICECandidate
    package let remoteCandidate: ICECandidate

    private let socketDescriptor: Int32
    private let lock: NSLock

    package convenience init(
        selectedCandidatePair: ICECandidatePair,
        receiveTimeoutMilliseconds: Int = 1_000
    ) throws {
        try Self.validateCandidatePair(selectedCandidatePair)
        try self.init(
            localCandidate: selectedCandidatePair.local,
            remoteCandidate: selectedCandidatePair.remote,
            receiveTimeoutMilliseconds: receiveTimeoutMilliseconds
        )
    }

    package init(
        localCandidate: ICECandidate,
        remoteCandidate: ICECandidate,
        receiveTimeoutMilliseconds: Int = 1_000
    ) throws {
        guard localCandidate.componentID == .rtp,
              remoteCandidate.componentID == .rtp
        else {
            throw SecureMediaTransportError.unsupportedCandidatePairComponent
        }
        guard localCandidate.transport == .udp,
              remoteCandidate.transport == .udp
        else {
            throw SecureMediaTransportError.unsupportedCandidatePairTransport
        }

        let descriptor = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard descriptor >= 0 else {
            throw SecureMediaTransportError.socketCreationFailed(errno)
        }

        do {
            var reuseAddress: Int32 = 1
            guard setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_REUSEADDR,
                &reuseAddress,
                socklen_t(MemoryLayout<Int32>.size)
            ) == 0 else {
                throw SecureMediaTransportError.socketOptionFailed(errno)
            }

            var timeout = timeval(
                tv_sec: receiveTimeoutMilliseconds / 1_000,
                tv_usec: Int32((receiveTimeoutMilliseconds % 1_000) * 1_000)
            )
            guard setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_RCVTIMEO,
                &timeout,
                socklen_t(MemoryLayout<timeval>.size)
            ) == 0 else {
                throw SecureMediaTransportError.socketOptionFailed(errno)
            }

            var localAddress = try makeIPv4SocketAddress(
                address: localCandidate.address,
                port: localCandidate.port
            )
            let bindResult = withUnsafePointer(to: &localAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.bind(
                        descriptor,
                        socketAddress,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
            guard bindResult == 0 else {
                throw SecureMediaTransportError.socketBindFailed(errno)
            }

            var remoteAddress = try makeIPv4SocketAddress(
                address: remoteCandidate.address,
                port: remoteCandidate.port
            )
            let connectResult = withUnsafePointer(to: &remoteAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                    Darwin.connect(
                        descriptor,
                        socketAddress,
                        socklen_t(MemoryLayout<sockaddr_in>.size)
                    )
                }
            }
            guard connectResult == 0 else {
                throw SecureMediaTransportError.socketConnectFailed(errno)
            }

            self.localCandidate = localCandidate
            self.remoteCandidate = remoteCandidate
            self.socketDescriptor = descriptor
            self.lock = NSLock()
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    deinit {
        Darwin.close(socketDescriptor)
    }

    package func send(_ datagram: Data) async throws {
        guard datagram.count <= UInt16.max else {
            throw SecureMediaTransportError.datagramTooLarge(datagram.count)
        }

        try lock.withLock {
            let sentCount = datagram.withUnsafeBytes { buffer in
                Darwin.send(socketDescriptor, buffer.baseAddress, datagram.count, 0)
            }
            guard sentCount == datagram.count else {
                throw SecureMediaTransportError.socketSendFailed(errno)
            }
        }
    }

    package func receive() async throws -> Data {
        var buffer = [UInt8](repeating: 0, count: Int(UInt16.max))

        return try lock.withLock {
            let receivedCount = Darwin.recv(socketDescriptor, &buffer, buffer.count, 0)
            guard receivedCount > 0 else {
                throw SecureMediaTransportError.socketReceiveFailed(errno)
            }

            return Data(buffer.prefix(receivedCount))
        }
    }

    package static func validateCandidatePair(_ candidatePair: ICECandidatePair) throws {
        guard candidatePair.state == .succeeded else {
            throw SecureMediaTransportError.candidatePairNotSucceeded
        }
        guard candidatePair.nominated else {
            throw SecureMediaTransportError.candidatePairNotNominated
        }
        guard candidatePair.local.componentID == .rtp,
              candidatePair.remote.componentID == .rtp
        else {
            throw SecureMediaTransportError.unsupportedCandidatePairComponent
        }
        guard candidatePair.local.transport == .udp,
              candidatePair.remote.transport == .udp
        else {
            throw SecureMediaTransportError.unsupportedCandidatePairTransport
        }
    }

}

package actor DTLSSRTPMediaTransport {
    private var packetProtectionContext: DTLSSRTPPacketProtectionContext
    private let datagramTransport: any MediaDatagramTransport
    private var outboundRTPSequenceExtenders: [UInt32: RTPSequenceNumberExtender]
    private var inboundRTPSequenceExtenders: [UInt32: RTPSequenceNumberExtender]
    private var outboundSRTCPIndex: UInt32
    private var isClosed: Bool

    package init(
        packetProtectionContext: DTLSSRTPPacketProtectionContext,
        datagramTransport: any MediaDatagramTransport
    ) {
        self.packetProtectionContext = packetProtectionContext
        self.datagramTransport = datagramTransport
        self.outboundRTPSequenceExtenders = [:]
        self.inboundRTPSequenceExtenders = [:]
        self.outboundSRTCPIndex = 0
        self.isClosed = false
    }

    package init(
        selectedCandidatePair: ICECandidatePair,
        keyMaterial: DTLSSRTPKeyMaterial,
        role: DTLSSRTPRole,
        datagramTransport: any MediaDatagramTransport
    ) throws {
        try UDPMediaDatagramTransport.validateCandidatePair(selectedCandidatePair)

        self.init(
            packetProtectionContext: try DTLSSRTPPacketProtectionContext(
                keyMaterial: keyMaterial,
                role: role
            ),
            datagramTransport: datagramTransport
        )
    }

    package func sendRTP(_ packet: RTPPacket) async throws {
        try ensureOpen()

        var sequenceExtender = outboundRTPSequenceExtenders[packet.ssrc] ?? RTPSequenceNumberExtender()
        let extendedSequenceNumber = sequenceExtender.extend(packet.sequenceNumber)
        let rolloverCounter = UInt32(extendedSequenceNumber >> 16)
        let protected = try packetProtectionContext.protectRTP(
            packet,
            rolloverCounter: rolloverCounter
        )

        try await datagramTransport.send(protected.encoded())
        outboundRTPSequenceExtenders[packet.ssrc] = sequenceExtender
    }

    package func sendRTCP(_ packet: RTCPPacket) async throws {
        try ensureOpen()

        guard outboundSRTCPIndex < SRTCPIndex.maxValue else {
            throw SecureMediaTransportError.srtcpIndexExhausted
        }

        let nextIndex = outboundSRTCPIndex + 1
        let protected = try packetProtectionContext.protectRTCP(
            SRTCPPacket(
                rtcpPacket: packet,
                index: try SRTCPIndex(value: nextIndex)
            )
        )

        try await datagramTransport.send(try protected.encoded())
        outboundSRTCPIndex = nextIndex
    }

    package func receive() async throws -> SecureMediaTransportPacket {
        try ensureOpen()

        let datagram = try await datagramTransport.receive()
        switch try classify(datagram) {
        case .rtp:
            return try .rtp(receiveRTP(datagram))
        case .rtcp:
            return try .rtcp(packetProtectionContext.unprotectRTCP(encoded: datagram).rtcpPacket)
        }
    }

    package func close() {
        isClosed = true
    }

    private func ensureOpen() throws {
        guard !isClosed else {
            throw SecureMediaTransportError.transportClosed
        }
    }

    private func receiveRTP(_ datagram: Data) throws -> RTPPacket {
        let authenticationTagLength = packetProtectionContext.protectionProfile.srtpAuthenticationTagLength
        guard datagram.count >= 12 + authenticationTagLength else {
            throw SecureMediaTransportError.packetTooShort
        }

        let rtpByteCount = datagram.count - authenticationTagLength
        let protectedRTP = try RTPPacket(decoding: Data(datagram.prefix(rtpByteCount)))
        var sequenceExtender = inboundRTPSequenceExtenders[protectedRTP.ssrc] ?? RTPSequenceNumberExtender()
        let extendedSequenceNumber = sequenceExtender.extend(protectedRTP.sequenceNumber)
        let rolloverCounter = UInt32(extendedSequenceNumber >> 16)

        let unprotected = try packetProtectionContext.unprotectRTP(
            encoded: datagram,
            rolloverCounter: rolloverCounter
        )
        inboundRTPSequenceExtenders[protectedRTP.ssrc] = sequenceExtender
        return unprotected
    }

    private func classify(_ datagram: Data) throws -> MediaDatagramKind {
        guard datagram.count >= 2 else {
            throw SecureMediaTransportError.packetTooShort
        }

        let packetType = datagram[datagram.index(after: datagram.startIndex)]
        if (192...223).contains(packetType) {
            return .rtcp
        }

        return .rtp
    }
}

package struct DTLSSRTPMediaSessionFactory: Sendable {
    package var datagramTransportFactory: any MediaDatagramTransportFactory

    package init(
        datagramTransportFactory: any MediaDatagramTransportFactory = UDPMediaDatagramTransportFactory()
    ) {
        self.datagramTransportFactory = datagramTransportFactory
    }

    package func makeMediaTransport(
        selectedCandidatePair: ICECandidatePair,
        handshakeResult: DTLSSRTPHandshakeResult,
        expectedRemoteFingerprint: DTLSSignature? = nil
    ) throws -> DTLSSRTPMediaTransport {
        try validateRemoteFingerprint(
            handshakeResult.remoteFingerprint,
            expected: expectedRemoteFingerprint
        )
        try UDPMediaDatagramTransport.validateCandidatePair(selectedCandidatePair)

        let datagramTransport = try datagramTransportFactory.makeTransport(
            selectedCandidatePair: selectedCandidatePair
        )

        return try makeMediaTransport(
            selectedCandidatePair: selectedCandidatePair,
            handshakeResult: handshakeResult,
            expectedRemoteFingerprint: expectedRemoteFingerprint,
            datagramTransport: datagramTransport
        )
    }

    package func makeMediaTransport(
        selectedCandidatePair: ICECandidatePair,
        handshakeResult: DTLSSRTPHandshakeResult,
        expectedRemoteFingerprint: DTLSSignature? = nil,
        datagramTransport: any MediaDatagramTransport
    ) throws -> DTLSSRTPMediaTransport {
        try validateRemoteFingerprint(
            handshakeResult.remoteFingerprint,
            expected: expectedRemoteFingerprint
        )
        try UDPMediaDatagramTransport.validateCandidatePair(selectedCandidatePair)

        return try DTLSSRTPMediaTransport(
            selectedCandidatePair: selectedCandidatePair,
            keyMaterial: try handshakeResult.keyMaterial(),
            role: handshakeResult.role,
            datagramTransport: datagramTransport
        )
    }

    private func validateRemoteFingerprint(
        _ actual: DTLSSignature?,
        expected: DTLSSignature?
    ) throws {
        guard let expected else {
            return
        }

        guard let actual else {
            throw SecureMediaTransportError.missingRemoteFingerprint(expected)
        }

        guard actual == expected else {
            throw SecureMediaTransportError.remoteFingerprintMismatch(
                expected: expected,
                actual: actual
            )
        }
    }
}

package struct DTLSSRTPMediaSessionBinder: Sendable {
    package var datagramTransportFactory: any MediaDatagramTransportFactory
    package var handshaker: any DTLSSRTPHandshaking

    package init(
        datagramTransportFactory: any MediaDatagramTransportFactory = UDPMediaDatagramTransportFactory(),
        handshaker: any DTLSSRTPHandshaking
    ) {
        self.datagramTransportFactory = datagramTransportFactory
        self.handshaker = handshaker
    }

    package func makeMediaTransport(
        selectedCandidatePair: ICECandidatePair,
        handshakeConfiguration: DTLSSRTPHandshakeConfiguration
    ) async throws -> DTLSSRTPMediaTransport {
        try UDPMediaDatagramTransport.validateCandidatePair(selectedCandidatePair)
        let datagramTransport = try datagramTransportFactory.makeTransport(
            selectedCandidatePair: selectedCandidatePair
        )
        let handshakeResult = try await handshaker.performHandshake(
            configuration: handshakeConfiguration,
            transport: datagramTransport
        )
        try validateHandshakeResult(handshakeResult, matches: handshakeConfiguration)

        return try DTLSSRTPMediaSessionFactory(
            datagramTransportFactory: datagramTransportFactory
        ).makeMediaTransport(
            selectedCandidatePair: selectedCandidatePair,
            handshakeResult: handshakeResult,
            expectedRemoteFingerprint: handshakeConfiguration.remoteFingerprint,
            datagramTransport: datagramTransport
        )
    }

    private func validateHandshakeResult(
        _ result: DTLSSRTPHandshakeResult,
        matches configuration: DTLSSRTPHandshakeConfiguration
    ) throws {
        guard result.role == configuration.role else {
            throw SecureMediaTransportError.handshakeRoleMismatch(
                expected: configuration.role,
                actual: result.role
            )
        }

        guard configuration.useSRTExtension.protectionProfiles.contains(result.protectionProfile) else {
            throw SecureMediaTransportError.unofferedHandshakeProtectionProfile(
                result.protectionProfile
            )
        }
    }
}

package struct DTLSSRTPMediaDataSession: Sendable {
    package var mediaTransport: DTLSSRTPMediaTransport
    package var dataChannelTransport: DTLSSCTPDataChannelPacketTransport
    package var applicationDataTransport: OpenSSLDTLSApplicationDataTransport
    package var handshakeResult: DTLSSRTPHandshakeResult

    package init(
        mediaTransport: DTLSSRTPMediaTransport,
        dataChannelTransport: DTLSSCTPDataChannelPacketTransport,
        applicationDataTransport: OpenSSLDTLSApplicationDataTransport,
        handshakeResult: DTLSSRTPHandshakeResult
    ) {
        self.mediaTransport = mediaTransport
        self.dataChannelTransport = dataChannelTransport
        self.applicationDataTransport = applicationDataTransport
        self.handshakeResult = handshakeResult
    }

    package func close() async {
        await mediaTransport.close()
        await applicationDataTransport.close()
    }
}

package struct DTLSSRTPMediaDataSessionBinder: Sendable {
    package var datagramTransportFactory: any MediaDatagramTransportFactory
    package var identity: DTLSSRTPIdentity
    package var receiveAttemptLimit: Int
    package var maxDataChannelFragmentPayloadSize: Int?

    package init(
        datagramTransportFactory: any MediaDatagramTransportFactory = UDPMediaDatagramTransportFactory(),
        identity: DTLSSRTPIdentity = .generated(),
        receiveAttemptLimit: Int = 64,
        maxDataChannelFragmentPayloadSize: Int? = nil
    ) {
        self.datagramTransportFactory = datagramTransportFactory
        self.identity = identity
        self.receiveAttemptLimit = max(1, receiveAttemptLimit)
        self.maxDataChannelFragmentPayloadSize = maxDataChannelFragmentPayloadSize
    }

    package func makeSession(
        selectedCandidatePair: ICECandidatePair,
        handshakeConfiguration: DTLSSRTPHandshakeConfiguration
    ) async throws -> DTLSSRTPMediaDataSession {
        try UDPMediaDatagramTransport.validateCandidatePair(selectedCandidatePair)
        let datagramTransport = try datagramTransportFactory.makeTransport(
            selectedCandidatePair: selectedCandidatePair
        )
        let demultiplexer = WebRTCDatagramDemultiplexer(transport: datagramTransport)
        let dtlsDatagramTransport = WebRTCDemultiplexedDatagramTransport(
            demultiplexer: demultiplexer,
            receiveKind: .dtls
        )
        let mediaDatagramTransport = WebRTCDemultiplexedDatagramTransport(
            demultiplexer: demultiplexer,
            receiveKind: .media
        )
        let applicationDataTransport = try OpenSSLDTLSApplicationDataTransport(
            identity: identity,
            role: handshakeConfiguration.role,
            transport: dtlsDatagramTransport,
            profiles: handshakeConfiguration.useSRTExtension.protectionProfiles
        )
        let handshakeResult = try await applicationDataTransport.performHandshake(
            role: handshakeConfiguration.role,
            expectedRemoteFingerprint: handshakeConfiguration.remoteFingerprint,
            receiveAttemptLimit: receiveAttemptLimit
        )
        try validateHandshakeResult(handshakeResult, matches: handshakeConfiguration)
        let mediaTransport = try DTLSSRTPMediaSessionFactory().makeMediaTransport(
            selectedCandidatePair: selectedCandidatePair,
            handshakeResult: handshakeResult,
            expectedRemoteFingerprint: handshakeConfiguration.remoteFingerprint,
            datagramTransport: mediaDatagramTransport
        )
        let dataChannelTransport = DTLSSCTPDataChannelPacketTransport(
            dtlsTransport: applicationDataTransport,
            maxFragmentPayloadSize: maxDataChannelFragmentPayloadSize
        )

        return DTLSSRTPMediaDataSession(
            mediaTransport: mediaTransport,
            dataChannelTransport: dataChannelTransport,
            applicationDataTransport: applicationDataTransport,
            handshakeResult: handshakeResult
        )
    }

    private func validateHandshakeResult(
        _ result: DTLSSRTPHandshakeResult,
        matches configuration: DTLSSRTPHandshakeConfiguration
    ) throws {
        guard result.role == configuration.role else {
            throw SecureMediaTransportError.handshakeRoleMismatch(
                expected: configuration.role,
                actual: result.role
            )
        }

        guard configuration.useSRTExtension.protectionProfiles.contains(result.protectionProfile) else {
            throw SecureMediaTransportError.unofferedHandshakeProtectionProfile(
                result.protectionProfile
            )
        }
    }
}

private enum MediaDatagramKind {
    case rtp
    case rtcp
}

private func validateCandidateEndpoint(_ candidate: ICECandidate) throws {
    guard candidate.componentID == .rtp else {
        throw SecureMediaTransportError.unsupportedCandidatePairComponent
    }
    guard candidate.transport == .udp else {
        throw SecureMediaTransportError.unsupportedCandidatePairTransport
    }
}

private func makeIPv4SocketAddress(address: String, port: UInt16) throws -> sockaddr_in {
    var ipv4Address = in_addr()
    guard inet_pton(AF_INET, address, &ipv4Address) == 1 else {
        throw SecureMediaTransportError.unsupportedCandidateAddress(address)
    }

    return sockaddr_in(
        sin_len: UInt8(MemoryLayout<sockaddr_in>.size),
        sin_family: sa_family_t(AF_INET),
        sin_port: port.bigEndian,
        sin_addr: ipv4Address,
        sin_zero: (0, 0, 0, 0, 0, 0, 0, 0)
    )
}
