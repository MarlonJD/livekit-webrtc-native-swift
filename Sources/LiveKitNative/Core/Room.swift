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
    private let snapshots: RoomSnapshotStore
    private let signalLoopLock = NSLock()
    private let eventContinuation: AsyncStream<RoomEvent>.Continuation
    private var signalLoopTask: Task<Void, Never>?

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
        )
    ) {
        self.options = options
        self.signalConnection = signalConnection
        self.subscriberPeerConnection = subscriberPeerConnection

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

        let autoSubscribe = connectOptions.autoSubscribe ?? options.defaultAutoSubscribe
        let signalURL = try SignalURLBuilder(serverURL: url).build(
            token: token,
            reconnect: connectOptions.reconnect,
            autoSubscribe: autoSubscribe,
            connectOptions: connectOptions
        )

        await transition(to: .connecting)

        do {
            try await signalConnection.connect(to: signalURL)
            let response = try await signalConnection.receive(Livekit_SignalResponse.self)
            try await applyInitialSignalResponse(response)
            startSignalLoop()
            LiveKitNativeLogging.log(.info, "Room connected.")
        } catch {
            stopSignalLoop()
            await signalConnection.close()
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
        case let .trickle(trickle):
            try handleTrickle(trickle)
            return true
        case let .trackUnpublished(trackUnpublished):
            await applyTrackUnpublished(trackSID: trackUnpublished.trackSid)
            return true
        case let .requestResponse(response):
            await requestTracker.fulfill(response)
            return true
        case let .leave(leave):
            await handleLeaveRequest(leave)
            return false
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

    private func handleLeaveRequest(_ leave: Livekit_LeaveRequest) async {
        if leave.canReconnect || leave.action == .resume || leave.action == .reconnect {
            await transition(to: .reconnecting)
        } else {
            await signalConnection.close()
            await transition(to: .disconnected)
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

    private func emit(_ event: RoomEvent) {
        eventContinuation.yield(event)
        delegate?.room(self, didEmit: event)
    }
}
