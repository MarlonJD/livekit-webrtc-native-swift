# LiveKitNative Status

Last updated: 2026-05-14

## Current State

`LiveKitNative` is currently an early SwiftPM scaffold plus protocol-engine
groundwork. It is not yet a working end-to-end LiveKit client.

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

### Signaling Groundwork

- `/rtc` signal URL builder with token, reconnect, auto-subscribe, SDK version,
  and `protocol=9` query parameters.
- Binary protobuf frame codec using `SwiftProtobuf`.
- `SignalTransport` abstraction over WebSocket-style binary/text frames.
- `URLSessionWebSocketSignalTransport` with send, receive, ping, and close
  behavior.
- `SignalConnection` actor for connection state, encode/decode, send, receive,
  ping, and close.
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
- ICE basics:
  - candidate type preferences
  - candidate priority calculation
  - candidate pair priority calculation
  - basic SDP candidate attribute serialization
- RTP basics:
  - RTP v2 header encode/decode
  - marker bit, payload type, sequence number, timestamp, SSRC, and payload
    handling
- H.264 over RTP basics:
  - single NAL packetization/depacketization
  - STAP-A parameter set packing/unpacking
  - FU-A fragmentation/reassembly
  - missing fragment start and sequence gap error paths

## Verified

The following checks passed after the latest implementation pass:

- `swift test`
  - 33 tests passed
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

- WebSocket join handshake.
- `JoinResponse` handling.
- `LeaveRequest`, `ReconnectResponse`, and `refresh_token`.
- Signal reconnect and resume.
- Server-driven participant/track state reducer from real LiveKit messages.

### ICE and Networking

- UDP socket gathering through `Network.framework`.
- STUN server transactions over the network.
- Candidate pair checklist.
- Connectivity checks.
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

- Camera capture pipeline.
- VideoToolbox H.264 encode path.
- VideoToolbox H.264 decode/render path.
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

1. Vendor generated LiveKit protobuf Swift sources from the pinned protocol
   revision.
2. Replace placeholder signaling tests with tests using real `SignalRequest`
   and `SignalResponse` messages.
3. Implement WebSocket join request/response handling in `Room.connect`.
4. Add an SDP offer/answer model that can produce a LiveKit subscriber answer
   from a server offer.
5. Start ICE networking with UDP host candidates and STUN binding transactions.
6. Add SRTP/RTCP primitives before wiring media render.

## Practical Release Status

No tag should be cut as a usable SDK yet.

The repository is ready for continued implementation work toward `0.1.0`, but
`0.1.0` should wait until a client can join a LiveKit room and complete at
least the signaling-side room join flow.
