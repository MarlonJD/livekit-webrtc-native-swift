import Foundation

package enum VP8RTPError: Error, Equatable, Sendable {
    case emptyPayload
    case invalidPayloadDescriptor
    case missingFrameStart
    case sequenceNumberGap(expected: UInt16, actual: UInt16)
    case payloadTypeMismatch(expected: UInt8, actual: UInt8)
    case invalidFrameHeader
    case invalidKeyFrameStartCode
}

package struct VP8PayloadDescriptor: Equatable, Sendable {
    package var hasExtension: Bool
    package var isNonReferenceFrame: Bool
    package var isStartOfPartition: Bool
    package var partitionIndex: UInt8
    package var pictureID: UInt16?
    package var tl0PicIndex: UInt8?
    package var temporalLayerID: UInt8?
    package var layerSync: Bool?
    package var keyIndex: UInt8?
    package var headerLength: Int

    package init(payload: Data) throws {
        guard let firstByte = payload.first else {
            throw VP8RTPError.emptyPayload
        }

        var offset = 1
        self.hasExtension = (firstByte & 0x80) != 0
        self.isNonReferenceFrame = (firstByte & 0x20) != 0
        self.isStartOfPartition = (firstByte & 0x10) != 0
        self.partitionIndex = firstByte & 0x0F
        self.pictureID = nil
        self.tl0PicIndex = nil
        self.temporalLayerID = nil
        self.layerSync = nil
        self.keyIndex = nil

        if hasExtension {
            guard offset < payload.count else {
                throw VP8RTPError.invalidPayloadDescriptor
            }

            let extensionByte = payload.byte(at: offset)
            offset += 1

            let hasPictureID = (extensionByte & 0x80) != 0
            let hasTL0PicIndex = (extensionByte & 0x40) != 0
            let hasTemporalLayer = (extensionByte & 0x20) != 0
            let hasKeyIndex = (extensionByte & 0x10) != 0

            if hasPictureID {
                guard offset < payload.count else {
                    throw VP8RTPError.invalidPayloadDescriptor
                }

                let firstPictureIDByte = payload.byte(at: offset)
                offset += 1
                if (firstPictureIDByte & 0x80) != 0 {
                    guard offset < payload.count else {
                        throw VP8RTPError.invalidPayloadDescriptor
                    }

                    pictureID = UInt16(firstPictureIDByte & 0x7F) << 8 | UInt16(payload.byte(at: offset))
                    offset += 1
                } else {
                    pictureID = UInt16(firstPictureIDByte & 0x7F)
                }
            }

            if hasTL0PicIndex {
                guard offset < payload.count else {
                    throw VP8RTPError.invalidPayloadDescriptor
                }

                tl0PicIndex = payload.byte(at: offset)
                offset += 1
            }

            if hasTemporalLayer || hasKeyIndex {
                guard offset < payload.count else {
                    throw VP8RTPError.invalidPayloadDescriptor
                }

                let temporalAndKeyIndex = payload.byte(at: offset)
                offset += 1
                if hasTemporalLayer {
                    temporalLayerID = temporalAndKeyIndex >> 6
                    layerSync = (temporalAndKeyIndex & 0x20) != 0
                }
                if hasKeyIndex {
                    keyIndex = temporalAndKeyIndex & 0x1F
                }
            }
        }

        self.headerLength = offset
    }
}

package struct VP8FrameFragment: Equatable, Sendable {
    package var descriptor: VP8PayloadDescriptor
    package var payload: Data
    package var timestamp: UInt32
    package var sequenceNumber: UInt16
    package var marker: Bool
    package var ssrc: UInt32
}

package struct VP8RTPDepacketizer: Sendable {
    package init() {}

    package func depacketize(_ packet: RTPPacket) throws -> VP8FrameFragment {
        let descriptor = try VP8PayloadDescriptor(payload: packet.payload)
        guard descriptor.headerLength < packet.payload.count else {
            throw VP8RTPError.emptyPayload
        }

        let payloadStart = packet.payload.index(packet.payload.startIndex, offsetBy: descriptor.headerLength)
        return VP8FrameFragment(
            descriptor: descriptor,
            payload: Data(packet.payload[payloadStart..<packet.payload.endIndex]),
            timestamp: packet.timestamp,
            sequenceNumber: packet.sequenceNumber,
            marker: packet.marker,
            ssrc: packet.ssrc
        )
    }
}

private extension Data {
    func byte(at offset: Int) -> UInt8 {
        self[index(startIndex, offsetBy: offset)]
    }
}
