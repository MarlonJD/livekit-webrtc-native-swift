import AVFoundation
import CoreMedia
import Foundation
import VideoToolbox

package enum NativeCameraPosition: Equatable, Sendable {
    case front
    case back
    case unspecified

    var avFoundationPosition: AVCaptureDevice.Position {
        switch self {
        case .front:
            .front
        case .back:
            .back
        case .unspecified:
            .unspecified
        }
    }
}

package struct NativeCameraCaptureConfiguration: Equatable, Sendable {
    package var position: NativeCameraPosition
    package var width: Int
    package var height: Int
    package var framesPerSecond: Int

    package init(
        position: NativeCameraPosition = .front,
        width: Int = 1_280,
        height: Int = 720,
        framesPerSecond: Int = 30
    ) {
        self.position = position
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
    }
}

package protocol NativeCameraVideoFrameSink: AnyObject, Sendable {
    func cameraSource(_ source: NativeCameraVideoSource, didOutput sampleBuffer: CMSampleBuffer)
}

package final class NativeCameraVideoSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    package let configuration: NativeCameraCaptureConfiguration
    private let session = AVCaptureSession()
    private let outputQueue = DispatchQueue(label: "LiveKitNative.CameraVideoSource")
    private weak var frameSink: (any NativeCameraVideoFrameSink)?
    private var isConfigured = false

    package init(configuration: NativeCameraCaptureConfiguration) {
        self.configuration = configuration
        super.init()
    }

    package func setFrameSink(_ frameSink: (any NativeCameraVideoFrameSink)?) {
        self.frameSink = frameSink
    }

    package func start() throws {
        try configureSessionIfNeeded()
        session.startRunning()
    }

    package func stop() {
        session.stopRunning()
    }

    package func configureSessionIfNeeded() throws {
        guard !isConfigured else {
            return
        }

        guard let device = selectVideoDevice(position: configuration.position.avFoundationPosition) else {
            throw NativeCameraVideoSourceError.noCameraDevice
        }

        let input = try AVCaptureDeviceInput(device: device)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        output.setSampleBufferDelegate(self, queue: outputQueue)

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canAddInput(input) {
            session.addInput(input)
        }

        if session.canAddOutput(output) {
            session.addOutput(output)
        }

        configureFrameDuration(on: device)
        isConfigured = true
    }

    package func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        frameSink?.cameraSource(self, didOutput: sampleBuffer)
    }

    private func selectVideoDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: position
        )
        return discovery.devices.first ?? AVCaptureDevice.default(for: .video)
    }

    private func configureFrameDuration(on device: AVCaptureDevice) {
        let frameDuration = CMTime(value: 1, timescale: CMTimeScale(configuration.framesPerSecond))

        do {
            try device.lockForConfiguration()
            if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { range in
                range.minFrameRate <= Double(configuration.framesPerSecond) &&
                    Double(configuration.framesPerSecond) <= range.maxFrameRate
            }) {
                device.activeVideoMinFrameDuration = frameDuration
                device.activeVideoMaxFrameDuration = frameDuration
            }
            device.unlockForConfiguration()
        } catch {
            return
        }
    }
}

package enum NativeCameraVideoSourceError: Error, Equatable, Sendable {
    case noCameraDevice
}

package struct H264EncoderSettings: Equatable, Sendable {
    package var width: Int32
    package var height: Int32
    package var framesPerSecond: Int32
    package var bitrate: Int
    package var profileLevel: H264ProfileLevel

    package init(
        width: Int32 = 1_280,
        height: Int32 = 720,
        framesPerSecond: Int32 = 30,
        bitrate: Int = 1_500_000,
        profileLevel: H264ProfileLevel = .baselineAutoLevel
    ) {
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.bitrate = bitrate
        self.profileLevel = profileLevel
    }
}

package enum H264ProfileLevel: Equatable, Sendable {
    case baselineAutoLevel

    var videoToolboxValue: CFString {
        switch self {
        case .baselineAutoLevel:
            kVTProfileLevel_H264_Baseline_AutoLevel
        }
    }
}

package struct H264EncodedFrame: Equatable, Sendable {
    package var nalUnits: [Data]
    package var rtpTimestamp: UInt32
    package var isKeyFrame: Bool

    package init(nalUnits: [Data], rtpTimestamp: UInt32, isKeyFrame: Bool = false) {
        self.nalUnits = nalUnits
        self.rtpTimestamp = rtpTimestamp
        self.isKeyFrame = isKeyFrame
    }
}

package final class H264VideoToolboxEncoder: @unchecked Sendable {
    package let settings: H264EncoderSettings
    private let lock = NSLock()
    private var compressionSession: VTCompressionSession?
    private var outputHandler: (@Sendable (H264EncodedFrame) -> Void)?
    private var mutableUsesHardwareAcceleration: Bool?
    private var mutableLastEncodingError: (any Error)?
    private var mutableTargetBitrate: Int
    private var mutableTargetFramesPerSecond: Int32
    private var mutableAppliedQualityRecommendation: AdaptiveVideoQualityRecommendation?

    package init(settings: H264EncoderSettings) {
        self.settings = settings
        self.mutableTargetBitrate = settings.bitrate
        self.mutableTargetFramesPerSecond = settings.framesPerSecond
    }

    package var isConfigured: Bool {
        compressionSession != nil
    }

    package var usesHardwareAcceleration: Bool? {
        lock.withLock {
            mutableUsesHardwareAcceleration
        }
    }

    package var lastEncodingError: (any Error)? {
        lock.withLock {
            mutableLastEncodingError
        }
    }

    package var targetBitrate: Int {
        lock.withLock {
            mutableTargetBitrate
        }
    }

    package var targetFramesPerSecond: Int32 {
        lock.withLock {
            mutableTargetFramesPerSecond
        }
    }

    package var appliedQualityRecommendation: AdaptiveVideoQualityRecommendation? {
        lock.withLock {
            mutableAppliedQualityRecommendation
        }
    }

    package func configure(outputHandler: (@Sendable (H264EncodedFrame) -> Void)? = nil) throws {
        lock.withLock {
            self.outputHandler = outputHandler
            self.mutableLastEncodingError = nil
        }
        guard compressionSession == nil else {
            return
        }

        var session: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: settings.width,
            height: settings.height,
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: h264VideoToolboxEncoderOutputCallback,
            refcon: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()),
            compressionSessionOut: &session
        )

        guard status == noErr, let session else {
            throw H264VideoToolboxEncoderError.configurationFailed(status)
        }

        let target = lock.withLock {
            (bitrate: mutableTargetBitrate, framesPerSecond: mutableTargetFramesPerSecond)
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: settings.profileLevel.videoToolboxValue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: target.bitrate as CFNumber)
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
            value: max(1, Int(settings.framesPerSecond * 2)) as CFNumber
        )
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: target.framesPerSecond as CFNumber
        )
        VTCompressionSessionPrepareToEncodeFrames(session)
        compressionSession = session
        updateHardwareAccelerationState(session)
    }

    package func applyQualityRecommendation(_ recommendation: AdaptiveVideoQualityRecommendation) {
        let targetBitrate = max(1, recommendation.targetBitrateBps)
        let targetFramesPerSecond = Int32(max(1, recommendation.maxFramesPerSecond))
        let session = lock.withLock {
            mutableTargetBitrate = targetBitrate
            mutableTargetFramesPerSecond = targetFramesPerSecond
            mutableAppliedQualityRecommendation = recommendation
            return compressionSession
        }

        guard let session else {
            return
        }

        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_AverageBitRate,
            value: targetBitrate as CFNumber
        )
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: targetFramesPerSecond as CFNumber
        )
    }

    package func encode(_ sampleBuffer: CMSampleBuffer) throws {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw H264VideoToolboxEncoderError.sampleBufferMissingImageBuffer
        }

        try encode(
            pixelBuffer: imageBuffer,
            presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            duration: CMSampleBufferGetDuration(sampleBuffer)
        )
    }

    package func encode(
        pixelBuffer: CVImageBuffer,
        presentationTimeStamp: CMTime,
        duration: CMTime = .invalid
    ) throws {
        guard let compressionSession else {
            try configure()
            guard let compressionSession else {
                throw H264VideoToolboxEncoderError.encoderNotConfigured
            }

            return try encode(
                pixelBuffer: pixelBuffer,
                presentationTimeStamp: presentationTimeStamp,
                duration: duration,
                session: compressionSession
            )
        }

        try encode(
            pixelBuffer: pixelBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: duration,
            session: compressionSession
        )
    }

    package func completeFrames(until presentationTimeStamp: CMTime = .invalid) throws {
        guard let compressionSession else {
            return
        }

        let status = VTCompressionSessionCompleteFrames(
            compressionSession,
            untilPresentationTimeStamp: presentationTimeStamp
        )
        guard status == noErr else {
            throw H264VideoToolboxEncoderError.encodingFailed(status)
        }
    }

    package func invalidate() {
        guard let compressionSession else {
            return
        }

        VTCompressionSessionInvalidate(compressionSession)
        self.compressionSession = nil
        lock.withLock {
            outputHandler = nil
            mutableUsesHardwareAcceleration = nil
        }
    }

    private func encode(
        pixelBuffer: CVImageBuffer,
        presentationTimeStamp: CMTime,
        duration: CMTime,
        session: VTCompressionSession
    ) throws {
        let status = VTCompressionSessionEncodeFrame(
            session,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: duration,
            frameProperties: nil,
            sourceFrameRefcon: nil,
            infoFlagsOut: nil
        )
        guard status == noErr else {
            throw H264VideoToolboxEncoderError.encodingFailed(status)
        }
    }

    fileprivate func handleOutput(status: OSStatus, sampleBuffer: CMSampleBuffer?) {
        do {
            guard status == noErr else {
                throw H264VideoToolboxEncoderError.encodingFailed(status)
            }
            guard let sampleBuffer, CMSampleBufferDataIsReady(sampleBuffer) else {
                throw H264VideoToolboxEncoderError.encodedSampleBufferDataUnavailable
            }

            let frame = try H264EncodedFrame(sampleBuffer: sampleBuffer)
            let handler = lock.withLock {
                mutableLastEncodingError = nil
                return outputHandler
            }
            handler?(frame)
        } catch {
            lock.withLock {
                mutableLastEncodingError = error
            }
        }
    }

    private func updateHardwareAccelerationState(_ session: VTCompressionSession) {
        var property: CFTypeRef?
        let status = withUnsafeMutablePointer(to: &property) { propertyPointer in
            VTSessionCopyProperty(
                session,
                key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                allocator: kCFAllocatorDefault,
                valueOut: propertyPointer
            )
        }
        guard status == noErr else {
            return
        }

        let isHardwareAccelerated = (property as? Bool)
        lock.withLock {
            mutableUsesHardwareAcceleration = isHardwareAccelerated
        }
    }
}

package enum H264VideoToolboxEncoderError: Error, Equatable, Sendable {
    case configurationFailed(OSStatus)
    case encoderNotConfigured
    case encodingFailed(OSStatus)
    case sampleBufferMissingImageBuffer
    case encodedSampleBufferDataUnavailable
    case missingFormatDescription
    case invalidParameterSet(OSStatus)
    case invalidBlockBuffer(OSStatus)
    case invalidNALUnitLength
}

package final class H264CameraPublishPipeline: NativeCameraVideoFrameSink, @unchecked Sendable {
    package let source: NativeCameraVideoSource
    package let encoder: H264VideoToolboxEncoder
    package let backpressureController: VideoFrameBackpressureController
    private let sendFrame: @Sendable (H264EncodedFrame) async throws -> Void
    private let lock = NSLock()
    private var mutableIsRunning = false
    private var mutableLastError: (any Error)?

    package init(
        source: NativeCameraVideoSource,
        encoder: H264VideoToolboxEncoder,
        backpressureController: VideoFrameBackpressureController = VideoFrameBackpressureController(),
        sendFrame: @escaping @Sendable (H264EncodedFrame) async throws -> Void
    ) {
        self.source = source
        self.encoder = encoder
        self.backpressureController = backpressureController
        self.sendFrame = sendFrame
    }

    package var isRunning: Bool {
        lock.withLock {
            mutableIsRunning
        }
    }

    package var lastError: (any Error)? {
        lock.withLock {
            mutableLastError
        }
    }

    package var backpressureSnapshot: MediaFrameBackpressureSnapshot {
        backpressureController.snapshot
    }

    package var appliedQualityRecommendation: AdaptiveVideoQualityRecommendation? {
        encoder.appliedQualityRecommendation
    }

    package func applyQualityRecommendation(_ recommendation: AdaptiveVideoQualityRecommendation) {
        encoder.applyQualityRecommendation(recommendation)
    }

    package func start() throws {
        let shouldStart = lock.withLock {
            guard !mutableIsRunning else {
                return false
            }
            mutableIsRunning = true
            mutableLastError = nil
            return true
        }
        guard shouldStart else {
            return
        }

        do {
            try encoder.configure { [weak self] frame in
                self?.dispatch(frame)
            }
            source.setFrameSink(self)
            try source.start()
        } catch {
            lock.withLock {
                mutableIsRunning = false
                mutableLastError = error
            }
            source.setFrameSink(nil)
            throw error
        }
    }

    package func stop() {
        source.stop()
        source.setFrameSink(nil)
        encoder.invalidate()
        lock.withLock {
            mutableIsRunning = false
        }
    }

    package func cameraSource(
        _ source: NativeCameraVideoSource,
        didOutput sampleBuffer: CMSampleBuffer
    ) {
        do {
            try encoder.encode(sampleBuffer)
        } catch {
            lock.withLock {
                mutableLastError = error
            }
        }
    }

    private func dispatch(_ frame: H264EncodedFrame) {
        guard backpressureController.beginFrame(isKeyFrame: frame.isKeyFrame).shouldSend else {
            return
        }

        Task { [sendFrame, backpressureController] in
            defer {
                backpressureController.endFrame()
            }
            do {
                try await sendFrame(frame)
            } catch {
                self.lock.withLock {
                    self.mutableLastError = error
                }
            }
        }
    }
}

private let h264VideoToolboxEncoderOutputCallback: VTCompressionOutputCallback = {
    outputCallbackRefCon,
    _,
    status,
    _,
    sampleBuffer in
    guard let outputCallbackRefCon else {
        return
    }

    let encoder = Unmanaged<H264VideoToolboxEncoder>
        .fromOpaque(outputCallbackRefCon)
        .takeUnretainedValue()
    encoder.handleOutput(status: status, sampleBuffer: sampleBuffer)
}

private extension H264EncodedFrame {
    init(sampleBuffer: CMSampleBuffer) throws {
        let timestamp = Self.rtpTimestamp(for: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let isKeyFrame = Self.isKeyFrame(sampleBuffer)
        var nalUnits: [Data] = []

        if isKeyFrame {
            nalUnits.append(contentsOf: try Self.parameterSets(from: sampleBuffer))
        }
        nalUnits.append(contentsOf: try Self.sampleNALUnits(from: sampleBuffer))

        self.init(nalUnits: nalUnits, rtpTimestamp: timestamp, isKeyFrame: isKeyFrame)
    }

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

    static func isKeyFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[CFString: Any]]
        let isNotSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
        return !isNotSync
    }

    static func parameterSets(from sampleBuffer: CMSampleBuffer) throws -> [Data] {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            throw H264VideoToolboxEncoderError.missingFormatDescription
        }

        var parameterSetCount = 0
        var nalUnitHeaderLength: Int32 = 0
        var status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: nil,
            parameterSetSizeOut: nil,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength
        )
        guard status == noErr else {
            throw H264VideoToolboxEncoderError.invalidParameterSet(status)
        }

        var parameterSets: [Data] = []
        for index in 0..<parameterSetCount {
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                formatDescription,
                parameterSetIndex: index,
                parameterSetPointerOut: &pointer,
                parameterSetSizeOut: &size,
                parameterSetCountOut: nil,
                nalUnitHeaderLengthOut: nil
            )
            guard status == noErr else {
                throw H264VideoToolboxEncoderError.invalidParameterSet(status)
            }
            guard let pointer, size > 0 else {
                continue
            }

            parameterSets.append(Data(bytes: pointer, count: size))
        }

        return parameterSets
    }

    static func sampleNALUnits(from sampleBuffer: CMSampleBuffer) throws -> [Data] {
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            throw H264VideoToolboxEncoderError.encodedSampleBufferDataUnavailable
        }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )
        guard status == noErr else {
            throw H264VideoToolboxEncoderError.invalidBlockBuffer(status)
        }
        guard let dataPointer else {
            throw H264VideoToolboxEncoderError.encodedSampleBufferDataUnavailable
        }

        let bytes = UnsafeRawBufferPointer(start: dataPointer, count: totalLength)
        var offset = 0
        var nalUnits: [Data] = []

        while offset < totalLength {
            guard offset + 4 <= totalLength else {
                throw H264VideoToolboxEncoderError.invalidNALUnitLength
            }

            let nalLength = Int(bytes.networkUInt32(at: offset))
            offset += 4

            guard nalLength > 0, offset + nalLength <= totalLength else {
                throw H264VideoToolboxEncoderError.invalidNALUnitLength
            }

            nalUnits.append(Data(bytes: bytes.baseAddress!.advanced(by: offset), count: nalLength))
            offset += nalLength
        }

        return nalUnits
    }
}

private extension UnsafeRawBufferPointer {
    func networkUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset]) << 24 |
            UInt32(self[offset + 1]) << 16 |
            UInt32(self[offset + 2]) << 8 |
            UInt32(self[offset + 3])
    }
}

package final class H264PublishRTPPacketizer: @unchecked Sendable {
    private let packetizer: H264RTPPacketizer
    private let ssrc: UInt32
    private var nextSequenceNumber: UInt16

    package init(
        payloadType: UInt8 = 102,
        mtu: Int = 1_200,
        ssrc: UInt32,
        startingSequenceNumber: UInt16 = 0
    ) {
        self.packetizer = H264RTPPacketizer(payloadType: payloadType, mtu: mtu)
        self.ssrc = ssrc
        self.nextSequenceNumber = startingSequenceNumber
    }

    package func packetize(_ frame: H264EncodedFrame) throws -> [RTPPacket] {
        let packets = try packetizer.packetize(
            nalUnits: frame.nalUnits,
            timestamp: frame.rtpTimestamp,
            ssrc: ssrc,
            startingSequenceNumber: nextSequenceNumber
        )
        nextSequenceNumber &+= UInt16(packets.count)
        return packets
    }
}
