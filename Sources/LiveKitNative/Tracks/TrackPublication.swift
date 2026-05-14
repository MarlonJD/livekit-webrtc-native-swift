import Foundation

public class TrackPublication: Identifiable, Equatable, @unchecked Sendable {
    public let sid: String
    public let name: String
    public let kind: TrackKind
    public let source: TrackSource

    public var id: String {
        sid
    }

    public init(sid: String, name: String, kind: TrackKind, source: TrackSource = .unknown) {
        self.sid = sid
        self.name = name
        self.kind = kind
        self.source = source
    }

    public static func == (lhs: TrackPublication, rhs: TrackPublication) -> Bool {
        lhs.sid == rhs.sid
    }
}

public final class LocalTrackPublication: TrackPublication, @unchecked Sendable {
    public let track: Track?

    public init(sid: String, name: String, kind: TrackKind, source: TrackSource = .unknown, track: Track? = nil) {
        self.track = track
        super.init(sid: sid, name: name, kind: kind, source: source)
    }
}

public final class RemoteTrackPublication: TrackPublication, @unchecked Sendable {
    public let track: Track?

    public init(sid: String, name: String, kind: TrackKind, source: TrackSource = .unknown, track: Track? = nil) {
        self.track = track
        super.init(sid: sid, name: name, kind: kind, source: source)
    }
}
