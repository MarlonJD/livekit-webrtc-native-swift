import AVFoundation
import AudioToolbox
import Foundation

package enum OpusPacketError: Error, Equatable, Sendable {
    case emptyPacket
    case invalidFrameCount
}

package enum OpusAudioPipelineError: Error, Equatable, Sendable {
    case payloadTypeMismatch(expected: UInt8, actual: UInt8)
    case unsupportedAudioFormat
    case audioConverterCreationFailed(OSStatus)
    case audioConverterPropertyFailed(OSStatus)
    case audioConversionFailed(OSStatus)
    case encodedPacketUnavailable
    case decodedPCMBufferUnavailable
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

package final class OpusAudioConverterEncoder: @unchecked Sendable {
    package let profile: OpusVoiceProfile
    package let bitrate: UInt32
    private var converter: AudioConverterRef?
    private var configuredInputSampleRate: Double?
    private var configuredInputChannelCount: Int?

    package init(profile: OpusVoiceProfile = OpusVoiceProfile(), bitrate: UInt32 = 32_000) {
        self.profile = profile
        self.bitrate = bitrate
    }

    deinit {
        if let converter {
            AudioConverterDispose(converter)
        }
    }

    package func encode(_ buffer: AVAudioPCMBuffer) throws -> OpusPacket {
        let input = try InterleavedFloatPCMInput(buffer: buffer)
        let converter = try configureIfNeeded(
            sampleRate: input.sampleRate,
            channelCount: input.channelCount
        )
        let context = AudioConverterLinearPCMInputContext(
            data: input.data,
            frameCount: input.frameCount,
            channelCount: input.channelCount
        )

        var outputPacketCount: UInt32 = 1
        var outputData = Data(count: Int(maximumOutputPacketSize(converter: converter)))
        var outputBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: UInt32(profile.channelCount),
                mDataByteSize: UInt32(outputData.count),
                mData: nil
            )
        )

        let status = outputData.withUnsafeMutableBytes { outputBytes in
            outputBufferList.mBuffers.mData = outputBytes.baseAddress
            return AudioConverterFillComplexBuffer(
                converter,
                opusLinearPCMInputProc,
                Unmanaged.passUnretained(context).toOpaque(),
                &outputPacketCount,
                &outputBufferList,
                nil
            )
        }
        guard status == noErr else {
            throw OpusAudioPipelineError.audioConversionFailed(status)
        }
        guard outputPacketCount > 0, outputBufferList.mBuffers.mDataByteSize > 0 else {
            throw OpusAudioPipelineError.encodedPacketUnavailable
        }

        return try OpusPacket(payload: outputData.prefixBytes(Int(outputBufferList.mBuffers.mDataByteSize)))
    }

    package func invalidate() {
        if let converter {
            AudioConverterDispose(converter)
        }
        converter = nil
        configuredInputSampleRate = nil
        configuredInputChannelCount = nil
    }

    private func configureIfNeeded(sampleRate: Double, channelCount: Int) throws -> AudioConverterRef {
        if let converter,
           configuredInputSampleRate == sampleRate,
           configuredInputChannelCount == channelCount {
            return converter
        }

        invalidate()

        var inputDescription = Self.linearPCMDescription(sampleRate: sampleRate, channelCount: channelCount)
        var outputDescription = Self.opusDescription(
            sampleRate: Double(profile.clockRate),
            channelCount: profile.channelCount,
            framesPerPacket: profile.framesPerPacket
        )

        var newConverter: AudioConverterRef?
        let creationStatus = AudioConverterNew(
            &inputDescription,
            &outputDescription,
            &newConverter
        )
        guard creationStatus == noErr, let newConverter else {
            throw OpusAudioPipelineError.audioConverterCreationFailed(creationStatus)
        }

        var mutableBitrate = bitrate
        let propertyStatus = AudioConverterSetProperty(
            newConverter,
            kAudioConverterEncodeBitRate,
            UInt32(MemoryLayout<UInt32>.size),
            &mutableBitrate
        )
        if propertyStatus != noErr {
            AudioConverterDispose(newConverter)
            throw OpusAudioPipelineError.audioConverterPropertyFailed(propertyStatus)
        }

        converter = newConverter
        configuredInputSampleRate = sampleRate
        configuredInputChannelCount = channelCount
        return newConverter
    }

    private func maximumOutputPacketSize(converter: AudioConverterRef) -> UInt32 {
        var packetSize: UInt32 = 1_500
        var propertySize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioConverterGetProperty(
            converter,
            kAudioConverterPropertyMaximumOutputPacketSize,
            &propertySize,
            &packetSize
        )
        guard status == noErr else {
            return 1_500
        }

        return max(packetSize, 1_500)
    }

    fileprivate static func linearPCMDescription(sampleRate: Double, channelCount: Int) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(channelCount * MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(channelCount * MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
    }

    fileprivate static func opusDescription(
        sampleRate: Double,
        channelCount: Int,
        framesPerPacket: Int
    ) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(max(1, framesPerPacket)),
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 0,
            mReserved: 0
        )
    }
}

package final class OpusAudioConverterDecoder: @unchecked Sendable {
    package let profile: OpusVoiceProfile
    private var converter: AudioConverterRef?

    package init(profile: OpusVoiceProfile = OpusVoiceProfile()) {
        self.profile = profile
    }

    deinit {
        if let converter {
            AudioConverterDispose(converter)
        }
    }

    package func decode(_ packet: OpusPacket) throws -> AVAudioPCMBuffer {
        let converter = try configureIfNeeded()
        let frameCapacity = max(1, packet.toc.packetDurationMicroseconds * profile.clockRate / 1_000_000)
        let byteCapacity = frameCapacity * profile.channelCount * MemoryLayout<Float>.size
        let context = AudioConverterCompressedInputContext(
            data: packet.payload,
            framesPerPacket: frameCapacity,
            channelCount: profile.channelCount
        )

        var outputFrameCount = UInt32(frameCapacity)
        var outputData = Data(count: byteCapacity)
        var outputBufferList = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: UInt32(profile.channelCount),
                mDataByteSize: UInt32(outputData.count),
                mData: nil
            )
        )

        let status = outputData.withUnsafeMutableBytes { outputBytes in
            outputBufferList.mBuffers.mData = outputBytes.baseAddress
            return AudioConverterFillComplexBuffer(
                converter,
                opusCompressedInputProc,
                Unmanaged.passUnretained(context).toOpaque(),
                &outputFrameCount,
                &outputBufferList,
                nil
            )
        }
        guard status == noErr else {
            throw OpusAudioPipelineError.audioConversionFailed(status)
        }

        return try Self.pcmBuffer(
            interleavedFloatData: outputData,
            frameCount: Int(outputFrameCount),
            channelCount: profile.channelCount,
            sampleRate: Double(profile.clockRate)
        )
    }

    package func invalidate() {
        if let converter {
            AudioConverterDispose(converter)
        }
        converter = nil
    }

    private func configureIfNeeded() throws -> AudioConverterRef {
        if let converter {
            return converter
        }

        var inputDescription = OpusAudioConverterEncoder.opusDescription(
            sampleRate: Double(profile.clockRate),
            channelCount: profile.channelCount,
            framesPerPacket: profile.framesPerPacket
        )
        var outputDescription = OpusAudioConverterEncoder.linearPCMDescription(
            sampleRate: Double(profile.clockRate),
            channelCount: profile.channelCount
        )

        var newConverter: AudioConverterRef?
        let creationStatus = AudioConverterNew(
            &inputDescription,
            &outputDescription,
            &newConverter
        )
        guard creationStatus == noErr, let newConverter else {
            throw OpusAudioPipelineError.audioConverterCreationFailed(creationStatus)
        }

        converter = newConverter
        return newConverter
    }

    private static func pcmBuffer(
        interleavedFloatData data: Data,
        frameCount: Int,
        channelCount: Int,
        sampleRate: Double
    ) throws -> AVAudioPCMBuffer {
        guard let format = AVAudioFormat(
            standardFormatWithSampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount)
        ),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(frameCount)
            ),
            let outputChannels = buffer.floatChannelData
        else {
            throw OpusAudioPipelineError.decodedPCMBufferUnavailable
        }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        data.withUnsafeBytes { rawBytes in
            let samples = rawBytes.bindMemory(to: Float.self)
            for frame in 0..<frameCount {
                for channel in 0..<channelCount {
                    outputChannels[channel][frame] = samples[frame * channelCount + channel]
                }
            }
        }

        return buffer
    }
}

package final class OpusMicrophonePublishPipeline: NativeMicrophoneAudioFrameSink, @unchecked Sendable {
    package let source: NativeMicrophoneAudioSource
    package let encoder: OpusAudioConverterEncoder
    private let sendPacket: @Sendable (OpusPacket) async throws -> Void
    private let lock = NSLock()
    private var mutableIsRunning = false
    private var mutableLastError: (any Error)?

    package init(
        source: NativeMicrophoneAudioSource,
        encoder: OpusAudioConverterEncoder,
        sendPacket: @escaping @Sendable (OpusPacket) async throws -> Void
    ) {
        self.source = source
        self.encoder = encoder
        self.sendPacket = sendPacket
    }

    package var isRunning: Bool {
        lock.withLock {
            mutableIsRunning
        }
    }

    package var lastError: (any Error)? {
        lock.withLock {
            mutableLastError
        }
    }

    package func start() throws {
        let shouldStart = lock.withLock {
            guard !mutableIsRunning else {
                return false
            }
            mutableIsRunning = true
            mutableLastError = nil
            return true
        }
        guard shouldStart else {
            return
        }

        do {
            source.setFrameSink(self)
            try source.start()
        } catch {
            lock.withLock {
                mutableIsRunning = false
                mutableLastError = error
            }
            source.setFrameSink(nil)
            throw error
        }
    }

    package func stop() {
        source.stop()
        source.setFrameSink(nil)
        encoder.invalidate()
        lock.withLock {
            mutableIsRunning = false
        }
    }

    package func microphoneSource(
        _ source: NativeMicrophoneAudioSource,
        didOutput buffer: AVAudioPCMBuffer,
        at time: AVAudioTime
    ) {
        do {
            let packet = try encoder.encode(buffer)
            dispatch(packet)
        } catch {
            lock.withLock {
                mutableLastError = error
            }
        }
    }

    private func dispatch(_ packet: OpusPacket) {
        Task { [sendPacket] in
            do {
                try await sendPacket(packet)
            } catch {
                self.lock.withLock {
                    self.mutableLastError = error
                }
            }
        }
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

private extension OpusVoiceProfile {
    var framesPerPacket: Int {
        max(1, clockRate * frameDurationMilliseconds / 1_000)
    }
}

private struct InterleavedFloatPCMInput {
    var data: Data
    var frameCount: Int
    var channelCount: Int
    var sampleRate: Double

    init(buffer: AVAudioPCMBuffer) throws {
        guard let channelData = buffer.floatChannelData else {
            throw OpusAudioPipelineError.unsupportedAudioFormat
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        guard frameCount > 0, channelCount > 0 else {
            throw OpusAudioPipelineError.unsupportedAudioFormat
        }

        self.frameCount = frameCount
        self.channelCount = channelCount
        self.sampleRate = buffer.format.sampleRate
        self.data = Data(count: frameCount * channelCount * MemoryLayout<Float>.size)

        data.withUnsafeMutableBytes { rawBytes in
            let samples = rawBytes.bindMemory(to: Float.self)
            if buffer.format.isInterleaved {
                let source = UnsafeBufferPointer(start: channelData[0], count: frameCount * channelCount)
                for index in source.indices {
                    samples[index] = source[index]
                }
            } else {
                for frame in 0..<frameCount {
                    for channel in 0..<channelCount {
                        samples[frame * channelCount + channel] = channelData[channel][frame]
                    }
                }
            }
        }
    }
}

private final class AudioConverterLinearPCMInputContext {
    let data: Data
    let frameCount: Int
    let channelCount: Int
    var didProvideData = false

    init(data: Data, frameCount: Int, channelCount: Int) {
        self.data = data
        self.frameCount = frameCount
        self.channelCount = channelCount
    }
}

private final class AudioConverterCompressedInputContext {
    let data: Data
    let channelCount: Int
    let packetDescription: UnsafeMutablePointer<AudioStreamPacketDescription>
    var didProvideData = false

    init(data: Data, framesPerPacket: Int, channelCount: Int) {
        self.data = data
        self.channelCount = channelCount
        self.packetDescription = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
        self.packetDescription.initialize(
            to: AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: UInt32(max(1, framesPerPacket)),
                mDataByteSize: UInt32(data.count)
            )
        )
    }

    deinit {
        packetDescription.deinitialize(count: 1)
        packetDescription.deallocate()
    }
}

private let opusLinearPCMInputProc: AudioConverterComplexInputDataProc = {
    _,
    ioNumberDataPackets,
    ioData,
    _,
    userData in
    guard let userData else {
        return -1
    }

    let context = Unmanaged<AudioConverterLinearPCMInputContext>
        .fromOpaque(userData)
        .takeUnretainedValue()
    guard !context.didProvideData else {
        ioNumberDataPackets.pointee = 0
        return noErr
    }

    context.didProvideData = true
    ioNumberDataPackets.pointee = UInt32(context.frameCount)

    return context.data.withUnsafeBytes { rawBytes in
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers = AudioBuffer(
            mNumberChannels: UInt32(context.channelCount),
            mDataByteSize: UInt32(context.data.count),
            mData: UnsafeMutableRawPointer(mutating: rawBytes.baseAddress)
        )
        return noErr
    }
}

private let opusCompressedInputProc: AudioConverterComplexInputDataProc = {
    _,
    ioNumberDataPackets,
    ioData,
    outDataPacketDescription,
    userData in
    guard let userData else {
        return -1
    }

    let context = Unmanaged<AudioConverterCompressedInputContext>
        .fromOpaque(userData)
        .takeUnretainedValue()
    guard !context.didProvideData else {
        ioNumberDataPackets.pointee = 0
        return noErr
    }

    context.didProvideData = true
    ioNumberDataPackets.pointee = 1
    outDataPacketDescription?.pointee = context.packetDescription

    return context.data.withUnsafeBytes { rawBytes in
        ioData.pointee.mNumberBuffers = 1
        ioData.pointee.mBuffers = AudioBuffer(
            mNumberChannels: UInt32(context.channelCount),
            mDataByteSize: UInt32(context.data.count),
            mData: UnsafeMutableRawPointer(mutating: rawBytes.baseAddress)
        )
        return noErr
    }
}

private extension Data {
    func prefixBytes(_ count: Int) -> Data {
        Data(prefix(count))
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
