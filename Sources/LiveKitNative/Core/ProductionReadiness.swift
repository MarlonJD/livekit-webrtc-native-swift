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
            "DTLS-SRTP media transport is not implemented.",
            "TURN TCP/TLS fallback and ICE restart hardening are not implemented.",
            "H.264/VP8/Opus media send/receive paths are not end-to-end integrated.",
            "SCTP data channel support is packet-level only and not connected to a live DTLS transport.",
            "Reconnect resume and full reconnect fallback are not production-hardened.",
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
