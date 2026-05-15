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
Milestone 0.2 adds ICE/STUN groundwork, subscriber trickle handling, DTLS
fingerprint material, candidate checklist state, and subscribe-side H.264 RTP
assembly. Milestone 0.3 adds native camera track scaffolding, VideoToolbox
H.264 encoder configuration, H.264 publish RTP packetization, LiveKit
`AddTrackRequest` construction, and local camera publication state. Active work
has moved to 0.4 audio.

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
