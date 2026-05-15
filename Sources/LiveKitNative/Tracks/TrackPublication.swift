import Foundation

public class TrackPublication: Identifiable, Equatable, @unchecked Sendable {
    private let stateLock = NSLock()
    private var mutableIsMuted: Bool

    public let sid: String
    public let name: String
    public let kind: TrackKind
    public let source: TrackSource

    public var id: String {
        sid
    }

    public var isMuted: Bool {
        stateLock.withLock {
            mutableIsMuted
        }
    }

    public init(sid: String, name: String, kind: TrackKind, source: TrackSource = .unknown, isMuted: Bool = false) {
        self.sid = sid
        self.name = name
        self.kind = kind
        self.source = source
        self.mutableIsMuted = isMuted
    }

    public static func == (lhs: TrackPublication, rhs: TrackPublication) -> Bool {
        lhs.sid == rhs.sid
    }

    @discardableResult
    func setMuted(_ isMuted: Bool) -> Bool {
        stateLock.withLock {
            guard mutableIsMuted != isMuted else {
                return false
            }

            mutableIsMuted = isMuted
            return true
        }
    }
}

public final class LocalTrackPublication: TrackPublication, @unchecked Sendable {
    public let track: Track?

    public init(sid: String, name: String, kind: TrackKind, source: TrackSource = .unknown, isMuted: Bool = false, track: Track? = nil) {
        self.track = track
        super.init(sid: sid, name: name, kind: kind, source: source, isMuted: isMuted)
    }
}

public final class RemoteTrackPublication: TrackPublication, @unchecked Sendable {
    public let track: Track?

    public init(sid: String, name: String, kind: TrackKind, source: TrackSource = .unknown, isMuted: Bool = false, track: Track? = nil) {
        self.track = track
        super.init(sid: sid, name: name, kind: kind, source: source, isMuted: isMuted)
    }
}
