# LiveKitNative Status

Last updated: 2026-05-15

## Current State

`LiveKitNative` has completed the `0.6.0` developer-preview scope and is now
in `1.0.0-dev` hardening. It is not yet a working end-to-end production media
client.

Production readiness is intentionally represented in code through
`LiveKitNative.productionReadiness` and `LiveKitNative.assertProductionReady()`.
The current status is `developerPreview`, with explicit blockers for the real
DTLS handshake/exporter implementation, TURN/ICE hardening, live media startup
integration, DTLS-backed SCTP, media recovery during reconnect, and end-to-end
LiveKit compatibility testing.
Publisher `AddTrackRequest` signaling is now wired for local audio/video
publishes, publisher SDP offers are generated and sent after
`TrackPublishedResponse`, and publisher answers and publisher-targeted trickle
candidates are routed into the publisher peer connection adapter, but media
sender transport is still open.
Data-track publish/unpublish/update-subscription signaling is also wired at
unit-test level; live SCTP transport remains open.

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
  publications from the server-returned `TrackInfo`.
- After media publish acknowledgement, publisher SDP offers are generated from
  local audio/video publish plans and sent as LiveKit `SignalRequest.offer`
  messages for the publisher negotiation path.
- `LocalParticipant.setTrackMuted(publication:muted:)` sends LiveKit
  `MuteTrackRequest` messages for local publications and updates local mute
  state after the signal send succeeds.
- `LocalParticipant.unpublish(publication:)`, `setCamera(enabled: false)`, and
  `setMicrophone(enabled: false)` send a muted `MuteTrackRequest` before
  removing local publications when the participant is attached to a connected
  room. The normal media renegotiation work needed for full publisher unpublish
  remains open.
- `Room.updateSubscription(trackSIDs:subscribe:)` sends LiveKit
  `UpdateSubscription` messages for media tracks, and
  `Room.updateTrackSettings(...)` sends `UpdateTrackSettings` messages for
  subscribed track pause, quality, resolution, FPS, and priority preferences.
- `LocalParticipant.setTrackSubscriptionPermissions(...)` sends LiveKit
  `SubscriptionPermission` messages for publisher-controlled subscriber access
  to all local tracks or selected track SIDs.
- `LocalParticipant.updateAudioTrack(...)` and `updateVideoTrack(...)` send
  LiveKit `UpdateLocalAudioTrack` / `UpdateLocalVideoTrack` messages for local
  publisher track feature and dimension updates.
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
- DTLS/SRTP groundwork:
  - SHA-256 fingerprint formatting
  - ephemeral Security framework key material for SDP fingerprint generation
  - SDP `fingerprint` and `setup` role extraction for remote offers/answers
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
    handshaker, validates the completed remote fingerprint, and returns a
    protected media transport
  - UDP media datagram socket transport for IPv4 RTP-component candidate pairs,
    including loopback send/receive coverage
  - explicit boundary before full DTLS `use_srtp` handshake implementation and
    subscriber/publisher startup integration
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

## Verified

The following checks passed after the latest implementation pass:

- `swift test`
  - 225 tests passed
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
    `LiveKitNativeBenchmarks` release binary at 2,299,949 bytes under the 5 MB
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

- Stateful handling for data-track subscriber handle updates and media section
  requirement updates beyond typed event emission.
- Transceiver negotiation, RTP sender transport, and LiveKit integration
  coverage for AddTrack publishes beyond unit-level publisher offer signaling.
- Production-hardened reconnect across ICE restart, media recovery, data
  channel recovery, and server migration.
- Request-response coverage for remaining client-originated signaling commands
  beyond participant metadata/name/attribute updates, AddTrack publishes, and
  data-track publish/unpublish.
- Wiring subscriber ICE candidates into real network connectivity.

### ICE and Networking

- Binding the `ICEAgent` into subscriber/publisher peer connection startup
  against a real LiveKit server.
- Full connectivity-check pacing, timeout, triggered checks, and role-conflict
  handling.
- Consent freshness.
- TURN UDP, TCP, or TLS behavior.

### DTLS, SRTP, RTP, and RTCP

- DTLS 1.2 handshake.
- Wiring `use_srtp` extension negotiation into the DTLS handshake.
- Invoking the real DTLS exporter from a completed handshake.
- Wiring the handshaker-backed secure RTP/RTCP media session binder into
  subscriber/publisher peer connection startup.
- Wiring RTCP feedback/report packets into live media transport.
- TWCC, REMB, or congestion control.
- Jitter buffer.
- RTP timestamp and jitter tracking beyond packet encode/decode.

### Media

- Full device camera permission UX and runtime capture integration.
- Full VideoToolbox H.264 encoded sample extraction.
- Full VideoToolbox H.264 decode/render path.
- Full Swift VP8 pixel reconstruction and renderer handoff.
- Full CELT/SILK Swift Opus encode/decode implementation.
- Audio session management and production playout timing.

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
- Final size gate using a minimal release app, beyond the current compressed
  benchmark-binary proxy gate.

## Next Recommended Work

1. Continue `1.0.0` hardening with a real DTLS handshake/exporter
   implementation and subscriber/publisher startup integration.
2. Connect queued local data publish plans to the publisher peer connection
   once data channels are open.
3. Add ICE restart, media/data recovery after signal reconnect, TURN UDP/TCP/TLS
   fallback, and automated local LiveKit integration tests.
4. Add text streams, byte streams, RPC, and two-client data integration tests.
5. Add adaptive video quality support with multi-layer simulcast/SVC publish
   presets, bandwidth-aware layer selection, Dynacast-style layer pausing, and
   manual subscriber quality controls for low/medium/high video reception.
6. Keep full VP8 pixel reconstruction, full CELT/SILK Opus codec work,
   publisher transceiver negotiation, RTP sender transport, and real DTLS
   handshake/exporter integration as the hardening path before a usable
   end-to-end release.

## Practical Release Status

`0.6.0` scope is complete as an SCTP data-channel and LiveKit data-packet
groundwork milestone. The repository has started `1.0.0-dev` hardening, but it
should still be treated as a developer preview, not as a usable production
media SDK.

Do not tag this as production-ready `1.0.0` until
`LiveKitNative.productionReadiness.status == .productionReady`, blockers are
empty, local LiveKit integration tests pass, and the release size/dependency
guards pass on CI.

For current CI hardening, use:

```sh
scripts/check_release_readiness.sh
```

For an actual production tag gate, use:

```sh
REQUIRE_PRODUCTION_READY=1 scripts/check_release_readiness.sh
```
