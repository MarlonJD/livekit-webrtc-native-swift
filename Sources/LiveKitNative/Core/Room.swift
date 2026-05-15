import Foundation
import LiveKitNativeProtocol
import LiveKitNativeWebRTC

public final class Room: @unchecked Sendable {
    public weak var delegate: (any RoomDelegate)?
    public let events: AsyncStream<RoomEvent>

    private let options: RoomOptions
    private let actor: RoomActor
    private let signalConnection: SignalConnection
    private let requestTracker = SignalRequestTracker()
    private let subscriberPeerConnection: PeerConnectionCoordinator
    private let publisherPeerConnection: PeerConnectionCoordinator
    private let snapshots: RoomSnapshotStore
    private let signalLoopLock = NSLock()
    private let connectionContextLock = NSLock()
    private let eventContinuation: AsyncStream<RoomEvent>.Continuation
    private var signalLoopTask: Task<Void, Never>?
    private var connectionContext: RoomConnectionContext?

    public var localParticipant: LocalParticipant {
        snapshots.localParticipant
    }

    public var remoteParticipants: [RemoteParticipant] {
        snapshots.remoteParticipants
    }

    public var connectionState: ConnectionState {
        snapshots.connectionState
    }

    public convenience init(options: RoomOptions = .init()) {
        self.init(options: options, signalConnection: SignalConnection())
    }

    init(
        options: RoomOptions = .init(),
        signalConnection: SignalConnection,
        subscriberPeerConnection: PeerConnectionCoordinator = PeerConnectionCoordinator(
            configuration: NativeWebRTCConfiguration(role: .subscriber)
        ),
        publisherPeerConnection: PeerConnectionCoordinator = PeerConnectionCoordinator(
            configuration: NativeWebRTCConfiguration(role: .publisher)
        )
    ) {
        self.options = options
        self.signalConnection = signalConnection
        self.subscriberPeerConnection = subscriberPeerConnection
        self.publisherPeerConnection = publisherPeerConnection

        let localParticipant = LocalParticipant(identity: "local")
        self.actor = RoomActor(localParticipant: localParticipant)
        self.snapshots = RoomSnapshotStore(localParticipant: localParticipant)

        let stream = AsyncStream<RoomEvent>.makeStream(bufferingPolicy: .bufferingNewest(100))
        self.events = stream.stream
        self.eventContinuation = stream.continuation

        configureLocalParticipant(localParticipant)
    }

    deinit {
        stopSignalLoop()
        Task { [signalConnection] in
            await signalConnection.close()
        }
        eventContinuation.finish()
    }

    public func connect(url: URL, token: String, connectOptions: ConnectOptions = .init()) async throws {
        LiveKitNativeLogging.log(.info, "Connecting room.")
        let context = RoomConnectionContext(serverURL: url, token: token, connectOptions: connectOptions)
        setConnectionContext(context)

        await transition(to: .connecting)

        do {
            try await connectSignalAndApplyInitialResponse(
                context: context,
                reconnect: connectOptions.reconnect,
                alternativeURLRedirects: max(0, connectOptions.maxAlternativeURLRedirects)
            )
            startSignalLoop()
            LiveKitNativeLogging.log(.info, "Room connected.")
        } catch {
            stopSignalLoop()
            await signalConnection.close()
            clearConnectionContext()
            await transition(to: .disconnected)
            LiveKitNativeLogging.log(.error, "Room connect failed: \(error.localizedDescription)")
            throw error
        }
    }

    public func disconnect() async {
        LiveKitNativeLogging.log(.info, "Disconnecting room.")

        stopSignalLoop()
        await sendLeaveIfConnected()
        await transition(to: .disconnecting)
        await signalConnection.close()
        await requestTracker.clear()
        clearConnectionContext()
        let result = await actor.disconnect()
        snapshots.replace(with: result.0)

        for event in result.1 {
            emit(event)
        }

        emit(.connectionStateChanged(.disconnected))
        LiveKitNativeLogging.log(.info, "Room disconnected.")
    }

    func applyRemoteParticipantSnapshots(_ participantSnapshots: [ParticipantSnapshot]) async {
        let result = await actor.applyParticipantUpdates(participantSnapshots)
        snapshots.replace(with: result.0)

        for event in result.1 {
            emit(event)
        }
    }

    private func transition(to connectionState: ConnectionState) async {
        let snapshot = await actor.setConnectionState(connectionState)
        snapshots.replace(with: snapshot)
        emit(.connectionStateChanged(connectionState))
    }

    private func applyInitialSignalResponse(_ response: Livekit_SignalResponse) async throws {
        guard case let .join(joinResponse)? = response.message else {
            throw LiveKitNativeError.invalidSignalFrame("Expected initial JoinResponse from LiveKit signaling.")
        }

        let result = await actor.applyJoin(RoomJoinSnapshot(joinResponse: joinResponse))
        snapshots.replace(with: result.0)
        configureLocalParticipant(result.0.localParticipant)
        emit(.connectionStateChanged(.connected))

        for event in result.1 {
            emit(event)
        }
    }

    private func startSignalLoop() {
        let task = Task { [weak self, signalConnection] in
            while !Task.isCancelled {
                do {
                    let response = try await signalConnection.receive(Livekit_SignalResponse.self)

                    guard let self else {
                        return
                    }

                    let shouldContinue = try await self.applySignalResponse(response)
                    if !shouldContinue {
                        return
                    }
                } catch {
                    if Task.isCancelled {
                        return
                    }

                    guard let self else {
                        return
                    }

                    await signalConnection.close()
                    await self.requestTracker.clear()
                    self.clearConnectionContext()
                    await self.transition(to: .disconnected)
                    LiveKitNativeLogging.log(.error, "Signal loop stopped: \(error.localizedDescription)")
                    return
                }
            }
        }

        replaceSignalLoopTask(with: task)
    }

    private func stopSignalLoop() {
        let task = signalLoopLock.withLock {
            let task = signalLoopTask
            signalLoopTask = nil
            return task
        }
        task?.cancel()
    }

    private func replaceSignalLoopTask(with task: Task<Void, Never>) {
        let previousTask = signalLoopLock.withLock {
            let previousTask = signalLoopTask
            signalLoopTask = task
            return previousTask
        }
        previousTask?.cancel()
    }

    private func applySignalResponse(_ response: Livekit_SignalResponse) async throws -> Bool {
        guard let message = response.message else {
            return true
        }

        switch message {
        case let .update(update):
            await applyRemoteParticipantSnapshots(update.participants.map { ParticipantSnapshot(participantInfo: $0) })
            return true
        case let .refreshToken(token):
            updateConnectionToken(token)
            emit(.tokenRefreshed(token))
            return true
        case let .offer(offer):
            try await answerSubscriberOffer(offer)
            return true
        case let .answer(answer):
            try handlePublisherAnswer(answer)
            return true
        case let .trickle(trickle):
            try handleTrickle(trickle)
            return true
        case let .speakersChanged(speakers):
            emit(.speakersChanged(speakers.speakers.map { SpeakerInfo(speakerInfo: $0) }))
            return true
        case let .connectionQuality(connectionQuality):
            emit(.connectionQualityChanged(connectionQuality.updates.map { ConnectionQualityInfo(qualityInfo: $0) }))
            return true
        case let .streamStateUpdate(streamStateUpdate):
            emit(.streamStateChanged(streamStateUpdate.streamStates.map { TrackStreamStateInfo(streamStateInfo: $0) }))
            return true
        case let .roomUpdate(roomUpdate):
            emit(.roomUpdated(RoomUpdateInfo(room: roomUpdate.room)))
            return true
        case let .subscribedQualityUpdate(subscribedQualityUpdate):
            emit(.subscribedQualityChanged(SubscribedQualityUpdateInfo(update: subscribedQualityUpdate)))
            return true
        case let .subscribedAudioCodecUpdate(subscribedAudioCodecUpdate):
            emit(.subscribedAudioCodecChanged(SubscribedAudioCodecUpdateInfo(update: subscribedAudioCodecUpdate)))
            return true
        case let .subscriptionPermissionUpdate(subscriptionPermissionUpdate):
            emit(.subscriptionPermissionChanged(SubscriptionPermissionUpdateInfo(update: subscriptionPermissionUpdate)))
            return true
        case let .subscriptionResponse(subscriptionResponse):
            emit(.subscriptionResponded(SubscriptionResponseInfo(response: subscriptionResponse)))
            return true
        case let .trackSubscribed(trackSubscribed):
            emit(.trackSubscribed(TrackSubscribedInfo(trackSID: trackSubscribed.trackSid)))
            return true
        case let .mediaSectionsRequirement(requirement):
            emit(.mediaSectionsRequirementChanged(MediaSectionsRequirementInfo(requirement: requirement)))
            return true
        case let .publishDataTrackResponse(response):
            await requestTracker.fulfill(response)
            emit(.dataTrackPublished(DataTrackInfo(info: response.info)))
            return true
        case let .unpublishDataTrackResponse(response):
            await requestTracker.fulfill(response)
            emit(.dataTrackUnpublished(DataTrackInfo(info: response.info)))
            return true
        case let .dataTrackSubscriberHandles(handles):
            emit(.dataTrackSubscriberHandlesChanged(DataTrackSubscriberHandlesInfo(handles: handles)))
            return true
        case let .roomMoved(roomMoved):
            await applyRoomMoved(roomMoved)
            return true
        case let .trackUnpublished(trackUnpublished):
            await applyTrackUnpublished(trackSID: trackUnpublished.trackSid)
            return true
        case let .trackPublished(trackPublished):
            await requestTracker.fulfill(trackPublished)
            return true
        case let .requestResponse(response):
            await requestTracker.fulfill(response)
            return true
        case let .leave(leave):
            return await handleLeaveRequest(leave)
        case .reconnect(_):
            await transition(to: .connected)
            return true
        default:
            return true
        }
    }

    private func applyTrackUnpublished(trackSID: String) async {
        let result = await actor.removeTrackPublication(sid: trackSID)
        snapshots.replace(with: result.0)

        for event in result.1 {
            emit(event)
        }
    }

    private func handleTrickle(_ trickle: Livekit_TrickleRequest) throws {
        let peerConnection: PeerConnectionCoordinator
        switch trickle.target {
        case .publisher:
            peerConnection = publisherPeerConnection
        case .subscriber:
            peerConnection = subscriberPeerConnection
        case .UNRECOGNIZED:
            return
        }

        try peerConnection.addRemoteICECandidate(
            candidateInitJSON: trickle.candidateInit,
            isFinal: trickle.final
        )
    }

    private func handlePublisherAnswer(_ answer: Livekit_SessionDescription) throws {
        try publisherPeerConnection.applyPublisherAnswer(type: answer.type, sdp: answer.sdp, id: answer.id)
    }

    private func applyRoomMoved(_ roomMoved: Livekit_RoomMovedResponse) async {
        if !roomMoved.token.isEmpty {
            updateConnectionToken(roomMoved.token)
        }

        let movedInfo = RoomMovedInfo(roomMovedResponse: roomMoved)
        var joinResponse = Livekit_JoinResponse()
        joinResponse.participant = roomMoved.participant
        joinResponse.otherParticipants = roomMoved.otherParticipants

        let result = await actor.applyJoin(RoomJoinSnapshot(joinResponse: joinResponse))
        snapshots.replace(with: result.0)
        configureLocalParticipant(result.0.localParticipant)
        emit(.roomMoved(movedInfo))

        for event in result.1 {
            emit(event)
        }
    }

    private func handleLeaveRequest(_ leave: Livekit_LeaveRequest) async -> Bool {
        if leave.canReconnect || leave.action == .resume || leave.action == .reconnect {
            await transition(to: .reconnecting)
            do {
                try await reconnectAfterLeave(leave)
                return true
            } catch {
                LiveKitNativeLogging.log(.error, "Reconnect failed: \(error.localizedDescription)")
                await signalConnection.close()
                await requestTracker.clear()
                clearConnectionContext()
                await transition(to: .disconnected)
                return false
            }
        } else {
            await signalConnection.close()
            await requestTracker.clear()
            clearConnectionContext()
            await transition(to: .disconnected)
            return false
        }
    }

    private func answerSubscriberOffer(_ offer: Livekit_SessionDescription) async throws {
        var answer = Livekit_SessionDescription()
        answer.type = "answer"
        answer.sdp = try subscriberPeerConnection.makeSubscriberAnswer(for: offer.sdp)
        answer.id = offer.id

        var request = Livekit_SignalRequest()
        request.answer = answer
        try await signalConnection.send(request)
    }

    private func configureLocalParticipant(_ localParticipant: LocalParticipant) {
        localParticipant.setCommandHandler(
            LocalParticipantCommandHandler(
                publishVideo: { [weak self] plan in
                    guard let self else {
                        throw LiveKitNativeError.notConnected
                    }
                    return try await self.sendAddTrack(
                        plan.addTrackRequest,
                        cid: plan.cid,
                        fallbackName: plan.name,
                        fallbackKind: .video,
                        fallbackSource: plan.source,
                        action: "publish video track"
                    )
                },
                publishAudio: { [weak self] plan in
                    guard let self else {
                        throw LiveKitNativeError.notConnected
                    }
                    return try await self.sendAddTrack(
                        plan.addTrackRequest,
                        cid: plan.cid,
                        fallbackName: plan.name,
                        fallbackKind: .audio,
                        fallbackSource: plan.source,
                        action: "publish audio track"
                    )
                },
                updateParticipant: { [weak self] update in
                    guard let self else {
                        throw LiveKitNativeError.notConnected
                    }
                    try await self.sendParticipantMetadataUpdate(update)
                },
                publishData: { [weak self] _ in
                    guard self != nil else {
                        throw LiveKitNativeError.notConnected
                    }
                    throw LiveKitNativeError.notImplemented("DTLS-backed SCTP data transport")
                },
                publishDataTrack: { [weak self] plan in
                    guard let self else {
                        throw LiveKitNativeError.notConnected
                    }
                    return try await self.sendPublishDataTrack(plan)
                },
                unpublishDataTrack: { [weak self] plan in
                    guard let self else {
                        throw LiveKitNativeError.notConnected
                    }
                    return try await self.sendUnpublishDataTrack(plan)
                },
                updateDataSubscription: { [weak self] plan in
                    guard let self else {
                        throw LiveKitNativeError.notConnected
                    }
                    try await self.sendUpdateDataSubscription(plan)
                }
            )
        )
    }

    private func sendAddTrack(
        _ addTrackRequest: Livekit_AddTrackRequest,
        cid: String,
        fallbackName: String,
        fallbackKind: TrackKind,
        fallbackSource: TrackSource,
        action: String
    ) async throws -> LocalPublishedTrack {
        var request = Livekit_SignalRequest()
        request.addTrack = addTrackRequest

        try await signalConnection.send(request)
        let response = try await requestTracker.waitForTrackPublished(cid: cid, action: action)
        return LocalPublishedTrack(
            trackInfo: response.track,
            fallbackCID: cid,
            fallbackName: fallbackName,
            fallbackKind: fallbackKind,
            fallbackSource: fallbackSource
        )
    }

    private func sendParticipantMetadataUpdate(_ update: ParticipantMetadataUpdate) async throws {
        let requestID = await requestTracker.nextID()
        let action = "participant metadata update"

        var metadataUpdate = Livekit_UpdateParticipantMetadata()
        metadataUpdate.requestID = requestID
        if let metadata = update.metadata {
            metadataUpdate.metadata = metadata
        }
        if let name = update.name {
            metadataUpdate.name = name
        }
        if let attributes = update.attributes {
            metadataUpdate.attributes = attributes
        }

        var request = Livekit_SignalRequest()
        request.updateMetadata = metadataUpdate

        try await signalConnection.send(request)
        let response = try await requestTracker.waitForResponse(requestID: requestID, action: action)
        try validateRequestResponse(response, action: action)
    }

    private func sendPublishDataTrack(_ plan: LocalDataTrackPublishPlan) async throws -> DataTrackInfo {
        let action = "publish data track"
        var request = Livekit_SignalRequest()
        request.publishDataTrackRequest = plan.publishRequest

        try await signalConnection.send(request)
        let response = try await requestTracker.waitForPublishDataTrack(
            publisherHandle: plan.pubHandle,
            action: action
        )
        return DataTrackInfo(info: response.info)
    }

    private func sendUnpublishDataTrack(_ plan: LocalDataTrackPublishPlan) async throws -> DataTrackInfo {
        let action = "unpublish data track"
        var request = Livekit_SignalRequest()
        request.unpublishDataTrackRequest = plan.unpublishRequest

        try await signalConnection.send(request)
        let response = try await requestTracker.waitForUnpublishDataTrack(
            publisherHandle: plan.pubHandle,
            action: action
        )
        return DataTrackInfo(info: response.info)
    }

    private func sendUpdateDataSubscription(_ plan: DataSubscriptionUpdatePlan) async throws {
        var update = Livekit_UpdateDataSubscription()
        update.updates = [plan.update]

        var request = Livekit_SignalRequest()
        request.updateDataSubscription = update
        try await signalConnection.send(request)
    }

    private func sendLeaveIfConnected() async {
        guard await signalConnection.state == .connected else {
            return
        }

        var leave = Livekit_LeaveRequest()
        leave.action = .disconnect
        leave.reason = .clientInitiated

        var request = Livekit_SignalRequest()
        request.leave = leave

        do {
            try await signalConnection.send(request)
        } catch {
            LiveKitNativeLogging.log(.warning, "Failed to send leave request before disconnect: \(error.localizedDescription)")
        }
    }

    private func validateRequestResponse(_ response: Livekit_RequestResponse, action: String) throws {
        switch response.reason {
        case .ok, .queued:
            return
        case .notAllowed:
            throw LiveKitNativeError.permissionDenied(action: action)
        default:
            throw LiveKitNativeError.requestFailed(
                action: action,
                reason: String(describing: response.reason),
                message: response.message
            )
        }
    }

    private func connectSignalAndApplyInitialResponse(
        context: RoomConnectionContext,
        reconnect: Bool,
        alternativeURLRedirects: Int
    ) async throws {
        var serverURL = context.serverURL
        var remainingRedirects = alternativeURLRedirects

        while true {
            let response = try await connectSignalAndReceiveInitialResponse(
                serverURL: serverURL,
                context: context,
                reconnect: reconnect
            )

            if case let .join(joinResponse)? = response.message, !joinResponse.alternativeURL.isEmpty {
                guard remainingRedirects > 0 else {
                    throw LiveKitNativeError.reconnectFailed("Alternative signal URL redirect limit exceeded.")
                }

                guard let alternativeURL = URL(string: joinResponse.alternativeURL) else {
                    throw LiveKitNativeError.invalidURL("Invalid alternative signal URL: \(joinResponse.alternativeURL)")
                }

                remainingRedirects -= 1
                serverURL = alternativeURL
                await signalConnection.close()
                LiveKitNativeLogging.log(.info, "Retrying signal connection with alternative URL.")
                continue
            }

            try await applyInitialOrReconnectResponse(response, reconnect: reconnect)
            return
        }
    }

    private func connectSignalAndReceiveInitialResponse(
        serverURL: URL,
        context: RoomConnectionContext,
        reconnect: Bool
    ) async throws -> Livekit_SignalResponse {
        let autoSubscribe = context.connectOptions.autoSubscribe ?? options.defaultAutoSubscribe
        let signalURL = try SignalURLBuilder(serverURL: serverURL).build(
            token: context.token,
            reconnect: reconnect,
            autoSubscribe: autoSubscribe,
            connectOptions: context.connectOptions
        )

        try await signalConnection.connect(to: signalURL)
        return try await signalConnection.receive(Livekit_SignalResponse.self)
    }

    private func applyInitialOrReconnectResponse(_ response: Livekit_SignalResponse, reconnect: Bool) async throws {
        switch response.message {
        case .join?:
            try await applyInitialSignalResponse(response)
        case .reconnect?:
            await transition(to: .connected)
        default:
            let expected = reconnect ? "ReconnectResponse or JoinResponse" : "JoinResponse"
            throw LiveKitNativeError.invalidSignalFrame("Expected initial \(expected) from LiveKit signaling.")
        }
    }

    private func reconnectAfterLeave(_ leave: Livekit_LeaveRequest) async throws {
        guard let context = currentConnectionContext() else {
            throw LiveKitNativeError.reconnectFailed("Missing previous connection context.")
        }

        let shouldResume = leave.action == .resume || (leave.canReconnect && leave.action != .reconnect)
        let attempts = max(1, context.connectOptions.maxReconnectAttempts)
        let delay = max(0, context.connectOptions.reconnectRetryDelayMilliseconds)
        var lastError: (any Error)?

        for attempt in 0..<attempts {
            if attempt > 0, delay > 0 {
                try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000)
            }

            do {
                await signalConnection.close()
                try await connectSignalAndApplyInitialResponse(
                    context: context,
                    reconnect: shouldResume,
                    alternativeURLRedirects: max(0, context.connectOptions.maxAlternativeURLRedirects)
                )
                return
            } catch {
                lastError = error
                LiveKitNativeLogging.log(.warning, "Reconnect attempt \(attempt + 1) failed: \(error.localizedDescription)")
            }
        }

        throw LiveKitNativeError.reconnectFailed(lastError?.localizedDescription ?? "No reconnect attempts were made.")
    }

    private func setConnectionContext(_ context: RoomConnectionContext) {
        connectionContextLock.withLock {
            connectionContext = context
        }
    }

    private func currentConnectionContext() -> RoomConnectionContext? {
        connectionContextLock.withLock {
            connectionContext
        }
    }

    private func clearConnectionContext() {
        connectionContextLock.withLock {
            connectionContext = nil
        }
    }

    private func updateConnectionToken(_ token: String) {
        connectionContextLock.withLock {
            guard var context = connectionContext else {
                return
            }

            context.token = token
            connectionContext = context
        }
    }

    private func emit(_ event: RoomEvent) {
        eventContinuation.yield(event)
        delegate?.room(self, didEmit: event)
    }
}

private struct RoomConnectionContext: Sendable {
    var serverURL: URL
    var token: String
    var connectOptions: ConnectOptions
}

private extension SpeakerInfo {
    init(speakerInfo: Livekit_SpeakerInfo) {
        self.init(
            participantSID: speakerInfo.sid,
            level: speakerInfo.level,
            isActive: speakerInfo.active
        )
    }
}

private extension RoomUpdateInfo {
    init(room: Livekit_Room) {
        self.init(
            sid: room.sid,
            name: room.name,
            metadata: room.metadata,
            participantCount: room.numParticipants,
            publisherCount: room.numPublishers,
            isRecording: room.activeRecording
        )
    }
}

private extension MediaSectionsRequirementInfo {
    init(requirement: Livekit_MediaSectionsRequirement) {
        self.init(
            audioCount: requirement.numAudios,
            videoCount: requirement.numVideos
        )
    }
}

private extension ConnectionQualityInfo {
    init(qualityInfo: Livekit_ConnectionQualityInfo) {
        self.init(
            participantSID: qualityInfo.participantSid,
            quality: ConnectionQuality(protocolQuality: qualityInfo.quality),
            score: qualityInfo.score
        )
    }
}

private extension ConnectionQuality {
    init(protocolQuality: Livekit_ConnectionQuality) {
        switch protocolQuality {
        case .poor:
            self = .poor
        case .good:
            self = .good
        case .excellent:
            self = .excellent
        case .lost:
            self = .lost
        case let .UNRECOGNIZED(rawValue):
            self = .unknown(rawValue)
        }
    }
}

private extension TrackStreamStateInfo {
    init(streamStateInfo: Livekit_StreamStateInfo) {
        self.init(
            participantSID: streamStateInfo.participantSid,
            trackSID: streamStateInfo.trackSid,
            state: TrackStreamState(protocolState: streamStateInfo.state)
        )
    }
}

private extension TrackStreamState {
    init(protocolState: Livekit_StreamState) {
        switch protocolState {
        case .active:
            self = .active
        case .paused:
            self = .paused
        case let .UNRECOGNIZED(rawValue):
            self = .unknown(rawValue)
        }
    }
}

private extension SubscribedQualityUpdateInfo {
    init(update: Livekit_SubscribedQualityUpdate) {
        self.init(
            trackSID: update.trackSid,
            qualities: update.subscribedQualities.map { SubscribedQualityInfo(quality: $0) },
            codecs: update.subscribedCodecs.map { SubscribedCodecInfo(codec: $0) }
        )
    }
}

private extension SubscribedCodecInfo {
    init(codec: Livekit_SubscribedCodec) {
        self.init(
            codec: codec.codec,
            qualities: codec.qualities.map { SubscribedQualityInfo(quality: $0) }
        )
    }
}

private extension SubscribedQualityInfo {
    init(quality: Livekit_SubscribedQuality) {
        self.init(
            quality: VideoQuality(protocolQuality: quality.quality),
            isEnabled: quality.enabled
        )
    }
}

private extension VideoQuality {
    init(protocolQuality: Livekit_VideoQuality) {
        switch protocolQuality {
        case .low:
            self = .low
        case .medium:
            self = .medium
        case .high:
            self = .high
        case .off:
            self = .off
        case let .UNRECOGNIZED(rawValue):
            self = .unknown(rawValue)
        }
    }
}

private extension SubscribedAudioCodecUpdateInfo {
    init(update: Livekit_SubscribedAudioCodecUpdate) {
        self.init(
            trackSID: update.trackSid,
            codecs: update.subscribedAudioCodecs.map { SubscribedAudioCodecInfo(codec: $0) }
        )
    }
}

private extension SubscribedAudioCodecInfo {
    init(codec: Livekit_SubscribedAudioCodec) {
        self.init(
            codec: codec.codec,
            isEnabled: codec.enabled
        )
    }
}

private extension SubscriptionPermissionUpdateInfo {
    init(update: Livekit_SubscriptionPermissionUpdate) {
        self.init(
            participantSID: update.participantSid,
            trackSID: update.trackSid,
            isAllowed: update.allowed
        )
    }
}

private extension SubscriptionResponseInfo {
    init(response: Livekit_SubscriptionResponse) {
        self.init(
            trackSID: response.trackSid,
            error: SubscriptionError(protocolError: response.err)
        )
    }
}

private extension SubscriptionError {
    init(protocolError: Livekit_SubscriptionError) {
        switch protocolError {
        case .seUnknown:
            self = .unknown
        case .seCodecUnsupported:
            self = .codecUnsupported
        case .seTrackNotfound:
            self = .trackNotFound
        case let .UNRECOGNIZED(rawValue):
            self = .unrecognized(rawValue)
        }
    }
}

private extension DataTrackInfo {
    init(info: Livekit_DataTrackInfo) {
        self.init(
            publisherHandle: info.pubHandle,
            sid: info.sid,
            name: info.name,
            encryption: DataTrackEncryption(protocolEncryption: info.encryption)
        )
    }
}

private extension DataTrackEncryption {
    init(protocolEncryption: Livekit_Encryption.TypeEnum) {
        switch protocolEncryption {
        case .none:
            self = .none
        case .gcm:
            self = .gcm
        case .custom:
            self = .custom
        case let .UNRECOGNIZED(rawValue):
            self = .unknown(rawValue)
        }
    }
}

private extension DataTrackSubscriberHandlesInfo {
    init(handles: Livekit_DataTrackSubscriberHandles) {
        self.init(
            handles: handles.subHandles
                .map { DataTrackSubscriberHandleInfo(handle: $0.key, publishedTrack: $0.value) }
                .sorted { $0.subscriberHandle < $1.subscriberHandle }
        )
    }
}

private extension DataTrackSubscriberHandleInfo {
    init(
        handle: UInt32,
        publishedTrack: Livekit_DataTrackSubscriberHandles.PublishedDataTrack
    ) {
        self.init(
            subscriberHandle: handle,
            publisherIdentity: publishedTrack.publisherIdentity,
            publisherSID: publishedTrack.publisherSid,
            trackSID: publishedTrack.trackSid
        )
    }
}

private extension RoomMovedInfo {
    init(roomMovedResponse: Livekit_RoomMovedResponse) {
        self.init(
            roomSID: roomMovedResponse.room.sid,
            roomName: roomMovedResponse.room.name,
            reconnectToken: roomMovedResponse.token,
            participantSID: roomMovedResponse.participant.sid,
            participantIdentity: roomMovedResponse.participant.identity,
            remoteParticipantIdentities: roomMovedResponse.otherParticipants.map(\.identity)
        )
    }
}
