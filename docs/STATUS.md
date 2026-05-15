# LiveKitNative Status

Last updated: 2026-05-15

## Current State

`LiveKitNative` has completed the `0.3.0` developer-preview scope and is now
moving into the `0.4.0` Swift Opus audio publish/subscribe phase. It is not yet
a working end-to-end production media client.

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

## Verified

The following checks passed after the latest implementation pass:

- `swift test`
  - 60 tests passed
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
- Swift VP8 decode-only path.
- Swift Opus encode/decode path.
- Audio capture/playout and audio session management.

### Data Channels

- DTLS-backed SCTP association.
- Data channel open/ack/control messages.
- LiveKit data packet mapping.
- Text streams, byte streams, and RPC APIs.

### Integration

- End-to-end connection to a LiveKit server.
- Subscribe path.
- Publish path.
- Two-client media/data test.
- Reconnect integration test.
- Size gate using a minimal release app.

## Next Recommended Work

1. Start `0.4.0` with Swift Opus packet encode/decode primitives.
2. Add microphone capture through `AVAudioEngine` or `AVCaptureAudioDataOutput`.
3. Add audio RTP packetization/depacketization and jitter-buffer groundwork.
4. Wire local microphone publication state to `LocalParticipant`.
5. Keep publisher `AddTrackRequest`, transceiver negotiation, and DTLS-SRTP
   integration as the hardening path before a usable end-to-end release.

## Practical Release Status

`0.3.0` scope is complete as an H.264 camera-publish groundwork milestone. It
should be treated as a developer preview, not as a usable media SDK.

The repository is ready for `0.4.0` implementation work: Swift Opus audio
publish/subscribe groundwork.
