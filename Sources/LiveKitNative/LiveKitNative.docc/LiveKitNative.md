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
publish/unpublish/update-subscription signaling. The 1.0 hardening path now
adds queued local data publish flushing through an injected SCTP packet
transport, inbound data-channel `DataPacket` event plumbing, and OpenSSL DTLS
application-data packet transport coverage. Active work has moved to 1.0
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
session construction with remote fingerprint, role, and protection-profile
validation, handshaker-backed media session binding, plus RTCP
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
Room can send publisher RTP packets through a started injected secure media
transport in tests, establishing the bridge for the future capture/encode
loop, and stateful Opus/H.264 publisher RTP bridge helpers now keep packetizer
sequence/timestamp state across packets and frames before handing RTP packets
to that sink. Room also stores publisher audio/video RTP sender state by
published SID and local CID after successful publish, removes only the matching
sender after unpublish, and preserves remaining sender state for resume
reconnect. Encoded Opus packets, H.264 frames, publisher RTCP packets, and
subscriber RTCP packets can now be handed through the tested Room-level media
hooks, registered publisher/subscriber RTCP handlers can receive decoded
inbound RTCP from the injected secure media transport, and a deterministic
feedback planner can map H.264/VP8 subscriber packet-loss and keyframe-request
signals into bounded NACK/PLI RTCP packets that Room can send through the
injected subscriber RTCP transport.
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
before binding secure media. Room can now trigger publisher and subscriber media
startup after negotiated SDP and final ICE trickle, and can send local ICE
candidate and final-trickle signaling for both peer connection targets when
media startup is configured. Media startup can now be backed by bound local ICE
UDP sockets so host candidate gathering, STUN checks, and media datagrams share
the same local port. `JoinResponse` and `ReconnectResponse` ICE server lists now
update both subscriber and publisher peer connection configurations, and
bound-socket startup can use supported `stun:` UDP URLs to add server-reflexive
candidates while preserving socket reuse. Public `Room` initialization now
installs default socket-backed subscriber and publisher media startup
configurations, so live signaling can gather and trickle local ICE candidates
and then use the package-internal OpenSSL DTLS-SRTP handshaker to negotiate
WebRTC `use_srtp`, export SRTP keying material, and bind secure RTP/RTCP
transport when the remote peer completes the same path.
Deterministic ICE consent freshness planning can now schedule
selected-pair checks, timeout expiry, failure expiry, disabled policy behavior,
and clamped jitter without a wall-clock dependency, and an injectable executor
primitive records consent success/failure/expiry state in unit tests. Injected
Room media startup now runs a selected-pair consent loop after secure transport
binding and closes the protected transport on consent expiry. A bounded
RTP jitter buffer primitive can release contiguous packets, skip bounded gaps,
report missing sequence numbers, drop duplicate/old packets, flush in sequence
order, and preserve ordering across sequence-number wrap. `turn:` and `turns:`
ICE server URLs are parsed with UDP/TCP/TLS intent and credentials retained for
future relay allocation, and TURN Allocate
request primitives cover requested transport, lifetime, realm, nonce,
`ERROR-CODE`, and relayed-address decoding. TURN allocation client groundwork
can send Allocate requests over the STUN datagram transport abstraction, parse
and validate success responses, and perform one long-term credential 401
challenge retry in unit tests. TURN Refresh request/response validation covers
lifetime refresh and deallocation, CreatePermission request/response validation
covers IPv4 `XOR-PEER-ADDRESS`, ChannelBind request/response validation covers
TURN channel numbers, and authenticated TURN Allocate/Refresh/CreatePermission/
ChannelBind flows retry once on stale nonce responses. TURN ChannelData frame
encode/decode and stream parsing now cover channel-range validation, declared
payload lengths, and 4-byte padding, while deterministic TURN
allocation/permission maintenance planning and scheduling calculate refresh
deadlines, due actions, expiry flags, and next deadlines without a wall-clock
dependency. A TURN maintenance executor now drives injectable allocation and
permission refresh closures and advances scheduler deadlines only on success,
and relay candidate planning can build relayed ICE candidates from TURN
relayed addresses and ChannelBind metadata. TURN relay session configuration
can now select supported UDP relay endpoints from parsed ICE server URLs when
credentials, realm, and nonce are available. A bounded TURN relay session
composes allocation, permission creation, channel binding, relayed candidate
planning, relay transport metadata, and deterministic maintenance execution
over abstract transports, and a setup plan can create and execute that
configured session deterministically. A ChannelData relay transport can
encode outbound payloads and decode inbound packets over an abstract media
datagram transport while
preserving partial stream remainder and peer endpoint metadata. Fresh join,
reconnect, and disconnect boundaries now reset stale remote SDP/ICE negotiation
state without replacing the local peer connection configuration, and regenerate
local ICE credentials for the next negotiation.
Resume reconnects now send LiveKit `SyncState` for retained media subscription
preferences, disabled subscribed tracks, local media/data publications, and
the latest negotiated subscriber answer / publisher offer SDP state at
unit-test level, and keep publisher offer track state so a later local publish
after resume still includes existing local media sections. LiveKit E2E
verification for the OpenSSL DTLS-SRTP path, default subscriber jitter-buffer
integration, standards-compliant live SCTP association behavior, RTP sender
capture/encode startup, subscriber-pipeline RTCP feedback dispatch, and
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
