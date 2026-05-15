import AVFoundation
import Foundation

package enum OpusPacketError: Error, Equatable, Sendable {
    case emptyPacket
    case invalidFrameCount
}

package enum OpusAudioPipelineError: Error, Equatable, Sendable {
    case payloadTypeMismatch(expected: UInt8, actual: UInt8)
    case unsupportedAudioFormat
}

package struct OpusVoiceProfile: Equatable, Sendable {
    package var payloadType: UInt8
    package var clockRate: Int
    package var channelCount: Int
    package var frameDurationMilliseconds: Int
    package var mimeType: String

    package init(
        payloadType: UInt8 = 111,
        clockRate: Int = 48_000,
        channelCount: Int = 1,
        frameDurationMilliseconds: Int = 20,
        mimeType: String = "audio/opus"
    ) {
        self.payloadType = payloadType
        self.clockRate = clockRate
        self.channelCount = channelCount
        self.frameDurationMilliseconds = frameDurationMilliseconds
        self.mimeType = mimeType
    }
}

package struct OpusPacket: Equatable, Sendable {
    package var payload: Data
    package var toc: OpusTOC

    package init(payload: Data) throws {
        guard let firstByte = payload.first else {
            throw OpusPacketError.emptyPacket
        }

        self.payload = payload
        self.toc = try OpusTOC(byte: firstByte, payload: payload)
    }
}

package struct OpusTOC: Equatable, Sendable {
    package var configuration: UInt8
    package var isStereo: Bool
    package var frameCountCode: UInt8
    package var frameCount: Int
    package var frameDurationMicroseconds: Int

    package init(byte: UInt8, payload: Data) throws {
        self.configuration = byte >> 3
        self.isStereo = (byte & 0x04) != 0
        self.frameCountCode = byte & 0x03
        self.frameCount = try Self.frameCount(frameCountCode: frameCountCode, payload: payload)
        self.frameDurationMicroseconds = Self.frameDurationMicroseconds(configuration: configuration)
    }

    package var packetDurationMicroseconds: Int {
        frameDurationMicroseconds * frameCount
    }

    private static func frameCount(frameCountCode: UInt8, payload: Data) throws -> Int {
        switch frameCountCode {
        case 0:
            return 1
        case 1, 2:
            return 2
        case 3:
            guard payload.count >= 2 else {
                throw OpusPacketError.invalidFrameCount
            }

            let count = Int(payload[payload.index(after: payload.startIndex)] & 0x3F)
            guard count > 0 else {
                throw OpusPacketError.invalidFrameCount
            }

            return count
        default:
            throw OpusPacketError.invalidFrameCount
        }
    }

    private static func frameDurationMicroseconds(configuration: UInt8) -> Int {
        switch configuration {
        case 0...11:
            [10_000, 20_000, 40_000, 60_000][Int(configuration % 4)]
        case 12...15:
            configuration % 2 == 0 ? 10_000 : 20_000
        default:
            [2_500, 5_000, 10_000, 20_000][Int(configuration % 4)]
        }
    }
}

package final class OpusRTPPacketizer: @unchecked Sendable {
    package var payloadType: UInt8
    package var ssrc: UInt32
    private var nextSequenceNumber: UInt16
    private var nextTimestamp: UInt32

    package init(
        payloadType: UInt8 = 111,
        ssrc: UInt32,
        startingSequenceNumber: UInt16 = 0,
        startingTimestamp: UInt32 = 0
    ) {
        self.payloadType = payloadType
        self.ssrc = ssrc
        self.nextSequenceNumber = startingSequenceNumber
        self.nextTimestamp = startingTimestamp
    }

    package func packetize(_ packet: OpusPacket) -> RTPPacket {
        let rtpPacket = RTPPacket(
            marker: false,
            payloadType: payloadType,
            sequenceNumber: nextSequenceNumber,
            timestamp: nextTimestamp,
            ssrc: ssrc,
            payload: packet.payload
        )

        nextSequenceNumber &+= 1
        nextTimestamp &+= UInt32(packet.toc.packetDurationMicroseconds * 48 / 1_000)
        return rtpPacket
    }
}

package struct OpusRTPDepacketizer: Sendable {
    package init() {}

    package func depacketize(_ packet: RTPPacket) throws -> OpusPacket {
        try OpusPacket(payload: packet.payload)
    }
}

package final class OpusSubscribePipeline: @unchecked Sendable {
    package let expectedPayloadType: UInt8
    private let depacketizer = OpusRTPDepacketizer()
    private var lastSequenceNumber: UInt16?
    package private(set) var droppedPacketCount: Int = 0

    package init(expectedPayloadType: UInt8 = 111) {
        self.expectedPayloadType = expectedPayloadType
    }

    package func append(_ packet: RTPPacket) throws -> OpusPacket {
        guard packet.payloadType == expectedPayloadType else {
            throw OpusAudioPipelineError.payloadTypeMismatch(expected: expectedPayloadType, actual: packet.payloadType)
        }

        if let lastSequenceNumber {
            let expectedSequenceNumber = lastSequenceNumber &+ 1
            droppedPacketCount += Int(packet.sequenceNumber &- expectedSequenceNumber)
        }
        lastSequenceNumber = packet.sequenceNumber

        return try depacketizer.depacketize(packet)
    }
}

package struct NativeMicrophoneCaptureConfiguration: Equatable, Sendable {
    package var echoCancellation: Bool
    package var sampleRate: Int
    package var channelCount: Int
    package var frameDurationMilliseconds: Int

    package init(
        echoCancellation: Bool = true,
        sampleRate: Int = 48_000,
        channelCount: Int = 1,
        frameDurationMilliseconds: Int = 20
    ) {
        self.echoCancellation = echoCancellation
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameDurationMilliseconds = frameDurationMilliseconds
    }
}

package protocol NativeMicrophoneAudioFrameSink: AnyObject, Sendable {
    func microphoneSource(_ source: NativeMicrophoneAudioSource, didOutput buffer: AVAudioPCMBuffer, at time: AVAudioTime)
}

package final class NativeMicrophoneAudioSource: @unchecked Sendable {
    package let configuration: NativeMicrophoneCaptureConfiguration
    private let engine = AVAudioEngine()
    private weak var frameSink: (any NativeMicrophoneAudioFrameSink)?
    private var isTapInstalled = false

    package init(configuration: NativeMicrophoneCaptureConfiguration) {
        self.configuration = configuration
    }

    package var isRunning: Bool {
        engine.isRunning
    }

    package func setFrameSink(_ frameSink: (any NativeMicrophoneAudioFrameSink)?) {
        self.frameSink = frameSink
    }

    package func start() throws {
        installTapIfNeeded()
        try engine.start()
    }

    package func stop() {
        engine.stop()
    }

    package func installTapIfNeeded() {
        guard !isTapInstalled else {
            return
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let framesPerBuffer = AVAudioFrameCount(
            max(1, configuration.sampleRate * configuration.frameDurationMilliseconds / 1_000)
        )
        input.installTap(onBus: 0, bufferSize: framesPerBuffer, format: format) { [weak self] buffer, time in
            guard let self else {
                return
            }

            self.frameSink?.microphoneSource(self, didOutput: buffer, at: time)
        }
        isTapInstalled = true
    }
}

package struct NativeAudioPlayoutConfiguration: Equatable, Sendable {
    package var sampleRate: Double
    package var channelCount: AVAudioChannelCount

    package init(sampleRate: Double = 48_000, channelCount: AVAudioChannelCount = 1) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

package final class NativeAudioPlayoutSource: @unchecked Sendable {
    package let configuration: NativeAudioPlayoutConfiguration
    private lazy var engine = AVAudioEngine()
    private lazy var player = AVAudioPlayerNode()
    private var isConfigured = false

    package init(configuration: NativeAudioPlayoutConfiguration = .init()) {
        self.configuration = configuration
    }

    package var isRunning: Bool {
        guard isConfigured else {
            return false
        }

        return engine.isRunning && player.isPlaying
    }

    package func start() throws {
        try configureIfNeeded()
        try engine.start()
        player.play()
    }

    package func stop() {
        player.stop()
        engine.stop()
    }

    package func schedule(_ buffer: AVAudioPCMBuffer) {
        player.scheduleBuffer(buffer)
    }

    package func configureIfNeeded() throws {
        guard !isConfigured else {
            return
        }

        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: configuration.sampleRate,
            channels: configuration.channelCount
        ) else {
            throw OpusAudioPipelineError.unsupportedAudioFormat
        }

        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        isConfigured = true
    }
}
