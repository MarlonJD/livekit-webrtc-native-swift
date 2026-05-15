public enum LiveKitNativeReleaseStatus: String, Equatable, Sendable {
    case developerPreview
    case releaseCandidate
    case productionReady
}

public struct LiveKitNativeProductionReadiness: Equatable, Sendable {
    public let status: LiveKitNativeReleaseStatus
    public let blockers: [String]
    public let warnings: [String]

    public var isProductionReady: Bool {
        status == .productionReady && blockers.isEmpty
    }

    public init(
        status: LiveKitNativeReleaseStatus,
        blockers: [String],
        warnings: [String] = []
    ) {
        self.status = status
        self.blockers = blockers
        self.warnings = warnings
    }
}

public extension LiveKitNative {
    static let productionReadiness = LiveKitNativeProductionReadiness(
        status: .developerPreview,
        blockers: [
            "DTLS-SRTP packet protection and nominated ICE-pair guarded media transport exist, but they are not bound to a live ICE agent, completed DTLS handshake, exporter output, or UDP socket transport.",
            "TURN TCP/TLS fallback and ICE restart hardening are not implemented.",
            "H.264/VP8/Opus media send/receive paths are not end-to-end integrated.",
            "SCTP data channel support is packet-level only and not connected to a live DTLS transport.",
            "Signal reconnect is unit-tested only; ICE restart, media recovery, and LiveKit integration hardening are incomplete.",
            "End-to-end LiveKit server compatibility tests are not automated in CI."
        ],
        warnings: [
            "The public API shape is intentionally close to LiveKit Swift SDK v2, but behavior is still a native Swift preview.",
            "Use the package for protocol, signaling, and engine development until production readiness is promoted."
        ]
    )

    static func assertProductionReady() throws {
        guard productionReadiness.isProductionReady else {
            throw LiveKitNativeError.productionReadinessFailed(productionReadiness.blockers)
        }
    }
}
