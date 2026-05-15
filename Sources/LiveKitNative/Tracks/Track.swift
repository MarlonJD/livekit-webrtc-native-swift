import Foundation
import LiveKitNativeProtocol

public enum TrackKind: String, Equatable, Sendable {
    case audio
    case video
}

extension TrackKind {
    init?(protocolTrackType: Livekit_TrackType) {
        switch protocolTrackType {
        case .audio:
            self = .audio
        case .video:
            self = .video
        case .data, .UNRECOGNIZED(_):
            return nil
        }
    }
}

public enum TrackSource: String, Equatable, Sendable {
    case camera
    case microphone
    case screenShare
    case screenShareAudio
    case unknown
}

extension TrackSource {
    init(protocolTrackSource: Livekit_TrackSource) {
        switch protocolTrackSource {
        case .camera:
            self = .camera
        case .microphone:
            self = .microphone
        case .screenShare:
            self = .screenShare
        case .screenShareAudio:
            self = .screenShareAudio
        case .unknown, .UNRECOGNIZED(_):
            self = .unknown
        }
    }
}

public class Track: Identifiable, Equatable, @unchecked Sendable {
    public let id: String
    public let sid: String?
    public let name: String
    public let kind: TrackKind
    public let source: TrackSource

    public init(id: String = UUID().uuidString, sid: String? = nil, name: String, kind: TrackKind, source: TrackSource = .unknown) {
        self.id = id
        self.sid = sid
        self.name = name
        self.kind = kind
        self.source = source
    }

    public static func == (lhs: Track, rhs: Track) -> Bool {
        lhs.id == rhs.id
    }
}

public class VideoTrack: Track, @unchecked Sendable {
    public init(id: String = UUID().uuidString, sid: String? = nil, name: String, source: TrackSource = .camera) {
        super.init(id: id, sid: sid, name: name, kind: .video, source: source)
    }
}

public class AudioTrack: Track, @unchecked Sendable {
    public init(id: String = UUID().uuidString, sid: String? = nil, name: String, source: TrackSource = .microphone) {
        super.init(id: id, sid: sid, name: name, kind: .audio, source: source)
    }
}

public final class LocalVideoTrack: VideoTrack, @unchecked Sendable {
    public static func createCameraTrack(options: CameraCaptureOptions = .init()) throws -> LocalVideoTrack {
        LocalVideoTrack(name: "camera", source: .camera)
    }
}

public final class LocalAudioTrack: AudioTrack, @unchecked Sendable {
    public static func createTrack(options: AudioCaptureOptions = .init()) throws -> LocalAudioTrack {
        LocalAudioTrack(name: "microphone", source: .microphone)
    }
}

public final class RemoteVideoTrack: VideoTrack, @unchecked Sendable {}

public final class RemoteAudioTrack: AudioTrack, @unchecked Sendable {}
