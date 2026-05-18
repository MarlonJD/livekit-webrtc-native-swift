import Foundation

public struct RoomOptions: Equatable, Sendable {
    public var defaultAutoSubscribe: Bool
    public var defaultAdaptiveStream: Bool?
    public var defaultSubscriberAllowPause: Bool?
    public var defaultAutoSubscribeDataTrack: Bool?
    public var automaticallyApplySubscriberAdaptiveTrackSettings: Bool
    public var subscriberAdaptiveTrackSettingsPriority: UInt32
    public var automaticallyDecodeSubscriberVideo: Bool
    public var automaticallyPlaySubscriberAudio: Bool

    public init(
        defaultAutoSubscribe: Bool = true,
        defaultAdaptiveStream: Bool? = nil,
        defaultSubscriberAllowPause: Bool? = nil,
        defaultAutoSubscribeDataTrack: Bool? = nil,
        automaticallyApplySubscriberAdaptiveTrackSettings: Bool = false,
        subscriberAdaptiveTrackSettingsPriority: UInt32 = 0,
        automaticallyDecodeSubscriberVideo: Bool = false,
        automaticallyPlaySubscriberAudio: Bool = false
    ) {
        self.defaultAutoSubscribe = defaultAutoSubscribe
        self.defaultAdaptiveStream = defaultAdaptiveStream
        self.defaultSubscriberAllowPause = defaultSubscriberAllowPause
        self.defaultAutoSubscribeDataTrack = defaultAutoSubscribeDataTrack
        self.automaticallyApplySubscriberAdaptiveTrackSettings = automaticallyApplySubscriberAdaptiveTrackSettings
        self.subscriberAdaptiveTrackSettingsPriority = subscriberAdaptiveTrackSettingsPriority
        self.automaticallyDecodeSubscriberVideo = automaticallyDecodeSubscriberVideo
        self.automaticallyPlaySubscriberAudio = automaticallyPlaySubscriberAudio
    }
}

public struct ConnectOptions: Equatable, Sendable {
    public var autoSubscribe: Bool?
    public var adaptiveStream: Bool?
    public var subscriberAllowPause: Bool?
    public var autoSubscribeDataTrack: Bool?
    public var reconnect: Bool
    public var sdk: String
    public var version: String
    public var protocolVersion: Int
    public var maxReconnectAttempts: Int
    public var reconnectRetryDelayMilliseconds: Int
    public var maxAlternativeURLRedirects: Int

    public init(
        autoSubscribe: Bool? = nil,
        adaptiveStream: Bool? = nil,
        subscriberAllowPause: Bool? = nil,
        autoSubscribeDataTrack: Bool? = nil,
        reconnect: Bool = false,
        sdk: String = LiveKitNative.sdkName,
        version: String = LiveKitNative.version,
        protocolVersion: Int = LiveKitNative.protocolVersion,
        maxReconnectAttempts: Int = 1,
        reconnectRetryDelayMilliseconds: Int = 250,
        maxAlternativeURLRedirects: Int = 1
    ) {
        self.autoSubscribe = autoSubscribe
        self.adaptiveStream = adaptiveStream
        self.subscriberAllowPause = subscriberAllowPause
        self.autoSubscribeDataTrack = autoSubscribeDataTrack
        self.reconnect = reconnect
        self.sdk = sdk
        self.version = version
        self.protocolVersion = protocolVersion
        self.maxReconnectAttempts = maxReconnectAttempts
        self.reconnectRetryDelayMilliseconds = reconnectRetryDelayMilliseconds
        self.maxAlternativeURLRedirects = maxAlternativeURLRedirects
    }
}

public struct CameraCaptureOptions: Equatable, Sendable {
    public var position: CameraPosition
    public var width: Int
    public var height: Int
    public var framesPerSecond: Int

    public init(
        position: CameraPosition = .front,
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

public enum CameraPosition: String, Equatable, Sendable {
    case front
    case back
    case unspecified
}

public struct AudioCaptureOptions: Equatable, Sendable {
    public var echoCancellation: Bool
    public var sampleRate: Int
    public var channelCount: Int
    public var frameDurationMilliseconds: Int

    public init(
        echoCancellation: Bool = true,
        sampleRate: Int = 48_000,
        channelCount: Int = 1,
        frameDurationMilliseconds: Int = 20
    ) {
        self.echoCancellation = echoCancellation
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameDurationMilliseconds = frameDurationMilliseconds
    }
}

public struct TrackPublishOptions: Equatable, Sendable {
    public var name: String?
    public var source: TrackSource?
    public var simulcast: Bool

    public init(name: String? = nil, source: TrackSource? = nil, simulcast: Bool = true) {
        self.name = name
        self.source = source
        self.simulcast = simulcast
    }
}

public struct DataPublishOptions: Equatable, Sendable {
    public var reliable: Bool
    public var topic: String?
    public var destinationIdentities: [String]

    public init(reliable: Bool = true, topic: String? = nil, destinationIdentities: [String] = []) {
        self.reliable = reliable
        self.topic = topic
        self.destinationIdentities = destinationIdentities
    }
}
