# LiveKitNative

Tiny native Swift client SDK for LiveKit, packaged as `LiveKitNative`.

This repository is an independent, unofficial SDK that aims to mirror the
shape of LiveKit Swift SDK v2 while implementing the client logic directly in
Swift. The media engine is an internal `LiveKitNativeWebRTC` target, designed
around Apple-native media frameworks and a small LiveKit-focused WebRTC
profile.

## Why We Needed This Project

iOS and macOS applications that use LiveKit usually inherit a large WebRTC
stack through mostly opaque binary dependencies maintained outside the Apple
platform toolchain. This project exists to split LiveKit client behavior into
smaller Swift-native pieces that can be audited, tested, and reasoned about
directly.

The goal is not to build a general-purpose browser WebRTC engine. The goal is
to implement the narrow LiveKit-focused profile needed for signaling,
publishing and subscribing to media, data channels, and reconnect behavior on
top of Apple-native frameworks. That keeps package shape, release size,
security surface, debugging experience, and production-readiness boundaries
under explicit project control.

This approach is valuable for applications that need a SwiftPM-distributed,
LiveKit-focused client SDK without Rust/UniFFI, a heavyweight WebRTC
xcframework, or broad media dependencies that are difficult to inspect and
ship.

## Performance Expectations

This project's core promise is not to be faster than official WebRTC stacks in
every situation. Its purpose is to provide a smaller, inspectable, LiveKit
focused client surface. Low-level pieces such as protobuf, SDP, STUN, RTP,
SRTP, and data-channel framing can run with very low latency in
microbenchmarks, but those numbers alone do not define real-time media quality.

Production behavior is shaped more by video encode/decode cost, audio capture
and playout, packet loss, jitter, TURN usage, reconnect handling, battery
usage, thermal behavior, and multi-participant room load. Performance is
therefore not irrelevant; it is just not the only decision point. A real
evaluation should measure join latency, CPU, memory, FPS, audio drops, packet
loss recovery, reconnect time, battery usage, and thermal behavior on real
devices.

Performance issues may be manageable in small, controlled LiveKit scenarios.
Applications with larger rooms, weak network conditions, long-running mobile
sessions, or strict media-quality expectations should benchmark this package
side by side with the official SDK and validate it with end-to-end tests before
making a production decision.

## Codec Acceleration and Swift Scope

The H.264 encoder and decoder are intentionally not expected to be pure Swift
implementations. Video codec work is one of the few places where "all Swift"
would be the wrong production tradeoff: a Swift H.264 codec would be large,
hard to validate, difficult to keep power-efficient, and unlikely to match the
hardware acceleration, battery behavior, and thermal characteristics provided
by Apple platforms.

The intended production model is to keep LiveKit client logic, signaling,
state, RTP/SRTP framing, SDP, ICE/STUN, and media pipeline orchestration in
Swift, while using Apple-native system frameworks for heavy media primitives.
For H.264, that means real VideoToolbox-backed encode and decode paths through
`VTCompressionSession` and `VTDecompressionSession`, with hardware acceleration
used when the platform supports it.

Using VideoToolbox does not add a vendored WebRTC binary or a third-party codec
library to the package. It links against Apple system frameworks that are
already part of the target OS. This preserves the goal of a small,
inspectable, Swift-native LiveKit client while avoiding an impractical and
power-hungry pure Swift codec implementation.

Production readiness must require the H.264 media path to use VideoToolbox for
real frame encode/decode, verify whether the hardware path is active where the
OS exposes that signal, and define explicit fallback behavior for devices or
profiles where hardware acceleration is unavailable.

H.265/HEVC is a reasonable future codec profile for Apple-focused deployments
because Apple platforms expose HEVC through VideoToolbox and can benefit from
its better compression efficiency. It is intentionally not part of the initial
production-ready core because H.264 is the safer WebRTC compatibility baseline.
Adding HEVC later should be treated as an optional negotiated profile with its
own SDP/RTP handling, hardware/fallback policy, LiveKit compatibility testing,
and cross-client support matrix.

VP9 and AV1 are also future codec candidates, but they should be treated as
advanced profiles rather than production-readiness requirements for v1. Their
main value is SVC and better bandwidth adaptation in supported LiveKit/WebRTC
environments. Before either codec is enabled, the project needs an explicit
hardware/software dependency policy, SVC handling, battery and thermal
measurements, and cross-client compatibility coverage.

## Production Meeting Bar

This package should not be considered competitive with `LiveKitWebRTC` for
general production video meetings until the hardening bar covers the full call
experience, not only the signaling and media packet paths.

Production readiness must include meeting-grade audio capture and playout,
echo cancellation, route changes, Bluetooth behavior, interruptions,
background/foreground transitions, jitter buffering, packet-loss recovery,
RTCP feedback, bandwidth estimation, congestion control, adaptive quality,
bounded frame dropping, reconnect media recovery, TURN-only operation, and
multi-participant behavior.

Those requirements are intentionally production blockers. A release can only be
called production-ready after automated LiveKit integration tests, weak-network
tests, TURN-only tests, long-running soak tests, battery/thermal measurements,
and real-device iOS validation pass.

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
protection profile and exporter key/salt splitting, `use_srtp` extension
encode/decode and profile selection, SDP DTLS fingerprint/setup extraction,
case-normalized DTLS fingerprint comparison, media-level SDP DTLS
fingerprint/setup fallback, peer-connection handshake configuration, typed DTLS-SRTP handshake results,
remote fingerprint, role, and protection-profile validation for media
sessions, RFC 3711 AES-CM SRTP/SRTCP session key derivation, client/server
DTLS-SRTP packet-protection context wiring, RTP packet encode/decode, RTP
sequence rollover tracking, SRTP replay-window protection groundwork, SRTP
AES-CM payload encryption/decryption using RFC 3711 IV construction, SRTP
authentication-tag framing with ROC-aware HMAC-SHA1
validation, full SRTP packet protect/unprotect APIs with replay rejection,
SRTCP AES-CM payload protection, SRTCP index/authentication-tag framing,
HMAC-SHA1 auth-tag validation, full SRTCP packet protect/unprotect APIs with
replay rejection, actor-backed secure RTP/RTCP datagram send/receive wiring
with RTCP mux demux, RTP rollover tracking, and nominated ICE-pair guarded
construction, exporter-backed secure media session construction, UDP media
datagram socket transport with loopback coverage, handshaker-backed media
session binder coverage, coordinator-level secure media transport startup from
negotiated SDP and nominated ICE pairs, coordinator-run ICE checks that select
a pair before secure transport binding, Room-level publisher/subscriber media
startup triggering after negotiated SDP and final ICE trickle when a media
binder is injected, local publisher/subscriber ICE candidate JSON encoding and
trickle/final-trickle signaling, bound local ICE UDP sockets that can gather
host candidates and reuse the candidate port for STUN checks and media
datagrams, server-provided `JoinResponse` and `ReconnectResponse` ICE server
configuration mapping onto subscriber and publisher peer connections, STUN UDP
server-reflexive candidate discovery from supported `stun:` ICE server URLs
for bound-socket startup, default public `Room` subscriber/publisher media
startup configurations that gather and trickle socket-backed local ICE
candidates, deterministic ICE consent freshness planning, injectable executor
primitive, and Room-level consent loop for selected pairs after secure-media
startup succeeds, bounded RTP
jitter buffering with gap skip, duplicate/old packet drops, missing-sequence
accounting, and sequence-wrap ordering, TURN endpoint parsing from
`turn:`/`turns:` ICE server URLs with UDP/TCP/TLS intent and credentials
retained for future relay allocation, TURN Allocate request primitives for
requested transport, lifetime, realm, nonce, `ERROR-CODE`, and relayed-address
decoding, TURN
allocation client request/response validation with one long-term credential
401 challenge retry over the STUN datagram transport abstraction, TURN Refresh
request/response validation and deallocation lifetime support, CreatePermission
request/response validation with IPv4 `XOR-PEER-ADDRESS`, ChannelBind
request/response validation with TURN channel range checks, and one-shot stale
nonce retry for authenticated TURN Allocate/Refresh/CreatePermission/ChannelBind
flows, TURN ChannelData frame encode/decode and stream parsing with 4-byte
padding, TURN ChannelData relay send/receive over an abstract media datagram
transport, deterministic TURN allocation/permission refresh planning,
maintenance execution, due action scheduling, relay ICE candidate planning, and
TURN relay session configuration selection from parsed ICE server endpoints,
plus bounded TURN relay session orchestration and deterministic setup-plan
execution over abstract transports, peer
negotiation state reset across
fresh join/reconnect/disconnect boundaries, RTCP
sender/receiver report and bounded PLI/NACK subscriber feedback planning,
H.264
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
Media section requirements and data-track subscriber handles are retained as
latest-value Room state and emitted as typed room events.

The active implementation focus is now `1.0.0` hardening: validating the
OpenSSL-backed DTLS-SRTP `use_srtp` handshake/exporter against LiveKit,
completing default live secure media transport, reconnect, TURN, quality
controls, default capture/encode startup into the tested RTP sender bridge,
DTLS-SCTP network transport, integration apps, and size gates.

Current builds expose `LiveKitNative.productionReadiness` and
`LiveKitNative.assertProductionReady()` so applications and release automation
can fail fast while the remaining production blockers are still open.
`LocalParticipant.setMetadata`, `setName`, and `setAttributes` now send
LiveKit `UpdateParticipantMetadata` requests and map server
`RequestResponse` failures to typed SDK errors. `Room.disconnect()` also clears
remote participant state, sends a client-initiated `LeaveRequest`, and emits
cleanup lifecycle events. Refreshed signal tokens are retained for subsequent
resume reconnects. Basic signal resume/full-reconnect and
`JoinResponse.alternative_url` retry are unit-tested. `JoinResponse` and
`ReconnectResponse` ICE server lists are applied to both subscriber and
publisher peer connection configurations, injected bound-socket media startup
can use supported `stun:` UDP URLs to add server-reflexive local candidates
while reusing the same local UDP socket, fresh joins/reconnect responses clear
stale peer negotiation state and regenerate local ICE credentials before
applying new signaling configuration, resume reconnects send LiveKit
`SyncState` for current media subscription preferences, disabled subscribed
tracks, local media/data publications, and the latest negotiated subscriber
answer / publisher offer SDP state in unit tests, preserve publisher offer
track state so later publishes after resume do not drop existing local media,
and room-connected
`publish(videoTrack:)` / `publish(audioTrack:)` calls send LiveKit
`AddTrackRequest` messages and wait for matching `TrackPublishedResponse`
acknowledgements before recording local publications, while matching
`RequestResponse` failures are mapped to typed SDK errors instead of timing out.
`LocalParticipant.setTrackMuted(publication:muted:)` now sends LiveKit
`MuteTrackRequest` messages for local publications and waits for matching
`RequestResponse` acknowledgements before applying local mute state.
Room-connected local
track unpublish and camera/microphone disable flows also send a muted
`MuteTrackRequest` and wait for matching `RequestResponse` acknowledgements
before removing the local publication, and multi-track unpublish sends a
refreshed publisher offer for the remaining local media. Server-initiated
`TrackUnpublishedResponse` messages for local media publications clear local
publication and cached publisher offer reconnect state so resume reconnects and
later publisher offers do not replay removed tracks. When the last local media
track is unpublished, the injected publisher media transport is closed and its
startup state is cleared so stale SRTP transports cannot keep sending.
Room can also send publisher RTP packets through the started injected secure
media transport in tests, establishing the handoff point for the future
capture/encode loop. A stateful publisher RTP bridge now keeps Opus and
H.264 packetizer state across packets/frames before handing RTP packets to that
sink, and Room now stores publisher audio/video RTP sender state by published
SID and local CID so unpublish removes only the matching sender while preserving
remaining local sender state for resume reconnect. Encoded Opus packets, H.264
frames, publisher RTCP packets, and subscriber RTCP packets can now be handed
through those tested Room-level media hooks. Registered publisher and subscriber
RTCP handlers can also receive decoded inbound RTCP from the injected secure
media transport, and deterministic feedback planning can map H.264/VP8
subscriber packet-loss and keyframe-request signals into bounded NACK/PLI RTCP
packets that Room can send through the injected subscriber RTCP transport.
Server-initiated mute messages update local/remote track publication state and emit
`RoomEvent.trackMuteChanged`. Room-level media subscription and subscribed
track settings requests are available through `Room.updateSubscription` and
`Room.updateTrackSettings`; publisher track subscription permissions are
available through `LocalParticipant.setTrackSubscriptionPermissions`. Local
publisher audio/video track update signaling is exposed through
`LocalParticipant.updateAudioTrack` and `LocalParticipant.updateVideoTrack`,
with matching `RequestResponse` acknowledgement handling.
After `TrackPublishedResponse`, publisher publish flows now generate a send-only
SDP offer and send it as `SignalRequest.offer` for the publisher negotiation
path.
Publisher answer routing, data-track control event mapping, data-track
publish/unpublish request flows, and server/SFU media/data-track unpublish cleanup
for reconnect state, injected publisher transport teardown, consent-freshness
execution primitives plus the media-startup consent loop, RTP jitter-buffer
primitives, default socket-backed Room ICE trickle startup, and matching
`RequestResponse` failure mapping are unit-tested, while real default secure
media transport completion, default live consent execution after DTLS,
subscriber jitter-buffer integration, capture/encode loop startup, media
recovery, and end-to-end reconnect hardening are still open.

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
`6.548 us/op`, subscriber SDP answer generation at `107.148 us/op`, STUN
binding roundtrip at `1.893 us/op`, RTP encode/decode at `0.609 us/op`, SRTP
replay protection at `0.049 us/op`, SRTP authenticated roundtrip at
`8.873 us/op`, SRTP AES-CM payload roundtrip at `69.165 us/op`, full SRTP
packet protect/unprotect at `79.796 us/op`, RTCP feedback roundtrip at
`1.941 us/op`, SRTCP packet/replay roundtrip at `0.866 us/op`, SRTCP
authenticated roundtrip at `7.645 us/op`, full SRTCP packet protect/unprotect
at `10.131 us/op`, DTLS-SRTP exporter split at `0.335 us/op`, DTLS-SRTP session
protect/unprotect at `89.203 us/op`, H.264 packetize/depacketize at
`2.657 us/op`, VP8 payload depacketize at `0.167 us/op`, Opus RTP
packetize/depacketize at `0.028 us/op`, and SCTP DCEP open/ack roundtrip at
`0.905 us/op`.

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
That strict gate intentionally fails today because LiveKit E2E secure RTP/RTCP
verification, full ICE/TURN hardening, publisher capture/encode startup,
subscriber-pipeline RTCP feedback dispatch, live SCTP, Apple-platform OpenSSL
packaging validation, and end-to-end LiveKit tests are still open.

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
- H.265/HEVC is a future optional Apple-focused codec profile, not a v1
  production-readiness requirement.
- VP9 and AV1 are future advanced codec profiles for SVC and bandwidth
  efficiency work, not v1 production-readiness requirements.
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
  libopus, and no libvpx. DTLS-SRTP uses a small package-internal OpenSSL 3
  bridge instead of the forbidden WebRTC/BoringSSL runtime.

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
