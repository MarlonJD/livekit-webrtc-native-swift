import Foundation
import LiveKitNativeProtocol

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
    private let publicationLock = NSLock()
    private let dataPublicationLock = NSLock()
    private let commandLock = NSLock()
    private var localTrackPublications: [String: LocalTrackPublication] = [:]
    private var localDataPublishPlans: [LocalDataPublishPlan] = []
    private var commandHandler: LocalParticipantCommandHandler?

    public var trackPublications: [LocalTrackPublication] {
        publicationLock.withLock {
            localTrackPublications.values.sorted { $0.sid < $1.sid }
        }
    }

    var dataPublishPlans: [LocalDataPublishPlan] {
        dataPublicationLock.withLock {
            localDataPublishPlans
        }
    }

    public func setCamera(enabled: Bool, options: CameraCaptureOptions = .init()) async throws {
        if enabled {
            let hasCameraPublication = publicationLock.withLock {
                localTrackPublications.values.contains { $0.source == .camera }
            }

            guard !hasCameraPublication else {
                return
            }

            let track = try LocalVideoTrack.createCameraTrack(options: options)
            _ = try await publish(videoTrack: track, options: TrackPublishOptions(source: .camera))
        } else {
            publicationLock.withLock {
                localTrackPublications = localTrackPublications.filter { $0.value.source != .camera }
            }
        }
    }

    public func setMicrophone(enabled: Bool, options: AudioCaptureOptions = .init()) async throws {
        if enabled {
            let hasMicrophonePublication = publicationLock.withLock {
                localTrackPublications.values.contains { $0.source == .microphone }
            }

            guard !hasMicrophonePublication else {
                return
            }

            let track = try LocalAudioTrack.createTrack(options: options)
            _ = try await publish(audioTrack: track, options: TrackPublishOptions(source: .microphone))
        } else {
            publicationLock.withLock {
                localTrackPublications = localTrackPublications.filter { $0.value.source != .microphone }
            }
        }
    }

    public func publish(videoTrack: LocalVideoTrack, options: TrackPublishOptions = .init()) async throws -> LocalTrackPublication {
        let plan = LocalVideoPublishPlan(track: videoTrack, options: options)
        let publication = LocalTrackPublication(
            sid: plan.cid,
            name: plan.name,
            kind: .video,
            source: plan.source,
            track: videoTrack
        )

        publicationLock.withLock {
            localTrackPublications[publication.sid] = publication
        }

        return publication
    }

    public func publish(audioTrack: LocalAudioTrack, options: TrackPublishOptions = .init()) async throws -> LocalTrackPublication {
        let plan = LocalAudioPublishPlan(track: audioTrack, options: options)
        let publication = LocalTrackPublication(
            sid: plan.cid,
            name: plan.name,
            kind: .audio,
            source: plan.source,
            track: audioTrack
        )

        publicationLock.withLock {
            localTrackPublications[publication.sid] = publication
        }

        return publication
    }

    public func unpublish(publication: LocalTrackPublication) async throws {
        publicationLock.withLock {
            _ = localTrackPublications.removeValue(forKey: publication.sid)
        }
    }

    public func publish(data: Data, options: DataPublishOptions = .init()) async throws {
        let plan = try LocalDataPublishPlan(data: data, options: options, participantSid: sid, participantIdentity: identity)

        if let commandHandler = currentCommandHandler() {
            try await commandHandler.publishData(plan)
        }

        dataPublicationLock.withLock {
            localDataPublishPlans.append(plan)
        }
    }

    public func setMetadata(_ metadata: String) async throws {
        guard let commandHandler = currentCommandHandler() else {
            throw LiveKitNativeError.notConnected
        }

        try await commandHandler.updateParticipant(ParticipantMetadataUpdate(metadata: metadata))
        apply(
            ParticipantSnapshot(
                sid: sid,
                identity: identity,
                name: name,
                metadata: metadata,
                attributes: attributes
            )
        )
    }

    public func setName(_ name: String) async throws {
        guard let commandHandler = currentCommandHandler() else {
            throw LiveKitNativeError.notConnected
        }

        try await commandHandler.updateParticipant(ParticipantMetadataUpdate(name: name))
        apply(
            ParticipantSnapshot(
                sid: sid,
                identity: identity,
                name: name,
                metadata: metadata,
                attributes: attributes
            )
        )
    }

    public func setAttributes(_ attributes: [String: String]) async throws {
        guard let commandHandler = currentCommandHandler() else {
            throw LiveKitNativeError.notConnected
        }

        try await commandHandler.updateParticipant(ParticipantMetadataUpdate(attributes: attributes))
        apply(
            ParticipantSnapshot(
                sid: sid,
                identity: identity,
                name: name,
                metadata: metadata,
                attributes: attributes
            )
        )
    }

    func setCommandHandler(_ commandHandler: LocalParticipantCommandHandler?) {
        commandLock.withLock {
            self.commandHandler = commandHandler
        }
    }

    private func currentCommandHandler() -> LocalParticipantCommandHandler? {
        commandLock.withLock {
            commandHandler
        }
    }
}

struct ParticipantMetadataUpdate: Equatable, Sendable {
    var metadata: String?
    var name: String?
    var attributes: [String: String]?

    init(metadata: String? = nil, name: String? = nil, attributes: [String: String]? = nil) {
        self.metadata = metadata
        self.name = name
        self.attributes = attributes
    }
}

struct LocalParticipantCommandHandler: Sendable {
    var updateParticipant: @Sendable (ParticipantMetadataUpdate) async throws -> Void
    var publishData: @Sendable (LocalDataPublishPlan) async throws -> Void
}

public final class RemoteParticipant: Participant, @unchecked Sendable {
    private let publicationLock = NSLock()
    private var remoteTrackPublications: [String: RemoteTrackPublication] = [:]

    public var trackPublications: [RemoteTrackPublication] {
        publicationLock.withLock {
            remoteTrackPublications.values.sorted { $0.sid < $1.sid }
        }
    }

    func applyTrackPublications(_ snapshots: [TrackPublicationSnapshot]) -> [RemoteTrackPublication] {
        publicationLock.withLock {
            var addedPublications: [RemoteTrackPublication] = []

            for snapshot in snapshots where !snapshot.sid.isEmpty {
                guard remoteTrackPublications[snapshot.sid] == nil else {
                    continue
                }

                let publication = RemoteTrackPublication(
                    sid: snapshot.sid,
                    name: snapshot.name,
                    kind: snapshot.kind,
                    source: snapshot.source
                )
                remoteTrackPublications[snapshot.sid] = publication
                addedPublications.append(publication)
            }

            return addedPublications
        }
    }

    func removeTrackPublication(sid: String) -> RemoteTrackPublication? {
        publicationLock.withLock {
            remoteTrackPublications.removeValue(forKey: sid)
        }
    }

    func removeAllTrackPublications() -> [RemoteTrackPublication] {
        publicationLock.withLock {
            let publications = remoteTrackPublications.values.sorted { $0.sid < $1.sid }
            remoteTrackPublications.removeAll()
            return publications
        }
    }
}

struct ParticipantSnapshot: Equatable, Sendable {
    var sid: String
    var identity: String
    var name: String?
    var metadata: String?
    var attributes: [String: String]
    var trackPublications: [TrackPublicationSnapshot]
    var isDisconnected: Bool

    init(
        sid: String,
        identity: String,
        name: String? = nil,
        metadata: String? = nil,
        attributes: [String: String] = [:],
        trackPublications: [TrackPublicationSnapshot] = [],
        isDisconnected: Bool = false
    ) {
        self.sid = sid
        self.identity = identity
        self.name = name
        self.metadata = metadata
        self.attributes = attributes
        self.trackPublications = trackPublications
        self.isDisconnected = isDisconnected
    }

    var stableKey: String {
        sid.isEmpty ? identity : sid
    }

    var hasStableIdentity: Bool {
        !stableKey.isEmpty
    }
}

extension ParticipantSnapshot {
    init(participantInfo: Livekit_ParticipantInfo, fallbackIdentity: String? = nil) {
        self.init(
            sid: participantInfo.sid,
            identity: participantInfo.identity.isEmpty ? fallbackIdentity ?? "" : participantInfo.identity,
            name: participantInfo.name.nilIfEmpty,
            metadata: participantInfo.metadata.nilIfEmpty,
            attributes: participantInfo.attributes,
            trackPublications: participantInfo.tracks.compactMap { TrackPublicationSnapshot(trackInfo: $0) },
            isDisconnected: participantInfo.state == .disconnected
        )
    }
}

struct TrackPublicationSnapshot: Equatable, Sendable {
    var sid: String
    var name: String
    var kind: TrackKind
    var source: TrackSource

    init(sid: String, name: String, kind: TrackKind, source: TrackSource = .unknown) {
        self.sid = sid
        self.name = name
        self.kind = kind
        self.source = source
    }

    init?(trackInfo: Livekit_TrackInfo) {
        guard let kind = TrackKind(protocolTrackType: trackInfo.type) else {
            return nil
        }

        self.init(
            sid: trackInfo.sid,
            name: trackInfo.name,
            kind: kind,
            source: TrackSource(protocolTrackSource: trackInfo.source)
        )
    }
}

private struct ParticipantMutableState {
    var name: String?
    var metadata: String?
    var attributes: [String: String]
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

extension NSLocking {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
