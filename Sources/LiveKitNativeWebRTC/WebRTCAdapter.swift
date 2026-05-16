import AVFoundation
import AudioToolbox
import CoreMedia
import CryptoKit
import Foundation
import Network
import Security
import VideoToolbox

package enum PeerConnectionRole: String, Equatable, Sendable {
    case subscriber
    case publisher
}

package enum RTPMediaKind: String, Equatable, Sendable {
    case audio
    case video
    case application
}

package enum RTPCodec: String, CaseIterable, Equatable, Sendable {
    case h264 = "H264"
    case vp8 = "VP8"
    case opus = "opus"
    case webRTCDataChannel = "webrtc-datachannel"
}

package struct ICEServer: Equatable, Sendable {
    package var urls: [String]
    package var username: String?
    package var credential: String?

    package init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }
}

package struct ICECredentials: Equatable, Sendable {
    package var usernameFragment: String
    package var password: String

    package init(usernameFragment: String, password: String) {
        self.usernameFragment = usernameFragment
        self.password = password
    }

    package static func random() -> ICECredentials {
        let usernameCharacters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        let passwordCharacters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789./-_")
        var generator = SystemRandomNumberGenerator()

        let username = String((0..<8).map { _ in
            usernameCharacters.randomElement(using: &generator) ?? "a"
        })

        let password = String((0..<24).map { _ in
            passwordCharacters.randomElement(using: &generator) ?? "a"
        })

        return ICECredentials(
            usernameFragment: username,
            password: password
        )
    }
}

package struct DTLSSignature: Equatable, Sendable {
    package var hashFunction: String
    package var value: String

    package init(hashFunction: String, value: String) {
        self.hashFunction = hashFunction
        self.value = value
    }

    package static func sha256Fingerprint(for data: Data) -> DTLSSignature {
        let digest = SHA256.hash(data: data)
        let value = digest
            .map { String(format: "%02X", Int($0)) }
            .joined(separator: ":")

        return DTLSSignature(hashFunction: "sha-256", value: value)
    }

    package static func ephemeralIdentityFingerprint() -> DTLSSignature {
        var error: Unmanaged<CFError>?
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits: 256,
        ]

        guard
            let privateKey = SecKeyCreateRandomKey(attributes as CFDictionary, &error),
            let publicKey = SecKeyCopyPublicKey(privateKey),
            let publicKeyData = SecKeyCopyExternalRepresentation(publicKey, &error) as Data?
        else {
            return random()
        }

        return sha256Fingerprint(for: publicKeyData)
    }

    package static func random() -> DTLSSignature {
        var generator = SystemRandomNumberGenerator()
        let randomBytes = (0..<32).map { _ in
            UInt8.random(in: .min ... .max, using: &generator)
        }
        let value = randomBytes
            .map { String(format: "%02X", Int($0)) }
            .joined(separator: ":")

        return DTLSSignature(hashFunction: "sha-256", value: value)
    }
}

package struct RTCIceCandidateInit: Equatable, Sendable, Codable {
    package var candidate: String
    package var sdpMid: String?
    package var sdpMLineIndex: Int32?
    package var usernameFragment: String?

    package init(
        candidate: String,
        sdpMid: String? = nil,
        sdpMLineIndex: Int32? = nil,
        usernameFragment: String? = nil
    ) {
        self.candidate = candidate
        self.sdpMid = sdpMid
        self.sdpMLineIndex = sdpMLineIndex
        self.usernameFragment = usernameFragment
    }

    package init(
        candidate: ICECandidate,
        sdpMid: String? = nil,
        sdpMLineIndex: Int32? = nil,
        usernameFragment: String? = nil
    ) {
        self.init(
            candidate: candidate.sdpAttributeValue,
            sdpMid: sdpMid,
            sdpMLineIndex: sdpMLineIndex,
            usernameFragment: usernameFragment
        )
    }

    package init(jsonString: String) throws {
        let data = Data(jsonString.utf8)
        self = try JSONDecoder().decode(Self.self, from: data)
    }

    package func jsonString() throws -> String {
        let data = try JSONEncoder().encode(self)
        guard let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }

        return string
    }
}

package struct RemoteICECandidate: Equatable, Sendable {
    package var candidateInit: RTCIceCandidateInit
    package var candidate: ICECandidate?

    package init(candidateInit: RTCIceCandidateInit) {
        self.candidateInit = candidateInit
        self.candidate = try? ICECandidate(sdpAttributeValue: candidateInit.candidate)
    }
}

package struct NativeWebRTCMediaProfile: Equatable, Sendable {
    package var publishVideoCodecs: [RTPCodec]
    package var receiveVideoCodecs: [RTPCodec]
    package var publishAudioCodecs: [RTPCodec]
    package var receiveAudioCodecs: [RTPCodec]
    package var dataChannelCodec: RTPCodec

    package init(
        publishVideoCodecs: [RTPCodec],
        receiveVideoCodecs: [RTPCodec],
        publishAudioCodecs: [RTPCodec],
        receiveAudioCodecs: [RTPCodec],
        dataChannelCodec: RTPCodec
    ) {
        self.publishVideoCodecs = publishVideoCodecs
        self.receiveVideoCodecs = receiveVideoCodecs
        self.publishAudioCodecs = publishAudioCodecs
        self.receiveAudioCodecs = receiveAudioCodecs
        self.dataChannelCodec = dataChannelCodec
    }

    package static let liveKitTiny = NativeWebRTCMediaProfile(
        publishVideoCodecs: [.h264],
        receiveVideoCodecs: [.h264, .vp8],
        publishAudioCodecs: [.opus],
        receiveAudioCodecs: [.opus],
        dataChannelCodec: .webRTCDataChannel
    )
}

package struct NativeWebRTCConfiguration: Equatable, Sendable {
    package var role: PeerConnectionRole
    package var iceServers: [ICEServer]
    package var mediaProfile: NativeWebRTCMediaProfile
    package var iceCredentials: ICECredentials
    package var dtlsFingerprint: DTLSSignature

    package init(
        role: PeerConnectionRole,
        iceServers: [ICEServer] = [],
        mediaProfile: NativeWebRTCMediaProfile = .liveKitTiny,
        iceCredentials: ICECredentials = .random(),
        dtlsFingerprint: DTLSSignature = .ephemeralIdentityFingerprint()
    ) {
        self.role = role
        self.iceServers = iceServers
        self.mediaProfile = mediaProfile
        self.iceCredentials = iceCredentials
        self.dtlsFingerprint = dtlsFingerprint
    }
}

package struct SDPCodecCapability: Equatable, Sendable {
    package var kind: RTPMediaKind
    package var codec: RTPCodec
    package var clockRate: Int
    package var channels: Int?

    package init(kind: RTPMediaKind, codec: RTPCodec, clockRate: Int, channels: Int? = nil) {
        self.kind = kind
        self.codec = codec
        self.clockRate = clockRate
        self.channels = channels
    }
}

package enum PeerConnectionState: String, Equatable, Sendable {
    case new
    case connecting
    case connected
    case disconnected
    case failed
    case closed
}

package enum PeerConnectionNegotiationError: Error, Equatable, Sendable {
    case subscriberAnswerRequestedForPublisher
    case publisherOfferRequestedForSubscriber
    case publisherAnswerAppliedToSubscriber
    case missingRemoteICECredentials
    case missingRemoteDTLSFingerprint
    case missingRemoteDTLSSetupRole
    case missingSelectedICECandidatePair
    case unsupportedRemoteDTLSSetupRole(SDPDTLSSetupRole)
}

package struct PeerConnectionMediaStartupResult: Sendable {
    package var transport: DTLSSRTPMediaTransport
    package var iceSummary: ICEAgentCheckSummary
    package var selectedCandidatePair: ICECandidatePair

    package init(
        transport: DTLSSRTPMediaTransport,
        iceSummary: ICEAgentCheckSummary,
        selectedCandidatePair: ICECandidatePair
    ) {
        self.transport = transport
        self.iceSummary = iceSummary
        self.selectedCandidatePair = selectedCandidatePair
    }
}

package struct RemoteSessionDescription: Equatable, Sendable {
    package var type: String
    package var sdp: String
    package var id: UInt32

    package init(type: String, sdp: String, id: UInt32) {
        self.type = type
        self.sdp = sdp
        self.id = id
    }
}

package final class PeerConnectionCoordinator: @unchecked Sendable {
    package private(set) var state: PeerConnectionState = .new
    private let configurationLock = NSLock()
    private let remoteCandidateLock = NSLock()
    private let remoteDescriptionLock = NSLock()
    private var mutableConfiguration: NativeWebRTCConfiguration
    private var mutableRemoteICECandidates: [RemoteICECandidate] = []
    private var mutableRemoteICEGatheringComplete = false
    private var mutableRemoteAnswer: RemoteSessionDescription?
    private var mutableRemoteICECredentials: ICECredentials?
    private var mutableRemoteDTLSFingerprint: DTLSSignature?
    private var mutableRemoteDTLSSetupRole: SDPDTLSSetupRole?

    package init(configuration: NativeWebRTCConfiguration) {
        self.mutableConfiguration = configuration
    }

    package var configuration: NativeWebRTCConfiguration {
        configurationLock.lock()
        defer { configurationLock.unlock() }
        return mutableConfiguration
    }

    package func updateICEServers(_ iceServers: [ICEServer]) {
        configurationLock.lock()
        defer { configurationLock.unlock() }
        mutableConfiguration.iceServers = iceServers
    }

    package func resetNegotiationState() {
        remoteCandidateLock.lock()
        mutableRemoteICECandidates = []
        mutableRemoteICEGatheringComplete = false
        remoteCandidateLock.unlock()

        remoteDescriptionLock.lock()
        mutableRemoteAnswer = nil
        mutableRemoteICECredentials = nil
        mutableRemoteDTLSFingerprint = nil
        mutableRemoteDTLSSetupRole = nil
        remoteDescriptionLock.unlock()

        state = .new
    }

    package func restartICE() {
        let newCredentials = ICECredentials.random()

        resetNegotiationState()

        configurationLock.lock()
        mutableConfiguration.iceCredentials = newCredentials
        configurationLock.unlock()
    }

    package var remoteICECandidates: [RemoteICECandidate] {
        remoteCandidateLock.lock()
        defer { remoteCandidateLock.unlock() }
        return mutableRemoteICECandidates
    }

    package var parsedRemoteICECandidates: [ICECandidate] {
        remoteICECandidates.compactMap(\.candidate)
    }

    package var isRemoteICEGatheringComplete: Bool {
        remoteCandidateLock.lock()
        defer { remoteCandidateLock.unlock() }
        return mutableRemoteICEGatheringComplete
    }

    package var remoteAnswer: RemoteSessionDescription? {
        remoteDescriptionLock.lock()
        defer { remoteDescriptionLock.unlock() }
        return mutableRemoteAnswer
    }

    package var remoteICECredentials: ICECredentials? {
        remoteDescriptionLock.lock()
        defer { remoteDescriptionLock.unlock() }
        return mutableRemoteICECredentials
    }

    package var remoteDTLSFingerprint: DTLSSignature? {
        remoteDescriptionLock.lock()
        defer { remoteDescriptionLock.unlock() }
        return mutableRemoteDTLSFingerprint
    }

    package var remoteDTLSSetupRole: SDPDTLSSetupRole? {
        remoteDescriptionLock.lock()
        defer { remoteDescriptionLock.unlock() }
        return mutableRemoteDTLSSetupRole
    }

    package var localCapabilities: [SDPCodecCapability] {
        let configuration = configuration
        var capabilities: [SDPCodecCapability] = []

        for codec in configuration.mediaProfile.publishAudioCodecs {
            capabilities.append(SDPCodecCapability(kind: .audio, codec: codec, clockRate: 48_000, channels: 1))
        }

        for codec in configuration.mediaProfile.publishVideoCodecs {
            capabilities.append(SDPCodecCapability(kind: .video, codec: codec, clockRate: 90_000))
        }

        capabilities.append(SDPCodecCapability(kind: .application, codec: configuration.mediaProfile.dataChannelCodec, clockRate: 0))
        return capabilities
    }

    package func close() {
        state = .closed
    }

    package func addRemoteICECandidate(candidateInitJSON: String, isFinal: Bool) throws {
        let parsedCandidate: RTCIceCandidateInit?
        if candidateInitJSON.isEmpty {
            parsedCandidate = nil
        } else {
            parsedCandidate = try RTCIceCandidateInit(jsonString: candidateInitJSON)
        }

        remoteCandidateLock.lock()
        defer { remoteCandidateLock.unlock() }

        if let parsedCandidate {
            mutableRemoteICECandidates.append(RemoteICECandidate(candidateInit: parsedCandidate))
        }

        if isFinal {
            mutableRemoteICEGatheringComplete = true
        }
    }

    package func makeCandidateChecklist(
        localCandidates: [ICECandidate],
        isControlling: Bool
    ) -> ICECandidateChecklist {
        ICECandidateChecklist(
            localCandidates: localCandidates,
            remoteCandidates: parsedRemoteICECandidates,
            isControlling: isControlling
        )
    }

    package func makeICEAgent(
        localCandidates: [ICECandidate],
        role: ICEAgentRole,
        tieBreaker: UInt64,
        nominationPolicy: ICEPairNominationPolicy = .nominateFirstSuccessful,
        checker: any ICEConnectivityChecking = STUNICEConnectivityChecker()
    ) throws -> ICEAgent {
        guard let remoteICECredentials else {
            throw PeerConnectionNegotiationError.missingRemoteICECredentials
        }
        let configuration = configuration

        return ICEAgent(
            localCandidates: localCandidates,
            remoteCandidates: parsedRemoteICECandidates,
            configuration: ICEAgentConfiguration(
                localCredentials: configuration.iceCredentials,
                remoteCredentials: remoteICECredentials,
                role: role,
                tieBreaker: tieBreaker,
                nominationPolicy: nominationPolicy
            ),
            checker: checker
        )
    }

    package func makeSubscriberAnswer(for offerSDP: String) throws -> String {
        let configuration = configuration
        guard configuration.role == .subscriber else {
            throw PeerConnectionNegotiationError.subscriberAnswerRequestedForPublisher
        }

        let offer = try SDPSessionDescription(parsing: offerSDP)
        if let credentials = offer.iceCredentials {
            setRemoteICECredentials(credentials)
        }
        setRemoteDTLSParameters(from: offer)

        return try SubscriberSDPAnswerFactory(
            mediaProfile: configuration.mediaProfile,
            iceCredentials: configuration.iceCredentials,
            dtlsFingerprint: configuration.dtlsFingerprint
        ).makeAnswer(to: offerSDP)
    }

    package func makePublisherOffer(for tracks: [PublisherSDPOfferTrack]) throws -> String {
        let configuration = configuration
        guard configuration.role == .publisher else {
            throw PeerConnectionNegotiationError.publisherOfferRequestedForSubscriber
        }

        return try PublisherSDPOfferFactory(
            mediaProfile: configuration.mediaProfile,
            iceCredentials: configuration.iceCredentials,
            dtlsFingerprint: configuration.dtlsFingerprint
        ).makeOffer(for: tracks)
    }

    package func applyPublisherAnswer(type: String, sdp: String, id: UInt32) throws {
        let configuration = configuration
        guard configuration.role == .publisher else {
            throw PeerConnectionNegotiationError.publisherAnswerAppliedToSubscriber
        }

        let answer = try SDPSessionDescription(parsing: sdp)

        remoteDescriptionLock.lock()
        defer { remoteDescriptionLock.unlock() }
        mutableRemoteICECredentials = answer.iceCredentials
        mutableRemoteDTLSFingerprint = answer.dtlsFingerprint
        mutableRemoteDTLSSetupRole = answer.dtlsSetupRole
        mutableRemoteAnswer = RemoteSessionDescription(type: type, sdp: sdp, id: id)
        state = .connected
    }

    package func makeDTLSSRTPHandshakeConfiguration() throws -> DTLSSRTPHandshakeConfiguration {
        remoteDescriptionLock.lock()
        let fingerprint = mutableRemoteDTLSFingerprint
        let setupRole = mutableRemoteDTLSSetupRole
        remoteDescriptionLock.unlock()

        guard let fingerprint else {
            throw PeerConnectionNegotiationError.missingRemoteDTLSFingerprint
        }
        guard let setupRole else {
            throw PeerConnectionNegotiationError.missingRemoteDTLSSetupRole
        }

        return try DTLSSRTPHandshakeConfiguration(
            role: localDTLSRole(forRemoteSetupRole: setupRole),
            remoteFingerprint: fingerprint
        )
    }

    package func makeSecureMediaTransport(
        selectedCandidatePair: ICECandidatePair,
        binder: DTLSSRTPMediaSessionBinder
    ) async throws -> DTLSSRTPMediaTransport {
        try await binder.makeMediaTransport(
            selectedCandidatePair: selectedCandidatePair,
            handshakeConfiguration: try makeDTLSSRTPHandshakeConfiguration()
        )
    }

    package func startSecureMediaTransport(
        localCandidates: [ICECandidate],
        iceRole: ICEAgentRole,
        tieBreaker: UInt64,
        nominationPolicy: ICEPairNominationPolicy = .nominateFirstSuccessful,
        checker: any ICEConnectivityChecking = STUNICEConnectivityChecker(),
        binder: DTLSSRTPMediaSessionBinder
    ) async throws -> PeerConnectionMediaStartupResult {
        let iceAgent = try makeICEAgent(
            localCandidates: localCandidates,
            role: iceRole,
            tieBreaker: tieBreaker,
            nominationPolicy: nominationPolicy,
            checker: checker
        )
        let summary = await iceAgent.performConnectivityChecks()
        guard let selectedCandidatePair = summary.selectedPair else {
            throw PeerConnectionNegotiationError.missingSelectedICECandidatePair
        }

        let transport = try await makeSecureMediaTransport(
            selectedCandidatePair: selectedCandidatePair,
            binder: binder
        )

        return PeerConnectionMediaStartupResult(
            transport: transport,
            iceSummary: summary,
            selectedCandidatePair: selectedCandidatePair
        )
    }

    private func setRemoteICECredentials(_ credentials: ICECredentials) {
        remoteDescriptionLock.lock()
        defer { remoteDescriptionLock.unlock() }
        mutableRemoteICECredentials = credentials
    }

    private func setRemoteDTLSParameters(from description: SDPSessionDescription) {
        remoteDescriptionLock.lock()
        defer { remoteDescriptionLock.unlock() }
        mutableRemoteDTLSFingerprint = description.dtlsFingerprint
        mutableRemoteDTLSSetupRole = description.dtlsSetupRole
    }

    private func localDTLSRole(forRemoteSetupRole setupRole: SDPDTLSSetupRole) throws -> DTLSSRTPRole {
        switch setupRole {
        case .active:
            return .server
        case .passive:
            return .client
        case .actpass where configuration.role == .subscriber:
            return .client
        case .actpass, .holdconn:
            throw PeerConnectionNegotiationError.unsupportedRemoteDTLSSetupRole(setupRole)
        }
    }
}
