# LiveKitNative

Tiny native Swift client SDK for LiveKit, packaged as `LiveKitNative`.

This repository is an independent, unofficial SDK that aims to mirror the
shape of LiveKit Swift SDK v2 while implementing the client logic directly in
Swift. The media engine is an internal `LiveKitNativeWebRTC` target, designed
around Apple-native media frameworks and a small LiveKit-focused WebRTC
profile.

## Status

Detailed project status is tracked in [docs/STATUS.md](docs/STATUS.md).

This is a Milestone 0/0.1 scaffold. It contains the SwiftPM package layout,
single public `LiveKitNative` product, public API surface, actor-backed state
skeleton, signaling URL builder, CI workflow, privacy manifest, DocC landing
page, and tests for the pieces that already have behavior.

Milestone 1 signaling and tiny WebRTC groundwork has started: binary protobuf
frame encode/decode, a WebSocket transport abstraction, ping/close lifecycle
hooks, a `SignalConnection` actor, SDP parsing/writing, STUN packet
encode/decode, ICE priority helpers, RTP packet encode/decode, H.264
single-NAL/STAP-A/FU-A packetization, and mock transport tests are in place.

The full networking handshake, protobuf-generated signal messages, ICE,
DTLS-SRTP, RTP/RTCP, media capture, data channels, reconnect, and quality
controls are the next implementation milestones.

## Requirements

- iOS 13+
- macOS 10.15+
- Swift 6
- Xcode 16+

## Installation

```swift
.package(
    url: "https://github.com/marlonjd/livekit-native-swift.git",
    from: "1.0.0"
)
```

```swift
.product(name: "LiveKitNative", package: "livekit-native-swift")
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
