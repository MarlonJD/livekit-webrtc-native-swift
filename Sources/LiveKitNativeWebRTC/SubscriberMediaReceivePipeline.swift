import Foundation

package struct SubscriberMediaReceiveResult: Equatable, Sendable {
    package var releasedPackets: [RTPPacket]
    package var missingSequenceNumbers: [UInt16]
    package var droppedSequenceNumbers: [UInt16]
    package var h264AccessUnits: [H264AccessUnit]
    package var opusPackets: [OpusPacket]
    package var feedbackPackets: [RTCPPacket]

    package init(
        releasedPackets: [RTPPacket] = [],
        missingSequenceNumbers: [UInt16] = [],
        droppedSequenceNumbers: [UInt16] = [],
        h264AccessUnits: [H264AccessUnit] = [],
        opusPackets: [OpusPacket] = [],
        feedbackPackets: [RTCPPacket] = []
    ) {
        self.releasedPackets = releasedPackets
        self.missingSequenceNumbers = missingSequenceNumbers
        self.droppedSequenceNumbers = droppedSequenceNumbers
        self.h264AccessUnits = h264AccessUnits
        self.opusPackets = opusPackets
        self.feedbackPackets = feedbackPackets
    }
}

package final class SubscriberMediaReceivePipeline: @unchecked Sendable {
    package let audioPayloadType: UInt8
    package let videoPayloadType: UInt8
    package let feedbackSenderSSRC: UInt32
    private let maxBufferedPackets: Int
    private let lock = NSLock()
    private var jitterBuffersBySSRC: [UInt32: RTPJitterBuffer] = [:]
    private var h264PipelinesBySSRC: [UInt32: H264SubscribePipeline] = [:]
    private var h264DecodersBySSRC: [UInt32: H264VideoToolboxSubscribeDecoder] = [:]
    private var opusPipelinesBySSRC: [UInt32: OpusSubscribePipeline] = [:]

    package init(
        audioPayloadType: UInt8 = 111,
        videoPayloadType: UInt8 = 102,
        feedbackSenderSSRC: UInt32 = 0,
        maxBufferedPackets: Int = 64
    ) {
        self.audioPayloadType = audioPayloadType
        self.videoPayloadType = videoPayloadType
        self.feedbackSenderSSRC = feedbackSenderSSRC
        self.maxBufferedPackets = maxBufferedPackets
    }

    package func append(_ packet: RTPPacket) -> SubscriberMediaReceiveResult {
        lock.withLock {
            appendLocked(packet)
        }
    }

    private func appendLocked(_ packet: RTPPacket) -> SubscriberMediaReceiveResult {
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
            result.opusPackets.append(try pipeline.append(packet))
        } catch {
            result.droppedSequenceNumbers.append(packet.sequenceNumber)
        }
    }
}
