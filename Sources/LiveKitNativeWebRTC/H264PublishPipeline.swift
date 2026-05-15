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
    private var compressionSession: VTCompressionSession?

    package init(settings: H264EncoderSettings) {
        self.settings = settings
    }

    package var isConfigured: Bool {
        compressionSession != nil
    }

    package func configure() throws {
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
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &session
        )

        guard status == noErr, let session else {
            throw H264VideoToolboxEncoderError.configurationFailed(status)
        }

        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: settings.profileLevel.videoToolboxValue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: settings.bitrate as CFNumber)
        VTSessionSetProperty(
            session,
            key: kVTCompressionPropertyKey_ExpectedFrameRate,
            value: settings.framesPerSecond as CFNumber
        )
        VTCompressionSessionPrepareToEncodeFrames(session)
        compressionSession = session
    }

    package func invalidate() {
        guard let compressionSession else {
            return
        }

        VTCompressionSessionInvalidate(compressionSession)
        self.compressionSession = nil
    }
}

package enum H264VideoToolboxEncoderError: Error, Equatable, Sendable {
    case configurationFailed(OSStatus)
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
