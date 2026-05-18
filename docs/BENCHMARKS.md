# LiveKitNative Benchmarks

Last updated: 2026-05-18

## Scope

The repository includes a release-mode benchmark executable:

```sh
swift run -c release LiveKitNativeBenchmarks
```

The benchmark suite measures low-level operations that already exist in this
package:

- LiveKit protobuf signal frame encode/decode
- Subscriber SDP answer generation
- STUN Binding message encode/decode
- RTP packet encode/decode
- SRTP replay-protector sequence tracking
- SRTP auth-tag framing and validation
- SRTP AES-CM payload encrypt/decrypt
- SRTP packet protect/unprotect, including authentication and replay rejection
- RTCP PLI/NACK feedback encode/decode
- SRTCP packet framing, AES-CM payload encrypt/decrypt, auth-tag validation,
  packet protect/unprotect, and replay-protector tracking
- DTLS-SRTP exporter key/salt splitting
- DTLS-SRTP session key derivation and client/server packet protection context
- H.264 RTP packetization/depacketization
- VP8 RTP payload depacketization
- Opus-over-RTP packetization/depacketization scaffolding
- WebRTC data-channel DCEP open/ack encode/decode

These are microbenchmarks, not end-to-end media benchmarks. They do not claim
that the SDK is production-ready, and they do not measure full ICE, DTLS-SRTP,
live DTLS exporter output from a completed handshake, live packet protection
binding to a selected ICE candidate pair, jitter buffering, real-device
platform display validation, audio route/interruption recovery,
Opus codec quality, or LiveKit server compatibility. Those
remain production blockers. Secure RTP/RTCP datagram send/receive behavior is
covered by unit tests; it is intentionally not used as an end-to-end throughput
claim yet.

## Running

```sh
swift run -c release LiveKitNativeBenchmarks \
  --samples 300 \
  --warmup 30 \
  --ops-per-sample 100
```

Options:

- `--samples N`: measured samples per benchmark. Default: `300`.
- `--warmup N`: warmup samples before measurement. Default: `30`.
- `--ops-per-sample N`: base operations per sample. Default: `100`.
- `--baseline PATH`: optional CSV with official SDK/WebRTC baseline numbers.

Use release builds only. Debug builds are useful for checking correctness, but
not for comparing performance.

## CI and Size Gate

CI runs a short benchmark smoke and a compressed release-binary size proxy:

```sh
swift run -c release LiveKitNativeBenchmarks --samples 50 --warmup 5 --ops-per-sample 50
scripts/check_release_size.sh
```

The default size limit is `5,242,880` bytes. Override it with:

```sh
LIVEKIT_NATIVE_MAX_COMPRESSED_BYTES=5242880 scripts/check_release_size.sh
```

This is not a substitute for a final iOS app-size measurement. It is a cheap
regression guard that catches large dependency/runtime growth while the package
still avoids the official binary WebRTC runtime.

## Current Local Results

Command:

```sh
swift run -c release LiveKitNativeBenchmarks --samples 50 --warmup 5 --ops-per-sample 50
```

Environment:

- Generated: `2026-05-18T12:00:46Z`
- OS: `Version 26.3.1 (a) (Build 25D771280a)`
- Architecture: `arm64`
- Build mode: SwiftPM release

Lower median and p95 values are better. `ops/sec` is derived from the median.

| Benchmark | Category | Implementation | Samples | Ops/sample | Median us/op | P95 us/op | Ops/sec |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| `signal.protobuf_roundtrip` | signaling | LiveKitNative | 50 | 100 | 6.370 | 8.350 | 156985.871 |
| `sdp.subscriber_answer` | signaling | LiveKitNative | 50 | 20 | 71.779 | 82.154 | 13931.622 |
| `stun.binding_roundtrip` | ice | LiveKitNative | 50 | 200 | 1.819 | 2.017 | 549828.179 |
| `rtp.packet_encode_decode` | rtp | LiveKitNative | 50 | 500 | 0.621 | 0.735 | 1609875.621 |
| `srtp.replay_protector` | security | LiveKitNative | 50 | 500 | 0.043 | 0.053 | 23484101.263 |
| `srtp.authenticated_roundtrip` | security | LiveKitNative | 50 | 200 | 8.414 | 9.506 | 118847.206 |
| `srtp.aes_cm_payload_roundtrip` | security | LiveKitNative | 50 | 100 | 63.523 | 68.263 | 15742.453 |
| `srtp.packet_protect_unprotect` | security | LiveKitNative | 50 | 100 | 72.390 | 79.541 | 13814.063 |
| `rtcp.feedback_roundtrip` | rtcp | LiveKitNative | 50 | 500 | 1.711 | 1.863 | 584424.844 |
| `srtcp.packet_replay_roundtrip` | security | LiveKitNative | 50 | 500 | 0.809 | 0.878 | 1236222.302 |
| `srtcp.authenticated_roundtrip` | security | LiveKitNative | 50 | 200 | 6.639 | 7.157 | 150626.115 |
| `srtcp.packet_protect_unprotect` | security | LiveKitNative | 50 | 200 | 9.227 | 9.794 | 108371.715 |
| `dtls_srtp.exporter_split` | security | LiveKitNative | 50 | 500 | 0.314 | 0.337 | 3185565.565 |
| `dtls_srtp.session_protect_unprotect` | security | LiveKitNative | 50 | 50 | 79.576 | 82.891 | 12566.628 |
| `h264.packetize_depacketize` | video | LiveKitNative | 50 | 50 | 2.389 | 2.517 | 418557.150 |
| `vp8.payload_depacketize` | video | LiveKitNative | 50 | 500 | 0.136 | 0.154 | 7339449.541 |
| `opus.rtp_packetize_depacketize` | audio | LiveKitNative | 50 | 500 | 0.027 | 0.036 | 36808009.423 |
| `sctp.dcep_open_ack_roundtrip` | data | LiveKitNative | 50 | 500 | 0.762 | 0.857 | 1312194.751 |

## Official SDK/WebRTC Comparison

This repository intentionally does not add the official LiveKit Swift SDK or
the binary WebRTC runtime as dependencies, so official baseline numbers are not
run inside the main package. Instead, the benchmark executable accepts an
external CSV baseline and computes ratios against `LiveKitNative`.

Baseline CSV schema:

```csv
benchmark,implementation,median_us,p95_us,ops_per_second,notes
signal.protobuf_roundtrip,Official LiveKit Swift SDK + WebRTC baseline,0,0,0,replace with measured release-build value
```

A template is available at:

```sh
Benchmarks/Baselines/official-livekit-webrtc-template.csv
```

After measuring the official SDK/WebRTC path in a separate checkout or app, run:

```sh
swift run -c release LiveKitNativeBenchmarks \
  --baseline Benchmarks/Baselines/official-livekit-webrtc-template.csv
```

The report will add a comparison table:

- `1.00x` means equal median latency.
- `> 1.00x` means `LiveKitNative` is faster for that microbenchmark.
- `< 1.00x` means the official SDK/WebRTC baseline is faster.

## Current Comparison Status

Official SDK/WebRTC baseline numbers have not been measured on this machine in
this repository. The only honest comparison today is:

| Area | LiveKitNative | Official SDK/WebRTC baseline | Ratio |
| --- | ---: | ---: | ---: |
| Microbenchmarks listed above | measured | pending external CSV | pending |
| End-to-end join/subscribe/publish | not implemented | production SDK exists | not comparable |
| Media transport throughput | not implemented | production WebRTC exists | not comparable |
| App size/dependency footprint | no Rust, UniFFI, WebRTC binary, BoringSSL, libopus, or libvpx artifacts in repo | pending external release-app measurement | pending |

Do not use these microbenchmark numbers to tag `1.0.0`. They are useful for
tracking regressions in the tiny Swift implementation while the production
blockers are being closed.
