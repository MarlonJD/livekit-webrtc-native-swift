# LiveKitNative Status

Last updated: 2026-05-15

## Current State

`LiveKitNative` has completed the `0.6.0` developer-preview scope and is now
in `1.0.0-dev` hardening. It is not yet a working end-to-end production media
client.

Production readiness is intentionally represented in code through
`LiveKitNative.productionReadiness` and `LiveKitNative.assertProductionReady()`.
The current status is `developerPreview`, with explicit blockers for DTLS-SRTP,
TURN/reconnect hardening, live media transport integration, DTLS-backed SCTP,
and end-to-end LiveKit compatibility testing.

The repository now has one public SwiftPM product, `LiveKitNative`, with
internal targets for LiveKit protobuf code and the tiny Swift WebRTC engine.
The old binary WebRTC dependency path has been removed from the package model.

## Package Shape

- Public product: `LiveKitNative`
- Public SDK target: `LiveKitNative`
- Internal implementation targets:
  - `LiveKitNativeProtocol`
  - `LiveKitNativeWebRTC`
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
- `LeaveRequest` messages transition to `disconnected` for disconnect actions
  and to `reconnecting` for resume/reconnect actions.
- `SignalResponse.requestResponse` messages are correlated by request ID for
  client-originated signaling requests.
- `LocalParticipant.setMetadata`, `setName`, and `setAttributes` send
  `UpdateParticipantMetadata` requests, await LiveKit `RequestResponse`, map
  permission failures to typed SDK errors, and apply local state only after
  successful acknowledgement.
- Public `Room.disconnect()` clears remote participants, removes remote track
  publications, emits cleanup lifecycle events, closes signaling, and clears
  pending request-response state.
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
- ICE basics:
  - local ICE username fragment and password generation
  - host candidate construction from local interface addresses
  - UDP STUN datagram transport abstraction and Darwin UDP socket transport
  - remote trickle candidate JSON decoding and storage
  - end-of-candidates tracking
  - candidate type preferences
  - candidate priority calculation
  - candidate pair priority calculation
  - candidate pair checklist state and nomination tracking
  - basic SDP candidate attribute serialization
  - connectivity-check Binding request construction with ICE username,
    priority, role, and use-candidate attributes
  - Binding success response handling for server-reflexive mapped address
    discovery
- DTLS/SRTP groundwork:
  - SHA-256 fingerprint formatting
  - ephemeral Security framework key material for SDP fingerprint generation
  - explicit boundary before full DTLS `use_srtp` handshake and SRTP key export
- RTP basics:
  - RTP v2 header encode/decode
  - marker bit, payload type, sequence number, timestamp, SSRC, and payload
    handling
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
  - `PublishDataTrackRequest`, `UnpublishDataTrackRequest`, and
    `UpdateDataSubscription` scaffolds for newer data-track protocol messages

## Verified

The following checks passed after the latest implementation pass:

- `swift test`
  - 100 tests passed
  - 1 integration test skipped by opt-in guard
- macOS `xcodebuild build`
- iOS Simulator `xcodebuild build`
- `xcodebuild docbuild`
  - passes with warnings from the third-party SwiftProtobuf DocC content
- Forbidden dependency guard:
  - no Rust, UniFFI, LiveKitWebRTC XCFramework, BoringSSL, libopus, or libvpx
    artifacts found
- SwiftPM package description:
  - one public product: `LiveKitNative`
  - one external dependency: `swift-protobuf`

## Not Implemented Yet

### LiveKit Signaling

- Rich handling for publisher answers, speaker updates, connection quality,
  stream state, subscription permissions, room moved, and data track control
  messages.
- Sending local video `AddTrackRequest` through the live signal connection and
  awaiting server `TrackPublishedResponse`.
- Alternative URL retry handling from `JoinResponse.alternative_url`.
- Signal reconnect and resume.
- Request-response coverage for all client-originated signaling commands beyond
  participant metadata/name/attribute updates.
- Wiring subscriber ICE candidates into real network connectivity.

### ICE and Networking

- Full ICE agent orchestration against a LiveKit server.
- Connectivity-check scheduling, retransmit, timeout, and nomination policy.
- Consent freshness.
- TURN UDP, TCP, or TLS behavior.

### DTLS, SRTP, RTP, and RTCP

- DTLS 1.2 handshake.
- `use_srtp` negotiation.
- SRTP/SRTCP key export.
- SRTP packet protection/unprotection.
- Replay protection.
- RTCP sender/receiver reports.
- NACK, PLI, TWCC, REMB, or congestion control.
- Jitter buffer.
- RTP timestamp/sequence rollover tracking beyond packet encode/decode.

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
- Size gate using a minimal release app.

## Next Recommended Work

1. Continue `1.0.0` hardening with real DTLS-backed SCTP transport wiring.
2. Connect queued local data publish plans to the publisher peer connection
   once data channels are open.
3. Add signal reconnect/resume, ICE restart, TURN UDP/TCP/TLS fallback, and
   automated local LiveKit integration tests.
4. Add text streams, byte streams, RPC, and two-client data integration tests.
5. Keep full VP8 pixel reconstruction, full CELT/SILK Opus codec work,
   publisher `AddTrackRequest` signaling, transceiver negotiation, and
   DTLS-SRTP integration as the hardening path before a usable end-to-end
   release.

## Practical Release Status

`0.6.0` scope is complete as an SCTP data-channel and LiveKit data-packet
groundwork milestone. The repository has started `1.0.0-dev` hardening, but it
should still be treated as a developer preview, not as a usable production
media SDK.

Do not tag this as production-ready `1.0.0` until
`LiveKitNative.productionReadiness.status == .productionReady`, blockers are
empty, local LiveKit integration tests pass, and the release size/dependency
guards pass on CI.
