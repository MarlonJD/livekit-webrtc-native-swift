# LiveKitNative Benchmarks

Last updated: 2026-05-15

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
- H.264 RTP packetization/depacketization
- VP8 RTP payload depacketization
- Opus-over-RTP packetization/depacketization scaffolding
- WebRTC data-channel DCEP open/ack encode/decode

These are microbenchmarks, not end-to-end media benchmarks. They do not claim
that the SDK is production-ready, and they do not measure full ICE, DTLS-SRTP,
full SRTP/SRTCP KDF with live DTLS exporter output, live packet protection
wiring into media transport, jitter buffering, VideoToolbox decode/render, Opus
codec quality, or LiveKit server compatibility. Those remain production
blockers.

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
swift run -c release LiveKitNativeBenchmarks --samples 30 --warmup 5 --ops-per-sample 50
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
swift run -c release LiveKitNativeBenchmarks --samples 300 --warmup 30 --ops-per-sample 100
```

Environment:

- Generated: `2026-05-15T12:37:04Z`
- OS: `Version 26.3.1 (a) (Build 25D771280a)`
- Architecture: `arm64`
- Build mode: SwiftPM release

Lower median and p95 values are better. `ops/sec` is derived from the median.

| Benchmark | Category | Implementation | Samples | Ops/sample | Median us/op | P95 us/op | Ops/sec |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| `signal.protobuf_roundtrip` | signaling | LiveKitNative | 300 | 100 | 6.541 | 8.059 | 152875.979 |
| `sdp.subscriber_answer` | signaling | LiveKitNative | 300 | 20 | 106.275 | 120.667 | 9409.551 |
| `stun.binding_roundtrip` | ice | LiveKitNative | 300 | 200 | 1.847 | 2.154 | 541271.989 |
| `rtp.packet_encode_decode` | rtp | LiveKitNative | 300 | 500 | 0.595 | 0.689 | 1681146.946 |
| `srtp.replay_protector` | security | LiveKitNative | 300 | 500 | 0.046 | 0.056 | 21582423.274 |
| `srtp.authenticated_roundtrip` | security | LiveKitNative | 300 | 200 | 8.876 | 12.453 | 112660.189 |
| `srtp.aes_cm_payload_roundtrip` | security | LiveKitNative | 300 | 100 | 68.147 | 98.413 | 14674.233 |
| `srtp.packet_protect_unprotect` | security | LiveKitNative | 300 | 100 | 74.986 | 87.946 | 13335.778 |
| `rtcp.feedback_roundtrip` | rtcp | LiveKitNative | 300 | 500 | 1.795 | 2.136 | 557206.124 |
| `srtcp.packet_replay_roundtrip` | security | LiveKitNative | 300 | 500 | 0.797 | 0.927 | 1253918.495 |
| `srtcp.authenticated_roundtrip` | security | LiveKitNative | 300 | 200 | 7.228 | 8.731 | 138352.485 |
| `srtcp.packet_protect_unprotect` | security | LiveKitNative | 300 | 200 | 9.589 | 10.751 | 104288.880 |
| `dtls_srtp.exporter_split` | security | LiveKitNative | 300 | 500 | 0.321 | 0.372 | 3117692.907 |
| `h264.packetize_depacketize` | video | LiveKitNative | 300 | 50 | 2.466 | 3.081 | 405541.317 |
| `vp8.payload_depacketize` | video | LiveKitNative | 300 | 500 | 0.150 | 0.187 | 6666666.667 |
| `opus.rtp_packetize_depacketize` | audio | LiveKitNative | 300 | 500 | 0.026 | 0.034 | 38095238.095 |
| `sctp.dcep_open_ack_roundtrip` | data | LiveKitNative | 300 | 500 | 0.822 | 1.014 | 1216175.129 |

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
