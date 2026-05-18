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
H.264 encode output, H.264 publish RTP packetization, LiveKit
`AddTrackRequest` construction, and local camera publication state. Milestone
0.4 adds native microphone track scaffolding, AudioToolbox Opus encode/decode
adapters, Opus RTP packetization/depacketization, audio playout scaffolding,
LiveKit `AddTrackRequest` construction for microphone publishes, and local
microphone publication state. Milestone 0.5 adds VP8 RTP payload descriptor parsing, VP8
frame assembly, keyframe metadata extraction, and a decode-only frame inspector.
Milestone 0.6 adds WebRTC data-channel DCEP open/ack messages, reliable/lossy
SCTP channel planning, LiveKit `DataPacket` user-packet mapping,
`publish(data:options:)` local publish planning, and data-track
publish/unpublish/update-subscription signaling. The 1.0 hardening path now
adds queued local data publish flushing through an injected SCTP packet
transport, inbound data-channel `DataPacket` event plumbing, and OpenSSL DTLS
application-data packet transport coverage with deterministic packet
fragmentation/reassembly and fragmented-packet retransmission scheduling. Data
channel recovery can reset LiveKit channels after association restart and
Room reconnect responses reset injected publisher data channels before
post-reconnect publish. A
shared WebRTC DTLS/SRTP datagram demux and media/data session binder can keep
persistent OpenSSL DTLS application data and SRTP media on the same selected
ICE datagram path in unit tests, and public default `Room` construction now
selects that shared startup binder for live media/data transport construction.
Active
work has moved to 1.0 hardening with explicit production
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
transport in tests, and that bridge is now used by default camera/microphone
capture and encode pipelines. Native camera-backed tracks encode H.264 through
VideoToolbox, native microphone-backed tracks encode Opus through AudioToolbox
without a vendored codec dependency, and stateful Opus/H.264 publisher RTP
bridge helpers keep packetizer sequence/timestamp state before handing RTP
packets to the secure transport. Room also stores publisher audio/video RTP
sender state by published SID and local CID after successful publish, removes
only the matching sender after unpublish, and preserves remaining sender state
for resume reconnect. Registered publisher/subscriber RTCP handlers can
receive decoded inbound RTCP from the injected secure media transport, and the
default subscriber RTP receive loop now feeds protected RTP through jitter
buffering, H.264/Opus packet assembly, and bounded NACK/PLI feedback dispatch.
A deterministic RTCP receiver-report bandwidth estimator maps packet loss into
adaptive video quality recommendations, and the camera publish pipeline applies
bounded frame backpressure/drop control before queuing VideoToolbox encode
work. Publisher RTCP receiver reports now feed the estimator even without an
external app RTCP handler, and matching H.264 camera pipelines can apply
recommended bitrate/FPS caps to VideoToolbox. Subscriber-side recommendations
can be planned and sent as LiveKit `UpdateTrackSettings` requests for
low/medium/high/off reception, and observed subscriber RTP/Sender Report state
can produce scheduled RTCP Receiver Reports with DLSR timing plus REMB bitrate
feedback over the subscriber secure RTCP transport. `RoomOptions` can opt into
deduplicated automatic subscriber `UpdateTrackSettings` dispatch from the
current receiver-report estimate.
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
installs default socket-backed subscriber and publisher media-data startup
configurations, so live signaling can gather and trickle local ICE candidates
and then use the package-internal OpenSSL DTLS-SRTP identity plus shared
datagram demux to negotiate WebRTC `use_srtp`, export SRTP keying material,
and bind secure RTP/RTCP plus DTLS application-data packet transport when the
remote peer completes the same path.
The WebRTC datagram demux can split DTLS records from SRTP/SRTCP media on the
same underlying selected-pair transport for a shared media/data binder, though
LiveKit server E2E verification for the combined media/data path remains open.
Deterministic ICE consent freshness planning can now schedule
selected-pair checks, timeout expiry, failure expiry, disabled policy behavior,
and clamped jitter without a wall-clock dependency, and an injectable executor
primitive records consent success/failure/expiry state in unit tests. Injected
Room media startup now runs a selected-pair consent loop after secure transport
binding and closes the protected transport on consent expiry. A bounded
RTP jitter buffer primitive can release contiguous packets, skip bounded gaps,
report missing sequence numbers, drop duplicate/old packets, flush in sequence
order, and preserve ordering across sequence-number wrap. `turn:` and `turns:`
ICE server URLs are parsed with UDP/TCP/TLS intent, default UDP TURN relay
allocation now uses credentialed `turn:` entries, and TURN Allocate
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
can now order credentialed relay fallback candidates from parsed ICE server
URLs as UDP, TCP, then TLS while exposing the current UDP datagram-supported
subset. A bounded TURN relay session composes allocation, permission creation,
channel binding, relayed candidate planning, relay transport metadata, and
deterministic maintenance execution over abstract transports, and a setup plan
can create and execute that configured session deterministically. The default
socket-backed Room media startup path now allocates supported UDP TURN relay
candidates through the bound ICE socket, stores relay contexts, trickles the
relayed candidates, and routes selected relayed ICE checks plus media datagrams
through ChannelData bindings. A ChannelData
relay transport can encode outbound payloads and decode inbound packets over
an abstract media datagram transport while
preserving partial stream remainder and peer endpoint metadata. ICE
connectivity-check orchestration now has deterministic pacing, transaction
timeout scheduling, triggered-check priority, STUN 487 role-conflict parsing,
tie-breaker based role-conflict resolution, and `ICEAgent` integration for
queued triggered checks plus role-switch priority recompute. Fresh join,
reconnect, and disconnect boundaries now reset stale remote SDP/ICE negotiation
state without replacing the local peer connection configuration, and regenerate
local ICE credentials for the next negotiation.
Resume reconnects now rebuild retained subscriber answer / publisher offer SDP
with fresh local ICE credentials, send local trickle/final-trickle when media
startup is configured, send LiveKit `SyncState` for retained media subscription
preferences, disabled subscribed tracks, and local media/data publications at
unit-test level, and keep publisher offer track state so a later local publish
after resume still includes existing local media sections. LiveKit E2E
verification for the OpenSSL DTLS-SRTP path, decoded subscriber render/playout,
standards-compliant live SCTP association behavior, TURN TCP/TLS execution,
real-device media timing, complete live congestion/adaptive-quality control,
LiveKit-validated data-channel recovery, and reconnect
media recovery remain part of production
hardening.

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
