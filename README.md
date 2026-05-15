# LiveKitNative

Tiny native Swift client SDK for LiveKit, packaged as `LiveKitNative`.

This repository is an independent, unofficial SDK that aims to mirror the
shape of LiveKit Swift SDK v2 while implementing the client logic directly in
Swift. The media engine is an internal `LiveKitNativeWebRTC` target, designed
around Apple-native media frameworks and a small LiveKit-focused WebRTC
profile.

## Status

Detailed project status is tracked in [docs/STATUS.md](docs/STATUS.md).

The `0.5.0` developer-preview scope is complete. The package contains the
SwiftPM layout, single public `LiveKitNative` product, public API surface,
actor-backed room state, signaling URL builder, CI workflow, privacy manifest,
DocC landing page, and tests for the pieces that already have behavior.

Signaling and tiny WebRTC groundwork now includes generated LiveKit protobuf
signal messages, binary protobuf frame encode/decode, a WebSocket transport
abstraction, ping/close lifecycle hooks, a `SignalConnection` actor,
`Room.connect` JoinResponse handling, remote track publication state updates,
participant disconnect and track-unpublish reducers, a post-join signal receive
loop for participant updates, refresh tokens, leave messages, subscriber offers,
subscriber trickle candidates, SDP parsing/writing, minimal subscriber answer
generation, STUN packet encode/decode, STUN `XOR-MAPPED-ADDRESS` handling, ICE
priority helpers, host candidate construction, UDP STUN transport,
connectivity-check request/response handling, candidate checklist nomination,
DTLS fingerprint material, RTP packet encode/decode, H.264
single-NAL/STAP-A/FU-A packetization, subscribe-side H.264 access-unit
assembly, native camera track scaffolding, VideoToolbox H.264 encoder
configuration, H.264 publish RTP packetization, LiveKit `AddTrackRequest`
construction, local video publication state, and mock transport tests.

The audio groundwork now includes native microphone track scaffolding,
AVAudioEngine capture and playout adapters, Opus voice profile defaults, Opus
TOC parsing, Opus RTP packetization/depacketization, subscribe-side packet loss
accounting, LiveKit `AddTrackRequest` construction for microphone publishes,
and local audio publication state.

VP8 subscribe groundwork now includes RTP payload descriptor parsing, PictureID
and layer metadata parsing, VP8 frame assembly from single-packet and fragmented
RTP frames, keyframe width/height extraction, sequence-gap validation, and a
decode-only frame inspector for future renderer integration.

The active implementation focus is now `0.6.0`: SCTP data channel and LiveKit
data packet groundwork. Reconnect and quality controls follow in later
milestones.

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
