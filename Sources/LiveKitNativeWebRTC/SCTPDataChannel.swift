import Foundation

package enum SCTPDataChannelError: Error, Equatable, Sendable {
    case truncatedControlMessage
    case invalidControlMessageType(UInt8)
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
