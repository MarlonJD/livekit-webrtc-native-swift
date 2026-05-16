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
transport retries, DTLS fingerprint material, SDP ICE candidate parsing,
dynamic trickle candidate checklists, SDP ICE credential extraction,
coordinator-created ICE agents, use-candidate nomination, and subscribe-side
H.264 RTP assembly.
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
sequence rollover tracking, RFC 3711 SRTP/SRTCP session key derivation,
client/server DTLS-SRTP packet-protection context wiring, SRTP replay-window
and ROC-aware authentication groundwork, SRTP AES-CM payload
encryption/decryption groundwork, full SRTP/SRTCP packet protect/unprotect APIs
with replay rejection, secure RTP/RTCP datagram send/receive wiring,
nominated ICE-pair guarded transport construction, UDP media datagram socket
transport, bound local ICE UDP sockets that gather host candidates and reuse
the candidate port for STUN checks and media datagrams, ICE agent
connectivity-check orchestration, typed DTLS-SRTP handshake results, `use_srtp`
extension encode/decode and profile selection, SDP DTLS fingerprint/setup
parsing, peer-connection handshake configuration, exporter-backed secure media
session construction with remote fingerprint validation, handshaker-backed
media session binding, plus RTCP
report/feedback packet groundwork.
Basic signal
resume/full-reconnect and alternative signal URL retry are implemented at
unit-test level. Speaker, connection quality,
stream state, room update, subscribed quality, subscription permission,
subscription response, track-subscribed, room-moved, publisher answer, and
publisher trickle messages are also mapped into typed SDK state/events at
unit-test level. Media section requirements, subscribed audio codec updates,
data-track publish/unpublish responses, and data-track subscriber handle
updates are exposed as typed room events, with media section requirements and
data-track subscriber handles also retained as latest-value Room state.
Room-connected data-track
publish/unpublish requests now wait for matching server responses and surface
matching `RequestResponse` failures as typed SDK errors. Server/SFU data-track
unpublish responses clear matching local publication state so reconnect does
not replay stale data tracks. Server/SFU track-unpublished responses for local
media also clear local publication and cached publisher offer state so reconnect
and later publisher offers do not replay removed tracks. Room-connected
`publish(videoTrack:)` and `publish(audioTrack:)` now send LiveKit
`AddTrackRequest` messages and wait for matching `TrackPublishedResponse`
acknowledgements, while matching `RequestResponse` failures are surfaced before
timeout. Local track unpublish and camera/microphone disable also send
muted `MuteTrackRequest` messages and wait for matching `RequestResponse`
acknowledgements before local publication removal; multi-track unpublish also
sends a refreshed publisher offer for the remaining local media, and final
local media unpublish closes and clears the injected publisher media transport.
`Room.updateSubscription` and `Room.updateTrackSettings` expose media
subscription and subscribed track settings signaling.
`LocalParticipant.setTrackSubscriptionPermissions` exposes publisher-controlled
subscription permission signaling, and `LocalParticipant.updateAudioTrack` /
`LocalParticipant.updateVideoTrack` expose local publisher track update
signaling with matching `RequestResponse` acknowledgement handling. Publisher
publish acknowledgements now trigger send-only SDP offer signaling for the
publisher negotiation path. Peer connection coordinators can
now hand negotiated DTLS configuration and nominated ICE pairs into the
handshaker-backed media session binder, and can run ICE checks to select a pair
before binding secure media. Room can now trigger injected publisher and
subscriber media startup after negotiated SDP and final ICE trickle, and can
send local ICE candidate and final-trickle signaling for both peer connection
targets when media startup is configured. Injected media startup can now be
backed by bound local ICE UDP sockets so host candidate gathering, STUN checks,
and media datagrams share the same local port. `JoinResponse` and
`ReconnectResponse` ICE server lists now update both subscriber and publisher
peer connection configurations, and injected bound-socket startup can use
supported `stun:` UDP URLs to add server-reflexive candidates while preserving
socket reuse. `turn:` and `turns:` ICE server URLs are parsed with UDP/TCP/TLS
intent and credentials retained for future relay allocation, and TURN Allocate
request primitives cover requested transport, lifetime, realm, nonce, and
relayed-address decoding. Fresh join, reconnect, and disconnect boundaries now
reset stale remote SDP/ICE negotiation state without replacing the local peer
connection configuration, and regenerate local ICE credentials for the next
negotiation.
Resume reconnects now send LiveKit `SyncState` for retained media subscription
preferences, disabled subscribed tracks, local media/data publications, and
the latest negotiated subscriber answer / publisher offer SDP state at
unit-test level, and keep publisher offer track state so a later local publish
after resume still includes existing local media sections. Real DTLS handshake/exporter
implementation, default Room media transport wiring, RTP sender transport, and
reconnect media recovery remain part of production hardening.

Release-mode microbenchmarks are available with
`swift run -c release LiveKitNativeBenchmarks`. The benchmark suite covers the
implemented signaling, SDP, STUN, RTP, SRTP/SRTCP replay and authentication
tracking, SRTP/SRTCP packet protect/unprotect paths, DTLS-SRTP exporter
splitting and session-protection context, RTCP feedback, H.264, VP8, Opus RTP
scaffolding, and SCTP data-channel message paths, and accepts an external
official SDK/WebRTC baseline CSV for ratio comparisons.

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
