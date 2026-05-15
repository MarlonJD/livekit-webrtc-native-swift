# LiveKitNative

Tiny native Swift client SDK for LiveKit, packaged as `LiveKitNative`.

This repository is an independent, unofficial SDK that aims to mirror the
shape of LiveKit Swift SDK v2 while implementing the client logic directly in
Swift. The media engine is an internal `LiveKitNativeWebRTC` target, designed
around Apple-native media frameworks and a small LiveKit-focused WebRTC
profile.

## Status

Detailed project status is tracked in [docs/STATUS.md](docs/STATUS.md).

The `0.6.0` developer-preview scope is complete and `main` now reports SDK
version `1.0.0-dev` while hardening continues. The package contains the
SwiftPM layout, single public `LiveKitNative` product, public API surface,
actor-backed room state, signaling URL builder, CI workflow, privacy manifest,
DocC landing page, and tests for the pieces that already have behavior.

Signaling and tiny WebRTC groundwork now includes generated LiveKit protobuf
signal messages, binary protobuf frame encode/decode, a WebSocket transport
abstraction, ping/close lifecycle hooks, a `SignalConnection` actor,
`Room.connect` JoinResponse handling, remote track publication state updates,
participant disconnect and track-unpublish reducers, a post-join signal receive
loop for participant updates, refresh tokens, leave messages, subscriber offers,
subscriber and publisher trickle candidates, publisher answer routing, speaker
updates, connection quality events, stream state events, room updates,
subscription permission/response events, subscribed quality events,
track-subscribed events, media section requirements, subscribed audio codec
updates, data-track publish/unpublish responses, data-track subscriber handle
updates, room-moved events, SDP parsing/writing, minimal subscriber answer
generation, STUN packet encode/decode, STUN
`XOR-MAPPED-ADDRESS` handling, RFC-vector-tested STUN `MESSAGE-INTEGRITY` and
`FINGERPRINT` signing/validation, authenticated ICE connectivity-check request
sending and authenticated response validation, ICE priority helpers, host
candidate construction, UDP STUN transport, connectivity-check
request/response handling with bounded transport retries, candidate checklist
nomination, SDP ICE candidate parsing, dynamic trickle candidate checklist
updates, SDP ICE credential extraction, coordinator-created ICE agents,
STUN-backed candidate-pair checking, use-candidate nomination,
validate-only nomination handoff, DTLS fingerprint material, DTLS-SRTP
protection profile and exporter key/salt splitting, RFC 3711 AES-CM SRTP/SRTCP session key
derivation, client/server DTLS-SRTP packet-protection context wiring, RTP
packet encode/decode, RTP sequence rollover tracking, SRTP replay-window
protection groundwork, SRTP AES-CM payload encryption/decryption using RFC
3711 IV construction, SRTP authentication-tag framing with ROC-aware HMAC-SHA1
validation, full SRTP packet protect/unprotect APIs with replay rejection,
SRTCP AES-CM payload protection, SRTCP index/authentication-tag framing,
HMAC-SHA1 auth-tag validation, full SRTCP packet protect/unprotect APIs with
replay rejection, actor-backed secure RTP/RTCP datagram send/receive wiring
with RTCP mux demux, RTP rollover tracking, and nominated ICE-pair guarded
construction, UDP media datagram socket transport with loopback coverage, RTCP
sender/receiver report and PLI/NACK feedback wire-format groundwork, H.264
single-NAL/STAP-A/FU-A packetization, subscribe-side H.264 access-unit
assembly, native camera track scaffolding, VideoToolbox H.264 encoder
configuration, H.264 publish RTP packetization, LiveKit `AddTrackRequest`
construction, `TrackPublishedResponse` correlation, local video publication
state, and mock transport tests.

The audio groundwork now includes native microphone track scaffolding,
AVAudioEngine capture and playout adapters, Opus voice profile defaults, Opus
TOC parsing, Opus RTP packetization/depacketization, subscribe-side packet loss
accounting, LiveKit `AddTrackRequest` construction for microphone publishes,
`TrackPublishedResponse` correlation, and local audio publication state.

VP8 subscribe groundwork now includes RTP payload descriptor parsing, PictureID
and layer metadata parsing, VP8 frame assembly from single-packet and fragmented
RTP frames, keyframe width/height extraction, sequence-gap validation, and a
decode-only frame inspector for future renderer integration.

Data channel groundwork now includes WebRTC DCEP open/ack encode/decode,
reliable/lossy LiveKit data-channel labels, SCTP stream routing for local data
channels, binary PPID envelopes, LiveKit `DataPacket` user-packet mapping,
`publish(data:options:)` local publish planning, data-track publish/unpublish
request/response signaling, data subscription update signaling, and
`RoomEvent.dataReceived` mapping for decoded packets.

The active implementation focus is now `1.0.0` hardening: binding ICE-selected
candidate pairs through a completed DTLS handshake and exporter output into the
secure media datagram transport, reconnect, TURN, quality controls, real
DTLS-SCTP network transport, integration apps, and size gates.

Current builds expose `LiveKitNative.productionReadiness` and
`LiveKitNative.assertProductionReady()` so applications and release automation
can fail fast while the remaining production blockers are still open.
`LocalParticipant.setMetadata`, `setName`, and `setAttributes` now send
LiveKit `UpdateParticipantMetadata` requests and map server
`RequestResponse` failures to typed SDK errors. `Room.disconnect()` also clears
remote participant state and emits cleanup lifecycle events. Basic signal
resume/full-reconnect and `JoinResponse.alternative_url` retry are unit-tested,
and room-connected `publish(videoTrack:)` / `publish(audioTrack:)` calls send
LiveKit `AddTrackRequest` messages and wait for matching
`TrackPublishedResponse` acknowledgements before recording local publications.
Publisher answer routing, data-track control event mapping, and data-track
publish/unpublish request flows are unit-tested, while publisher offer
generation, ICE-bound media transport, media recovery, and end-to-end reconnect
hardening are still open.

## Benchmarks

Release-mode microbenchmarks are available through:

```sh
swift run -c release LiveKitNativeBenchmarks
```

The current local run measures low-level signaling, SDP, STUN, RTP, SRTP/SRTCP
replay/authentication tracking, SRTP/SRTCP AES-CM payload protection, full
SRTP/SRTCP packet protect/unprotect paths, DTLS-SRTP exporter splitting and
session-protection context, RTCP feedback, H.264, VP8, Opus RTP scaffolding,
and SCTP data-channel message paths. On this machine, the latest
release-readiness smoke medians include protobuf signal roundtrip at
`9.022 us/op`, subscriber SDP answer generation at `102.942 us/op`, RTP
encode/decode at `0.590 us/op`, SRTP replay protection at `0.047 us/op`, SRTP
authenticated roundtrip at `8.368 us/op`, SRTP AES-CM payload roundtrip at
`65.058 us/op`, full SRTP packet protect/unprotect at `72.214 us/op`, RTCP
feedback roundtrip at `1.722 us/op`, SRTCP packet/replay roundtrip at
`0.781 us/op`, SRTCP authenticated roundtrip at `6.837 us/op`, full SRTCP
packet protect/unprotect at `9.332 us/op`, DTLS-SRTP exporter split at
`0.315 us/op`, DTLS-SRTP session protect/unprotect at `87.486 us/op`, H.264
packetize/depacketize at `2.500 us/op`, and SCTP DCEP open/ack roundtrip at
`0.843 us/op`.

Official LiveKit Swift SDK/WebRTC baseline numbers are accepted as an external
CSV so this package does not reintroduce the forbidden binary WebRTC dependency.
See [docs/BENCHMARKS.md](docs/BENCHMARKS.md) for the full methodology,
current results, and comparison workflow.

## Release Gates

The repository now has a non-strict release-readiness gate for CI and a strict
gate for real `1.0.0` tagging:

```sh
scripts/check_release_readiness.sh
REQUIRE_PRODUCTION_READY=1 scripts/check_release_readiness.sh
```

The default gate checks package shape, forbidden runtime dependencies,
unit/integration opt-in tests, benchmark smoke, and the compressed release
binary size proxy. The strict gate additionally requires
`LiveKitNative.productionReadiness.status == .productionReady` and no blockers.
That strict gate intentionally fails today because DTLS handshake/exporter
binding, full ICE/TURN hardening, publisher media transport, live SCTP, and
end-to-end LiveKit tests are still open.

## Requirements

- iOS 13+
- macOS 10.15+
- Swift 6
- Xcode 16+

## Installation

```swift
.package(
    url: "https://github.com/MarlonJD/livekit-webrtc-native-swift.git",
    from: "1.0.0"
)
```

Use the `1.0.0` requirement only after the readiness gate reports
`productionReady`. Until then, `main` should be treated as a developer preview.

```swift
.product(name: "LiveKitNative", package: "livekit-webrtc-native-swift")
```

## Usage Shape

```swift
import LiveKitNative

let room = Room()

Task {
    for await event in room.events {
        print(event)
    }
}

try await room.connect(
    url: URL(string: "wss://example.livekit.cloud")!,
    token: token
)
```

## Design Notes

- WebSocket signaling uses `/rtc` and binary protobuf frames.
- The client protocol target is `protocol=9`.
- `LiveKitNativeWebRTC` is an internal package target, not a public SwiftPM
  product and not a separate semver surface.
- The tiny media profile publishes H.264 video, receives H.264 and VP8 video,
  and uses Opus for audio.
- The WebRTC engine is planned around `AVFoundation`, `AudioToolbox`,
  `VideoToolbox`, `CoreMedia`, `Security`, `Network`, and `CryptoKit`.
- LiveKit protocol sources are pinned to
  `765a80e4298e376593859c3f11cf748c725f68f9`. Run
  `scripts/generate_protocol_sources.sh` to regenerate vendored Swift protobuf
  files when the pin changes. The current vendored set is the client signaling
  subset needed for `/rtc` room join and media control.
- `Room` owns a `RoomActor` for core state updates.
- `RoomEvent` is available as an `AsyncStream`, with a delegate hook for UIKit
  and AppKit style integrations.
- Production readiness is explicit through `LiveKitNative.productionReadiness`
  and `LiveKitNative.assertProductionReady()`.
- Logging can be configured through `LiveKitNativeLogging.configure`.
- UIKit and AppKit `VideoView` classes are included. SwiftUI components are out
  of scope for v1 in this package.
- The repository intentionally contains no Rust toolchain, no `.rs` sources, no
  UniFFI bridge dependency, no `LiveKitWebRTC.xcframework`, no BoringSSL, no
  libopus, and no libvpx.

## Milestones

| Tag | Scope |
| --- | --- |
| `0.1.0` | Package cleanup, signaling, SDP parser/writer, room join |
| `0.2.0` | ICE/STUN, DTLS-SRTP, H.264 subscribe, video render |
| `0.3.0` | H.264 camera publish through VideoToolbox |
| `0.4.0` | Swift Opus audio publish/subscribe |
| `0.5.0` | Swift VP8 decode-only subscribe path |
| `0.6.0` | SCTP data channel and LiveKit data packets |
| `1.0.0` | Reconnect, TURN hardening, quality controls, sample apps, size gates |

## Compatibility Matrix

| LiveKitNative | LiveKit protocol | Swift | Xcode | Platforms |
| --- | --- | --- | --- | --- |
| `main` | 9 | 6 | 16+ | iOS 13+, macOS 10.15+ |
