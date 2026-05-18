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
            "ICEAgent nomination, local ICE trickle signaling, server ICE server configuration application, STUN UDP server-reflexive candidate gathering, bound local ICE UDP host candidate gathering and socket reuse for STUN checks and media datagrams, default Room socket-backed subscriber/publisher startup configuration, OpenSSL-backed WebRTC DTLS-SRTP use_srtp handshake/exporter wiring, DTLS-SRTP packet protection, SDP DTLS role/fingerprint extraction, handshaker-backed media-session binding with result role/profile validation, injected Room publisher/subscriber media startup, injected selected-pair ICE consent freshness loop with transport closure on expiry, injected publisher transport teardown, Room publisher RTP/RTCP and subscriber RTCP bridges through injected secure media transport, publisher and subscriber RTCP receive-handler loops, deterministic NACK/PLI RTCP feedback policy primitives, bounded subscriber feedback planning from H.264/VP8 RTP loss signals, Room subscriber feedback dispatch through injected subscriber RTCP transport, bounded RTP jitter-buffer primitives, stateful Opus/H.264 publisher RTP packetizer bridges, Room publisher RTP sender registry lifecycle coverage, and encoded publisher audio/video send hooks exist, but production readiness still needs LiveKit server E2E secure RTP/RTCP integration, default TURN relay selection, Apple-platform OpenSSL packaging validation, and the remaining media pipeline gates.",
            "Fresh join, resume reconnect, disconnect, and failed signal-loop boundaries regenerate local ICE credentials, clear stale peer negotiation state, parse TURN UDP/TCP/TLS endpoint configuration, select supported TURN UDP relay session configurations from parsed ICE server endpoints with credentials, exercise TURN Allocate, Refresh, CreatePermission, and ChannelBind request/authentication/response-validation primitives with one-shot stale nonce retry, cover TURN ChannelData framing, provide deterministic allocation/permission maintenance scheduling and execution, plan relayed ICE candidates from TURN bindings, compose and execute a bounded TURN relay session setup plan over abstract transports, expose a ChannelData relay transport over an abstract media datagram transport, and provide deterministic ICE consent freshness planning plus an injected Room startup loop, but full ICE restart signaling, default TURN relay allocation/socket integration, UDP/TCP/TLS fallback, and live media recovery are not implemented.",
            "H.264/VP8/Opus media send/receive paths are not end-to-end integrated.",
            "Production H.264 must use real VideoToolbox encode/decode paths, verify hardware acceleration where the OS exposes that signal, and define explicit fallback behavior instead of relying on a pure Swift codec implementation.",
            "SCTP data channel support includes packet-level DCEP/DataPacket planning, manager-assigned stream routing, queued local publish flushing, inbound DataPacket-to-RoomEvent plumbing, and OpenSSL DTLS application-data transport coverage, but full standards-compliant SCTP chunking, retransmission, congestion control, default live Room association wiring, and data-channel recovery are incomplete.",
            "Signal reconnect resets stale peer negotiation state, restarts local ICE credentials, sends SyncState for retained subscription/local media/data publication state plus last negotiated SDP answer/offer state, preserves publisher offer track state for later publish/unpublish re-offers, and clears stale local media/data publication state for server/SFU unpublish responses in unit tests, but live media recovery, data channel recovery, and LiveKit integration hardening are incomplete.",
            "General production video meetings require meeting-grade audio capture/playout, echo cancellation, route changes, Bluetooth behavior, interruptions, background/foreground handling, and validated timing on real iOS devices.",
            "An RTP jitter-buffer primitive exists, but general production video meetings still require default subscriber jitter-buffer integration, packet-loss recovery, RTCP feedback handling, bandwidth estimation, congestion control, adaptive quality, and bounded backpressure/frame-drop policy.",
            "General production video meetings require automated multi-participant, weak-network, TURN-only, reconnect, long-running soak, battery, and thermal tests on real devices.",
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
