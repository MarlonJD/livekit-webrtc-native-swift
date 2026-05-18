import Foundation

package enum SCTPDataChannelError: Error, Equatable, Sendable {
    case truncatedSCTPPacket
    case invalidSCTPChecksum(expected: UInt32, actual: UInt32)
    case truncatedSCTPChunk
    case invalidSCTPChunkLength(UInt16)
    case invalidSCTPParameterLength(UInt16)
    case invalidSCTPDataChunkType(UInt8)
    case invalidSCTPDataChunkLength(Int)
    case invalidSCTPInitChunkType(UInt8)
    case invalidSCTPInitChunkLength(Int)
    case invalidSCTPSACKChunkType(UInt8)
    case invalidSCTPSACKChunkLength(Int)
    case invalidSCTPDataChunkFragmentPayloadSize(Int)
    case missingSCTPStateCookie
    case missingSCTPPeerVerificationTag
    case invalidSCTPVerificationTag(expected: UInt32, actual: UInt32)
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

package enum SCTPChunkType: UInt8, Equatable, Sendable {
    case data = 0
    case initChunk = 1
    case initAck = 2
    case sack = 3
    case heartbeat = 4
    case heartbeatAck = 5
    case abort = 6
    case shutdown = 7
    case shutdownAck = 8
    case error = 9
    case cookieEcho = 10
    case cookieAck = 11
}

package enum SCTPParameterType {
    package static let stateCookie: UInt16 = 0x0007
    package static let supportedAddressTypes: UInt16 = 0x000c
}

package struct SCTPParameter: Equatable, Sendable {
    package var type: UInt16
    package var value: Data

    package init(type: UInt16, value: Data) {
        self.type = type
        self.value = value
    }

    fileprivate init(decoding data: Data, offset: inout Int) throws {
        guard data.count - offset >= 4 else {
            throw SCTPDataChannelError.invalidSCTPParameterLength(UInt16(data.count - offset))
        }

        self.type = data.uint16(at: offset)
        let length = Int(data.uint16(at: offset + 2))
        guard length >= 4 else {
            throw SCTPDataChannelError.invalidSCTPParameterLength(UInt16(length))
        }
        guard offset + length <= data.count else {
            throw SCTPDataChannelError.invalidSCTPParameterLength(UInt16(length))
        }

        self.value = Data(data[(offset + 4)..<(offset + length)])
        offset += Self.paddedLength(length)
    }

    fileprivate func encoded() -> Data {
        let length = 4 + value.count
        var data = Data()
        data.append(type.bigEndianBytes)
        data.append(UInt16(length).bigEndianBytes)
        data.append(value)
        data.appendPadding(toMultipleOfFourFrom: length)
        return data
    }

    private static func paddedLength(_ length: Int) -> Int {
        length + ((4 - (length % 4)) % 4)
    }
}

package struct SCTPDataChunk: Equatable, Sendable {
    package var unordered: Bool
    package var beginning: Bool
    package var ending: Bool
    package var tsn: UInt32
    package var streamID: UInt16
    package var streamSequenceNumber: UInt16
    package var payloadProtocolIdentifier: UInt32
    package var userData: Data

    package init(
        unordered: Bool = false,
        beginning: Bool = true,
        ending: Bool = true,
        tsn: UInt32,
        streamID: UInt16,
        streamSequenceNumber: UInt16,
        payloadProtocolIdentifier: UInt32,
        userData: Data
    ) {
        self.unordered = unordered
        self.beginning = beginning
        self.ending = ending
        self.tsn = tsn
        self.streamID = streamID
        self.streamSequenceNumber = streamSequenceNumber
        self.payloadProtocolIdentifier = payloadProtocolIdentifier
        self.userData = userData
    }

    package init(chunk: SCTPChunk) throws {
        guard chunk.rawType == SCTPChunkType.data.rawValue else {
            throw SCTPDataChannelError.invalidSCTPDataChunkType(chunk.rawType)
        }
        guard chunk.value.count >= 12 else {
            throw SCTPDataChannelError.invalidSCTPDataChunkLength(chunk.value.count)
        }

        self.unordered = (chunk.flags & 0x04) != 0
        self.beginning = (chunk.flags & 0x02) != 0
        self.ending = (chunk.flags & 0x01) != 0
        self.tsn = chunk.value.uint32(at: 0)
        self.streamID = chunk.value.uint16(at: 4)
        self.streamSequenceNumber = chunk.value.uint16(at: 6)
        self.payloadProtocolIdentifier = chunk.value.uint32(at: 8)
        self.userData = Data(chunk.value.dropFirst(12))
    }

    fileprivate var flags: UInt8 {
        (unordered ? 0x04 : 0) |
            (beginning ? 0x02 : 0) |
            (ending ? 0x01 : 0)
    }

    fileprivate func chunk() -> SCTPChunk {
        var value = Data()
        value.append(tsn.bigEndianBytes)
        value.append(streamID.bigEndianBytes)
        value.append(streamSequenceNumber.bigEndianBytes)
        value.append(payloadProtocolIdentifier.bigEndianBytes)
        value.append(userData)
        return SCTPChunk(type: .data, flags: flags, value: value)
    }
}

package struct SCTPSACKGapAckBlock: Equatable, Sendable {
    package var start: UInt16
    package var end: UInt16

    package init(start: UInt16, end: UInt16) {
        self.start = start
        self.end = end
    }
}

package struct SCTPSACKChunk: Equatable, Sendable {
    package var cumulativeTSNAck: UInt32
    package var advertisedReceiverWindowCredit: UInt32
    package var gapAckBlocks: [SCTPSACKGapAckBlock]
    package var duplicateTSNs: [UInt32]

    package init(
        cumulativeTSNAck: UInt32,
        advertisedReceiverWindowCredit: UInt32,
        gapAckBlocks: [SCTPSACKGapAckBlock] = [],
        duplicateTSNs: [UInt32] = []
    ) {
        self.cumulativeTSNAck = cumulativeTSNAck
        self.advertisedReceiverWindowCredit = advertisedReceiverWindowCredit
        self.gapAckBlocks = gapAckBlocks
        self.duplicateTSNs = duplicateTSNs
    }

    package init(chunk: SCTPChunk) throws {
        guard chunk.rawType == SCTPChunkType.sack.rawValue else {
            throw SCTPDataChannelError.invalidSCTPSACKChunkType(chunk.rawType)
        }
        guard chunk.value.count >= 12 else {
            throw SCTPDataChannelError.invalidSCTPSACKChunkLength(chunk.value.count)
        }

        let gapAckBlockCount = Int(chunk.value.uint16(at: 8))
        let duplicateTSNCount = Int(chunk.value.uint16(at: 10))
        let expectedLength = 12 + (gapAckBlockCount * 4) + (duplicateTSNCount * 4)
        guard chunk.value.count == expectedLength else {
            throw SCTPDataChannelError.invalidSCTPSACKChunkLength(chunk.value.count)
        }

        self.cumulativeTSNAck = chunk.value.uint32(at: 0)
        self.advertisedReceiverWindowCredit = chunk.value.uint32(at: 4)

        var offset = 12
        self.gapAckBlocks = (0..<gapAckBlockCount).map { _ in
            defer { offset += 4 }
            return SCTPSACKGapAckBlock(
                start: chunk.value.uint16(at: offset),
                end: chunk.value.uint16(at: offset + 2)
            )
        }
        self.duplicateTSNs = (0..<duplicateTSNCount).map { _ in
            defer { offset += 4 }
            return chunk.value.uint32(at: offset)
        }
    }

    fileprivate func chunk() -> SCTPChunk {
        var value = Data()
        value.append(cumulativeTSNAck.bigEndianBytes)
        value.append(advertisedReceiverWindowCredit.bigEndianBytes)
        value.append(UInt16(gapAckBlocks.count).bigEndianBytes)
        value.append(UInt16(duplicateTSNs.count).bigEndianBytes)
        for block in gapAckBlocks {
            value.append(block.start.bigEndianBytes)
            value.append(block.end.bigEndianBytes)
        }
        for tsn in duplicateTSNs {
            value.append(tsn.bigEndianBytes)
        }
        return SCTPChunk(type: .sack, value: value)
    }
}

package struct SCTPInitChunk: Equatable, Sendable {
    package var type: SCTPChunkType
    package var initiateTag: UInt32
    package var advertisedReceiverWindowCredit: UInt32
    package var outboundStreams: UInt16
    package var inboundStreams: UInt16
    package var initialTSN: UInt32
    package var parameters: [SCTPParameter]

    package init(
        type: SCTPChunkType = .initChunk,
        initiateTag: UInt32,
        advertisedReceiverWindowCredit: UInt32,
        outboundStreams: UInt16,
        inboundStreams: UInt16,
        initialTSN: UInt32,
        parameters: [SCTPParameter] = []
    ) {
        self.type = type
        self.initiateTag = initiateTag
        self.advertisedReceiverWindowCredit = advertisedReceiverWindowCredit
        self.outboundStreams = outboundStreams
        self.inboundStreams = inboundStreams
        self.initialTSN = initialTSN
        self.parameters = parameters
    }

    package init(chunk: SCTPChunk) throws {
        guard chunk.rawType == SCTPChunkType.initChunk.rawValue ||
              chunk.rawType == SCTPChunkType.initAck.rawValue
        else {
            throw SCTPDataChannelError.invalidSCTPInitChunkType(chunk.rawType)
        }
        guard chunk.value.count >= 16 else {
            throw SCTPDataChannelError.invalidSCTPInitChunkLength(chunk.value.count)
        }

        self.type = SCTPChunkType(rawValue: chunk.rawType) ?? .initChunk
        self.initiateTag = chunk.value.uint32(at: 0)
        self.advertisedReceiverWindowCredit = chunk.value.uint32(at: 4)
        self.outboundStreams = chunk.value.uint16(at: 8)
        self.inboundStreams = chunk.value.uint16(at: 10)
        self.initialTSN = chunk.value.uint32(at: 12)

        var offset = 16
        var parameters: [SCTPParameter] = []
        while offset < chunk.value.count {
            parameters.append(try SCTPParameter(decoding: chunk.value, offset: &offset))
        }
        self.parameters = parameters
    }

    fileprivate func chunk() -> SCTPChunk {
        var value = Data()
        value.append(initiateTag.bigEndianBytes)
        value.append(advertisedReceiverWindowCredit.bigEndianBytes)
        value.append(outboundStreams.bigEndianBytes)
        value.append(inboundStreams.bigEndianBytes)
        value.append(initialTSN.bigEndianBytes)
        for parameter in parameters {
            value.append(parameter.encoded())
        }
        return SCTPChunk(type: type, flags: 0, value: value)
    }
}

package struct SCTPChunk: Equatable, Sendable {
    package var rawType: UInt8
    package var flags: UInt8
    package var value: Data

    package init(rawType: UInt8, flags: UInt8 = 0, value: Data = Data()) {
        self.rawType = rawType
        self.flags = flags
        self.value = value
    }

    package init(type: SCTPChunkType, flags: UInt8 = 0, value: Data = Data()) {
        self.init(rawType: type.rawValue, flags: flags, value: value)
    }

    package static func data(_ chunk: SCTPDataChunk) -> SCTPChunk {
        chunk.chunk()
    }

    package static func initChunk(_ chunk: SCTPInitChunk) -> SCTPChunk {
        chunk.chunk()
    }

    package static func sack(_ chunk: SCTPSACKChunk) -> SCTPChunk {
        chunk.chunk()
    }

    package static func cookieEcho(_ cookie: Data) -> SCTPChunk {
        SCTPChunk(type: .cookieEcho, value: cookie)
    }

    package static var cookieAck: SCTPChunk {
        SCTPChunk(type: .cookieAck)
    }

    package var type: SCTPChunkType? {
        SCTPChunkType(rawValue: rawType)
    }

    fileprivate init(decoding data: Data, offset: inout Int) throws {
        guard data.count - offset >= 4 else {
            throw SCTPDataChannelError.truncatedSCTPChunk
        }

        self.rawType = data.byte(at: offset)
        self.flags = data.byte(at: offset + 1)
        let length = Int(data.uint16(at: offset + 2))
        guard length >= 4 else {
            throw SCTPDataChannelError.invalidSCTPChunkLength(UInt16(length))
        }
        guard offset + length <= data.count else {
            throw SCTPDataChannelError.truncatedSCTPChunk
        }

        self.value = Data(data[(offset + 4)..<(offset + length)])
        offset += Self.paddedLength(length)
    }

    fileprivate func encoded() -> Data {
        let length = 4 + value.count
        var data = Data()
        data.append(rawType)
        data.append(flags)
        data.append(UInt16(length).bigEndianBytes)
        data.append(value)
        data.appendPadding(toMultipleOfFourFrom: length)
        return data
    }

    private static func paddedLength(_ length: Int) -> Int {
        length + ((4 - (length % 4)) % 4)
    }
}

package struct SCTPPacket: Equatable, Sendable {
    package var sourcePort: UInt16
    package var destinationPort: UInt16
    package var verificationTag: UInt32
    package var chunks: [SCTPChunk]

    package init(
        sourcePort: UInt16 = 5_000,
        destinationPort: UInt16 = 5_000,
        verificationTag: UInt32,
        chunks: [SCTPChunk]
    ) {
        self.sourcePort = sourcePort
        self.destinationPort = destinationPort
        self.verificationTag = verificationTag
        self.chunks = chunks
    }

    package init(decoding data: Data, validateChecksum: Bool = true) throws {
        guard data.count >= 12 else {
            throw SCTPDataChannelError.truncatedSCTPPacket
        }

        if validateChecksum {
            let expectedChecksum = data.uint32(at: 8)
            let actualChecksum = SCTPCRC32C.checksum(data.zeroingSCTPChecksum())
            guard expectedChecksum == actualChecksum else {
                throw SCTPDataChannelError.invalidSCTPChecksum(
                    expected: expectedChecksum,
                    actual: actualChecksum
                )
            }
        }

        self.sourcePort = data.uint16(at: 0)
        self.destinationPort = data.uint16(at: 2)
        self.verificationTag = data.uint32(at: 4)

        var offset = 12
        var chunks: [SCTPChunk] = []
        while offset < data.count {
            chunks.append(try SCTPChunk(decoding: data, offset: &offset))
        }
        self.chunks = chunks
    }

    package func encoded(includeChecksum: Bool = true) -> Data {
        var data = Data()
        data.append(sourcePort.bigEndianBytes)
        data.append(destinationPort.bigEndianBytes)
        data.append(verificationTag.bigEndianBytes)
        data.append(UInt32.zero.bigEndianBytes)
        for chunk in chunks {
            data.append(chunk.encoded())
        }

        if includeChecksum {
            let checksum = SCTPCRC32C.checksum(data)
            data.replaceSubrange(8..<12, with: checksum.bigEndianBytes)
        }
        return data
    }
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

    package init(dataChunk: SCTPDataChunk) throws {
        guard let ppid = SCTPDataChannelPPID(rawValue: dataChunk.payloadProtocolIdentifier) else {
            throw SCTPDataChannelError.invalidPacketEnvelopePPID(dataChunk.payloadProtocolIdentifier)
        }

        self.init(
            streamID: dataChunk.streamID,
            ppid: ppid,
            payload: dataChunk.userData
        )
    }

    package func dataChunk(
        tsn: UInt32,
        streamSequenceNumber: UInt16 = 0,
        unordered: Bool = false
    ) -> SCTPDataChunk {
        SCTPDataChunk(
            unordered: unordered,
            beginning: true,
            ending: true,
            tsn: tsn,
            streamID: streamID,
            streamSequenceNumber: streamSequenceNumber,
            payloadProtocolIdentifier: ppid.rawValue,
            userData: payload
        )
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

    package func resetForRecovery() {
        lock.withCriticalSection {
            mutableState = .connecting
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
        switch message {
        case let .open(openMessage):
            acceptRemoteOpen(openMessage, streamID: packet.streamID)
        case .acknowledgement:
            let channel = try channel(for: packet.streamID)
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

    package func resetChannelsForRecovery() {
        lock.withCriticalSection {
            for channel in channelsByStreamID.values {
                channel.resetForRecovery()
            }
        }
    }

    private func acceptRemoteOpen(_ message: SCTPDataChannelOpenMessage, streamID: UInt16) {
        lock.withCriticalSection {
            if let channel = channelsByStreamID[streamID] {
                channel.acceptRemoteOpen(message)
                channelsByLabel[message.label] = channel
                return
            }

            if let previous = channelsByLabel[message.label] {
                channelsByStreamID.removeValue(forKey: previous.streamID)
            }

            let channel = SCTPDataChannel(streamID: streamID, label: message.label, reliability: message.reliability)
            channel.acceptRemoteOpen(message)
            channelsByStreamID[streamID] = channel
            channelsByLabel[message.label] = channel
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
    private let retransmissionPolicy: SCTPDataChannelRetransmissionPolicy
    private var fragmenter: SCTPDataChannelFragmenter?
    private var reassembler: SCTPDataChannelReassembler
    private var retransmissionQueue: SCTPDataChannelRetransmissionQueue

    package init(
        dtlsTransport: OpenSSLDTLSApplicationDataTransport,
        codec: SCTPDataChannelPacketEnvelopeCodec = SCTPDataChannelPacketEnvelopeCodec(),
        maxFragmentPayloadSize: Int? = nil,
        retransmissionPolicy: SCTPDataChannelRetransmissionPolicy = SCTPDataChannelRetransmissionPolicy()
    ) {
        self.dtlsTransport = dtlsTransport
        self.codec = codec
        self.retransmissionPolicy = retransmissionPolicy
        self.fragmenter = maxFragmentPayloadSize.map {
            SCTPDataChannelFragmenter(maxFragmentPayloadSize: $0)
        }
        self.reassembler = SCTPDataChannelReassembler()
        self.retransmissionQueue = SCTPDataChannelRetransmissionQueue()
    }

    package var pendingRetransmissionCount: Int {
        retransmissionQueue.pendingCount
    }

    package func send(_ packet: SCTPDataChannelPacket) async throws {
        if var fragmenter {
            let envelopes = try fragmenter.fragment(packet)
            self.fragmenter = fragmenter
            retransmissionQueue.enqueue(
                envelopes,
                at: Date().timeIntervalSince1970 + retransmissionPolicy.initialDelaySeconds
            )
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

    @discardableResult
    package func sendDueRetransmissions(
        at now: TimeInterval = Date().timeIntervalSince1970
    ) async throws -> [SCTPDataChannelScheduledFragment] {
        let dueFragments = try retransmissionQueue.dueFragments(
            at: now,
            policy: retransmissionPolicy
        )
        for fragment in dueFragments {
            try await dtlsTransport.send(fragment.envelope.encoded())
        }
        return dueFragments
    }

    package func markFragmentAcknowledged(messageID: UInt32, fragmentIndex: UInt16) {
        retransmissionQueue.markAcknowledged(
            messageID: messageID,
            fragmentIndex: fragmentIndex
        )
    }

    package func markMessageAcknowledged(messageID: UInt32) {
        retransmissionQueue.markMessageAcknowledged(messageID: messageID)
    }
}

package struct SCTPAssociationConfiguration: Equatable, Sendable {
    package static let webRTCDataChannelPort: UInt16 = 5_000

    package var localPort: UInt16
    package var remotePort: UInt16
    package var localInitiateTag: UInt32
    package var initialTSN: UInt32
    package var advertisedReceiverWindowCredit: UInt32
    package var outboundStreams: UInt16
    package var inboundStreams: UInt16
    package var stateCookie: Data
    package var maxDataChunkPayloadSize: Int?

    package init(
        localPort: UInt16 = Self.webRTCDataChannelPort,
        remotePort: UInt16 = Self.webRTCDataChannelPort,
        localInitiateTag: UInt32 = UInt32.random(in: 1...UInt32.max),
        initialTSN: UInt32 = UInt32.random(in: 0...UInt32.max),
        advertisedReceiverWindowCredit: UInt32 = 1_048_576,
        outboundStreams: UInt16 = 1_024,
        inboundStreams: UInt16 = 1_024,
        stateCookie: Data = Data([0x4c, 0x4b, 0x4e, 0x53, 0x43, 0x54, 0x50]),
        maxDataChunkPayloadSize: Int? = nil
    ) {
        self.localPort = localPort
        self.remotePort = remotePort
        self.localInitiateTag = localInitiateTag == 0 ? 1 : localInitiateTag
        self.initialTSN = initialTSN
        self.advertisedReceiverWindowCredit = advertisedReceiverWindowCredit
        self.outboundStreams = outboundStreams
        self.inboundStreams = inboundStreams
        self.stateCookie = stateCookie
        self.maxDataChunkPayloadSize = maxDataChunkPayloadSize
    }
}

private struct SCTPDataChunkFragmentReassembler {
    private struct FragmentKey: Hashable {
        var streamID: UInt16
        var streamSequenceNumber: UInt16
        var payloadProtocolIdentifier: UInt32
    }

    private struct PendingFragments {
        var chunksByTSN: [UInt32: SCTPDataChunk] = [:]
        var beginningTSN: UInt32?
        var endingTSN: UInt32?
    }

    private var pendingFragmentsByKey: [FragmentKey: PendingFragments] = [:]

    mutating func append(_ chunk: SCTPDataChunk) throws -> SCTPDataChannelPacket? {
        guard !(chunk.beginning && chunk.ending) else {
            return try SCTPDataChannelPacket(dataChunk: chunk)
        }

        let key = FragmentKey(
            streamID: chunk.streamID,
            streamSequenceNumber: chunk.streamSequenceNumber,
            payloadProtocolIdentifier: chunk.payloadProtocolIdentifier
        )
        var pending = pendingFragmentsByKey[key] ?? PendingFragments()
        pending.chunksByTSN[chunk.tsn] = chunk

        if chunk.beginning {
            pending.beginningTSN = chunk.tsn
        }
        if chunk.ending {
            pending.endingTSN = chunk.tsn
        }

        guard let beginningTSN = pending.beginningTSN,
              let endingTSN = pending.endingTSN
        else {
            pendingFragmentsByKey[key] = pending
            return nil
        }

        let fragmentDistance = endingTSN &- beginningTSN
        let fragmentCount = Int(fragmentDistance) + 1
        guard pending.chunksByTSN.count >= fragmentCount else {
            pendingFragmentsByKey[key] = pending
            return nil
        }

        var userData = Data()
        for offset in 0..<fragmentCount {
            let tsn = beginningTSN &+ UInt32(offset)
            guard let fragment = pending.chunksByTSN[tsn] else {
                pendingFragmentsByKey[key] = pending
                return nil
            }
            userData.append(fragment.userData)
        }

        pendingFragmentsByKey.removeValue(forKey: key)
        return try SCTPDataChannelPacket(dataChunk: SCTPDataChunk(
            unordered: chunk.unordered,
            beginning: true,
            ending: true,
            tsn: beginningTSN,
            streamID: key.streamID,
            streamSequenceNumber: key.streamSequenceNumber,
            payloadProtocolIdentifier: key.payloadProtocolIdentifier,
            userData: userData
        ))
    }
}

package actor DTLSSCTPAssociationDataChannelPacketTransport: SCTPDataChannelPacketTransceiver {
    private enum AssociationState: Equatable {
        case new
        case initSent
        case initAckSent
        case cookieEchoSent
        case established
    }

    private let dtlsTransport: OpenSSLDTLSApplicationDataTransport
    private let configuration: SCTPAssociationConfiguration
    private var state: AssociationState = .new
    private var peerVerificationTag: UInt32?
    private var nextTSN: UInt32
    private var expectedPeerTSN: UInt32?
    private var nextStreamSequenceNumbers: [UInt16: UInt16] = [:]
    private var pendingReceivedPackets: [SCTPDataChannelPacket] = []
    private var receivePumpTask: Task<Void, Never>?
    private var receivePumpError: (any Error)?
    private var associationWaiters: [CheckedContinuation<Void, any Error>] = []
    private var packetWaiters: [CheckedContinuation<SCTPDataChannelPacket, any Error>] = []
    private var fragmentReassembler = SCTPDataChunkFragmentReassembler()

    package init(
        dtlsTransport: OpenSSLDTLSApplicationDataTransport,
        configuration: SCTPAssociationConfiguration = SCTPAssociationConfiguration()
    ) {
        self.dtlsTransport = dtlsTransport
        self.configuration = configuration
        self.nextTSN = configuration.initialTSN
    }

    package var isEstablished: Bool {
        state == .established
    }

    package func startAssociation() async throws {
        try await ensureAssociation()
    }

    package func send(_ packet: SCTPDataChannelPacket) async throws {
        try await ensureAssociation()
        let streamSequenceNumber = nextStreamSequenceNumber(for: packet.streamID)
        let dataChunks = try dataChunks(
            for: packet,
            firstTSN: nextTSN,
            streamSequenceNumber: streamSequenceNumber
        )
        nextTSN &+= UInt32(dataChunks.count)
        try await sendPacket(
            verificationTag: try requirePeerVerificationTag(),
            chunks: dataChunks.map { .data($0) }
        )
    }

    package func receive() async throws -> SCTPDataChannelPacket {
        if !pendingReceivedPackets.isEmpty {
            return pendingReceivedPackets.removeFirst()
        }

        try await ensureAssociation()
        if !pendingReceivedPackets.isEmpty {
            return pendingReceivedPackets.removeFirst()
        }

        return try await waitForPacket()
    }

    private func ensureAssociation() async throws {
        guard state != .established else {
            return
        }
        if let receivePumpError {
            throw receivePumpError
        }

        startReceivePumpIfNeeded()

        if state == .new {
            state = .initSent
            try await sendInit()
        }

        try await waitForAssociation()
    }

    private func sendInit() async throws {
        let initChunk = SCTPInitChunk(
            type: .initChunk,
            initiateTag: configuration.localInitiateTag,
            advertisedReceiverWindowCredit: configuration.advertisedReceiverWindowCredit,
            outboundStreams: configuration.outboundStreams,
            inboundStreams: configuration.inboundStreams,
            initialTSN: configuration.initialTSN,
            parameters: [
                SCTPParameter(
                    type: SCTPParameterType.supportedAddressTypes,
                    value: Data([0x00, 0x05, 0x00, 0x06])
                ),
            ]
        )
        try await sendPacket(verificationTag: 0, chunks: [.initChunk(initChunk)])
    }

    private func processInbound(_ data: Data) async throws {
        let packet = try SCTPPacket(decoding: data)
        for chunk in packet.chunks {
            switch chunk.type {
            case .initChunk:
                try await acceptInit(chunk, packet: packet)
            case .initAck:
                try await acceptInitAck(chunk, packet: packet)
            case .cookieEcho:
                try await acceptCookieEcho(packet: packet)
            case .cookieAck:
                try acceptCookieAck(packet: packet)
            case .data:
                try await acceptData(chunk, packet: packet)
            case .sack:
                _ = try SCTPSACKChunk(chunk: chunk)
            default:
                continue
            }
        }
        resumeWaitersIfReady()
    }

    private func startReceivePumpIfNeeded() {
        guard receivePumpTask == nil else {
            return
        }

        let dtlsTransport = self.dtlsTransport
        receivePumpTask = Task { [weak self, dtlsTransport] in
            do {
                while !Task.isCancelled {
                    let data = try await dtlsTransport.receive()
                    try await self?.processPumpedInbound(data)
                }
            } catch {
                await self?.failReceivePump(error)
            }
        }
    }

    private func processPumpedInbound(_ data: Data) async throws {
        try await processInbound(data)
    }

    private func waitForAssociation() async throws {
        if state == .established {
            return
        }
        if let receivePumpError {
            throw receivePumpError
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            associationWaiters.append(continuation)
            resumeWaitersIfReady()
        }
    }

    private func waitForPacket() async throws -> SCTPDataChannelPacket {
        if !pendingReceivedPackets.isEmpty {
            return pendingReceivedPackets.removeFirst()
        }
        if let receivePumpError {
            throw receivePumpError
        }

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SCTPDataChannelPacket, any Error>) in
            packetWaiters.append(continuation)
            resumeWaitersIfReady()
        }
    }

    private func resumeWaitersIfReady() {
        if state == .established {
            let waiters = associationWaiters
            associationWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }

        while !pendingReceivedPackets.isEmpty, !packetWaiters.isEmpty {
            let packet = pendingReceivedPackets.removeFirst()
            let waiter = packetWaiters.removeFirst()
            waiter.resume(returning: packet)
        }
    }

    private func failReceivePump(_ error: any Error) {
        receivePumpError = error
        let associationWaiters = associationWaiters
        let packetWaiters = packetWaiters
        self.associationWaiters.removeAll()
        self.packetWaiters.removeAll()
        for waiter in associationWaiters {
            waiter.resume(throwing: error)
        }
        for waiter in packetWaiters {
            waiter.resume(throwing: error)
        }
    }

    private func acceptInit(_ chunk: SCTPChunk, packet: SCTPPacket) async throws {
        try validateVerificationTag(packet.verificationTag, expected: 0)
        let initChunk = try SCTPInitChunk(chunk: chunk)
        peerVerificationTag = initChunk.initiateTag
        expectedPeerTSN = initChunk.initialTSN

        let initAck = SCTPInitChunk(
            type: .initAck,
            initiateTag: configuration.localInitiateTag,
            advertisedReceiverWindowCredit: configuration.advertisedReceiverWindowCredit,
            outboundStreams: configuration.outboundStreams,
            inboundStreams: configuration.inboundStreams,
            initialTSN: configuration.initialTSN,
            parameters: [
                SCTPParameter(type: SCTPParameterType.stateCookie, value: configuration.stateCookie),
            ]
        )
        try await sendPacket(
            verificationTag: initChunk.initiateTag,
            chunks: [.initChunk(initAck)]
        )
        if state == .new {
            state = .initAckSent
        }
    }

    private func acceptInitAck(_ chunk: SCTPChunk, packet: SCTPPacket) async throws {
        try validateVerificationTag(packet.verificationTag, expected: configuration.localInitiateTag)
        let initAck = try SCTPInitChunk(chunk: chunk)
        peerVerificationTag = initAck.initiateTag
        expectedPeerTSN = initAck.initialTSN
        guard let stateCookie = initAck.parameters.first(where: { $0.type == SCTPParameterType.stateCookie })?.value else {
            throw SCTPDataChannelError.missingSCTPStateCookie
        }

        try await sendPacket(
            verificationTag: initAck.initiateTag,
            chunks: [.cookieEcho(stateCookie)]
        )
        state = .cookieEchoSent
    }

    private func acceptCookieEcho(packet: SCTPPacket) async throws {
        try validateVerificationTag(packet.verificationTag, expected: configuration.localInitiateTag)
        try await sendPacket(
            verificationTag: try requirePeerVerificationTag(),
            chunks: [.cookieAck]
        )
        state = .established
    }

    private func acceptCookieAck(packet: SCTPPacket) throws {
        try validateVerificationTag(packet.verificationTag, expected: configuration.localInitiateTag)
        state = .established
    }

    private func acceptData(_ chunk: SCTPChunk, packet: SCTPPacket) async throws {
        try validateVerificationTag(packet.verificationTag, expected: configuration.localInitiateTag)
        let dataChunk = try SCTPDataChunk(chunk: chunk)
        expectedPeerTSN = dataChunk.tsn &+ 1

        try await sendPacket(
            verificationTag: try requirePeerVerificationTag(),
            chunks: [
                .sack(SCTPSACKChunk(
                    cumulativeTSNAck: dataChunk.tsn,
                    advertisedReceiverWindowCredit: configuration.advertisedReceiverWindowCredit
                )),
            ]
        )
        if let packet = try fragmentReassembler.append(dataChunk) {
            pendingReceivedPackets.append(packet)
        }
    }

    private func dataChunks(
        for packet: SCTPDataChannelPacket,
        firstTSN: UInt32,
        streamSequenceNumber: UInt16
    ) throws -> [SCTPDataChunk] {
        guard let maxDataChunkPayloadSize = configuration.maxDataChunkPayloadSize,
              packet.payload.count > maxDataChunkPayloadSize else {
            return [
                packet.dataChunk(
                    tsn: firstTSN,
                    streamSequenceNumber: streamSequenceNumber,
                    unordered: false
                ),
            ]
        }
        guard maxDataChunkPayloadSize > 0 else {
            throw SCTPDataChannelError.invalidSCTPDataChunkFragmentPayloadSize(maxDataChunkPayloadSize)
        }

        var chunks: [SCTPDataChunk] = []
        var offset = 0
        while offset < packet.payload.count {
            let end = min(packet.payload.count, offset + maxDataChunkPayloadSize)
            let chunkIndex = chunks.count
            chunks.append(SCTPDataChunk(
                unordered: false,
                beginning: offset == 0,
                ending: end == packet.payload.count,
                tsn: firstTSN &+ UInt32(chunkIndex),
                streamID: packet.streamID,
                streamSequenceNumber: streamSequenceNumber,
                payloadProtocolIdentifier: packet.ppid.rawValue,
                userData: Data(packet.payload[offset..<end])
            ))
            offset = end
        }

        return chunks
    }

    private func sendPacket(
        verificationTag: UInt32,
        chunks: [SCTPChunk]
    ) async throws {
        let packet = SCTPPacket(
            sourcePort: configuration.localPort,
            destinationPort: configuration.remotePort,
            verificationTag: verificationTag,
            chunks: chunks
        )
        try await dtlsTransport.send(packet.encoded())
    }

    private func nextStreamSequenceNumber(for streamID: UInt16) -> UInt16 {
        let sequenceNumber = nextStreamSequenceNumbers[streamID] ?? 0
        nextStreamSequenceNumbers[streamID] = sequenceNumber &+ 1
        return sequenceNumber
    }

    private func requirePeerVerificationTag() throws -> UInt32 {
        guard let peerVerificationTag else {
            throw SCTPDataChannelError.missingSCTPPeerVerificationTag
        }
        return peerVerificationTag
    }

    private func validateVerificationTag(_ actual: UInt32, expected: UInt32) throws {
        guard actual == expected else {
            throw SCTPDataChannelError.invalidSCTPVerificationTag(
                expected: expected,
                actual: actual
            )
        }
    }
}

private enum SCTPCRC32C {
    private static let table: [UInt32] = {
        let polynomial: UInt32 = 0x82F63B78
        return (0..<256).map { index in
            var crc = UInt32(index)
            for _ in 0..<8 {
                crc = (crc & 1) == 1 ? (crc >> 1) ^ polynomial : crc >> 1
            }
            return crc
        }
    }()

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffff_ffff
        for byte in data {
            let index = Int((crc ^ UInt32(byte)) & 0xff)
            crc = (crc >> 8) ^ table[index]
        }
        return (~crc).byteSwapped
    }
}

private extension Data {
    mutating func appendPadding(toMultipleOfFourFrom length: Int) {
        let paddingByteCount = (4 - (length % 4)) % 4
        guard paddingByteCount > 0 else { return }
        append(Data(repeating: 0, count: paddingByteCount))
    }

    func zeroingSCTPChecksum() -> Data {
        guard count >= 12 else { return self }

        var data = self
        data.replaceSubrange(8..<12, with: Data(repeating: 0, count: 4))
        return data
    }

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
