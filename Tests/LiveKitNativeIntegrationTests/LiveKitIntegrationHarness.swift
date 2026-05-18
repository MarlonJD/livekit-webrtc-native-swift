import CryptoKit
import Foundation
import LiveKitNativeWebRTC
import XCTest
@testable import LiveKitNative

struct LiveKitIntegrationHarness: Sendable {
    static let runIntegrationKey = "LIVEKIT_NATIVE_RUN_INTEGRATION"
    static let liveKitURLKey = "LIVEKIT_NATIVE_LIVEKIT_URL"
    static let apiKeyKey = "LIVEKIT_NATIVE_API_KEY"
    static let apiSecretKey = "LIVEKIT_NATIVE_API_SECRET"

    let liveKitURL: URL
    let roomPrefix: String

    private let tokenFactory: LiveKitIntegrationTokenFactory

    static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        now: Date = Date(),
        uuid: UUID = UUID()
    ) throws -> Self {
        guard environment[runIntegrationKey] == "1" else {
            throw XCTSkip("Set \(runIntegrationKey)=1 and provide a local LiveKit server to run integration tests.")
        }

        let liveKitURLString = try requiredValue(liveKitURLKey, in: environment)
        guard let liveKitURL = URL(string: liveKitURLString),
              let scheme = liveKitURL.scheme?.lowercased(),
              ["http", "https", "ws", "wss"].contains(scheme),
              liveKitURL.host?.isEmpty == false
        else {
            throw LiveKitIntegrationHarnessError.invalidEnvironmentValue(
                name: liveKitURLKey,
                value: liveKitURLString,
                reason: "expected an http(s) or ws(s) LiveKit URL with a host"
            )
        }

        let apiKey = try requiredValue(apiKeyKey, in: environment)
        let apiSecret = try requiredValue(apiSecretKey, in: environment)
        let prefixTimestamp = Int(now.timeIntervalSince1970)
        let prefixEntropy = String(uuid.uuidString.lowercased().prefix(8))

        return Self(
            liveKitURL: liveKitURL,
            roomPrefix: "lknative-\(prefixTimestamp)-\(prefixEntropy)",
            tokenFactory: LiveKitIntegrationTokenFactory(
                apiKey: apiKey,
                apiSecret: apiSecret
            )
        )
    }

    func roomName(suffix: String) -> String {
        "\(roomPrefix)-\(suffix)-\(UUID().uuidString.lowercased())"
    }

    func token(identity: String, roomName: String, ttlSeconds: Int = 600) throws -> String {
        try tokenFactory.token(
            identity: identity,
            roomName: roomName,
            ttlSeconds: ttlSeconds
        )
    }

    func connect(
        _ room: Room,
        identity: String,
        roomName: String,
        timeoutSeconds: TimeInterval = 15
    ) async throws {
        let token = try token(identity: identity, roomName: roomName)
        do {
            try await withLiveKitIntegrationTimeout(seconds: timeoutSeconds) {
                try await room.connect(url: liveKitURL, token: token)
            }
        } catch {
            await room.disconnect()
            throw error
        }
    }

    func waitForPublisherMediaStartup(
        _ room: Room,
        timeoutSeconds: TimeInterval = 30
    ) async throws -> PeerConnectionMediaStartupResult {
        try await waitForMediaStartup(
            role: "publisher",
            timeoutSeconds: timeoutSeconds,
            result: { room.lastPublisherMediaStartupResult },
            error: { room.lastPublisherMediaStartupError }
        )
    }

    func waitForSubscriberMediaStartup(
        _ room: Room,
        timeoutSeconds: TimeInterval = 30
    ) async throws -> PeerConnectionMediaStartupResult {
        try await waitForMediaStartup(
            role: "subscriber",
            timeoutSeconds: timeoutSeconds,
            result: { room.lastSubscriberMediaStartupResult },
            error: { room.lastSubscriberMediaStartupError }
        )
    }

    func waitForPublisherDataChannelInstalled(
        _ room: Room,
        timeoutSeconds: TimeInterval = 10
    ) async throws -> RoomDataChannelObserverState {
        try await waitForDataChannelState(
            role: "publisher",
            expected: "installed",
            timeoutSeconds: timeoutSeconds,
            state: { await room.publisherDataChannelObserverState() },
            matches: { $0.installed }
        )
    }

    func waitForSubscriberDataChannelInstalled(
        _ room: Room,
        timeoutSeconds: TimeInterval = 10
    ) async throws -> RoomDataChannelObserverState {
        try await waitForDataChannelState(
            role: "subscriber",
            expected: "installed",
            timeoutSeconds: timeoutSeconds,
            state: { await room.subscriberDataChannelObserverState() },
            matches: { $0.installed }
        )
    }

    func waitForPublisherReliableDataChannelOpenAndFlushed(
        _ room: Room,
        timeoutSeconds: TimeInterval = 10
    ) async throws -> RoomDataChannelObserverState {
        try await waitForDataChannelState(
            role: "publisher",
            expected: "reliable channel open with no pending publish plans",
            timeoutSeconds: timeoutSeconds,
            state: { await room.publisherDataChannelObserverState() },
            matches: { $0.installed && $0.reliableOpen && $0.pendingPlanCount == 0 }
        )
    }

    private static func requiredValue(_ name: String, in environment: [String: String]) throws -> String {
        let value = environment[name]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else {
            throw LiveKitIntegrationHarnessError.missingEnvironmentValue(name)
        }

        return value
    }

    private func waitForMediaStartup(
        role: String,
        timeoutSeconds: TimeInterval,
        result: @escaping @Sendable () -> PeerConnectionMediaStartupResult?,
        error: @escaping @Sendable () -> (any Error)?
    ) async throws -> PeerConnectionMediaStartupResult {
        do {
            return try await withLiveKitIntegrationTimeout(seconds: timeoutSeconds) {
                while !Task.isCancelled {
                    if let error = error() {
                        throw LiveKitIntegrationHarnessError.mediaStartupFailed(
                            role: role,
                            reason: String(describing: error)
                        )
                    }

                    if let result = result() {
                        guard result.iceSummary.state == .connected else {
                            throw LiveKitIntegrationHarnessError.unexpectedMediaStartupICEState(
                                role: role,
                                state: result.iceSummary.state.rawValue
                            )
                        }

                        return result
                    }

                    try await Task.sleep(nanoseconds: 50_000_000)
                }

                throw CancellationError()
            }
        } catch LiveKitIntegrationHarnessError.timeout {
            let lastResult = result()
            throw LiveKitIntegrationHarnessError.mediaStartupTimeout(
                role: role,
                seconds: timeoutSeconds,
                lastICEState: lastResult?.iceSummary.state.rawValue,
                selectedPair: lastResult.map { String(describing: $0.selectedCandidatePair) },
                lastError: error().map { String(describing: $0) }
            )
        }
    }

    private func waitForDataChannelState(
        role: String,
        expected: String,
        timeoutSeconds: TimeInterval,
        state: @escaping @Sendable () async -> RoomDataChannelObserverState,
        matches: @escaping @Sendable (RoomDataChannelObserverState) -> Bool
    ) async throws -> RoomDataChannelObserverState {
        do {
            return try await withLiveKitIntegrationTimeout(seconds: timeoutSeconds) {
                while !Task.isCancelled {
                    let snapshot = await state()
                    if matches(snapshot) {
                        return snapshot
                    }

                    try await Task.sleep(nanoseconds: 50_000_000)
                }

                throw CancellationError()
            }
        } catch LiveKitIntegrationHarnessError.timeout {
            let snapshot = await state()
            throw LiveKitIntegrationHarnessError.dataChannelStateTimeout(
                role: role,
                expected: expected,
                state: snapshot.description,
                seconds: timeoutSeconds
            )
        }
    }
}

final class LiveKitIntegrationEventRecorder: RoomDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RoomEvent] = []

    var recordedEvents: [RoomEvent] {
        lock.withLock {
            events
        }
    }

    func room(_ room: Room, didEmit event: RoomEvent) {
        lock.withLock {
            events.append(event)
        }
    }

    func waitForParticipantConnected(
        identity: String,
        timeoutSeconds: TimeInterval = 10
    ) async throws -> RemoteParticipant {
        try await wait(timeoutSeconds: timeoutSeconds) { events in
            for event in events.reversed() {
                if case let .participantConnected(participant) = event,
                   participant.identity == identity {
                    return participant
                }
            }

            return nil
        }
    }

    func waitForParticipantDisconnected(
        identity: String,
        timeoutSeconds: TimeInterval = 10
    ) async throws -> RemoteParticipant {
        try await wait(timeoutSeconds: timeoutSeconds) { events in
            for event in events.reversed() {
                if case let .participantDisconnected(participant) = event,
                   participant.identity == identity {
                    return participant
                }
            }

            return nil
        }
    }

    func waitForDataTrackSubscriberHandle(
        publisherIdentity: String,
        timeoutSeconds: TimeInterval = 10
    ) async throws -> DataTrackSubscriberHandleInfo {
        try await wait(timeoutSeconds: timeoutSeconds) { events in
            for event in events.reversed() {
                if case let .dataTrackSubscriberHandlesChanged(handles) = event,
                   let handle = handles.handles.first(where: { $0.publisherIdentity == publisherIdentity }) {
                    return handle
                }
            }

            return nil
        }
    }

    func waitForTrackSubscribed(
        trackSID: String? = nil,
        timeoutSeconds: TimeInterval = 10
    ) async throws -> TrackSubscribedInfo {
        try await wait(timeoutSeconds: timeoutSeconds) { events in
            for event in events.reversed() {
                if case let .trackSubscribed(info) = event,
                   trackSID == nil || info.trackSID == trackSID {
                    return info
                }
            }

            return nil
        }
    }

    func waitForTrackSubscribedOrRemoteVideoPublication(
        publisherIdentity: String,
        trackSID: String,
        timeoutSeconds: TimeInterval = 10
    ) async throws -> String {
        try await wait(timeoutSeconds: timeoutSeconds) { events in
            for event in events.reversed() {
                switch event {
                case let .trackSubscribed(info) where info.trackSID == trackSID:
                    return "trackSubscribed"
                case let .trackPublished(publication, participant)
                    where participant.identity == publisherIdentity &&
                    publication.sid == trackSID &&
                    publication.kind == .video:
                    return "remoteVideoPublication"
                default:
                    continue
                }
            }

            return nil
        }
    }

    func waitForDataReceived(
        payload: Data,
        topic: String? = nil,
        participantIdentity: String? = nil,
        timeoutSeconds: TimeInterval = 10
    ) async throws -> (Data, RemoteParticipant?, String?) {
        try await wait(timeoutSeconds: timeoutSeconds) { events in
            for event in events.reversed() {
                if case let .dataReceived(eventPayload, participant, eventTopic) = event,
                   eventPayload == payload,
                   eventTopic == topic,
                   participantIdentity == nil || participant?.identity == participantIdentity {
                    return (eventPayload, participant, eventTopic)
                }
            }

            return nil
        }
    }

    private func wait<T: Sendable>(
        timeoutSeconds: TimeInterval,
        match: @escaping @Sendable ([RoomEvent]) -> T?
    ) async throws -> T {
        try await withLiveKitIntegrationTimeout(seconds: timeoutSeconds) {
            while !Task.isCancelled {
                if let value = match(self.recordedEvents) {
                    return value
                }

                try await Task.sleep(nanoseconds: 50_000_000)
            }

            throw CancellationError()
        }
    }
}

private struct LiveKitIntegrationTokenFactory: Sendable {
    var apiKey: String
    var apiSecret: String

    func token(
        identity: String,
        roomName: String,
        ttlSeconds: Int,
        now: Date = Date()
    ) throws -> String {
        let identity = identity.trimmingCharacters(in: .whitespacesAndNewlines)
        let roomName = roomName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !identity.isEmpty else {
            throw LiveKitIntegrationHarnessError.invalidTokenInput("identity must not be empty")
        }
        guard !roomName.isEmpty else {
            throw LiveKitIntegrationHarnessError.invalidTokenInput("roomName must not be empty")
        }

        let issuedAt = Int(now.timeIntervalSince1970)
        let expiresAt = issuedAt + max(1, ttlSeconds)
        let header: [String: Any] = [
            "alg": "HS256",
            "typ": "JWT",
        ]
        let payload: [String: Any] = [
            "iss": apiKey,
            "sub": identity,
            "nbf": issuedAt,
            "exp": expiresAt,
            "video": [
                "roomJoin": true,
                "room": roomName,
                "canPublish": true,
                "canSubscribe": true,
                "canPublishData": true,
                "canUpdateOwnMetadata": true,
            ],
        ]

        let encodedHeader = try Self.base64URLEncodedJSONObject(header)
        let encodedPayload = try Self.base64URLEncodedJSONObject(payload)
        let signingInput = "\(encodedHeader).\(encodedPayload)"
        let signature = HMAC<SHA256>.authenticationCode(
            for: Data(signingInput.utf8),
            using: SymmetricKey(data: Data(apiSecret.utf8))
        )

        return "\(signingInput).\(Data(signature).base64URLEncodedString())"
    }

    private static func base64URLEncodedJSONObject(_ object: Any) throws -> String {
        try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        ).base64URLEncodedString()
    }
}

enum LiveKitIntegrationHarnessError: Error, CustomStringConvertible {
    case missingEnvironmentValue(String)
    case invalidEnvironmentValue(name: String, value: String, reason: String)
    case invalidTokenInput(String)
    case mediaStartupFailed(role: String, reason: String)
    case unexpectedMediaStartupICEState(role: String, state: String)
    case mediaStartupTimeout(
        role: String,
        seconds: TimeInterval,
        lastICEState: String?,
        selectedPair: String?,
        lastError: String?
    )
    case dataChannelStateTimeout(role: String, expected: String, state: String, seconds: TimeInterval)
    case timeout(seconds: TimeInterval)

    var description: String {
        switch self {
        case let .missingEnvironmentValue(name):
            "Missing required integration environment variable: \(name)."
        case let .invalidEnvironmentValue(name, value, reason):
            "Invalid integration environment variable \(name)=\(value): \(reason)."
        case let .invalidTokenInput(reason):
            "Invalid LiveKit integration token input: \(reason)."
        case let .mediaStartupFailed(role, reason):
            "LiveKit integration \(role) media startup failed: \(reason)."
        case let .unexpectedMediaStartupICEState(role, state):
            "LiveKit integration \(role) media startup ICE state was \(state), expected connected."
        case let .mediaStartupTimeout(role, seconds, lastICEState, selectedPair, lastError):
            "LiveKit integration \(role) media startup timed out after \(seconds) seconds; " +
                "lastICEState=\(lastICEState ?? "nil"), " +
                "selectedPair=\(selectedPair ?? "nil"), " +
                "lastError=\(lastError ?? "nil")."
        case let .dataChannelStateTimeout(role, expected, state, seconds):
            "LiveKit integration \(role) data channel did not reach \(expected) after " +
                "\(seconds) seconds; last state: \(state)."
        case let .timeout(seconds):
            "LiveKit integration operation timed out after \(seconds) seconds."
        }
    }
}

func withLiveKitIntegrationTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    let outcome = await withTaskGroup(of: LiveKitIntegrationTimeoutOutcome<T>.self) { group in
        group.addTask {
            do {
                return .success(try await operation())
            } catch {
                return .failure(LiveKitIntegrationCapturedError(error))
            }
        }
        group.addTask {
            do {
                try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            } catch {
                return .failure(LiveKitIntegrationCapturedError(error))
            }
            return .timeout
        }

        guard let result = await group.next() else {
            return LiveKitIntegrationTimeoutOutcome<T>.timeout
        }

        group.cancelAll()
        return result
    }

    switch outcome {
    case let .success(value):
        return value
    case let .failure(error):
        throw error.error
    case .timeout:
        throw LiveKitIntegrationHarnessError.timeout(seconds: seconds)
    }
}

private struct LiveKitIntegrationCapturedError: @unchecked Sendable {
    let error: any Error

    init(_ error: any Error) {
        self.error = error
    }
}

private enum LiveKitIntegrationTimeoutOutcome<T: Sendable>: Sendable {
    case success(T)
    case failure(LiveKitIntegrationCapturedError)
    case timeout
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "="))
    }

    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 {
            base64.append("=")
        }

        self.init(base64Encoded: base64)
    }
}
