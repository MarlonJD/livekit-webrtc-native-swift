import Foundation

public struct AudioSessionConfiguration: Equatable, Sendable {
    public var sampleRate: Double
    public var preferredIOBufferDuration: TimeInterval
    public var allowsBluetooth: Bool
    public var allowsBluetoothA2DP: Bool
    public var allowsAirPlay: Bool
    public var defaultToSpeaker: Bool
    public var mixWithOthers: Bool
    public var duckOthers: Bool

    public init(
        sampleRate: Double = 48_000,
        preferredIOBufferDuration: TimeInterval = 0.02,
        allowsBluetooth: Bool = true,
        allowsBluetoothA2DP: Bool = false,
        allowsAirPlay: Bool = true,
        defaultToSpeaker: Bool = true,
        mixWithOthers: Bool = false,
        duckOthers: Bool = false
    ) {
        self.sampleRate = sampleRate
        self.preferredIOBufferDuration = preferredIOBufferDuration
        self.allowsBluetooth = allowsBluetooth
        self.allowsBluetoothA2DP = allowsBluetoothA2DP
        self.allowsAirPlay = allowsAirPlay
        self.defaultToSpeaker = defaultToSpeaker
        self.mixWithOthers = mixWithOthers
        self.duckOthers = duckOthers
    }

    public static let voiceChat = AudioSessionConfiguration()
}

public enum AudioSessionInterruptionState: Equatable, Sendable {
    case began
    case ended(shouldResume: Bool)
}

public enum AudioSessionRouteChangeReason: String, Equatable, Sendable {
    case unknown
    case newDeviceAvailable
    case oldDeviceUnavailable
    case categoryChange
    case override
    case wakeFromSleep
    case noSuitableRoute
    case routeConfigurationChange
}

public protocol AudioSessionControlling: AnyObject, Sendable {
    func configureForVoiceChat(_ configuration: AudioSessionConfiguration) throws
    func activate() throws
    func deactivate() throws
}

#if os(iOS)
import AVFoundation

public final class AudioSessionController: AudioSessionControlling, @unchecked Sendable {
    private let session: AVAudioSession

    public convenience init() {
        self.init(session: .sharedInstance())
    }

    init(session: AVAudioSession) {
        self.session = session
    }

    public func configureForVoiceChat(_ configuration: AudioSessionConfiguration = .voiceChat) throws {
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: configuration.categoryOptions
        )
        try session.setPreferredSampleRate(configuration.sampleRate)
        try session.setPreferredIOBufferDuration(configuration.preferredIOBufferDuration)
    }

    public func activate() throws {
        try session.setActive(true)
    }

    public func deactivate() throws {
        try session.setActive(false, options: .notifyOthersOnDeactivation)
    }

    public func interruptionState(from notification: Notification) -> AudioSessionInterruptionState? {
        Self.interruptionState(from: notification)
    }

    public func routeChangeReason(from notification: Notification) -> AudioSessionRouteChangeReason? {
        Self.routeChangeReason(from: notification)
    }

    public static func interruptionState(from notification: Notification) -> AudioSessionInterruptionState? {
        guard notification.name == AVAudioSession.interruptionNotification,
              let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else {
            return nil
        }

        switch type {
        case .began:
            return .began
        case .ended:
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            return .ended(shouldResume: options.contains(.shouldResume))
        @unknown default:
            return nil
        }
    }

    public static func routeChangeReason(from notification: Notification) -> AudioSessionRouteChangeReason? {
        guard notification.name == AVAudioSession.routeChangeNotification,
              let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason)
        else {
            return nil
        }

        return AudioSessionRouteChangeReason(reason)
    }
}

private extension AudioSessionConfiguration {
    var categoryOptions: AVAudioSession.CategoryOptions {
        var options: AVAudioSession.CategoryOptions = []
        if allowsBluetooth {
            options.insert(.allowBluetooth)
        }
        if allowsBluetoothA2DP {
            options.insert(.allowBluetoothA2DP)
        }
        if allowsAirPlay {
            options.insert(.allowAirPlay)
        }
        if defaultToSpeaker {
            options.insert(.defaultToSpeaker)
        }
        if mixWithOthers {
            options.insert(.mixWithOthers)
        }
        if duckOthers {
            options.insert(.duckOthers)
        }
        return options
    }
}

private extension AudioSessionRouteChangeReason {
    init(_ reason: AVAudioSession.RouteChangeReason) {
        switch reason {
        case .unknown:
            self = .unknown
        case .newDeviceAvailable:
            self = .newDeviceAvailable
        case .oldDeviceUnavailable:
            self = .oldDeviceUnavailable
        case .categoryChange:
            self = .categoryChange
        case .override:
            self = .override
        case .wakeFromSleep:
            self = .wakeFromSleep
        case .noSuitableRouteForCategory:
            self = .noSuitableRoute
        case .routeConfigurationChange:
            self = .routeConfigurationChange
        @unknown default:
            self = .unknown
        }
    }
}
#else
public final class AudioSessionController: AudioSessionControlling, @unchecked Sendable {
    public init() {}

    public func configureForVoiceChat(_ configuration: AudioSessionConfiguration = .voiceChat) throws {}

    public func activate() throws {}

    public func deactivate() throws {}

    public func interruptionState(from notification: Notification) -> AudioSessionInterruptionState? {
        nil
    }

    public func routeChangeReason(from notification: Notification) -> AudioSessionRouteChangeReason? {
        nil
    }

    public static func interruptionState(from notification: Notification) -> AudioSessionInterruptionState? {
        nil
    }

    public static func routeChangeReason(from notification: Notification) -> AudioSessionRouteChangeReason? {
        nil
    }
}
#endif
