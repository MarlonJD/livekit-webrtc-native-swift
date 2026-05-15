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
- H.264 RTP packetization/depacketization
- VP8 RTP payload depacketization
- Opus-over-RTP packetization/depacketization scaffolding
- WebRTC data-channel DCEP open/ack encode/decode

These are microbenchmarks, not end-to-end media benchmarks. They do not claim
that the SDK is production-ready, and they do not measure full ICE, DTLS-SRTP,
SRTP, jitter buffering, VideoToolbox decode/render, Opus codec quality, or
LiveKit server compatibility. Those remain production blockers.

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

- Generated: `2026-05-15T01:08:43Z`
- OS: `Version 26.3.1 (a) (Build 25D771280a)`
- Architecture: `arm64`
- Build mode: SwiftPM release

Lower median and p95 values are better. `ops/sec` is derived from the median.

| Benchmark | Category | Implementation | Samples | Ops/sample | Median us/op | P95 us/op | Ops/sec |
| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |
| `signal.protobuf_roundtrip` | signaling | LiveKitNative | 300 | 100 | 6.159 | 7.285 | 162370.611 |
| `sdp.subscriber_answer` | signaling | LiveKitNative | 300 | 20 | 106.156 | 119.588 | 9420.077 |
| `stun.binding_roundtrip` | ice | LiveKitNative | 300 | 200 | 1.806 | 2.246 | 553760.449 |
| `rtp.packet_encode_decode` | rtp | LiveKitNative | 300 | 500 | 0.589 | 0.771 | 1696830.660 |
| `h264.packetize_depacketize` | video | LiveKitNative | 300 | 50 | 2.513 | 2.793 | 398009.950 |
| `vp8.payload_depacketize` | video | LiveKitNative | 300 | 500 | 0.149 | 0.161 | 6718985.164 |
| `opus.rtp_packetize_depacketize` | audio | LiveKitNative | 300 | 500 | 0.026 | 0.028 | 38217534.205 |
| `sctp.dcep_open_ack_roundtrip` | data | LiveKitNative | 300 | 500 | 0.818 | 1.007 | 1222990.260 |

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
