# ``LiveKitNative``

Build LiveKit clients with native Swift signaling, room state, media adapters,
and data APIs.

## Overview

`LiveKitNative` is an independent Swift 6 package for iOS and macOS. The package
keeps LiveKit client logic in Swift and builds toward a tiny internal
`LiveKitNativeWebRTC` engine for media transport.

Milestone 0 establishes the package structure and public API shape. Milestone
0.1 adds generated LiveKit signaling protobufs, WebSocket frame handling,
initial JoinResponse room state updates, a post-join signal receive loop, and
minimal subscriber offer/answer SDP plumbing for the native WebRTC engine.
Milestone 0.2 adds ICE/STUN groundwork, subscriber trickle handling, STUN
`MESSAGE-INTEGRITY`/`FINGERPRINT` signing and validation, authenticated
connectivity-check request sending and response validation, bounded STUN
transport retries, DTLS fingerprint material, candidate checklist state, and
subscribe-side H.264 RTP assembly.
Milestone 0.3 adds native camera track scaffolding, VideoToolbox
H.264 encoder configuration, H.264 publish RTP packetization, LiveKit
`AddTrackRequest` construction, and local camera publication state. Milestone
0.4 adds native microphone track scaffolding, Opus voice profile defaults, Opus
RTP packetization/depacketization, audio playout scaffolding, LiveKit
`AddTrackRequest` construction for microphone publishes, and local microphone
publication state. Milestone 0.5 adds VP8 RTP payload descriptor parsing, VP8
frame assembly, keyframe metadata extraction, and a decode-only frame inspector.
Milestone 0.6 adds WebRTC data-channel DCEP open/ack messages, reliable/lossy
SCTP channel planning, LiveKit `DataPacket` user-packet mapping,
`publish(data:options:)` local publish planning, and data-track
publish/unpublish/update-subscription signaling. Active work has moved to 1.0
hardening with explicit production
readiness gates, request/response correlation for client-originated signaling,
metadata/name/attribute update requests, configurable logging, disconnect
lifecycle cleanup, DTLS-SRTP protection-profile key/salt splitting, RTP
sequence rollover tracking, SRTP replay-window and ROC-aware authentication
groundwork, SRTP AES-CM payload encryption/decryption groundwork, full
SRTP/SRTCP packet protect/unprotect APIs with replay rejection, plus RTCP
report/feedback packet groundwork.
Basic signal
resume/full-reconnect and alternative signal URL retry are implemented at
unit-test level. Speaker, connection quality,
stream state, room update, subscribed quality, subscription permission,
subscription response, track-subscribed, room-moved, publisher answer, and
publisher trickle messages are also mapped into typed SDK state/events at
unit-test level. Media section requirements, subscribed audio codec updates,
data-track publish/unpublish responses, and data-track subscriber handle
updates are exposed as typed room events. Room-connected data-track
publish/unpublish requests now wait for matching server responses. Room-connected
`publish(videoTrack:)` and `publish(audioTrack:)` now send LiveKit
`AddTrackRequest` messages and wait for matching `TrackPublishedResponse`
acknowledgements, while publisher offer generation, media transport, and
reconnect media recovery remain part of production hardening.

Release-mode microbenchmarks are available with
`swift run -c release LiveKitNativeBenchmarks`. The benchmark suite covers the
implemented signaling, SDP, STUN, RTP, SRTP/SRTCP replay and authentication
tracking, SRTP/SRTCP packet protect/unprotect paths, DTLS-SRTP exporter
splitting, RTCP feedback, H.264, VP8, Opus RTP scaffolding, and SCTP
data-channel message paths, and accepts an external official SDK/WebRTC
baseline CSV for ratio comparisons.

Release automation can run `scripts/check_release_readiness.sh` for the current
developer-preview gate, or `REQUIRE_PRODUCTION_READY=1
scripts/check_release_readiness.sh` for a real production tag gate once all
blockers are cleared.

## Topics

### Rooms

- ``Room``
- ``RoomEvent``
- ``RoomDelegate``
- ``ConnectionState``

### Participants

- ``Participant``
- ``LocalParticipant``
- ``RemoteParticipant``

### Tracks

- ``Track``
- ``VideoTrack``
- ``AudioTrack``
- ``TrackPublication``
- ``VideoView``
