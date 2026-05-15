import Darwin
import Foundation

package enum SecureMediaTransportError: Error, Equatable, Sendable {
    case packetTooShort
    case srtcpIndexExhausted
    case candidatePairNotSucceeded
    case candidatePairNotNominated
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
}

package enum SecureMediaTransportPacket: Equatable, Sendable {
    case rtp(RTPPacket)
    case rtcp(RTCPPacket)
}

package protocol MediaDatagramTransport: Sendable {
    func send(_ datagram: Data) async throws
    func receive() async throws -> Data
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

            var localAddress = try Self.makeIPv4SocketAddress(
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

            var remoteAddress = try Self.makeIPv4SocketAddress(
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

    private static func makeIPv4SocketAddress(address: String, port: UInt16) throws -> sockaddr_in {
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
}

package actor DTLSSRTPMediaTransport {
    private var packetProtectionContext: DTLSSRTPPacketProtectionContext
    private let datagramTransport: any MediaDatagramTransport
    private var outboundRTPSequenceExtenders: [UInt32: RTPSequenceNumberExtender]
    private var inboundRTPSequenceExtenders: [UInt32: RTPSequenceNumberExtender]
    private var outboundSRTCPIndex: UInt32

    package init(
        packetProtectionContext: DTLSSRTPPacketProtectionContext,
        datagramTransport: any MediaDatagramTransport
    ) {
        self.packetProtectionContext = packetProtectionContext
        self.datagramTransport = datagramTransport
        self.outboundRTPSequenceExtenders = [:]
        self.inboundRTPSequenceExtenders = [:]
        self.outboundSRTCPIndex = 0
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
        let datagram = try await datagramTransport.receive()
        switch try classify(datagram) {
        case .rtp:
            return try .rtp(receiveRTP(datagram))
        case .rtcp:
            return try .rtcp(packetProtectionContext.unprotectRTCP(encoded: datagram).rtcpPacket)
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

private enum MediaDatagramKind {
    case rtp
    case rtcp
}
