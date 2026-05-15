import CoreMedia
import Foundation

package struct H264AccessUnit: Equatable, Sendable {
    package var timestamp: UInt32
    package var nalUnits: [Data]
    package var annexBData: Data

    package init(timestamp: UInt32, nalUnits: [Data]) {
        self.timestamp = timestamp
        self.nalUnits = nalUnits
        self.annexBData = H264AnnexBWriter.write(nalUnits: nalUnits)
    }
}

package enum H264AnnexBWriter {
    package static func write(nalUnits: [Data]) -> Data {
        var data = Data()

        for nalUnit in nalUnits where !nalUnit.isEmpty {
            data.append(contentsOf: [0x00, 0x00, 0x00, 0x01])
            data.append(nalUnit)
        }

        return data
    }
}

package final class H264SubscribePipeline: @unchecked Sendable {
    private let depacketizer: H264RTPDepacketizer
    private var pendingNALUnits: [Data] = []
    private var pendingTimestamp: UInt32?

    package init(depacketizer: H264RTPDepacketizer = H264RTPDepacketizer()) {
        self.depacketizer = depacketizer
    }

    package func append(_ packet: RTPPacket) throws -> [H264AccessUnit] {
        let nalUnits = try depacketizer.append(packet)
        guard !nalUnits.isEmpty else {
            return []
        }

        if pendingTimestamp == nil {
            pendingTimestamp = packet.timestamp
        }

        if pendingTimestamp != packet.timestamp, !pendingNALUnits.isEmpty {
            let flushed = flush()
            pendingTimestamp = packet.timestamp
            pendingNALUnits.append(contentsOf: nalUnits)
            return flushed
        }

        pendingNALUnits.append(contentsOf: nalUnits)

        guard packet.marker else {
            return []
        }

        return flush()
    }

    package func flush() -> [H264AccessUnit] {
        guard let timestamp = pendingTimestamp, !pendingNALUnits.isEmpty else {
            pendingTimestamp = nil
            pendingNALUnits.removeAll()
            return []
        }

        let accessUnit = H264AccessUnit(timestamp: timestamp, nalUnits: pendingNALUnits)
        pendingTimestamp = nil
        pendingNALUnits.removeAll()
        return [accessUnit]
    }
}

package final class H264VideoToolboxSubscribeDecoder: @unchecked Sendable {
    private var formatDescription: CMVideoFormatDescription?
    private var didReceiveParameterSets = false

    package init() {}

    package func configureIfPossible(from accessUnit: H264AccessUnit) {
        guard let parameterSets = H264ParameterSets(accessUnit: accessUnit) else {
            return
        }
        didReceiveParameterSets = true

        let sps = [UInt8](parameterSets.sps)
        let pps = [UInt8](parameterSets.pps)
        sps.withUnsafeBufferPointer { spsPointer in
            pps.withUnsafeBufferPointer { ppsPointer in
                guard
                    let spsBaseAddress = spsPointer.baseAddress,
                    let ppsBaseAddress = ppsPointer.baseAddress
                else {
                    return
                }

                let parameterSetPointers: [UnsafePointer<UInt8>] = [spsBaseAddress, ppsBaseAddress]
                let parameterSetSizes = [spsPointer.count, ppsPointer.count]

                parameterSetPointers.withUnsafeBufferPointer { pointerBuffer in
                    parameterSetSizes.withUnsafeBufferPointer { sizeBuffer in
                        guard
                            let pointerBaseAddress = pointerBuffer.baseAddress,
                            let sizeBaseAddress = sizeBuffer.baseAddress
                        else {
                            return
                        }

                        var description: CMFormatDescription?
                        CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBaseAddress,
                            parameterSetSizes: sizeBaseAddress,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &description
                        )
                        formatDescription = description
                    }
                }
            }
        }
    }

    package var isConfigured: Bool {
        formatDescription != nil
    }

    package var hasParameterSets: Bool {
        didReceiveParameterSets
    }
}

private struct H264ParameterSets {
    var sps: Data
    var pps: Data

    init?(accessUnit: H264AccessUnit) {
        var sps: Data?
        var pps: Data?

        for nalUnit in accessUnit.nalUnits {
            guard let firstByte = nalUnit.first else {
                continue
            }

            switch firstByte & 0x1F {
            case H264NALUnitType.sequenceParameterSet.rawValue:
                sps = nalUnit
            case H264NALUnitType.pictureParameterSet.rawValue:
                pps = nalUnit
            default:
                continue
            }
        }

        guard let sps, let pps else {
            return nil
        }

        self.sps = sps
        self.pps = pps
    }
}
