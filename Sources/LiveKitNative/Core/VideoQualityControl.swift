import Foundation
import LiveKitNativeProtocol

public struct SubscribedVideoQualityPreset: Equatable, Sendable {
    public var disabled: Bool
    public var quality: VideoQuality
    public var width: UInt32
    public var height: UInt32
    public var framesPerSecond: UInt32

    public init(
        disabled: Bool,
        quality: VideoQuality,
        width: UInt32,
        height: UInt32,
        framesPerSecond: UInt32
    ) {
        self.disabled = disabled
        self.quality = quality
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
    }

    public static let off = SubscribedVideoQualityPreset(
        disabled: true,
        quality: .off,
        width: 0,
        height: 0,
        framesPerSecond: 0
    )

    public static let low = SubscribedVideoQualityPreset(
        disabled: false,
        quality: .low,
        width: 640,
        height: 360,
        framesPerSecond: 15
    )

    public static let medium = SubscribedVideoQualityPreset(
        disabled: false,
        quality: .medium,
        width: 1_280,
        height: 720,
        framesPerSecond: 24
    )

    public static let high = SubscribedVideoQualityPreset(
        disabled: false,
        quality: .high,
        width: 1_920,
        height: 1_080,
        framesPerSecond: 30
    )

    public static func preset(for quality: VideoQuality) -> SubscribedVideoQualityPreset {
        switch quality {
        case .low:
            return .low
        case .medium:
            return .medium
        case .high:
            return .high
        case .off:
            return .off
        case let .unknown(rawValue):
            return SubscribedVideoQualityPreset(
                disabled: false,
                quality: .unknown(rawValue),
                width: 0,
                height: 0,
                framesPerSecond: 0
            )
        }
    }
}

public struct PublishedVideoLayer: Equatable, Sendable {
    public var quality: VideoQuality
    public var width: UInt32
    public var height: UInt32
    public var bitrate: UInt32
    public var ssrc: UInt32
    public var spatialLayer: Int32
    public var rid: String
    public var repairSSRC: UInt32

    public init(
        quality: VideoQuality,
        width: UInt32,
        height: UInt32,
        bitrate: UInt32,
        ssrc: UInt32 = 0,
        spatialLayer: Int32 = 0,
        rid: String = "",
        repairSSRC: UInt32 = 0
    ) {
        self.quality = quality
        self.width = width
        self.height = height
        self.bitrate = bitrate
        self.ssrc = ssrc
        self.spatialLayer = spatialLayer
        self.rid = rid
        self.repairSSRC = repairSSRC
    }

    public static func singleH264(
        width: UInt32,
        height: UInt32,
        bitrate: UInt32,
        ssrc: UInt32
    ) -> PublishedVideoLayer {
        PublishedVideoLayer(
            quality: .high,
            width: width,
            height: height,
            bitrate: bitrate,
            ssrc: ssrc
        )
    }
}

extension PublishedVideoLayer {
    var protocolLayer: Livekit_VideoLayer {
        var layer = Livekit_VideoLayer()
        layer.quality = quality.liveKitProtocolQuality
        layer.width = width
        layer.height = height
        layer.bitrate = bitrate
        layer.ssrc = ssrc
        layer.spatialLayer = spatialLayer
        layer.rid = rid
        layer.repairSsrc = repairSSRC
        return layer
    }
}

extension VideoQuality {
    var liveKitProtocolQuality: Livekit_VideoQuality {
        switch self {
        case .low:
            return .low
        case .medium:
            return .medium
        case .high:
            return .high
        case .off:
            return .off
        case let .unknown(rawValue):
            return .UNRECOGNIZED(rawValue)
        }
    }
}
