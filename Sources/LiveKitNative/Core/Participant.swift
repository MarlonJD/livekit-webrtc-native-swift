import Foundation

public class Participant: Identifiable, Hashable, @unchecked Sendable {
    private let stateLock = NSLock()
    private var mutableState: ParticipantMutableState

    public let sid: String
    public let identity: String

    public var id: String {
        sid.isEmpty ? identity : sid
    }

    public var name: String? {
        stateLock.withLock {
            mutableState.name
        }
    }

    public var metadata: String? {
        stateLock.withLock {
            mutableState.metadata
        }
    }

    public var attributes: [String: String] {
        stateLock.withLock {
            mutableState.attributes
        }
    }

    public init(sid: String = "", identity: String, name: String? = nil, metadata: String? = nil, attributes: [String: String] = [:]) {
        self.sid = sid
        self.identity = identity
        self.mutableState = ParticipantMutableState(name: name, metadata: metadata, attributes: attributes)
    }

    public static func == (lhs: Participant, rhs: Participant) -> Bool {
        lhs.id == rhs.id
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    func apply(_ snapshot: ParticipantSnapshot) {
        stateLock.withLock {
            mutableState.name = snapshot.name
            mutableState.metadata = snapshot.metadata
            mutableState.attributes = snapshot.attributes
        }
    }
}

public final class LocalParticipant: Participant, @unchecked Sendable {
    public func setCamera(enabled: Bool, options: CameraCaptureOptions = .init()) async throws {
        throw LiveKitNativeError.notImplemented("Camera capture")
    }

    public func setMicrophone(enabled: Bool, options: AudioCaptureOptions = .init()) async throws {
        throw LiveKitNativeError.notImplemented("Microphone capture")
    }

    public func publish(videoTrack: LocalVideoTrack, options: TrackPublishOptions = .init()) async throws -> LocalTrackPublication {
        throw LiveKitNativeError.notImplemented("Video publishing")
    }

    public func publish(audioTrack: LocalAudioTrack, options: TrackPublishOptions = .init()) async throws -> LocalTrackPublication {
        throw LiveKitNativeError.notImplemented("Audio publishing")
    }

    public func unpublish(publication: LocalTrackPublication) async throws {
        throw LiveKitNativeError.notImplemented("Track unpublishing")
    }

    public func publish(data: Data, options: DataPublishOptions = .init()) async throws {
        throw LiveKitNativeError.notImplemented("Data publishing")
    }

    public func setMetadata(_ metadata: String) async throws {
        throw LiveKitNativeError.notImplemented("Participant metadata update")
    }

    public func setName(_ name: String) async throws {
        throw LiveKitNativeError.notImplemented("Participant name update")
    }

    public func setAttributes(_ attributes: [String: String]) async throws {
        throw LiveKitNativeError.notImplemented("Participant attributes update")
    }
}

public final class RemoteParticipant: Participant, @unchecked Sendable {}

struct ParticipantSnapshot: Equatable, Sendable {
    var sid: String
    var identity: String
    var name: String?
    var metadata: String?
    var attributes: [String: String]

    init(sid: String, identity: String, name: String? = nil, metadata: String? = nil, attributes: [String: String] = [:]) {
        self.sid = sid
        self.identity = identity
        self.name = name
        self.metadata = metadata
        self.attributes = attributes
    }

    var stableKey: String {
        sid.isEmpty ? identity : sid
    }
}

private struct ParticipantMutableState {
    var name: String?
    var metadata: String?
    var attributes: [String: String]
}

extension NSLocking {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
