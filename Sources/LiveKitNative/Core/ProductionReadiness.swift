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
            "ICEAgent nomination, local ICE trickle signaling, server ICE server configuration application, STUN UDP server-reflexive candidate gathering, bound local ICE UDP host candidate gathering and socket reuse for STUN checks and media datagrams, default Room socket-backed subscriber/publisher media-data startup configuration, OpenSSL-backed WebRTC DTLS-SRTP use_srtp handshake/exporter wiring, DTLS-SRTP packet protection, RFC 5764 DTLS/SRTP datagram demux, shared persistent DTLS application-data plus SRTP session binding, SDP DTLS role/fingerprint extraction, handshaker-backed media-session binding with result role/profile validation, injected Room publisher/subscriber media startup, injected selected-pair ICE consent freshness loop with transport closure on expiry, injected publisher transport teardown, Room publisher RTP/RTCP and subscriber RTCP bridges through injected secure media transport, publisher and subscriber RTCP receive-handler loops, deterministic NACK/PLI RTCP feedback policy primitives, bounded subscriber feedback planning from H.264/VP8 RTP loss signals, Room subscriber feedback dispatch through injected subscriber RTCP transport, bounded RTP jitter-buffer primitives, stateful Opus/H.264 publisher RTP packetizer bridges, native camera/microphone publisher capture pipelines, Room publisher RTP sender registry lifecycle coverage, and subscriber RTP jitter-buffer/feedback dispatch exist, but production readiness still needs LiveKit server E2E secure RTP/RTCP integration, default TURN relay execution, Apple-platform OpenSSL packaging validation, and the remaining media pipeline gates.",
            "Fresh join, resume reconnect, disconnect, and failed signal-loop boundaries regenerate local ICE credentials, clear stale peer negotiation state, parse TURN UDP/TCP/TLS endpoint configuration, order TURN relay fallback candidates as UDP, TCP, then TLS while identifying the currently executable UDP datagram path, select supported TURN UDP relay session configurations from parsed ICE server endpoints with credentials, exercise TURN Allocate, Refresh, CreatePermission, and ChannelBind request/authentication/response-validation primitives with one-shot stale nonce retry, cover TURN ChannelData framing, provide deterministic allocation/permission maintenance scheduling and execution, plan relayed ICE candidates from TURN bindings, compose and execute a bounded TURN relay session setup plan over abstract transports, expose a ChannelData relay transport over an abstract media datagram transport, allocate default UDP TURN relay candidates through the bound Room ICE socket, use ChannelData relay bindings for relayed ICE checks and media datagrams, provide deterministic ICE consent freshness planning plus an injected Room startup loop, run ICEAgent connectivity checks through paced scheduling with queued triggered-check priority plus role-conflict role switching and pair-priority recompute, and rebuild reconnect SyncState SDP/trickle state with fresh local ICE credentials, but TCP/TLS TURN transport execution, LiveKit TURN-only validation, and live media recovery are not complete.",
            "Publisher camera capture can encode H.264 through VideoToolbox with bounded frame backpressure/drop control and publisher microphone capture can encode Opus through AudioToolbox before RTP/SRTP send, while subscriber RTP can pass through jitter buffering, H.264/Opus packet assembly, and NACK/PLI feedback; default decoded video rendering, default audio playout wiring, LiveKit E2E media validation, and production runtime pacing remain incomplete.",
            "Production H.264 now uses real VideoToolbox encode output for publish smoke coverage, but production readiness still requires full decode/render, hardware acceleration verification where the OS exposes that signal, and explicit fallback behavior instead of relying on a pure Swift codec implementation.",
            "SCTP data channel support includes packet-level DCEP/DataPacket planning, manager-assigned stream routing, queued local publish flushing, inbound DataPacket-to-RoomEvent plumbing, OpenSSL DTLS application-data transport coverage, default Room shared-media DTLS/SRTP demux binding, deterministic packet fragmentation/reassembly envelopes, fragmented-packet retransmission scheduling on the DTLS-backed packet transport, and recovery reset that reopens LiveKit data channels after association restart, but full standards-compliant SCTP association state, congestion control, LiveKit-validated data-channel recovery, and E2E hardening are incomplete.",
            "Signal reconnect resets stale peer negotiation state, restarts local ICE credentials, rebuilds retained subscriber answer and publisher offer SDP with fresh ICE credentials, sends SyncState for retained subscription/local media/data publication state, re-sends local ICE trickle/final-trickle when media startup is configured, preserves publisher offer track state for later publish/unpublish re-offers, clears stale local media/data publication state for server/SFU unpublish responses, and resets injected publisher data channels for post-reconnect DCEP reopen in unit tests, but live media recovery and LiveKit integration hardening are incomplete.",
            "General production video meetings require meeting-grade audio capture/playout, echo cancellation, route changes, Bluetooth behavior, interruptions, background/foreground handling, and validated timing on real iOS devices.",
            "A default subscriber RTP receive pipeline now integrates jitter buffering with bounded NACK/PLI feedback, scheduled RTCP Receiver Reports with DLSR timing from observed RTP/Sender Report state, REMB bitrate-feedback packet planning/sending, deterministic RTCP receiver-report bandwidth estimation, adaptive video quality recommendations, publisher RTCP receiver-report ingestion, H.264 encoder bitrate/FPS recommendation application, opt-in automatic subscriber adaptive track-settings dispatch, and camera publish frame backpressure primitives, but general production video meetings still require full packet-loss recovery, TWCC/full REMB interop or equivalent congestion control, default-on LiveKit-validated subscriber adaptation policy, complete encoder control policy, and weak-network E2E validation.",
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
