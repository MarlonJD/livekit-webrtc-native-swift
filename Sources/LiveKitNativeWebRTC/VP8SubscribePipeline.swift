import Foundation

package struct VP8FrameSize: Equatable, Sendable {
    package var width: Int
    package var height: Int

    package init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

package struct VP8FrameHeader: Equatable, Sendable {
    package var isKeyFrame: Bool
    package var version: UInt8
    package var showFrame: Bool
    package var firstPartitionLength: Int
    package var size: VP8FrameSize?

    package init(frameData: Data) throws {
        guard frameData.count >= 3 else {
            throw VP8RTPError.invalidFrameHeader
        }

        let firstByte = frameData.byte(at: 0)
        let frameTag = UInt32(firstByte) |
            UInt32(frameData.byte(at: 1)) << 8 |
            UInt32(frameData.byte(at: 2)) << 16

        self.isKeyFrame = (firstByte & 0x01) == 0
        self.version = (firstByte >> 1) & 0x07
        self.showFrame = (firstByte & 0x10) != 0
        self.firstPartitionLength = Int(frameTag >> 5)
        self.size = nil

        if isKeyFrame {
            guard frameData.count >= 10 else {
                throw VP8RTPError.invalidFrameHeader
            }

            guard
                frameData.byte(at: 3) == 0x9D,
                frameData.byte(at: 4) == 0x01,
                frameData.byte(at: 5) == 0x2A
            else {
                throw VP8RTPError.invalidKeyFrameStartCode
            }

            let rawWidth = UInt16(frameData.byte(at: 6)) | UInt16(frameData.byte(at: 7)) << 8
            let rawHeight = UInt16(frameData.byte(at: 8)) | UInt16(frameData.byte(at: 9)) << 8
            self.size = VP8FrameSize(width: Int(rawWidth & 0x3FFF), height: Int(rawHeight & 0x3FFF))
        }
    }
}

package struct VP8Frame: Equatable, Sendable {
    package var timestamp: UInt32
    package var payload: Data
    package var header: VP8FrameHeader
    package var pictureID: UInt16?

    package init(timestamp: UInt32, payload: Data, pictureID: UInt16? = nil) throws {
        self.timestamp = timestamp
        self.payload = payload
        self.header = try VP8FrameHeader(frameData: payload)
        self.pictureID = pictureID
    }

    package var isKeyFrame: Bool {
        header.isKeyFrame
    }

    package var size: VP8FrameSize? {
        header.size
    }
}

package struct VP8DecodedFrameMetadata: Equatable, Sendable {
    package var timestamp: UInt32
    package var pictureID: UInt16?
    package var isKeyFrame: Bool
    package var size: VP8FrameSize?

    package init(frame: VP8Frame) {
        self.timestamp = frame.timestamp
        self.pictureID = frame.pictureID
        self.isKeyFrame = frame.isKeyFrame
        self.size = frame.size
    }
}

package final class VP8DecodeOnlyFrameInspector: @unchecked Sendable {
    package private(set) var lastMetadata: VP8DecodedFrameMetadata?
    package private(set) var lastKeyFrameSize: VP8FrameSize?

    package init() {}

    @discardableResult
    package func inspect(_ frame: VP8Frame) -> VP8DecodedFrameMetadata {
        let metadata = VP8DecodedFrameMetadata(frame: frame)
        lastMetadata = metadata

        if frame.isKeyFrame {
            lastKeyFrameSize = frame.size
        }

        return metadata
    }
}

package final class VP8SubscribePipeline: @unchecked Sendable {
    package let expectedPayloadType: UInt8
    private let depacketizer: VP8RTPDepacketizer
    private var pendingPayload = Data()
    private var pendingTimestamp: UInt32?
    private var pendingPictureID: UInt16?
    private var expectedSequenceNumber: UInt16?
    package private(set) var droppedPacketCount: Int = 0

    package init(expectedPayloadType: UInt8 = 96, depacketizer: VP8RTPDepacketizer = VP8RTPDepacketizer()) {
        self.expectedPayloadType = expectedPayloadType
        self.depacketizer = depacketizer
    }

    package func append(_ packet: RTPPacket) throws -> [VP8Frame] {
        guard packet.payloadType == expectedPayloadType else {
            throw VP8RTPError.payloadTypeMismatch(expected: expectedPayloadType, actual: packet.payloadType)
        }

        let fragment = try depacketizer.depacketize(packet)
        let isFrameStart = fragment.descriptor.isStartOfPartition && fragment.descriptor.partitionIndex == 0

        if isFrameStart {
            startNewFrame(with: fragment)
        } else {
            guard pendingTimestamp != nil else {
                throw VP8RTPError.missingFrameStart
            }

            try validateContinuation(fragment)
            pendingPayload.append(fragment.payload)
        }

        guard fragment.marker else {
            return []
        }

        return try flush()
    }

    package func flush() throws -> [VP8Frame] {
        guard let timestamp = pendingTimestamp, !pendingPayload.isEmpty else {
            resetFrameState()
            return []
        }

        let frame = try VP8Frame(timestamp: timestamp, payload: pendingPayload, pictureID: pendingPictureID)
        resetFrameState()
        return [frame]
    }

    private func startNewFrame(with fragment: VP8FrameFragment) {
        pendingPayload = fragment.payload
        pendingTimestamp = fragment.timestamp
        pendingPictureID = fragment.descriptor.pictureID
        expectedSequenceNumber = fragment.sequenceNumber &+ 1
    }

    private func validateContinuation(_ fragment: VP8FrameFragment) throws {
        if let pendingTimestamp, pendingTimestamp != fragment.timestamp {
            resetFrameState()
            throw VP8RTPError.missingFrameStart
        }

        if let expectedSequenceNumber, expectedSequenceNumber != fragment.sequenceNumber {
            let actual = fragment.sequenceNumber
            droppedPacketCount += Int(actual &- expectedSequenceNumber)
            resetFrameState()
            throw VP8RTPError.sequenceNumberGap(expected: expectedSequenceNumber, actual: actual)
        }

        expectedSequenceNumber = fragment.sequenceNumber &+ 1
    }

    private func resetFrameState() {
        pendingPayload.removeAll()
        pendingTimestamp = nil
        pendingPictureID = nil
        expectedSequenceNumber = nil
    }
}

private extension Data {
    func byte(at offset: Int) -> UInt8 {
        self[index(startIndex, offsetBy: offset)]
    }
}
