import Foundation

package enum SCTPDataChannelError: Error, Equatable, Sendable {
    case truncatedControlMessage
    case truncatedPacketEnvelope
    case invalidControlMessageType(UInt8)
    case invalidPacketEnvelopePPID(UInt32)
    case packetEnvelopeLengthMismatch(expected: Int, actual: Int)
    case invalidFragmentPayloadSize(Int)
    case tooManyFragments(Int)
    case truncatedFragmentEnvelope
    case invalidFragmentEnvelopeMagic
    case unsupportedFragmentEnvelopeVersion(UInt8)
    case invalidFragmentEnvelopePPID(UInt32)
    case fragmentEnvelopeLengthMismatch(expected: Int, actual: Int)
    case invalidFragmentCount(UInt16)
    case duplicateFragment(messageID: UInt32, fragmentIndex: UInt16)
    case mismatchedFragmentMetadata(messageID: UInt32)
    case missingFragments(messageID: UInt32)
    case retransmissionAttemptsExhausted(messageID: UInt32, fragmentIndex: UInt16)
    case invalidUTF8
    case duplicateStreamID(UInt16)
    case duplicateLabel(String)
    case unknownStreamID(UInt16)
    case channelNotOpen(UInt16)
}

package enum SCTPDataChannelState: Equatable, Sendable {
    case connecting
    case open
    case closing
    case closed
}

package enum SCTPDataChannelReliability: Equatable, Sendable {
    case reliable
    case lossy

    package var label: String {
        switch self {
        case .reliable:
            LiveKitSCTPDataChannelLabel.reliable
        case .lossy:
            LiveKitSCTPDataChannelLabel.lossy
        }
    }

    package var dataPacketKindName: String {
        switch self {
        case .reliable:
            "reliable"
        case .lossy:
            "lossy"
        }
    }

    fileprivate var openChannelType: UInt8 {
        switch self {
        case .reliable:
            0x00
        case .lossy:
            0x81
        }
    }

    fileprivate var reliabilityParameter: UInt32 {
        switch self {
        case .reliable:
            0
        case .lossy:
            0
        }
    }

    fileprivate init(channelType: UInt8) {
        self = channelType == 0x00 ? .reliable : .lossy
    }
}

package enum LiveKitSCTPDataChannelLabel {
    package static let reliable = "_reliable"
    package static let lossy = "_lossy"
    package static let dataTrack = "_data_track"
}

package enum SCTPDataChannelPPID: UInt32, Equatable, Sendable {
    case dataChannelControl = 50
    case string = 51
    case binaryPartial = 52
    case binary = 53
    case stringEmpty = 56
    case binaryEmpty = 57
}

package struct SCTPDataChannelPacket: Equatable, Sendable {
    package var streamID: UInt16
    package var ppid: SCTPDataChannelPPID
    package var payload: Data

    package init(streamID: UInt16, ppid: SCTPDataChannelPPID, payload: Data) {
        self.streamID = streamID
        self.ppid = ppid
        self.payload = payload
    }

    package var isControl: Bool {
        ppid == .dataChannelControl
    }
}

package protocol SCTPDataChannelPacketTransport: Sendable {
    func send(_ packet: SCTPDataChannelPacket) async throws
}

package protocol SCTPDataChannelPacketTransceiver: SCTPDataChannelPacketTransport {
    func receive() async throws -> SCTPDataChannelPacket
}

package enum SCTPDataChannelControlMessage: Equatable, Sendable {
    case open(SCTPDataChannelOpenMessage)
    case acknowledgement

    package init(decoding data: Data) throws {
        guard let messageType = data.first else {
            throw SCTPDataChannelError.truncatedControlMessage
        }

        switch messageType {
        case 0x02:
            self = .acknowledgement
        case 0x03:
            self = .open(try SCTPDataChannelOpenMessage(decoding: data))
        default:
            throw SCTPDataChannelError.invalidControlMessageType(messageType)
        }
    }

    package func encoded() -> Data {
        switch self {
        case let .open(message):
            message.encoded()
        case .acknowledgement:
            Data([0x02])
        }
    }
}

package struct SCTPDataChannelOpenMessage: Equatable, Sendable {
    package var reliability: SCTPDataChannelReliability
    package var priority: UInt16
    package var reliabilityParameter: UInt32
    package var label: String
    package var protocolName: String

    package init(
        reliability: SCTPDataChannelReliability,
        priority: UInt16 = 0,
        reliabilityParameter: UInt32? = nil,
        label: String? = nil,
        protocolName: String = ""
    ) {
        self.reliability = reliability
        self.priority = priority
        self.reliabilityParameter = reliabilityParameter ?? reliability.reliabilityParameter
        self.label = label ?? reliability.label
        self.protocolName = protocolName
    }

    fileprivate init(decoding data: Data) throws {
        guard data.count >= 12 else {
            throw SCTPDataChannelError.truncatedControlMessage
        }

        let channelType = data.byte(at: 1)
        self.reliability = SCTPDataChannelReliability(channelType: channelType)
        self.priority = data.uint16(at: 2)
        self.reliabilityParameter = data.uint32(at: 4)
        let labelLength = Int(data.uint16(at: 8))
        let protocolLength = Int(data.uint16(at: 10))
        let labelStart = 12
        let protocolStart = labelStart + labelLength
        let protocolEnd = protocolStart + protocolLength

        guard protocolEnd <= data.count else {
            throw SCTPDataChannelError.truncatedControlMessage
        }

        guard
            let label = String(data: data[labelStart..<protocolStart], encoding: .utf8),
            let protocolName = String(data: data[protocolStart..<protocolEnd], encoding: .utf8)
        else {
            throw SCTPDataChannelError.invalidUTF8
        }

        self.label = label
        self.protocolName = protocolName
    }

    fileprivate func encoded() -> Data {
        let labelData = Data(label.utf8)
        let protocolData = Data(protocolName.utf8)
        var data = Data()
        data.append(0x03)
        data.append(reliability.openChannelType)
        data.append(priority.bigEndianBytes)
        data.append(reliabilityParameter.bigEndianBytes)
        data.append(UInt16(labelData.count).bigEndianBytes)
        data.append(UInt16(protocolData.count).bigEndianBytes)
        data.append(labelData)
        data.append(protocolData)
        return data
    }
}

package final class SCTPDataChannel: @unchecked Sendable {
    package let streamID: UInt16
    package let label: String
    package let reliability: SCTPDataChannelReliability
    private let lock = NSLock()
    private var mutableState: SCTPDataChannelState

    package init(streamID: UInt16, label: String, reliability: SCTPDataChannelReliability) {
        self.streamID = streamID
        self.label = label
        self.reliability = reliability
        self.mutableState = .connecting
    }

    package var state: SCTPDataChannelState {
        lock.withCriticalSection {
            mutableState
        }
    }

    package func openPacket() -> SCTPDataChannelPacket {
        let message = SCTPDataChannelControlMessage.open(
            SCTPDataChannelOpenMessage(reliability: reliability, label: label)
        )
        return SCTPDataChannelPacket(streamID: streamID, ppid: .dataChannelControl, payload: message.encoded())
    }

    package func acceptAcknowledgement() {
        lock.withCriticalSection {
            guard mutableState == .connecting else { return }
            mutableState = .open
        }
    }

    package func acceptRemoteOpen(_ message: SCTPDataChannelOpenMessage) {
        lock.withCriticalSection {
            guard message.label == label else { return }
            mutableState = .open
        }
    }

    package func close() {
        lock.withCriticalSection {
            mutableState = .closed
        }
    }

    package func makeBinaryPacket(_ payload: Data) throws -> SCTPDataChannelPacket {
        let state = lock.withCriticalSection {
            mutableState
        }

        guard state == .open else {
            throw SCTPDataChannelError.channelNotOpen(streamID)
        }

        return SCTPDataChannelPacket(
            streamID: streamID,
            ppid: payload.isEmpty ? .binaryEmpty : .binary,
            payload: payload
        )
    }
}

package final class SCTPDataChannelManager: @unchecked Sendable {
    private let lock = NSLock()
    private var channelsByStreamID: [UInt16: SCTPDataChannel] = [:]
    private var channelsByLabel: [String: SCTPDataChannel] = [:]
    private var nextStreamID: UInt16

    package init(firstLocalStreamID: UInt16 = 0) {
        self.nextStreamID = firstLocalStreamID
    }

    package var channels: [SCTPDataChannel] {
        lock.withCriticalSection {
            channelsByStreamID.values.sorted { $0.streamID < $1.streamID }
        }
    }

    @discardableResult
    package func openChannel(label: String, reliability: SCTPDataChannelReliability) throws -> SCTPDataChannel {
        try lock.withCriticalSection {
            guard channelsByLabel[label] == nil else {
                throw SCTPDataChannelError.duplicateLabel(label)
            }

            let streamID = nextAvailableStreamID()
            let channel = SCTPDataChannel(streamID: streamID, label: label, reliability: reliability)
            channelsByStreamID[streamID] = channel
            channelsByLabel[label] = channel
            nextStreamID = streamID &+ 2
            return channel
        }
    }

    package func ensureLiveKitChannel(for reliability: SCTPDataChannelReliability) -> SCTPDataChannel {
        lock.withCriticalSection {
            if let existing = channelsByLabel[reliability.label] {
                return existing
            }

            let streamID = nextAvailableStreamID()
            let channel = SCTPDataChannel(streamID: streamID, label: reliability.label, reliability: reliability)
            channelsByStreamID[streamID] = channel
            channelsByLabel[reliability.label] = channel
            nextStreamID = streamID &+ 2
            return channel
        }
    }

    package func acceptControlPacket(_ packet: SCTPDataChannelPacket) throws {
        guard packet.ppid == .dataChannelControl else {
            return
        }

        let message = try SCTPDataChannelControlMessage(decoding: packet.payload)
        let channel = try channel(for: packet.streamID)
        switch message {
        case let .open(openMessage):
            channel.acceptRemoteOpen(openMessage)
        case .acknowledgement:
            channel.acceptAcknowledgement()
        }
    }

    package func makeBinaryPacket(label: String, payload: Data) throws -> SCTPDataChannelPacket {
        let channel = try lock.withCriticalSection {
            guard let channel = channelsByLabel[label] else {
                throw SCTPDataChannelError.unknownStreamID(0)
            }

            return channel
        }

        return try channel.makeBinaryPacket(payload)
    }

    package func channel(for streamID: UInt16) throws -> SCTPDataChannel {
        try lock.withCriticalSection {
            guard let channel = channelsByStreamID[streamID] else {
                throw SCTPDataChannelError.unknownStreamID(streamID)
            }

            return channel
        }
    }

    private func nextAvailableStreamID() -> UInt16 {
        while channelsByStreamID[nextStreamID] != nil {
            nextStreamID &+= 2
        }

        return nextStreamID
    }
}

package struct SCTPDataChannelPacketEnvelopeCodec: Sendable {
    package init() {}

    package func encode(_ packet: SCTPDataChannelPacket) -> Data {
        var data = Data()
        data.append(packet.streamID.bigEndianBytes)
        data.append(packet.ppid.rawValue.bigEndianBytes)
        data.append(UInt32(packet.payload.count).bigEndianBytes)
        data.append(packet.payload)
        return data
    }

    package func decode(_ data: Data) throws -> SCTPDataChannelPacket {
        guard data.count >= 10 else {
            throw SCTPDataChannelError.truncatedPacketEnvelope
        }

        let streamID = data.uint16(at: 0)
        let rawPPID = data.uint32(at: 2)
        guard let ppid = SCTPDataChannelPPID(rawValue: rawPPID) else {
            throw SCTPDataChannelError.invalidPacketEnvelopePPID(rawPPID)
        }

        let payloadLength = Int(data.uint32(at: 6))
        let actualLength = data.count - 10
        guard actualLength == payloadLength else {
            throw SCTPDataChannelError.packetEnvelopeLengthMismatch(
                expected: payloadLength,
                actual: actualLength
            )
        }

        return SCTPDataChannelPacket(
            streamID: streamID,
            ppid: ppid,
            payload: Data(data.dropFirst(10))
        )
    }
}

package struct SCTPDataChannelFragmentEnvelope: Equatable, Sendable {
    package static let version: UInt8 = 1
    private static let magic = Data([0x4C, 0x4B, 0x43, 0x46])
    private static let headerByteCount = 27

    package var messageID: UInt32
    package var fragmentIndex: UInt16
    package var fragmentCount: UInt16
    package var originalPayloadLength: UInt32
    package var streamID: UInt16
    package var ppid: SCTPDataChannelPPID
    package var payload: Data

    package init(
        messageID: UInt32,
        fragmentIndex: UInt16,
        fragmentCount: UInt16,
        originalPayloadLength: UInt32,
        streamID: UInt16,
        ppid: SCTPDataChannelPPID,
        payload: Data
    ) throws {
        guard fragmentCount > 0, fragmentIndex < fragmentCount else {
            throw SCTPDataChannelError.invalidFragmentCount(fragmentCount)
        }

        self.messageID = messageID
        self.fragmentIndex = fragmentIndex
        self.fragmentCount = fragmentCount
        self.originalPayloadLength = originalPayloadLength
        self.streamID = streamID
        self.ppid = ppid
        self.payload = payload
    }

    package init(decoding data: Data) throws {
        guard data.count >= Self.headerByteCount else {
            throw SCTPDataChannelError.truncatedFragmentEnvelope
        }
        guard Self.hasMagicPrefix(data) else {
            throw SCTPDataChannelError.invalidFragmentEnvelopeMagic
        }

        let version = data.byte(at: 4)
        guard version == Self.version else {
            throw SCTPDataChannelError.unsupportedFragmentEnvelopeVersion(version)
        }

        let rawPPID = data.uint32(at: 19)
        guard let ppid = SCTPDataChannelPPID(rawValue: rawPPID) else {
            throw SCTPDataChannelError.invalidFragmentEnvelopePPID(rawPPID)
        }

        let payloadLength = Int(data.uint32(at: 23))
        let actualLength = data.count - Self.headerByteCount
        guard payloadLength == actualLength else {
            throw SCTPDataChannelError.fragmentEnvelopeLengthMismatch(
                expected: payloadLength,
                actual: actualLength
            )
        }

        try self.init(
            messageID: data.uint32(at: 5),
            fragmentIndex: data.uint16(at: 9),
            fragmentCount: data.uint16(at: 11),
            originalPayloadLength: data.uint32(at: 13),
            streamID: data.uint16(at: 17),
            ppid: ppid,
            payload: Data(data.dropFirst(Self.headerByteCount))
        )
    }

    package static func hasMagicPrefix(_ data: Data) -> Bool {
        data.count >= magic.count && data.prefix(magic.count) == magic
    }

    package func encoded() -> Data {
        var data = Data()
        data.append(Self.magic)
        data.append(Self.version)
        data.append(messageID.bigEndianBytes)
        data.append(fragmentIndex.bigEndianBytes)
        data.append(fragmentCount.bigEndianBytes)
        data.append(originalPayloadLength.bigEndianBytes)
        data.append(streamID.bigEndianBytes)
        data.append(ppid.rawValue.bigEndianBytes)
        data.append(UInt32(payload.count).bigEndianBytes)
        data.append(payload)
        return data
    }
}

package struct SCTPDataChannelFragmenter: Sendable {
    package var maxFragmentPayloadSize: Int
    private var nextMessageID: UInt32

    package init(maxFragmentPayloadSize: Int = 1_200, firstMessageID: UInt32 = 1) {
        self.maxFragmentPayloadSize = maxFragmentPayloadSize
        self.nextMessageID = firstMessageID
    }

    package mutating func fragment(_ packet: SCTPDataChannelPacket) throws -> [SCTPDataChannelFragmentEnvelope] {
        guard maxFragmentPayloadSize > 0 else {
            throw SCTPDataChannelError.invalidFragmentPayloadSize(maxFragmentPayloadSize)
        }

        let fragmentCount = max(1, (packet.payload.count + maxFragmentPayloadSize - 1) / maxFragmentPayloadSize)
        guard fragmentCount <= Int(UInt16.max) else {
            throw SCTPDataChannelError.tooManyFragments(fragmentCount)
        }

        let messageID = nextMessageID
        nextMessageID &+= 1
        let fragmentCount16 = UInt16(fragmentCount)
        let originalPayloadLength = UInt32(packet.payload.count)

        if packet.payload.isEmpty {
            return [
                try SCTPDataChannelFragmentEnvelope(
                    messageID: messageID,
                    fragmentIndex: 0,
                    fragmentCount: 1,
                    originalPayloadLength: 0,
                    streamID: packet.streamID,
                    ppid: packet.ppid,
                    payload: Data()
                ),
            ]
        }

        return try (0..<fragmentCount).map { index in
            let startOffset = index * maxFragmentPayloadSize
            let endOffset = min(packet.payload.count, startOffset + maxFragmentPayloadSize)
            let startIndex = packet.payload.index(packet.payload.startIndex, offsetBy: startOffset)
            let endIndex = packet.payload.index(packet.payload.startIndex, offsetBy: endOffset)
            return try SCTPDataChannelFragmentEnvelope(
                messageID: messageID,
                fragmentIndex: UInt16(index),
                fragmentCount: fragmentCount16,
                originalPayloadLength: originalPayloadLength,
                streamID: packet.streamID,
                ppid: packet.ppid,
                payload: Data(packet.payload[startIndex..<endIndex])
            )
        }
    }
}

package struct SCTPDataChannelReassembler: Sendable {
    private struct PendingMessage: Sendable {
        var streamID: UInt16
        var ppid: SCTPDataChannelPPID
        var fragmentCount: UInt16
        var originalPayloadLength: UInt32
        var fragments: [UInt16: Data]
    }

    private var pendingMessages: [UInt32: PendingMessage] = [:]

    package init() {}

    package var pendingMessageCount: Int {
        pendingMessages.count
    }

    package mutating func append(_ envelope: SCTPDataChannelFragmentEnvelope) throws -> SCTPDataChannelPacket? {
        var pending = pendingMessages[envelope.messageID] ?? PendingMessage(
            streamID: envelope.streamID,
            ppid: envelope.ppid,
            fragmentCount: envelope.fragmentCount,
            originalPayloadLength: envelope.originalPayloadLength,
            fragments: [:]
        )

        guard
            pending.streamID == envelope.streamID,
            pending.ppid == envelope.ppid,
            pending.fragmentCount == envelope.fragmentCount,
            pending.originalPayloadLength == envelope.originalPayloadLength
        else {
            throw SCTPDataChannelError.mismatchedFragmentMetadata(messageID: envelope.messageID)
        }

        guard pending.fragments[envelope.fragmentIndex] == nil else {
            throw SCTPDataChannelError.duplicateFragment(
                messageID: envelope.messageID,
                fragmentIndex: envelope.fragmentIndex
            )
        }

        pending.fragments[envelope.fragmentIndex] = envelope.payload
        pendingMessages[envelope.messageID] = pending

        guard pending.fragments.count == Int(pending.fragmentCount) else {
            return nil
        }

        var payload = Data()
        for index in 0..<Int(pending.fragmentCount) {
            guard let fragment = pending.fragments[UInt16(index)] else {
                throw SCTPDataChannelError.missingFragments(messageID: envelope.messageID)
            }
            payload.append(fragment)
        }

        guard payload.count == Int(pending.originalPayloadLength) else {
            throw SCTPDataChannelError.fragmentEnvelopeLengthMismatch(
                expected: Int(pending.originalPayloadLength),
                actual: payload.count
            )
        }

        pendingMessages[envelope.messageID] = nil
        return SCTPDataChannelPacket(
            streamID: pending.streamID,
            ppid: pending.ppid,
            payload: payload
        )
    }
}

package struct SCTPDataChannelRetransmissionPolicy: Equatable, Sendable {
    package var initialDelaySeconds: TimeInterval
    package var maxAttempts: Int

    package init(initialDelaySeconds: TimeInterval = 0.5, maxAttempts: Int = 5) {
        self.initialDelaySeconds = max(0, initialDelaySeconds)
        self.maxAttempts = max(1, maxAttempts)
    }
}

package struct SCTPDataChannelScheduledFragment: Equatable, Sendable {
    package var envelope: SCTPDataChannelFragmentEnvelope
    package var attempt: Int
    package var nextTransmitAt: TimeInterval

    package init(
        envelope: SCTPDataChannelFragmentEnvelope,
        attempt: Int,
        nextTransmitAt: TimeInterval
    ) {
        self.envelope = envelope
        self.attempt = attempt
        self.nextTransmitAt = nextTransmitAt
    }
}

package struct SCTPDataChannelRetransmissionQueue: Sendable {
    private struct FragmentKey: Hashable, Sendable {
        var messageID: UInt32
        var fragmentIndex: UInt16
    }

    private var scheduledFragments: [FragmentKey: SCTPDataChannelScheduledFragment] = [:]

    package init() {}

    package var pendingCount: Int {
        scheduledFragments.count
    }

    package mutating func enqueue(
        _ envelopes: [SCTPDataChannelFragmentEnvelope],
        at now: TimeInterval
    ) {
        for envelope in envelopes {
            let key = FragmentKey(
                messageID: envelope.messageID,
                fragmentIndex: envelope.fragmentIndex
            )
            scheduledFragments[key] = SCTPDataChannelScheduledFragment(
                envelope: envelope,
                attempt: 0,
                nextTransmitAt: now
            )
        }
    }

    package mutating func markAcknowledged(messageID: UInt32, fragmentIndex: UInt16) {
        scheduledFragments.removeValue(forKey: FragmentKey(
            messageID: messageID,
            fragmentIndex: fragmentIndex
        ))
    }

    package mutating func markMessageAcknowledged(messageID: UInt32) {
        scheduledFragments = scheduledFragments.filter { $0.key.messageID != messageID }
    }

    package mutating func dueFragments(
        at now: TimeInterval,
        policy: SCTPDataChannelRetransmissionPolicy = SCTPDataChannelRetransmissionPolicy()
    ) throws -> [SCTPDataChannelScheduledFragment] {
        var due: [SCTPDataChannelScheduledFragment] = []
        let dueKeys = scheduledFragments.keys
            .filter { scheduledFragments[$0].map { $0.nextTransmitAt <= now } ?? false }
            .sorted {
                ($0.messageID, $0.fragmentIndex) < ($1.messageID, $1.fragmentIndex)
            }

        for key in dueKeys {
            guard var scheduled = scheduledFragments[key] else {
                continue
            }
            guard scheduled.attempt < policy.maxAttempts else {
                throw SCTPDataChannelError.retransmissionAttemptsExhausted(
                    messageID: key.messageID,
                    fragmentIndex: key.fragmentIndex
                )
            }

            scheduled.attempt += 1
            scheduled.nextTransmitAt = now + retryDelay(
                forAttempt: scheduled.attempt,
                policy: policy
            )
            scheduledFragments[key] = scheduled
            due.append(scheduled)
        }

        return due
    }

    private func retryDelay(
        forAttempt attempt: Int,
        policy: SCTPDataChannelRetransmissionPolicy
    ) -> TimeInterval {
        let exponent = min(max(0, attempt - 1), 30)
        return policy.initialDelaySeconds * TimeInterval(1 << exponent)
    }
}

package actor DTLSSCTPDataChannelPacketTransport: SCTPDataChannelPacketTransceiver {
    private let dtlsTransport: OpenSSLDTLSApplicationDataTransport
    private let codec: SCTPDataChannelPacketEnvelopeCodec
    private var fragmenter: SCTPDataChannelFragmenter?
    private var reassembler: SCTPDataChannelReassembler

    package init(
        dtlsTransport: OpenSSLDTLSApplicationDataTransport,
        codec: SCTPDataChannelPacketEnvelopeCodec = SCTPDataChannelPacketEnvelopeCodec(),
        maxFragmentPayloadSize: Int? = nil
    ) {
        self.dtlsTransport = dtlsTransport
        self.codec = codec
        self.fragmenter = maxFragmentPayloadSize.map {
            SCTPDataChannelFragmenter(maxFragmentPayloadSize: $0)
        }
        self.reassembler = SCTPDataChannelReassembler()
    }

    package func send(_ packet: SCTPDataChannelPacket) async throws {
        if var fragmenter {
            let envelopes = try fragmenter.fragment(packet)
            self.fragmenter = fragmenter
            for envelope in envelopes {
                try await dtlsTransport.send(envelope.encoded())
            }
            return
        }

        try await dtlsTransport.send(codec.encode(packet))
    }

    package func receive() async throws -> SCTPDataChannelPacket {
        while true {
            let data = try await dtlsTransport.receive()
            guard SCTPDataChannelFragmentEnvelope.hasMagicPrefix(data) else {
                return try codec.decode(data)
            }

            let envelope = try SCTPDataChannelFragmentEnvelope(decoding: data)
            if let packet = try reassembler.append(envelope) {
                return packet
            }
        }
    }
}

private extension Data {
    func byte(at offset: Int) -> UInt8 {
        self[index(startIndex, offsetBy: offset)]
    }

    func uint16(at offset: Int) -> UInt16 {
        UInt16(byte(at: offset)) << 8 | UInt16(byte(at: offset + 1))
    }

    func uint32(at offset: Int) -> UInt32 {
        UInt32(byte(at: offset)) << 24 |
            UInt32(byte(at: offset + 1)) << 16 |
            UInt32(byte(at: offset + 2)) << 8 |
            UInt32(byte(at: offset + 3))
    }
}

private extension UInt16 {
    var bigEndianBytes: Data {
        Data([UInt8((self >> 8) & 0xff), UInt8(self & 0xff)])
    }
}

private extension UInt32 {
    var bigEndianBytes: Data {
        Data([
            UInt8((self >> 24) & 0xff),
            UInt8((self >> 16) & 0xff),
            UInt8((self >> 8) & 0xff),
            UInt8(self & 0xff),
        ])
    }
}

private extension NSLocking {
    func withCriticalSection<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
