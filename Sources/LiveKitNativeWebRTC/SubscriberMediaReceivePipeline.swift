import Foundation

package struct SubscriberMediaReceiveResult: Equatable, Sendable {
    package var releasedPackets: [RTPPacket]
    package var missingSequenceNumbers: [UInt16]
    package var droppedSequenceNumbers: [UInt16]
    package var h264AccessUnits: [H264AccessUnit]
    package var decodedVideoFrameCount: Int
    package var videoDecodeErrorCount: Int
    package var opusPackets: [OpusPacket]
    package var decodedAudioBufferCount: Int
    package var audioPlayoutErrorCount: Int
    package var feedbackPackets: [RTCPPacket]

    package init(
        releasedPackets: [RTPPacket] = [],
        missingSequenceNumbers: [UInt16] = [],
        droppedSequenceNumbers: [UInt16] = [],
        h264AccessUnits: [H264AccessUnit] = [],
        decodedVideoFrameCount: Int = 0,
        videoDecodeErrorCount: Int = 0,
        opusPackets: [OpusPacket] = [],
        decodedAudioBufferCount: Int = 0,
        audioPlayoutErrorCount: Int = 0,
        feedbackPackets: [RTCPPacket] = []
    ) {
        self.releasedPackets = releasedPackets
        self.missingSequenceNumbers = missingSequenceNumbers
        self.droppedSequenceNumbers = droppedSequenceNumbers
        self.h264AccessUnits = h264AccessUnits
        self.decodedVideoFrameCount = decodedVideoFrameCount
        self.videoDecodeErrorCount = videoDecodeErrorCount
        self.opusPackets = opusPackets
        self.decodedAudioBufferCount = decodedAudioBufferCount
        self.audioPlayoutErrorCount = audioPlayoutErrorCount
        self.feedbackPackets = feedbackPackets
    }
}

package final class SubscriberMediaReceivePipeline: @unchecked Sendable {
    package let audioPayloadType: UInt8
    package let videoPayloadType: UInt8
    package let feedbackSenderSSRC: UInt32
    private let maxBufferedPackets: Int
    private let isVideoDecodeEnabled: Bool
    private let lock = NSLock()
    private var jitterBuffersBySSRC: [UInt32: RTPJitterBuffer] = [:]
    private var h264PipelinesBySSRC: [UInt32: H264SubscribePipeline] = [:]
    private var h264DecodersBySSRC: [UInt32: H264VideoToolboxSubscribeDecoder] = [:]
    private var opusPipelinesBySSRC: [UInt32: OpusSubscribePipeline] = [:]
    private let audioPlayoutPipeline: OpusAudioPlayoutPipeline?
    private let receiverReportStore = RTCPReceiverReportStore()

    package init(
        audioPayloadType: UInt8 = 111,
        videoPayloadType: UInt8 = 102,
        feedbackSenderSSRC: UInt32 = 0,
        maxBufferedPackets: Int = 64,
        videoDecodeEnabled: Bool = false,
        audioPlayoutPipeline: OpusAudioPlayoutPipeline? = nil
    ) {
        self.audioPayloadType = audioPayloadType
        self.videoPayloadType = videoPayloadType
        self.feedbackSenderSSRC = feedbackSenderSSRC
        self.maxBufferedPackets = maxBufferedPackets
        self.isVideoDecodeEnabled = videoDecodeEnabled
        self.audioPlayoutPipeline = audioPlayoutPipeline
    }

    package func append(_ packet: RTPPacket) -> SubscriberMediaReceiveResult {
        lock.withLock {
            appendLocked(packet)
        }
    }

    package func observeRTCP(_ packet: RTCPPacket, receivedAt: TimeInterval = Date().timeIntervalSince1970) {
        receiverReportStore.observe(packet, receivedAt: receivedAt)
    }

    package func receiverReport(
        senderSSRC: UInt32,
        now: TimeInterval = Date().timeIntervalSince1970
    ) -> RTCPPacket? {
        receiverReportStore.receiverReportPacket(senderSSRC: senderSSRC, now: now)
    }

    package var receiverReportSnapshots: [RTCPReceiverReportSnapshot] {
        receiverReportStore.snapshots
    }

    package func reset() {
        lock.withLock {
            jitterBuffersBySSRC.removeAll()
            h264PipelinesBySSRC.removeAll()
            h264DecodersBySSRC.removeAll()
            opusPipelinesBySSRC.removeAll()
            audioPlayoutPipeline?.reset()
            receiverReportStore.reset()
        }
    }

    package var audioPlayoutScheduledBufferCount: Int {
        audioPlayoutPipeline?.scheduledBufferCount ?? 0
    }

    package var decodedVideoFrameCount: Int {
        lock.withLock {
            h264DecodersBySSRC.values.reduce(0) { $0 + $1.decodedFrameCount }
        }
    }

    private func appendLocked(_ packet: RTPPacket) -> SubscriberMediaReceiveResult {
        receiverReportStore.observe(packet)

        var jitterBuffer = jitterBuffersBySSRC[packet.ssrc] ?? RTPJitterBuffer(maxBufferedPackets: maxBufferedPackets)
        let jitterResult = jitterBuffer.insert(packet)
        jitterBuffersBySSRC[packet.ssrc] = jitterBuffer

        var result = SubscriberMediaReceiveResult(
            releasedPackets: jitterResult.releasedPackets,
            missingSequenceNumbers: jitterResult.missingSequenceNumbers,
            droppedSequenceNumbers: jitterResult.droppedSequenceNumbers
        )

        var feedbackSignals = jitterResult.missingSequenceNumbers.isEmpty
            ? []
            : [SubscribeRTCPFeedbackSignal.missingSequenceNumbers(jitterResult.missingSequenceNumbers)]

        for releasedPacket in jitterResult.releasedPackets {
            switch releasedPacket.payloadType {
            case videoPayloadType:
                feedbackSignals.append(contentsOf: appendH264Packet(releasedPacket, result: &result))
            case audioPayloadType:
                appendOpusPacket(releasedPacket, result: &result)
            default:
                result.droppedSequenceNumbers.append(releasedPacket.sequenceNumber)
            }
        }

        result.feedbackPackets = SubscribeRTCPFeedbackPlanner().feedbackPackets(
            senderSSRC: feedbackSenderSSRC,
            mediaSSRC: packet.ssrc,
            signals: feedbackSignals
        )
        return result
    }

    private func appendH264Packet(
        _ packet: RTPPacket,
        result: inout SubscriberMediaReceiveResult
    ) -> [SubscribeRTCPFeedbackSignal] {
        let pipeline = h264PipelinesBySSRC[packet.ssrc] ?? H264SubscribePipeline()
        h264PipelinesBySSRC[packet.ssrc] = pipeline

        let decoder = h264DecodersBySSRC[packet.ssrc] ?? H264VideoToolboxSubscribeDecoder()
        h264DecodersBySSRC[packet.ssrc] = decoder

        do {
            let accessUnits = try pipeline.append(packet)
            result.h264AccessUnits.append(contentsOf: accessUnits)

            var signals: [SubscribeRTCPFeedbackSignal] = []
            for accessUnit in accessUnits {
                decoder.configureIfPossible(from: accessUnit)
                if !decoder.isConfigured {
                    signals.append(.keyFrameRequest)
                    continue
                }

                guard isVideoDecodeEnabled else {
                    continue
                }

                do {
                    result.decodedVideoFrameCount += try decoder.decode(accessUnit).count
                } catch {
                    result.videoDecodeErrorCount += 1
                    signals.append(.keyFrameRequest)
                }
            }
            return signals
        } catch let error as H264RTPError {
            return [.h264RTPError(error), .keyFrameRequest]
        } catch {
            return [.keyFrameRequest]
        }
    }

    private func appendOpusPacket(
        _ packet: RTPPacket,
        result: inout SubscriberMediaReceiveResult
    ) {
        let pipeline = opusPipelinesBySSRC[packet.ssrc] ?? OpusSubscribePipeline(expectedPayloadType: audioPayloadType)
        opusPipelinesBySSRC[packet.ssrc] = pipeline

        do {
            let opusPacket = try pipeline.append(packet)
            result.opusPackets.append(opusPacket)
            if let audioPlayoutPipeline {
                do {
                    try audioPlayoutPipeline.append(opusPacket)
                    result.decodedAudioBufferCount += 1
                } catch {
                    result.audioPlayoutErrorCount += 1
                }
            }
        } catch {
            result.droppedSequenceNumbers.append(packet.sequenceNumber)
        }
    }
}
