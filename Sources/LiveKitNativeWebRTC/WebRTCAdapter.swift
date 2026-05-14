import AVFoundation
import AudioToolbox
import CoreMedia
import CryptoKit
import Foundation
import Network
import Security
import VideoToolbox

package enum PeerConnectionRole: String, Equatable, Sendable {
    case subscriber
    case publisher
}

package enum RTPMediaKind: String, Equatable, Sendable {
    case audio
    case video
    case application
}

package enum RTPCodec: String, CaseIterable, Equatable, Sendable {
    case h264 = "H264"
    case vp8 = "VP8"
    case opus = "opus"
    case webRTCDataChannel = "webrtc-datachannel"
}

package struct ICEServer: Equatable, Sendable {
    package var urls: [String]
    package var username: String?
    package var credential: String?

    package init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }
}

package struct NativeWebRTCMediaProfile: Equatable, Sendable {
    package var publishVideoCodecs: [RTPCodec]
    package var receiveVideoCodecs: [RTPCodec]
    package var publishAudioCodecs: [RTPCodec]
    package var receiveAudioCodecs: [RTPCodec]
    package var dataChannelCodec: RTPCodec

    package init(
        publishVideoCodecs: [RTPCodec],
        receiveVideoCodecs: [RTPCodec],
        publishAudioCodecs: [RTPCodec],
        receiveAudioCodecs: [RTPCodec],
        dataChannelCodec: RTPCodec
    ) {
        self.publishVideoCodecs = publishVideoCodecs
        self.receiveVideoCodecs = receiveVideoCodecs
        self.publishAudioCodecs = publishAudioCodecs
        self.receiveAudioCodecs = receiveAudioCodecs
        self.dataChannelCodec = dataChannelCodec
    }

    package static let liveKitTiny = NativeWebRTCMediaProfile(
        publishVideoCodecs: [.h264],
        receiveVideoCodecs: [.h264, .vp8],
        publishAudioCodecs: [.opus],
        receiveAudioCodecs: [.opus],
        dataChannelCodec: .webRTCDataChannel
    )
}

package struct NativeWebRTCConfiguration: Equatable, Sendable {
    package var role: PeerConnectionRole
    package var iceServers: [ICEServer]
    package var mediaProfile: NativeWebRTCMediaProfile

    package init(
        role: PeerConnectionRole,
        iceServers: [ICEServer] = [],
        mediaProfile: NativeWebRTCMediaProfile = .liveKitTiny
    ) {
        self.role = role
        self.iceServers = iceServers
        self.mediaProfile = mediaProfile
    }
}

package struct SDPCodecCapability: Equatable, Sendable {
    package var kind: RTPMediaKind
    package var codec: RTPCodec
    package var clockRate: Int
    package var channels: Int?

    package init(kind: RTPMediaKind, codec: RTPCodec, clockRate: Int, channels: Int? = nil) {
        self.kind = kind
        self.codec = codec
        self.clockRate = clockRate
        self.channels = channels
    }
}

package enum PeerConnectionState: String, Equatable, Sendable {
    case new
    case connecting
    case connected
    case disconnected
    case failed
    case closed
}

package final class PeerConnectionCoordinator: @unchecked Sendable {
    package let configuration: NativeWebRTCConfiguration
    package private(set) var state: PeerConnectionState = .new

    package init(configuration: NativeWebRTCConfiguration) {
        self.configuration = configuration
    }

    package var localCapabilities: [SDPCodecCapability] {
        var capabilities: [SDPCodecCapability] = []

        for codec in configuration.mediaProfile.publishAudioCodecs {
            capabilities.append(SDPCodecCapability(kind: .audio, codec: codec, clockRate: 48_000, channels: 1))
        }

        for codec in configuration.mediaProfile.publishVideoCodecs {
            capabilities.append(SDPCodecCapability(kind: .video, codec: codec, clockRate: 90_000))
        }

        capabilities.append(SDPCodecCapability(kind: .application, codec: configuration.mediaProfile.dataChannelCodec, clockRate: 0))
        return capabilities
    }

    package func close() {
        state = .closed
    }
}
