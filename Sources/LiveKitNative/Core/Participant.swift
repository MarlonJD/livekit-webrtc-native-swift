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

public struct TrackSubscriptionPermission: Equatable, Sendable {
    public let participantSID: String
    public let participantIdentity: String
    public let allTracks: Bool
    public let trackSIDs: [String]

    public init(
        participantSID: String = "",
        participantIdentity: String = "",
        allTracks: Bool = false,
        trackSIDs: [String] = []
    ) {
        self.participantSID = participantSID
        self.participantIdentity = participantIdentity
        self.allTracks = allTracks
        self.trackSIDs = trackSIDs
    }

    var protocolPermission: Livekit_TrackPermission {
        var permission = Livekit_TrackPermission()
        permission.participantSid = participantSID
        permission.participantIdentity = participantIdentity
        permission.allTracks = allTracks
        permission.trackSids = trackSIDs
        return permission
    }
}

public enum LocalAudioTrackFeature: Equatable, Sendable {
    case stereo
    case noDTX
    case autoGainControl
    case echoCancellation
    case noiseSuppression
    case enhancedNoiseCancellation
    case preconnectBuffer
    case unknown(Int)

    var protocolFeature: Livekit_AudioTrackFeature {
        switch self {
        case .stereo:
            return .tfStereo
        case .noDTX:
            return .tfNoDtx
        case .autoGainControl:
            return .tfAutoGainControl
        case .echoCancellation:
            return .tfEchoCancellation
        case .noiseSuppression:
            return .tfNoiseSuppression
        case .enhancedNoiseCancellation:
            return .tfEnhancedNoiseCancellation
        case .preconnectBuffer:
            return .tfPreconnectBuffer
        case let .unknown(rawValue):
            return .UNRECOGNIZED(rawValue)
        }
    }
}

public final class LocalParticipant: Participant, @unchecked Sendable {
    private let publicationLock = NSLock()
    private let dataPublicationLock = NSLock()
    private let commandLock = NSLock()
    private var localTrackPublications: [String: LocalTrackPublication] = [:]
    private var localDataPublishPlans: [LocalDataPublishPlan] = []
    private var localDataTrackPublications: [UInt32: DataTrackInfo] = [:]
    private var nextDataTrackPublisherHandle: UInt32 = 1
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

    public var dataTrackPublications: [DataTrackInfo] {
        dataPublicationLock.withLock {
            localDataTrackPublications.values.sorted { $0.publisherHandle < $1.publisherHandle }
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
            let cameraPublications = publicationLock.withLock {
                localTrackPublications.values.filter { $0.source == .camera }
            }

            for publication in cameraPublications {
                try await unpublish(publication: publication)
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
            let microphonePublications = publicationLock.withLock {
                localTrackPublications.values.filter { $0.source == .microphone }
            }

            for publication in microphonePublications {
                try await unpublish(publication: publication)
            }
        }
    }

    public func publish(videoTrack: LocalVideoTrack, options: TrackPublishOptions = .init()) async throws -> LocalTrackPublication {
        let plan = LocalVideoPublishPlan(track: videoTrack, options: options)
        let publishedTrack = if let commandHandler = currentCommandHandler() {
            try await commandHandler.publishVideo(plan)
        } else {
            LocalPublishedTrack(sid: plan.cid, name: plan.name, kind: .video, source: plan.source)
        }
        let publication = LocalTrackPublication(
            sid: publishedTrack.sid,
            name: publishedTrack.name,
            kind: publishedTrack.kind,
            source: publishedTrack.source,
            isMuted: publishedTrack.isMuted,
            track: videoTrack
        )

        publicationLock.withLock {
            localTrackPublications[publication.sid] = publication
        }

        return publication
    }

    public func publish(audioTrack: LocalAudioTrack, options: TrackPublishOptions = .init()) async throws -> LocalTrackPublication {
        let plan = LocalAudioPublishPlan(track: audioTrack, options: options)
        let publishedTrack = if let commandHandler = currentCommandHandler() {
            try await commandHandler.publishAudio(plan)
        } else {
            LocalPublishedTrack(sid: plan.cid, name: plan.name, kind: .audio, source: plan.source)
        }
        let publication = LocalTrackPublication(
            sid: publishedTrack.sid,
            name: publishedTrack.name,
            kind: publishedTrack.kind,
            source: publishedTrack.source,
            isMuted: publishedTrack.isMuted,
            track: audioTrack
        )

        publicationLock.withLock {
            localTrackPublications[publication.sid] = publication
        }

        return publication
    }

    public func unpublish(publication: LocalTrackPublication) async throws {
        guard publicationLock.withLock({ localTrackPublications[publication.sid] }) != nil else {
            return
        }

        let plan = LocalTrackUnpublishPlan(sid: publication.sid)
        if let commandHandler = currentCommandHandler() {
            try await commandHandler.unpublishTrack(plan)
        }

        removeLocalTrackPublication(sid: publication.sid)
    }

    public func setTrackMuted(publication: LocalTrackPublication, muted: Bool) async throws {
        guard publicationLock.withLock({ localTrackPublications[publication.sid] }) != nil else {
            throw LiveKitNativeError.requestFailed(
                action: "track mute",
                reason: "trackNotPublished",
                message: "Local track publication is not active."
            )
        }

        guard publication.isMuted != muted else {
            return
        }

        let plan = LocalTrackMutePlan(sid: publication.sid, muted: muted)
        if let commandHandler = currentCommandHandler() {
            try await commandHandler.updateTrackMute(plan)
        } else {
            _ = applyTrackMute(sid: publication.sid, muted: muted)
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

    @discardableResult
    public func publishDataTrack(name: String, encryption: DataTrackEncryption = .none) async throws -> DataTrackInfo {
        let publisherHandle = allocateDataTrackPublisherHandle()
        let plan = LocalDataTrackPublishPlan(
            pubHandle: publisherHandle,
            name: name,
            encryption: encryption.protocolEncryption
        )
        let dataTrack = if let commandHandler = currentCommandHandler() {
            try await commandHandler.publishDataTrack(plan)
        } else {
            DataTrackInfo(
                publisherHandle: publisherHandle,
                sid: "",
                name: name,
                encryption: encryption
            )
        }

        dataPublicationLock.withLock {
            localDataTrackPublications[dataTrack.publisherHandle] = dataTrack
        }

        return dataTrack
    }

    @discardableResult
    public func unpublishDataTrack(_ dataTrack: DataTrackInfo) async throws -> DataTrackInfo {
        let plan = LocalDataTrackPublishPlan(
            pubHandle: dataTrack.publisherHandle,
            name: dataTrack.name,
            encryption: dataTrack.encryption.protocolEncryption
        )
        let unpublishedTrack = if let commandHandler = currentCommandHandler() {
            try await commandHandler.unpublishDataTrack(plan)
        } else {
            dataTrack
        }

        dataPublicationLock.withLock {
            _ = localDataTrackPublications.removeValue(forKey: dataTrack.publisherHandle)
        }

        return unpublishedTrack
    }

    public func updateDataSubscription(
        trackSID: String,
        subscribe: Bool,
        targetFPS: UInt32? = nil
    ) async throws {
        guard let commandHandler = currentCommandHandler() else {
            throw LiveKitNativeError.notConnected
        }

        try await commandHandler.updateDataSubscription(
            DataSubscriptionUpdatePlan(
                trackSid: trackSID,
                subscribe: subscribe,
                targetFps: targetFPS
            )
        )
    }

    public func setTrackSubscriptionPermissions(
        allParticipantsAllowed: Bool,
        permissions: [TrackSubscriptionPermission] = []
    ) async throws {
        guard let commandHandler = currentCommandHandler() else {
            throw LiveKitNativeError.notConnected
        }

        try await commandHandler.updateSubscriptionPermissions(
            LocalTrackSubscriptionPermissionPlan(
                allParticipantsAllowed: allParticipantsAllowed,
                permissions: permissions
            )
        )
    }

    public func updateAudioTrack(
        publication: LocalTrackPublication,
        features: [LocalAudioTrackFeature]
    ) async throws {
        guard let publication = localPublication(sid: publication.sid) else {
            throw LiveKitNativeError.requestFailed(
                action: "update audio track",
                reason: "trackNotPublished",
                message: "Local track publication is not active."
            )
        }
        guard publication.kind == .audio else {
            throw LiveKitNativeError.requestFailed(
                action: "update audio track",
                reason: "trackKindMismatch",
                message: "Local track publication is not audio."
            )
        }
        guard let commandHandler = currentCommandHandler() else {
            throw LiveKitNativeError.notConnected
        }

        try await commandHandler.updateAudioTrack(
            LocalAudioTrackUpdatePlan(
                sid: publication.sid,
                features: features
            )
        )
    }

    public func updateVideoTrack(
        publication: LocalTrackPublication,
        width: UInt32,
        height: UInt32
    ) async throws {
        guard let publication = localPublication(sid: publication.sid) else {
            throw LiveKitNativeError.requestFailed(
                action: "update video track",
                reason: "trackNotPublished",
                message: "Local track publication is not active."
            )
        }
        guard publication.kind == .video else {
            throw LiveKitNativeError.requestFailed(
                action: "update video track",
                reason: "trackKindMismatch",
                message: "Local track publication is not video."
            )
        }
        guard let commandHandler = currentCommandHandler() else {
            throw LiveKitNativeError.notConnected
        }

        try await commandHandler.updateVideoTrack(
            LocalVideoTrackUpdatePlan(
                sid: publication.sid,
                width: width,
                height: height
            )
        )
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

    func applyTrackMute(sid: String, muted: Bool) -> LocalTrackPublication? {
        publicationLock.withLock {
            guard let publication = localTrackPublications[sid], publication.setMuted(muted) else {
                return nil
            }

            return publication
        }
    }

    private func localPublication(sid: String) -> LocalTrackPublication? {
        publicationLock.withLock {
            localTrackPublications[sid]
        }
    }

    @discardableResult
    private func removeLocalTrackPublication(sid: String) -> LocalTrackPublication? {
        publicationLock.withLock {
            localTrackPublications.removeValue(forKey: sid)
        }
    }

    private func currentCommandHandler() -> LocalParticipantCommandHandler? {
        commandLock.withLock {
            commandHandler
        }
    }

    private func allocateDataTrackPublisherHandle() -> UInt32 {
        dataPublicationLock.withLock {
            while localDataTrackPublications[nextDataTrackPublisherHandle] != nil {
                nextDataTrackPublisherHandle &+= 1
                if nextDataTrackPublisherHandle == 0 {
                    nextDataTrackPublisherHandle = 1
                }
            }

            let handle = nextDataTrackPublisherHandle
            repeat {
                nextDataTrackPublisherHandle &+= 1
                if nextDataTrackPublisherHandle == 0 {
                    nextDataTrackPublisherHandle = 1
                }
            } while localDataTrackPublications[nextDataTrackPublisherHandle] != nil
            return handle
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

struct LocalTrackMutePlan: Equatable, Sendable {
    var sid: String
    var muted: Bool

    var muteRequest: Livekit_MuteTrackRequest {
        var request = Livekit_MuteTrackRequest()
        request.sid = sid
        request.muted = muted
        return request
    }
}

struct LocalTrackUnpublishPlan: Equatable, Sendable {
    var sid: String

    var muteRequest: Livekit_MuteTrackRequest {
        var request = Livekit_MuteTrackRequest()
        request.sid = sid
        request.muted = true
        return request
    }
}

struct LocalTrackSubscriptionPermissionPlan: Equatable, Sendable {
    var allParticipantsAllowed: Bool
    var permissions: [TrackSubscriptionPermission]

    var subscriptionPermission: Livekit_SubscriptionPermission {
        var permission = Livekit_SubscriptionPermission()
        permission.allParticipants = allParticipantsAllowed
        permission.trackPermissions = permissions.map(\.protocolPermission)
        return permission
    }
}

struct LocalAudioTrackUpdatePlan: Equatable, Sendable {
    var sid: String
    var features: [LocalAudioTrackFeature]

    var updateRequest: Livekit_UpdateLocalAudioTrack {
        var request = Livekit_UpdateLocalAudioTrack()
        request.trackSid = sid
        request.features = features.map(\.protocolFeature)
        return request
    }
}

struct LocalVideoTrackUpdatePlan: Equatable, Sendable {
    var sid: String
    var width: UInt32
    var height: UInt32

    var updateRequest: Livekit_UpdateLocalVideoTrack {
        var request = Livekit_UpdateLocalVideoTrack()
        request.trackSid = sid
        request.width = width
        request.height = height
        return request
    }
}

struct LocalPublishedTrack: Equatable, Sendable {
    var sid: String
    var name: String
    var kind: TrackKind
    var source: TrackSource
    var isMuted: Bool

    init(sid: String, name: String, kind: TrackKind, source: TrackSource, isMuted: Bool = false) {
        self.sid = sid
        self.name = name
        self.kind = kind
        self.source = source
        self.isMuted = isMuted
    }

    init(trackInfo: Livekit_TrackInfo, fallbackCID: String, fallbackName: String, fallbackKind: TrackKind, fallbackSource: TrackSource) {
        self.sid = trackInfo.sid.isEmpty ? fallbackCID : trackInfo.sid
        self.name = trackInfo.name.isEmpty ? fallbackName : trackInfo.name
        self.kind = TrackKind(protocolTrackType: trackInfo.type) ?? fallbackKind
        self.source = TrackSource(protocolTrackSource: trackInfo.source)
        if self.source == .unknown {
            self.source = fallbackSource
        }
        self.isMuted = trackInfo.muted
    }
}

struct LocalParticipantCommandHandler: Sendable {
    var publishVideo: @Sendable (LocalVideoPublishPlan) async throws -> LocalPublishedTrack
    var publishAudio: @Sendable (LocalAudioPublishPlan) async throws -> LocalPublishedTrack
    var unpublishTrack: @Sendable (LocalTrackUnpublishPlan) async throws -> Void
    var updateParticipant: @Sendable (ParticipantMetadataUpdate) async throws -> Void
    var publishData: @Sendable (LocalDataPublishPlan) async throws -> Void
    var publishDataTrack: @Sendable (LocalDataTrackPublishPlan) async throws -> DataTrackInfo
    var unpublishDataTrack: @Sendable (LocalDataTrackPublishPlan) async throws -> DataTrackInfo
    var updateDataSubscription: @Sendable (DataSubscriptionUpdatePlan) async throws -> Void
    var updateTrackMute: @Sendable (LocalTrackMutePlan) async throws -> Void
    var updateSubscriptionPermissions: @Sendable (LocalTrackSubscriptionPermissionPlan) async throws -> Void
    var updateAudioTrack: @Sendable (LocalAudioTrackUpdatePlan) async throws -> Void
    var updateVideoTrack: @Sendable (LocalVideoTrackUpdatePlan) async throws -> Void
}

public final class RemoteParticipant: Participant, @unchecked Sendable {
    private let publicationLock = NSLock()
    private var remoteTrackPublications: [String: RemoteTrackPublication] = [:]

    public var trackPublications: [RemoteTrackPublication] {
        publicationLock.withLock {
            remoteTrackPublications.values.sorted { $0.sid < $1.sid }
        }
    }

    func applyTrackPublications(_ snapshots: [TrackPublicationSnapshot]) -> TrackPublicationUpdateResult {
        publicationLock.withLock {
            var addedPublications: [RemoteTrackPublication] = []
            var muteChangedPublications: [RemoteTrackPublication] = []

            for snapshot in snapshots where !snapshot.sid.isEmpty {
                if let existing = remoteTrackPublications[snapshot.sid] {
                    if existing.setMuted(snapshot.isMuted) {
                        muteChangedPublications.append(existing)
                    }
                    continue
                }

                let publication = RemoteTrackPublication(
                    sid: snapshot.sid,
                    name: snapshot.name,
                    kind: snapshot.kind,
                    source: snapshot.source,
                    isMuted: snapshot.isMuted
                )
                remoteTrackPublications[snapshot.sid] = publication
                addedPublications.append(publication)
            }

            return TrackPublicationUpdateResult(
                addedPublications: addedPublications,
                muteChangedPublications: muteChangedPublications
            )
        }
    }

    func applyTrackMute(sid: String, muted: Bool) -> RemoteTrackPublication? {
        publicationLock.withLock {
            guard let publication = remoteTrackPublications[sid], publication.setMuted(muted) else {
                return nil
            }

            return publication
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
    var isMuted: Bool

    init(sid: String, name: String, kind: TrackKind, source: TrackSource = .unknown, isMuted: Bool = false) {
        self.sid = sid
        self.name = name
        self.kind = kind
        self.source = source
        self.isMuted = isMuted
    }

    init?(trackInfo: Livekit_TrackInfo) {
        guard let kind = TrackKind(protocolTrackType: trackInfo.type) else {
            return nil
        }

        self.init(
            sid: trackInfo.sid,
            name: trackInfo.name,
            kind: kind,
            source: TrackSource(protocolTrackSource: trackInfo.source),
            isMuted: trackInfo.muted
        )
    }
}

struct TrackPublicationUpdateResult: Equatable, Sendable {
    var addedPublications: [RemoteTrackPublication]
    var muteChangedPublications: [RemoteTrackPublication]
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
