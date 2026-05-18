import Darwin
import Foundation
import LiveKitNativeProtocol
import LiveKitNativeWebRTC

struct RoomMediaStartupConfiguration: Sendable {
    var localCandidates: @Sendable ([ICEServer]) -> [ICECandidate]
    var iceRole: ICEAgentRole
    var tieBreaker: UInt64
    var nominationPolicy: ICEPairNominationPolicy
    var checker: any ICEConnectivityChecking
    var binder: DTLSSRTPMediaSessionBinder
    var consentFreshnessPolicy: ICEConsentFreshnessPolicy
    var consentFreshnessRetryPolicy: STUNBindingRetryPolicy

    init(
        localCandidates: @escaping @Sendable () -> [ICECandidate],
        iceRole: ICEAgentRole = .controlling,
        tieBreaker: UInt64 = UInt64.random(in: 1 ... UInt64.max),
        nominationPolicy: ICEPairNominationPolicy = .nominateFirstSuccessful,
        checker: any ICEConnectivityChecking = STUNICEConnectivityChecker(),
        binder: DTLSSRTPMediaSessionBinder,
        consentFreshnessPolicy: ICEConsentFreshnessPolicy = .standard,
        consentFreshnessRetryPolicy: STUNBindingRetryPolicy = .once
    ) {
        self.init(
            localCandidatesProvider: { _ in localCandidates() },
            iceRole: iceRole,
            tieBreaker: tieBreaker,
            nominationPolicy: nominationPolicy,
            checker: checker,
            binder: binder,
            consentFreshnessPolicy: consentFreshnessPolicy,
            consentFreshnessRetryPolicy: consentFreshnessRetryPolicy
        )
    }

    init(
        localCandidatesProvider: @escaping @Sendable ([ICEServer]) -> [ICECandidate],
        iceRole: ICEAgentRole = .controlling,
        tieBreaker: UInt64 = UInt64.random(in: 1 ... UInt64.max),
        nominationPolicy: ICEPairNominationPolicy = .nominateFirstSuccessful,
        checker: any ICEConnectivityChecking = STUNICEConnectivityChecker(),
        binder: DTLSSRTPMediaSessionBinder,
        consentFreshnessPolicy: ICEConsentFreshnessPolicy = .standard,
        consentFreshnessRetryPolicy: STUNBindingRetryPolicy = .once
    ) {
        self.localCandidates = localCandidatesProvider
        self.iceRole = iceRole
        self.tieBreaker = tieBreaker
        self.nominationPolicy = nominationPolicy
        self.checker = checker
        self.binder = binder
        self.consentFreshnessPolicy = consentFreshnessPolicy
        self.consentFreshnessRetryPolicy = consentFreshnessRetryPolicy
    }

    init(
        localCandidateSockets: [LocalICEUDPSocketCandidate],
        iceRole: ICEAgentRole = .controlling,
        tieBreaker: UInt64 = UInt64.random(in: 1 ... UInt64.max),
        nominationPolicy: ICEPairNominationPolicy = .nominateFirstSuccessful,
        handshaker: any DTLSSRTPHandshaking,
        consentFreshnessPolicy: ICEConsentFreshnessPolicy = .standard,
        consentFreshnessRetryPolicy: STUNBindingRetryPolicy = .once
    ) {
        let candidateStore = LocalICEUDPSocketCandidateStore(candidates: localCandidateSockets)
        self.init(
            localCandidatesProvider: { iceServers in
                let serverReflexiveCandidates = localCandidateSockets.flatMap {
                    $0.serverReflexiveCandidates(iceServers: iceServers)
                }
                let allCandidates = localCandidateSockets + serverReflexiveCandidates
                candidateStore.replace(with: allCandidates)
                return allCandidates.map(\.candidate)
            },
            iceRole: iceRole,
            tieBreaker: tieBreaker,
            nominationPolicy: nominationPolicy,
            checker: LocalICEUDPSocketConnectivityChecker(candidateStore: candidateStore),
            binder: DTLSSRTPMediaSessionBinder(
                datagramTransportFactory: LocalICEUDPSocketMediaDatagramTransportFactory(
                    candidateStore: candidateStore
                ),
                handshaker: handshaker
            ),
            consentFreshnessPolicy: consentFreshnessPolicy,
            consentFreshnessRetryPolicy: consentFreshnessRetryPolicy
        )
    }

    init(
        hostCandidateAddresses: [ICEInterfaceAddress] = ICEHostCandidateGatherer.localInterfaceAddresses(),
        bindAddress: String = "0.0.0.0",
        receiveTimeoutMilliseconds: Int = 1_000,
        iceRole: ICEAgentRole = .controlling,
        tieBreaker: UInt64 = UInt64.random(in: 1 ... UInt64.max),
        nominationPolicy: ICEPairNominationPolicy = .nominateFirstSuccessful,
        handshaker: any DTLSSRTPHandshaking,
        consentFreshnessPolicy: ICEConsentFreshnessPolicy = .standard,
        consentFreshnessRetryPolicy: STUNBindingRetryPolicy = .once
    ) throws {
        self.init(
            localCandidateSockets: try LocalICEUDPSocketCandidate.hostCandidates(
                from: hostCandidateAddresses,
                bindAddress: bindAddress,
                receiveTimeoutMilliseconds: receiveTimeoutMilliseconds
            ),
            iceRole: iceRole,
            tieBreaker: tieBreaker,
            nominationPolicy: nominationPolicy,
            handshaker: handshaker,
            consentFreshnessPolicy: consentFreshnessPolicy,
            consentFreshnessRetryPolicy: consentFreshnessRetryPolicy
        )
    }

    static func defaultLive(
        hostCandidateAddresses: @escaping @Sendable () -> [ICEInterfaceAddress] = {
            ICEHostCandidateGatherer.localInterfaceAddresses()
        },
        bindAddress: String = "0.0.0.0",
        receiveTimeoutMilliseconds: Int = 1_000,
        iceRole: ICEAgentRole = .controlling,
        tieBreaker: UInt64 = UInt64.random(in: 1 ... UInt64.max),
        nominationPolicy: ICEPairNominationPolicy = .nominateFirstSuccessful,
        handshaker: any DTLSSRTPHandshaking = OpenSSLDTLSSRTPHandshaker(),
        consentFreshnessPolicy: ICEConsentFreshnessPolicy = .standard,
        consentFreshnessRetryPolicy: STUNBindingRetryPolicy = .once
    ) -> Self {
        let candidateStore = LocalICEUDPSocketCandidateStore(candidates: [])
        let candidateProvider = DefaultRoomMediaStartupLocalCandidateProvider(
            candidateStore: candidateStore,
            hostCandidateAddresses: hostCandidateAddresses,
            bindAddress: bindAddress,
            receiveTimeoutMilliseconds: receiveTimeoutMilliseconds
        )

        return Self(
            localCandidatesProvider: { iceServers in
                candidateProvider.localCandidates(iceServers: iceServers)
            },
            iceRole: iceRole,
            tieBreaker: tieBreaker,
            nominationPolicy: nominationPolicy,
            checker: LocalICEUDPSocketConnectivityChecker(candidateStore: candidateStore),
            binder: DTLSSRTPMediaSessionBinder(
                datagramTransportFactory: LocalICEUDPSocketMediaDatagramTransportFactory(
                    candidateStore: candidateStore
                ),
                handshaker: handshaker
            ),
            consentFreshnessPolicy: consentFreshnessPolicy,
            consentFreshnessRetryPolicy: consentFreshnessRetryPolicy
        )
    }
}

typealias RoomPublisherMediaStartupConfiguration = RoomMediaStartupConfiguration
typealias RoomSubscriberMediaStartupConfiguration = RoomMediaStartupConfiguration

private final class DefaultRoomMediaStartupLocalCandidateProvider: @unchecked Sendable {
    private let candidateStore: LocalICEUDPSocketCandidateStore
    private let hostCandidateAddresses: @Sendable () -> [ICEInterfaceAddress]
    private let bindAddress: String
    private let receiveTimeoutMilliseconds: Int
    private let lock = NSLock()
    private var hostCandidates: [LocalICEUDPSocketCandidate]?

    init(
        candidateStore: LocalICEUDPSocketCandidateStore,
        hostCandidateAddresses: @escaping @Sendable () -> [ICEInterfaceAddress],
        bindAddress: String,
        receiveTimeoutMilliseconds: Int
    ) {
        self.candidateStore = candidateStore
        self.hostCandidateAddresses = hostCandidateAddresses
        self.bindAddress = bindAddress
        self.receiveTimeoutMilliseconds = receiveTimeoutMilliseconds
    }

    func localCandidates(iceServers: [ICEServer]) -> [ICECandidate] {
        lock.withLock {
            let hostCandidates = gatherHostCandidatesIfNeeded()
            let serverReflexiveCandidates = hostCandidates.flatMap {
                $0.serverReflexiveCandidates(iceServers: iceServers)
            }
            let candidates = hostCandidates + serverReflexiveCandidates
            candidateStore.replace(with: candidates)
            return candidates.map(\.candidate)
        }
    }

    private func gatherHostCandidatesIfNeeded() -> [LocalICEUDPSocketCandidate] {
        if let hostCandidates {
            return hostCandidates
        }

        do {
            let gathered = try LocalICEUDPSocketCandidate.hostCandidates(
                from: hostCandidateAddresses(),
                bindAddress: bindAddress,
                receiveTimeoutMilliseconds: receiveTimeoutMilliseconds
            )
            hostCandidates = gathered
            return gathered
        } catch {
            LiveKitNativeLogging.log(.error, "Default ICE host candidate gathering failed: \(error.localizedDescription)")
            hostCandidates = []
            return []
        }
    }
}

public final class Room: @unchecked Sendable {
    public weak var delegate: (any RoomDelegate)?
    public let events: AsyncStream<RoomEvent>

    private let options: RoomOptions
    private let actor: RoomActor
    private let signalConnection: SignalConnection
    private let requestTracker = SignalRequestTracker()
    private let subscriberPeerConnection: PeerConnectionCoordinator
    private let publisherPeerConnection: PeerConnectionCoordinator
    private let subscriberMediaStartupConfiguration: RoomSubscriberMediaStartupConfiguration?
    private let publisherMediaStartupConfiguration: RoomPublisherMediaStartupConfiguration?
    private let snapshots: RoomSnapshotStore
    private let signalLoopLock = NSLock()
    private let connectionContextLock = NSLock()
    private let publisherOfferLock = NSLock()
    private let publisherRTPSenderLock = NSLock()
    private let subscriberMediaStartupLock = NSLock()
    private let publisherMediaStartupLock = NSLock()
    private let reconnectSyncStateLock = NSLock()
    private let reconnectSessionDescriptionLock = NSLock()
    private let eventContinuation: AsyncStream<RoomEvent>.Continuation
    private var signalLoopTask: Task<Void, Never>?
    private var connectionContext: RoomConnectionContext?
    private var publisherOfferTracks: [PublisherSDPOfferTrack] = []
    private var nextPublisherOfferID: UInt32 = 1
    private var publisherAudioRTPSendersBySID: [String: PublisherAudioRTPSender] = [:]
    private var publisherVideoRTPSendersBySID: [String: PublisherVideoRTPSender] = [:]
    private var publisherRTPSenderSIDByCID: [String: String] = [:]
    private var subscriberMediaStartupStarted = false
    private var subscriberMediaStartupTask: Task<Void, Never>?
    private var subscriberMediaStartupResult: PeerConnectionMediaStartupResult?
    private var subscriberMediaStartupError: (any Error)?
    private var subscriberICEConsentFreshnessTask: Task<Void, Never>?
    private var subscriberRTCPHandler: (@Sendable (RTCPPacket) async -> Void)?
    private var subscriberRTCPReceiveTask: Task<Void, Never>?
    private var subscriberRTCPReceiveLoopID: UInt64 = 0
    private var subscriberLocalCandidatesGathered = false
    private var subscriberLocalCandidates: [ICECandidate] = []
    private var publisherMediaStartupStarted = false
    private var publisherMediaStartupTask: Task<Void, Never>?
    private var publisherMediaStartupResult: PeerConnectionMediaStartupResult?
    private var publisherMediaStartupError: (any Error)?
    private var publisherICEConsentFreshnessTask: Task<Void, Never>?
    private var publisherRTCPHandler: (@Sendable (RTCPPacket) async -> Void)?
    private var publisherRTCPReceiveTask: Task<Void, Never>?
    private var publisherRTCPReceiveLoopID: UInt64 = 0
    private var publisherLocalCandidatesGathered = false
    private var publisherLocalCandidates: [ICECandidate] = []
    private var reconnectSubscribedTrackSIDs: Set<String> = []
    private var reconnectDisabledTrackSIDs: Set<String> = []
    private var reconnectSubscriberAnswer: Livekit_SessionDescription?
    private var reconnectPublisherOffer: Livekit_SessionDescription?

    public var localParticipant: LocalParticipant {
        snapshots.localParticipant
    }

    public var remoteParticipants: [RemoteParticipant] {
        snapshots.remoteParticipants
    }

    public var connectionState: ConnectionState {
        snapshots.connectionState
    }

    public var mediaSectionsRequirement: MediaSectionsRequirementInfo? {
        snapshots.mediaSectionsRequirement
    }

    public var dataTrackSubscriberHandles: DataTrackSubscriberHandlesInfo? {
        snapshots.dataTrackSubscriberHandles
    }

    var lastPublisherMediaStartupResult: PeerConnectionMediaStartupResult? {
        publisherMediaStartupLock.withLock {
            publisherMediaStartupResult
        }
    }

    var lastPublisherMediaStartupError: (any Error)? {
        publisherMediaStartupLock.withLock {
            publisherMediaStartupError
        }
    }

    func publisherAudioRTPSender(sid: String) -> PublisherAudioRTPSender? {
        publisherRTPSenderLock.withLock {
            publisherAudioRTPSendersBySID[sid]
        }
    }

    func publisherVideoRTPSender(sid: String) -> PublisherVideoRTPSender? {
        publisherRTPSenderLock.withLock {
            publisherVideoRTPSendersBySID[sid]
        }
    }

    func publisherRTPSenderSID(forCID cid: String) -> String? {
        publisherRTPSenderLock.withLock {
            publisherRTPSenderSIDByCID[cid]
        }
    }

    var lastSubscriberMediaStartupResult: PeerConnectionMediaStartupResult? {
        subscriberMediaStartupLock.withLock {
            subscriberMediaStartupResult
        }
    }

    var lastSubscriberMediaStartupError: (any Error)? {
        subscriberMediaStartupLock.withLock {
            subscriberMediaStartupError
        }
    }

    func waitForPublisherMediaStartup() async {
        let task = publisherMediaStartupLock.withLock {
            publisherMediaStartupTask
        }
        await task?.value
    }

    var isPublisherRTCPReceiveLoopActive: Bool {
        publisherMediaStartupLock.withLock {
            publisherRTCPReceiveTask != nil
        }
    }

    func setPublisherRTCPHandler(_ handler: (@Sendable (RTCPPacket) async -> Void)?) {
        let taskToCancel = publisherMediaStartupLock.withLock {
            publisherRTCPHandler = handler
            guard handler == nil else {
                return nil as Task<Void, Never>?
            }

            let task = publisherRTCPReceiveTask
            publisherRTCPReceiveTask = nil
            return task
        }

        taskToCancel?.cancel()

        if handler != nil {
            startPublisherRTCPReceiveLoopIfReady()
        }
    }

    func waitForSubscriberMediaStartup() async {
        let task = subscriberMediaStartupLock.withLock {
            subscriberMediaStartupTask
        }
        await task?.value
    }

    var isSubscriberRTCPReceiveLoopActive: Bool {
        subscriberMediaStartupLock.withLock {
            subscriberRTCPReceiveTask != nil
        }
    }

    func setSubscriberRTCPHandler(_ handler: (@Sendable (RTCPPacket) async -> Void)?) {
        let taskToCancel = subscriberMediaStartupLock.withLock {
            subscriberRTCPHandler = handler
            guard handler == nil else {
                return nil as Task<Void, Never>?
            }

            let task = subscriberRTCPReceiveTask
            subscriberRTCPReceiveTask = nil
            return task
        }

        taskToCancel?.cancel()

        if handler != nil {
            startSubscriberRTCPReceiveLoopIfReady()
        }
    }

    func sendPublisherRTP(_ packet: RTPPacket) async throws {
        let transport = publisherMediaStartupLock.withLock {
            publisherMediaStartupResult?.transport
        }

        guard let transport else {
            throw LiveKitNativeError.requestFailed(
                action: "send RTP",
                reason: "publisherMediaTransportUnavailable",
                message: "Publisher secure media transport is not started."
            )
        }

        try await transport.sendRTP(packet)
    }

    func sendPublisherRTCP(_ packet: RTCPPacket) async throws {
        let transport = publisherMediaStartupLock.withLock {
            publisherMediaStartupResult?.transport
        }

        guard let transport else {
            throw LiveKitNativeError.requestFailed(
                action: "send RTCP",
                reason: "publisherMediaTransportUnavailable",
                message: "Publisher secure media transport is not started."
            )
        }

        try await transport.sendRTCP(packet)
    }

    func sendSubscriberRTCP(_ packet: RTCPPacket) async throws {
        let transport = subscriberMediaStartupLock.withLock {
            subscriberMediaStartupResult?.transport
        }

        guard let transport else {
            throw LiveKitNativeError.requestFailed(
                action: "send RTCP",
                reason: "subscriberMediaTransportUnavailable",
                message: "Subscriber secure media transport is not started."
            )
        }

        try await transport.sendRTCP(packet)
    }

    @discardableResult
    func sendSubscriberRTCPFeedback(
        senderSSRC: UInt32,
        mediaSSRC: UInt32,
        signals: [SubscribeRTCPFeedbackSignal]
    ) async throws -> [RTCPPacket] {
        let packets = SubscribeRTCPFeedbackPlanner().feedbackPackets(
            senderSSRC: senderSSRC,
            mediaSSRC: mediaSSRC,
            signals: signals
        )

        for packet in packets {
            try await sendSubscriberRTCP(packet)
        }

        return packets
    }

    @discardableResult
    func sendSubscriberRTCPFeedback(
        senderSSRC: UInt32,
        mediaSSRC: UInt32,
        missingSequenceNumbers: [UInt16] = [],
        requestsKeyFrame: Bool = false
    ) async throws -> [RTCPPacket] {
        let packets = SubscribeRTCPFeedbackPlanner().feedbackPackets(
            senderSSRC: senderSSRC,
            mediaSSRC: mediaSSRC,
            missingSequenceNumbers: missingSequenceNumbers,
            requestsKeyFrame: requestsKeyFrame
        )

        for packet in packets {
            try await sendSubscriberRTCP(packet)
        }

        return packets
    }

    @discardableResult
    func sendPublisherAudio(_ packet: OpusPacket, sid: String) async throws -> RTPPacket {
        guard let sender = publisherAudioRTPSender(sid: sid) else {
            throw LiveKitNativeError.requestFailed(
                action: "send publisher audio",
                reason: "publisherAudioRTPSenderUnavailable",
                message: "No publisher audio RTP sender is registered for SID \(sid)."
            )
        }

        return try await sender.send(packet)
    }

    @discardableResult
    func sendPublisherVideo(_ frame: H264EncodedFrame, sid: String) async throws -> [RTPPacket] {
        guard let sender = publisherVideoRTPSender(sid: sid) else {
            throw LiveKitNativeError.requestFailed(
                action: "send publisher video",
                reason: "publisherVideoRTPSenderUnavailable",
                message: "No publisher video RTP sender is registered for SID \(sid)."
            )
        }

        return try await sender.send(frame)
    }

    public convenience init(options: RoomOptions = .init()) {
        let subscriberDTLSIdentity = DTLSSRTPIdentity.generated()
        let publisherDTLSIdentity = DTLSSRTPIdentity.generated()
        self.init(
            options: options,
            signalConnection: SignalConnection(),
            subscriberPeerConnection: PeerConnectionCoordinator(
                configuration: NativeWebRTCConfiguration(
                    role: .subscriber,
                    dtlsIdentity: subscriberDTLSIdentity
                )
            ),
            publisherPeerConnection: PeerConnectionCoordinator(
                configuration: NativeWebRTCConfiguration(
                    role: .publisher,
                    dtlsIdentity: publisherDTLSIdentity
                )
            ),
            subscriberMediaStartupConfiguration: .defaultLive(
                handshaker: OpenSSLDTLSSRTPHandshaker(identity: subscriberDTLSIdentity)
            ),
            publisherMediaStartupConfiguration: .defaultLive(
                handshaker: OpenSSLDTLSSRTPHandshaker(identity: publisherDTLSIdentity)
            )
        )
    }

    init(
        options: RoomOptions = .init(),
        signalConnection: SignalConnection,
        subscriberPeerConnection: PeerConnectionCoordinator = PeerConnectionCoordinator(
            configuration: NativeWebRTCConfiguration(role: .subscriber)
        ),
        publisherPeerConnection: PeerConnectionCoordinator = PeerConnectionCoordinator(
            configuration: NativeWebRTCConfiguration(role: .publisher)
        ),
        subscriberMediaStartupConfiguration: RoomSubscriberMediaStartupConfiguration? = nil,
        publisherMediaStartupConfiguration: RoomPublisherMediaStartupConfiguration? = nil
    ) {
        self.options = options
        self.signalConnection = signalConnection
        self.subscriberPeerConnection = subscriberPeerConnection
        self.publisherPeerConnection = publisherPeerConnection
        self.subscriberMediaStartupConfiguration = subscriberMediaStartupConfiguration
        self.publisherMediaStartupConfiguration = publisherMediaStartupConfiguration

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
        closeMediaStartupTransportDetached(clearSubscriberMediaStartupState())
        closeMediaStartupTransportDetached(clearPublisherMediaStartupState())
        Task { [signalConnection] in
            await signalConnection.close()
        }
        eventContinuation.finish()
    }

    public func connect(url: URL, token: String, connectOptions: ConnectOptions = .init()) async throws {
        LiveKitNativeLogging.log(.info, "Connecting room.")
        let context = RoomConnectionContext(serverURL: url, token: token, connectOptions: connectOptions)
        setConnectionContext(context)
        resetPeerConnectionNegotiationState()

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
            resetPeerConnectionNegotiationState(restartICE: true)
            clearLocalParticipantCommandHandler()
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
        resetPeerConnectionNegotiationState(restartICE: true)
        clearReconnectSessionDescriptionState()
        let result = await actor.disconnect()
        snapshots.replace(with: result.0)
        clearLocalParticipantCommandHandler()

        for event in result.1 {
            emit(event)
        }

        emit(.connectionStateChanged(.disconnected))
        LiveKitNativeLogging.log(.info, "Room disconnected.")
    }

    public func updateSubscription(trackSIDs: [String], subscribe: Bool) async throws {
        guard !trackSIDs.isEmpty else {
            return
        }

        var update = Livekit_UpdateSubscription()
        update.trackSids = trackSIDs
        update.subscribe = subscribe

        var request = Livekit_SignalRequest()
        request.subscription = update
        try await signalConnection.send(request)
        storeReconnectSubscriptionUpdate(trackSIDs: trackSIDs, subscribe: subscribe)
    }

    public func updateTrackSettings(
        trackSIDs: [String],
        disabled: Bool = false,
        quality: VideoQuality = .low,
        width: UInt32 = 0,
        height: UInt32 = 0,
        fps: UInt32 = 0,
        priority: UInt32 = 0
    ) async throws {
        guard !trackSIDs.isEmpty else {
            return
        }

        var settings = Livekit_UpdateTrackSettings()
        settings.trackSids = trackSIDs
        settings.disabled = disabled
        settings.quality = quality.protocolQuality
        settings.width = width
        settings.height = height
        settings.fps = fps
        settings.priority = priority

        var request = Livekit_SignalRequest()
        request.trackSetting = settings
        try await signalConnection.send(request)
        storeReconnectTrackSettingsUpdate(trackSIDs: trackSIDs, disabled: disabled)
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

        resetPeerConnectionNegotiationState(restartICE: true)
        clearReconnectSessionDescriptionState()
        applyICEServers(joinResponse.iceServers)
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
                    self.resetPeerConnectionNegotiationState(restartICE: true)
                    self.clearLocalParticipantCommandHandler()
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
            try await handlePublisherAnswer(answer)
            return true
        case let .trickle(trickle):
            try await handleTrickle(trickle)
            return true
        case let .mute(mute):
            await applyTrackMute(mute)
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
            await applyMediaSectionsRequirement(requirement)
            return true
        case let .publishDataTrackResponse(response):
            let dataTrack = DataTrackInfo(info: response.info)
            localParticipant.applyDataTrackPublication(dataTrack)
            await requestTracker.fulfill(response)
            emit(.dataTrackPublished(dataTrack))
            return true
        case let .unpublishDataTrackResponse(response):
            let dataTrack = DataTrackInfo(info: response.info)
            localParticipant.removeDataTrackPublication(publisherHandle: dataTrack.publisherHandle)
            await requestTracker.fulfill(response)
            emit(.dataTrackUnpublished(dataTrack))
            return true
        case let .dataTrackSubscriberHandles(handles):
            await applyDataTrackSubscriberHandles(handles)
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
        if localParticipant.removeLocalTrackPublication(sid: trackSID) != nil {
            removePublisherRTPSender(sid: trackSID)
            let removal = removePublisherOfferTrack(sid: trackSID)
            if removal.removed != nil {
                clearReconnectPublisherOffer()
                if removal.tracks.isEmpty {
                    await closeMediaStartupTransport(clearPublisherMediaStartupState())
                }
            }
        }

        let result = await actor.removeTrackPublication(sid: trackSID)
        snapshots.replace(with: result.0)

        for event in result.1 {
            emit(event)
        }
    }

    private func applyTrackMute(_ mute: Livekit_MuteTrackRequest) async {
        let result = await actor.applyTrackMute(sid: mute.sid, muted: mute.muted)
        snapshots.replace(with: result.0)

        for event in result.1 {
            emit(event)
        }
    }

    private func applyMediaSectionsRequirement(_ requirement: Livekit_MediaSectionsRequirement) async {
        let result = await actor.applyMediaSectionsRequirement(
            MediaSectionsRequirementInfo(requirement: requirement)
        )
        snapshots.replace(with: result.0)

        for event in result.1 {
            emit(event)
        }
    }

    private func applyDataTrackSubscriberHandles(_ handles: Livekit_DataTrackSubscriberHandles) async {
        let result = await actor.applyDataTrackSubscriberHandles(
            DataTrackSubscriberHandlesInfo(handles: handles)
        )
        snapshots.replace(with: result.0)

        for event in result.1 {
            emit(event)
        }
    }

    private func handleTrickle(_ trickle: Livekit_TrickleRequest) async throws {
        let peerConnection: PeerConnectionCoordinator
        let isPublisherTarget: Bool
        switch trickle.target {
        case .publisher:
            peerConnection = publisherPeerConnection
            isPublisherTarget = true
        case .subscriber:
            peerConnection = subscriberPeerConnection
            isPublisherTarget = false
        case .UNRECOGNIZED:
            return
        }

        try peerConnection.addRemoteICECandidate(
            candidateInitJSON: trickle.candidateInit,
            isFinal: trickle.final
        )

        if isPublisherTarget {
            startPublisherMediaTransportIfReady()
        } else {
            startSubscriberMediaTransportIfReady()
        }
    }

    private func handlePublisherAnswer(_ answer: Livekit_SessionDescription) async throws {
        try publisherPeerConnection.applyPublisherAnswer(type: answer.type, sdp: answer.sdp, id: answer.id)
        startPublisherMediaTransportIfReady()
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
                resetPeerConnectionNegotiationState(restartICE: true)
                clearLocalParticipantCommandHandler()
                await transition(to: .disconnected)
                return false
            }
        } else {
            await signalConnection.close()
            await requestTracker.clear()
            clearConnectionContext()
            resetPeerConnectionNegotiationState(restartICE: true)
            clearLocalParticipantCommandHandler()
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
        storeReconnectSubscriberAnswer(answer)
        try await sendSubscriberLocalICETrickleCandidates()
        startSubscriberMediaTransportIfReady()
    }

    private func configureLocalParticipant(_ localParticipant: LocalParticipant) {
        localParticipant.setCommandHandler(
            LocalParticipantCommandHandler(
                publishVideo: { [weak self] plan in
                    guard let self else {
                        throw LiveKitNativeError.notConnected
                    }
                    let publishedTrack = try await self.sendAddTrack(
                        plan.addTrackRequest,
                        cid: plan.cid,
                        fallbackName: plan.name,
                        fallbackKind: .video,
                        fallbackSource: plan.source,
                        offerTrack: plan.publisherOfferTrack,
                        action: "publish video track"
                    )
                    self.storePublisherVideoRTPSender(
                        self.makePublisherRTPBridge().videoSender(for: plan),
                        sid: publishedTrack.sid,
                        cid: plan.cid
                    )
                    return publishedTrack
                },
                publishAudio: { [weak self] plan in
                    guard let self else {
                        throw LiveKitNativeError.notConnected
                    }
                    let publishedTrack = try await self.sendAddTrack(
                        plan.addTrackRequest,
                        cid: plan.cid,
                        fallbackName: plan.name,
                        fallbackKind: .audio,
                        fallbackSource: plan.source,
                        offerTrack: plan.publisherOfferTrack,
                        action: "publish audio track"
                    )
                    self.storePublisherAudioRTPSender(
                        self.makePublisherRTPBridge().audioSender(for: plan),
                        sid: publishedTrack.sid,
                        cid: plan.cid
                    )
                    return publishedTrack
                },
                unpublishTrack: { [weak self] plan in
                    guard let self else {
                        throw LiveKitNativeError.notConnected
                    }
                    try await self.sendUnpublishTrack(plan)
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
                },
                updateTrackMute: { [weak self] plan in
                    guard let self else {
                        throw LiveKitNativeError.notConnected
                    }
                    try await self.sendTrackMute(plan)
                },
                updateSubscriptionPermissions: { [weak self] plan in
                    guard let self else {
                        throw LiveKitNativeError.notConnected
                    }
                    try await self.sendSubscriptionPermissions(plan)
                },
                updateAudioTrack: { [weak self] plan in
                    guard let self else {
                        throw LiveKitNativeError.notConnected
                    }
                    try await self.sendUpdateAudioTrack(plan)
                },
                updateVideoTrack: { [weak self] plan in
                    guard let self else {
                        throw LiveKitNativeError.notConnected
                    }
                    try await self.sendUpdateVideoTrack(plan)
                }
            )
        )
    }

    private func clearLocalParticipantCommandHandler() {
        snapshots.localParticipant.setCommandHandler(nil)
    }

    private func sendAddTrack(
        _ addTrackRequest: Livekit_AddTrackRequest,
        cid: String,
        fallbackName: String,
        fallbackKind: TrackKind,
        fallbackSource: TrackSource,
        offerTrack: PublisherSDPOfferTrack? = nil,
        action: String
    ) async throws -> LocalPublishedTrack {
        var request = Livekit_SignalRequest()
        request.addTrack = addTrackRequest

        try await signalConnection.send(request)
        let response = try await requestTracker.waitForTrackPublished(
            cid: cid,
            action: action,
            request: .addTrack(addTrackRequest)
        )
        let publishedTrack = LocalPublishedTrack(
            trackInfo: response.track,
            fallbackCID: cid,
            fallbackName: fallbackName,
            fallbackKind: fallbackKind,
            fallbackSource: fallbackSource
        )

        if let offerTrack {
            let offerTrack = offerTrack.withTrackID(publishedTrack.sid)
            let tracks = addPublisherOfferTrack(offerTrack)
            do {
                try await sendPublisherOffer(for: tracks)
            } catch {
                _ = removePublisherOfferTrack(sid: offerTrack.trackID)
                throw error
            }
        }

        return publishedTrack
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
            action: action,
            request: .publishDataTrack(plan.publishRequest)
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
            action: action,
            request: .unpublishDataTrack(plan.unpublishRequest)
        )
        return DataTrackInfo(info: response.info)
    }

    private func sendUnpublishTrack(_ plan: LocalTrackUnpublishPlan) async throws {
        let action = "unpublish track"
        let muteRequest = plan.muteRequest

        var request = Livekit_SignalRequest()
        request.mute = muteRequest
        try await signalConnection.send(request)

        let response = try await requestTracker.waitForResponse(
            matching: .mute(muteRequest),
            action: action
        )
        try validateRequestResponse(response, action: action)

        let removal = removePublisherOfferTrack(sid: plan.sid)
        guard removal.removed != nil else {
            if removal.tracks.isEmpty {
                clearReconnectPublisherOffer()
                await closeMediaStartupTransport(clearPublisherMediaStartupState())
            }
            removePublisherRTPSender(sid: plan.sid)
            return
        }

        guard !removal.tracks.isEmpty else {
            clearReconnectPublisherOffer()
            await closeMediaStartupTransport(clearPublisherMediaStartupState())
            removePublisherRTPSender(sid: plan.sid)
            return
        }

        do {
            try await sendPublisherOffer(for: removal.tracks)
        } catch {
            if let removed = removal.removed {
                _ = addPublisherOfferTrack(removed)
            }
            throw error
        }
        removePublisherRTPSender(sid: plan.sid)
    }

    private func sendPublisherOffer(for tracks: [PublisherSDPOfferTrack]) async throws {
        guard !tracks.isEmpty else {
            return
        }

        var offer = Livekit_SessionDescription()
        offer.type = "offer"
        offer.id = nextPublisherOfferIdentifier()
        offer.sdp = try publisherPeerConnection.makePublisherOffer(for: tracks)

        var request = Livekit_SignalRequest()
        request.offer = offer
        try await signalConnection.send(request)
        storeReconnectPublisherOffer(offer)
        try await sendPublisherLocalICETrickleCandidates()
    }

    private func sendUpdateDataSubscription(_ plan: DataSubscriptionUpdatePlan) async throws {
        var update = Livekit_UpdateDataSubscription()
        update.updates = [plan.update]

        var request = Livekit_SignalRequest()
        request.updateDataSubscription = update
        try await signalConnection.send(request)
    }

    private func sendSubscriptionPermissions(_ plan: LocalTrackSubscriptionPermissionPlan) async throws {
        var request = Livekit_SignalRequest()
        request.subscriptionPermission = plan.subscriptionPermission
        try await signalConnection.send(request)
    }

    private func sendUpdateAudioTrack(_ plan: LocalAudioTrackUpdatePlan) async throws {
        let action = "update audio track"
        let updateRequest = plan.updateRequest

        var request = Livekit_SignalRequest()
        request.updateAudioTrack = updateRequest
        try await signalConnection.send(request)

        let response = try await requestTracker.waitForResponse(
            matching: .updateAudioTrack(updateRequest),
            action: action
        )
        try validateRequestResponse(response, action: action)
    }

    private func sendUpdateVideoTrack(_ plan: LocalVideoTrackUpdatePlan) async throws {
        let action = "update video track"
        let updateRequest = plan.updateRequest

        var request = Livekit_SignalRequest()
        request.updateVideoTrack = updateRequest
        try await signalConnection.send(request)

        let response = try await requestTracker.waitForResponse(
            matching: .updateVideoTrack(updateRequest),
            action: action
        )
        try validateRequestResponse(response, action: action)
    }

    private func sendTrackMute(_ plan: LocalTrackMutePlan) async throws {
        let action = "mute track"
        let muteRequest = plan.muteRequest

        var request = Livekit_SignalRequest()
        request.mute = muteRequest

        try await signalConnection.send(request)

        let response = try await requestTracker.waitForResponse(
            matching: .mute(muteRequest),
            action: action
        )
        try validateRequestResponse(response, action: action)

        let result = await actor.applyTrackMute(sid: plan.sid, muted: plan.muted)
        snapshots.replace(with: result.0)

        for event in result.1 {
            emit(event)
        }
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
        case let .reconnect(reconnectResponse)?:
            resetPeerConnectionNegotiationState(restartICE: true, preservePublisherOfferState: true)
            applyICEServers(reconnectResponse.iceServers)
            try await sendReconnectSyncStateIfNeeded()
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

    private func applyICEServers(_ iceServers: [Livekit_ICEServer]) {
        let nativeICEServers = iceServers.map(ICEServer.init(protocolServer:))
        subscriberPeerConnection.updateICEServers(nativeICEServers)
        publisherPeerConnection.updateICEServers(nativeICEServers)
    }

    private func resetPeerConnectionNegotiationState(
        restartICE: Bool = false,
        preservePublisherOfferState: Bool = false
    ) {
        if restartICE {
            subscriberPeerConnection.restartICE()
            publisherPeerConnection.restartICE()
        } else {
            subscriberPeerConnection.resetNegotiationState()
            publisherPeerConnection.resetNegotiationState()
        }
        if !preservePublisherOfferState {
            clearPublisherOfferState()
        }
        closeMediaStartupTransportDetached(clearSubscriberMediaStartupState())
        closeMediaStartupTransportDetached(clearPublisherMediaStartupState())
    }

    private func storeReconnectSubscriptionUpdate(trackSIDs: [String], subscribe: Bool) {
        reconnectSyncStateLock.withLock {
            if subscribe {
                reconnectSubscribedTrackSIDs.formUnion(trackSIDs)
            } else {
                reconnectSubscribedTrackSIDs.subtract(trackSIDs)
            }
        }
    }

    private func storeReconnectTrackSettingsUpdate(trackSIDs: [String], disabled: Bool) {
        reconnectSyncStateLock.withLock {
            if disabled {
                reconnectDisabledTrackSIDs.formUnion(trackSIDs)
            } else {
                reconnectDisabledTrackSIDs.subtract(trackSIDs)
            }
        }
    }

    private func sendReconnectSyncStateIfNeeded() async throws {
        guard let syncState = reconnectSyncState() else {
            return
        }

        var request = Livekit_SignalRequest()
        request.syncState = syncState
        try await signalConnection.send(request)
    }

    private func reconnectSyncState() -> Livekit_SyncState? {
        var syncState = Livekit_SyncState()
        var hasSyncState = false

        let reconnectState = reconnectSyncStateLock.withLock {
            (
                subscribedTrackSIDs: reconnectSubscribedTrackSIDs.sorted(),
                disabledTrackSIDs: reconnectDisabledTrackSIDs.sorted()
            )
        }

        if !reconnectState.subscribedTrackSIDs.isEmpty {
            var subscription = Livekit_UpdateSubscription()
            subscription.trackSids = reconnectState.subscribedTrackSIDs
            subscription.subscribe = true
            syncState.subscription = subscription
            hasSyncState = true
        }

        if !reconnectState.disabledTrackSIDs.isEmpty {
            syncState.trackSidsDisabled = reconnectState.disabledTrackSIDs
            hasSyncState = true
        }

        let sessionDescriptions = reconnectSessionDescriptionLock.withLock {
            (
                subscriberAnswer: reconnectSubscriberAnswer,
                publisherOffer: reconnectPublisherOffer
            )
        }

        if let subscriberAnswer = sessionDescriptions.subscriberAnswer {
            syncState.answer = subscriberAnswer
            hasSyncState = true
        }

        if let publisherOffer = sessionDescriptions.publisherOffer {
            syncState.offer = publisherOffer
            hasSyncState = true
        }

        let publishTracks = localParticipant.trackPublications.map { Self.publishResponse(for: $0) }
        if !publishTracks.isEmpty {
            syncState.publishTracks = publishTracks
            hasSyncState = true
        }

        let publishDataTracks = localParticipant.dataTrackPublications.map { Self.publishDataTrackResponse(for: $0) }
        if !publishDataTracks.isEmpty {
            syncState.publishDataTracks = publishDataTracks
            hasSyncState = true
        }

        return hasSyncState ? syncState : nil
    }

    private static func publishResponse(for publication: LocalTrackPublication) -> Livekit_TrackPublishedResponse {
        var track = Livekit_TrackInfo()
        track.sid = publication.sid
        track.name = publication.name
        track.type = publication.kind.protocolTrackType
        track.source = publication.source.protocolTrackSource
        track.muted = publication.isMuted

        var response = Livekit_TrackPublishedResponse()
        response.cid = publication.track?.id ?? publication.sid
        response.track = track
        return response
    }

    private static func publishDataTrackResponse(for dataTrack: DataTrackInfo) -> Livekit_PublishDataTrackResponse {
        var info = Livekit_DataTrackInfo()
        info.pubHandle = dataTrack.publisherHandle
        info.sid = dataTrack.sid
        info.name = dataTrack.name
        info.encryption = dataTrack.encryption.protocolEncryption

        var response = Livekit_PublishDataTrackResponse()
        response.info = info
        return response
    }

    private func addPublisherOfferTrack(_ track: PublisherSDPOfferTrack) -> [PublisherSDPOfferTrack] {
        publisherOfferLock.withLock {
            if let index = publisherOfferTracks.firstIndex(where: { $0.trackID == track.trackID }) {
                publisherOfferTracks[index] = track
            } else {
                publisherOfferTracks.append(track)
            }

            return publisherOfferTracks
        }
    }

    private func removePublisherOfferTrack(
        sid: String
    ) -> (removed: PublisherSDPOfferTrack?, tracks: [PublisherSDPOfferTrack]) {
        publisherOfferLock.withLock {
            let removed: PublisherSDPOfferTrack?
            if let index = publisherOfferTracks.firstIndex(where: { $0.trackID == sid }) {
                removed = publisherOfferTracks.remove(at: index)
            } else {
                removed = nil
            }
            return (removed, publisherOfferTracks)
        }
    }

    private func clearPublisherOfferState() {
        publisherOfferLock.withLock {
            publisherOfferTracks.removeAll()
            nextPublisherOfferID = 1
        }
        clearPublisherRTPSenders()
    }

    private func makePublisherRTPBridge() -> PublisherMediaRTPBridge {
        PublisherMediaRTPBridge { [weak self] packet in
            guard let self else {
                throw LiveKitNativeError.notConnected
            }

            try await self.sendPublisherRTP(packet)
        }
    }

    private func storePublisherAudioRTPSender(_ sender: PublisherAudioRTPSender, sid: String, cid: String) {
        publisherRTPSenderLock.withLock {
            removeStalePublisherRTPSenderLocked(cid: cid, sid: sid)
            publisherAudioRTPSendersBySID[sid] = sender
            publisherVideoRTPSendersBySID[sid] = nil
            publisherRTPSenderSIDByCID[cid] = sid
        }
    }

    private func storePublisherVideoRTPSender(_ sender: PublisherVideoRTPSender, sid: String, cid: String) {
        publisherRTPSenderLock.withLock {
            removeStalePublisherRTPSenderLocked(cid: cid, sid: sid)
            publisherVideoRTPSendersBySID[sid] = sender
            publisherAudioRTPSendersBySID[sid] = nil
            publisherRTPSenderSIDByCID[cid] = sid
        }
    }

    private func removeStalePublisherRTPSenderLocked(cid: String, sid: String) {
        guard let existingSID = publisherRTPSenderSIDByCID[cid], existingSID != sid else {
            return
        }

        publisherAudioRTPSendersBySID[existingSID] = nil
        publisherVideoRTPSendersBySID[existingSID] = nil
    }

    @discardableResult
    private func removePublisherRTPSender(sid: String) -> Bool {
        publisherRTPSenderLock.withLock {
            let removedAudio = publisherAudioRTPSendersBySID.removeValue(forKey: sid)
            let removedVideo = publisherVideoRTPSendersBySID.removeValue(forKey: sid)
            publisherRTPSenderSIDByCID = publisherRTPSenderSIDByCID.filter { $0.value != sid }
            return removedAudio != nil || removedVideo != nil
        }
    }

    private func clearPublisherRTPSenders() {
        publisherRTPSenderLock.withLock {
            publisherAudioRTPSendersBySID.removeAll()
            publisherVideoRTPSendersBySID.removeAll()
            publisherRTPSenderSIDByCID.removeAll()
        }
    }

    private func storeReconnectSubscriberAnswer(_ answer: Livekit_SessionDescription) {
        reconnectSessionDescriptionLock.withLock {
            reconnectSubscriberAnswer = answer
        }
    }

    private func storeReconnectPublisherOffer(_ offer: Livekit_SessionDescription) {
        reconnectSessionDescriptionLock.withLock {
            reconnectPublisherOffer = offer
        }
    }

    private func clearReconnectPublisherOffer() {
        reconnectSessionDescriptionLock.withLock {
            reconnectPublisherOffer = nil
        }
    }

    private func clearReconnectSessionDescriptionState() {
        reconnectSessionDescriptionLock.withLock {
            reconnectSubscriberAnswer = nil
            reconnectPublisherOffer = nil
        }
    }

    private func startSubscriberMediaTransportIfReady() {
        guard let subscriberMediaStartupConfiguration else {
            return
        }
        guard subscriberPeerConnection.remoteICECredentials != nil,
              subscriberPeerConnection.isRemoteICEGatheringComplete
        else {
            return
        }

        let shouldStart = subscriberMediaStartupLock.withLock {
            guard !subscriberMediaStartupStarted else {
                return false
            }

            subscriberMediaStartupStarted = true
            subscriberMediaStartupError = nil
            return true
        }
        guard shouldStart else {
            return
        }

        let localCandidates = subscriberLocalICECandidates()
        guard !localCandidates.isEmpty else {
            storeSubscriberMediaStartupError(
                PeerConnectionNegotiationError.missingSelectedICECandidatePair
            )
            return
        }

        let task = Task { [weak self, subscriberPeerConnection, subscriberMediaStartupConfiguration, localCandidates] in
            do {
                let result = try await subscriberPeerConnection.startSecureMediaTransport(
                    localCandidates: localCandidates,
                    iceRole: subscriberMediaStartupConfiguration.iceRole,
                    tieBreaker: subscriberMediaStartupConfiguration.tieBreaker,
                    nominationPolicy: subscriberMediaStartupConfiguration.nominationPolicy,
                    checker: subscriberMediaStartupConfiguration.checker,
                    binder: subscriberMediaStartupConfiguration.binder
                )
                self?.storeSubscriberMediaStartupResult(result)
                LiveKitNativeLogging.log(.info, "Subscriber media transport started.")
            } catch {
                self?.storeSubscriberMediaStartupError(error)
                LiveKitNativeLogging.log(.error, "Subscriber media transport startup failed: \(error.localizedDescription)")
            }
        }

        subscriberMediaStartupLock.withLock {
            subscriberMediaStartupTask = task
        }
    }

    private func startPublisherMediaTransportIfReady() {
        guard let publisherMediaStartupConfiguration else {
            return
        }
        guard publisherPeerConnection.remoteAnswer != nil,
              publisherPeerConnection.isRemoteICEGatheringComplete
        else {
            return
        }

        let shouldStart = publisherMediaStartupLock.withLock {
            guard !publisherMediaStartupStarted else {
                return false
            }

            publisherMediaStartupStarted = true
            publisherMediaStartupError = nil
            return true
        }
        guard shouldStart else {
            return
        }

        let localCandidates = publisherLocalICECandidates()
        guard !localCandidates.isEmpty else {
            storePublisherMediaStartupError(
                PeerConnectionNegotiationError.missingSelectedICECandidatePair
            )
            return
        }

        let task = Task { [weak self, publisherPeerConnection, publisherMediaStartupConfiguration, localCandidates] in
            do {
                let result = try await publisherPeerConnection.startSecureMediaTransport(
                    localCandidates: localCandidates,
                    iceRole: publisherMediaStartupConfiguration.iceRole,
                    tieBreaker: publisherMediaStartupConfiguration.tieBreaker,
                    nominationPolicy: publisherMediaStartupConfiguration.nominationPolicy,
                    checker: publisherMediaStartupConfiguration.checker,
                    binder: publisherMediaStartupConfiguration.binder
                )
                self?.storePublisherMediaStartupResult(result)
                LiveKitNativeLogging.log(.info, "Publisher media transport started.")
            } catch {
                self?.storePublisherMediaStartupError(error)
                LiveKitNativeLogging.log(.error, "Publisher media transport startup failed: \(error.localizedDescription)")
            }
        }

        publisherMediaStartupLock.withLock {
            publisherMediaStartupTask = task
        }
    }

    private func storePublisherMediaStartupResult(_ result: PeerConnectionMediaStartupResult) {
        publisherMediaStartupLock.withLock {
            publisherMediaStartupResult = result
            publisherMediaStartupError = nil
        }
        startPublisherICEConsentFreshnessLoopIfReady(result: result)
        startPublisherRTCPReceiveLoopIfReady()
    }

    private func storeSubscriberMediaStartupResult(_ result: PeerConnectionMediaStartupResult) {
        subscriberMediaStartupLock.withLock {
            subscriberMediaStartupResult = result
            subscriberMediaStartupError = nil
        }
        startSubscriberICEConsentFreshnessLoopIfReady(result: result)
        startSubscriberRTCPReceiveLoopIfReady()
    }

    private func storePublisherMediaStartupError(_ error: any Error) {
        publisherMediaStartupLock.withLock {
            publisherMediaStartupError = error
        }
    }

    private func storeSubscriberMediaStartupError(_ error: any Error) {
        subscriberMediaStartupLock.withLock {
            subscriberMediaStartupError = error
        }
    }

    @discardableResult
    private func clearSubscriberMediaStartupState() -> PeerConnectionMediaStartupResult? {
        let cleared = subscriberMediaStartupLock.withLock {
            let task = subscriberMediaStartupTask
            let result = subscriberMediaStartupResult
            let rtcpReceiveTask = subscriberRTCPReceiveTask
            let consentFreshnessTask = subscriberICEConsentFreshnessTask
            subscriberMediaStartupStarted = false
            subscriberMediaStartupTask = nil
            subscriberMediaStartupResult = nil
            subscriberMediaStartupError = nil
            subscriberICEConsentFreshnessTask = nil
            subscriberRTCPReceiveTask = nil
            subscriberLocalCandidatesGathered = false
            subscriberLocalCandidates = []
            return (task, result, rtcpReceiveTask, consentFreshnessTask)
        }

        cleared.0?.cancel()
        cleared.2?.cancel()
        cleared.3?.cancel()
        return cleared.1
    }

    @discardableResult
    private func clearPublisherMediaStartupState() -> PeerConnectionMediaStartupResult? {
        let cleared = publisherMediaStartupLock.withLock {
            let task = publisherMediaStartupTask
            let result = publisherMediaStartupResult
            let rtcpReceiveTask = publisherRTCPReceiveTask
            let consentFreshnessTask = publisherICEConsentFreshnessTask
            publisherMediaStartupStarted = false
            publisherMediaStartupTask = nil
            publisherMediaStartupResult = nil
            publisherMediaStartupError = nil
            publisherICEConsentFreshnessTask = nil
            publisherRTCPReceiveTask = nil
            publisherLocalCandidatesGathered = false
            publisherLocalCandidates = []
            return (task, result, rtcpReceiveTask, consentFreshnessTask)
        }

        cleared.0?.cancel()
        cleared.2?.cancel()
        cleared.3?.cancel()
        return cleared.1
    }

    private func startPublisherICEConsentFreshnessLoopIfReady(result: PeerConnectionMediaStartupResult) {
        guard let publisherMediaStartupConfiguration,
              publisherMediaStartupConfiguration.consentFreshnessPolicy.isEnabled
        else {
            return
        }

        guard let remoteCredentials = publisherPeerConnection.remoteICECredentials else {
            storePublisherMediaStartupError(PeerConnectionNegotiationError.missingRemoteICECredentials)
            return
        }

        let iceConfiguration = ICEAgentConfiguration(
            localCredentials: publisherPeerConnection.configuration.iceCredentials,
            remoteCredentials: remoteCredentials,
            role: publisherMediaStartupConfiguration.iceRole,
            tieBreaker: publisherMediaStartupConfiguration.tieBreaker,
            nominationPolicy: publisherMediaStartupConfiguration.nominationPolicy,
            retryPolicy: publisherMediaStartupConfiguration.consentFreshnessRetryPolicy
        )
        let task = Task { [weak self, publisherMediaStartupConfiguration, result, iceConfiguration] in
            guard let self else {
                return
            }

            await self.runICEConsentFreshnessLoop(
                label: "Publisher",
                selectedPair: result.selectedCandidatePair,
                transport: result.transport,
                policy: publisherMediaStartupConfiguration.consentFreshnessPolicy,
                checker: publisherMediaStartupConfiguration.checker,
                iceConfiguration: iceConfiguration
            ) { [weak self] action in
                self?.storePublisherMediaStartupError(ICEConsentFreshnessError.expired(action))
            }
        }

        publisherMediaStartupLock.withLock {
            publisherICEConsentFreshnessTask?.cancel()
            publisherICEConsentFreshnessTask = task
        }
    }

    private func startSubscriberICEConsentFreshnessLoopIfReady(result: PeerConnectionMediaStartupResult) {
        guard let subscriberMediaStartupConfiguration,
              subscriberMediaStartupConfiguration.consentFreshnessPolicy.isEnabled
        else {
            return
        }

        guard let remoteCredentials = subscriberPeerConnection.remoteICECredentials else {
            storeSubscriberMediaStartupError(PeerConnectionNegotiationError.missingRemoteICECredentials)
            return
        }

        let iceConfiguration = ICEAgentConfiguration(
            localCredentials: subscriberPeerConnection.configuration.iceCredentials,
            remoteCredentials: remoteCredentials,
            role: subscriberMediaStartupConfiguration.iceRole,
            tieBreaker: subscriberMediaStartupConfiguration.tieBreaker,
            nominationPolicy: subscriberMediaStartupConfiguration.nominationPolicy,
            retryPolicy: subscriberMediaStartupConfiguration.consentFreshnessRetryPolicy
        )
        let task = Task { [weak self, subscriberMediaStartupConfiguration, result, iceConfiguration] in
            guard let self else {
                return
            }

            await self.runICEConsentFreshnessLoop(
                label: "Subscriber",
                selectedPair: result.selectedCandidatePair,
                transport: result.transport,
                policy: subscriberMediaStartupConfiguration.consentFreshnessPolicy,
                checker: subscriberMediaStartupConfiguration.checker,
                iceConfiguration: iceConfiguration
            ) { [weak self] action in
                self?.storeSubscriberMediaStartupError(ICEConsentFreshnessError.expired(action))
            }
        }

        subscriberMediaStartupLock.withLock {
            subscriberICEConsentFreshnessTask?.cancel()
            subscriberICEConsentFreshnessTask = task
        }
    }

    private func runICEConsentFreshnessLoop(
        label: String,
        selectedPair: ICECandidatePair,
        transport: DTLSSRTPMediaTransport,
        policy: ICEConsentFreshnessPolicy,
        checker: any ICEConnectivityChecking,
        iceConfiguration: ICEAgentConfiguration,
        onExpired: @escaping @Sendable (ICEConsentFreshnessDueAction) -> Void
    ) async {
        var session = ICEConsentFreshnessSession(
            selectedPair: selectedPair,
            startedAt: Date().timeIntervalSince1970
        )
        let executor = ICEConsentFreshnessExecutor(policy: policy) { pair in
            do {
                _ = try checker.checkCandidatePair(
                    pair,
                    configuration: iceConfiguration,
                    nominate: false
                )
                return true
            } catch {
                return false
            }
        }

        while !Task.isCancelled {
            let now = Date().timeIntervalSince1970
            switch executor.execute(session: &session, at: now) {
            case .noAction, .success, .failure:
                break
            case let .expired(action):
                onExpired(action)
                await transport.close()
                LiveKitNativeLogging.log(.error, "\(label) ICE consent freshness expired.")
                return
            }

            let sleepNanoseconds = Self.iceConsentFreshnessSleepNanoseconds(
                session: session,
                policy: policy,
                now: Date().timeIntervalSince1970
            )
            do {
                try await Task.sleep(nanoseconds: sleepNanoseconds)
            } catch {
                return
            }
        }
    }

    private static func iceConsentFreshnessSleepNanoseconds(
        session: ICEConsentFreshnessSession,
        policy: ICEConsentFreshnessPolicy,
        now: TimeInterval
    ) -> UInt64 {
        let nextDeadline = min(
            session.nextCheckDeadline(policy: policy),
            session.timeoutDeadline(policy: policy)
        )
        let seconds = max(0.010, nextDeadline - now)
        return UInt64(min(seconds * 1_000_000_000, Double(UInt64.max)))
    }

    private func startPublisherRTCPReceiveLoopIfReady() {
        publisherMediaStartupLock.withLock {
            guard publisherRTCPHandler != nil,
                  publisherRTCPReceiveTask == nil,
                  let transport = publisherMediaStartupResult?.transport
            else {
                return
            }

            publisherRTCPReceiveLoopID &+= 1
            let loopID = publisherRTCPReceiveLoopID
            publisherRTCPReceiveTask = Task { [weak self, transport] in
                await self?.runPublisherRTCPReceiveLoop(transport: transport, loopID: loopID)
            }
        }
    }

    private func startSubscriberRTCPReceiveLoopIfReady() {
        subscriberMediaStartupLock.withLock {
            guard subscriberRTCPHandler != nil,
                  subscriberRTCPReceiveTask == nil,
                  let transport = subscriberMediaStartupResult?.transport
            else {
                return
            }

            subscriberRTCPReceiveLoopID &+= 1
            let loopID = subscriberRTCPReceiveLoopID
            subscriberRTCPReceiveTask = Task { [weak self, transport] in
                await self?.runSubscriberRTCPReceiveLoop(transport: transport, loopID: loopID)
            }
        }
    }

    private func runPublisherRTCPReceiveLoop(
        transport: DTLSSRTPMediaTransport,
        loopID: UInt64
    ) async {
        defer {
            clearPublisherRTCPReceiveTask(loopID: loopID)
        }

        while !Task.isCancelled {
            do {
                let packet = try await transport.receive()
                guard !Task.isCancelled else {
                    return
                }

                switch packet {
                case .rtp:
                    continue
                case let .rtcp(packet):
                    guard let handler = publisherRTCPHandlerSnapshot() else {
                        return
                    }
                    await handler(packet)
                }
            } catch {
                if isRecoverablePublisherRTCPReceiveError(error) {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    continue
                }

                if !Task.isCancelled {
                    LiveKitNativeLogging.log(.error, "Publisher RTCP receive loop stopped: \(error.localizedDescription)")
                }
                return
            }
        }
    }

    private func runSubscriberRTCPReceiveLoop(
        transport: DTLSSRTPMediaTransport,
        loopID: UInt64
    ) async {
        defer {
            clearSubscriberRTCPReceiveTask(loopID: loopID)
        }

        while !Task.isCancelled {
            do {
                let packet = try await transport.receive()
                guard !Task.isCancelled else {
                    return
                }

                switch packet {
                case .rtp:
                    continue
                case let .rtcp(packet):
                    guard let handler = subscriberRTCPHandlerSnapshot() else {
                        return
                    }
                    await handler(packet)
                }
            } catch {
                if isRecoverableSubscriberRTCPReceiveError(error) {
                    try? await Task.sleep(nanoseconds: 10_000_000)
                    continue
                }

                if !Task.isCancelled {
                    LiveKitNativeLogging.log(.error, "Subscriber RTCP receive loop stopped: \(error.localizedDescription)")
                }
                return
            }
        }
    }

    private func isRecoverablePublisherRTCPReceiveError(_ error: any Error) -> Bool {
        guard case let SecureMediaTransportError.socketReceiveFailed(code) = error else {
            return false
        }

        return code == EAGAIN || code == EWOULDBLOCK
    }

    private func isRecoverableSubscriberRTCPReceiveError(_ error: any Error) -> Bool {
        guard case let SecureMediaTransportError.socketReceiveFailed(code) = error else {
            return false
        }

        return code == EAGAIN || code == EWOULDBLOCK
    }

    private func publisherRTCPHandlerSnapshot() -> (@Sendable (RTCPPacket) async -> Void)? {
        publisherMediaStartupLock.withLock {
            publisherRTCPHandler
        }
    }

    private func subscriberRTCPHandlerSnapshot() -> (@Sendable (RTCPPacket) async -> Void)? {
        subscriberMediaStartupLock.withLock {
            subscriberRTCPHandler
        }
    }

    private func clearPublisherRTCPReceiveTask(loopID: UInt64) {
        publisherMediaStartupLock.withLock {
            guard publisherRTCPReceiveLoopID == loopID else {
                return
            }
            publisherRTCPReceiveTask = nil
        }
    }

    private func clearSubscriberRTCPReceiveTask(loopID: UInt64) {
        subscriberMediaStartupLock.withLock {
            guard subscriberRTCPReceiveLoopID == loopID else {
                return
            }
            subscriberRTCPReceiveTask = nil
        }
    }

    private func closeMediaStartupTransport(_ result: PeerConnectionMediaStartupResult?) async {
        await result?.transport.close()
    }

    private func closeMediaStartupTransportDetached(_ result: PeerConnectionMediaStartupResult?) {
        guard let result else {
            return
        }

        Task {
            await result.transport.close()
        }
    }

    private func subscriberLocalICECandidates() -> [ICECandidate] {
        if let candidates = subscriberMediaStartupLock.withLock({ () -> [ICECandidate]? in
            subscriberLocalCandidatesGathered ? subscriberLocalCandidates : nil
        }) {
            return candidates
        }

        guard let subscriberMediaStartupConfiguration else {
            return []
        }

        let candidates = subscriberMediaStartupConfiguration.localCandidates(
            subscriberPeerConnection.configuration.iceServers
        )
        return subscriberMediaStartupLock.withLock {
            if !subscriberLocalCandidatesGathered {
                subscriberLocalCandidates = candidates
                subscriberLocalCandidatesGathered = true
            }

            return subscriberLocalCandidates
        }
    }

    private func publisherLocalICECandidates() -> [ICECandidate] {
        if let candidates = publisherMediaStartupLock.withLock({ () -> [ICECandidate]? in
            publisherLocalCandidatesGathered ? publisherLocalCandidates : nil
        }) {
            return candidates
        }

        guard let publisherMediaStartupConfiguration else {
            return []
        }

        let candidates = publisherMediaStartupConfiguration.localCandidates(
            publisherPeerConnection.configuration.iceServers
        )
        return publisherMediaStartupLock.withLock {
            if !publisherLocalCandidatesGathered {
                publisherLocalCandidates = candidates
                publisherLocalCandidatesGathered = true
            }

            return publisherLocalCandidates
        }
    }

    private func sendSubscriberLocalICETrickleCandidates() async throws {
        guard subscriberMediaStartupConfiguration != nil else {
            return
        }

        for candidate in subscriberLocalICECandidates() {
            var trickle = Livekit_TrickleRequest()
            trickle.target = .subscriber
            trickle.candidateInit = try RTCIceCandidateInit(
                candidate: candidate,
                sdpMid: "0",
                sdpMLineIndex: 0,
                usernameFragment: subscriberPeerConnection.configuration.iceCredentials.usernameFragment
            ).jsonString()

            var request = Livekit_SignalRequest()
            request.trickle = trickle
            try await signalConnection.send(request)
        }

        var finalTrickle = Livekit_TrickleRequest()
        finalTrickle.target = .subscriber
        finalTrickle.final = true

        var finalRequest = Livekit_SignalRequest()
        finalRequest.trickle = finalTrickle
        try await signalConnection.send(finalRequest)
    }

    private func sendPublisherLocalICETrickleCandidates() async throws {
        guard publisherMediaStartupConfiguration != nil else {
            return
        }

        for candidate in publisherLocalICECandidates() {
            var trickle = Livekit_TrickleRequest()
            trickle.target = .publisher
            trickle.candidateInit = try RTCIceCandidateInit(
                candidate: candidate,
                sdpMid: "0",
                sdpMLineIndex: 0,
                usernameFragment: publisherPeerConnection.configuration.iceCredentials.usernameFragment
            ).jsonString()

            var request = Livekit_SignalRequest()
            request.trickle = trickle
            try await signalConnection.send(request)
        }

        var finalTrickle = Livekit_TrickleRequest()
        finalTrickle.target = .publisher
        finalTrickle.final = true

        var finalRequest = Livekit_SignalRequest()
        finalRequest.trickle = finalTrickle
        try await signalConnection.send(finalRequest)
    }

    private func nextPublisherOfferIdentifier() -> UInt32 {
        publisherOfferLock.withLock {
            let id = nextPublisherOfferID
            nextPublisherOfferID = nextPublisherOfferID == UInt32.max ? 1 : nextPublisherOfferID + 1
            return id
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

private extension ICEServer {
    init(protocolServer: Livekit_ICEServer) {
        self.init(
            urls: protocolServer.urls,
            username: protocolServer.username.nilIfEmpty,
            credential: protocolServer.credential.nilIfEmpty
        )
    }
}

private extension TrackKind {
    var protocolTrackType: Livekit_TrackType {
        switch self {
        case .audio:
            .audio
        case .video:
            .video
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
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

    var protocolQuality: Livekit_VideoQuality {
        switch self {
        case .low:
            return .low
        case .medium:
            return .medium
        case .high:
            return .high
        case .off:
            return .off
        case let .unknown(rawValue):
            return .UNRECOGNIZED(rawValue)
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
