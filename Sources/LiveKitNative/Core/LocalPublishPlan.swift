import Foundation
import LiveKitNativeProtocol
import LiveKitNativeWebRTC

struct LocalVideoPublishPlan: Equatable, Sendable {
    var cid: String
    var name: String
    var source: TrackSource
    var width: UInt32
    var height: UInt32
    var framesPerSecond: UInt32
    var simulcast: Bool
    var codec: RTPCodec
    var ssrc: UInt32
    var payloadType: UInt8
    var nativeCameraSource: NativeCameraVideoSource?

    init(
        track: LocalVideoTrack,
        options: TrackPublishOptions = .init(),
        ssrc: UInt32 = UInt32.random(in: 1 ... UInt32.max),
        payloadType: UInt8 = 102
    ) {
        let captureOptions = track.cameraCaptureOptions ?? CameraCaptureOptions()
        self.cid = track.id
        self.name = options.name ?? track.name
        self.source = options.source ?? track.source
        self.width = UInt32(max(0, captureOptions.width))
        self.height = UInt32(max(0, captureOptions.height))
        self.framesPerSecond = UInt32(max(0, captureOptions.framesPerSecond))
        self.simulcast = options.simulcast
        self.codec = .h264
        self.ssrc = ssrc
        self.payloadType = payloadType
        self.nativeCameraSource = track.nativeCameraSource
    }

    static func == (lhs: LocalVideoPublishPlan, rhs: LocalVideoPublishPlan) -> Bool {
        lhs.cid == rhs.cid &&
            lhs.name == rhs.name &&
            lhs.source == rhs.source &&
            lhs.width == rhs.width &&
            lhs.height == rhs.height &&
            lhs.framesPerSecond == rhs.framesPerSecond &&
            lhs.simulcast == rhs.simulcast &&
            lhs.codec == rhs.codec &&
            lhs.ssrc == rhs.ssrc &&
            lhs.payloadType == rhs.payloadType
    }

    var encoderSettings: H264EncoderSettings {
        H264EncoderSettings(
            width: Int32(width),
            height: Int32(height),
            framesPerSecond: Int32(framesPerSecond),
            bitrate: recommendedBitrate
        )
    }

    var packetizer: H264PublishRTPPacketizer {
        H264PublishRTPPacketizer(payloadType: payloadType, ssrc: ssrc)
    }

    var publisherOfferTrack: PublisherSDPOfferTrack {
        PublisherSDPOfferTrack(
            trackID: cid,
            kind: .video,
            codec: codec,
            payloadType: payloadType,
            clockRate: 90_000,
            ssrc: ssrc
        )
    }

    var addTrackRequest: Livekit_AddTrackRequest {
        var request = Livekit_AddTrackRequest()
        request.cid = cid
        request.name = name
        request.type = .video
        request.width = width
        request.height = height
        request.source = source.protocolTrackSource
        request.layers = videoLayers
        request.simulcastCodecs = [simulcastCodec]
        return request
    }

    private var recommendedBitrate: Int {
        switch max(width, height) {
        case 0..<721:
            1_500_000
        case 721..<1_081:
            2_500_000
        default:
            4_000_000
        }
    }

    private var videoLayers: [Livekit_VideoLayer] {
        var layer = Livekit_VideoLayer()
        layer.width = width
        layer.height = height
        layer.bitrate = UInt32(recommendedBitrate)
        layer.ssrc = ssrc
        return [layer]
    }

    private var simulcastCodec: Livekit_SimulcastCodec {
        var simulcastCodec = Livekit_SimulcastCodec()
        simulcastCodec.codec = "video/H264"
        simulcastCodec.cid = cid
        simulcastCodec.layers = videoLayers
        return simulcastCodec
    }
}

struct LocalAudioPublishPlan: Equatable, Sendable {
    var cid: String
    var name: String
    var source: TrackSource
    var sampleRate: Int
    var channelCount: Int
    var frameDurationMilliseconds: Int
    var codec: RTPCodec
    var ssrc: UInt32
    var payloadType: UInt8
    var nativeMicrophoneSource: NativeMicrophoneAudioSource?

    init(
        track: LocalAudioTrack,
        options: TrackPublishOptions = .init(),
        ssrc: UInt32 = UInt32.random(in: 1 ... UInt32.max),
        payloadType: UInt8 = 111
    ) {
        let captureOptions = track.audioCaptureOptions ?? AudioCaptureOptions()
        self.cid = track.id
        self.name = options.name ?? track.name
        self.source = options.source ?? track.source
        self.sampleRate = max(1, captureOptions.sampleRate)
        self.channelCount = max(1, captureOptions.channelCount)
        self.frameDurationMilliseconds = max(1, captureOptions.frameDurationMilliseconds)
        self.codec = .opus
        self.ssrc = ssrc
        self.payloadType = payloadType
        self.nativeMicrophoneSource = track.nativeMicrophoneSource
    }

    static func == (lhs: LocalAudioPublishPlan, rhs: LocalAudioPublishPlan) -> Bool {
        lhs.cid == rhs.cid &&
            lhs.name == rhs.name &&
            lhs.source == rhs.source &&
            lhs.sampleRate == rhs.sampleRate &&
            lhs.channelCount == rhs.channelCount &&
            lhs.frameDurationMilliseconds == rhs.frameDurationMilliseconds &&
            lhs.codec == rhs.codec &&
            lhs.ssrc == rhs.ssrc &&
            lhs.payloadType == rhs.payloadType
    }

    var packetizer: OpusRTPPacketizer {
        OpusRTPPacketizer(payloadType: payloadType, ssrc: ssrc)
    }

    var publisherOfferTrack: PublisherSDPOfferTrack {
        PublisherSDPOfferTrack(
            trackID: cid,
            kind: .audio,
            codec: codec,
            payloadType: payloadType,
            clockRate: 48_000,
            channels: channelCount,
            ssrc: ssrc
        )
    }

    var addTrackRequest: Livekit_AddTrackRequest {
        var request = Livekit_AddTrackRequest()
        request.cid = cid
        request.name = name
        request.type = .audio
        request.source = source.protocolTrackSource
        request.stereo = channelCount > 1
        request.disableDtx = false
        request.disableRed = true
        return request
    }
}

extension TrackSource {
    var protocolTrackSource: Livekit_TrackSource {
        switch self {
        case .camera:
            .camera
        case .microphone:
            .microphone
        case .screenShare:
            .screenShare
        case .screenShareAudio:
            .screenShareAudio
        case .unknown:
            .unknown
        }
    }
}
