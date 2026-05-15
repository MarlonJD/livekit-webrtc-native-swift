import Foundation
import LiveKitNative
import LiveKitNativeProtocol
import LiveKitNativeWebRTC

struct BenchmarkConfiguration {
    var samples: Int = 300
    var warmupSamples: Int = 30
    var operationsPerSample: Int = 100
    var baselineCSVPath: String?

    static func parse(arguments: [String]) throws -> BenchmarkConfiguration {
        var configuration = BenchmarkConfiguration()
        var index = 1

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--samples", "--iterations":
                configuration.samples = try parsePositiveInteger(arguments, at: &index, option: argument)
            case "--warmup":
                configuration.warmupSamples = try parsePositiveInteger(arguments, at: &index, option: argument)
            case "--ops-per-sample":
                configuration.operationsPerSample = try parsePositiveInteger(arguments, at: &index, option: argument)
            case "--baseline":
                index += 1
                guard index < arguments.count else {
                    throw BenchmarkCLIError.missingValue(argument)
                }
                configuration.baselineCSVPath = arguments[index]
            case "--help", "-h":
                throw BenchmarkCLIError.helpRequested
            default:
                throw BenchmarkCLIError.unknownArgument(argument)
            }

            index += 1
        }

        return configuration
    }

    private static func parsePositiveInteger(_ arguments: [String], at index: inout Int, option: String) throws -> Int {
        index += 1
        guard index < arguments.count else {
            throw BenchmarkCLIError.missingValue(option)
        }

        guard let value = Int(arguments[index]), value > 0 else {
            throw BenchmarkCLIError.invalidInteger(option, arguments[index])
        }

        return value
    }
}

enum BenchmarkCLIError: Error, CustomStringConvertible {
    case helpRequested
    case missingValue(String)
    case invalidInteger(String, String)
    case unknownArgument(String)

    var description: String {
        switch self {
        case .helpRequested:
            Self.usage
        case let .missingValue(option):
            "Missing value for \(option).\n\n\(Self.usage)"
        case let .invalidInteger(option, value):
            "Expected a positive integer for \(option), got \(value).\n\n\(Self.usage)"
        case let .unknownArgument(argument):
            "Unknown argument: \(argument)\n\n\(Self.usage)"
        }
    }

    static let usage = """
    Usage:
      swift run -c release LiveKitNativeBenchmarks [options]

    Options:
      --samples N            Measured samples per benchmark. Default: 300
      --iterations N         Alias for --samples.
      --warmup N             Warmup samples before measurement. Default: 30
      --ops-per-sample N     Operations per measured sample. Default: 100
      --baseline PATH        Optional CSV with official SDK/WebRTC baseline rows.
      --help                 Show this help text.

    Baseline CSV columns:
      benchmark,implementation,median_us,p95_us,ops_per_second,notes
    """
}

struct BenchmarkCase {
    var name: String
    var category: String
    var operationsPerSample: Int?
    var operation: () throws -> Void
}

struct BenchmarkResult {
    var name: String
    var category: String
    var implementation: String
    var samples: Int
    var operationsPerSample: Int
    var medianMicroseconds: Double
    var p95Microseconds: Double
    var operationsPerSecond: Double
}

struct BaselineResult {
    var benchmark: String
    var implementation: String
    var medianMicroseconds: Double
    var p95Microseconds: Double
    var operationsPerSecond: Double
    var notes: String
}

final class BenchmarkBlackhole {
    private var storage: UInt64 = 0

    @inline(never)
    func consume(_ value: Int) {
        storage &+= UInt64(value)
    }

    @inline(never)
    func consume(_ value: UInt64) {
        storage &+= value
    }

    @inline(never)
    func consume(_ data: Data) {
        storage &+= UInt64(data.count)
        if let firstByte = data.first {
            storage &+= UInt64(firstByte)
        }
    }

    @inline(never)
    func consume(_ string: String) {
        storage &+= UInt64(string.utf8.count)
        if let firstByte = string.utf8.first {
            storage &+= UInt64(firstByte)
        }
    }

    var value: UInt64 {
        storage
    }
}

struct BenchmarkRunner {
    var configuration: BenchmarkConfiguration

    func run(_ benchmark: BenchmarkCase) throws -> BenchmarkResult {
        let operationsPerSample = benchmark.operationsPerSample ?? configuration.operationsPerSample

        for _ in 0..<configuration.warmupSamples {
            for _ in 0..<operationsPerSample {
                try benchmark.operation()
            }
        }

        var measuredMicroseconds: [Double] = []
        measuredMicroseconds.reserveCapacity(configuration.samples)

        for _ in 0..<configuration.samples {
            let start = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<operationsPerSample {
                try benchmark.operation()
            }
            let end = DispatchTime.now().uptimeNanoseconds
            let microsecondsPerOperation = Double(end - start) / 1_000.0 / Double(operationsPerSample)
            measuredMicroseconds.append(microsecondsPerOperation)
        }

        let sorted = measuredMicroseconds.sorted()
        let median = sorted[sorted.count / 2]
        let p95Index = min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))
        let p95 = sorted[p95Index]

        return BenchmarkResult(
            name: benchmark.name,
            category: benchmark.category,
            implementation: "LiveKitNative",
            samples: configuration.samples,
            operationsPerSample: operationsPerSample,
            medianMicroseconds: median,
            p95Microseconds: p95,
            operationsPerSecond: 1_000_000.0 / median
        )
    }
}

enum BaselineCSV {
    static func load(path: String) throws -> [String: BaselineResult] {
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        var baselines: [String: BaselineResult] = [:]

        for (lineIndex, rawLine) in contents.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else {
                continue
            }
            guard lineIndex != 0 else {
                continue
            }

            let fields = line.split(separator: ",", omittingEmptySubsequences: false).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard fields.count >= 5,
                  let median = Double(fields[2]),
                  let p95 = Double(fields[3]),
                  let ops = Double(fields[4])
            else {
                continue
            }

            let result = BaselineResult(
                benchmark: fields[0],
                implementation: fields[1],
                medianMicroseconds: median,
                p95Microseconds: p95,
                operationsPerSecond: ops,
                notes: fields.count > 5 ? fields[5] : ""
            )
            baselines[result.benchmark] = result
        }

        return baselines
    }
}

enum BenchmarkReport {
    static func render(
        results: [BenchmarkResult],
        baselines: [String: BaselineResult],
        blackholeValue: UInt64
    ) -> String {
        var lines: [String] = []
        lines.append("# LiveKitNative Benchmark Results")
        lines.append("")
        lines.append("- Generated: \(ISO8601DateFormatter().string(from: Date()))")
        lines.append("- OS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("- Architecture: \(currentArchitecture)")
        lines.append("- Build mode: use `swift run -c release LiveKitNativeBenchmarks` for comparable numbers")
        lines.append("- Blackhole checksum: \(blackholeValue)")
        lines.append("")
        lines.append("Lower median and p95 values are better. `ops/sec` is derived from the median.")
        lines.append("")
        lines.append("| Benchmark | Category | Implementation | Samples | Ops/sample | Median us/op | P95 us/op | Ops/sec |")
        lines.append("| --- | --- | --- | ---: | ---: | ---: | ---: | ---: |")

        for result in results {
            lines.append(
                "| \(result.name) | \(result.category) | \(result.implementation) | \(result.samples) | \(result.operationsPerSample) | \(format(result.medianMicroseconds)) | \(format(result.p95Microseconds)) | \(format(result.operationsPerSecond)) |"
            )
        }

        lines.append("")
        lines.append("## Baseline Comparison")
        lines.append("")

        if baselines.isEmpty {
            lines.append("No official SDK/WebRTC baseline CSV was supplied. Re-run with `--baseline path/to/baseline.csv` to compute ratios.")
        } else {
            lines.append("| Benchmark | Baseline implementation | Baseline median us/op | LiveKitNative median us/op | Native speed ratio |")
            lines.append("| --- | --- | ---: | ---: | ---: |")
            for result in results {
                guard let baseline = baselines[result.name] else {
                    continue
                }
                let ratio = baseline.medianMicroseconds / result.medianMicroseconds
                lines.append(
                    "| \(result.name) | \(baseline.implementation) | \(format(baseline.medianMicroseconds)) | \(format(result.medianMicroseconds)) | \(format(ratio))x |"
                )
            }
        }

        return lines.joined(separator: "\n")
    }

    private static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x86_64"
        #else
        "unknown"
        #endif
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}

func makeBenchmarks(blackhole: BenchmarkBlackhole) throws -> [BenchmarkCase] {
    let signalCodec = SignalFrameCodec()
    let signalResponse = makeSignalResponseFixture()

    let subscriberOffer = """
    v=0
    o=- 1 1 IN IP4 127.0.0.1
    s=-
    t=0 0
    a=group:BUNDLE 0 1 data
    m=audio 9 UDP/TLS/RTP/SAVPF 111 63
    a=mid:0
    a=setup:actpass
    a=rtcp-mux
    a=rtpmap:111 opus/48000/2
    a=rtpmap:63 red/48000/2
    m=video 9 UDP/TLS/RTP/SAVPF 102 96 35
    a=mid:1
    a=setup:actpass
    a=rtcp-mux
    a=rtpmap:102 H264/90000
    a=rtpmap:96 VP8/90000
    a=rtpmap:35 AV1/90000
    m=application 9 UDP/DTLS/SCTP webrtc-datachannel
    a=mid:data
    a=setup:actpass
    a=sctp-port:5000
    """
    let answerFactory = SubscriberSDPAnswerFactory(
        iceCredentials: ICECredentials(usernameFragment: "ufragfix", password: "pwd-fixed-value-123456"),
        dtlsFingerprint: DTLSSignature(hashFunction: "sha-256", value: "AA:BB:CC")
    )

    let transactionID = try STUNTransactionID(bytes: Array(0..<12).map(UInt8.init))
    let stunMessage = STUNMessage(
        type: .bindingRequest,
        transactionID: transactionID,
        attributes: [
            .username("local:remote"),
            .priority(2_132_260_223),
            .iceControlling(tieBreaker: 0x1122_3344_5566_7788),
            .useCandidate,
        ]
    )

    let rtpPayload = Data(repeating: 0xAB, count: 1_200)
    let rtpPacket = RTPPacket(
        marker: true,
        payloadType: 102,
        sequenceNumber: 42,
        timestamp: 90_000,
        ssrc: 7,
        payload: rtpPayload
    )

    var h264NALUnit = Data([0x65])
    h264NALUnit.append(Data(repeating: 0x11, count: 3_000))
    let h264Packetizer = H264RTPPacketizer(payloadType: 102, mtu: 1_200)

    var vp8Payload = Data([0x10])
    vp8Payload.append(Data([0x9D, 0x01, 0x2A, 0x80, 0x02, 0xE0, 0x01]))
    vp8Payload.append(Data(repeating: 0x22, count: 1_000))
    let vp8Packet = RTPPacket(
        marker: true,
        payloadType: 96,
        sequenceNumber: 77,
        timestamp: 12_345,
        ssrc: 8,
        payload: vp8Payload
    )
    let vp8Depacketizer = VP8RTPDepacketizer()

    let opusPayload = Data([0x78, 0x01, 0x02, 0x03, 0x04, 0x05])
    let opusPacket = try OpusPacket(payload: opusPayload)
    let opusPacketizer = OpusRTPPacketizer(ssrc: 9)
    let opusDepacketizer = OpusRTPDepacketizer()

    let dcepOpen = SCTPDataChannelControlMessage.open(
        SCTPDataChannelOpenMessage(reliability: .reliable, label: LiveKitSCTPDataChannelLabel.reliable)
    )

    return [
        BenchmarkCase(name: "signal.protobuf_roundtrip", category: "signaling", operationsPerSample: 100) {
            let encoded = try signalCodec.encode(signalResponse)
            let decoded = try signalCodec.decode(Livekit_SignalResponse.self, from: encoded)
            if case let .join(join)? = decoded.message {
                blackhole.consume(join.participant.sid.count + join.otherParticipants.count)
            }
        },
        BenchmarkCase(name: "sdp.subscriber_answer", category: "signaling", operationsPerSample: 20) {
            let answer = try answerFactory.makeAnswer(to: subscriberOffer)
            blackhole.consume(answer)
        },
        BenchmarkCase(name: "stun.binding_roundtrip", category: "ice", operationsPerSample: 200) {
            let encoded = try stunMessage.encoded()
            let decoded = try STUNMessage(decoding: encoded)
            blackhole.consume(decoded.attributes.count + encoded.count)
        },
        BenchmarkCase(name: "rtp.packet_encode_decode", category: "rtp", operationsPerSample: 500) {
            let encoded = rtpPacket.encoded()
            let decoded = try RTPPacket(decoding: encoded)
            blackhole.consume(decoded.payload.count + encoded.count)
        },
        BenchmarkCase(name: "h264.packetize_depacketize", category: "video", operationsPerSample: 50) {
            let packets = try h264Packetizer.packetize(
                nalUnits: [h264NALUnit],
                timestamp: 90_000,
                ssrc: 10,
                startingSequenceNumber: 1
            )
            let depacketizer = H264RTPDepacketizer()
            var units = 0
            for packet in packets {
                units += try depacketizer.append(packet).count
            }
            blackhole.consume(units + packets.count)
        },
        BenchmarkCase(name: "vp8.payload_depacketize", category: "video", operationsPerSample: 500) {
            let fragment = try vp8Depacketizer.depacketize(vp8Packet)
            blackhole.consume(fragment.payload.count + Int(fragment.sequenceNumber))
        },
        BenchmarkCase(name: "opus.rtp_packetize_depacketize", category: "audio", operationsPerSample: 500) {
            let packet = opusPacketizer.packetize(opusPacket)
            let decoded = try opusDepacketizer.depacketize(packet)
            blackhole.consume(decoded.payload.count + Int(packet.sequenceNumber))
        },
        BenchmarkCase(name: "sctp.dcep_open_ack_roundtrip", category: "data", operationsPerSample: 500) {
            let encoded = dcepOpen.encoded()
            let decoded = try SCTPDataChannelControlMessage(decoding: encoded)
            if case let .open(message) = decoded {
                blackhole.consume(message.label.count + encoded.count)
            }
        },
    ]
}

func makeSignalResponseFixture() -> Livekit_SignalResponse {
    var localParticipant = Livekit_ParticipantInfo()
    localParticipant.sid = "PA_local"
    localParticipant.identity = "local"
    localParticipant.name = "Local"
    localParticipant.state = .active

    var track = Livekit_TrackInfo()
    track.sid = "TR_camera"
    track.name = "camera"
    track.type = .video
    track.source = .camera
    track.mimeType = "video/H264"

    var remoteParticipant = Livekit_ParticipantInfo()
    remoteParticipant.sid = "PA_remote"
    remoteParticipant.identity = "remote"
    remoteParticipant.name = "Remote"
    remoteParticipant.state = .active
    remoteParticipant.tracks = [track]

    var join = Livekit_JoinResponse()
    join.participant = localParticipant
    join.otherParticipants = [remoteParticipant]

    var response = Livekit_SignalResponse()
    response.join = join
    return response
}

do {
    let configuration = try BenchmarkConfiguration.parse(arguments: CommandLine.arguments)
    let blackhole = BenchmarkBlackhole()
    let benchmarks = try makeBenchmarks(blackhole: blackhole)
    let runner = BenchmarkRunner(configuration: configuration)
    let results = try benchmarks.map { try runner.run($0) }
    let baselines = try configuration.baselineCSVPath.map { try BaselineCSV.load(path: $0) } ?? [:]
    print(BenchmarkReport.render(results: results, baselines: baselines, blackholeValue: blackhole.value))
} catch let error as BenchmarkCLIError {
    print(error.description)
    if case .helpRequested = error {
        exit(0)
    } else {
        exit(2)
    }
} catch {
    fputs("Benchmark failed: \(error)\n", stderr)
    exit(1)
}
