# LiveKitNative Status

Last updated: 2026-05-17

## Current State

`LiveKitNative` has completed the `0.6.0` developer-preview scope and is now
in `1.0.0-dev` hardening. It is not yet a working end-to-end production media
client.

Production readiness is intentionally represented in code through
`LiveKitNative.productionReadiness` and `LiveKitNative.assertProductionReady()`.
The current status is `developerPreview`, with explicit blockers for the real
DTLS-SRTP `use_srtp` handshake/exporter implementation, TURN/ICE hardening,
default live secure media completion, VideoToolbox-backed production H.264
encode/decode with hardware path verification and fallback policy, DTLS-backed SCTP, media
recovery during reconnect, meeting-grade audio, jitter buffering, packet-loss
recovery, congestion control, adaptive quality, real-device iOS
soak/performance tests, and end-to-end LiveKit compatibility testing.
Publisher `AddTrackRequest` signaling is now wired for local audio/video
publishes, publisher SDP offers are generated and sent after
`TrackPublishedResponse`, and publisher answers and publisher-targeted trickle
candidates are routed into the publisher peer connection adapter, but media
sender capture/encode pipeline and end-to-end live media transport are still
open.
Data-track publish/unpublish/update-subscription signaling is also wired at
unit-test level, including server/SFU data-track unpublish cleanup for local
publication and reconnect state; live SCTP transport remains open.
Server/SFU `TrackUnpublishedResponse` cleanup for local media publications also
clears local publication state and cached publisher offer reconnect state so
resume reconnects and later publisher offers do not replay removed media.
Injected publisher media transports are now closed and cleared when the final
local media track is unpublished, preventing stale SRTP transport use in the
covered Room media startup path.
Server-provided `JoinResponse.ice_servers` and
`ReconnectResponse.ice_servers` are now retained in the subscriber and
publisher peer connection configurations. In the injected bound-socket media
startup path, supported `stun:` UDP URLs can be queried for server-reflexive
candidate discovery while preserving socket reuse. TURN ICE server URLs are
also parsed from `turn:` and `turns:` entries with UDP/TCP/TLS intent and
credentials retained for future relay allocation, and TURN Allocate, Refresh,
CreatePermission, and ChannelBind request primitives now cover requested
transport, lifetime, realm, nonce, `ERROR-CODE`, relayed-address decoding,
IPv4 `XOR-PEER-ADDRESS`, and channel-number validation. TURN allocation,
refresh, permission, and channel-bind clients can send requests over the STUN
datagram transport abstraction, validate success/error responses, and perform
the covered long-term credential authentication plus one-shot stale nonce retry
behavior at unit-test level. TURN ChannelData framing now covers encode/decode,
stream parsing, 4-byte padding, and invalid frame rejection, and deterministic
TURN allocation/permission maintenance planning now calculates refresh
deadlines without a wall-clock dependency, schedules due refresh actions in
deadline order, executes due allocation/permission refreshes through injectable
network closures, and advances deadlines only on successful refresh. TURN relay
candidate planning can build relayed ICE candidates from relayed addresses and
channel bindings. TURN relay session configuration can now select supported UDP
relay endpoints from parsed ICE server URLs when credentials, realm, and nonce
are available. A bounded TURN relay session now composes allocation, permission
creation, channel binding, relay candidate planning, relay transport metadata,
and deterministic maintenance execution over abstract transports, and a setup
plan can create and execute that configured session over scripted abstract
transports. A ChannelData
relay transport can encode outbound payloads and decode inbound packets over an
abstract media datagram transport with partial stream remainder handling.
Deterministic ICE consent freshness planning now models selected-pair consent
check deadlines, timeout expiry, bounded failure expiry, disabled policy, and
clamped jitter without a wall-clock dependency, and an injectable consent
freshness executor can advance success/failure/expiry state in unit tests.
Injected Room media startup now starts a selected-pair consent freshness loop
after secure transport binding and closes the protected transport when consent
expires. Public `Room` initialization now installs default socket-backed
subscriber and publisher media startup configurations, so the live path can
gather host candidates lazily, add supported STUN server-reflexive candidates,
send local trickle/final-trickle signaling, reuse the bound ICE socket for
checks/media datagrams, and then fail explicitly at the unavailable Apple
DTLS-SRTP handshaker boundary instead of silently skipping media startup.
Fresh
join, reconnect, and disconnect paths now
reset stale
remote SDP, ICE candidate, and final-trickle state and regenerate local ICE
credentials without replacing the rest of the local peer connection
configuration. Resume reconnect `SyncState` now includes
retained subscription preferences, disabled track SIDs, local media/data
publications, and the latest negotiated subscriber answer / publisher offer SDP
state at unit-test level, while publisher offer track state is preserved so
later publishes after resume do not drop existing local media sections.
Room-level publisher RTP sending can now hand packets to a started injected
secure media transport in tests, and stateful Opus/H.264 publisher RTP bridges
keep packetizer sequence and timestamp state across packets/frames before that
handoff. Room stores publisher audio/video RTP sender state by published SID
and local CID after successful publish, removes only the unpublished sender
after successful unpublish, preserves remaining local sender state for resume
reconnect, and clears sender state on full publisher offer reset. Encoded Opus
packets and H.264 frames can now be sent through the stored publisher senders
by published SID, publisher RTCP packets can be handed to the injected secure
media transport, inbound publisher RTCP can be decoded through a registered
handler loop, subscriber RTCP packets can be handed to the injected secure
media transport, and inbound subscriber RTCP can be decoded through a registered
handler loop. A deterministic RTCP feedback policy primitive can now build
Generic NACK and PLI packets from subscriber-side packet-loss/keyframe needs,
and a subscriber feedback planner maps H.264/VP8 RTP sequence gaps plus
explicit keyframe requests into bounded RTCP feedback packets that Room can
dispatch through the injected subscriber RTCP transport. A bounded RTP jitter
buffer primitive can release contiguous packets, skip bounded gaps, report
missing sequence numbers, drop duplicate/old packets, flush in sequence order,
and preserve ordering across sequence-number wrap; the default capture/encode
loop, default subscriber jitter-buffer integration, and subscriber-pipeline
feedback dispatch remain open.

The repository now has one public SwiftPM product, `LiveKitNative`, with
internal targets for LiveKit protobuf code and the tiny Swift WebRTC engine.
The old binary WebRTC dependency path has been removed from the package model.

## Package Shape

- Public product: `LiveKitNative`
- Public SDK target: `LiveKitNative`
- Internal implementation targets:
  - `LiveKitNativeProtocol`
  - `LiveKitNativeWebRTC`
- Benchmark target:
  - `LiveKitNativeBenchmarks`
- Test targets:
  - `LiveKitNativeTests`
  - `LiveKitNativeIntegrationTests`
- External dependency:
  - `swift-protobuf`
- Explicitly forbidden:
  - Rust toolchain or `.rs` sources
  - UniFFI bridge dependencies
  - `LiveKitWebRTC.xcframework`
  - BoringSSL
  - libopus
  - libvpx

## Implemented

### SDK Skeleton

- Swift 6 package manifest for iOS 13+ and macOS 10.15+.
- Apache-2.0 license, notice file, README, DocC landing page, privacy manifest,
  and CI workflow.
- Public API shell for:
  - `Room`
  - `RoomEvent`
  - `RoomDelegate`
  - `Participant`
  - local and remote participant models
  - track and track publication models
  - UIKit/AppKit `VideoView`
- Actor-backed room state with idempotent participant updates by SID/identity.
- Explicit production-readiness API:
  - `LiveKitNative.productionReadiness`
  - `LiveKitNative.assertProductionReady()`
  - typed `productionReadinessFailed` error with blocker details
- Configurable SDK logging through `LiveKitNativeLogging` with an OSLog-backed
  default logger.
- Release-mode microbenchmark executable and documentation:
  - `swift run -c release LiveKitNativeBenchmarks`
  - `docs/BENCHMARKS.md`
  - optional external CSV baseline comparison for official SDK/WebRTC numbers
- Release-readiness scripts:
  - `scripts/check_release_readiness.sh`
  - `scripts/check_release_size.sh`
  - strict production mode through `REQUIRE_PRODUCTION_READY=1`
- `LocalParticipant` has local video publication state for camera tracks,
  including idempotent `setCamera(enabled:)`, `publish(videoTrack:)`, and
  `unpublish(publication:)` behavior.

### Signaling Groundwork

- `/rtc` signal URL builder with token, reconnect, auto-subscribe, SDK version,
  and `protocol=9` query parameters.
- Binary protobuf frame codec using `SwiftProtobuf`.
- `SignalTransport` abstraction over WebSocket-style binary/text frames.
- `URLSessionWebSocketSignalTransport` with send, receive, ping, and close
  behavior.
- `SignalConnection` actor for connection state, encode/decode, send, receive,
  ping, and close.
- `Room.connect` now opens the signal connection, waits for the initial
  `SignalResponse.join`, applies local participant identity from
  `JoinResponse.participant`, and hydrates remote participants from
  `JoinResponse.otherParticipants`.
- Remote participant snapshots now map LiveKit `TrackInfo` entries into
  idempotent `RemoteTrackPublication` state and emit `trackPublished` events
  for newly observed track SIDs.
- A post-join signal receive loop now consumes `ParticipantUpdate`,
  `refresh_token`, `TrickleRequest`, `TrackUnpublishedResponse`,
  `LeaveRequest`, and `ReconnectResponse` messages.
- `ParticipantUpdate` messages flow through the same idempotent participant and
  track publication reducers used by the initial join snapshot.
- Participant updates with disconnected participant state remove the remote
  participant and emit `trackUnpublished` plus `participantDisconnected` events.
- `TrackUnpublishedResponse` removes the matching remote publication and emits a
  `trackUnpublished` event.
- `TrackUnpublishedResponse` for a local media publication clears the matching
  local publication and cached publisher offer reconnect state so resume
  reconnects and later publisher offers do not replay removed media.
- `refresh_token` messages emit a `RoomEvent.tokenRefreshed` event.
- Refreshed signal tokens are retained and used by later resume/full reconnect
  attempts.
- `LeaveRequest` messages transition to `disconnected` for disconnect actions
  and to `reconnecting` for resume/reconnect actions.
- Server-initiated `MuteTrackRequest` messages update local or remote track
  publication mute state and emit `RoomEvent.trackMuteChanged`.
- `SignalResponse.requestResponse` messages are correlated by request ID for
  client-originated signaling requests.
- `LocalParticipant.setMetadata`, `setName`, and `setAttributes` send
  `UpdateParticipantMetadata` requests, await LiveKit `RequestResponse`, map
  permission failures to typed SDK errors, and apply local state only after
  successful acknowledgement.
- `LocalParticipant.publish(videoTrack:)` and `publish(audioTrack:)` send
  LiveKit `AddTrackRequest` messages over the active signal connection, await
  the matching `TrackPublishedResponse` by local CID, and record local
  publications from the server-returned `TrackInfo`. Matching
  `RequestResponse` failures are mapped to typed SDK errors while waiting for
  the publish response.
- After media publish acknowledgement, publisher SDP offers are generated from
  local audio/video publish plans and sent as LiveKit `SignalRequest.offer`
  messages for the publisher negotiation path.
- `LocalParticipant.setTrackMuted(publication:muted:)` sends LiveKit
  `MuteTrackRequest` messages for local publications, waits for a matching
  `RequestResponse` acknowledgement, maps failures to typed SDK errors, and
  updates local mute state after acknowledgement succeeds.
- `LocalParticipant.unpublish(publication:)`, `setCamera(enabled: false)`, and
  `setMicrophone(enabled: false)` send a muted `MuteTrackRequest` before
  removing local publications when the participant is attached to a connected
  room, and now wait for matching `RequestResponse` acknowledgements.
  Multi-track unpublish also removes the unpublished track from publisher offer
  state, sends a refreshed publisher offer for the remaining local media, and
  updates reconnect `SyncState` to avoid replaying stale media sections. When
  the last media track is unpublished, cached publisher offer state is cleared
  so resume reconnect does not replay stale media, and the injected publisher
  media transport is closed and cleared.
- `Room.updateSubscription(trackSIDs:subscribe:)` sends LiveKit
  `UpdateSubscription` messages for media tracks, and
  `Room.updateTrackSettings(...)` sends `UpdateTrackSettings` messages for
  subscribed track pause, quality, resolution, FPS, and priority preferences.
- `LocalParticipant.setTrackSubscriptionPermissions(...)` sends LiveKit
  `SubscriptionPermission` messages for publisher-controlled subscriber access
  to all local tracks or selected track SIDs.
- `LocalParticipant.updateAudioTrack(...)` and `updateVideoTrack(...)` send
  LiveKit `UpdateLocalAudioTrack` / `UpdateLocalVideoTrack` messages for local
  publisher track feature and dimension updates and wait for matching
  `RequestResponse` acknowledgements.
- `SignalResponse.trackPublished` messages are correlated by local CID for
  client-originated publish requests.
- `SignalResponse.answer` messages are routed into the publisher peer
  connection adapter so server answers are retained for the publish negotiation
  path.
- Public `Room.disconnect()` clears remote participants, removes remote track
  publications, sends a client-initiated `LeaveRequest`, emits cleanup
  lifecycle events, closes signaling, and clears pending request-response
  state.
- `JoinResponse.alternative_url` is retried with a bounded redirect budget.
- `LeaveRequest.resume` reconnects the signal socket with `reconnect=true` and
  accepts `ReconnectResponse`.
- `JoinResponse.ice_servers` and `ReconnectResponse.ice_servers` are mapped
  into both subscriber and publisher peer connection configurations.
- Fresh joins, `ReconnectResponse`, and disconnect clear stale peer negotiation
  state and regenerate local ICE credentials before a new signaling/media
  negotiation can begin.
- Resume reconnects send LiveKit `SyncState` for retained media subscription
  preferences, disabled subscribed track SIDs, local media publications, and
  local data-track publications at unit-test level.
- Resume reconnects include the latest negotiated subscriber answer and
  publisher offer SDP state in `SyncState` when those descriptions were sent
  before reconnecting.
- Resume reconnects preserve publisher offer track state so a later local media
  publish generates a publisher offer that still includes pre-reconnect local
  publications.
- `LeaveRequest.reconnect` performs a fresh signal join with `reconnect=false`
  and replaces stale remote participant state with cleanup events.
- `ConnectOptions` exposes reconnect attempt, retry delay, and alternative URL
  redirect limits.
- `SignalResponse.offer` is routed into the subscriber peer connection adapter,
  which generates a minimal SDP answer and sends it back as
  `SignalRequest.answer`.
- Subscriber SDP answer generation preserves offered BUNDLE MIDs, accepts the
  tiny receive profile codecs (Opus, H.264, VP8, WebRTC data channel), filters
  unsupported codec payloads, and answers media sections as receive-only.
- SDP answers now emit local `a=ice-ufrag`, `a=ice-pwd`,
  `a=fingerprint:<algorithm> <value>`, and `a=ice-options:trickle` lines so the
  answer is closer to a real negotiation payload.
- Subscriber-targeted trickle messages decode `RTCIceCandidateInit` JSON and
  store remote ICE candidates on the subscriber peer connection adapter,
  including end-of-candidates state.
- Publisher-targeted trickle messages are routed to the publisher peer
  connection adapter with the same candidate decode and end-of-candidates
  handling.
- `SignalResponse.speakers_changed`, `connection_quality`, and
  `stream_state_update` now emit public `RoomEvent` values with typed payloads.
- `SignalResponse.room_update`, `subscribed_quality_update`,
  `subscription_permission_update`, `subscription_response`, and
  `track_subscribed` now emit public `RoomEvent` values with typed payloads.
- `SignalResponse.media_sections_requirement`,
  `subscribed_audio_codec_update`, `publish_data_track_response`,
  `unpublish_data_track_response`, and `data_track_subscriber_handles` now
  emit public `RoomEvent` values with typed payloads.
- Media section requirements and data-track subscriber handles are also retained
  as latest-value Room snapshot state and cleared by public `Room.disconnect()`
  and fresh joins.
- `SignalResponse.room_moved` now updates local/remote participant state,
  refreshes the reconnect token, emits `RoomEvent.roomMoved`, and publishes
  cleanup/addition lifecycle events for participant changes.
- Non-join initial signal frames close the connection, return the room to
  `disconnected`, and surface a typed signal frame error.
- Mock signal transport for unit tests.

### Protocol Pinning

- LiveKit protocol revision is pinned to:
  `765a80e4298e376593859c3f11cf748c725f68f9`
- `scripts/generate_protocol_sources.sh` exists to regenerate vendored Swift
  protobuf sources from the pinned LiveKit protocol revision.
- Client signaling protobuf sources are vendored from the pinned revision:
  - `logger/options.proto`
  - `livekit_metrics.proto`
  - `livekit_models.proto`
  - `livekit_rtc.proto`
- `SignalRequestFrame` and `SignalResponseFrame` now alias the generated
  `Livekit_SignalRequest` and `Livekit_SignalResponse` types.

### Tiny Swift WebRTC Groundwork

- Internal `LiveKitNativeWebRTC` target.
- Tiny LiveKit media profile:
  - publish video: H.264
  - receive video: H.264 and VP8
  - audio: Opus
  - data: WebRTC data channel profile placeholder
- SDP parser/writer basics:
  - line parsing
  - BUNDLE MIDs
  - media sections
  - MID extraction
  - codec name extraction
  - CRLF serialization
- STUN basics:
  - Binding request/response message type support
  - transaction ID handling
  - message encode/decode
  - magic cookie validation
  - attribute padding
  - ICE attributes such as username, priority, use-candidate, controlled, and
    controlling
  - IPv4 `XOR-MAPPED-ADDRESS` encode/decode groundwork for Binding success
    responses
  - `MESSAGE-INTEGRITY` HMAC-SHA1 signing and validation with RFC 5769 vector
    coverage
  - `FINGERPRINT` CRC32 signing and validation with tamper detection tests
  - TURN Allocate request/success/error message type support
  - TURN Refresh, CreatePermission, and ChannelBind request/success/error
    message type support
  - TURN `REQUESTED-TRANSPORT`, `LIFETIME`, `REALM`, `NONCE`, `ERROR-CODE`,
    IPv4 `XOR-RELAYED-ADDRESS`, IPv4 `XOR-PEER-ADDRESS`, and `CHANNEL-NUMBER`
    encode/decode primitives
  - TURN allocation request/response client over the STUN datagram transport
    abstraction, including relayed-address/lifetime parsing, transaction
    validation, response `MESSAGE-INTEGRITY` / `FINGERPRINT` validation, and
    one long-term credential 401 `REALM` / `NONCE` challenge retry
  - TURN refresh request/response client with lifetime parsing, deallocation
    lifetime support, transaction validation, optional response integrity /
    fingerprint validation, and error-code mapping
  - TURN CreatePermission request/response client with IPv4 peer-address
    encoding, transaction validation, optional response integrity / fingerprint
    validation, and error-code mapping
  - TURN ChannelBind request/response client with channel-number range
    validation, IPv4 peer-address encoding, optional response integrity /
    fingerprint validation, and error-code mapping
  - one-shot stale nonce retry for authenticated TURN Allocate, Refresh,
    CreatePermission, and ChannelBind flows
  - TURN ChannelData frame encode/decode with channel-range validation,
    declared-length validation, and 4-byte padding
  - TURN ChannelData stream parsing that returns complete frames and preserves
    partial trailing bytes as remainder
  - deterministic TURN allocation and permission maintenance planning with
    safety margins and wall-clock-free refresh/expiry decisions
  - deterministic TURN maintenance scheduler that returns allocation and
    permission due actions in deadline order, flags expired state, reports the
    next future deadline, and updates deadlines after refresh success
  - deterministic TURN maintenance executor that calls injectable allocation
    and permission refresh closures, records success lifetimes back into the
    scheduler, reports expired actions, and leaves deadlines unchanged on
    refresh failure
  - deterministic ICE consent freshness policy/session planning for selected
    candidate pairs, including check deadlines, timeout expiry, consecutive
    failure expiry, disabled policy, and clamped jitter
  - injectable ICE consent freshness executor primitive that records
    success/failure state and reports timeout/failure expiry
  - injected Room publisher/subscriber media startup can run a selected-pair
    consent freshness loop and close the protected transport on expiry
  - bounded RTP jitter buffer primitive for contiguous release, duplicate/old
    packet drops, bounded gap skip, missing-sequence reporting, flush ordering,
    and 16-bit sequence-number wrap
  - TURN relay ICE candidate planning from relayed addresses and ChannelBind
    metadata, including relayed candidate priority/foundation selection
  - TURN relay session configuration selection from parsed ICE server
    endpoints, requiring supported UDP transport intent plus endpoint
    credentials, realm, and nonce
  - bounded TURN relay session orchestration that composes Allocate,
    CreatePermission, ChannelBind, relayed ICE candidate planning, ChannelData
    relay transport metadata, and deterministic maintenance execution over
    abstract transports
  - deterministic TURN relay setup plan factory/execution that carries
    credentials, endpoint, relayed transport, peer address, channel number,
    lifetime preferences, and candidate preference metadata over abstract
    transports
  - TURN ChannelData relay transport over `MediaDatagramTransport` that
    encodes outbound payloads, decodes inbound channel-bound packets, keeps
    partial stream remainder, rejects unbound channels, and preserves peer
    endpoint metadata
- ICE basics:
  - local ICE username fragment and password generation
  - host candidate construction from local interface addresses
  - UDP STUN datagram transport abstraction and Darwin UDP socket transport
  - bounded STUN Binding transport retry policy for connectivity checks
  - remote trickle candidate JSON decoding and storage
  - end-of-candidates tracking
  - candidate type preferences
  - candidate priority calculation
  - candidate pair priority calculation
  - candidate pair checklist state and nomination tracking
  - SDP `candidate:` attribute parsing into typed ICE candidates
  - SDP `ice-ufrag` / `ice-pwd` extraction into typed remote ICE credentials
  - trickled remote ICE candidates are exposed as parsed candidates on the peer
    connection coordinator
  - candidate checklists can accept dynamically trickled local and remote
    candidates while maintaining priority order
  - peer connection coordinator can build an `ICEAgent` from local candidates,
    parsed remote trickle candidates, local ICE credentials, and remote SDP
    ICE credentials
  - `ICEAgent` actor can unfreeze prioritized candidate pairs, run bounded
    STUN connectivity checks, mark failed pairs, nominate the first successful
    pair, expose the selected pair, and support validate-only nomination handoff
  - basic SDP candidate attribute serialization
  - connectivity-check Binding request construction with ICE username,
    priority, role, and use-candidate attributes
  - connectivity-check requests are sent with `MESSAGE-INTEGRITY` and
    `FINGERPRINT`
  - authenticated Binding responses validate `FINGERPRINT` and
    `MESSAGE-INTEGRITY` before mapped-address handling
  - Binding success response handling for server-reflexive mapped address
    discovery
  - signaling `ICEServer` URL parsing for supported `stun:` UDP endpoints
  - unauthenticated STUN Binding mapped-address requests with optional
    response fingerprint validation
  - server-reflexive local candidate construction from STUN mapped-address
    responses, with duplicate mapped endpoints ignored
- DTLS/SRTP groundwork:
  - SHA-256 fingerprint formatting
  - certificate-DER SHA-256 fingerprint helper for real DTLS identity wiring
  - case-normalized DTLS fingerprint comparison
  - ephemeral Security framework key material for preview SDP fingerprint generation
  - SDP `fingerprint` and `setup` role extraction for remote offers/answers,
    including media-level fallback when session-level attributes are absent
  - DTLS-SRTP protection profile metadata for
    `SRTP_AES128_CM_HMAC_SHA1_80` and `SRTP_AES128_CM_HMAC_SHA1_32`
  - DTLS-SRTP `use_srtp` extension encode/decode, MKI handling, malformed
    payload rejection, and first-supported profile selection
  - `DTLSSRTPHandshakeConfiguration` carrying the local DTLS role, remote
    fingerprint, and `use_srtp` offer data for a real handshaker
  - DTLS-SRTP exporter output splitting into client/server SRTP master
    keys and salts
  - typed `DTLSSRTPHandshakeResult` that carries negotiated role, protection
    profile, exported keying material, and optional remote fingerprint from a
    completed future handshake
  - `PeerConnectionCoordinator` stores remote DTLS fingerprint/setup data from
    subscriber offers and publisher answers, then derives the local DTLS
    client/server role for handshake startup
  - `PeerConnectionCoordinator` can hand negotiated DTLS configuration and a
    nominated ICE pair into the handshaker-backed media session binder to build
    a protected RTP/RTCP transport
  - `PeerConnectionCoordinator.startSecureMediaTransport(...)` runs ICE
    connectivity checks, requires a selected candidate pair, then binds that
    pair through the handshaker-backed secure media session path
  - `Room` can trigger publisher and subscriber media startup after negotiated
    SDP and final ICE trickle, so runtime signaling can now reach the
    coordinator-run ICE + media binder path in tests
  - `Room` can send publisher RTP packets through a started injected secure
    media transport, giving the future capture/encode loop a tested bridge
    into protected SRTP sending
  - stateful publisher Opus and H.264 RTP bridge helpers keep packetizer
    sequence/timestamp state across packets and frames before handing RTP
    packets to the secure publisher transport sink
  - `Room` stores publisher audio/video RTP senders after successful publish,
    maps local CIDs to published SIDs, removes only the matching sender after
    unpublish, preserves remaining senders for resume reconnect, and clears
    the registry during full publisher offer resets
  - `Room` can send encoded Opus packets and H.264 frames through the stored
    publisher RTP sender registry by published SID
  - `Room` can send publisher RTCP packets through the started injected secure
    media transport
  - `Room` can receive protected publisher RTCP packets from the injected
    secure media transport, decode them, and deliver them to a registered
    async handler loop with teardown coverage
  - `Room` can send subscriber RTCP packets through the started injected
    secure media transport
  - `Room` can receive protected subscriber RTCP packets from the injected
    secure media transport, decode them, and deliver them to a registered
    async handler loop with disconnect cleanup coverage
  - deterministic RTCP feedback policy that builds Generic NACK and PLI packets
    from missing RTP sequence numbers and keyframe requests
  - subscriber RTCP feedback planner that maps H.264/VP8 RTP sequence gaps and
    explicit keyframe requests into bounded NACK/PLI packet plans
  - `Room` can dispatch subscriber feedback plans through the injected
    subscriber RTCP transport and preserves NACK/PLI ordering
  - publisher offer and subscriber answer signaling can send encoded local ICE
    candidates and final trickle markers when media startup has supplied local
    candidates
  - `turn:` and `turns:` ICE server URL parsing retains host, port, UDP/TCP/TLS
    transport intent, username, and credential for future relay allocation
  - RFC 3711 AES-CM session key derivation for SRTP/SRTCP encryption,
    authentication, and salting keys
  - client/server DTLS-SRTP packet-protection context that maps local/remote
    write material to outbound/inbound SRTP and SRTCP protectors
  - RTP sequence-number extension across rollover for SRTP packet indexing
  - SRTP replay-window primitive with per-SSRC duplicate and old-packet
    rejection
  - SRTP AES-CM payload encryption/decryption with RFC 3711 IV construction
    and RFC B.2 keystream-vector coverage
  - SRTP authentication-tag framing and HMAC-SHA1 validation with rollover
    counter included in the authentication input
  - SRTP packet protect/unprotect API that combines AES-CM payload protection,
    HMAC-SHA1 authentication, and replay rejection
  - SRTCP AES-CM payload encryption/decryption with SRTCP E-flag handling
  - SRTCP index/authentication-tag framing with configurable auth-tag length
  - SRTCP HMAC-SHA1 auth-tag generation and constant-time validation
  - SRTCP replay-window primitive keyed by sender SSRC and SRTCP index
  - SRTCP packet protect/unprotect API that combines AES-CM payload protection,
    authentication validation, and replay rejection
  - actor-backed secure RTP/RTCP datagram transport that protects outbound RTP
    and RTCP packets, demuxes inbound RTP/SRTCP datagrams, estimates inbound
    RTP rollover counters, and applies SRTP/SRTCP replay rejection at the
    transport boundary
  - nominated ICE-pair guarded construction for secure RTP/RTCP datagram
    transport
  - exporter-backed secure media session factory that validates the remote
    DTLS fingerprint, validates the nominated ICE pair, builds the datagram
    transport, splits exporter output into SRTP key material, and returns an
    actor-backed `DTLSSRTPMediaTransport`
  - handshaker-backed media session binder that validates the nominated ICE
    pair, builds the datagram transport, invokes an injected DTLS-SRTP
    handshaker, validates the completed remote fingerprint, role, and negotiated
    SRTP protection profile, and returns a protected media transport
  - UDP media datagram socket transport for IPv4 RTP-component candidate pairs,
    including loopback send/receive coverage
  - bound local ICE UDP socket lifecycle that can gather host candidates from
    local interface addresses, assign them the bound port, and reuse that
    socket for STUN checks and selected-pair media datagrams
  - `RoomMediaStartupConfiguration` can be built from bound local candidate
    sockets, wiring the socket-backed ICE checker and media datagram factory
    into startup paths
  - signaling-provided ICE server lists can update peer connection
    configuration without replacing local ICE credentials, DTLS fingerprints,
    or media profile state
  - peer connection coordinators can reset remote SDP, ICE candidate, remote
    ICE credential, DTLS fingerprint/setup, and final-trickle state while
    preserving local configuration
  - bound-socket media startup can pass signaling-provided ICE servers into
    local candidate gathering so supported `stun:` UDP endpoints add
    server-reflexive candidates that still map back to the same local socket
  - public default `Room` startup installs socket-backed subscriber/publisher
    media startup configurations and an explicit unavailable Apple DTLS-SRTP
    handshaker boundary
  - explicit boundary before full DTLS `use_srtp` handshake implementation can
    complete default live secure RTP/RTCP transport
- RTP basics:
  - RTP v2 header encode/decode
  - marker bit, payload type, sequence number, timestamp, SSRC, and payload
    handling
- RTCP basics:
  - Sender Report and Receiver Report encode/decode
  - Reception report block encode/decode including signed 24-bit cumulative
    packet loss
  - Picture Loss Indication encode/decode
  - Generic NACK encode/decode with PID/BLP bitmask packing
- H.264 over RTP basics:
  - single NAL packetization/depacketization
  - STAP-A parameter set packing/unpacking
  - FU-A fragmentation/reassembly
  - missing fragment start and sequence gap error paths
  - subscribe-side RTP to H.264 access-unit assembly
  - Annex-B byte-stream output for decoder handoff
  - VideoToolbox subscribe decoder adapter scaffold with SPS/PPS detection
- H.264 camera publish groundwork:
  - `CameraCaptureOptions` carries position, resolution, and frame-rate intent
  - `LocalVideoTrack.createCameraTrack` creates a native camera-backed track
  - `AVCaptureSession` camera source scaffold with sample-buffer sink
  - VideoToolbox H.264 encoder configuration scaffold
  - H.264 encoded-frame to RTP packetization
  - LiveKit `AddTrackRequest` builder for H.264 camera publishes
  - room-connected publish signaling through `AddTrackRequest` and
    `TrackPublishedResponse`
  - local video publication lifecycle tests
- Swift Opus audio groundwork:
  - `AudioCaptureOptions` carries echo-cancellation, sample-rate,
    channel-count, and frame-duration intent
  - `LocalAudioTrack.createTrack` creates a native microphone-backed track
  - `AVAudioEngine` microphone source scaffold with frame-sink callback
  - Opus voice profile defaults for 48 kHz, 20 ms, mono, payload type 111
  - Opus TOC parsing and packet-duration calculation
  - Opus RTP packetization and depacketization
  - subscribe-side Opus packet pipeline with payload type validation and packet
    loss accounting
  - native audio playout scaffold using `AVAudioEngine` and
    `AVAudioPlayerNode`
  - LiveKit `AddTrackRequest` builder for Opus microphone publishes
  - room-connected publish signaling through `AddTrackRequest` and
    `TrackPublishedResponse`
  - local audio publication lifecycle tests for `setMicrophone(enabled:)`,
    `publish(audioTrack:)`, and `unpublish(publication:)`
- Swift VP8 decode-only subscribe groundwork:
  - VP8 RTP payload descriptor parsing, including PictureID, TL0PICIDX,
    temporal layer, layer-sync, and key index fields
  - VP8 RTP depacketization into frame fragments
  - subscribe-side VP8 frame assembly from single-packet and fragmented RTP
    frames
  - VP8 keyframe header parsing with start-code validation and width/height
    extraction
  - sequence-gap, missing-start, payload-type mismatch, and invalid descriptor
    error paths
  - decode-only frame inspector that records keyframe metadata for the future
    pixel decoder/render path
- SCTP data channel and LiveKit data packet groundwork:
  - WebRTC DCEP data-channel open and acknowledgement message encode/decode
  - reliable and lossy LiveKit data-channel labels (`_reliable`, `_lossy`)
  - reliable and lossy SCTP stream planning for local data channels
  - WebRTC binary/control PPID envelope types
  - data-channel state transitions from connecting to open on DCEP ack
  - LiveKit `DataPacket` user-packet mapping for reliable/lossy delivery
  - topic and destination-identity mapping through `DataPublishOptions`
  - `LocalParticipant.publish(data:options:)` local publish planning
  - incoming user-packet decode helper for future WebRTC receive plumbing
  - `RoomEvent.dataReceived` mapping from decoded data packets to remote
    participants
- `LocalParticipant.publishDataTrack`, `unpublishDataTrack`, and
  `updateDataSubscription` send newer data-track protocol messages
- `PublishDataTrackResponse` and `UnpublishDataTrackResponse` are correlated
  by publisher handle for request completion
- server/SFU `UnpublishDataTrackResponse` clears matching local data-track
  publication state so resume reconnect does not replay stale data tracks
- matching `RequestResponse` failures for AddTrack and data-track
  publish/unpublish requests are surfaced as typed SDK errors before timeout

## Verified

The following checks passed after the latest implementation pass:

- `swift test`
  - 386 tests passed
  - 1 integration test skipped by opt-in guard
- macOS `xcodebuild build`
- iOS Simulator `xcodebuild build`
- `xcodebuild docbuild`
  - passes with warnings from the third-party SwiftProtobuf DocC content
- Release-mode benchmark smoke:
  - `swift run -c release LiveKitNativeBenchmarks`
  - official SDK/WebRTC baseline is intentionally external and not yet measured
- Release gates:
  - `scripts/check_release_readiness.sh` validates package shape, dependency
    guard, tests, benchmark smoke, and size gate in non-strict mode
  - `scripts/check_release_size.sh` passes with the current compressed
    `LiveKitNativeBenchmarks` release binary at 2,537,112 bytes under the 5 MB
    proxy limit
  - `REQUIRE_PRODUCTION_READY=1 scripts/check_release_readiness.sh` is expected
    to fail until production blockers are removed
- Forbidden dependency guard:
  - no Rust, UniFFI, LiveKitWebRTC XCFramework, BoringSSL, libopus, or libvpx
    artifacts found
- SwiftPM package description:
  - one public product: `LiveKitNative`
  - one external dependency: `swift-protobuf`

## Not Implemented Yet

### LiveKit Signaling

- Transceiver negotiation, default capture/encode-to-RTP sender pipeline, and
  LiveKit integration coverage for AddTrack publishes beyond unit-level
  publisher offer signaling and injected RTP bridge coverage.
- Production-hardened reconnect across live media recovery, data channel
  recovery, and server migration beyond the current local ICE credential
  restart plus signal `SyncState` unit coverage for state and SDP recovery.
- Request-response coverage for remaining client-originated signaling commands
  beyond participant metadata/name/attribute updates, AddTrack publishes,
  local mute/unpublish, local publisher track updates, and data-track
  publish/unpublish.
- Default Room creation and lifecycle management for subscriber/publisher local
  ICE candidate sockets from public options.

### ICE and Networking

- Binding the socket-backed `ICEAgent` path into default subscriber/publisher
  peer connection startup against a real LiveKit server.
- Consuming the stored signaling-provided STUN/TURN server list from public
  Room options for default candidate gathering and TURN relay allocation.
- Full ICE restart signaling against LiveKit, connectivity-check pacing,
  timeout, triggered checks, and role-conflict handling.
- Consent freshness execution over default ICEAgent selected pairs.
- Full TURN relay client behavior beyond the current Allocate, Refresh,
  CreatePermission, ChannelBind, ChannelData framing, abstract relay transport,
  deterministic maintenance scheduler/executor, relayed candidate planning,
  bounded relay session orchestration, and deterministic setup-plan execution
  primitives: default relay allocation and socket lifecycle integration,
  UDP/TCP/TLS fallback, and ICE relay candidate integration.

### DTLS, SRTP, RTP, and RTCP

- DTLS 1.2 handshake with WebRTC `use_srtp` extension negotiation. The current
  Apple public API surface exposes DTLS and exporter primitives, but not
  `use_srtp` extension injection or selected SRTP profile reporting for this
  package's selected datagram transport model.
- Invoking the real DTLS exporter from a completed WebRTC-compatible handshake.
- Completing the handshaker-backed secure RTP/RTCP media session binder in the
  default live Room runtime after the explicit unavailable Apple DTLS-SRTP
  boundary is replaced.
- Connecting the tested Room publisher RTP bridge, sender registry, and
  stateful packetizer helpers to the default camera/audio capture and encode
  loops.
- Live RTCP feedback/report integration, retransmission/keyframe-request
  dispatch from subscriber pipelines beyond the current publisher/subscriber
  RTCP send/receive hooks plus deterministic bounded NACK/PLI packet builder,
  subscriber feedback planner, and Room subscriber feedback send helper.
- TWCC, REMB, or congestion control.
- Default subscriber jitter-buffer integration beyond the current bounded RTP
  jitter buffer primitive.
- Packet-loss recovery beyond basic RTP/RTCP packet primitives.
- Adaptive quality control driven by estimated bandwidth, packet loss, CPU,
  and subscriber preferences.
- RTP timestamp and jitter tracking beyond packet encode/decode.

### Media

- Full device camera permission UX and runtime capture integration.
- Full VideoToolbox H.264 encoded sample extraction using real
  `VTCompressionSessionEncodeFrame` output.
- Full VideoToolbox H.264 decode/render path using `VTDecompressionSession`.
- Production H.264 hardware-acceleration verification where the OS exposes
  `UsingHardwareAcceleratedVideoEncoder` / `UsingHardwareAcceleratedVideoDecoder`
  signals, plus an explicit fallback policy for unsupported devices, profiles,
  resolutions, or OS versions.
- H.264 codec implementation must remain delegated to Apple-native media
  frameworks for production; a pure Swift H.264 encoder/decoder is not the
  intended path because it would increase validation, power, thermal, and
  maintenance risk.
- H.265/HEVC is a future optional Apple-focused codec profile, not a `1.0.0`
  production-readiness requirement. It needs separate SDP/RTP handling,
  VideoToolbox encode/decode integration, hardware/fallback policy, LiveKit
  compatibility testing, and a cross-client support matrix before it can be
  enabled.
- VP9 and AV1 are future advanced codec profiles, not `1.0.0`
  production-readiness requirements. They are mainly valuable for SVC and
  bandwidth adaptation, and need an explicit hardware/software dependency
  policy, SVC packetization/depacketization and negotiation work, battery and
  thermal measurements, and cross-client compatibility coverage before they can
  be enabled.
- Full Swift VP8 pixel reconstruction and renderer handoff.
- Full CELT/SILK Swift Opus encode/decode implementation.
- Meeting-grade iOS audio session management, capture/playout timing, echo
  cancellation, noise suppression strategy, automatic gain behavior, route
  changes, Bluetooth behavior, interruptions, and background/foreground
  recovery.
- Bounded capture, encode, decode, and render queues with explicit frame-drop
  and backpressure policy for real-time calls.

### Data Channels

- DTLS-backed SCTP association.
- SCTP chunking, association state, congestion control, retransmission, and
  reassembly.
- Wiring data-channel packets into the real DTLS transport.
- Text streams, byte streams, and RPC APIs.

### Integration

- End-to-end connection to a LiveKit server.
- Subscribe path.
- Publish path.
- Two-client media/data test.
- Reconnect integration test.
- Multi-participant meeting tests with simultaneous publish/subscribe.
- Weak-network tests with packet loss, jitter, bandwidth changes, and recovery
  assertions.
- TURN-only tests across UDP, TCP, and TLS fallback.
- Long-running real-device iOS soak tests with battery, thermal, CPU, memory,
  FPS, audio drop, and reconnect metrics.
- iOS lifecycle tests for background/foreground, audio interruptions, and
  Bluetooth route changes.
- Final size gate using a minimal release app, beyond the current compressed
  benchmark-binary proxy gate.

## Next Recommended Work

1. Continue `1.0.0` hardening by resolving the DTLS-SRTP dependency/API
   boundary: implement a real WebRTC `use_srtp` handshake/exporter or revise the
   no-external-DTLS-stack constraint, then let the now-default Room
   subscriber/publisher startup complete secure RTP/RTCP transport.
2. Connect queued local data publish plans to the publisher peer connection
   once data channels are open.
3. Add full LiveKit ICE restart signaling, media/data recovery after signal
   reconnect, TURN UDP/TCP/TLS fallback, and automated local LiveKit
   integration tests beyond current local ICE credential restart plus signal
   `SyncState` state/SDP unit coverage.
4. Add text streams, byte streams, RPC, and two-client data integration tests.
5. Add adaptive video quality support with multi-layer simulcast/SVC publish
   presets, bandwidth-aware layer selection, Dynacast-style layer pausing, and
   manual subscriber quality controls for low/medium/high video reception.
6. Complete VideoToolbox-backed H.264 encode/decode, hardware-path detection,
   and fallback policy before production readiness.
7. Track H.265/HEVC as a post-`1.0.0` optional Apple-focused codec profile,
   gated by hardware/fallback behavior, LiveKit negotiation, and cross-client
   compatibility.
8. Track VP9 and AV1 as future advanced SVC codec profiles, gated by
   dependency policy, battery/thermal behavior, LiveKit negotiation, and
   cross-client compatibility.
9. Make meeting-grade audio, jitter buffering, packet-loss recovery,
   congestion control, adaptive quality, TURN-only operation, reconnect media
   recovery, and real-device iOS soak/performance testing production blockers.
10. Keep full VP8 pixel reconstruction, full CELT/SILK Opus codec work,
   publisher transceiver negotiation, default capture/encode startup into the
   tested RTP sender bridge, and real DTLS handshake/exporter integration as
   the hardening path before a usable end-to-end release.

## Practical Release Status

`0.6.0` scope is complete as an SCTP data-channel and LiveKit data-packet
groundwork milestone. The repository has started `1.0.0-dev` hardening, but it
should still be treated as a developer preview, not as a usable production
media SDK.

Do not tag this as production-ready `1.0.0` until
`LiveKitNative.productionReadiness.status == .productionReady`, blockers are
empty, VideoToolbox-backed H.264 encode/decode and hardware/fallback behavior
are validated on real devices, meeting-grade audio and network adaptation are
validated, weak-network/TURN-only/multi-participant/soak tests pass, local
LiveKit integration tests pass, and the release size/dependency guards pass on
CI.

For current CI hardening, use:

```sh
scripts/check_release_readiness.sh
```

For an actual production tag gate, use:

```sh
REQUIRE_PRODUCTION_READY=1 scripts/check_release_readiness.sh
```
