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

        guard joinResponse.alternativeURL.isEmpty else {
            throw LiveKitNativeError.notImplemented("Alternative signal URL retry")
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
        guard trickle.target == .subscriber else {
            return
        }

        try subscriberPeerConnection.addRemoteICECandidate(
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
