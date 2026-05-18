import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

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
    private let lock = NSLock()
    private var formatDescription: CMVideoFormatDescription?
    private var decompressionSession: VTDecompressionSession?
    private var didReceiveParameterSets = false
    private var mutableDecodedFrameCount = 0
    private var mutableLastDecodedFrame: H264DecodedFrame?
    private var mutableLastDecodingError: (any Error)?

    package init() {}

    deinit {
        invalidate()
    }

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
                        let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                            allocator: kCFAllocatorDefault,
                            parameterSetCount: 2,
                            parameterSetPointers: pointerBaseAddress,
                            parameterSetSizes: sizeBaseAddress,
                            nalUnitHeaderLength: 4,
                            formatDescriptionOut: &description
                        )
                        guard status == noErr, let description else {
                            return
                        }

                        invalidate()
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

    package var decodedFrameCount: Int {
        lock.withLock {
            mutableDecodedFrameCount
        }
    }

    package var lastDecodedFrame: H264DecodedFrame? {
        lock.withLock {
            mutableLastDecodedFrame
        }
    }

    package var lastDecodingError: (any Error)? {
        lock.withLock {
            mutableLastDecodingError
        }
    }

    @discardableResult
    package func decode(_ accessUnit: H264AccessUnit) throws -> [H264DecodedFrame] {
        configureIfPossible(from: accessUnit)
        guard let formatDescription else {
            throw H264VideoToolboxSubscribeDecoderError.missingFormatDescription
        }

        guard let sampleBuffer = try Self.sampleBuffer(
            from: accessUnit,
            formatDescription: formatDescription
        ) else {
            return []
        }

        let session = try decompressionSessionIfNeeded(formatDescription: formatDescription)
        let collector = H264DecodeOutputCollector()
        var infoFlags = VTDecodeInfoFlags(rawValue: 0)
        let status = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer: sampleBuffer,
            flags: [],
            frameRefcon: UnsafeMutableRawPointer(Unmanaged.passUnretained(collector).toOpaque()),
            infoFlagsOut: &infoFlags
        )
        guard status == noErr else {
            let error = H264VideoToolboxSubscribeDecoderError.decodingFailed(status)
            store(error)
            throw error
        }

        VTDecompressionSessionWaitForAsynchronousFrames(session)
        if let error = collector.error {
            store(error)
            throw error
        }

        lock.withLock {
            mutableDecodedFrameCount += collector.frames.count
            mutableLastDecodedFrame = collector.frames.last ?? mutableLastDecodedFrame
            mutableLastDecodingError = nil
        }
        return collector.frames
    }

    package func invalidate() {
        if let decompressionSession {
            VTDecompressionSessionInvalidate(decompressionSession)
        }
        decompressionSession = nil
    }

    package func reset() {
        invalidate()
        formatDescription = nil
        didReceiveParameterSets = false
        lock.withLock {
            mutableDecodedFrameCount = 0
            mutableLastDecodedFrame = nil
            mutableLastDecodingError = nil
        }
    }

    private func decompressionSessionIfNeeded(
        formatDescription: CMVideoFormatDescription
    ) throws -> VTDecompressionSession {
        if let decompressionSession {
            return decompressionSession
        }

        let imageBufferAttributes = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ] as CFDictionary
        var callbackRecord = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: h264VideoToolboxSubscribeDecoderOutputCallback,
            decompressionOutputRefCon: nil
        )
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            formatDescription: formatDescription,
            decoderSpecification: nil,
            imageBufferAttributes: imageBufferAttributes,
            outputCallback: &callbackRecord,
            decompressionSessionOut: &session
        )
        guard status == noErr, let session else {
            let error = H264VideoToolboxSubscribeDecoderError.decompressionSessionCreationFailed(status)
            store(error)
            throw error
        }

        decompressionSession = session
        return session
    }

    private func store(_ error: any Error) {
        lock.withLock {
            mutableLastDecodingError = error
        }
    }

    private static func sampleBuffer(
        from accessUnit: H264AccessUnit,
        formatDescription: CMVideoFormatDescription
    ) throws -> CMSampleBuffer? {
        let decodableNALUnits = accessUnit.nalUnits.filter { nalUnit in
            guard let first = nalUnit.first else {
                return false
            }

            switch first & 0x1F {
            case H264NALUnitType.sequenceParameterSet.rawValue,
                 H264NALUnitType.pictureParameterSet.rawValue:
                return false
            default:
                return true
            }
        }
        guard !decodableNALUnits.isEmpty else {
            return nil
        }

        var sampleData = Data()
        for nalUnit in decodableNALUnits {
            guard nalUnit.count <= Int(UInt32.max) else {
                throw H264VideoToolboxSubscribeDecoderError.invalidNALUnitLength
            }

            sampleData.appendH264NetworkUInt32(UInt32(nalUnit.count))
            sampleData.append(nalUnit)
        }

        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: sampleData.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: sampleData.count,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr, let blockBuffer else {
            throw H264VideoToolboxSubscribeDecoderError.blockBufferCreationFailed(status)
        }

        status = sampleData.withUnsafeBytes { rawBytes in
            guard let baseAddress = rawBytes.baseAddress else {
                return noErr
            }

            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: sampleData.count
            )
        }
        guard status == noErr else {
            throw H264VideoToolboxSubscribeDecoderError.blockBufferCreationFailed(status)
        }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: Int64(accessUnit.timestamp), timescale: 90_000),
            decodeTimeStamp: .invalid
        )
        var sampleSize = sampleData.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else {
            throw H264VideoToolboxSubscribeDecoderError.sampleBufferCreationFailed(status)
        }

        return sampleBuffer
    }
}

package struct H264DecodedFrame: @unchecked Sendable {
    package var timestamp: UInt32
    package var presentationTimeStamp: CMTime
    package var duration: CMTime
    package var pixelBuffer: CVPixelBuffer

    package init(
        timestamp: UInt32,
        presentationTimeStamp: CMTime,
        duration: CMTime,
        pixelBuffer: CVPixelBuffer
    ) {
        self.timestamp = timestamp
        self.presentationTimeStamp = presentationTimeStamp
        self.duration = duration
        self.pixelBuffer = pixelBuffer
    }
}

package enum H264VideoToolboxSubscribeDecoderError: Error, Equatable, Sendable {
    case missingFormatDescription
    case invalidNALUnitLength
    case blockBufferCreationFailed(OSStatus)
    case sampleBufferCreationFailed(OSStatus)
    case decompressionSessionCreationFailed(OSStatus)
    case decodingFailed(OSStatus)
    case decodedPixelBufferUnavailable(OSStatus)
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

private final class H264DecodeOutputCollector {
    var frames: [H264DecodedFrame] = []
    var error: H264VideoToolboxSubscribeDecoderError?

    func append(
        status: OSStatus,
        imageBuffer: CVImageBuffer?,
        presentationTimeStamp: CMTime,
        duration: CMTime
    ) {
        guard status == noErr else {
            error = .decodingFailed(status)
            return
        }
        guard let imageBuffer else {
            error = .decodedPixelBufferUnavailable(status)
            return
        }

        frames.append(
            H264DecodedFrame(
                timestamp: H264DecodedFrame.rtpTimestamp(for: presentationTimeStamp),
                presentationTimeStamp: presentationTimeStamp,
                duration: duration,
                pixelBuffer: imageBuffer
            )
        )
    }
}

private let h264VideoToolboxSubscribeDecoderOutputCallback: VTDecompressionOutputCallback = {
    _,
    sourceFrameRefCon,
    status,
    _,
    imageBuffer,
    presentationTimeStamp,
    duration in
    guard let sourceFrameRefCon else {
        return
    }

    let collector = Unmanaged<H264DecodeOutputCollector>
        .fromOpaque(sourceFrameRefCon)
        .takeUnretainedValue()
    collector.append(
        status: status,
        imageBuffer: imageBuffer,
        presentationTimeStamp: presentationTimeStamp,
        duration: duration
    )
}

private extension H264DecodedFrame {
    static func rtpTimestamp(for presentationTimeStamp: CMTime) -> UInt32 {
        guard presentationTimeStamp.isValid, !presentationTimeStamp.isIndefinite else {
            return 0
        }

        let seconds = CMTimeGetSeconds(presentationTimeStamp)
        guard seconds.isFinite, seconds >= 0 else {
            return 0
        }

        return UInt32(seconds * 90_000) &+ 0
    }
}

private extension Data {
    mutating func appendH264NetworkUInt32(_ value: UInt32) {
        append(UInt8((value >> 24) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8(value & 0xFF))
    }
}
